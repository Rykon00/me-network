#!/usr/bin/env python3
"""The texture mod ae2-textures/ (issue #239, before it the folder graphics/ae2/ of issue #235): its manifest and its guard.

ae2-textures/ is a mod of its own, me-network-ae2-textures, under CC BY-NC-SA 3.0 (docs/LICENSES.md); the repository
root is the mod me-network under GPLv3 (its GT5-Unofficial graphics LGPL-3.0), and no zip holds both
(tools/build.py). The texture mod holds its mod files (MOD_FILES, locale/<language>/*.cfg), three documentation
files (LICENSE-CC-BY-NC-SA-3.0.txt, README.md, MANIFEST.tsv), in graphics/ the AE2-derived images and in its top
folder the thumbnail (THUMBNAIL, issue #500: the one AE2-derived image outside graphics/), one manifest row per image:

    file           the image's path inside ae2-textures/graphics/ ("cable/fluix.png"); the thumbnail's row has the file
                   "thumbnail.png", so graphics/ never holds a file of that name at its top
    repository     the AE2 repository it came from (one of REPOSITORIES)
    source         its path in that repository (under the repository's textures folder; the thumbnail's may also be
                   the repository's mod logo, LOGOS); a file made from more than one
                   texture of the same checkout (issue #260: a block and its lights) lists them all, separated by `;`,
                   the imported one first
    commit         the commit of the checkout it was taken from (git rev-parse HEAD)
    source_sha256  SHA-256 of the source file at that commit (one per source, in the same order, separated by `;`)
    author         the copyright line of "Textures and Models" in that repository's README
    license        CC BY-NC-SA 3.0
    changed        no (a byte-identical copy) or yes (recoloured, cropped, scaled, framed, ...)
    note           one line: what the file is for and, when changed, what was changed

Rows are written by tools/import_ae2_textures.py only. check_tree() is the guard that `devcheck.py check` runs:
every image has a row, every row has its image, nothing else lies in the texture mod, no file outside it (and none
in another checkout, --with-gregtorio) is byte-identical to a file of the manifest or to its AE2 source, and
tools/gen_ae2_sprites.py (GPLv3/LGPL graphics) never names the texture mod or an AE2 checkout.
"""
import hashlib, os, re, subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MOD_FOLDER = "ae2-textures"                 # the texture mod, me-network-ae2-textures
MOD_NAME = "me-network-ae2-textures"
FOLDER = MOD_FOLDER + "/graphics"           # its images: with THUMBNAIL the only files with a manifest row
THUMBNAIL = "thumbnail.png"                 # issue #500: the mod's thumbnail in its top folder, manifest file "thumbnail.png"
LICENSE_FILE = "LICENSE-CC-BY-NC-SA-3.0.txt"
DOCS = (LICENSE_FILE, "README.md", "MANIFEST.tsv")
# the texture mod's own files besides DOCS, locale/<language>/*.cfg and the images (all CC BY-NC-SA 3.0)
MOD_FILES = ("info.json", "changelog.txt", "data-updates.lua", "data-final-fixes.lua", "overrides.lua")
LOCALE = re.compile(r"locale/[a-zA-Z-]+/[A-Za-z0-9_.-]+\.cfg")
COLUMNS = ("file", "repository", "source", "commit", "source_sha256", "author", "license", "changed", "note")
LICENSE = "CC BY-NC-SA 3.0"
# SHA-256 of https://creativecommons.org/licenses/by-nc-sa/3.0/legalcode.txt (LF line ends, .gitattributes)
LICENSE_SHA256 = "8812f83442fd0eca14eb0208988e190fdcbfebec58fa5459d3218edfdfdc5a32"
# the AE2 repositories graphics may come from, and the folder of their textures; AE2-Unofficial (GTNewHorizons) is
# the same authors' work under the same license, the manifest names which one a file came from
REPOSITORIES = {
    "https://github.com/AppliedEnergistics/Applied-Energistics-2": "src/main/resources/assets/ae2/textures/",
    "https://github.com/GTNewHorizons/Applied-Energistics-2-Unofficial": "src/main/resources/assets/appliedenergistics2/textures/",
}
# issue #500: the mod logo of an AE2 repository (its mcmod.info "logoFile"), a source the thumbnail's row may name
LOGOS = {
    "https://github.com/GTNewHorizons/Applied-Energistics-2-Unofficial": "src/main/resources/assets/appliedenergistics2/meta/logo.png",
}
IMAGE_SUFFIXES = (".png",)
SOURCE_SEP = ";"            # between the sources of a file made from more than one texture (issue #260)
PNG_MAGIC = b"\x89PNG\r\n\x1a\n"
# the generator of the GPLv3/LGPL sprites: it never reads AE2 graphics (CLAUDE.md, "Graphics")
AE2_FREE = ("tools/gen_ae2_sprites.py",)
AE2_NAMES = re.compile(r"ae2-textures[/\\]|__me-network-ae2-textures__|graphics/ae2/|graphics\\ae2\\|Applied-Energistics-2")
# never walked when a tree is not a git checkout: the harness folder holds junctions to other checkouts
SKIP_DIRS = {".git", ".devcheck", "dist", "__pycache__"}


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 16), b""):
            h.update(block)
    return h.hexdigest()


