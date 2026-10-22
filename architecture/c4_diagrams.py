"""Generate macula-ci-images' two C4 diagrams into assets/.

Run:  python3 architecture/c4_diagrams.py

  c4-context.svg     Level 1: the repository, who uses it and what it talks to
  c4-components.svg  Level 3: the image pipeline, the base images and the
                     shared gates (reusable workflows) it is made of

Every element is read from this repository: the Containerfile.* files,
.github/workflows/ and scripts/. The drawing helpers, colours and legend are
mcl-fovea's (macula-services/mcl-fovea, architecture/c4_diagrams.py), so the
diagrams read the same across repositories.

Colours are plain classes with a prefers-color-scheme: dark block, no CSS
custom properties (rsvg-convert renders those black). After a change, render
each (rsvg-convert -w 1400 assets/c4-context.svg -o /tmp/c.png) and look at
it; keep architecture/README.md's tables in step.
"""
import os
from xml.sax.saxutils import escape

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "assets")

SANS = '"Atkinson Hyperlegible", "Segoe UI", system-ui, -apple-system, Helvetica, Arial, sans-serif'
MONO = '"JetBrains Mono", ui-monospace, Menlo, Consolas, monospace'

# Element kinds, each (light fill, light stroke, dark fill, dark stroke).
KINDS = {
    "b-sys": ("#F5E9CC", "#A56F0A", "#3A2E13", "#E3AA3C"),   # in scope
    "b-per": ("#E3EBF2", "#3B5B7A", "#1D2A36", "#8EB4D8"),   # person
    "b-mac": ("#E6E4EE", "#5E5A78", "#26243A", "#A9A4C8"),   # Macula infrastructure
    "b-ext": ("#ECEFED", "#8A9791", "#1C2421", "#7D8B85"),   # external system
    "b-cmp": ("#FFFFFF", "#8A9791", "#171F1C", "#7D8B85"),   # component or container
}

STYLE = f"""<style>
.t-name {{ font-family: {SANS}; font-size: 15px; font-weight: 700; }}
.t-desc {{ font-family: {SANS}; font-size: 12.5px; }}
.t-rel {{ font-family: {SANS}; font-size: 11.5px; paint-order: stroke; stroke-width: 4px; stroke-linejoin: round; }}
.t-code {{ font-family: {MONO}; font-size: 13px; font-weight: 600; }}
.t-type {{ font-family: {MONO}; font-size: 11.5px; }}
.t-bound {{ font-family: {MONO}; font-size: 12px; font-weight: 600; }}
.t-leg {{ font-family: {SANS}; font-size: 12px; }}
.edge {{ fill: none; stroke-width: 1.25; }}
.edge-later {{ fill: none; stroke-width: 1.25; stroke-dasharray: 5 4; }}
.bg {{ fill: #FFFFFF; }}
""" + "".join(f".{k} {{ fill: {v[0]}; stroke: {v[1]}; stroke-width: {2 if k == 'b-sys' else 1.25}; }}\n" for k, v in KINDS.items()) + """\
.b-later { fill: none; stroke: #8A9791; stroke-width: 1.25; stroke-dasharray: 5 4; }
.bound { fill: none; stroke: #B3BDB8; stroke-width: 1; }
.head { fill: #3B5B7A; }
.t-name, .t-code { fill: #16201D; }
.t-type, .t-bound, .t-leg { fill: #66736E; }
.t-desc { fill: #34413C; }
.t-rel { fill: #66736E; stroke: #FFFFFF; }
.edge, .edge-later { stroke: #8A9791; }
.arrowhead { fill: #8A9791; }
@media (prefers-color-scheme: dark) {
.bg { fill: #171F1C; }
""" + "".join(f".{k} {{ fill: {v[2]}; stroke: {v[3]}; }}\n" for k, v in KINDS.items()) + """\
.b-later { stroke: #7D8B85; }
.bound { stroke: #4A5752; }
.head { fill: #8EB4D8; }
.t-name, .t-code { fill: #E6ECE9; }
.t-type, .t-bound, .t-leg { fill: #93A09A; }
.t-desc { fill: #C3CDC8; }
.t-rel { fill: #93A09A; stroke: #171F1C; }
.edge, .edge-later { stroke: #7D8B85; }
.arrowhead { fill: #7D8B85; }
}
</style>"""

