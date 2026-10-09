#!/usr/bin/env python3
"""The icons taken over from Gregtorio 0.1.9 (issue #238): their hashes and the guard against them.

Until 0.5.2, 17 files of graphics/icons/ were byte-identical to the original Gregtorio 0.1.9 (Gregtorio Continued's tag
v0.1.9-upstream) and looked like the art of Applied Energistics 2. Issue #238 replaced them by icons drawn with
tools/gen_ae2_sprites.py --own-icons. tools/upstream-icon-hashes.tsv keeps their SHA-256 (tab-separated, header in the
first line):

    file     the path the file had in this repository
    sha256   SHA-256 of its bytes
    source   where it came from (v0.1.9-upstream)

check_tree() is the guard that `devcheck.py check` runs: no file under graphics/ and not thumbnail.png may have one of
these hashes (with --with-gregtorio no file of that checkout either).
"""
import re
from pathlib import Path

from ae2_manifest import identical_files, sha256, tree_files      # (the same file walk as the guard of graphics/ae2/)

ROOT = Path(__file__).resolve().parent.parent
LIST = "tools/upstream-icon-hashes.tsv"
COLUMNS = ("file", "sha256", "source")


def read_list(root=ROOT):
    """({sha256: row}, problems)"""
    p = Path(root) / LIST
    if not p.is_file():
        return {}, [f"{LIST} is missing"]
    lines = p.read_text(encoding="utf-8").splitlines()
    if not lines or tuple(lines[0].split("\t")) != COLUMNS:
        return {}, [f"{LIST}: the first line must be the header " + "\\t".join(COLUMNS)]
    hashes, problems = {}, []
    for n, line in enumerate(lines[1:], 2):
        if not line.strip():
            continue
        fields = line.split("\t")
        if len(fields) != len(COLUMNS):
            problems.append(f"{LIST} line {n}: {len(fields)} fields, the header has {len(COLUMNS)}")
            continue
        row = dict(zip(COLUMNS, fields), line=n)
        if not re.fullmatch(r"[0-9a-f]{64}", row["sha256"]):
            problems.append(f"{LIST} line {n}: {row['sha256']!r} is not a SHA-256")
            continue
        hashes[row["sha256"]] = row
    return hashes, problems


def guarded(f):
    """the files of this mod the guard looks at"""
    return f.startswith("graphics/") or f == "thumbnail.png"


def check_tree(root=ROOT, others=()):
    """the guard: (number of hashes, problems, {other tree: hashes compared}); `others` are other checkouts (Gregtorio
    Continued), whose files are all compared"""
    root = Path(root)
    hashes, problems = read_list(root)
    compared = {}
    if not hashes:
        return 0, problems or [f"{LIST} lists no hash"], compared
    for f in tree_files(root):
        row = hashes.get(sha256(root / f)) if guarded(f) else None
        if row:
            problems.append(f"{f} is byte-identical to {row['file']} of {row['source']} (an icon taken over from Gregtorio "
                            f"0.1.9, issue #238; {LIST} line {row['line']}): draw it with tools/gen_ae2_sprites.py")
    what = {h: f"{r['file']} of {r['source']}" for h, r in hashes.items()}
    for other in others:
        hits = identical_files(other, what)
        compared[str(other)] = len(hashes)
        for f, w in hits:
            problems.append(f"{other}: {f} is byte-identical to {w} (an icon taken over from Gregtorio 0.1.9, issue #238)")
    return len(hashes), problems, compared
