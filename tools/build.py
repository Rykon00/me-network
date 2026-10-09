#!/usr/bin/env python3
"""Packs the two mods of this repository as Factorio zips (<name>_<version>.zip) into dist/ (issue #239):

    me-network_<version>.zip               the repository root without ae2-textures/: GPLv3 (LICENSE), its
                                           GT5-Unofficial graphics LGPL-3.0
    me-network-ae2-textures_<version>.zip  ae2-textures/ alone, its info.json at the zip's top folder: CC BY-NC-SA 3.0
                                           (LICENSE-CC-BY-NC-SA-3.0.txt), depends on me-network

    python tools/build.py              # build both
    python tools/build.py --install    # build + copy both into the Factorio mods folder
    python tools/build.py --mods-dir PATH --install
    python tools/build.py --no-psd     # leave out Photoshop sources (smaller zip)
    python tools/build.py --portal     # zips for the mod portal (same as --no-psd)

No zip holds both licenses. The build fails and deletes both zips when the me-network zip holds a path under
ae2-textures/, a file with the bytes of an image of ae2-textures/MANIFEST.tsv or of its AE2 source, the CC BY-NC-SA
3.0 text, or a Lua file or info.json naming the texture mod (me-network never knows it), or lacks LICENSE; and when
the texture zip holds anything but its own files (tools/ae2_manifest.py: MOD_FILES, DOCS, locale/<language>/*.cfg)
and the images of its manifest with their bytes, or the GPL text.
"""
import argparse, hashlib, json, os, shutil, sys, zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ae2_manifest as M

ROOT = Path(__file__).resolve().parent.parent
INCLUDE = ["info.json", "changelog.txt", "thumbnail.png", "LICENSE",
           "data.lua", "data-updates.lua", "data-final-fixes.lua", "control.lua",
           "settings.lua", "settings-updates.lua", "settings-final-fixes.lua",
           "prototypes", "graphics", "locale", "scripts", "migrations"]
JUNK = (".DS_Store", "Thumbs.db")

def default_mods_dir():
    if sys.platform.startswith("win"):
        return Path(os.environ["APPDATA"]) / "Factorio" / "mods"
    if sys.platform == "darwin":
        return Path.home() / "Library/Application Support/factorio/mods"
    return Path.home() / ".factorio/mods"

def info_of(folder):
    return json.loads((Path(folder) / "info.json").read_text(encoding="utf-8"))

def write_zip(out, base, files):
    """files: [(path on disk, path inside the mod)] -> out, every entry under base/"""
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        for f, rel in files:
            z.write(f, f"{base}/{rel}")
    return out

def build_me_network(root=ROOT, dist=None, no_psd=False):
    root = Path(root)
    info = info_of(root)
    base = f"{info['name']}_{info['version']}"
    files = []
    for entry in INCLUDE:
        p = root / entry
        if not p.exists():
            continue
        for f in [p] if p.is_file() else sorted(x for x in p.rglob("*") if x.is_file()):
            if (no_psd and f.suffix.lower() == ".psd") or f.name in JUNK:
                continue
            files.append((f, f.relative_to(root).as_posix()))
    return write_zip(Path(dist or root / "dist") / f"{base}.zip", base, files)

def build_textures(root=ROOT, dist=None):
    mod = Path(root) / M.MOD_FOLDER
    info = info_of(mod)
    base = f"{info['name']}_{info['version']}"
    files = [(f, f.relative_to(mod).as_posix()) for f in sorted(mod.rglob("*")) if f.is_file() and f.name not in JUNK]
    return write_zip(Path(dist or Path(root) / "dist") / f"{base}.zip", base, files)

def entries_of(path):
    """(top folder, {path inside the mod: bytes}, problems)"""
    with zipfile.ZipFile(path) as z:
        names = [n for n in z.namelist() if not n.endswith("/")]
        data = {n: z.read(n) for n in names}
    tops = {n.split("/", 1)[0] for n in names}
    if len(tops) != 1 or any("/" not in n for n in names):
        return None, {}, [f"{Path(path).name}: every file must lie in one top folder, found {sorted(tops)}"]
    top = tops.pop()
    return top, {n[len(top) + 1:]: b for n, b in data.items()}, []

def digest(b):
    return hashlib.sha256(b).hexdigest()

def check_me_network_zip(path, root=ROOT):
    """what is wrong with the me-network zip (GPLv3): [problem]"""
    root = Path(root)
    top, entries, problems = entries_of(path)
    if problems:
        return problems
    name = Path(path).name
    info = info_of(root)
    if top != f"{info['name']}_{info['version']}":
        problems.append(f"{name}: top folder {top}, expected {info['name']}_{info['version']}")
    hashes = M.manifest_hashes(root)
    gpl = M.sha256(root / "LICENSE") if (root / "LICENSE").is_file() else None
    for rel, b in sorted(entries.items()):
        h = digest(b)
        if rel == M.MOD_FOLDER or rel.startswith(M.MOD_FOLDER + "/"):
            problems.append(f"{name}: {rel} is a file of the texture mod; {M.MOD_FOLDER}/ is never in the me-network zip")
        if h in hashes:
            problems.append(f"{name}: {rel} is byte-identical to {hashes[h]}: AE2 graphics are never in the me-network zip")
        if h == M.LICENSE_SHA256 or Path(rel).name == M.LICENSE_FILE:
            problems.append(f"{name}: {rel} is the CC BY-NC-SA 3.0 text; the me-network zip is GPLv3 only")
        if (rel.endswith(".lua") or rel == "info.json") and M.MOD_NAME.encode() in b:
            problems.append(f"{name}: {rel} names {M.MOD_NAME}; me-network never knows the texture mod")
    if "LICENSE" not in entries or (gpl and digest(entries["LICENSE"]) != gpl):
        problems.append(f"{name}: LICENSE (GPLv3) is missing or not the repository's")
    return problems