DEFS = ('<defs><marker id="a" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" '
        'orient="auto-start-reverse"><path class="arrowhead" d="M0 0L10 5L0 10z"/></marker></defs>')

LEGEND = [("b-sys", "In scope"), ("b-per", "Person"), ("b-mac", "Macula infrastructure"),
          ("b-ext", "External system"), ("b-cmp", "Container or component"), ("b-later", "Planned, not built")]
BOUNDARY = ("bound", "Boundary")


class Diagram:
    def __init__(self, name, title, w, h):
        self.name, self.title, self.w, self.h, self.parts = name, title, w, h, []

    def text(self, cls, x, y, s, anchor=None, rotate=None):
        a = f' text-anchor="{anchor}"' if anchor else ""
        r = f' transform="rotate({rotate} {x} {y})"' if rotate is not None else ""
        self.parts.append(f'<text class="{cls}" x="{x}" y="{y}"{a}{r}>{escape(s)}</text>')

    def box(self, cls, x, y, w, h, name, kind, desc, person=False, code=False):
        self.parts.append(f'<rect class="{cls}" x="{x}" y="{y}" width="{w}" height="{h}" rx="10"/>')
        tx = x + 16
        if person:
            self.parts.append(f'<circle class="head" cx="{x + 26}" cy="{y + 24}" r="9"/>')
            tx = x + 44
        self.text("t-code" if code else "t-name", tx, y + 28, name)
        self.text("t-type", tx, y + 46, kind)
        for i, line in enumerate(desc):
            self.text("t-desc", x + 16, y + 70 + 16 * i, line)

    def bound(self, x, y, w, h, label):
        self.parts.append(f'<rect class="bound" x="{x}" y="{y}" width="{w}" height="{h}" rx="12"/>')
        self.text("t-bound", x + 16, y + 22, label)

    def edge(self, d, later=False):
        self.parts.append(f'<path class="{"edge-later" if later else "edge"}" d="{d}" marker-end="url(#a)"/>')

    def legend(self, y, boundary=True):
        x = 24
        for cls, label in LEGEND + ([BOUNDARY] if boundary else []):
            self.parts.append(f'<rect class="{cls}" x="{x}" y="{y}" width="22" height="14" rx="3"/>')
            self.text("t-leg", x + 30, y + 12, label)
            x += 34 + 6.6 * len(label)

    def write(self):
        svg = [(f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {self.w} {self.h}" role="img" '
                f'aria-label="{escape(self.title)}">'), f"<title>{escape(self.title)}</title>", STYLE, DEFS,
               f'<rect class="bg" x="0" y="0" width="{self.w}" height="{self.h}"/>'] + self.parts + ["</svg>", ""]
        with open(os.path.join(OUT, self.name), "w") as f:
            f.write("\n".join(svg))


