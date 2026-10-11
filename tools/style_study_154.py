"""Style study of me-network issue #154 (run: python tools/style_study_154.py . docs/graphics-review/style-study-154.png): six things in two routes next to today's pictures.

Route A: simple 3D shapes (boxes and slabs) built from this mod's own textures, rendered in one direction of light: entity sprites
as a block with depth to the east and the south (the look of Gregtorio's machine blocks, its issue #148), item icons as an
isometric cube or slab (the look of Gregtorio's machine icons). Route B: today's top-down tiles, 2x, with a bevel, a contour and a
drop shadow. Everything at 64 px (sprites at scale 0.5 per tile, icons 64 x 64 with mipmaps).
"""
import sys
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(sys.argv[1])
OUT = Path(sys.argv[2])
ENT = ROOT / "graphics/entity/fork/ae2"
ICO = ROOT / "graphics/icons"
S = 64


def load(p):
    return Image.open(p).convert("RGBA")


def up(img, f=2):
    return img.resize((img.width * f, img.height * f), Image.NEAREST)


def shade(img, f):
    px = img.copy().load()
    out = img.copy()
    o = out.load()
    for y in range(img.height):
        for x in range(img.width):
            r, g, b, a = px[x, y]
            o[x, y] = (int(r * f), int(g * f), int(b * f), a)
    return out


def affine_paste(dst, src, p0, u, v):
    """paste `src` so that its (0,0) lands on p0, its x axis along u (for its full width), its y axis along v"""
    w, h = src.size
    # output point q = p0 + (sx / w) * u + (sy / h) * v  ->  solve for (sx, sy)
    det = u[0] * v[1] - u[1] * v[0]
    a = v[1] / det * w
    b = -v[0] / det * w
    d = -u[1] / det * h
    e = u[0] / det * h
    c = -(a * p0[0] + b * p0[1])
    f = -(d * p0[0] + e * p0[1])
    layer = src.transform(dst.size, Image.AFFINE, (a, b, c, d, e, f), resample=Image.NEAREST)
    dst.alpha_composite(layer)


def contour(img, colour=(18, 18, 22, 255)):
    """a one pixel dark outline around everything that is not transparent"""
    a = img.getchannel("A")
    px = a.load()
    out = img.copy()
    o = out.load()
    w, h = img.size
    for y in range(h):
        for x in range(w):
            if px[x, y] == 0:
                for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                    nx, ny = x + dx, y + dy
                    if 0 <= nx < w and 0 <= ny < h and px[nx, ny] > 0:
                        o[x, y] = colour
                        break
    return out


# --- route A ------------------------------------------------------------------------------------------------------
def block_sprite(face, depth=10, side=None):
    """a 64 px tile: the face (54 x 54) top left, the east side and the south side as depth strips (lit from the top left)"""
    side = side or face
    img = Image.new("RGBA", (S, S))
    f = face.resize((S - depth, S - depth), Image.NEAREST)
    edge_e = side.crop((side.width - 3, 0, side.width, side.height)).resize((depth, S - depth), Image.NEAREST)
    edge_s = side.crop((0, side.height - 3, side.width, side.height)).resize((S - depth, depth), Image.NEAREST)
    # sides as parallelograms going down-right
    affine_paste(img, shade(edge_e, 0.72), (S - depth, 0), (depth, depth), (0, S - depth))
    affine_paste(img, shade(edge_s, 0.5), (0, S - depth), (S - depth, 0), (depth, depth))
    img.alpha_composite(f, (0, 0))
    d = ImageDraw.Draw(img)
    d.line((S - depth, 0, S - depth, S - depth), fill=(18, 18, 22, 255))
    d.line((0, S - depth, S - depth, S - depth), fill=(18, 18, 22, 255))
    return contour(img)


def iso_cube(top, front, side, size=S):
    """an isometric cube: top (lit), front (left, medium), side (right, dark)"""
    img = Image.new("RGBA", (size, size))
    w = size // 2 - 2
    cx, top_y = size // 2, 4
    h = w // 2
    edge = int(w * 1.0)
    # top rhombus: from the back corner (cx, top_y)
    affine_paste(img, top, (cx, top_y), (w, h), (-w, h))
    # left face: from (cx - w, top_y + h) along (w, h) and down
    affine_paste(img, shade(front, 0.82), (cx - w, top_y + h), (w, h), (0, edge))
    # right face
    affine_paste(img, shade(side, 0.6), (cx, top_y + 2 * h), (w, -h), (0, edge))
    return contour(img)


def iso_slab(top, front, side, thick=8, size=S):
    """a flat box (a cell, a card) lying on its back, seen from the same corner"""
    img = Image.new("RGBA", (size, size))
    w = size // 2 - 2
    cx, top_y = size // 2, size // 2 - w // 2 - thick // 2
    h = w // 2
    affine_paste(img, shade(front, 0.82), (cx - w, top_y + h), (w, h), (0, thick))
    affine_paste(img, shade(side, 0.6), (cx, top_y + 2 * h), (w, -h), (0, thick))
    affine_paste(img, top, (cx, top_y), (w, h), (-w, h))
    return contour(img)


def strip(img, colour):
    return Image.new("RGBA", img.size, colour)


