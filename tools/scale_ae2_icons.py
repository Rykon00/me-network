#!/usr/bin/env python3
"""Scales the AE2 item icons of the texture mod (issue #247) from 16 x 16 to the size of the me-network icon they
replace: nearest neighbour by an integer factor, so every pixel becomes a block of equal pixels and no new pixel
value appears. Palette images are written as RGBA with the same colours and transparency.

    python tools/scale_ae2_icons.py            # scale what is still 16 x 16 and record it with --mark-changed
    python tools/scale_ae2_icons.py --check    # only say which files are not at their size yet

The files are CC BY-NC-SA 3.0 (ae2-textures/README.md): this script reads only from ae2-textures/graphics/ and
writes only into it, and records each scaled file with `tools/import_ae2_textures.py --mark-changed`. SIZES is the
icon size of the me-network prototype each file stands in for (its `icon_size`; ae2-textures/overrides.lua names
the prototype). A file imported again (`--replace`) is 16 x 16 again and is scaled by the next run.
"""
import argparse, subprocess, sys
from pathlib import Path

from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))
from ae2_manifest import read_manifest

ROOT = Path(__file__).resolve().parent.parent
GRAPHICS = ROOT / "ae2-textures" / "graphics"
SOURCE = 16                 # AE2's item icons

# file inside ae2-textures/graphics/ -> the icon size of the me-network icon it replaces
SIZES = {
    **{f"icons/cells/me-{t}-storage-cell.png": 64 for t in ("1k", "4k", "16k", "64k", "256k")},
    **{f"icons/cells/me-{t}-storage-component.png": 32 for t in ("1k", "4k", "16k", "64k", "256k")},
    "icons/cells/basic-storage-housing.png": 32,
    **{f"icons/cards/me-{c}-card.png": 32 for c in ("basic", "advanced", "capacity", "overflow-destruction", "fuzzy",
                                                     "pattern-capacity", "sticky", "inverter", "equal-distribution",
                                                     "acceleration")},
    "icons/patterns/me-blank-pattern.png": 32,
    "icons/patterns/me-encoded-pattern.png": 32,
}


def scale(path, size):
    """the scaled image of `path` (an Image), or None when it is at `size` already"""
    im = Image.open(path)
    if im.size == (size, size):
        return None
    if im.size != (SOURCE, SOURCE) or size % SOURCE:
        sys.exit(f"scale_ae2_icons: {path.relative_to(ROOT)} is {im.size[0]} x {im.size[1]}, "
                 f"expected {SOURCE} x {SOURCE} (to scale to {size}) or {size} x {size}")
    src = im.convert("RGBA")
    out = src.resize((size, size), Image.NEAREST)
    k = size // SOURCE
    for y in range(size):                   # every pixel is its source pixel: nothing new
        for x in range(size):
            assert out.getpixel((x, y)) == src.getpixel((x // k, y // k))
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--check", action="store_true", help="change nothing, list the files not at their size")
    a = ap.parse_args()
    todo = []
    for name, size in sorted(SIZES.items()):
        path = GRAPHICS / name
        if not path.is_file():
            sys.exit(f"scale_ae2_icons: ae2-textures/graphics/{name} is missing (import it first)")
        out = scale(path, size)
        if out is not None:
            todo.append((name, size, path, out))
    if a.check:
        for name, size, _, _ in todo:
            print(f"not scaled yet: {name} (to {size} x {size})")
        sys.exit(1 if todo else 0)
    notes = {r["file"]: r["note"] for r in read_manifest()[0]}
    for name, size, path, out in todo:
        out.save(path)
        k = size // SOURCE
        note = (f"{notes.get(name, '').strip()}; scaled from {SOURCE} x {SOURCE} to {size} x {size} (x{k}, nearest "
                "neighbour, no new pixels; saved as RGBA) by tools/scale_ae2_icons.py").lstrip("; ")
        subprocess.run([sys.executable, str(ROOT / "tools" / "import_ae2_textures.py"), "--mark-changed", name,
                        "--note", note], check=True)
    print(f"scaled: {len(todo)}, at their size already: {len(SIZES) - len(todo)}")


if __name__ == "__main__":
    main()
