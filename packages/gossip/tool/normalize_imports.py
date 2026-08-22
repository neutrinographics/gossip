#!/usr/bin/env python3
"""Normalize intra-package import/export directives for packages/gossip.

Part of the bounded-contexts restructure (docs/superpowers/specs/
2026-08-21-bounded-contexts-restructure-design.md). Two modes:

    python3 tool/normalize_imports.py normalize
    python3 tool/normalize_imports.py rewrite <mapping.json>

`normalize` walks lib/ and test/ for *.dart files. For every import/export
directive whose quoted target is a RELATIVE path (i.e. not already
`dart:...` or `package:...`), it resolves that target on disk relative to
the importing file's directory. If the resolved file lives under lib/src/,
the quoted path is rewritten to the absolute `package:gossip/src/...` form.
Relative references that resolve OUTSIDE lib/src/ (e.g. test helpers
importing sibling test helpers, which have no package: URI since test/ is
not served by the package: scheme) are left untouched.

This makes every subsequent file move a pure string substitution: once all
intra-package edges are spelled as `package:gossip/src/...`, moving a file
is `git mv` plus a mapping-driven find/replace of its old absolute path for
its new one, with zero relative-path arithmetic.

`rewrite` takes a JSON object mapping OLD package-relative paths (the part
after `package:gossip/`) to NEW ones, e.g.

    {"src/domain/value_objects/node_id.dart":
     "src/shared/domain/value_objects/node_id.dart"}

and replaces `package:gossip/<old>` with `package:gossip/<new>` wherever an
import/export directive's quoted URI matches an OLD key exactly (whole-URI
match, not substring), across lib/ and test/. Intended to run immediately
after the corresponding `git mv`s.

Both modes are idempotent: a second run makes no further changes.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

PACKAGE_NAME = "gossip"

# Matches the start of an import/export directive and captures the quoted
# target. Deliberately does not require a trailing `;` on the same line --
# `show`/`hide` combinators may wrap to a following line -- so only the
# quoted URI itself is touched.
DIRECTIVE_RE = re.compile(r"^(import|export)(\s+)'([^']+)'")


def iter_dart_files(root: Path):
    for base in ("lib", "test"):
        directory = root / base
        if not directory.exists():
            continue
        yield from sorted(directory.rglob("*.dart"))


def _rewrite_file(path: Path, transform) -> bool:
    """Apply `transform(target) -> new_target | None` to every directive's
    quoted URI in `path`. Returns True if the file was changed."""
    original = path.read_text()
    lines = original.splitlines(keepends=True)
    changed = False
    out = []
    for line in lines:
        match = DIRECTIVE_RE.match(line)
        if not match:
            out.append(line)
            continue
        target = match.group(3)
        new_target = transform(target)
        if new_target is None or new_target == target:
            out.append(line)
            continue
        start, end = match.span(3)
        out.append(line[:start] + new_target + line[end:])
        changed = True
    if changed:
        path.write_text("".join(out))
    return changed


def normalize(root: Path) -> int:
    lib_dir = (root / "lib").resolve()
    src_dir = (lib_dir / "src").resolve()

    changed_files = 0
    for path in iter_dart_files(root):

        def transform(target: str, path=path) -> str | None:
            if target.startswith("dart:") or target.startswith("package:"):
                return None
            resolved = (path.parent / target).resolve()
            try:
                rel_to_src = resolved.relative_to(src_dir)
            except ValueError:
                return None  # not under lib/src -- leave relative
            rel_to_lib = Path("src") / rel_to_src
            return f"package:{PACKAGE_NAME}/{rel_to_lib.as_posix()}"

        if _rewrite_file(path, transform):
            changed_files += 1
    return changed_files


def rewrite(root: Path, mapping_path: Path) -> int:
    mapping: dict[str, str] = json.loads(mapping_path.read_text())
    prefix = f"package:{PACKAGE_NAME}/"

    changed_files = 0
    for path in iter_dart_files(root):

        def transform(target: str) -> str | None:
            if not target.startswith(prefix):
                return None
            suffix = target[len(prefix) :]
            if suffix not in mapping:
                return None
            return prefix + mapping[suffix]

        if _rewrite_file(path, transform):
            changed_files += 1
    return changed_files


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(__doc__)
        return 1

    mode = argv[1]
    root = Path(__file__).resolve().parent.parent

    if mode == "normalize":
        changed = normalize(root)
        print(f"normalize: rewrote {changed} file(s)")
        return 0

    if mode == "rewrite":
        if len(argv) < 3:
            print("usage: normalize_imports.py rewrite <mapping.json>")
            return 1
        changed = rewrite(root, Path(argv[2]))
        print(f"rewrite: rewrote {changed} file(s)")
        return 0

    print(f"unknown mode: {mode!r} (expected 'normalize' or 'rewrite')")
    return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