def manifest_path(root=ROOT):
    return Path(root) / MOD_FOLDER / "MANIFEST.tsv"


def read_manifest(root=ROOT):
    """(rows as dicts, problems); a row with the wrong number of fields is a problem, not a row"""
    rows, problems = [], []
    p = manifest_path(root)
    if not p.exists():
        return rows, [f"{MOD_FOLDER}/MANIFEST.tsv is missing"]
    lines = p.read_text(encoding="utf-8").splitlines()
    if not lines or tuple(lines[0].split("\t")) != COLUMNS:
        return rows, [f"{MOD_FOLDER}/MANIFEST.tsv: the first line must be the header " + "\\t".join(COLUMNS)]
    for n, line in enumerate(lines[1:], 2):
        if not line.strip():
            continue
        fields = line.split("\t")
        if len(fields) != len(COLUMNS):
            problems.append(f"MANIFEST.tsv line {n}: {len(fields)} fields, the header has {len(COLUMNS)}")
            continue
        rows.append(dict(zip(COLUMNS, fields), line=n))
    return rows, problems


def write_manifest(rows, root=ROOT):
    """rows sorted by file, LF line ends; a value never holds a tab or a line break"""
    out = ["\t".join(COLUMNS)]
    for r in sorted(rows, key=lambda r: r["file"]):
        for c in COLUMNS:
            if re.search(r"[\t\r\n]", str(r[c])):
                raise ValueError(f"{c} of {r['file']} holds a tab or a line break")
        out.append("\t".join(str(r[c]) for c in COLUMNS))
    manifest_path(root).write_bytes(("\n".join(out) + "\n").encode("utf-8"))


def image_path(f, root=ROOT):
    """the file of a manifest row: ae2-textures/thumbnail.png for THUMBNAIL (issue #500), else under graphics/"""
    return Path(root) / MOD_FOLDER / THUMBNAIL if f == THUMBNAIL else Path(root) / FOLDER / f


def image_name(f):
    """the repository path of a manifest row's file, for messages"""
    return f"{MOD_FOLDER}/{THUMBNAIL}" if f == THUMBNAIL else f"{FOLDER}/{f}"


def sources(r):
    """[(path, sha256)] of a row's sources (one, or several for a file made from more than one texture)"""
    return list(zip(r["source"].split(SOURCE_SEP), r["source_sha256"].split(SOURCE_SEP)))