def check_texture_zip(path, root=ROOT):
    """what is wrong with the texture mod's zip (CC BY-NC-SA 3.0): [problem]"""
    root = Path(root)
    top, entries, problems = entries_of(path)
    if problems:
        return problems
    name = Path(path).name
    info = info_of(root / M.MOD_FOLDER)
    if info.get("name") != M.MOD_NAME or top != f"{M.MOD_NAME}_{info.get('version')}":
        problems.append(f"{name}: top folder {top} and info.json name {info.get('name')!r}, expected "
                        f"{M.MOD_NAME}_{info.get('version')} and {M.MOD_NAME!r}")
    if not any(d.split()[0] == "me-network" for d in info.get("dependencies", [])):
        problems.append(f"{name}: info.json does not depend on me-network")
    rows, bad = M.read_manifest(root)
    problems += [f"{name}: {b}" for b in bad]
    files = {r["file"] for r in rows}
    gpl = M.sha256(root / "LICENSE") if (root / "LICENSE").is_file() else None
    for rel, b in sorted(entries.items()):
        h = digest(b)
        why = M.mod_file_problem(rel)
        if why:
            problems.append(f"{name}: {rel} is not a file of the texture mod")
        elif rel.startswith("graphics/"):
            f = rel[len("graphics/"):]
            src = root / M.FOLDER / f
            if f not in files:
                problems.append(f"{name}: {rel} has no row in {M.MOD_FOLDER}/MANIFEST.tsv")
            elif not src.is_file() or M.sha256(src) != h:
                problems.append(f"{name}: {rel} is not the bytes of {M.FOLDER}/{f}")
        if h == gpl or rel == "LICENSE":
            problems.append(f"{name}: {rel} is the GPLv3 text; the texture zip is CC BY-NC-SA 3.0 only")
    for d in M.DOCS + M.MOD_FILES:
        if d not in entries:
            problems.append(f"{name}: {d} is missing")
    if M.LICENSE_FILE in entries and digest(entries[M.LICENSE_FILE]) != M.LICENSE_SHA256:
        problems.append(f"{name}: {M.LICENSE_FILE} is not the legal code text of CC BY-NC-SA 3.0")
    return problems

def build_all(root=ROOT, dist=None, no_psd=False):
    """both zips and their problems; with a problem both zips are deleted"""
    dist = Path(dist or Path(root) / "dist")
    dist.mkdir(parents=True, exist_ok=True)
    me = build_me_network(root, dist, no_psd)
    tex = build_textures(root, dist)
    problems = check_me_network_zip(me, root) + check_texture_zip(tex, root)
    if problems:
        me.unlink()
        tex.unlink()
    return me, tex, problems

def topmost_section(changelog):
    if not changelog.exists():
        return ""
    blocks = changelog.read_text(encoding="utf-8").split("-" * 99)
    return next((b.strip() for b in blocks if b.strip()), "")

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--install", action="store_true")
    ap.add_argument("--mods-dir", type=Path)
    ap.add_argument("--no-psd", action="store_true")
    ap.add_argument("--portal", action="store_true", help="zips for the mod portal (same as --no-psd)")
    a = ap.parse_args()
    if a.portal:
        a.no_psd = True
    dist = ROOT / "dist"
    me, tex, problems = build_all(ROOT, dist, a.no_psd)
    if problems:
        sys.exit("build: the packages break the license split (issue #239):\n  " + "\n  ".join(problems))
    count = len(M.read_manifest()[0])
    print(f"licenses: {me.name}: LICENSE (GPLv3); {tex.name}: {M.LICENSE_FILE} (CC BY-NC-SA 3.0, {count} AE2 files; "
          f"attribution in README.md, MANIFEST.tsv)")
    # release notes = topmost section of each changelog.txt
    notes = "```\n" + topmost_section(ROOT / "changelog.txt") + "\n```\n"
    tex_info = info_of(ROOT / M.MOD_FOLDER)
    notes += (f"\n{tex_info['title']} {tex_info['version']} ({tex.name}, CC BY-NC-SA 3.0, optional):\n\n```\n"
              + topmost_section(ROOT / M.MOD_FOLDER / "changelog.txt") + "\n```\n")
    (dist / "release-notes.md").write_text(notes, encoding="utf-8")
    for out in (me, tex):
        print(f"built: {out} ({out.stat().st_size/1e6:.1f} MB)")

    if a.install:
        mods = a.mods_dir or default_mods_dir()
        for out in (me, tex):
            name = out.name.rsplit("_", 1)[0]
            for old in mods.glob(f"{name}_*.zip"):
                print(f"removing old version: {old.name}")
                old.unlink()
            shutil.copy2(out, mods / out.name)
            print(f"installed to: {mods / out.name}")

if __name__ == "__main__":
    main()
