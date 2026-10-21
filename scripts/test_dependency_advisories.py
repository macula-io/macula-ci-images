#!/usr/bin/env python3
"""Prove the dependency-advisories check before any repository calls it.

Every case runs against the check AS EMBEDDED in
.github/workflows/dependency-advisories.yml, so what is tested is what a caller
runs, and the first case fails when the embedded copy and
scripts/dependency_advisories.py have drifted apart.

The scanner outputs are recorded fixtures: the shapes each tool prints, trimmed.
Nothing here needs the network or a toolchain, so the test runs anywhere and says
exactly which shape stopped being read.

Usage: scripts/test_dependency_advisories.py
"""

import argparse
import contextlib
import importlib.util
import io
import json
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPOSITORY = HERE.parent
WORKFLOW = REPOSITORY / ".github/workflows/dependency-advisories.yml"
SOURCE = HERE / "dependency_advisories.py"
FIXTURES = HERE / "fixtures/dependency_advisories"
MARKER = "DEPENDENCY_ADVISORIES_SCRIPT"

FAILED = []


def embedded_script():
    """The check as the workflow carries it, read the way a runner reads it: the
    workflow parsed, the step's run text, the marked block between its heredoc
    and its closing marker."""
    import yaml

    workflow = yaml.safe_load(WORKFLOW.read_text())
    for step in workflow["jobs"]["advisories"]["steps"]:
        run = step.get("run") or ""
        if f"<<'{MARKER}'" in run:
            after = run.split(f"<<'{MARKER}'", 1)[1].lstrip("\n")
            return after.rsplit("\n" + MARKER, 1)[0] + "\n"
    raise AssertionError(f"no {MARKER} block in {WORKFLOW}")


