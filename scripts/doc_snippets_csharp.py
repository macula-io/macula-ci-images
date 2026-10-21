#!/usr/bin/env python3
"""Every C# code block a package publishes compiles against its own code.

Usage: doc_snippets_csharp.py ROOT

ROOT is a .NET repository and the package's project is somewhere in it: every
.csproj outside tests, examples, samples, benchmarks, fixtures, scripts and
tools. The docs read are the ones a package publishes: README*.md and
guides/**.md at any depth, and docs/**.md without design records, plans,
reports, backlogs or registers. The blocks read are the ones fenced csharp, cs,
c# or dotnet.

Each block becomes a file of one generated project that ProjectReferences the
package, so a block is compiled against the package's own source, not against
something already built or published. The project enables implicit usings and
nullable, what `dotnet new` writes, so a block is read as a reader's new
project would read it. A block that declares a type is a file and is compiled
as it stands; any other block is a fragment, whose statements become the body
of an async method of its own, in a class and a namespace of its own, so one
block never sees another's names. A #line directive carries each block's own
doc and line numbers into the compiler, so every error names the doc and the
line that is wrong.

What a fragment leaves to the reader is not an error: a name it uses and does
not declare (a realm, a caller the prose has made), a variable or a local
function it does not use, a name a block of alternatives binds twice, and a
return of a value where the wrapping method has none to return. Everything
about the package is: a type that is not there, a member (CS0117, CS1061), an
argument (CS1501), the syntax, and a capitalised name used as a type (Session,
where Pool is now) even when nothing declares it, because C# writes a value in
lowerCamelCase and a type in PascalCase. A misspelt local is a free name too,
so nothing catches it, and a method called on a name the block does not declare
cannot be checked: its type is not known.

A block that declares a type is wrapped in a namespace of its own, so two blocks
may declare the same name. A block written for one of those positions fails for a
reason the doc did not have: a file-scoped `namespace Foo;`, a `global using`, and
top-level statements beside a record are file-level in C# and are read inside
`namespace DocSnippetN { }` here. It fails closed rather than quietly, and the
block is written as a fragment or marked skip.

Markers, an HTML comment on the line before the fence:

  <!-- doc_snippets: skip <reason> -->   not checked; the reason is required

Exit 0 when every block compiles, 1 when any fails (path:line: message), 2 when
the check cannot run (no project, no TargetFramework, no dotnet, and anything
the compiler reports that is not inside a doc this check read: a package that
does not build is never a pass).
"""

import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

SKIP_DIRS = {".git", "node_modules", "bin", "obj", "artifacts", "packages", "_build",
             "deps", "target", "dist", ".venv"}
NOT_THE_PACKAGE = re.compile(
    r"(?:^|/)(?:tests?|examples?|samples?|benchmarks?|fixtures?|scripts?|tools?|docs?)/", re.I)
SHIPPED_DOCS = re.compile(
    r"^(?!(?:.*/)?(?:fixtures|testdata|vectors?)/)"
    r"(?!docs/(?:design|adr|adrs|decisions|plans?|reports?|research)/)"
    r"(?!docs/(?:.*/)?[^/]*(?:backlog|register)[^/]*$)"
    r"(?:(?:.*/)?README[^/]*\.md|(?:.*/)?guides/.+\.md|docs/.+\.md)$", re.I)
MARKER = re.compile(r"^\s*<!--\s*doc_snippets:\s*(\S+)\s*(.*?)\s*-->\s*$")
FENCE = re.compile(r"^(\s*)(`{3,}|~{3,})\s*([^`\s]*)")
LANGUAGES = {"csharp", "cs", "c#", "dotnet"}
USING = re.compile(r"^\s*(?:global\s+)?using\s+(?:static\s+)?[A-Za-z_][\w.]*"
                   r"(?:\s*=\s*[A-Za-z_][\w.]*)?\s*;\s*$")
# What only a file can hold: a type declaration, with any attributes and
# modifiers before it. A statement never starts this way.
TYPE_DECL = re.compile(
    r"^\s*(?:\[[^\]]*\]\s*)*"
    r"(?:(?:public|internal|private|protected|static|sealed|abstract|partial|readonly|"
    r"unsafe|file|ref)\s+)*"
    r"(?:class|record|struct|interface|enum|delegate)\s+[A-Za-z_@]")
ERROR = re.compile(r"^(?P<path>.+?)\((?P<line>\d+),(?P<col>\d+)\): error (?P<code>[A-Z]+\d+): "
                   r"(?P<msg>.*?)(?:\s+\[[^\]]*\])?$")
