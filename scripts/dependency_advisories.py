#!/usr/bin/env python3
"""One ecosystem's known-vulnerable dependencies: a release fails on one.

This exists so no release of ours ships a dependency with a known published
advisory without its CI refusing it first, and so an attacker cannot rely on a
vulnerability that is already public sitting in a package of ours
(macula-codebase-checks#11).

It runs the ecosystem's own scanner over what the release ships, reads the
repository's waivers, prints what is left, and exits 1 while anything is left
unwaived. There is no baseline and no "known findings" file: an advisory is
fixed, or a dated, named waiver says why it cannot be yet and when it must be.

  erlang  rebar3 compile, then the resolved rebar.lock as an SBOM, to osv-scanner
  elixir  mix deps.get, then mix.lock to osv-scanner
  go      govulncheck, which reports the vulnerabilities the code can reach,
          at call and package level; a module-level one is named, not failed
  rust    cargo audit, its vulnerabilities (an unmaintained crate is a warning)
  node    npm audit over the whole lock, dev included: a build tool runs in
          the release job with its credentials
  php     composer install, then composer audit over the whole lock
  python  the dependency set and the build backend's own requirements in
          [build-system], resolved and then audited by pip-audit; a test or
          dev extra is out, because it does not run in the release job
  csharp  dotnet list package --vulnerable --include-transitive

The waivers are a file in the repository, one row per advisory:

  # advisory | package | why it cannot be fixed yet | owner | expires YYYY-MM-DD
  GHSA-2p57-rm9w-gvfp | undici | dev-only: never shipped; fix lands with undici 7 | ceres | 2026-11-30

An expired waiver fails the run (exit 2), so a waiver cannot outlive its reason
unless someone looks at it again. A row without a why, an owner or an expiry is
refused the same way.

The waivers file is the only way to waive. Several scanners also read a config
file from the repository they run in, and more than one key there can drop a
finding with no date, no owner and no why, so those files are checked against an
allow-list rather than a list of refusals: cargo audit's .cargo/audit.toml may
carry [output], [yanked] and [advisories] informational_warnings and nothing
else; composer audit's composer.json config.audit may carry abandoned,
block-insecure and block-abandoned and nothing else; and a committed .npmrc may
not point npm audit at another registry or set a key that prunes the install. A
composer.json that switches packagist.org off is refused too: it leaves the audit
no advisory source to ask. Anything else is refused, naming the key (exit 2).
Likewise a rebar.lock or mix.lock that pins a git or path dependency is refused:
it ships, but no advisory database can look it up, so the scanned set would
quietly be smaller than the shipped set.

Usage:
  dependency_advisories.py --ecosystem node [--working-directory .]
                           [--waivers PATH] [--work DIR] [--today YYYY-MM-DD]
"""

import argparse
import datetime
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import tomllib
from dataclasses import dataclass
from pathlib import Path

ECOSYSTEMS = ("erlang", "elixir", "go", "rust", "node", "php", "python", "csharp")
SCANNER = {
    "erlang": "osv-scanner on the resolved rebar.lock",
    "elixir": "osv-scanner on mix.lock",
    "go": "govulncheck",
    "rust": "cargo audit",
    "node": "npm audit",
    "php": "composer audit",
    "python": "pip-audit",
    "csharp": "dotnet list package --vulnerable",
}


class CouldNotScan(Exception):
    """The scan could not run, or its answer could not be read: exit 2."""


@dataclass(frozen=True)
class Finding:
    advisory: str
    package: str
    version: str
    fixed: str
    severity: str
    title: str


@dataclass(frozen=True)
class Waiver:
    advisory: str
    package: str
    why: str
    owner: str
    expires: datetime.date


# --------------------------------------------------------------------------
# Running things.


def output(command, cwd, ok=(0,)):
    """One command's stdout, or CouldNotScan. A return code outside `ok` is a
    failure to scan, never a finding: a broken tool must not read as a clean
    repository."""
    try:
        done = subprocess.run(command, cwd=str(cwd), capture_output=True, text=True,
                              check=False)
    except FileNotFoundError as missing:
        raise CouldNotScan(f"{command[0]} is not installed: {missing}") from missing
    if done.returncode not in ok:
        raise CouldNotScan(f"{' '.join(command)} exited {done.returncode}: "
                           f"{last_lines(done.stderr)}")
    return done.stdout


