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
* a 2 x 2 block (issue #278, the ME Controller: 128 x 128, a picture or a strip): four copies of the face side by side,
  each x3 as above, depth strips of 18 px, the block at (6, 6): a block of the first kind at twice the size, with
  AE2's pixels at the size of the others (a 2 x 2 cluster of AE2 controllers, none of them a column or inside block);
* an icon (64 x 64): an isometric cube, the face in front, the face's frame (its inside in the frame's colour) on the
  top and the right side, shaded;
* a panel (issue #281, the ME Terminal and the ME Pattern Terminal): AE2 draws a terminal as a 12 x 12 plate on the
  cable (AbstractPartDisplay: bounds 2..14), so the plate of its 16 px front x3 (36 px) with depth strips of 6 px (the
  plate is two AE2 pixels thick), centred in the 64 px tile; dark (the frame, its inside on the frame's darkest colour) or
  lit (AE2's three screen layers over it, tinted in the Fluix colours of AEColor.Transparent: Bright with the white
  variant, Dark with the medium one, Colored with the black one, each imported as its own file and added to the row with
  --add-source); a sheet of both side by side for an entity with two variations; and as an icon a slab of the lit plate;
* a crafting block sheet (issue #302, the blocks of a Crafting CPU, as single AE2 cubes): ME Network's 48 variations
  side by side (64 px each, 1 + mask + 16 * state, its issue #152): state 0 (no CPU) the block picture of the face,
  states 1 and 2 (a CPU, one that runs a job) the block picture of AE2's formed look, its layers over each other (the
  formed unit `BlockCraftingUnitFit` and the block's `*Fit` overlay; the monitor's outer frame and its three screen
  layers tinted in the Fluix colours like the terminal's). The mask (the sides that touch the CPU) does not change the
  cube: AE2 draws every block of a CPU as a cube of its own;
* a cable sheet (issue #283): AE2's Fluix glass cable (PartCable: 4 AE2 pixels thick, x3 = 12 px) as the 16 variations
  of me-network's cable (its connections: north 1, east 2, south 4, west 8), side by side, 64 px each: an arm to every
  connected side made of the texture's middle band (rows 6..9, x3) from the tile's edge, so the band runs on into the
  next tile's arm (its 48 px repeat), a hub of the texture's middle (6..9 x 6..9, x3) in the tile's middle; lying on the
  ground: a shadow two pixels to the south-east and a contour; the icon is the crossing (variation 15);
* a cell piece (issue #264): a rectangle of AE2's cell textures (MEStorageCellTextures.png), mirrored as AE2 draws it on
  a block's front, x3: the cell that me-network draws in a drive bay or the chest's slot (its drive view).

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

BLOCKS = ("me-drive", "me-chest", "me-interface", "me-molecular-assembler-idle", "me-cell-workbench", "me-charger",
          "me-pattern-provider",                                                          # (issue #269)
          "me-import-bus", "me-export-bus", "me-storage-bus")                             # (issue #282: AE2's fronts)
ICONS = ("me-drive", "me-chest", "me-interface", "me-molecular-assembler", "me-cell-workbench", "me-charger",
         "me-pattern-provider", "me-import-bus", "me-export-bus", "me-storage-bus")
# issue #264: the pieces of MEStorageCellTextures.png (16 x 16: bands of 4 rows for item, fluid, essentia and no cell, two
# copies side by side) that AE2-Unofficial draws in a bay: RenderDrive.java (u 1..6, v 1..3 of a band: 5 x 2 px),
# RenderMEChest.java (u 9..15, v 0..3: 6 x 3 px); both mirrored on the front, so the transparent pixel is where the light is
CELL_PIECES = {
    "blocks/cells/drive-cell-item.png": (1, 1, 6, 3),
    "blocks/cells/drive-cell-fluid.png": (1, 5, 6, 7),
    "blocks/cells/chest-cell-item.png": (9, 0, 15, 3),
    "blocks/cells/chest-cell-fluid.png": (9, 4, 15, 7),
}
# issue #281: a terminal's three screen layers (blocks/lights/), and their tints: AEColor.Transparent (Fluix) whiteVariant,
# mediumVariant, blackVariant, as AbstractPartDisplay.renderStatic draws Bright, Dark and Colored
SCREEN_TINTS = ((0xD7, 0xBB, 0xEC), (0x89, 0x5C, 0xA8), (0x1B, 0x23, 0x44))
SCREENS = {
    "terminal": tuple(f"blocks/lights/me-terminal-screen-{n}.png" for n in ("bright", "dark", "colored")),
    "pattern-terminal": tuple(f"blocks/lights/me-pattern-terminal-screen-{n}.png" for n in ("bright", "dark", "colored")),
}
PLATE = (2, 2, 14, 14)      # the plate of a part's 16 px front
PANEL_DEPTH = 6
# issue #302: the crafting blocks: me-network's name -> the layers of AE2's formed look over each other (blocks/lights/
# files, each with the tint it is drawn in, or None)
CPU_FIT = "blocks/lights/crafting-unit-fit.png"
CRAFTING = {
    "me-crafting-unit": [(CPU_FIT, None)],
    "me-crafting-co-processing-unit": [(CPU_FIT, None), ("blocks/lights/crafting-accelerator-fit.png", None)],
    **{f"me-{t}-crafting-storage": [(CPU_FIT, None), (f"blocks/lights/crafting-storage-{t}-fit.png", None)]
       for t in ("1k", "4k", "16k", "64k", "256k")},
    "me-crafting-monitor": [("blocks/lights/crafting-monitor-outer.png", None),
                            ("blocks/lights/crafting-monitor-fit-light.png", SCREEN_TINTS[0]),
                            ("blocks/lights/crafting-monitor-fit-medium.png", SCREEN_TINTS[1]),
                            ("blocks/lights/crafting-monitor-fit-dark.png", SCREEN_TINTS[2])],
}
# file inside ae2-textures/graphics/ -> what it becomes (and, for a strip, the file of its lights and their frames; a
# block or strip of 2 x 2 tiles names the size last)
MAKE = {
    **{f"blocks/{b}.png": ("block",) for b in BLOCKS},
    "blocks/me-molecular-assembler-working.png": ("strip", "blocks/lights/me-molecular-assembler-lights.png", 12),
    # issue #278: the ME Controller dark (its picture), lit (the lights) and in a conflict (AE2's red over the powered face)
    "blocks/me-controller.png": ("block", 2),
    "blocks/me-controller-on.png": ("strip", "blocks/lights/me-controller-lights.png", 12, 2),
    "blocks/me-controller-conflict.png": ("strip", "blocks/lights/me-controller-conflict.png", 1, 2),
    "icons/blocks/me-controller.png": ("icon",),
    # issue #281: the terminals (the lamp's picture and its two screens; the pattern terminal's two variations)
    "blocks/me-terminal-off.png": ("panel", None),
    "blocks/me-terminal-lit.png": ("panel", "terminal"),
    "blocks/me-pattern-terminal.png": ("panel-sheet", "pattern-terminal"),
    "icons/blocks/me-terminal.png": ("panel-icon", "terminal"),
    "icons/blocks/me-pattern-terminal.png": ("panel-icon", "pattern-terminal"),
    # issue #283: the cable (me-cable.png's 16 variations) and its icon (the crossing)
    "blocks/me-cable.png": ("cable-sheet",),
    "icons/blocks/me-cable.png": ("cable-icon",),
    # issue #302: the crafting blocks and their icons (AE2 cubes of the face without a CPU)
    **{f"blocks/crafting/{b}.png": ("crafting-sheet", b) for b in CRAFTING},
    **{f"icons/blocks/{b}.png": ("icon",) for b in CRAFTING},
    **{f"icons/blocks/{i}.png": ("icon",) for i in ICONS},
    **{f: ("piece", box) for f, box in CELL_PIECES.items()},
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


def block(face, n=1):
    """a 64 x 64 block picture from an opaque 16 x 16 face; with n = 2 one of 128 x 128 (2 x 2 tiles) from four copies of
    it, the depth and the place doubled"""
    one = FACE * K
    size, depth = one * n, DEPTH * n
    f = Image.new("RGBA", (size, size))
    for y in range(n):
        for x in range(n):
            f.alpha_composite(face.resize((one, one), Image.NEAREST), (one * x, one * y))
    img = Image.new("RGBA", (size + depth, size + depth))
    edge_e = f.crop((size - depth, 0, size, size))
    edge_s = f.crop((0, size - depth, size, size))
    affine(img, shade(edge_e, 0.72), (size, 0), (depth, depth), (0, size))
    affine(img, shade(edge_s, 0.5), (0, size), (size, 0), (depth, depth))
    img.alpha_composite(f, (0, 0))
    d = ImageDraw.Draw(img)
    d.line((size, 0, size, size), fill=CONTOUR)
    d.line((0, size, size, size), fill=CONTOUR)
    out = Image.new("RGBA", (TILE * n, TILE * n))
    out.alpha_composite(img, (AT * n, AT * n))
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


def strip(face, lights, frames, n=1):
    """one block picture per frame of `lights` (frames of 16 x 16 below each other), stacked: the face's holes filled,
    the lights over the filling, the face over the lights (n: the block's tiles per side)"""
    t = TILE * n
    out = Image.new("RGBA", (t, t * frames))
    base = filled(face)
    for i in range(frames):
        f = base.copy()
        f.alpha_composite(lights.crop((0, FACE * i, FACE, FACE * (i + 1))))
        f.alpha_composite(face)
        out.alpha_composite(block(f, n), (0, t * i))
    return out


def tint(img, c):
    """multiplies the colour of every pixel by `c` (as Minecraft's Tessellator colour does)"""
    out = img.copy()
    px = out.load()
    for y in range(out.height):
        for x in range(out.width):
            r, g, b, a = px[x, y]
            if a:
                px[x, y] = (r * c[0] // 255, g * c[1] // 255, b * c[2] // 255, a)
    return out


def screen(face, layers):
    """a terminal's 16 px front: the frame, its inside on the frame's darkest colour, with `layers` (Bright, Dark,
    Colored) tinted over it; without layers dark"""
    f = filled(face)
    for img, c in zip(layers or (), SCREEN_TINTS):
        f.alpha_composite(tint(img, c))
    return f


def panel(front):
    """a 64 x 64 picture of a part's plate (PLATE of its 16 px front) x3 with depth strips, centred"""
    size = (PLATE[2] - PLATE[0]) * K
    f = front.crop(PLATE).resize((size, size), Image.NEAREST)
    img = Image.new("RGBA", (size + PANEL_DEPTH, size + PANEL_DEPTH))
    affine(img, shade(f.crop((size - PANEL_DEPTH, 0, size, size)), 0.72), (size, 0), (PANEL_DEPTH, PANEL_DEPTH), (0, size))
    affine(img, shade(f.crop((0, size - PANEL_DEPTH, size, size)), 0.5), (0, size), (size, 0), (PANEL_DEPTH, PANEL_DEPTH))
    img.alpha_composite(f, (0, 0))
    d = ImageDraw.Draw(img)
    d.line((size, 0, size, size), fill=CONTOUR)
    d.line((0, size, size, size), fill=CONTOUR)
    out = Image.new("RGBA", (TILE, TILE))
    at = (TILE - size - PANEL_DEPTH) // 2
    out.alpha_composite(img, (at, at))
    return contour(out)


def slab(front):
    """a 64 x 64 icon: the plate (PLATE of the 16 px front) upright, seen from the front left, a third of its width
    deep: the front, and the frame's colour on the top and the right side, shaded"""
    plate = front.crop(PLATE)
    w = 36                                    # the front's width; its slant h = w / 2
    h, t = w // 2, 6                          # t: the depth (x) of the top and the side, rising t / 2
    big = plate.resize((plate.width * 3, plate.height * 3), Image.NEAREST)
    edge = frame_colour(plate)
    img = Image.new("RGBA", (TILE, TILE))
    x0 = (TILE - w - t) // 2
    y0 = (TILE - (h + w + t // 2)) // 2 + t // 2
    side = Image.new("RGBA", (8, 8), edge)
    affine(img, side, (x0 + t, y0 - t // 2), (w, h), (-t, t // 2))                 # the top
    affine(img, shade(side, 0.6), (x0 + w, y0 + h), (t, -t // 2), (0, w))          # the right side
    affine(img, shade(big, 0.92), (x0, y0), (w, h), (0, w))                        # the front
    return contour(img)


CABLE_AT = (TILE - 4 * K) // 2           # the hub's (and the arms') top left: 26 of 64
CABLE_SHADOW = 70


def cable(glass, bits):
    """one 64 x 64 variation of the cable: an arm to every side whose bit is set (north 1, east 2, south 4, west 8) and
    the hub, lying on the ground"""
    thick, c = 4 * K, CABLE_AT
    band_h = glass.crop((0, 6, FACE, 10)).resize((FACE * K, thick), Image.NEAREST)        # 48 x 12, west to east
    band_v = glass.crop((6, 0, 10, FACE)).resize((thick, FACE * K), Image.NEAREST)        # 12 x 48, north to south
    arm = c                                                                                 # 26 px from the edge
    o = Image.new("RGBA", (TILE, TILE))
    if bits & 1:
        o.alpha_composite(band_v.crop((0, 0, thick, arm)), (c, 0))
    if bits & 4:
        o.alpha_composite(band_v.crop((0, FACE * K - arm, thick, FACE * K)), (c, TILE - arm))
    if bits & 8:
        o.alpha_composite(band_h.crop((0, 0, arm, thick)), (0, c))
    if bits & 2:
        o.alpha_composite(band_h.crop((FACE * K - arm, 0, FACE * K, thick)), (TILE - arm, c))
    o.alpha_composite(glass.crop((6, 6, 10, 10)).resize((thick, thick), Image.NEAREST), (c, c))
    out = Image.new("RGBA", (TILE, TILE))
    shadow = Image.new("RGBA", (TILE, TILE), (0, 0, 0, 0))
    shadow.putalpha(o.getchannel("A").point(lambda v: CABLE_SHADOW if v else 0))
    out.alpha_composite(shadow, (2, 2))
    out.alpha_composite(contour(o))
    return out


def frame_colour(img):
    """the most common opaque colour of the outermost ring"""
    px = img.load()
    ring = {}
    for y in range(img.height):
        for x in range(img.width):
            if min(x, y, img.width - 1 - x, img.height - 1 - y) == 0 and px[x, y][3] == 255:
                ring[px[x, y]] = ring.get(px[x, y], 0) + 1
    return max(ring, key=ring.get)


def make(name, how):
    """the made image of `name`, or None when it is made already (not a 16 x 16 face any more)"""
    path = GRAPHICS / name
    face = Image.open(path).convert("RGBA")
    if face.size != (FACE, FACE):
        return None, None
    if how[0] == "block" and len(how) > 1:
        return block(filled(face), how[1]), "2 x 2 block picture: four copies of the face side by side, each x3, with " \
            "depth strips of their last six columns and rows (shaded 0.72 / 0.5) and a contour, 128 x 128"
    if how[0] == "block":
        return block(filled(face)), "block picture: the face (holes filled with its darkest colour) x3 with depth strips " \
            "of its last three columns and rows (shaded 0.72 / 0.5) and a contour, 64 x 64"
    if how[0] == "piece":
        x0, y0, x1, y1 = how[1]
        piece = face.crop((x0, y0, x1, y1)).transpose(Image.FLIP_LEFT_RIGHT)
        return piece.resize((piece.width * K, piece.height * K), Image.NEAREST), \
            f"cell piece: x {x0}..{x1 - 1}, y {y0}..{y1 - 1} of the texture, mirrored (as AE2 draws it on a front), x3"
    if how[0] == "crafting-sheet":
        formed = None
        for f, tint_of in CRAFTING[how[1]]:
            layer = Image.open(GRAPHICS / f).convert("RGBA")
            if layer.size != (FACE, FACE):
                sys.exit(f"ae2_blocks: ae2-textures/graphics/{f} is {layer.size[0]} x {layer.size[1]}, expected {FACE} x {FACE}")
            layer = tint(layer, tint_of) if tint_of else layer
            if formed is None:
                formed = layer.copy()
            else:
                formed.alpha_composite(layer)
        lone, cpu = block(filled(face)), block(filled(formed))
        out = Image.new("RGBA", (48 * TILE, TILE))
        for v in range(48):
            out.alpha_composite(lone if v < 16 else cpu, (v * TILE, 0))
        tinted = " (the screen layers tinted #D7BBEC, #895CA8, #1B2344)" if how[1] == "me-crafting-monitor" else ""
        return out, ("crafting block sheet: 48 block pictures (64 x 64, side by side, ME Network's variations 1 + mask + 16 * "
                     "state): 1..16 the face (holes filled with its darkest colour) x3 with depth strips and a contour, "
                     f"17..48 the same of AE2's formed look (the further sources over each other{tinted})")
    if how[0] == "cable-sheet":
        out = Image.new("RGBA", (16 * TILE, TILE))
        for bits in range(16):
            out.alpha_composite(cable(face, bits), (bits * TILE, 0))
        return out, ("cable sheet: the 16 variations of ME Network's cable (connections north 1, east 2, south 4, west 8), "
                     "64 x 64 each side by side: arms of the texture's middle band (rows 6..9, x3: 12 px) from the tile's "
                     "edge, a hub of its middle (6..9 x 6..9, x3), a contour and a shadow two pixels to the south-east")
    if how[0] == "cable-icon":
        return cable(face, 15), ("icon: the cable's crossing (variation 15 of the cable sheet: four arms of the texture's "
                                 "middle band and its hub, x3, a contour and a shadow), 64 x 64")
    if how[0].startswith("panel"):
        layers = None
        if how[1]:
            layers = []
            for f in SCREENS[how[1]]:
                img = Image.open(GRAPHICS / f).convert("RGBA")
                if img.size != (FACE, FACE):
                    sys.exit(f"ae2_blocks: ae2-textures/graphics/{f} is {img.size[0]} x {img.size[1]}, expected {FACE} x {FACE}")
                layers.append(img)
        tints = "Bright, Dark, Colored tinted #D7BBEC, #895CA8, #1B2344 (AE2's Fluix colours)"
        if how[0] == "panel-icon":
            return slab(screen(face, layers)), ("icon: the lit plate (x 2..13, y 2..13 of the frame, its inside on the "
                                                f"frame's darkest colour, the screen layers {tints}) as an upright slab "
                                                "seen from the front left, the frame's colour on the top and the side, "
                                                "shaded, a contour, 64 x 64")
        if how[0] == "panel-sheet":
            out = Image.new("RGBA", (2 * TILE, TILE))
            out.alpha_composite(panel(screen(face, None)), (0, 0))
            out.alpha_composite(panel(screen(face, layers)), (TILE, 0))
            return out, ("panel sheet: dark (the plate x 2..13, y 2..13 of the frame, its inside on the frame's darkest "
                         f"colour) and lit (the screen layers {tints} over it), each x3 with depth strips of 6 px and a "
                         "contour, centred in 64 x 64, side by side")
        if layers:
            return panel(screen(face, layers)), ("lit panel: the plate x 2..13, y 2..13 of the frame, its inside on the "
                                                 f"frame's darkest colour, the screen layers {tints}, x3 with depth "
                                                 "strips of 6 px and a contour, centred in 64 x 64")
        return panel(screen(face, None)), ("dark panel: the plate x 2..13, y 2..13 of the frame, its inside on the "
                                           "frame's darkest colour, x3 with depth strips of 6 px and a contour, centred "
                                           "in 64 x 64")
    if how[0] == "icon":
        return icon(filled(face)), "icon: an isometric cube of the face (holes filled with its darkest colour), its frame " \
            "on the top and the right side (inside in the frame's colour), shaded, a contour, 64 x 64"
    lights = Image.open(GRAPHICS / how[1]).convert("RGBA")
    if lights.size != (FACE, FACE * how[2]):
        sys.exit(f"ae2_blocks: ae2-textures/graphics/{how[1]} is {lights.size[0]} x {lights.size[1]}, "
                 f"expected {FACE} x {FACE * how[2]}")
    n = how[3] if len(how) > 3 else 1
    if n > 1:
        return strip(face, lights, how[2], n), (f"2 x 2 strip: {how[2]} block picture(s) ({TILE * n} x {TILE * n}, below "
                                               "each other) of four copies of the face with the frame(s) of the second "
                                               "source between the hole filling and the face, each x3, depth strips, a "
                                               "contour")
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