ANY_ERROR = re.compile(r": error [A-Z]+\d*: ")
MISSING_NAME = re.compile(r"The name '(?P<name>[^']+)' does not exist in the current context")
TARGET_FRAMEWORK = re.compile(r"<TargetFrameworks?>([^<]+)</TargetFrameworks?>")
NAMESPACE = re.compile(r"^\s*namespace\s+([A-Za-z_][\w.]*)", re.M)

# What only a fragment produces, by the error code the compiler gives it. A
# member of a type that is not there (CS0117, CS1061), an argument (CS1501) and
# a type that is not there (CS0246, CS0234) are never in here: those are the
# package's, and they are what this check exists to catch.
FRAGMENT_ONLY = {
    "CS0103",  # The name 'x' does not exist in the current context.
    "CS0128",  # A local variable named 'x' is already defined in this scope.
    "CS0136",  # A local named 'x' cannot be declared here, shadowing another.
    "CS0168",  # The variable 'x' is declared but never used.
    "CS0219",  # The variable 'x' is assigned but its value is never used.
    "CS1997",  # A return with a value, in a method that returns Task.
    "CS4016",  # A return of a value, in a method that returns Task.
    "CS8321",  # The local function 'x' is declared but never used.
}
# What a free value causes, and only that: a deconstruction whose right-hand
# side has a name the block left to the prose has no type to infer from.
FREE_VALUE_ONLY = {"CS8130"}


def docs(root):
    found = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = sorted(d for d in dirnames if d not in SKIP_DIRS
                             and not d.startswith("_doc_snippets"))
        for name in sorted(filenames):
            rel = os.path.relpath(os.path.join(dirpath, name), root).replace(os.sep, "/")
            if SHIPPED_DOCS.search(rel):
                found.append(rel)
    return found


def blocks(text):
    """Every fenced block: (fence line, language word, marker, [(line, text)])."""
    lines, out, i, previous = text.split("\n"), [], 0, None
    while i < len(lines):
        opened = FENCE.match(lines[i])
        if not opened:
            if lines[i].strip():
                previous = lines[i]
            i += 1
            continue
        indent, fence = len(opened.group(1)), opened.group(2)
        word = opened.group(3).strip("{}.").split(",")[0].lower()
        mark = MARKER.match(previous) if previous else None
        start, body, i = i + 1, [], i + 1
        while i < len(lines):
            close = lines[i].strip()
            if close.startswith(fence[0] * len(fence)) and not close.strip(fence[0]):
                break
            line = lines[i]
            body.append((i + 1, line[indent:] if line[:indent].strip() == "" else line))
            i += 1
        out.append((start, word, (mark.group(1), mark.group(2)) if mark else None, body))
        previous, i = None, i + 1
    return out


def code_lines(body):
    return [(n, t) for n, t in body if t.strip() and not t.strip().startswith("//")]


def split_usings(body):
    """The block's using directives, and the rest of it, both keeping the
    doc's own line numbers."""
    usings = [(n, t) for n, t in body if USING.match(t)]
    rest = [(n, t) for n, t in body if not USING.match(t)]
    return usings, rest


def kind_of(code):
    return "decls" if any(TYPE_DECL.match(t) for _, t in code) else "statements"


def quoted(path):
    return path.replace("\\", "\\\\").replace('"', '\\"')


def snippet_file(index, doc, usings, rest, kind):
    """The file a block becomes, its #line directives carrying the doc and the
    block's own line numbers into every diagnostic. `usings` is every using the
    block is read with, each with the doc line it came from: the doc's earlier
    usings are carried in, as a reader who came that far down the page has them."""
    out = [f"// doc snippet {index}\n", f"namespace DocSnippet{index}\n{{\n"]
    for number, text in usings:
        out += [f'#line {number} "{quoted(doc)}"\n', text + "\n"]
    if kind == "statements":
        out += ["static class __Snippet\n{\n", "static async Task Run()\n{\n"]
    if rest:
        out.append(f'#line {rest[0][0]} "{quoted(doc)}"\n')
        out += [t + "\n" for _, t in rest]
    out.append("#line default\n")
    if kind == "statements":
        out.append("}\n}\n")
    out.append("}\n")
    return "".join(out)


def package_projects(root):
    """The projects that are the package: every .csproj that is not a test, an
    example, a sample, a benchmark, a fixture, a script or a tool."""
    found = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = sorted(d for d in dirnames if d not in SKIP_DIRS
                             and not d.startswith("_doc_snippets"))
        for name in sorted(filenames):
            if not name.endswith(".csproj"):
                continue
            rel = os.path.relpath(os.path.join(dirpath, name), root).replace(os.sep, "/")
            if not NOT_THE_PACKAGE.search(rel):
                found.append(os.path.join(dirpath, name))
    return found