def last_lines(text, wanted=6):
    lines = [line for line in (text or "").strip().splitlines() if line.strip()]
    return " / ".join(lines[-wanted:]) or "no output"


def load_json(text, tool):
    try:
        return json.loads(text)
    except json.JSONDecodeError as broken:
        raise CouldNotScan(f"{tool} did not print JSON: {broken}") from broken


def osv_scanner():
    return os.environ.get("OSV_SCANNER") or shutil.which("osv-scanner") or "osv-scanner"


# --------------------------------------------------------------------------
# The scanners. Each reads what the release ships and returns Findings.


def erlang_findings(cwd, work):
    """A rebar3 project commits no lock, so the build's resolved one is what is
    read: rebar3 compile writes rebar.lock from the versions it actually used."""
    output(["rebar3", "compile"], cwd)
    lock = cwd / "rebar.lock"
    if not lock.exists():
        raise CouldNotScan(f"rebar3 compile wrote no {lock}")
    refuse_a_foreign_dependency(lock)
    packages = rebar_packages(lock)
    if not packages:
        raise CouldNotScan(f"{lock} names no package")
    sbom = work / "sbom.cdx.json"
    sbom.write_text(json.dumps(cyclonedx(packages), indent=2) + "\n")
    return osv_findings(work)


REBAR_LOCK_ENTRY = re.compile(
    r'\{\s*<<"([^"]+)">>\s*,\s*\{pkg\s*,\s*<<"([^"]+)">>\s*,\s*<<"([^"]+)">>\s*\}')
# A lock entry whose second element is any source other than a released
# package: {<<"name">>, {git | path | hg, ...}, Level}.
REBAR_LOCK_OTHER = re.compile(r'\{\s*<<"([^"]+)">>\s*,\s*\{\s*(git|path|hg)\s*,')


def rebar_packages(lock):
    """The {pkg, Name, Version} entries of a rebar.lock, as name to version."""
    packages = {}
    for line in lock.read_text(errors="replace").splitlines():
        entry = REBAR_LOCK_ENTRY.search(line)
        if entry:
            packages[entry.group(2)] = entry.group(3)
    return packages


def rebar_foreign_dependencies(lock):
    """Every lock entry that is not a released package, as name and kind."""
    return [f"{entry.group(1)} ({entry.group(2)})"
            for line in lock.read_text(errors="replace").splitlines()
            for entry in [REBAR_LOCK_OTHER.search(line)] if entry]


def refuse_a_foreign_dependency(lock):
    """A git or path dependency ships, but no advisory database can look it up,
    so scanning it would leave the gate quietly smaller than what is shipped -
    and a git dependency is also how an advisory could be made to disappear
    rather than be fixed."""
    foreign = rebar_foreign_dependencies(lock)
    if foreign:
        raise CouldNotScan(
            f"{lock} carries {', '.join(foreign)}, which is not a released package: no "
            "advisory database covers it, so the scanned set would be smaller than the "
            "shipped set. Depend on a released version")


def cyclonedx(packages):
    """A CycloneDX document osv-scanner reads as Hex packages: rebar.lock has no
    reader of its own in the scanner, an SBOM does."""
    return {
        "bomFormat": "CycloneDX",
        "specVersion": "1.5",
        "version": 1,
        "components": [
            {"type": "library", "name": name, "version": version,
             "purl": f"pkg:hex/{name}@{version}"}
            for name, version in sorted(packages.items())
        ],
    }


def elixir_findings(cwd, work):
    """mix.lock is generated too (and is gitignored in several of our
    repositories), so deps.get writes it and it is copied where the scanner
    sees it by name."""
    output(["mix", "deps.get"], cwd)
    lock = cwd / "mix.lock"
    if not lock.exists():
        raise CouldNotScan(f"mix deps.get wrote no {lock}")
    refuse_a_foreign_mix_dependency(lock)
    shutil.copyfile(lock, work / "mix.lock")
    return osv_findings(work)


# A mix.lock entry whose source is not a released hex package:
# "name": {:git, ...} or "name": {:path, ...}.
MIX_LOCK_OTHER = re.compile(r'"([^"]+)"\s*:\s*\{:(git|path)\s*,')


def mix_foreign_dependencies(lock):
    """Every mix.lock entry that is not a hex package, as name and kind."""
    return [f"{entry.group(1)} ({entry.group(2)})"
            for line in lock.read_text(errors="replace").splitlines()
            for entry in [MIX_LOCK_OTHER.search(line)] if entry]


