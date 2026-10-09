#!/usr/bin/env python3
"""Imports a texture of Applied Energistics 2 into graphics/ae2/ and records it in graphics/ae2/MANIFEST.tsv
(issue #235). graphics/ae2/ is the CC BY-NC-SA 3.0 part of this mod (graphics/ae2/README.md, docs/LICENSES.md):
AE2 graphics enter the mod only through this tool, never traced, never merged with graphics of another origin.

    python tools/import_ae2_textures.py --ae2 ../Applied-Energistics-2 \\
        src/main/resources/assets/ae2/textures/block/drive/drive_bottom.png drive/bottom.png --note "ME Drive side"
    python tools/import_ae2_textures.py --ae2 ../Applied-Energistics-2 <source> <target> --replace   # a new version
    python tools/import_ae2_textures.py --mark-changed drive/bottom.png --note "scaled to 64 px, recoloured"
    python tools/import_ae2_textures.py --remove drive/bottom.png

The source is a path in the AE2 checkout (relative to it, or absolute inside it). It must be a PNG under the
repository's textures folder (ae2_manifest.REPOSITORIES: AE2 or GTNewHorizons' AE2-Unofficial, found by the
checkout's `origin`), tracked by git and unchanged against HEAD, because the manifest records `git rev-parse HEAD`
as the commit it came from, with the SHA-256 of the source. The author is the copyright line of "Textures and
Models" in the checkout's README.md, which must name CC BY-NC-SA 3.0. The target is a PNG path inside graphics/ae2/;
an existing target or row is refused unless --replace says so.

The copy is byte-identical (changed: no). A file changed afterwards (recoloured, cropped, scaled to the sprite grid,
put into an animation strip) stays CC BY-NC-SA 3.0: record it with --mark-changed and a note of what was done. A
script that transforms these files reads only from graphics/ae2/ and writes only into it, never into another
graphics folder and never from one; tools/gen_ae2_sprites.py (GPLv3/LGPL) never touches them. A sprite that needs
an AE2 part and a part of another origin is two layers in the prototype, one file per origin.
"""
import argparse, re, shutil, subprocess, sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from ae2_manifest import (COLUMNS, DOCS, FOLDER, IMAGE_SUFFIXES, LICENSE, PNG_MAGIC, REPOSITORIES, ROOT,
                          read_manifest, sha256, write_manifest)


def fail(msg):
    sys.exit("import_ae2_textures: " + msg)


def git(checkout, *args):
    r = subprocess.run(["git", "-C", str(checkout), *args], capture_output=True, text=True)
    return r.returncode, r.stdout.strip()


def repository_of(checkout):
    code, url = git(checkout, "remote", "get-url", "origin")
    if code:
        fail(f"{checkout} is not a git checkout with a remote `origin`")
    url = re.sub(r"^git@github\.com:", "https://github.com/", url)
    url = re.sub(r"\.git$", "", url.rstrip("/"))
    for repo in REPOSITORIES:
        if url.lower() == repo.lower():
            return repo
    fail(f"{checkout} is a checkout of {url}, not of an AE2 repository (" + ", ".join(REPOSITORIES) + ")")


def author_of(checkout):
    """the copyright line under "Textures and Models" in the checkout's README.md; it must name CC BY-NC-SA 3.0"""
    readme = Path(checkout) / "README.md"
    lines = readme.read_text(encoding="utf-8").splitlines() if readme.exists() else []
    for i, line in enumerate(lines):
        if line.strip().lstrip("*- ").strip() == "Textures and Models":
            block = lines[i + 1:i + 3]
            if len(block) == 2 and "(c)" in block[0] and re.search(r"by-nc-sa/3\.0|BY--NC--SA%203\.0", block[1]):
                return re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", block[0]).strip().lstrip("- ").strip()
    fail(f"{readme} does not state the authors and CC BY-NC-SA 3.0 for \"Textures and Models\"; read its license notes first")


def target_path(name):
    name = name.replace("\\", "/")
    if name.startswith("/") or ".." in name.split("/") or not name.lower().endswith(IMAGE_SUFFIXES) or name in DOCS:
        fail(f"target {name!r} must be a relative path inside {FOLDER}/ ending in " + ", ".join(IMAGE_SUFFIXES))
    return name, ROOT / FOLDER / name