def context():
    d = Diagram("c4-context.svg", "macula-ci-images system context", 1000, 810)
    d.box("b-ext", 40, 30, 270, 96, "Upstream releases", "[External systems]",
          ["rebar3, hex, Elixir, Gleam, rustup,", "erlang-rocksdb; the Rust toolchain"])
    d.box("b-per", 365, 30, 270, 96, "Macula maintainers", "[Person]",
          ["Edit the Containerfiles and gates;", "pin calls to them in their repos"], person=True)
    d.box("b-ext", 690, 30, 270, 96, "macula-codebase-checks", "[External: ours, the sweep]",
          ["Files an issue in a repository", "that does not call a shared gate"])
    d.box("b-ext", 40, 190, 270, 130, "Docker Hub", "[External system]",
          ["hexpm/erlang, hexpm/elixir, debian:", "the newest dated base for each", "pinned toolchain, taken by digest"])
    d.box("b-sys", 365, 190, 270, 130, "macula-ci-images", "[GitHub repository, public]",
          ["Builds the CI and runtime base", "images every day; hosts the shared", "gates other repositories call"])
    d.box("b-ext", 690, 190, 270, 130, "Macula repositories' CI", "[External: ours]",
          ["Services, stations, SDKs: build in", "these images, run on the runtime", "one, call the gates by full sha"])
    d.box("b-ext", 40, 400, 270, 120, "Advisory sources", "[External systems]",
          ["OSV, the Go vulnerability DB,", "RustSec, npm, Packagist, PyPI,", "NuGet"])
    d.box("b-ext", 365, 400, 270, 120, "Sigstore", "[External system]",
          ["Fulcio certificates for a GitHub", "OIDC identity; the public Rekor", "log of every signature"])
    d.box("b-ext", 690, 400, 270, 120, "ghcr.io", "[External: container registry]",
          ["The base images (ghcr.io/macula-io),", ":latest and :YYYYMMDD-HHmm, and", "the images callers build on them"])
    d.box("b-mac", 690, 600, 270, 120, "Macula fleet boxes", "[Macula infrastructure]",
          ["Run images on macula-pq-runtime;", "the reconciler verifies signature,", "SBOM and provenance first"])
    d.edge("M400 190V160H175V126"); d.text("t-rel", 190, 152, "downloads, checksum-pinned")
    d.edge("M500 126V190"); d.text("t-rel", 508, 162, "edit")
    d.edge("M600 126V150H760V190"); d.text("t-rel", 680, 142, "pin the gates", anchor="middle")
    d.edge("M900 126V190"); d.text("t-rel", 892, 162, "reads workflows,", anchor="end")
    d.text("t-rel", 892, 178, "files issues", anchor="end")
    d.edge("M365 255H310"); d.text("t-rel", 337, 245, "base,", anchor="middle"); d.text("t-rel", 337, 277, "by digest", anchor="middle")
    d.edge("M690 255H635"); d.text("t-rel", 662, 245, "calls,", anchor="middle"); d.text("t-rel", 662, 277, "by sha", anchor="middle")
    d.edge("M380 320V360H175V400"); d.text("t-rel", 190, 352, "scans advisories")
    d.edge("M500 320V400"); d.text("t-rel", 508, 368, "signs, attests")
    d.text("t-rel", 508, 384, "(keyless)")
    d.edge("M620 320V360H760V400"); d.text("t-rel", 690, 352, "pushes images", anchor="middle")
    d.edge("M900 320V400"); d.text("t-rel", 908, 362, "FROM by"); d.text("t-rel", 908, 378, "digest; push")
    d.edge("M825 600V520"); d.text("t-rel", 833, 566, "pulls by digest")
    d.edge("M690 660H500V520"); d.text("t-rel", 595, 652, "verifies signatures", anchor="middle")
    d.text("t-desc", 40, 600, "The gates are reusable workflows: they run in")
    d.text("t-desc", 40, 616, "the CALLER's repository and job, so the scans")
    d.text("t-desc", 40, 632, "and signatures they make are made there, in")
    d.text("t-desc", 40, 648, "the caller's name, by this repository's code.")
    d.legend(770, boundary=False)
    d.write()