def refuse_a_foreign_mix_dependency(lock):
    """osv-scanner looks up hex packages and no git revision, so a git or path
    dependency ships unscanned. The same rule as rebar.lock, for the same
    reason."""
    foreign = mix_foreign_dependencies(lock)
    if foreign:
        raise CouldNotScan(
            f"{lock} carries {', '.join(foreign)}, which is not a hex package: no "
            "advisory database covers it, so the scanned set would be smaller than "
            "the shipped set. Depend on a released version")


def osv_findings(directory):
    text = output([osv_scanner(), "scan", "source", str(directory), "--format", "json",
                "--all-vulns"], directory, ok=(0, 1))
    return parse_osv(load_json(text, "osv-scanner"))


def parse_osv(document):
    found = []
    for result in document.get("results") or []:
        for entry in result.get("packages") or []:
            found += osv_package(entry)
    return found


def osv_package(entry):
    package = entry.get("package") or {}
    severity = group_severities(entry)
    return [Finding(advisory=vuln.get("id", ""),
                    package=package.get("name", ""),
                    version=package.get("version", ""),
                    fixed=", ".join(fixed_versions(vuln)),
                    severity=severity.get(vuln.get("id"), ""),
                    title=first_line(vuln.get("summary")))
            for vuln in entry.get("vulnerabilities") or []]


def group_severities(entry):
    """The CVSS score osv-scanner reports, keyed by every id the group is known
    by (a finding may carry the GHSA id while the group names the CVE)."""
    scores = {}
    for group in entry.get("groups") or []:
        for name in (group.get("ids") or []) + (group.get("aliases") or []):
            scores[name] = group.get("max_severity") or scores.get(name, "")
    return scores


def fixed_versions(vulnerability):
    """Every version the advisory says fixes it, in the order the ranges give."""
    out = []
    for affected in vulnerability.get("affected") or []:
        for ranges in affected.get("ranges") or []:
            for event in ranges.get("events") or []:
                fixed = event.get("fixed")
                if fixed and fixed not in out:
                    out.append(fixed)
    return out


def go_findings(cwd, work):
    """govulncheck reports what the code can reach, at three levels: a call it
    found (symbol), a package it imports, and a module it merely requires. The
    first two are findings, because the code can reach the advisory through
    them. The third is a version that carries an advisory nobody can call, and
    it is named here without failing the build.
    """
    text = output(["govulncheck", "-json", "./..."], cwd, ok=(0, 3))
    found, unreachable = parse_govulncheck(text)
    if unreachable:
        print(f"govulncheck: {unreachable} advisory(ies) sit in required modules this "
              "code cannot call, so they are not findings", file=sys.stderr)
    return found


def parse_govulncheck(text):
    """govulncheck prints a stream of JSON documents, one message per concern
    (config, the module list, every osv record, every finding), not JSON lines:
    they are decoded one after another from the whole stream.

    Returns the findings and the number of advisories that are only in a
    required module: a trace that names no package and no function is that.
    The count is of distinct advisories, not messages, because one unreachable
    advisory is announced once per module that requires it.
    """
    summaries, found, unreachable = {}, [], set()
    for message in json_messages(text, "govulncheck"):
        if "osv" in message:
            summaries[message["osv"].get("id", "")] = first_line(message["osv"].get("summary"))
        finding = message.get("finding") or {}
        if not finding.get("trace"):
            continue
        reached = reached_entry(finding["trace"])
        if reached is None:
            unreachable.add(finding.get("osv", ""))
        else:
            found.append(govulncheck_finding(finding, reached, summaries))
    return found, len(unreachable)


def reached_entry(trace):
    """The first entry of a trace that names a package or a function: what
    govulncheck reached, as opposed to the module the advisory arrived in."""
    for entry in trace:
        if entry.get("package") or entry.get("function"):
            return entry
    return None


def json_messages(text, tool):
    decoder = json.JSONDecoder()
    position = 0
    while True:
        while position < len(text) and text[position].isspace():
            position += 1
        if position >= len(text):
            return
        try:
            message, position = decoder.raw_decode(text, position)
        except json.JSONDecodeError as broken:
            raise CouldNotScan(f"{tool} did not print JSON: {broken}") from broken
        yield message


