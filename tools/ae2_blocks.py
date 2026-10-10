#!/usr/bin/env python3
"""Makes the block pictures and block icons of the texture mod (issue #260, look B of #236: the whole block from AE2)
from AE2-Unofficial faces imported into ae2-textures/graphics/, in place:

    python tools/ae2_blocks.py            # make what is still a 16 x 16 face, record it with --mark-changed
    python tools/ae2_blocks.py --check    # only say which files are not made yet

* a block picture (64 x 64, the size of me-network's 3D-style sprites): the face (16 px) x3 = 48 px, depth strips of
  9 px to the east and the south made from the face's own last three columns and rows (shaded 0.72 and 0.5, the light
  from the top left as in the 3D style of #154), a contour, the block at (3, 3) of the tile;
* a working strip: the same block once per frame of a light animation (a second texture, imported as its own file and
  added to the strip's row with --add-source), the lights between the hole filling and the face;
* an icon (64 x 64): an isometric cube, the face in front, the face's frame (its inside in the frame's colour) on the
  top and the right side, shaded.

Holes of a face (Minecraft shows the inside of the block there: the drive's bays, the assembler's glass, the chest's
slot) are filled with the face's darkest colour. Everything is made from the AE2 texture(s) of the file's manifest row:
the files are CC BY-NC-SA 3.0 (ae2-textures/README.md); this script reads only from ae2-textures/graphics/ and writes
only into it, and records each made file with `tools/import_ae2_textures.py --mark-changed`. A file imported again
(`--replace`) is a 16 x 16 face again and is made by the next run.
"""
import argparse, subprocess, sys
from pathlib import Path

from PIL import Image, ImageDraw

sys.path.insert(0, str(Path(__file__).resolve().parent))
from ae2_manifest import read_manifest

ROOT = Path(__file__).resolve().parent.parent
GRAPHICS = ROOT / "ae2-textures" / "graphics"
FACE = 16                   # AE2's block faces
TILE = 64                   # me-network's 3D-style sprites and icons
K = 3                       # face scale: 48 px
DEPTH = 9                   # px of the depth strips (three face pixels)
AT = 3                      # where the 57 px block (and its contour) sits in the tile
CONTOUR = (18, 18, 22, 255)
RING = 2                    # face pixels of the frame an icon's top and side keep

BLOCKS = ("me-drive", "me-chest", "me-interface", "me-molecular-assembler-idle", "me-cell-workbench", "me-charger")
ICONS = ("me-drive", "me-chest", "me-interface", "me-molecular-assembler", "me-cell-workbench", "me-charger")
# file inside ae2-textures/graphics/ -> what it becomes (and, for a strip, the file of its lights and their frames)
MAKE = {
    **{f"blocks/{b}.png": ("block",) for b in BLOCKS},
    "blocks/me-molecular-assembler-working.png": ("strip", "blocks/lights/me-molecular-assembler-lights.png", 12),
    **{f"icons/blocks/{i}.png": ("icon",) for i in ICONS},
}


def luminance(c):
    return 0.299 * c[0] + 0.587 * c[1] + 0.114 * c[2]


def filled(face):
    """the face with its holes (transparent or see-through pixels) on its darkest colour"""
    pixels = face.get_flattened_data() if hasattr(face, "get_flattened_data") else face.getdata()   # (Pillow 14)
    opaque = [p for p in pixels if p[3] == 255]
    dark = min(opaque, key=luminance)
    out = Image.new("RGBA", face.size, dark)
    out.alpha_composite(face)
    return out


def shade(img, f):
    out = img.copy()
    px = out.load()
    for y in range(out.height):
        for x in range(out.width):
            r, g, b, a = px[x, y]
            px[x, y] = (int(r * f), int(g * f), int(b * f), a)
    return out


def affine(dst, src, p0, u, v):
    """paste `src` so that its top left lands on p0, its width along u, its height along v (nearest neighbour)"""
    w, h = src.size
    det = u[0] * v[1] - u[1] * v[0]
    a, b = v[1] / det * w, -v[0] / det * w
    d, e = -u[1] / det * h, u[0] / det * h
    dst.alpha_composite(src.transform(dst.size, Image.AFFINE,
                                      (a, b, -(a * p0[0] + b * p0[1]), d, e, -(d * p0[0] + e * p0[1])), resample=Image.NEAREST))


def contour(img):
    """a one pixel contour around everything that is not transparent"""
    alpha = img.getchannel("A").load()
    out = img.copy()
    o = out.load()
    w, h = img.size
    for y in range(h):
        for x in range(w):
            if alpha[x, y] == 0:
                for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                    nx, ny = x + dx, y + dy
                    if 0 <= nx < w and 0 <= ny < h and alpha[nx, ny] > 0:
                        o[x, y] = CONTOUR
                        break
    return out


