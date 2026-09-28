#!/usr/bin/env python3
"""Does reproducibility.yml build exactly the images build.yml publishes?

The reproducibility check proves a manifest digest, and the image name is in
that digest (image_labels.sh makes it the title label). So both workflows must
build the same (image, Containerfile) pairs and the same rocksdb targets. A
pair named differently in one of them proves a config that is never published:
the ex118 image was published as macula-ci-pq and checked as
macula-ci-pq-ex118 until this check existed.

Exit 0 when both matrices agree; otherwise name every pair that is only in one
of them and exit 1.

Usage: scripts/check_workflow_matrices_agree.py [build.yml] [reproducibility.yml]
"""
import sys

import yaml


def pairs(workflow, job):
    return {(e["image"], e["file"]) for e in workflow["jobs"][job]["strategy"]["matrix"]["include"]}


def targets(workflow, job):
    return set(workflow["jobs"][job]["strategy"]["matrix"]["target"])


def main():
    build_path = sys.argv[1] if len(sys.argv) > 1 else ".github/workflows/build.yml"
    repro_path = sys.argv[2] if len(sys.argv) > 2 else ".github/workflows/reproducibility.yml"
    build = yaml.safe_load(open(build_path))
    repro = yaml.safe_load(open(repro_path))
    problems = []
    for label, published, checked in (
        ("image", pairs(build, "build"), pairs(repro, "twice")),
        ("rocksdb target", targets(build, "rocksdb"), targets(repro, "twice-rocksdb")),
    ):
        for item in sorted(published - checked):
            problems.append(f"{label} {item} is published by build.yml but not checked by reproducibility.yml")
        for item in sorted(checked - published):
            problems.append(f"{label} {item} is checked by reproducibility.yml but not published by build.yml")
    if problems:
        print("REFUSED: the reproducibility check does not build what build.yml publishes")
        for p in problems:
            print(f"  {p}")
        sys.exit(1)
    print("OK: reproducibility.yml builds exactly the images build.yml publishes")


if __name__ == "__main__":
    main()