def govulncheck_finding(finding, reached, summaries):
    return Finding(advisory=finding.get("osv", ""),
                   package=reached.get("package") or reached.get("module", ""),
                   version=reached.get("version", ""),
                   fixed=finding.get("fixed_version", ""),
                   severity="",
                   title=summaries.get(finding.get("osv", ""), ""))


def rust_findings(cwd, work):
    text = output(["cargo", "audit", "--json"], cwd, ok=(0, 1))
    return parse_cargo_audit(load_json(text, "cargo audit"))


def parse_cargo_audit(document):
    found = []
    for entry in (document.get("vulnerabilities") or {}).get("list") or []:
        advisory = entry.get("advisory") or {}
        package = entry.get("package") or {}
        found.append(Finding(advisory=advisory.get("id", ""),
                             package=package.get("name", ""),
                             version=package.get("version", ""),
                             fixed=", ".join((entry.get("versions") or {}).get("patched") or []),
                             severity=str(advisory.get("severity") or ""),
                             title=first_line(advisory.get("title"))))
    return found


def node_findings(cwd, work):
    """The whole lock, dev included. A build tool runs inside the release job
    with the repository's credentials, so a vulnerable one is a way into the
    artifact, and it is what Dependabot reports. A dev advisory that cannot be
    fixed gets a waiver like any other, rather than being out of scope."""
    text = output(["npm", "audit", "--json"], cwd, ok=(0, 1))
    return parse_npm_audit(load_json(text, "npm audit"))


def parse_npm_audit(document):
    if document.get("error"):
        raise CouldNotScan(f"npm audit reported an error: {document['error']}")
    found = []
    for name, entry in (document.get("vulnerabilities") or {}).items():
        found += [npm_advisory(name, entry, via) for via in entry.get("via") or []
                  if isinstance(via, dict)]
    return found


def npm_advisory(name, entry, via):
    return Finding(advisory=advisory_id(via),
                   package=name,
                   version=entry.get("range", ""),
                   fixed=fix_available(entry.get("fixAvailable")),
                   severity=via.get("severity", ""),
                   title=first_line(via.get("title")))


def advisory_id(via):
    """The advisory npm names by URL when it has one (a GitHub advisory), and by
    its own numeric id when it has not."""
    found = re.search(r"GHSA-[0-9a-z-]+", str(via.get("url", "")), re.IGNORECASE)
    return found.group(0) if found else f"npm:{via.get('source', '')}"


def fix_available(available):
    if isinstance(available, dict) and available.get("version"):
        return f"{available.get('name', '')} {available['version']}".strip()
    return ""


def php_findings(cwd, work):
    """composer.lock is not committed in every repository, so the install's own
    lock is what is read, require-dev included: a developer tool runs inside the
    release job, and an advisory in one is what Dependabot reports. A package
    with no dependency at all (php and its extensions are not packages) has
    nothing to audit, and composer audit says so with an error rather than an
    empty answer, so it is asked nothing."""
    output(["composer", "install", "--no-interaction", "--quiet"], cwd)
    if not composer_packages(cwd / "composer.lock"):
        return []
    text = output(["composer", "audit", "--locked", "--format=json"], cwd, ok=(0, 1))
    return parse_composer(load_json(text, "composer audit"))


def composer_packages(lock):
    """Every package a composer.lock resolves, require and require-dev."""
    if not lock.exists():
        raise CouldNotScan(f"composer install wrote no {lock}")
    document = load_json(lock.read_text(errors="replace"), "composer.lock")
    return (document.get("packages") or []) + (document.get("packages-dev") or [])


def parse_composer(document):
    found = []
    for package, advisories in (document.get("advisories") or {}).items():
        found += [composer_advisory(package, advisory) for advisory in advisories or []]
    return found


def composer_advisory(package, advisory):
    return Finding(advisory=advisory.get("advisoryId", ""),
                   package=advisory.get("packageName", package),
                   version=advisory.get("affectedVersions", ""),
                   fixed="",
                   severity="",
                   title=first_line(advisory.get("title")))