def block(face):
    """a 64 x 64 block picture from an opaque 16 x 16 face"""
    size = FACE * K
    f = face.resize((size, size), Image.NEAREST)
    img = Image.new("RGBA", (size + DEPTH, size + DEPTH))
    edge_e = f.crop((size - DEPTH, 0, size, size))
    edge_s = f.crop((0, size - DEPTH, size, size))
    affine(img, shade(edge_e, 0.72), (size, 0), (DEPTH, DEPTH), (0, size))
    affine(img, shade(edge_s, 0.5), (0, size), (size, 0), (DEPTH, DEPTH))
    img.alpha_composite(f, (0, 0))
    d = ImageDraw.Draw(img)
    d.line((size, 0, size, size), fill=CONTOUR)
    d.line((0, size, size, size), fill=CONTOUR)
    out = Image.new("RGBA", (TILE, TILE))
    out.alpha_composite(img, (AT, AT))
    return contour(out)


def frame_only(face):
    """the face's frame: its inside in the frame's most common colour"""
    out = face.copy()
    px = out.load()
    ring = {}
    for y in range(FACE):
        for x in range(FACE):
            if min(x, y, FACE - 1 - x, FACE - 1 - y) < RING:
                ring[px[x, y]] = ring.get(px[x, y], 0) + 1
    colour = max(ring, key=ring.get)
    ImageDraw.Draw(out).rectangle((RING, RING, FACE - 1 - RING, FACE - 1 - RING), fill=colour)
    return out


def icon(face):
    """a 64 x 64 isometric cube: the face in front (left), its frame on the top and the right side"""
    img = Image.new("RGBA", (TILE, TILE))
    top = frame_only(face).resize((2 * FACE, 2 * FACE), Image.NEAREST)
    front = face.resize((2 * FACE, 2 * FACE), Image.NEAREST)
    w, h = TILE // 2 - 2, (TILE // 2 - 2) // 2
    cx, y0 = TILE // 2, 4
    affine(img, top, (cx, y0), (w, h), (-w, h))
    affine(img, shade(front, 0.85), (cx - w, y0 + h), (w, h), (0, w))
    affine(img, shade(top, 0.6), (cx, y0 + 2 * h), (w, -h), (0, w))
    return contour(img)


def strip(face, lights, frames):
    """one block picture per frame of `lights` (frames of 16 x 16 below each other), stacked: the face's holes filled,
    the lights over the filling, the face over the lights"""
    out = Image.new("RGBA", (TILE, TILE * frames))
    base = filled(face)
    for i in range(frames):
        f = base.copy()
        f.alpha_composite(lights.crop((0, FACE * i, FACE, FACE * (i + 1))))
        f.alpha_composite(face)
        out.alpha_composite(block(f), (0, TILE * i))
    return out


def make(name, how):
    """the made image of `name`, or None when it is made already (not a 16 x 16 face any more)"""
    path = GRAPHICS / name
    face = Image.open(path).convert("RGBA")
    if face.size != (FACE, FACE):
        return None, None
    if how[0] == "block":
        return block(filled(face)), "block picture: the face (holes filled with its darkest colour) x3 with depth strips " \
            "of its last three columns and rows (shaded 0.72 / 0.5) and a contour, 64 x 64"
    if how[0] == "icon":
        return icon(filled(face)), "icon: an isometric cube of the face (holes filled with its darkest colour), its frame " \
            "on the top and the right side (inside in the frame's colour), shaded, a contour, 64 x 64"
    lights = Image.open(GRAPHICS / how[1]).convert("RGBA")
    if lights.size != (FACE, FACE * how[2]):
        sys.exit(f"ae2_blocks: ae2-textures/graphics/{how[1]} is {lights.size[0]} x {lights.size[1]}, "
                 f"expected {FACE} x {FACE * how[2]}")
    return strip(face, lights, how[2]), (f"working strip: {how[2]} block pictures (64 x 64, below each other) of the "
                                        "face with the frames of its light animation (the second source) between the "
                                        "hole filling and the face, x3, depth strips, a contour")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--check", action="store_true", help="change nothing, list the files not made yet")
    a = ap.parse_args()
    todo = []
    for name, how in sorted(MAKE.items()):
        if not (GRAPHICS / name).is_file():
            sys.exit(f"ae2_blocks: ae2-textures/graphics/{name} is missing (import it first)")
        img, what = make(name, how)
        if img is not None:
            todo.append((name, img, what))
    if a.check:
        for name, _, _ in todo:
            print(f"not made yet: {name}")
        sys.exit(1 if todo else 0)
    notes = {r["file"]: r["note"] for r in read_manifest()[0]}
    for name, img, what in todo:
        img.save(GRAPHICS / name)
        note = f"{notes.get(name, '').strip()}; made by tools/ae2_blocks.py: {what}".lstrip("; ")
        subprocess.run([sys.executable, str(ROOT / "tools" / "import_ae2_textures.py"), "--mark-changed", name,
                        "--note", note], check=True)
    print(f"made: {len(todo)}, made already: {len(MAKE) - len(todo)}")


if __name__ == "__main__":
    main()