def row_problems(r):
    """what is wrong with one row by itself (the file is checked by check_tree)"""
    where, bad = f"MANIFEST.tsv line {r['line']} ({r['file']})", []
    f = r["file"]
    if not f or f.startswith("/") or "\\" in f or ".." in f.split("/") or not f.lower().endswith(IMAGE_SUFFIXES):
        bad.append(f"file must be a relative path with / inside {FOLDER}/, ending in " + ", ".join(IMAGE_SUFFIXES))
    prefix = REPOSITORIES.get(r["repository"])
    if prefix is None:
        bad.append(f"repository {r['repository']!r} is not an AE2 repository (" + ", ".join(REPOSITORIES) + ")")
    else:
        for path in r["source"].split(SOURCE_SEP):
            logo = f == THUMBNAIL and path == LOGOS.get(r["repository"])
            if not (path.startswith(prefix) or logo) or ".." in path.split("/"):
                bad.append(f"source {path!r} is not under {prefix}"
                           + (f" and not the repository's logo ({LOGOS[r['repository']]})"
                              if f == THUMBNAIL and r["repository"] in LOGOS else ""))
    if not re.fullmatch(r"[0-9a-f]{40}", r["commit"]):
        bad.append(f"commit {r['commit']!r} is not a full git commit hash")
    shas = r["source_sha256"].split(SOURCE_SEP)
    for h in shas:
        if not re.fullmatch(r"[0-9a-f]{64}", h):
            bad.append(f"source_sha256 {h!r} is not a SHA-256")
    n = len(r["source"].split(SOURCE_SEP))
    if len(shas) != n:
        bad.append(f"{n} sources but {len(shas)} SHA-256 values")
    if n > 1 and r["changed"] != "yes":
        bad.append("a file made from several sources is changed: yes")
    if not r["author"].strip():
        bad.append("author is empty")
    if r["license"] != LICENSE:
        bad.append(f"license {r['license']!r} is not {LICENSE!r}")
    if r["changed"] not in ("yes", "no"):
        bad.append(f"changed {r['changed']!r} is not yes or no")
    if not r["note"].strip():
        bad.append("note is empty (what the file is for and, when changed, what was changed)")
    return [f"{where}: {b}" for b in bad]


def tree_files(root):
    """every file of a tree as a path relative to it (/), without what git ignores; outside a git checkout the
    tree is walked without SKIP_DIRS and without following links or junctions"""
    root = Path(root)
    if (root / ".git").exists():
        out = subprocess.run(["git", "-C", str(root), "ls-files", "-z", "-co", "--exclude-standard"],
                             capture_output=True, check=True).stdout.decode("utf-8")
        return sorted({f for f in out.split("\0") if f and (root / f).is_file()})
    files = []
    for d, dirs, names in os.walk(root):
        dirs[:] = [x for x in dirs if x not in SKIP_DIRS and not os.path.islink(os.path.join(d, x))
                   and not (hasattr(os.path, "isjunction") and os.path.isjunction(os.path.join(d, x)))]
        files += [Path(d, n).relative_to(root).as_posix() for n in names]
    return sorted(files)


def identical_files(root, hashes, skip_folder=False):
    """files of a tree whose bytes are one of `hashes` ({sha256: what it is}): [(path, what)]; skip_folder leaves
    the texture mod out"""
    if not hashes:
        return []
    hits = []
    for f in tree_files(root):
        if skip_folder and (f + "/").startswith(MOD_FOLDER + "/"):
            continue
        h = sha256(Path(root) / f)
        if h in hashes:
            hits.append((f, hashes[h]))
    return hits


def mod_file_problem(rel):
    """why a path inside the texture mod (relative to it, /) does not belong there, or None (an image under
    graphics/ and the thumbnail are checked against the manifest by check_tree)"""
    if (rel in DOCS or rel in MOD_FILES or LOCALE.fullmatch(rel) or rel.startswith("graphics/")
            or rel == THUMBNAIL):
        return None
    return (f"{MOD_FOLDER}/{rel}: not a file of the texture mod; it holds {', '.join(MOD_FILES + DOCS)}, "
            f"locale/<language>/*.cfg, the AE2-derived images in graphics/ and {THUMBNAIL}")


def manifest_hashes(root=ROOT):
    """{sha256: what it is} of every image of the manifest and of its AE2 source"""
    rows, _ = read_manifest(root)
    hashes = {}
    for r in rows:
        p = image_path(r["file"], root)
        if p.is_file():
            hashes[sha256(p)] = image_name(r["file"])
    for r in rows:
        for path, h in sources(r):
            if re.fullmatch(r"[0-9a-f]{64}", h):
                hashes.setdefault(h, f"the AE2 source of {image_name(r['file'])} ({path})")
    return hashes