def do_import(a):
    checkout = Path(a.ae2).resolve()
    repo = repository_of(checkout)
    src = Path(a.source)
    src = (src if src.is_absolute() else checkout / src).resolve()
    try:
        rel = src.relative_to(checkout).as_posix()
    except ValueError:
        fail(f"{src} is not inside the AE2 checkout {checkout}")
    prefix = REPOSITORIES[repo]
    if not rel.startswith(prefix):
        fail(f"{rel} is not under the textures folder {prefix} of {repo}")
    if not src.is_file() or not rel.lower().endswith(IMAGE_SUFFIXES):
        fail(f"{rel} is not an image file (" + ", ".join(IMAGE_SUFFIXES) + ")")
    if src.read_bytes()[:len(PNG_MAGIC)] != PNG_MAGIC:
        fail(f"{rel} is not a PNG file")
    if git(checkout, "ls-files", "--error-unmatch", "--", rel)[0]:
        fail(f"{rel} is not tracked by git in {checkout}: the manifest needs a commit that holds it")
    if git(checkout, "status", "--porcelain", "--", rel)[1]:
        fail(f"{rel} differs from HEAD in {checkout}: commit, stash or check out the file first")
    commit = git(checkout, "rev-parse", "HEAD")[1]
    author = author_of(checkout)
    name, dest = target_path(a.target)
    rows, bad = read_manifest()
    if bad:
        fail("fix MANIFEST.tsv first: " + "; ".join(bad))
    known = [r for r in rows if r["file"] == name]
    if (known or dest.exists()) and not a.replace:
        fail(f"{FOLDER}/{name} exists already" + (" in MANIFEST.tsv" if known else "") + "; pass --replace to overwrite it")
    note = (a.note or "copied unchanged").strip()
    row = dict(file=name, repository=repo, source=rel, commit=commit, source_sha256=sha256(src), author=author,
               license=LICENSE, changed="no", note=note)
    dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(src, dest)
    write_manifest([r for r in rows if r["file"] != name] + [row])
    print(f"{'replaced' if known or a.replace else 'imported'}: {FOLDER}/{name}")
    for c in COLUMNS:
        print(f"  {c}: {row[c]}")


def do_mark_changed(a):
    name, dest = target_path(a.mark_changed)
    if not a.note:
        fail("--mark-changed needs --note with what was changed")
    rows, bad = read_manifest()
    if bad:
        fail("fix MANIFEST.tsv first: " + "; ".join(bad))
    row = next((r for r in rows if r["file"] == name), None)
    if row is None or not dest.is_file():
        fail(f"{FOLDER}/{name} has no row or no file")
    if sha256(dest) == row["source_sha256"]:
        fail(f"{FOLDER}/{name} is still the source's bytes; change the file first")
    row.update(changed="yes", note=a.note.strip())
    write_manifest(rows)
    print(f"changed: {FOLDER}/{name}: {row['note']}")


def do_remove(a):
    name, dest = target_path(a.remove)
    rows, bad = read_manifest()
    if bad:
        fail("fix MANIFEST.tsv first: " + "; ".join(bad))
    keep = [r for r in rows if r["file"] != name]
    if len(keep) == len(rows) and not dest.exists():
        fail(f"{FOLDER}/{name} has no row and no file")
    if dest.exists():
        dest.unlink()
    d = dest.parent
    while d != ROOT / FOLDER and d.is_dir() and not any(d.iterdir()):
        d.rmdir()
        d = d.parent
    write_manifest(keep)
    print(f"removed: {FOLDER}/{name}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--ae2", metavar="CHECKOUT", help="the AE2 (or AE2-Unofficial) checkout to copy from")
    ap.add_argument("source", nargs="?", help="the texture's path in the checkout")
    ap.add_argument("target", nargs="?", help=f"the file's path inside {FOLDER}/")
    ap.add_argument("--note", help="one line: what the file is for (import) or what was changed (--mark-changed)")
    ap.add_argument("--replace", action="store_true", help="overwrite an existing file and its row")
    ap.add_argument("--mark-changed", metavar="TARGET", help="record that a file was changed after its import")
    ap.add_argument("--remove", metavar="TARGET", help="delete a file and its row")
    a = ap.parse_args()
    modes = [bool(a.ae2 or a.source or a.target), bool(a.mark_changed), bool(a.remove)]
    if sum(modes) != 1:
        ap.error("give either --ae2 CHECKOUT SOURCE TARGET, or --mark-changed TARGET --note ..., or --remove TARGET")
    if a.mark_changed:
        return do_mark_changed(a)
    if a.remove:
        return do_remove(a)
    if not (a.ae2 and a.source and a.target):
        ap.error("an import needs --ae2 CHECKOUT, SOURCE and TARGET")
    return do_import(a)


if __name__ == "__main__":
    main()