def python_findings(cwd, work):
    """What `pip install .` would bring in, plus the build backend's own
    requirements. The project itself is resolved and not built: some of ours
    build a native library that needs a toolchain this gate has no business
    carrying, and what ships is the dependency set, not the build. The build
    requirements are in scope because the backend runs inside the release job
    with the PyPI credential, which is the same reason node and php read their
    dev dependencies."""
    venv = work / "venv"
    python = venv / ("Scripts/python.exe" if os.name == "nt" else "bin/python")
    output([sys.executable, "-m", "venv", str(venv)], cwd)
    pins = resolved_pins(cwd, work, python, build_requires(cwd))
    if not pins:
        return []
    output([str(python), "-m", "pip", "install", "--quiet", "--require-hashes",
            "-r", str(audit_requirements())], cwd)
    text = output([str(python), "-m", "pip_audit", "--format", "json", "-r", str(pins)],
                  cwd, ok=(0, 1))
    return parse_pip_audit(load_json(text, "pip-audit"))


def build_requires(cwd):
    """The build backend's requirements, from [build-system] in pyproject.toml.
    They are not in what `pip install .` reports, and they run with the
    credential that publishes the release, so they are resolved and audited
    beside the runtime dependencies. A test or dev extra is not: it runs
    nowhere near the release job."""
    path = cwd / "pyproject.toml"
    if not path.exists():
        return []
    requires = (toml_file(path).get("build-system") or {}).get("requires") or []
    return [str(requirement) for requirement in requires]


def audit_requirements():
    """The pinned, hash-checked wheels pip-audit is installed from. It travels
    beside this script, so the tool that decides the answer cannot change
    between two runs of the same commit."""
    return Path(__file__).with_name("pip-audit-requirements.txt")


def resolved_pins(cwd, work, python, extra=()):
    """The dependency set a `pip install .` resolves to, plus `extra` (the build
    backend's requirements), as pinned requirements (the project itself is a
    local path and is left out), or None when there is no dependency at all."""
    report = work / "pip-report.json"
    output([str(python), "-m", "pip", "install", "--dry-run", "--quiet",
            "--ignore-installed", "--report", str(report), ".", *extra], cwd)
    document = load_json(report.read_text(errors="replace"), "pip install --report")
    pins = sorted(f"{item['metadata']['name']}=={item['metadata']['version']}"
                  for item in document.get("install") or []
                  if not str((item.get("download_info") or {}).get("url", "")).startswith("file:"))
    if not pins:
        return None
    path = work / "requirements-advisories.txt"
    path.write_text("\n".join(pins) + "\n")
    return path


def parse_pip_audit(document):
    found = []
    for dependency in document.get("dependencies") or []:
        found += [pip_advisory(dependency, vuln) for vuln in dependency.get("vulns") or []]
    return found


def pip_advisory(dependency, vuln):
    return Finding(advisory=vuln.get("id", ""),
                   package=dependency.get("name", ""),
                   version=dependency.get("version", ""),
                   fixed=", ".join(vuln.get("fix_versions") or []),
                   severity="",
                   title=first_line(vuln.get("description")))


def csharp_findings(cwd, work):
    target = dotnet_target(cwd)
    output(["dotnet", "restore", target], cwd)
    text = output(["dotnet", "list", target, "package", "--vulnerable",
                "--include-transitive", "--format", "json"], cwd)
    return parse_dotnet(load_json(text, "dotnet list package"))


def dotnet_target(cwd):
    """The solution when the repository has one, else the projects, so a
    solution's every project is read rather than the first one found."""
    for pattern in ("*.slnx", "*.sln"):
        solutions = sorted(cwd.glob(pattern))
        if solutions:
            return solutions[0].name
    projects = sorted(cwd.glob("*.csproj"))
    if not projects:
        raise CouldNotScan(f"no solution or project in {cwd}")
    return projects[0].name


def parse_dotnet(document):
    found = []
    for project in document.get("projects") or []:
        for framework in project.get("frameworks") or []:
            found += dotnet_framework(project, framework)
    return found


def dotnet_framework(project, framework):
    found = []
    for section in ("topLevelPackages", "transitivePackages"):
        for package in framework.get(section) or []:
            found += [dotnet_advisory(project, framework, package, vuln)
                      for vuln in package.get("vulnerabilities") or []]
    return found


def dotnet_advisory(project, framework, package, vuln):
    return Finding(advisory=advisory_id({"url": vuln.get("advisoryurl", "")}),
                   package=package.get("id", ""),
                   version=package.get("resolvedVersion", ""),
                   fixed="",
                   severity=vuln.get("severity", ""),
                   title=f"{project.get('path', '')} ({framework.get('framework', '')})")


