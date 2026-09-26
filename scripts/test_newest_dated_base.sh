#!/usr/bin/env bash
# Does newest_dated_base.py ride out a flaky Docker Hub, and still fail loudly
# when it stays down?
#
# The daily build failed once on a single read timeout from Docker Hub
# (2026-09-26, run 36275367449): one HTTP attempt, no retry. This serves the
# tag API from a local server that fails a set number of times first, and
# refuses unless the resolver retries through transient failures, gives up
# after its last attempt with a non-zero exit naming the URL and the last
# error, and does not retry a request Docker Hub has answered with a 4xx.
#
# Usage: scripts/test_newest_dated_base.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESOLVER="$HERE/newest_dated_base.py"
WORK="$(mktemp -d)"
SERVER=""
trap '[ -z "$SERVER" ] || kill "$SERVER" 2>/dev/null; rm -rf "$WORK"' EXIT

fail() { echo "REFUSED: $*"; exit 1; }

# A Containerfile whose FROM resolves against library/debian.
# shellcheck disable=SC2016 # a literal Containerfile ARG reference, on purpose
printf 'ARG DEBIAN_VERSION=trixie-20260101-slim\nFROM docker.io/library/debian:${DEBIAN_VERSION}\n' > "$WORK/Containerfile"

# serve <mode> <failures>: the first <failures> requests fail as <mode>
# (503, 404, hang, short or badjson); after that the tag API answers with two dated tags.
# Every request is counted in $WORK/hits.
serve() {
    [ -z "$SERVER" ] || kill "$SERVER" 2>/dev/null
    : > "$WORK/hits"
    python3 - "$1" "$2" "$WORK/hits" "$WORK/port" <<'PY' &
import http.server, json, sys, time
mode, failures, hits, portfile = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]

class Hub(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass
    def do_GET(self):
        with open(hits, "a") as f:
            f.write(self.path + "\n")
        n = sum(1 for _ in open(hits))
        if n <= failures:
            if mode == "hang":
                time.sleep(5)
                return
            if mode in ("short", "badjson"):
                # A 200 whose body is cut off: promised longer than sent
                # (short), or complete but truncated JSON (badjson).
                body = b'{"results": [{"name": "trixie-2026'
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body) + (100 if mode == "short" else 0)))
                self.end_headers()
                self.wfile.write(body)
                self.wfile.flush()
                self.close_connection = True
                return
            self.send_response(int(mode))
            self.end_headers()
            return
        body = json.dumps({"results": [{"name": "trixie-20260918-slim"},
                                       {"name": "trixie-20260901-slim"}], "next": None}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(body)

server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Hub)
open(portfile, "w").write(str(server.server_port))
server.serve_forever()
PY
    SERVER=$!
    for _ in $(seq 50); do [ -s "$WORK/port" ] && break; sleep 0.1; done
    [ -s "$WORK/port" ] || fail "the fake Docker Hub did not start"
    NEWEST_BASE_HUB="http://127.0.0.1:$(cat "$WORK/port")"
    export NEWEST_BASE_HUB
    rm -f "$WORK/port"
}

hits() { wc -l < "$WORK/hits"; }

export NEWEST_BASE_ATTEMPTS=3 NEWEST_BASE_BACKOFF=0.1 NEWEST_BASE_TIMEOUT=1

# 1. Two transient failures, then an answer: resolved, on the third attempt.
serve 503 2
OUT=$(python3 "$RESOLVER" "$WORK/Containerfile" 2>&1) || fail "two 503s then an answer did not resolve: $OUT"
[ "$(tail -1 <<<"$OUT")" = trixie-20260918-slim ] || fail "the newest dated base was not printed: $OUT"
[ "$(hits)" -eq 3 ] || fail "expected 3 requests, saw $(hits)"

# 2. A read timeout is transient too: the failure that stopped the real build.
serve hang 1
OUT=$(python3 "$RESOLVER" "$WORK/Containerfile" 2>&1) || fail "a timeout then an answer did not resolve: $OUT"
[ "$(tail -1 <<<"$OUT")" = trixie-20260918-slim ] || fail "the base was not printed after a timeout: $OUT"

# 2b. A body cut off mid-read, and a 200 with truncated JSON, are hiccups
#     of the same kind: retried, not a traceback on the first one.
for mode in short badjson; do
    serve "$mode" 1
    OUT=$(python3 "$RESOLVER" "$WORK/Containerfile" 2>&1) || fail "a $mode body then an answer did not resolve: $OUT"
    [ "$(tail -1 <<<"$OUT")" = trixie-20260918-slim ] || fail "the base was not printed after a $mode body: $OUT"
    grep -q Traceback <<<"$OUT" && fail "a $mode body crashed the resolver: $OUT"
done

# 3. Down for every attempt: a non-zero exit, after exactly the allowed
#    attempts, naming the URL and the last error. Never a fallback base.
serve 503 99
OUT=$(python3 "$RESOLVER" "$WORK/Containerfile" 2>&1) && fail "a Docker Hub down for every attempt resolved: $OUT"
[ "$(hits)" -eq 3 ] || fail "expected exactly 3 attempts before giving up, saw $(hits)"
grep -q "REFUSED: .*after 3 attempts" <<<"$OUT" || fail "the failure did not say it gave up after 3 attempts: $OUT"
grep -q "$NEWEST_BASE_HUB/v2/repositories/library/debian/tags" <<<"$OUT" || fail "the failure did not name the URL: $OUT"
grep -q "503" <<<"$OUT" || fail "the failure did not name the last error: $OUT"
serve 503 99
STDOUT=$(python3 "$RESOLVER" "$WORK/Containerfile" 2>/dev/null) && fail "a Docker Hub down for every attempt resolved"
[ -z "$STDOUT" ] || fail "a failed resolve printed a base on stdout: $STDOUT"

# 4. A 4xx is Docker Hub's answer, not a hiccup: no retry, fail at once.
serve 404 99
OUT=$(python3 "$RESOLVER" "$WORK/Containerfile" 2>&1) && fail "a 404 resolved: $OUT"
[ "$(hits)" -eq 1 ] || fail "a 404 was retried: $(hits) requests"
grep -q "404" <<<"$OUT" || fail "the 404 was not named: $OUT"

# 5. A malformed setting (attempts, or a nan/inf backoff) is refused, not
#    read as some default.
for v in nan inf; do
    OUT=$(NEWEST_BASE_BACKOFF="$v" python3 "$RESOLVER" "$WORK/Containerfile" 2>&1) && fail "NEWEST_BASE_BACKOFF='$v' was accepted: $OUT"
    grep -q "REFUSED: NEWEST_BASE_BACKOFF='$v'" <<<"$OUT" || fail "the refusal did not name NEWEST_BASE_BACKOFF='$v': $OUT"
done
for v in 0 -1 x ""; do
    OUT=$(NEWEST_BASE_ATTEMPTS="$v" python3 "$RESOLVER" "$WORK/Containerfile" 2>&1) && fail "NEWEST_BASE_ATTEMPTS='$v' was accepted: $OUT"
    grep -q "REFUSED: NEWEST_BASE_ATTEMPTS='$v'" <<<"$OUT" || fail "the refusal did not name NEWEST_BASE_ATTEMPTS='$v': $OUT"
done

echo "OK: newest_dated_base.py retries transient failures and fails loudly when they persist"
