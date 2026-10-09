#!/usr/bin/env python3
"""Links the two mods of this repository into the Factorio mods folder, so Factorio always loads the
current working copy (no zip building/copying after every change).

    python tools/dev_link.py                 # create both links
    python tools/dev_link.py --no-textures   # only me-network
    python tools/dev_link.py --unlink        # remove both links again
    python tools/dev_link.py --mods-dir PATH

Factorio loads an unpacked mod from a folder named like the mod ("me-network") or like the mod and its version.
The links: "me-network" to the repository root, and "me-network-ae2-textures_<version>" to ae2-textures/, the
optional texture mod (CC BY-NC-SA 3.0, issue #239; me-network runs without it). On Windows a link is a directory
junction (no admin rights needed), elsewhere a symlink. A texture mod link of another version is replaced; only links
are ever removed, never a real folder. Existing <name>_*.zip files in the mods folder (for example from the mod
portal) would compete with the folder, so they are moved next to the mods folder into <name>-zips-backup/ (nothing
is deleted).
Factorio only reads mods at startup: restart it after pulling changes.
"""
import argparse, json, os, shutil, subprocess, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TEXTURES = ROOT / "ae2-textures"
OLD_NAMES = []             # earlier names of the mod (none)


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


def remove_link(p):
    try:
        os.rmdir(p) if sys.platform.startswith("win") else p.unlink()
    except PermissionError:
        sys.exit(f"{p} is in use - close Factorio and run the script again.")


def park_zips(mods, name):
    parked = mods.parent / (name + "-zips-backup")   # outside mods/, Factorio would scan it
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


def make_link(link, target):
    if link.exists() or is_link(link):
        if is_link(link):
            print(f"link already exists: {link}")
            return
        sys.exit(f"{link} already exists as a real folder - move it away first")
    if sys.platform.startswith("win"):
        subprocess.run(["cmd", "/c", "mklink", "/J", str(link), str(target)], check=True)
    else:
        link.symlink_to(target, target_is_directory=True)
    print(f"linked {link} -> {target}")


def texture_links(mods, name):
    """the links of the texture mod in the mods folder, whatever their version"""
    return [p for p in sorted(mods.glob(f"{name}_*")) if is_link(p)]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mods-dir", type=Path)
    ap.add_argument("--unlink", action="store_true")
    ap.add_argument("--no-textures", action="store_true", help="do not link the texture mod ae2-textures/")
    a = ap.parse_args()
    mods = a.mods_dir or default_mods_dir()
    name = json.loads((ROOT / "info.json").read_text(encoding="utf-8"))["name"]
    tex = json.loads((TEXTURES / "info.json").read_text(encoding="utf-8"))
    link = mods / name
    tex_link = mods / f"{tex['name']}_{tex['version']}"

    if a.unlink:
        found = [p for p in [link] if p.exists() or is_link(p)] + texture_links(mods, tex["name"])
        for p in found:
            if not is_link(p):
                sys.exit(f"{p} is a real folder, not a link - not touching it")
            remove_link(p)
            print(f"removed link {p}")
        if not found:
            print("no link found")
        return

    for old_name in OLD_NAMES:
        old = mods / old_name
        if old_name != name and is_link(old) and os.path.realpath(old) == os.path.realpath(ROOT):
            remove_link(old)
            print(f"removed the old link {old} (the mod is called {name} now)")

    park_zips(mods, name)
    make_link(link, ROOT)
    if not a.no_textures:
        for old in texture_links(mods, tex["name"]):
            if old.name != tex_link.name:
                remove_link(old)
                print(f"removed the link of another version {old}")
        park_zips(mods, tex["name"])
        make_link(tex_link, TEXTURES)
    print("Restart Factorio to load the working copy.")


if __name__ == "__main__":
    main()