SCANNERS = {
    "erlang": erlang_findings,
    "elixir": elixir_findings,
    "go": go_findings,
    "rust": rust_findings,
    "node": node_findings,
    "php": php_findings,
    "python": python_findings,
    "csharp": csharp_findings,
}


# --------------------------------------------------------------------------
# A repository's own scanner config. Every scanner that reads one honours it
# silently, and more than one key there can drop a finding: an ignore list, a
# severity threshold, another advisory database, composer's ignore-severity.
# So the rule is an allow-list: what a config may carry is the set of keys that
# cannot hide anything, and every other key is refused by name.

# cargo audit's .cargo/audit.toml: [output] and [yanked] whole, and inside
# [advisories] only informational_warnings. Not ignore, not severity_threshold,
# not a [database] pointing at a fork with the entry removed, not [target].
CARGO_AUDIT_SECTIONS = {"output", "yanked", "advisories"}
CARGO_AUDIT_ADVISORIES_KEYS = {"informational_warnings"}

# composer audit's composer.json config.audit: what Composer 2.8 documents as
# not dropping a finding. Not ignore, not ignore-severity, not
# ignore-unreachable.
COMPOSER_AUDIT_KEYS = {"abandoned", "block-insecure", "block-abandoned"}

NPM_DEFAULT_REGISTRY = "https://registry.npmjs.org/"


def rust_ignores(cwd):
    """The .cargo/audit.toml cargo audit reads for this project, wherever cargo
    finds it: the working directory or, in a workspace, a parent of it."""
    for directory in to_repository_root(cwd):
        path = directory / ".cargo/audit.toml"
        if not path.exists():
            continue
        refused = unallowed_keys(toml_file(path), CARGO_AUDIT_SECTIONS,
                                 CARGO_AUDIT_ADVISORIES_KEYS)
        if refused:
            return (f"{path} carries {refused}; only [output], [yanked] and "
                    "[advisories] informational_warnings may be set, because every "
                    "other key can drop a finding with no date and no owner. A waiver "
                    "belongs in .github/advisories-waivers.txt")
    return None


def unallowed_keys(document, sections, advisories):
    """The keys of a scanner config that are not on the allow-list, named by
    their path in the file. A section whose value is not a table is refused
    rather than guessed at."""
    refused = []
    for key, value in document.items():
        if key not in sections:
            refused.append(key)
        elif key == "advisories" and is_table(value):
            refused += [f"advisories.{inner}" for inner in value
                        if inner not in advisories]
        elif key == "advisories":
            refused.append("advisories")
    return ", ".join(sorted(refused))


def is_table(value):
    return isinstance(value, dict)


def packagist_disabled(document):
    """composer.json {"repositories": [{"packagist.org": false}]} turns the one
    source of advisories off, leaving composer audit nothing to ask."""
    for repository in document.get("repositories") or []:
        if is_table(repository) and repository.get("packagist.org") is False:
            return True
    return False


def php_ignores(cwd):
    """composer audit honours composer.json "config": {"audit": {...}}: the keys
    Composer 2.6 and 2.8 add there can silence a package or a severity."""
    path = cwd / "composer.json"
    if not path.exists():
        return None
    document = load_json(path.read_text(errors="replace"), str(path))
    if packagist_disabled(document):
        return (f"{path} switches packagist.org off in \"repositories\", which leaves "
                "composer audit with no advisory source to ask; the audit would answer "
                "clean because nobody was asked")
    audit = (document.get("config") or {}).get("audit")
    if audit is None:
        return None
    if not is_table(audit):
        return f"{path} carries config.audit, which is not a table; it cannot be read"
    refused = sorted(key for key in audit if key not in COMPOSER_AUDIT_KEYS)
    if not refused:
        return None
    return (f"{path} carries {', '.join('config.audit.' + key for key in refused)}; "
            "only abandoned, block-insecure and block-abandoned may be set, because "
            "every other key can drop a finding with no date and no owner. A waiver "
            "belongs in .github/advisories-waivers.txt")