def check_tree(root=ROOT, others=()):
    """the guard: (number of AE2 files in the manifest, problems, {other tree: files compared}); `others` are other
    checkouts (Gregtorio Continued) that must hold no file byte-identical to an AE2 file or its source"""
    root = Path(root)
    mod, folder = root / MOD_FOLDER, root / FOLDER
    problems, compared = [], {}
    if not mod.is_dir():
        return 0, [f"{MOD_FOLDER}/ is missing"], compared
    for d in DOCS + MOD_FILES:
        if not (mod / d).is_file():
            problems.append(f"{MOD_FOLDER}/{d} is missing")
    lic = mod / LICENSE_FILE
    if lic.is_file() and sha256(lic) != LICENSE_SHA256:
        problems.append(f"{MOD_FOLDER}/{LICENSE_FILE} is not the legal code text of CC BY-NC-SA 3.0 "
                        "(https://creativecommons.org/licenses/by-nc-sa/3.0/legalcode.txt)")
    rows, bad = read_manifest(root)
    problems += bad
    by_file = {}
    for r in rows:
        problems += row_problems(r)
        if r["file"] in by_file:
            problems.append(f"MANIFEST.tsv line {r['line']}: {r['file']} has a row already (line {by_file[r['file']]['line']})")
        by_file.setdefault(r["file"], r)
    for p in sorted(mod.rglob("*")):
        why = p.is_file() and mod_file_problem(p.relative_to(mod).as_posix())
        if why:
            problems.append(why)
    present = sorted(p.relative_to(folder).as_posix() for p in folder.rglob("*") if p.is_file()) if folder.is_dir() else []
    for f in present:
        p = folder / f
        if not f.lower().endswith(IMAGE_SUFFIXES):
            problems.append(f"{FOLDER}/{f}: not an image; {FOLDER}/ holds only AE2-derived images")
            continue
        with open(p, "rb") as fh:
            if fh.read(len(PNG_MAGIC)) != PNG_MAGIC:
                problems.append(f"{FOLDER}/{f}: not a PNG file")
        if f == THUMBNAIL:
            problems.append(f"{FOLDER}/{f}: the name {THUMBNAIL} at the top of {FOLDER}/ is kept for the row of "
                            f"{MOD_FOLDER}/{THUMBNAIL} (issue #500); give the image another name")
        elif f not in by_file:
            problems.append(f"{FOLDER}/{f}: no row in MANIFEST.tsv (import AE2 graphics with tools/import_ae2_textures.py)")
    thumb = mod / THUMBNAIL
    if thumb.is_file():
        with open(thumb, "rb") as fh:
            if fh.read(len(PNG_MAGIC)) != PNG_MAGIC:
                problems.append(f"{MOD_FOLDER}/{THUMBNAIL}: not a PNG file")
        if THUMBNAIL not in by_file:
            problems.append(f"{MOD_FOLDER}/{THUMBNAIL}: no row in MANIFEST.tsv (the thumbnail is AE2-derived too: "
                            f"import it with tools/import_ae2_textures.py ... {THUMBNAIL})")
    for f, r in by_file.items():
        p = image_path(f, root)
        if not p.is_file():
            problems.append(f"MANIFEST.tsv line {r['line']}: {image_name(f)} does not exist")
            continue
        h = sha256(p)
        if r["changed"] == "no" and h != r["source_sha256"]:
            problems.append(f"{image_name(f)}: changed is no, but the file is not the source's bytes (SHA-256 {h}); "
                            "record a change with tools/import_ae2_textures.py --mark-changed")
        if r["changed"] == "yes" and h in r["source_sha256"].split(SOURCE_SEP):
            problems.append(f"{image_name(f)}: changed is yes, but the file is the source's bytes")
    hashes = manifest_hashes(root)
    for f, what in identical_files(root, hashes, skip_folder=True):
        problems.append(f"{f} is byte-identical to {what}: AE2 graphics belong in {FOLDER}/ only")
    for other in others:
        hits = identical_files(other, hashes)
        compared[str(other)] = len(hashes)
        for f, what in hits:
            problems.append(f"{other}: {f} is byte-identical to {what}: that repository has no folder for AE2 graphics")
    for f in AE2_FREE:
        p = root / f
        if p.is_file():
            for n, line in enumerate(p.read_text(encoding="utf-8").splitlines(), 1):
                if AE2_NAMES.search(line):
                    problems.append(f"{f} line {n} names the texture mod or an AE2 checkout: its graphics are "
                                    "GPLv3/LGPL and never read AE2 graphics")
    return len(by_file), problems, compared
