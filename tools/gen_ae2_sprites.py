#!/usr/bin/env python3
"""Generates the sprites and icons for the ME network (prototypes/120-fork-ae2.lua).

Sources:
  * GregTech 5 machine casings and screen overlays from a checkout of
    GTNewHorizons/GT5-Unofficial (LGPL-3.0), tinted with the GT material color of the tier
  * existing Gregtorio icons (ME drive, storage housing)
  * everything else (drive bays, cell LEDs, interface arrows) is drawn here with Pillow

    python tools/gen_ae2_sprites.py --gt C:/00_Repositories/GT5-Unofficial

Output:
  graphics/entity/fork/ae2/*.png           entity sprites (32 px per tile, like the rest of Gregtorio)
  graphics/icons/fork/me-*.png             32x32 item icons
  graphics/technology/fork/me-*.png        256x256 technology icons
"""
import argparse
from pathlib import Path
from PIL import Image, ImageDraw

from gen_sprites import frames_of, gt_path, load, tint
from gen_tech_icons import upscale

ROOT = Path(__file__).resolve().parent.parent
ICONS = ROOT / "graphics/icons"
OUT_ENTITY = ROOT / "graphics/entity/fork/ae2"
OUT_ICON = ROOT / "graphics/icons/fork"
OUT_TECH = ROOT / "graphics/technology/fork"

TILE = 32
GT_PX = 16                     # GT textures are 16x16, scaled 2x to one Factorio tile

# GT material color of the machine hull per voltage tier
HULL_TINT = {"MV": (170, 210, 245), "EV": (220, 170, 240), "IV": (100, 100, 160)}

# storage cell tier -> (LED color, hull tier of the drive that holds four of them)
CELLS = {
    "1k": ((235, 235, 235), "MV"),
    "4k": ((245, 215, 70), "MV"),
    "16k": ((95, 225, 95), "MV"),
    "64k": ((70, 205, 245), "EV"),
    "256k": ((225, 95, 245), "IV"),
}
FLUIX = (150, 95, 225)
FLUIX_LIGHT = (120, 175, 255)
BAY = (32, 32, 38)
HOUSING = (140, 140, 150)


def hull(gt, tier):
    """16x16 GT machine side casing in the tier's material color."""
    return tint(load(gt_path(gt, f"gregtech:iconsets/MACHINE_{tier}_SIDE")), HULL_TINT[tier])


def up(img, factor=2):
    return img.resize((img.width * factor, img.height * factor), Image.NEAREST)


def drive_face(led):
    """16x16 overlay: 2x2 bays, each holding a storage cell with a status LED."""
    face = Image.new("RGBA", (GT_PX, GT_PX))
    d = ImageDraw.Draw(face)
    d.rectangle((2, 2, 13, 13), fill=(20, 20, 24, 255))
    for bx, by in ((3, 3), (8, 3), (3, 8), (8, 8)):
        d.rectangle((bx, by, bx + 4, by + 4), fill=BAY + (255,))
        d.rectangle((bx + 1, by + 1, bx + 3, by + 3), fill=HOUSING + (255,))
        d.point((bx + 2, by + 2), fill=led + (255,))
    return face


def drive_sprite(gt, cell):
    led, tier = CELLS[cell]
    img = hull(gt, tier)
    img.alpha_composite(drive_face(led))
    return up(img)


def interface_sprite(gt):
    img = hull(gt, "MV")
    d = ImageDraw.Draw(img)
    d.rectangle((3, 3, 12, 12), fill=(20, 20, 24, 255))
    d.rectangle((4, 4, 11, 11), outline=FLUIX + (255,))
    # import arrow (left, pointing in) and export arrow (right, pointing out)
    for x, y in ((5, 6), (6, 7), (5, 8)):
        d.point((x, y), fill=FLUIX_LIGHT + (255,))
    for x, y in ((9, 6), (10, 7), (9, 8)):
        d.point((x, y), fill=FLUIX + (255,))
    d.line((7, 7, 8, 7), fill=(235, 235, 255, 255))
    return up(img)


