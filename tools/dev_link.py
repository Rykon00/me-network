#!/usr/bin/env python3
"""Links this repository into the Factorio mods folder, so Factorio always loads the
current working copy (no zip building/copying after every change).

    python tools/dev_link.py            # create the link
    python tools/dev_link.py --unlink   # remove the link again
    python tools/dev_link.py --mods-dir PATH

Factorio loads an unpacked mod from a folder named like the mod ("Gregtorio"). On Windows
the link is a directory junction (no admin rights needed), elsewhere a symlink.
Existing Gregtorio_*.zip files in the mods folder would compete with the folder, so they
are moved next to the mods folder into gregtorio-zips-backup/ (nothing is deleted).
Factorio only reads mods at startup: restart it after pulling changes.
"""
import argparse, json, os, shutil, subprocess, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def default_mods_dir():
    if sys.platform.startswith("win"):
        return Path(os.environ["APPDATA"]) / "Factorio" / "mods"
    if sys.platform == "darwin":
        return Path.home() / "Library/Application Support/factorio/mods"
    return Path.home() / ".factorio/mods"


def is_link(p):
    try:
        return p.is_symlink() or (sys.platform.startswith("win") and bool(os.readlink(p)))
    except OSError:
        return False


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mods-dir", type=Path)
    ap.add_argument("--unlink", action="store_true")
    a = ap.parse_args()
    mods = a.mods_dir or default_mods_dir()
    name = json.loads((ROOT / "info.json").read_text(encoding="utf-8"))["name"]
    link = mods / name

    if a.unlink:
        if link.exists() or is_link(link):
            if not is_link(link):
                sys.exit(f"{link} is a real folder, not a link - not touching it")
            os.rmdir(link) if sys.platform.startswith("win") else link.unlink()
            print(f"removed link {link}")
        else:
            print("no link found")
        return

    if link.exists() or is_link(link):
        if is_link(link):
            print(f"link already exists: {link}")
            return
        sys.exit(f"{link} already exists as a real folder - move it away first")

    parked = mods.parent / "gregtorio-zips-backup"   # outside mods/, Factorio would scan it
    for z in sorted(mods.glob(f"{name}_*.zip")):
        parked.mkdir(parents=True, exist_ok=True)
        dst = parked / z.name
        try:
            if dst.exists():
                dst.unlink()          # left over from an earlier, interrupted run
            os.replace(z, dst)
        except PermissionError:
            sys.exit(f"{z.name} is in use - close Factorio and run the script again.")
        print(f"moved {z.name} -> {parked}")

    if sys.platform.startswith("win"):
        subprocess.run(["cmd", "/c", "mklink", "/J", str(link), str(ROOT)], check=True)
    else:
        link.symlink_to(ROOT, target_is_directory=True)
    print(f"linked {link} -> {ROOT}")
    print("Restart Factorio to load the working copy.")


if __name__ == "__main__":
    main()