def npm_registry(cwd):
    """npm audit asks the registry a .npmrc names, and it audits the tree that
    .npmrc's install flags leave: omit=dev, production=true, only=prod and
    include= drop the dev tree this gate deliberately keeps in the scan. So a
    .npmrc is read against a short allow-list of keys that decide nothing about
    which packages exist or where they come from, and every other key is named
    and refused. audit-level is on the list on purpose: it moves the exit code,
    which is not read here, because the JSON is."""
    for directory in to_repository_root(cwd):
        path = directory / ".npmrc"
        if not path.exists():
            continue
        for number, line in enumerate(path.read_text(errors="replace").splitlines(), 1):
            line = line.split("#", 1)[0].strip()
            if not line or "=" not in line:
                continue
            key, _, value = line.partition("=")
            key, value = key.strip(), value.strip()
            if key == "registry" and value.rstrip("/") + "/" != NPM_DEFAULT_REGISTRY:
                return (f"{path}:{number} scans a registry other than "
                        f"{NPM_DEFAULT_REGISTRY} ({value}), so an advisory it has not "
                        "heard of would read as clean; remove the line or say why here")
            if key not in NPMRC_KEYS:
                return (f"{path}:{number} sets {key}, which is not on the allow-list of "
                        "keys that cannot change what is audited or where it comes from; "
                        "a committed .npmrc is refused rather than obeyed")
    return None


# What a committed .npmrc may set. Deliberately short, and every entry is here
# because it decides neither the dependency set nor the database that answers:
# npm reads production, omit, only and include to prune the install, a scoped
# @scope:registry to redirect a package's source, and audit-level only moves the
# exit code, which this gate does not read (it parses the JSON).
NPMRC_KEYS = {
    "registry",             # only the default value, checked above
    "audit-level",          # exit code only; the findings are parsed from JSON
    "engine-strict",
    "fund",
    "save-exact",
    "save-prefix",
    "legacy-peer-deps",
    "strict-ssl",
    "loglevel",
    "progress",
    "update-notifier",
    "color",
    "fetch-retries",
    "fetch-timeout",
    "prefer-offline",
    "prefer-online",
    "offline",
    "cache",
    "user-agent",
}


def to_repository_root(cwd):
    """The working directory and its parents, up to the repository root: a
    scanner that searches upward finds a config above the directory it was
    pointed at, and never one outside the repository."""
    directory = cwd
    while True:
        yield directory
        if (directory / ".git").exists() or directory.parent == directory:
            return
        directory = directory.parent


# Which ecosystems read a config file of their own, and the reader that refuses
# it. The rest read none: govulncheck and pip-audit take no config file, and
# osv-scanner reads an osv-scanner.toml only from the directory it is pointed
# at, which is the work directory and never the repository. dotnet list package
# --vulnerable does not consult NuGetAuditSuppress: that item filters the
# restore-time audit's warnings, and the listing command asks the sources for
# the resolved packages itself (NuGet.Client keeps the two apart).
IGNORE_CONFIGS = {
    "rust": rust_ignores,
    "php": php_ignores,
    "node": npm_registry,
}


def refuse_an_undated_ignore(ecosystem, cwd):
    reader = IGNORE_CONFIGS.get(ecosystem)
    if not reader:
        return
    refusal = reader(cwd)
    if refusal:
        raise CouldNotScan(refusal)


def toml_file(path):
    try:
        return tomllib.loads(path.read_text(errors="replace"))
    except tomllib.TOMLDecodeError as broken:
        raise CouldNotScan(f"{path} is not TOML: {broken}") from broken



def first_line(text):
    for line in (text or "").strip().splitlines():
        if line.strip():
            return line.strip()[:200]
    return ""


# --------------------------------------------------------------------------
# Waivers.


WAIVER_FIELDS = 5
# How far ahead a waiver may name a date. A row dated years out is a baseline
# with a date on it: nobody will look at it again before it is forgotten.
WAIVER_HORIZON_DAYS = 90