def target_framework(root, projects):
    """The first framework the package targets, singular or plural: of a
    multi-targeted package's list, the first is the one a reader takes. It is
    read from the project, then from each Directory.Build.props above it, where
    a repository that shares one setting puts it."""
    for project in projects:
        for candidate in property_files(root, project):
            found = TARGET_FRAMEWORK.search(Path(candidate).read_text(errors="replace"))
            if found:
                return first_net(found.group(1).split(";"))
    return None


def first_net(frameworks):
    """The first framework a generated project can be built for. A package that
    also targets netstandard2.0 must not hand C# 7.3 to a block written for the
    modern language, since implicit usings and nullable need more than that."""
    named = [framework.strip() for framework in frameworks if framework.strip()]
    for framework in named:
        if re.match(r"^net\d", framework):
            return framework
    return named[0] if named else None


def property_files(root, project):
    """The project file, then every Directory.Build.props between it and the
    repository root."""
    yield project
    current = Path(project).parent
    root = Path(root)
    while True:
        props = current / "Directory.Build.props"
        if props.is_file():
            yield str(props)
        if current == root or root not in current.parents:
            return
        current = current.parent


def namespaces_of(projects):
    """The package's own namespaces, so a name a block uses as one and that it
    does not have is reported as the package's gap rather than as the prose's."""
    names = set()
    for project in projects:
        for source in Path(project).parent.rglob("*.cs"):
            if any(part in SKIP_DIRS for part in source.parts):
                continue
            for found in NAMESPACE.finditer(source.read_text(errors="replace")):
                names.add(found.group(1))
    return names


def project_file(references, framework):
    refs = "".join(f'    <ProjectReference Include="{quoted(os.path.abspath(r))}" />\n'
                   for r in references)
    return (
        '<Project Sdk="Microsoft.NET.Sdk">\n'
        "  <PropertyGroup>\n"
        f"    <TargetFramework>{framework}</TargetFramework>\n"
        "    <OutputType>Library</OutputType>\n"
        "    <ImplicitUsings>enable</ImplicitUsings>\n"
        "    <Nullable>enable</Nullable>\n"
        "    <EnableDefaultCompileItems>false</EnableDefaultCompileItems>\n"
        "    <TreatWarningsAsErrors>false</TreatWarningsAsErrors>\n"
        "    <NoWarn>$(NoWarn);CS0162;CS0164;CS0649;CS1591</NoWarn>\n"
        "  </PropertyGroup>\n"
        "  <ItemGroup>\n"
        '    <Compile Include="snippets/*.cs" />\n'
        f"{refs}"
        "  </ItemGroup>\n"
        "</Project>\n")


def relative(root, path):
    """The doc path a diagnostic names, made relative to the repository."""
    resolved = os.path.realpath(path)
    base = os.path.realpath(root)
    if resolved == base:
        return "."
    if resolved.startswith(base + os.sep):
        return os.path.relpath(resolved, base).replace(os.sep, "/")
    return path


_DOC_LINES = {}


def doc_line(root, doc, number):
    if doc not in _DOC_LINES:
        _DOC_LINES[doc] = (root / doc).read_text(errors="replace").split("\n")
    lines = _DOC_LINES[doc]
    return lines[number - 1] if 0 < number <= len(lines) else ""


def selects(root, doc, number, name):
    """Does the doc's own line use `name` as a type (name.Member)? A value that
    happens to share a type's name is not one, and a capitalised name used that
    way is a type the docs expected, so the package must have it."""
    return re.search(rf"(?<![\w.]){re.escape(name)}\s*\.", doc_line(root, doc, number)) is not None


def excuse(root, doc, line, code, message, kind, package_namespaces):
    """Whether a diagnostic is what only a fragment produces. A block that
    declares a type is the reader's own code, complete as far as it goes, and is
    held to the compiler entirely."""
    if kind != "statements" or code not in FRAGMENT_ONLY:
        return False
    missing = MISSING_NAME.search(message)
    if not missing:
        return True
    name = missing.group("name")
    as_type = (name[:1].isupper() or name in package_namespaces) and selects(root, doc, line, name)
    return not as_type


