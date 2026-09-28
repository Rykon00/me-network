#!/usr/bin/env python3
"""Packt die Mod als Factorio-Zip (Gregtorio_<version>.zip) nach dist/.

    python tools/build.py              # nur bauen
    python tools/build.py --install    # bauen + in den Factorio-Mods-Ordner kopieren
    python tools/build.py --mods-dir PFAD --install
    python tools/build.py --no-psd     # Photoshop-Quellen weglassen (kleineres Zip)
"""
import argparse, json, os, shutil, sys, zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
INCLUDE = ["info.json", "changelog.txt", "thumbnail.png", "LICENSE",
           "data.lua", "data-updates.lua", "data-final-fixes.lua", "control.lua",
           "settings.lua", "settings-updates.lua", "settings-final-fixes.lua",
           "prototypes", "graphics", "locale", "scripts", "migrations"]

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
    a = ap.parse_args()

    info = json.loads((ROOT / "info.json").read_text(encoding="utf-8"))
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
                z.write(f, f"{base}/{rel.as_posix()}")
    # Release-Notes = oberster Abschnitt aus changelog.txt
    cl = ROOT / "changelog.txt"
    if cl.exists():
        blocks = cl.read_text(encoding="utf-8").split("-" * 99)
        first = next((b.strip() for b in blocks if b.strip()), "")
        (dist / "release-notes.md").write_text("```\n" + first + "\n```\n", encoding="utf-8")
    print(f"gebaut: {out} ({out.stat().st_size/1e6:.1f} MB)")

    if a.install:
        mods = a.mods_dir or default_mods_dir()
        for old in mods.glob(f"{info['name']}_*.zip"):
            print(f"entferne alte Version: {old.name}")
            old.unlink()
        shutil.copy2(out, mods / out.name)
        print(f"installiert nach: {mods / out.name}")

if __name__ == "__main__":
    main()
