#!/usr/bin/env python3
"""Packs the mod as a Factorio zip (Gregtorio_<version>.zip) into dist/.

    python tools/build.py              # build only
    python tools/build.py --install    # build + copy into the Factorio mods folder
    python tools/build.py --mods-dir PATH --install
    python tools/build.py --no-psd     # leave out Photoshop sources (smaller zip)
    python tools/build.py --portal     # mod portal build as "gregtorio-continued"

The mod portal name "Gregtorio" belongs to the original author (Damien Reave), so the fork is
published as "gregtorio-continued". The repo itself keeps the name "Gregtorio" (the dev link and
existing saves depend on it); --portal renames the mod only inside the zip: info.json name,
title and description, and every "__Gregtorio__/" path in the Lua and JSON files.
"""
import argparse, json, os, shutil, sys, zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
INCLUDE = ["info.json", "changelog.txt", "thumbnail.png", "LICENSE",
           "data.lua", "data-updates.lua", "data-final-fixes.lua", "control.lua",
           "settings.lua", "settings-updates.lua", "settings-final-fixes.lua",
           "prototypes", "graphics", "locale", "scripts", "migrations"]

PORTAL = {
    "name": "gregtorio-continued",
    "title": "Gregtorio Continued",
    "description": (
        "Continuation of Gregtorio by Damien Reave: a GregTech-style total overhaul from digging clay "
        "with a shovel up to the stargate. Adds the GregTech: New Horizons progression up to UXV and "
        "victory, AE2-style ME storage with autocrafting and fluids, and fixes. "
        "Source and issues: https://github.com/Rykon00/Gregtorio"
    ),
    "homepage": "https://github.com/Rykon00/Gregtorio",
}
TEXT_SUFFIXES = {".lua", ".json", ".cfg"}


def default_mods_dir():
    if sys.platform.startswith("win"):
        return Path(os.environ["APPDATA"]) / "Factorio" / "mods"
    if sys.platform == "darwin":
        return Path.home() / "Library/Application Support/factorio/mods"
    return Path.home() / ".factorio/mods"

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--install", action="store_true")
    ap.add_argument("--mods-dir", type=Path)
    ap.add_argument("--no-psd", action="store_true")
    ap.add_argument("--portal", action="store_true", help="mod portal build as gregtorio-continued")
    a = ap.parse_args()

    info = json.loads((ROOT / "info.json").read_text(encoding="utf-8"))
    old_path = f"__{info['name']}__/"
    if a.portal:
        info.update(PORTAL)
        a.no_psd = True
    new_path = f"__{info['name']}__/"
    base = f"{info['name']}_{info['version']}"
    dist = ROOT / "dist"; dist.mkdir(exist_ok=True)
    out = dist / f"{base}.zip"

    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        for entry in INCLUDE:
            p = ROOT / entry
            if not p.exists():
                continue
            files = [p] if p.is_file() else sorted(x for x in p.rglob("*") if x.is_file())
            for f in files:
                rel = f.relative_to(ROOT)
                if a.no_psd and f.suffix.lower() == ".psd":
                    continue
                if f.name in (".DS_Store", "Thumbs.db"):
                    continue
                arc = f"{base}/{rel.as_posix()}"
                if a.portal and rel.as_posix() == "info.json":
                    z.writestr(arc, json.dumps(info, indent=2, ensure_ascii=False) + "\n")
                elif a.portal and f.suffix in TEXT_SUFFIXES:
                    z.writestr(arc, f.read_text(encoding="utf-8").replace(old_path, new_path))
                else:
                    z.write(f, arc)
    # release notes = topmost section of changelog.txt
    cl = ROOT / "changelog.txt"
    if cl.exists():
        blocks = cl.read_text(encoding="utf-8").split("-" * 99)
        first = next((b.strip() for b in blocks if b.strip()), "")
        (dist / "release-notes.md").write_text("```\n" + first + "\n```\n", encoding="utf-8")
    print(f"built: {out} ({out.stat().st_size/1e6:.1f} MB)")

    if a.install:
        mods = a.mods_dir or default_mods_dir()
        for old in mods.glob(f"{info['name']}_*.zip"):
            print(f"removing old version: {old.name}")
            old.unlink()
        shutil.copy2(out, mods / out.name)
        print(f"installed to: {mods / out.name}")

if __name__ == "__main__":
    main()