def main(argv):
    if len(argv) != 2:
        print("usage: doc_snippets_csharp.py ROOT", file=sys.stderr)
        return 2
    root = Path(argv[1]).resolve()
    references = package_projects(root)
    if not references:
        print(f"doc_snippets: no project to compile against in {root}", file=sys.stderr)
        return 2
    framework = target_framework(root, references)
    if framework is None:
        print("doc_snippets: no TargetFramework in the package's projects", file=sys.stderr)
        return 2
    if not shutil.which("dotnet"):
        print("doc_snippets: no dotnet on the PATH", file=sys.stderr)
        return 2

    package_namespaces = namespaces_of(references)
    failures, written, read = [], [], set(docs(root))
    work = root / f"_doc_snippets_{os.getpid()}"
    build = None
    try:
        (work / "snippets").mkdir(parents=True)
        for doc in sorted(read):
            carried = []
            for start, word, marker, body in blocks((root / doc).read_text(errors="replace")):
                if word not in LANGUAGES:
                    continue
                if marker and marker[0] == "skip":
                    if not marker[1]:
                        failures.append((doc, start, "skip gives no reason"))
                    continue
                if marker:
                    failures.append((doc, start, f"unknown marker '{marker[0]}'"))
                    continue
                own, rest = split_usings(body)
                # Only a block this check reads carries its usings on: a block in
                # another language, or one skipped as a counter-example, lends
                # nothing to the page below it. A block that is nothing but
                # usings carries them too, and has nothing of its own to compile:
                # "Add the namespace:" followed by a using alone is a shape a
                # README writes, and the block after it uses the alias.
                seen = {text for _, text in carried}
                for number, text in own:
                    if text not in seen:
                        carried.append((number, text))
                        seen.add(text)
                code = code_lines(rest)
                if not code:
                    continue
                index = len(written)
                (work / "snippets" / f"s{index}.cs").write_text(
                    snippet_file(index, str(root / doc), carried, rest, kind_of(code)))
                written.append((doc, start, kind_of(code)))
        if written:
            (work / "snippets.csproj").write_text(project_file(references, framework))
            build = subprocess.run(
                ["dotnet", "build", str(work / "snippets.csproj"), "--nologo", "-v", "quiet"],
                cwd=root, capture_output=True, text=True)
    finally:
        shutil.rmtree(work, ignore_errors=True)

    if build is not None:
        outside, found = [], []
        output = (build.stdout + "\n" + build.stderr).splitlines()
        for line in output:
            stripped = line.strip()
            error = ERROR.match(stripped)
            if error:
                doc = relative(root, error.group("path"))
                if doc in read:
                    found.append((doc, int(error.group("line")), error.group("code"),
                                  error.group("msg")))
                    continue
                outside.append(stripped)
            elif ANY_ERROR.search(stripped):
                outside.append(stripped)
        if outside:
            shown = "\n  ".join(outside[:10])
            print(f"doc_snippets: the compiler failed outside the docs read, so nothing "
                  f"here can be trusted:\n  {shown}", file=sys.stderr)
            for path, line, message in sorted(set(failures)):
                print(f"{path}:{line}: {message}")
            return 2
        # A build that fails without a diagnostic this check can place is not a
        # pass: a missing SDK prints "A compatible .NET SDK was not found", which
        # has no path and no line, and a repository that pins an SDK the runner
        # does not have is common.
        if build.returncode != 0 and not found:
            shown = "\n  ".join(line.strip() for line in output if line.strip())[-2000:]
            print(f"doc_snippets: dotnet failed (exit {build.returncode}) without naming a "
                  f"block, so nothing here can be trusted:\n  {shown}", file=sys.stderr)
            for path, line, message in sorted(set(failures)):
                print(f"{path}:{line}: {message}")
            return 2
        free, kept = set(), []
        for doc, line, code, message in found:
            block = written_block(written, doc, line)
            if excuse(root, doc, line, code, message, block[1], package_namespaces):
                free.add((doc, block[0]))
                continue
            kept.append((doc, line, code, message, block))
        for doc, line, code, message, block in kept:
            # A consequence of a free name, in the block that left the name out.
            if code in FREE_VALUE_ONLY and (doc, block[0]) in free:
                continue
            failures.append((doc, line, message))

    for path, line, message in sorted(set(failures)):
        print(f"{path}:{line}: {message}")
    print(f"doc_snippets: {len(set(failures))} failure(s) in {len(written)} block(s)",
          file=sys.stderr)
    return 1 if failures else 0


def written_block(written, doc, line):
    """The block a diagnostic falls in: the last one of that doc whose fence
    opens at or before the line, as (its fence line, its kind)."""
    block = (0, "statements")
    for entry_doc, start, entry_kind in written:
        if entry_doc == doc and start <= line:
            block = (start, entry_kind)
    return block


if __name__ == "__main__":
    sys.exit(main(sys.argv))