# --- route B ------------------------------------------------------------------------------------------------------
def bevel(tile):
    """today's tile at 2x with a bevel (light top left, dark bottom right), a contour and a drop shadow"""
    t = up(tile, 2)
    d = ImageDraw.Draw(t)
    for i in range(2):
        d.line((i, i, S - 1 - i, i), fill=(255, 255, 255, 70))
        d.line((i, i, i, S - 1 - i), fill=(255, 255, 255, 70))
        d.line((i, S - 1 - i, S - 1 - i, S - 1 - i), fill=(0, 0, 0, 110))
        d.line((S - 1 - i, i, S - 1 - i, S - 1 - i), fill=(0, 0, 0, 110))
    out = Image.new("RGBA", (S + 6, S + 6))
    shadow = Image.new("RGBA", t.size, (0, 0, 0, 90))
    shadow.putalpha(t.getchannel("A").point(lambda v: 90 if v else 0))
    out.alpha_composite(shadow, (5, 5))
    out.alpha_composite(contour(t), (0, 0))
    return out.resize((S, S), Image.LANCZOS)


# --- the six things -----------------------------------------------------------------------------------------------
def things():
    casing = load(ENT / "me-interface.png")            # MV casing
    top_plain = casing.copy()
    ImageDraw.Draw(top_plain).rectangle((3, 3, 28, 28), fill=(60, 64, 76, 255))
    drive = load(ENT / "me-drive-16k.png")
    iface = load(ENT / "me-interface.png")
    term_off, term_on = load(ENT / "me-terminal-off.png"), load(ENT / "me-terminal-on.png")
    bus = {d: load(ENT / f"me-import-bus-{d}.png") for d in ("north", "east", "south", "west")}
    cell = load(ICO / "fork/me-1k-storage-cell.png")
    card = load(ICO / "fork/me-capacity-card.png")
    rows = []
    rows.append(("ME Drive", drive, load(ICO / "fork/me-drive-16k.png") if (ICO / "fork/me-drive-16k.png").exists() else drive,
                 block_sprite(up(drive, 2), side=up(casing, 2)), iso_cube(up(top_plain, 2), up(drive, 2), up(top_plain, 2)),
                 bevel(drive)))
    rows.append(("ME Interface", iface, iface, block_sprite(up(iface, 2)), iso_cube(up(top_plain, 2), up(iface, 2), up(top_plain, 2)),
                 bevel(iface)))
    rows.append(("ME Terminal (dark)", term_off, load(ICO / "me-terminal.png"), block_sprite(up(term_off, 2), side=up(casing, 2)),
                 iso_cube(up(top_plain, 2), up(term_off, 2), up(top_plain, 2)), bevel(term_off)))
    rows.append(("ME Terminal (lit)", term_on, load(ICO / "me-terminal.png"), block_sprite(up(term_on, 2), side=up(casing, 2)),
                 iso_cube(up(top_plain, 2), up(term_on, 2), up(top_plain, 2)), bevel(term_on)))
    for d in ("north", "east", "south", "west"):
        b = bus[d]
        rows.append((f"Import Bus ({d})", b, load(ICO / "fork/me-import-bus.png"), block_sprite(up(b, 2), depth=6),
                     iso_cube(up(top_plain, 2), up(bus["south"], 2), up(top_plain, 2)), bevel(b)))
    # a cell and a card: items only (no entity): slabs
    cell_body = cell.crop(cell.getbbox())
    rows.append(("Storage Cell (item)", None, cell, None,
                 iso_slab(up(cell_body.resize((32, 32), Image.NEAREST), 2), strip(up(cell, 2), (150, 150, 160, 255)),
                          strip(up(cell, 2), (110, 110, 120, 255)), thick=16), bevel(cell)))
    card_body = card.crop(card.getbbox())
    rows.append(("Capacity Card (item)", None, card, None,
                 iso_slab(up(card_body.resize((32, 32), Image.NEAREST), 2), strip(up(card, 2), (190, 160, 60, 255)),
                          strip(up(card, 2), (130, 110, 40, 255)), thick=4), bevel(card)))
    return rows


def sheet(rows):
    cols = ["today: sprite", "today: icon", "A: sprite", "A: icon", "B: sprite / icon", "A at game size (32 px)", "B at game size"]
    cw, rh, lw = 150, 150, 170
    img = Image.new("RGBA", (lw + cw * len(cols) + 20, 40 + rh * len(rows)), (40, 40, 48, 255))
    d = ImageDraw.Draw(img)
    for i, c in enumerate(cols):
        d.text((lw + i * cw + 6, 12), c, fill=(220, 220, 230, 255))
    for r, (name, sprite, icon, a_sprite, a_icon, b) in enumerate(rows):
        y = 40 + r * rh
        d.text((10, y + 60), name, fill=(220, 220, 230, 255))
        cells = [up(sprite, 4) if sprite else None, up(icon, 4) if icon else None,
                 up(a_sprite, 2) if a_sprite else None, up(a_icon, 2), up(b, 2),
                 (a_sprite or a_icon).resize((32, 32), Image.LANCZOS), b.resize((32, 32), Image.LANCZOS)]
        for i, c in enumerate(cells):
            if c is not None:
                img.alpha_composite(c, (lw + i * cw + (cw - c.width) // 2, y + (rh - c.height) // 2))
    return img


if __name__ == "__main__":
    sheet(things()).save(OUT)
    print(OUT)