def components():
    d = Diagram("c4-components.svg", "macula-ci-images components", 1000, 960)
    d.bound(16, 40, 684, 866, "macula-ci-images [GitHub repository]")
    d.box("b-cmp", 32, 70, 208, 130, "reproducibility", "[reproducibility.yml]",
          ["Sundays and on change: two", "uncached builds, the same", "manifest digest or red"], code=True)
    d.box("b-sys", 254, 70, 430, 130, "build.yml", "[workflow: daily, weekly uncached, push]",
          ["pinned-downloads: every download checksum-", "pinned (check_pinned_downloads.py), first.",
           "build: newest_dated_base.py picks the base by", "digest; image_labels.sh; push. rocksdb: after."], code=True)
    d.bound(24, 220, 668, 256, "Base images [Containerfile.*, pushed to ghcr.io/macula-io]")
    d.box("b-cmp", 32, 254, 208, 92, "macula-ci-pq", "[Containerfile.ci-pq]",
          ["mix: Elixir 1.19.6, OTP", "28.4.3, Rust 1.98.1"], code=True)
    d.box("b-cmp", 254, 254, 208, 92, "ci-pq ex118-*", "[Containerfile.ci-pq-ex118]",
          ["Elixir 1.18.4 on OTP 28.4.3,", "for mix releases on 1.18"], code=True)
    d.box("b-cmp", 476, 254, 208, 92, "macula-ci-otp", "[Containerfile.ci-otp]",
          ["rebar3 3.27.0, OTP 28.4.3,", "Rust 1.98.1"], code=True)
    d.box("b-cmp", 32, 370, 208, 92, "macula-ci-gleam", "[Containerfile.ci-gleam]",
          ["gleam118-*: Gleam 1.18.1", "on OTP 28.4.3"], code=True)
    d.box("b-cmp", 254, 370, 208, 92, "macula-pq-runtime", "[Containerfile.pq-runtime]",
          ["Debian trixie, OpenSSL 3.5+:", "a release's runtime stage"], code=True)
    d.box("b-cmp", 476, 370, 208, 92, "*-rocksdb (three)", "[Containerfile.rocksdb]",
          ["ci-otp, pq-runtime, ci-pq-ex118", "plus librocksdb 11.1.2"], code=True)
    d.bound(24, 496, 668, 290, "Shared gates [reusable workflows, called pinned by full commit sha]")
    d.box("b-cmp", 254, 530, 208, 112, "release-guard", "[release-guard.yml]",
          ["A v* tag: on the default", "branch, and the version the", "repository publishes"], code=True)
    d.box("b-cmp", 476, 530, 208, 112, "attest-image", "[attest-image.yml]",
          ["Runs the guard, then keyless", "cosign: signature, SPDX SBOM,", "SLSA provenance, by digest"], code=True)
    d.box("b-cmp", 32, 530, 208, 112, "dependency-advisories", "[dependency-advisories.yml]",
          ["Eight ecosystems: a known", "advisory fails the run, or a", "dated waiver in the repo"], code=True)
    d.box("b-cmp", 32, 656, 208, 112, "doc-snippets-*", "[six workflows]",
          ["Erlang, Go, Python, TS, C#,", "PHP: published code blocks", "compile and run"], code=True)
    d.box("b-cmp", 254, 656, 208, 112, "c4-model", "[c4-model.yml]",
          ["A context and a component", "diagram in assets/, shown by", "a README"], code=True)
    d.box("b-cmp", 476, 656, 208, 112, "Self-tests", "[*-selftest.yml]",
          ["Each check is a script in", "scripts/, embedded in its", "workflow, tested as embedded"])
    d.box("b-cmp", 32, 800, 652, 92, "scripts/ci_gate.sh", "[local tool]",
          ["Runs a job's run steps on a commit, inside the job's own pinned image, as root, as CI runs them."], code=True)
    d.box("b-ext", 760, 70, 224, 96, "Docker Hub", "[External system]",
          ["hexpm and debian bases"])
    d.box("b-ext", 760, 176, 224, 96, "ghcr.io/macula-io", "[External: registry]",
          ["The published base images"])
    d.box("b-ext", 760, 300, 224, 110, "Upstream releases", "[External systems]",
          ["rebar3, hex, Elixir, Gleam,", "rustup, erlang-rocksdb"])
    d.box("b-ext", 760, 530, 224, 112, "Sigstore", "[External system]",
          ["Fulcio, and the public", "Rekor log"])
    d.box("b-ext", 760, 656, 224, 112, "Macula repositories' CI", "[External: ours]",
          ["Call the gates; the gates", "run in the caller's job"])
    d.edge("M684 110H760"); d.text("t-rel", 722, 100, "base,", anchor="middle"); d.text("t-rel", 722, 128, "by digest", anchor="middle")
    d.edge("M684 188H760"); d.text("t-rel", 722, 180, "pushes", anchor="middle")
    d.edge("M136 200V220"); d.text("t-rel", 144, 214, "rebuilds")
    d.edge("M470 200V220"); d.text("t-rel", 478, 214, "builds, pushes")
    d.edge("M580 346V370"); d.text("t-rel", 588, 362, "FROM by digest")
    d.edge("M692 355H760"); d.text("t-rel", 726, 345, "downloads,", anchor="middle"); d.text("t-rel", 726, 373, "checked", anchor="middle")
    d.edge("M476 586H462")
    d.edge("M684 586H760"); d.text("t-rel", 730, 576, "signs", anchor="middle")
    d.edge("M760 712H692"); d.text("t-rel", 726, 702, "call by", anchor="middle"); d.text("t-rel", 726, 730, "full sha", anchor="middle")
    d.legend(930)
    d.write()


if __name__ == "__main__":
    for make in (context, components):
        make()