def terminal_sprites(gt):
    """Off picture (casing + dark screen) and the lit screen drawn on top when powered."""
    off = hull(gt, "MV")
    off.alpha_composite(frames_of(load(gt_path(gt, "gregtech:iconsets/SCREEN_OFF")))[0])
    screen = frames_of(load(gt_path(gt, "gregtech:iconsets/OVERLAY_SCREEN")))[0]
    lit = tint(screen.copy(), (200, 160, 255))
    return up(off), up(lit)


def controller_sprite(gt):
    """2x2 tiles: MV casing ring around a fluix-tinted GT computer core."""
    tile = up(hull(gt, "MV"))
    img = Image.new("RGBA", (2 * TILE, 2 * TILE))
    for x in range(2):
        for y in range(2):
            img.paste(tile, (x * TILE, y * TILE))
    core = frames_of(load(gt_path(gt, "gregtech:iconsets/EM_COMPUTER_ACTIVE")))[0]
    core = up(tint(core, (215, 170, 255)))
    img.alpha_composite(core, (TILE // 2, TILE // 2))
    d = ImageDraw.Draw(img)
    d.rectangle((TILE // 2 - 2, TILE // 2 - 2, TILE * 3 // 2 + 1, TILE * 3 // 2 + 1), outline=FLUIX + (255,), width=2)
    for cx, cy in ((4, 4), (2 * TILE - 6, 4), (4, 2 * TILE - 6), (2 * TILE - 6, 2 * TILE - 6)):
        d.rectangle((cx, cy, cx + 1, cy + 1), fill=FLUIX_LIGHT + (255,))
    return img


def cell_icon(cell):
    """Storage housing icon, the component window and the status LED in the tier color."""
    led, _ = CELLS[cell]
    img = load(ICONS / "basic-storage-housing.png")
    px = img.load()
    for y in range(img.height):
        for x in range(img.width):
            r, g, b, a = px[x, y]
            if not a:
                continue
            if r > 150 and g < 90 and b < 90:                     # red LED
                px[x, y] = led + (a,)
            elif max(r, g, b) < 40 and 9 <= x <= 22 and 9 <= y <= 22:   # dark component window
                px[x, y] = (led[0] * 2 // 3, led[1] * 2 // 3, led[2] * 2 // 3, a)
    return img


def drive_icon(cell):
    img = load(ICONS / "me-drive.png")
    badge = cell_icon(cell).resize((20, 20), Image.NEAREST)
    img.alpha_composite(badge, (12, 12))
    return img


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--gt", type=Path, required=True, help="path to the GT5-Unofficial checkout")
    a = ap.parse_args()
    for d in (OUT_ENTITY, OUT_ICON, OUT_TECH):
        d.mkdir(parents=True, exist_ok=True)

    for cell in CELLS:
        drive_sprite(a.gt, cell).save(OUT_ENTITY / f"me-drive-{cell}.png")
        cell_icon(cell).save(OUT_ICON / f"me-{cell}-storage-cell.png")
        drive_icon(cell).save(OUT_ICON / f"me-drive-{cell}.png")
    interface_sprite(a.gt).save(OUT_ENTITY / "me-interface.png")
    off, lit = terminal_sprites(a.gt)
    off.save(OUT_ENTITY / "me-terminal-off.png")
    lit.save(OUT_ENTITY / "me-terminal-on.png")
    controller_sprite(a.gt).save(OUT_ENTITY / "me-controller.png")

    for tech, icon in (("me-network", "me-drive-16k"), ("me-storage-64k", "me-drive-64k"),
                       ("me-storage-256k", "me-drive-256k")):
        upscale(load(OUT_ICON / f"{icon}.png")).save(OUT_TECH / f"{tech}.png")
    print("ME sprites:", len(list(OUT_ENTITY.glob("*.png"))))


if __name__ == "__main__":
    main()