def parse_waivers(path, today):
    """Every waiver, by (advisory, package). A malformed or expired row is a
    failure to read, so a waiver is a decision somebody wrote down, dated and
    owns, never a line of noise."""
    if not path.exists():
        return {}
    waivers, problems = {}, []
    for number, raw in enumerate(path.read_text(errors="replace").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        waiver, problem = parse_waiver(line, today)
        if problem:
            problems.append(f"{path.name}:{number}: {problem}")
        else:
            waivers[(waiver.advisory, waiver.package)] = waiver
    if problems:
        raise CouldNotScan("; ".join(problems))
    return waivers


def parse_waiver(line, today):
    fields = [field.strip() for field in line.split("|")]
    if len(fields) != WAIVER_FIELDS:
        return None, (f"expected {WAIVER_FIELDS} fields "
                      "'advisory | package | why | owner | expires', got " + f"{len(fields)}")
    advisory = fields[0]
    package = fields[1]
    why = fields[2]
    owner = fields[3]
    if not advisory or not package:
        return None, "an advisory and a package are required"
    if not why or not owner:
        return None, f"{advisory} {package}: the why and the owner are required"
    try:
        expires = datetime.date.fromisoformat(fields[4])
    except ValueError:
        return None, f"{advisory} {package}: '{fields[4]}' is not a YYYY-MM-DD date"
    if expires < today:
        return None, (f"{advisory} {package}: the waiver expired on {expires}, "
                      "fix it or open a dated one that covers today")
    if expires > today + datetime.timedelta(days=WAIVER_HORIZON_DAYS):
        return None, (f"{advisory} {package}: {expires} is more than "
                      f"{WAIVER_HORIZON_DAYS} days away, so the waiver would outlive "
                      "any reason anyone can give for it today")
    return Waiver(advisory, package, why, owner, expires), None


def split_by_waiver(findings, waivers):
    waived, left = [], []
    for finding in findings:
        waiver = waivers.get((finding.advisory, finding.package))
        (waived if waiver else left).append((finding, waiver))
    return waived, left


# --------------------------------------------------------------------------
# Reporting.


def report(ecosystem, where, scanner, findings, waivers):
    waived, left = split_by_waiver(findings, waivers)
    print(f"dependency advisories: {ecosystem} in {where}, by {scanner}")
    print(f"{len(findings)} advisory finding(s), {len(waived)} waived, {len(left)} left")
    for finding, waiver in waived:
        print(f"  waived until {waiver.expires} ({waiver.owner}): {row(finding)}")
    for finding, _ in sorted(left, key=lambda pair: (pair[0].package, pair[0].advisory)):
        print(f"  ::error::{row(finding)}")
    return left, waived


def row(finding):
    parts = [finding.advisory, finding.package]
    if finding.version:
        parts[1] += f" {finding.version}"
    if finding.fixed:
        parts.append(f"fixed in {finding.fixed}")
    if finding.severity:
        parts.append(f"severity {finding.severity}")
    if finding.title:
        parts.append(finding.title)
    return " | ".join(parts)


# --------------------------------------------------------------------------
# Entry point.


def run_scan(ecosystem, cwd, work):
    """One row per advisory and package: govulncheck reports a finding once per
    call trace, which is more than a reader needs."""
    refuse_an_undated_ignore(ecosystem, cwd)
    found = SCANNERS[ecosystem](cwd, work)
    return list(dict.fromkeys(found))


def find_waivers(given, cwd):
    path = Path(given)
    return path if path.is_absolute() else cwd / path


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--ecosystem", required=True, choices=ECOSYSTEMS)
    parser.add_argument("--working-directory", default=".")
    parser.add_argument("--waivers", default=os.environ.get(
        "ADVISORIES_WAIVERS", ".github/advisories-waivers.txt"))
    parser.add_argument("--work", default=os.environ.get("RUNNER_TEMP", tempfile.gettempdir())
                        + "/dependency-advisories")
    parser.add_argument("--today", default=datetime.date.today().isoformat())
    args = parser.parse_args()
    return scan_and_report(args)


def scan_and_report(args):
    cwd = Path(args.working_directory).resolve()
    work = Path(args.work).resolve()
    if not cwd.is_dir():
        print(f"dependency_advisories could not run: {cwd} is not a directory",
              file=sys.stderr)
        return 2
    work.mkdir(parents=True, exist_ok=True)
    try:
        waivers = parse_waivers(find_waivers(args.waivers, cwd), parse_today(args.today))
        findings = run_scan(args.ecosystem, cwd, work)
    except (CouldNotScan, OSError) as problem:
        print(f"dependency_advisories could not run: {problem}", file=sys.stderr)
        return 2
    left, _ = report(args.ecosystem, args.working_directory, SCANNER[args.ecosystem],
                     findings, waivers)
    return 1 if left else 0


def parse_today(given):
    try:
        return datetime.date.fromisoformat(given)
    except ValueError as broken:
        raise CouldNotScan(f"--today '{given}' is not a YYYY-MM-DD date") from broken


if __name__ == "__main__":
    sys.exit(main())