def load(script_text):
    """The embedded check as a module, so its functions are the ones tested."""
    directory = Path(tempfile.mkdtemp())
    path = directory / "dependency_advisories_embedded.py"
    path.write_text(script_text)
    spec = importlib.util.spec_from_file_location("dependency_advisories_embedded", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def fixture(name):
    return (FIXTURES / name).read_text()


# --------------------------------------------------------------------------
# The cases. Each one asserts; a failure names the case.


def case_the_embedded_copy_is_the_script(module):
    assert embedded_script() == SOURCE.read_text(), (
        "the block in the workflow is not scripts/dependency_advisories.py: "
        "run scripts/embed_dependency_advisories.sh")


def case_osv_reads_each_package(module):
    found = module.parse_osv(json.loads(fixture("osv.json")))
    assert [f.advisory for f in found] == ["EEF-CVE-2026-56811", "GHSA-w7p3-7y2c-8nq3"], found
    phoenix, plug = found
    assert (phoenix.package, phoenix.version) == ("phoenix", "1.4.0"), phoenix
    assert phoenix.fixed == "1.5.15, 1.6.17", phoenix.fixed
    assert phoenix.severity == "8.7", phoenix.severity
    assert phoenix.title.startswith("Phoenix transports do not limit"), phoenix.title
    assert plug.severity == "5.3" and plug.fixed == "1.16.6", plug


def case_osv_with_nothing_found(module):
    assert module.parse_osv({"results": []}) == []


def case_govulncheck_reads_the_stream(module):
    found, unreachable = module.parse_govulncheck(fixture("govulncheck.json"))
    assert len(found) == 3, found
    stdlib = [f for f in found if f.package == "net/http/internal/http2"]
    assert len(stdlib) == 2, stdlib
    assert stdlib[0].advisory == "GO-2026-6603" and stdlib[0].fixed == "v1.27.2", stdlib[0]
    assert stdlib[0].title.startswith("HTTP/2 server memory exhaustion"), stdlib[0].title
    assert [f.package for f in found].count("golang.org/x/net/http2") == 1, found


def case_a_module_the_code_cannot_reach_is_not_a_finding(module):
    found, unreachable = module.parse_govulncheck(fixture("govulncheck.json"))
    assert unreachable == 1, unreachable
    assert not [f for f in found if "crypto" in f.package], found


def case_a_finding_once_per_call_trace_is_one_row(module):
    text = fixture("govulncheck.json")
    module.SCANNERS = dict(
        module.SCANNERS, go=lambda cwd, work: module.parse_govulncheck(text)[0])
    found = module.run_scan("go", None, None)
    assert len(found) == 2, found
    assert {f.advisory for f in found} == {"GO-2026-6603", "GO-2026-6617"}, found


def case_cargo_audit_reads_vulnerabilities_not_warnings(module):
    found = module.parse_cargo_audit(json.loads(fixture("cargo-audit.json")))
    assert len(found) == 1, found
    entry = found[0]
    assert (entry.advisory, entry.package, entry.version) == ("RUSTSEC-2026-0142", "h2", "0.4.4"), entry
    assert entry.fixed == "0.4.12" and entry.severity == "high", entry


def case_npm_audit_reads_an_advisory_and_its_fix(module):
    found = module.parse_npm_audit(json.loads(fixture("npm-audit.json")))
    assert len(found) == 1, found
    entry = found[0]
    assert entry.advisory == "GHSA-2p57-rm9w-gvfp", entry.advisory
    assert (entry.package, entry.version) == ("undici", "6.0.0 - 6.19.2"), entry
    assert entry.fixed == "undici 6.19.3", entry.fixed
    assert entry.severity == "high", entry.severity


def case_npm_audit_refuses_its_own_error(module):
    try:
        module.parse_npm_audit({"error": {"code": "ENOLOCK"}})
    except module.CouldNotScan:
        return
    raise AssertionError("an npm audit error was read as a clean repository")


def case_pip_audit_reads_each_advisory(module):
    found = module.parse_pip_audit(json.loads(fixture("pip-audit.json")))
    assert len(found) == 1, found
    entry = found[0]
    assert (entry.advisory, entry.package, entry.version) == (
        "GHSA-9wx4-h78v-vm56", "requests", "2.31.0"), entry
    assert entry.fixed == "2.32.0", entry.fixed


def case_composer_audit_reads_advisories(module):
    found = module.parse_composer(json.loads(fixture("composer.json")))
    assert len(found) == 1, found
    entry = found[0]
    assert (entry.advisory, entry.package) == ("PKSA-1y2z-3w4v-5u6t", "guzzlehttp/guzzle"), entry
    assert entry.title.startswith("Cookie header leakage"), entry.title


def case_composer_with_no_package_has_nothing_to_audit(module):
    assert module.parse_composer({"advisories": {}}) == []


def case_dotnet_reads_top_level_and_transitive(module):
    found = module.parse_dotnet(json.loads(fixture("dotnet.json")))
    assert len(found) == 1, found
    entry = found[0]
    assert (entry.advisory, entry.package, entry.version) == (
        "GHSA-abcd-efgh-ijkl", "System.Text.Json", "9.0.0"), entry
    assert entry.severity == "High", entry.severity
    assert "src/Macula/Macula.csproj" in entry.title, entry.title


def case_a_rebar_lock_becomes_hex_packages(module):
    packages = module.rebar_packages(FIXTURES / "rebar.lock")
    assert packages == {"gproc": "1.3.0", "macula": "15.6.0", "recon": "2.5.6",
                        "telemetry": "1.4.2"}, packages
    sbom = module.cyclonedx(packages)
    assert [component["purl"] for component in sbom["components"]] == [
        "pkg:hex/gproc@1.3.0", "pkg:hex/macula@15.6.0", "pkg:hex/recon@2.5.6",
        "pkg:hex/telemetry@1.4.2"], sbom


def case_a_waiver_is_read_and_dated(module):
    waivers = module.parse_waivers(FIXTURES / "waivers-good.txt", module.parse_today("2026-10-21"))
    assert set(waivers) == {("GHSA-2p57-rm9w-gvfp", "undici"), ("RUSTSEC-2026-0374", "basic-toml")}
    waiver = waivers[("GHSA-2p57-rm9w-gvfp", "undici")]
    assert waiver.owner == "ceres", waiver
    assert waiver.expires.isoformat() == "2026-12-31", waiver


def case_an_expired_waiver_fails_the_run(module):
    try:
        module.parse_waivers(FIXTURES / "waivers-expired.txt", module.parse_today("2026-10-21"))
    except module.CouldNotScan as problem:
        assert "expired" in str(problem), problem
        return
    raise AssertionError("an expired waiver was accepted")


def case_a_waiver_without_its_fields_is_refused(module):
    try:
        module.parse_waivers(FIXTURES / "waivers-malformed.txt", module.parse_today("2026-10-21"))
    except module.CouldNotScan as problem:
        assert "5 fields" in str(problem), problem
        return
    raise AssertionError("a waiver with no owner or expiry was accepted")
    # The same rule, said once more for the fields that a row can carry empty.


def case_a_waiver_with_no_reason_or_owner_is_refused(module):
    today = module.parse_today("2026-10-21")
    for row in ("GHSA-x | undici |  | ceres | 2026-12-31",
                "GHSA-x | undici | dev-only |  | 2026-12-31",
                "GHSA-x | undici | dev-only | ceres | soon",
                "GHSA-x |  | dev-only | ceres | 2026-12-31"):
        waiver, problem = module.parse_waiver(row, today)
        assert problem, f"accepted a waiver with no reason, owner, package or date: {row}"
        assert waiver is None, row


def case_a_waived_finding_is_not_left(module):
    found = module.parse_osv(json.loads(fixture("osv.json")))
    waivers = module.parse_waivers(FIXTURES / "waivers-good.txt", module.parse_today("2026-10-21"))
    waived, left = module.split_by_waiver(found, waivers)
    assert waived == [] and len(left) == 2, (waived, left)
    two = dict(waivers)
    two[("EEF-CVE-2026-56811", "phoenix")] = waivers[("GHSA-2p57-rm9w-gvfp", "undici")]
    waived, left = module.split_by_waiver(found, two)
    assert len(waived) == 1 and len(left) == 1, (waived, left)


# --------------------------------------------------------------------------
# End to end: the exit code a CI job sees.


def scan_in(directory, findings, waivers=None, ecosystem="rust"):
    """The check's own entry point over a directory, with the scanner replaced
    by the fixtures: what is proved here is the reading, the waiving and the
    exit code, not a toolchain."""
    module = load(embedded_script())
    module.SCANNERS = dict(module.SCANNERS, **{ecosystem: lambda cwd, work: findings})
    if waivers is not None:
        (directory / ".github").mkdir(exist_ok=True)
        (directory / ".github/advisories-waivers.txt").write_text(waivers)
    args = argparse.Namespace(ecosystem=ecosystem, working_directory=str(directory),
                              waivers=".github/advisories-waivers.txt",
                              work=str(directory / "work"), today="2026-10-21")
    output = io.StringIO()
    with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
        code = module.scan_and_report(args)
    return code, output.getvalue()


def case_a_clean_scan_exits_zero(module):
    found = []
    code, text = scan_in(Path(tempfile.mkdtemp()), found)
    assert code == 0, (code, text)
    assert "0 advisory finding(s)" in text, text


def case_a_finding_exits_one_and_is_annotated(module):
    found = module.parse_cargo_audit(json.loads(fixture("cargo-audit.json")))
    code, text = scan_in(Path(tempfile.mkdtemp()), found)
    assert code == 1, (code, text)
    assert "::error::RUSTSEC-2026-0142 | h2 0.4.4 | fixed in 0.4.12 | severity high" in text, text


def case_a_waived_finding_exits_zero_and_says_until_when(module):
    found = [module.Finding("GHSA-2p57-rm9w-gvfp", "undici", "6.19.2", "undici 6.19.3",
                            "high", "a dev-only advisory")]
    code, text = scan_in(Path(tempfile.mkdtemp()), found,
                         waivers=fixture("waivers-good.txt"))
    assert code == 0, (code, text)
    assert "waived until 2026-12-31 (ceres)" in text, text


def case_an_expired_waiver_exits_two(module):
    found = [module.Finding("GHSA-2p57-rm9w-gvfp", "undici", "6.19.2", "", "high", "")]
    code, text = scan_in(Path(tempfile.mkdtemp()), found, waivers=fixture("waivers-expired.txt"))
    assert code == 2, (code, text)
    assert "expired" in text, text


def case_a_scanner_that_cannot_run_exits_two(module):
    def broken(cwd, work):
        raise module.CouldNotScan("cargo audit is not installed")

    original = module.SCANNERS
    module.SCANNERS = dict(original, rust=broken)
    try:
        directory = Path(tempfile.mkdtemp())
        args = argparse.Namespace(ecosystem="rust", working_directory=str(directory),
                                  waivers=".github/advisories-waivers.txt",
                                  work=str(directory / "work"), today="2026-10-21")
        output = io.StringIO()
        with contextlib.redirect_stderr(output):
            code = module.scan_and_report(args)
    finally:
        module.SCANNERS = original
    assert code == 2, (code, output.getvalue())
    assert "cargo audit is not installed" in output.getvalue(), output.getvalue()


def case_a_directory_that_is_not_there_exits_two(module):
    code, text = scan_in(Path("/nonexistent-macula-advisories"), [])
    assert code == 2, (code, text)


CASES = [
    case_the_embedded_copy_is_the_script,
    case_osv_reads_each_package,
    case_osv_with_nothing_found,
    case_govulncheck_reads_the_stream,
    case_a_finding_once_per_call_trace_is_one_row,
    case_cargo_audit_reads_vulnerabilities_not_warnings,
    case_npm_audit_reads_an_advisory_and_its_fix,
    case_npm_audit_refuses_its_own_error,
    case_pip_audit_reads_each_advisory,
    case_composer_audit_reads_advisories,
    case_composer_with_no_package_has_nothing_to_audit,
    case_dotnet_reads_top_level_and_transitive,
    case_a_rebar_lock_becomes_hex_packages,
    case_a_waiver_is_read_and_dated,
    case_an_expired_waiver_fails_the_run,
    case_a_waiver_without_its_fields_is_refused,
    case_a_waiver_with_no_reason_or_owner_is_refused,
    case_a_waived_finding_is_not_left,
    case_a_clean_scan_exits_zero,
    case_a_finding_exits_one_and_is_annotated,
    case_a_waived_finding_exits_zero_and_says_until_when,
    case_an_expired_waiver_exits_two,
    case_a_scanner_that_cannot_run_exits_two,
    case_a_directory_that_is_not_there_exits_two,
]


def main():
    module = load(embedded_script())
    for case in CASES:
        try:
            case(module)
        except Exception as problem:  # noqa: BLE001 - a case that raises is a failure
            FAILED.append(case.__name__)
            print(f"FAIL {case.__name__}: {type(problem).__name__}: {problem}")
        else:
            print(f"ok   {case.__name__}")
    print(f"\n{len(CASES) - len(FAILED)} of {len(CASES)} passed")
    return 1 if FAILED else 0


if __name__ == "__main__":
    sys.exit(main())
