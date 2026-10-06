#!/usr/bin/env python3
"""Generates the sprites and icons for the ME network (prototypes/network.lua).

Sources:
  * GregTech 5 machine casings and screen overlays from a checkout of
    GTNewHorizons/GT5-Unofficial (LGPL-3.0), tinted with the GT material color of the tier; for the upgrade
    cards its circuit boards, circuits, an SMD chip and the signs of its machine GUI buttons (--cards)
  * existing icons of this mod (ME drive, storage housing; drawn for Gregtorio, where this network was made)
  * everything else (drive bays, cell LEDs, interface arrows) is drawn here with Pillow
  * the fluid variants (prototypes/fluids.lua) are derived from the item PNGs
    generated here: the same shapes with blue accents instead of fluix purple

    python tools/gen_ae2_sprites.py --gt C:/00_Repositories/GT5-Unofficial   # everything
    python tools/gen_ae2_sprites.py --fluids      # only the fluid graphics, from the existing item PNGs
    python tools/gen_ae2_sprites.py --extras      # only the issue #38 graphics, from the existing PNGs
    python tools/gen_ae2_sprites.py --r1          # only the issue #68 (R1) graphics, from the existing PNGs
    python tools/gen_ae2_sprites.py --r2          # only the issue #68 (R2) fluid bus graphics, from the R1 PNGs
    python tools/gen_ae2_sprites.py --underground # only the ME Underground Cable
    python tools/gen_ae2_sprites.py --storage-bus # only the ME Storage Bus, from the R1 PNGs
    python tools/gen_ae2_sprites.py --fluid-storage-bus # only the ME Fluid Storage Bus, from the R1 PNGs
    python tools/gen_ae2_sprites.py --patterns    # only the blank and encoded pattern icons (issue #80)
    python tools/gen_ae2_sprites.py --unified     # only the ME Interface with its four pipe sides (me-network issue #3)
    python tools/gen_ae2_sprites.py --cards C:/00_Repositories/GT5-Unofficial   # only the upgrade cards (from GT
                                                  # boards, chips and GUI signs), their technology and the ME Cell
                                                  # Workbench (me-network issues #17 and #20)
    python tools/gen_ae2_sprites.py --thumbnail   # only thumbnail.png, from the drive and terminal PNGs (issue #20)
    python tools/gen_ae2_sprites.py --crafting-cpu C:/00_Repositories/GT5-Unofficial   # only the crafting blocks of
                                                  # the multiblock crafting CPUs (me-network issue #6): GT casings and
                                                  # screens, faces drawn here (not AE2's textures: CC BY-NC-SA)
    python tools/gen_ae2_sprites.py --assembler C:/00_Repositories/GT5-Unofficial   # only the ME Molecular Assembler
                                                  # (1x1, me-network issue #131): idle, working strip, icons
    python tools/gen_ae2_sprites.py --sheet-assembler docs/graphics-review/issue-131.png   # contact sheet of the
                                                  # assembler at game size (and 4x), next to origin/main's 3x3 one
    python tools/gen_ae2_sprites.py --sheet docs/graphics-review/issue-20.png   # contact sheet of the issue #20
                                                  # graphics next to origin/main (can follow any other switch)

Output:
  graphics/entity/fork/ae2/*.png           entity sprites (32 px per tile, like Gregtorio Continued)
  graphics/icons/fork/me-*.png             32x32 item icons (also pattern provider, molecular assembler,
                                           crafting CPU of prototypes/autocrafting.lua)
  graphics/technology/fork/me-*.png        256x256 technology icons
  fluids (--fluids, or after everything else with --gt):
  graphics/entity/fork/ae2/me-fluid-drive-<tier>.png, me-fluid-interface.png
  graphics/icons/fork/me-<tier>-fluid-storage-cell.png, me-fluid-drive-<tier>.png, me-fluid-interface.png
  graphics/technology/fork/me-fluid-storage.png, me-fluid-storage-256k.png
  extras (issue #38, --extras, or after everything else): derived from the crafting CPU, terminal and
  interface PNGs
  graphics/entity/fork/ae2/me-co-processing-cpu-{off,on}.png, me-quantum-crafting-cpu-{off,on}.png,
  me-level-maintainer-{off,on}.png, me-circuit-interface.png; the item icons of the same names in
  graphics/icons/fork/; graphics/technology/fork/me-automation.png, me-co-processing.png,
  me-quantum-crafting.png
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
HULL_TINT = {"MV": (170, 210, 245), "HV": (205, 205, 225), "EV": (220, 170, 240), "IV": (100, 100, 160)}

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


# --- autocrafting (prototypes/autocrafting.lua) -------------------------------
CPU_CYAN = (95, 225, 245)
CARD = (235, 235, 245)


def provider_sprite(gt):
    """1x1: HV casing with a pattern card (a small grid of crafting slots, the result in blue)."""
    img = hull(gt, "HV")
    d = ImageDraw.Draw(img)
    d.rectangle((2, 2, 13, 13), fill=(20, 20, 24, 255))
    d.rectangle((3, 3, 12, 12), outline=FLUIX + (255,))
    for x in (4, 7, 10):                      # 3x3 crafting grid on the card, the last cell is the result
        for y in (4, 7, 10):
            colour = FLUIX_LIGHT if (x, y) == (10, 10) else CARD
            d.rectangle((x, y, x + 1, y + 1), fill=colour + (255,))
    return up(img)


def assembler_sprite(gt, phase=0):
    """1x1 (me-network issue #131; it was 3x3 before): HV casing, inner dark bay with four robot arms around a fluix
    core. phase 0..3 pulses the core and moves the arm tips (working animation)."""
    img = up(hull(gt, "HV"))
    d = ImageDraw.Draw(img)
    d.rectangle((4, 4, TILE - 5, TILE - 5), fill=(20, 20, 26, 255), outline=(60, 60, 72, 255))
    c = TILE // 2
    glow = [(150, 95, 225), (175, 120, 240), (205, 150, 255), (175, 120, 240)][phase]
    d.rectangle((c - 5, c - 5, c + 4, c + 4), fill=glow + (255,), outline=FLUIX_LIGHT + (255,))
    d.rectangle((c - 2, c - 2, c + 1, c + 1), fill=(235, 225, 255, 255))
    reach = 1 + (phase % 2) * 2
    for dx, dy in ((0, -1), (1, 0), (0, 1), (-1, 0)):        # arms towards the four sides
        x0, y0 = c + dx * 7, c + dy * 7
        x1, y1 = c + dx * (7 + reach), c + dy * (7 + reach)
        d.line((x0, y0, x1, y1), fill=(170, 170, 185, 255), width=2)
        d.rectangle((x1 - 1, y1 - 1, x1, y1), fill=FLUIX_LIGHT + (255,))
    for cx, cy in ((6, 6), (TILE - 8, 6), (6, TILE - 8), (TILE - 8, TILE - 8)):
        d.point((cx, cy), fill=FLUIX + (255,))
    return img


def cpu_sprites(gt):
    """2x2: EV casing ring around a dark screen with a chip grid. off = base, on = lit chips only."""
    tile = up(hull(gt, "EV"))
    off = Image.new("RGBA", (2 * TILE, 2 * TILE))
    for x in range(2):
        for y in range(2):
            off.paste(tile, (x * TILE, y * TILE))
    d = ImageDraw.Draw(off)
    d.rectangle((6, 6, 2 * TILE - 7, 2 * TILE - 7), fill=(20, 20, 26, 255), outline=(60, 60, 72, 255))
    lit = Image.new("RGBA", off.size)
    dl = ImageDraw.Draw(lit)
    for i, cx in enumerate((12, 27, 42)):
        for j, cy in enumerate((12, 27, 42)):
            d.rectangle((cx, cy, cx + 9, cy + 9), fill=(45, 45, 55, 255), outline=(85, 85, 100, 255))
            on = (i + j) % 2 == 0 or (i, j) == (1, 1)
            dl.rectangle((cx + 2, cy + 2, cx + 7, cy + 7), fill=(CPU_CYAN if on else FLUIX_LIGHT) + (255,))
    return off, lit


def flat_icon(img, size=TILE):
    return img.resize((size, size), Image.NEAREST if img.width % size == 0 else Image.LANCZOS)


def assembler(gt):
    """The ME Molecular Assembler (1x1, me-network issue #131): the idle picture, the working strip of four frames below
    each other, the item icon and the technology icon."""
    frames = [assembler_sprite(gt, p) for p in range(4)]
    frames[0].save(OUT_ENTITY / "me-molecular-assembler-idle.png")
    strip = Image.new("RGBA", (TILE, TILE * 4))
    for i, f in enumerate(frames):
        strip.paste(f, (0, i * TILE))
    strip.save(OUT_ENTITY / "me-molecular-assembler-working.png")
    frames[0].save(OUT_ICON / "me-molecular-assembler.png")
    upscale(load(OUT_ICON / "me-molecular-assembler.png")).save(OUT_TECH / "me-autocrafting.png")


def autocrafting(gt):
    provider_sprite(gt).save(OUT_ENTITY / "me-pattern-provider.png")
    provider_sprite(gt).save(OUT_ICON / "me-pattern-provider.png")
    assembler(gt)
    off, lit = cpu_sprites(gt)
    off.save(OUT_ENTITY / "me-crafting-cpu-off.png")
    lit.save(OUT_ENTITY / "me-crafting-cpu-on.png")
    icon = off.copy()
    icon.alpha_composite(lit)
    flat_icon(icon).save(OUT_ICON / "me-crafting-cpu.png")


# --- crafting CPU multiblocks (me-network issue #6, prototypes/autocrafting.lua) ----------------------------
# 1x1 blocks: the EV casing (the legacy CPU's) around a dark face; each sheet holds the block of a group that is no CPU
# (dark: the face's colours dimmed, no light) and of a CPU (lit) side by side, 64x32. The item icon is the lit block.
# AE2's crafting block textures are not used: they are CC BY-NC-SA 3.0 (see README.md, License).
CRAFTING_STORAGE = {"1k": CELLS["1k"][0], "4k": CELLS["4k"][0], "16k": CELLS["16k"][0], "64k": CELLS["64k"][0],
                    "256k": CELLS["256k"][0]}


def dim(rgb, f=0.35):
    return tuple(int(c * f) for c in rgb)


def crafting_face(gt, kind, lit, colour=None):
    """16x16: the EV casing with the block's face (unit: four chips; storage: a memory chip in the size's colour with
    three cell bars; co-processor: a fluix core with traces; monitor: a GT screen)."""
    img = hull(gt, "EV")
    d = ImageDraw.Draw(img)
    def c(rgb):
        return (rgb if lit else dim(rgb)) + (255,)
    if kind == "monitor":
        if lit:
            screen = frames_of(load(gt_path(gt, "gregtech:iconsets/OVERLAY_SCREEN")))[0]
            img.alpha_composite(tint(screen.copy(), CPU_CYAN))
        else:
            img.alpha_composite(frames_of(load(gt_path(gt, "gregtech:iconsets/SCREEN_OFF")))[0])
        return img
    d.rectangle((2, 2, 13, 13), fill=(20, 20, 26, 255), outline=(60, 60, 72, 255))
    if kind == "unit":
        for x, y in ((4, 4), (9, 4), (4, 9), (9, 9)):
            d.rectangle((x, y, x + 2, y + 2), fill=(45, 45, 55, 255), outline=(85, 85, 100, 255))
            d.point((x + 1, y + 1), fill=c(CPU_CYAN))
    elif kind == "storage":
        d.rectangle((4, 4, 11, 11), fill=(45, 45, 55, 255), outline=c(colour))
        for y in (6, 8, 10):
            d.line((6, y - 1, 9, y - 1), fill=c(colour))
        for x in (3, 12):                                   # the chip's pins
            for y in (5, 7, 9):
                d.point((x, y), fill=(150, 150, 160, 255))
    elif kind == "coprocessor":
        for x0, y0, x1, y1 in ((3, 7, 5, 8), (10, 7, 12, 8), (7, 3, 8, 5), (7, 10, 8, 12)):
            d.rectangle((x0, y0, x1, y1), fill=c(FLUIX))
        d.rectangle((5, 5, 10, 10), fill=c(FLUIX), outline=c(FLUIX_LIGHT))
        d.rectangle((7, 7, 8, 8), fill=c((235, 225, 255)))
    return img


def crafting_cpu(gt):
    """the eight crafting blocks: entity sheets (dark | lit) and item icons"""
    blocks = [("me-crafting-unit", "unit", None), ("me-crafting-co-processing-unit", "coprocessor", None),
              ("me-crafting-monitor", "monitor", None)]
    blocks += [(f"me-{k}-crafting-storage", "storage", rgb) for k, rgb in CRAFTING_STORAGE.items()]
    written = []
    for name, kind, colour in blocks:
        dark, lit = up(crafting_face(gt, kind, False, colour)), up(crafting_face(gt, kind, True, colour))
        sheet = Image.new("RGBA", (2 * TILE, TILE))
        sheet.paste(dark, (0, 0))
        sheet.paste(lit, (TILE, 0))
        sheet.save(OUT_ENTITY / f"{name}.png")
        lit.save(OUT_ICON / f"{name}.png")
        written += [OUT_ENTITY / f"{name}.png", OUT_ICON / f"{name}.png"]
    return written


# --- fluids (prototypes/fluids.lua) -------------------------------------------
# Derived from the item PNGs written above (not from the GT textures), so this part also runs
# without a checkout: the AE2 fluid cells look like the item cells with blue accents.
FLUID = (70, 150, 255)              # accent: cell drop, drive border ring, interface arrows
FLUID_LIGHT = (120, 190, 255)
STEEL = (95, 150, 225)              # the cell's gray housing is multiplied by this
FLUID_BAY = (40, 70, 120)           # drive bay outlines (instead of BAY)
FLUID_HOUSING = (110, 150, 210)     # cell housings in the bays (instead of HOUSING)
PIPE = (90, 130, 190)               # pipe ring of the fluid interface


def neutral(rgb, lo=90, hi=200, spread=12):
    """A gray pixel (channels within `spread` of each other) with a brightness in lo..hi."""
    r, g, b = rgb
    return max(abs(r - g), abs(g - b), abs(r - b)) <= spread and lo <= (r + g + b) // 3 <= hi


def recolor(img, mapping):
    """Replaces exact RGB values (mapping old -> new), alpha is kept."""
    px = img.load()
    for y in range(img.height):
        for x in range(img.width):
            p = px[x, y]
            new = mapping.get(p[:3])
            if new is not None:
                px[x, y] = new + (p[3],)
    return img


def fluid_cell_icon(cell):
    """Item cell icon of the tier with a steel blue housing, the tier LED and component window
    kept, and a blue drop (2x6 bar) bottom left, mirroring the LED."""
    led, _ = CELLS[cell]
    window = (led[0] * 2 // 3, led[1] * 2 // 3, led[2] * 2 // 3)      # as drawn by cell_icon()
    img = load(OUT_ICON / f"me-{cell}-storage-cell.png")
    px = img.load()
    for y in range(img.height):
        for x in range(img.width):
            r, g, b, a = px[x, y]
            if a and (r, g, b) not in (led, window) and neutral((r, g, b)):
                px[x, y] = (r * STEEL[0] // 255, g * STEEL[1] // 255, b * STEEL[2] // 255, a)
    ImageDraw.Draw(img).rectangle((12, 22, 13, 27), fill=FLUID + (255,))
    return img


def fluid_drive_icon(cell_icon_img):
    """Like drive_icon(), with the fluid cell as the badge."""
    img = load(ICONS / "me-drive.png")
    img.alpha_composite(cell_icon_img.resize((20, 20), Image.NEAREST), (12, 12))
    return img


def fluid_drive_sprite(cell):
    """Item drive sprite with the bays and cell housings shifted to blue (LEDs kept) and a
    1 px blue ring just inside the tile edge."""
    img = recolor(load(OUT_ENTITY / f"me-drive-{cell}.png"), {BAY: FLUID_BAY, HOUSING: FLUID_HOUSING})
    ImageDraw.Draw(img).rectangle((1, 1, TILE - 2, TILE - 2), outline=FLUID + (255,))
    return img


def fluid_interface_sprite():
    """Item interface sprite with the fluix arrows in blue and a pipe ring (2 px circle of
    radius 9) around the center. Also used as the item icon."""
    img = recolor(load(OUT_ENTITY / "me-interface.png"), {FLUIX: FLUID, FLUIX_LIGHT: FLUID_LIGHT})
    c = TILE // 2
    ImageDraw.Draw(img).ellipse((c - 9, c - 9, c + 8, c + 8), outline=PIPE + (255,), width=2)
    return img


def unified_interface_sprite():
    """The ME Interface with its four fluid sides (me-network issue #3): the item interface sprite with a pipe stub
    (6 x 3 px, the pipe colour with a blue line towards the tile) in the middle of every edge."""
    img = load(OUT_ENTITY / "me-interface.png")
    d = ImageDraw.Draw(img)
    c = TILE // 2
    for horizontal, edge in ((True, 0), (True, TILE - 3), (False, 0), (False, TILE - 3)):
        if horizontal:
            box = (c - 3, edge, c + 2, edge + 2)
            line = (c - 2, edge + (2 if edge == 0 else 0), c + 1, edge + (2 if edge == 0 else 0))
        else:
            box = (edge, c - 3, edge + 2, c + 2)
            line = (edge + (2 if edge == 0 else 0), c - 2, edge + (2 if edge == 0 else 0), c + 1)
        d.rectangle(box, fill=PIPE + (255,))
        d.line(line, fill=FLUID + (255,))
    return img


def unified():
    path = OUT_ENTITY / "me-interface-unified.png"
    unified_interface_sprite().save(path)
    return [path]


def fluids():
    written = []

    def save(img, path):
        img.save(path)
        written.append(path)

    for cell in CELLS:
        icon = fluid_cell_icon(cell)
        save(icon, OUT_ICON / f"me-{cell}-fluid-storage-cell.png")
        save(fluid_drive_icon(icon), OUT_ICON / f"me-fluid-drive-{cell}.png")
        save(fluid_drive_sprite(cell), OUT_ENTITY / f"me-fluid-drive-{cell}.png")
    interface = fluid_interface_sprite()
    save(interface, OUT_ENTITY / "me-fluid-interface.png")
    save(interface, OUT_ICON / "me-fluid-interface.png")
    for tech, icon in (("me-fluid-storage", "me-fluid-drive-16k"),
                       ("me-fluid-storage-256k", "me-fluid-drive-256k")):
        save(upscale(load(OUT_ICON / f"{icon}.png")), OUT_TECH / f"{tech}.png")
    return written


# --- issue #38: CPU tiers, level maintainer, circuit interface ------------------------------
# Derived from the PNGs written above (no checkout needed), like the fluid graphics.
CPU_TIERS = {                        # entity -> (casing tint relative to the EV one, lit chip colors)
    "me-co-processing-cpu": ((100, 100, 160), (CPU_CYAN, FLUIX_LIGHT)),
    "me-quantum-crafting-cpu": ((230, 150, 90), ((255, 120, 220), (235, 225, 255))),
}
SIGNAL_GREEN = (80, 220, 90)
SIGNAL_RED = (235, 70, 60)
GAUGE_ON = (95, 225, 120)
GAUGE_OFF = (60, 64, 72)
TARGET = (245, 215, 70)


def cpu_tier_sprites(tint_rgb, chips):
    """The crafting CPU with its casing ring re-tinted (EV -> tier) and every chip lit in the tier's
    colors (a co-processor on each), plus a tier colored frame around the screen."""
    ev = HULL_TINT["EV"]
    off = load(OUT_ENTITY / "me-crafting-cpu-off.png")
    px = off.load()
    for y in range(off.height):
        for x in range(off.width):
            if 6 <= x <= off.width - 7 and 6 <= y <= off.height - 7:
                continue
            r, g, b, a = px[x, y]
            if a:
                px[x, y] = (min(255, r * tint_rgb[0] // ev[0]), min(255, g * tint_rgb[1] // ev[1]),
                            min(255, b * tint_rgb[2] // ev[2]), a)
    d = ImageDraw.Draw(off)
    d.rectangle((6, 6, 2 * TILE - 7, 2 * TILE - 7), outline=tint_rgb + (255,))
    lit = Image.new("RGBA", off.size)
    dl = ImageDraw.Draw(lit)
    for i, cx in enumerate((12, 27, 42)):
        for j, cy in enumerate((12, 27, 42)):
            dl.rectangle((cx + 2, cy + 2, cx + 7, cy + 7), fill=chips[(i + j) % 2] + (255,))
    return off, lit


def maintainer_sprites():
    """1x1: the terminal casing with a gauge of three bars under a yellow target line (off: dark
    bars; on: the whole picture with green bars)."""
    off = load(OUT_ENTITY / "me-terminal-off.png")
    d = ImageDraw.Draw(off)
    d.rectangle((8, 8, 23, 23), fill=(20, 20, 24, 255))
    heights = (5, 9, 12)
    on = off.copy()
    for img, colour in ((off, GAUGE_OFF), (on, GAUGE_ON)):
        dd = ImageDraw.Draw(img)
        for i, h in enumerate(heights):
            x = 10 + i * 4
            dd.rectangle((x, 21 - h, x + 2, 21), fill=colour + (255,))
        dd.line((9, 10, 22, 10), fill=(TARGET if img is on else (110, 100, 50)) + (255,))
    return off, on


def circuit_interface_sprite():
    """The ME interface with a green square wave and a red signal line instead of the arrows."""
    img = load(OUT_ENTITY / "me-interface.png")
    d = ImageDraw.Draw(img)
    d.rectangle((10, 10, 21, 21), fill=(20, 20, 24, 255))
    wave = [(10, 16), (12, 16), (12, 12), (15, 12), (15, 16), (18, 16), (18, 12), (21, 12)]
    d.line(wave, fill=SIGNAL_GREEN + (255,), width=1)
    d.line((10, 19, 21, 19), fill=SIGNAL_RED + (255,), width=1)
    return img


def extras():
    written = []

    def save(img, path):
        img.save(path)
        written.append(path)

    for name, (tint_rgb, chips) in CPU_TIERS.items():
        off, lit = cpu_tier_sprites(tint_rgb, chips)
        save(off, OUT_ENTITY / f"{name}-off.png")
        save(lit, OUT_ENTITY / f"{name}-on.png")
        icon = off.copy()
        icon.alpha_composite(lit)
        save(flat_icon(icon), OUT_ICON / f"{name}.png")
    off, on = maintainer_sprites()
    save(off, OUT_ENTITY / "me-level-maintainer-off.png")
    save(on, OUT_ENTITY / "me-level-maintainer-on.png")
    save(on, OUT_ICON / "me-level-maintainer.png")
    circuit = circuit_interface_sprite()
    save(circuit, OUT_ENTITY / "me-circuit-interface.png")
    save(circuit, OUT_ICON / "me-circuit-interface.png")
    for tech, icon in (("me-automation", "me-level-maintainer"), ("me-co-processing", "me-co-processing-cpu"),
                       ("me-quantum-crafting", "me-quantum-crafting-cpu")):
        save(upscale(load(OUT_ICON / f"{icon}.png")), OUT_TECH / f"{tech}.png")
    return written


# --- issue #68, step R1: cable, controller, drive with 10 cell bays, buses -------------------
# Derived from the PNGs written above (the MV casing of the item drive and the interface; no checkout
# needed) and drawn with Pillow. The bay geometry must match DRIVE_BAYS in scripts/fork-me-network.lua,
# which draws the cell lights on top (rendering.draw_rectangle).
CABLE_CORE = (125, 80, 200)
CABLE_EDGE = (70, 40, 120)
CABLE_GLOW = (200, 165, 255)
DRIVE_BAY_X = (5, 17)                # left edge of the two bay columns (10 px wide)
DRIVE_BAY_Y = (4, 9, 14, 19, 24)     # top edge of the five bay rows (4 px tall)
IMPORT_ACCENT = (95, 165, 255)
EXPORT_ACCENT = FLUIX


def cable_variation(mask):
    """32x32: a knot in the middle and an arm to every side whose bit is set (1 N, 2 E, 4 S, 8 W)."""
    img = Image.new("RGBA", (TILE, TILE))
    d = ImageDraw.Draw(img)
    c0, c1 = 12, 19                                       # the knot, 8 px
    arms = {1: (13, 0, 18, c0), 2: (c1, 13, TILE - 1, 18), 4: (13, c1, 18, TILE - 1), 8: (0, 13, c0, 18)}
    for bit, box in arms.items():
        if mask & bit:
            d.rectangle(box, fill=CABLE_EDGE + (255,))
            x0, y0, x1, y1 = box
            if bit in (1, 4):
                d.rectangle((x0 + 1, y0, x1 - 1, y1), fill=CABLE_CORE + (255,))
                d.line((x0 + 2, y0, x0 + 2, y1), fill=CABLE_GLOW + (255,))
            else:
                d.rectangle((x0, y0 + 1, x1, y1 - 1), fill=CABLE_CORE + (255,))
                d.line((x0, y0 + 2, x1, y0 + 2), fill=CABLE_GLOW + (255,))
    d.rectangle((c0, c0, c1, c1), fill=CABLE_EDGE + (255,))
    d.rectangle((c0 + 1, c0 + 1, c1 - 1, c1 - 1), fill=CABLE_CORE + (255,))
    d.rectangle((c0 + 2, c0 + 2, c0 + 3, c0 + 3), fill=CABLE_GLOW + (255,))
    return img


def cable_sheet():
    sheet = Image.new("RGBA", (TILE * 16, TILE))
    for mask in range(16):
        sheet.paste(cable_variation(mask), (mask * TILE, 0))
    return sheet


def casing_ring(src):
    """The 32x32 sprite `src` with its inner part cleared to a dark panel (keeps the MV casing edge)."""
    img = src.copy()
    ImageDraw.Draw(img).rectangle((3, 2, TILE - 4, TILE - 3), fill=(20, 20, 24, 255))
    return img


def drive_r1_sprite():
    """1x1: MV casing, ten empty cell bays in two columns of five."""
    img = casing_ring(load(OUT_ENTITY / "me-drive-16k.png"))
    d = ImageDraw.Draw(img)
    for x in DRIVE_BAY_X:
        for y in DRIVE_BAY_Y:
            d.rectangle((x, y, x + 9, y + 3), fill=BAY + (255,), outline=(55, 55, 66, 255))
    return img


def controller_r1_sprite():
    """The old controller sprite with a green status lamp in each corner instead of the fluix dots."""
    img = load(OUT_ENTITY / "me-controller.png")
    d = ImageDraw.Draw(img)
    for cx, cy in ((4, 4), (2 * TILE - 6, 4), (4, 2 * TILE - 6), (2 * TILE - 6, 2 * TILE - 6)):
        d.rectangle((cx - 1, cy - 1, cx + 2, cy + 2), fill=(30, 30, 34, 255))
        d.rectangle((cx, cy, cx + 1, cy + 1), fill=(95, 225, 120, 255))
    return img


def bus_sprite(accent, export, direction):
    """1x1: MV casing, a plate on the side the bus faces and an arrow: towards the plate (export) or away
    from it (import). Drawn facing north, then rotated."""
    img = casing_ring(load(OUT_ENTITY / "me-interface.png"))
    d = ImageDraw.Draw(img)
    d.rectangle((4, 0, TILE - 5, 4), fill=accent + (255,), outline=(40, 40, 48, 255))   # the plate (north)
    d.rectangle((14, 7, 17, 24), fill=(235, 235, 245, 255))                             # arrow shaft
    if export:                                       # arrow head at the plate: items go out
        d.polygon([(9, 13), (22, 13), (15, 6)], fill=accent + (255,))
    else:                                            # arrow head away from the plate: items come in
        d.polygon([(9, 19), (22, 19), (15, 27)], fill=accent + (255,))
    turns = {"north": 0, "east": 270, "south": 180, "west": 90}[direction]
    return img.rotate(turns, resample=Image.NEAREST) if turns else img


def underground_sprite(direction):
    """1x1 underground cable end, drawn facing north (the run goes north under the ground): the cable arm on
    the back side (south) into a dark tunnel mouth with a fluix arrow pointing along the run. Rotated."""
    img = cable_variation(4)
    d = ImageDraw.Draw(img)
    d.rounded_rectangle((6, 3, TILE - 7, 20), radius=4, fill=(24, 22, 30, 255), outline=CABLE_EDGE + (255,), width=2)
    d.rectangle((10, 6, TILE - 11, 18), fill=(12, 10, 16, 255))
    d.polygon([(11, 15), (20, 15), (15, 8)], fill=CABLE_GLOW + (255,))
    turns = {"north": 0, "east": 270, "south": 180, "west": 90}[direction]
    return img.rotate(turns, resample=Image.NEAREST) if turns else img


def underground():
    """The ME Underground Cable (no other input: drawn from the cable colours)."""
    written = []
    for direction in ("north", "east", "south", "west"):
        path = OUT_ENTITY / f"me-underground-cable-{direction}.png"
        underground_sprite(direction).save(path)
        written.append(path)
    path = OUT_ICON / "me-underground-cable.png"
    underground_sprite("north").save(path)
    written.append(path)
    return written


def r1():
    written = []

    def save(img, path):
        img.save(path)
        written.append(path)

    save(cable_sheet(), OUT_ENTITY / "me-cable.png")
    save(cable_variation(15), OUT_ICON / "me-cable.png")
    save(drive_r1_sprite(), OUT_ENTITY / "me-drive.png")
    save(controller_r1_sprite(), OUT_ENTITY / "me-network-controller.png")
    for name, accent, export in (("me-import-bus", IMPORT_ACCENT, False), ("me-export-bus", EXPORT_ACCENT, True)):
        for direction in ("north", "east", "south", "west"):
            save(bus_sprite(accent, export, direction), OUT_ENTITY / f"{name}-{direction}.png")
        save(bus_sprite(accent, export, "north"), OUT_ICON / f"{name}.png")
    return written


# --- issue #68, step R2: fluid import and export bus --------------------------------------
# Derived from the item bus sprites of R1: the accents in fluid blue and the pipe ring of the fluid
# interface around the arrow.
def fluid_bus_sprite(name, direction):
    img = recolor(load(OUT_ENTITY / f"{name}-{direction}.png"),
                  {IMPORT_ACCENT: FLUID_LIGHT, EXPORT_ACCENT: FLUID})
    c = TILE // 2
    ImageDraw.Draw(img).ellipse((c - 9, c - 9, c + 8, c + 8), outline=PIPE + (255,), width=2)
    return img


def r2():
    written = []

    def save(img, path):
        img.save(path)
        written.append(path)

    for name in ("me-import-bus", "me-export-bus"):
        fluid_name = name.replace("me-", "me-fluid-", 1)
        for direction in ("north", "east", "south", "west"):
            save(fluid_bus_sprite(name, direction), OUT_ENTITY / f"{fluid_name}-{direction}.png")
        save(fluid_bus_sprite(name, "north"), OUT_ICON / f"{fluid_name}.png")
    return written


# --- issue #68: ME Storage Bus ----------------------------------------------------------------
# The R1 bus casing with a green plate on the side it faces, a two-headed arrow (the network reads and
# writes the inventory) and a small chest below it.
STORAGE_ACCENT = (95, 200, 120)
CHEST_WOOD = (150, 105, 60)
CHEST_DARK = (90, 60, 32)


def storage_bus_sprite(direction):
    img = casing_ring(load(OUT_ENTITY / "me-interface.png"))
    d = ImageDraw.Draw(img)
    d.rectangle((4, 0, TILE - 5, 4), fill=STORAGE_ACCENT + (255,), outline=(40, 40, 48, 255))   # the plate (north)
    d.rectangle((15, 9, 16, 15), fill=(235, 235, 245, 255))                                      # arrow shaft
    d.polygon([(12, 9), (19, 9), (15, 5)], fill=STORAGE_ACCENT + (255,))                       # head at the plate
    d.polygon([(12, 15), (19, 15), (15, 19)], fill=STORAGE_ACCENT + (255,))                      # head at the chest
    d.rectangle((9, 20, 22, 28), fill=CHEST_WOOD + (255,), outline=CHEST_DARK + (255,))          # the chest
    d.line((9, 23, 22, 23), fill=CHEST_DARK + (255,))                                             # lid
    d.rectangle((15, 22, 16, 25), fill=(230, 200, 90, 255))                                       # latch
    turns = {"north": 0, "east": 270, "south": 180, "west": 90}[direction]
    return img.rotate(turns, resample=Image.NEAREST) if turns else img


def storage_bus():
    written = []
    for direction in ("north", "east", "south", "west"):
        path = OUT_ENTITY / f"me-storage-bus-{direction}.png"
        storage_bus_sprite(direction).save(path)
        written.append(path)
    path = OUT_ICON / "me-storage-bus.png"
    storage_bus_sprite("north").save(path)
    written.append(path)
    return written


# --- issue #68: ME Fluid Storage Bus ----------------------------------------------------------
# The storage bus casing with the plate and arrows in fluid blue and a small storage tank (with its fluid
# window) instead of the chest.
TANK_STEEL = (120, 126, 136)
TANK_DARK = (60, 64, 72)


def fluid_storage_bus_sprite(direction):
    img = casing_ring(load(OUT_ENTITY / "me-interface.png"))
    d = ImageDraw.Draw(img)
    d.rectangle((4, 0, TILE - 5, 4), fill=FLUID + (255,), outline=(40, 40, 48, 255))             # the plate (north)
    d.rectangle((15, 9, 16, 15), fill=(235, 235, 245, 255))                                      # arrow shaft
    d.polygon([(12, 9), (19, 9), (15, 5)], fill=FLUID_LIGHT + (255,))                          # head at the plate
    d.polygon([(12, 15), (19, 15), (15, 19)], fill=FLUID_LIGHT + (255,))                         # head at the tank
    d.ellipse((9, 19, 22, 29), fill=TANK_STEEL + (255,), outline=TANK_DARK + (255,))            # the tank
    d.rectangle((12, 23, 19, 25), fill=FLUID + (255,))                                            # fluid window
    d.line((9, 24, 11, 24), fill=PIPE + (255,))                                                    # pipe stubs
    d.line((20, 24, 22, 24), fill=PIPE + (255,))
    turns = {"north": 0, "east": 270, "south": 180, "west": 90}[direction]
    return img.rotate(turns, resample=Image.NEAREST) if turns else img


def fluid_storage_bus():
    written = []
    for direction in ("north", "east", "south", "west"):
        path = OUT_ENTITY / f"me-fluid-storage-bus-{direction}.png"
        fluid_storage_bus_sprite(direction).save(path)
        written.append(path)
    path = OUT_ICON / "me-fluid-storage-bus.png"
    fluid_storage_bus_sprite("north").save(path)
    written.append(path)
    return written


# --- issue #80: blank and encoded pattern ----------------------------------------------------
# A pattern card drawn with Pillow: a dark slate with a fluix rim and a 3x3 grid of crafting slots (AE2's pattern
# is a card with a grid). The blank card has empty slots; the encoded one has lit slots, an arrow and the result in
# fluix blue.
CARD_SLATE = (52, 56, 70)
CARD_RIM = (110, 116, 135)


def pattern_icon(encoded):
    img = Image.new("RGBA", (TILE, TILE))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle((3, 5, TILE - 4, TILE - 6), radius=3, fill=CARD_SLATE + (255,), outline=CARD_RIM + (255,))
    d.line((5, 6, TILE - 6, 6), fill=FLUIX + (255,))                     # fluix rim at the top
    for i, x in enumerate((6, 11, 16)):
        for j, y in enumerate((9, 14, 19)):
            if encoded and (i + j) % 2 == 0:
                d.rectangle((x, y, x + 3, y + 3), fill=CARD + (255,))
            else:
                d.rectangle((x, y, x + 3, y + 3), outline=(85, 90, 108, 255))
    if encoded:
        d.polygon([(21, 13), (21, 19), (24, 16)], fill=FLUIX_LIGHT + (255,))   # arrow to the result
        d.rectangle((25, 13, 27, 19), fill=FLUIX_LIGHT + (255,))
    else:
        d.rectangle((23, 14, 26, 18), outline=(85, 90, 108, 255))
    return img


def patterns():
    written = []
    for name, encoded in (("me-blank-pattern", False), ("me-encoded-pattern", True)):
        path = OUT_ICON / f"{name}.png"
        pattern_icon(encoded).save(path)
        written.append(path)
    return written


# --- me-network issues #17 and #20: upgrade cards, their technology, the ME Cell Workbench ----------------
# Made from GT5-Unofficial textures, like the blocks (no textures of Applied Energistics 2, see README "License"). As
# in AE2 every card is made from a basic or an advanced card and shows that card's body: a GT circuit board (the
# coated basic board, gray, or the epoxy board, blue; items/gt.metaitem.03/7 and 6) cut to a card with gold contacts
# on the left. The two components carry a GT circuit in the middle (the basic and the good circuit); the cards made
# from them carry a GT SMD chip next to the contacts and, on the right, the sign of a GT machine GUI button in a
# colour of their own, so that they are told apart at 32 px:
#   capacity              plus_large (green)        fuzzy                 analog: a wave, "about" (magenta)
#   inverter              disable: a slashed ring   equal distribution    cyclic: round robin arrows (cyan)
#                         (orange)                  acceleration          x2: "twice as fast" (lime)
# The Overflow Destruction Card is a warning: a yellow triangle with a black "!" (drawn) and black and yellow hazard
# stripes along the card's bottom edge.
CARD_OUTLINE = (30, 30, 38)
CONTACT = (230, 190, 70)
CONTACT_DARK = (150, 115, 35)
HAZARD = (250, 205, 40)
CARD_BOX = (1, 6, TILE - 2, 26)    # the card: 30 x 21 px
CARD_CHIP = "items/gt.metaitem.03/75"   # SMD chip of the cards made from a component
CARD_BASES = {                # base -> (GT board texture of the body, GT circuit of the component card, body colour)
    "basic": ("items/gt.metaitem.03/7", "items/gt.metaitem.01/701", (200, 200, 205)),
    "advanced": ("items/gt.metaitem.03/6", "items/gt.metaitem.01/702", (45, 85, 200)),
}
CARDS = {                     # name -> (base card, GT GUI texture of the sign, its colour)
    "me-basic-card": ("basic", None, None),
    "me-advanced-card": ("advanced", None, None),
    "me-capacity-card": ("basic", "gui/overlay_button/plus_large", (70, 200, 90)),
    "me-overflow-destruction-card": ("basic", "warning", HAZARD),
    "me-fuzzy-card": ("advanced", "gui/overlay_button/analog", (235, 95, 215)),
    "me-inverter-card": ("advanced", "gui/overlay_button/disable", (245, 120, 30)),
    "me-equal-distribution-card": ("advanced", "gui/overlay_button/cyclic", (60, 225, 210)),
    "me-acceleration-card": ("advanced", "gui/overlay_button/x2", (185, 240, 70)),   # issue #110: the "x2" sign (lime)
}
CARD_SIGN_MAX = 20            # px; larger GT signs (the 24 px ring of "disable") are scaled down to it


def gt_texture(gt, rel):
    """A GT5-Unofficial texture (assets/gregtech/textures/<rel>.png), its first frame."""
    img = load(gt / "src/main/resources/assets/gregtech/textures" / (rel + ".png"))
    return img.crop((0, 0, img.width, img.width))


def opaque(img):
    return img.crop(img.getchannel("A").getbbox())


def card_board(gt, base):
    """The card body: the GT board texture (its rim cut off) tiled over the card, gold contacts on the left."""
    tex = gt_texture(gt, CARD_BASES[base][0]).crop((1, 1, GT_PX - 1, GT_PX - 1))
    fill = Image.new("RGBA", (TILE, TILE))
    for y in range(0, TILE, tex.height):
        for x in range(0, TILE, tex.width):
            fill.alpha_composite(tex, (x, y))
    mask = Image.new("L", (TILE, TILE))
    ImageDraw.Draw(mask).rounded_rectangle(CARD_BOX, radius=3, fill=255)
    img = Image.new("RGBA", (TILE, TILE))
    img.paste(fill, (0, 0), mask)
    d = ImageDraw.Draw(img)
    d.rounded_rectangle(CARD_BOX, radius=3, outline=CARD_OUTLINE + (255,))
    for y in range(9, 24, 3):
        d.rectangle((2, y, 4, y + 1), fill=CONTACT + (255,))
        d.point((4, y + 1), fill=CONTACT_DARK + (255,))
    return img


def card_sign(img, colour):
    """A GT GUI sign in `colour`, its light and shade kept, with a 1 px dark outline (1 px larger on each side)."""
    if max(img.size) > CARD_SIGN_MAX:
        s = CARD_SIGN_MAX / max(img.size)
        img = img.resize((round(img.width * s), round(img.height * s)), Image.LANCZOS)
    w, h = img.size
    mask = img.getchannel("A").point(lambda v: 255 if v > 100 else 0)
    src, m = img.load(), mask.load()
    lums = [sum(src[x, y][:3]) / 3 for y in range(h) for x in range(w) if m[x, y]]
    lo, hi = min(lums), max(lums)
    sign = Image.new("RGBA", (w, h))
    px = sign.load()
    for y in range(h):
        for x in range(w):
            if m[x, y]:
                t = 1.0 if hi - lo < 40 else (sum(src[x, y][:3]) / 3 - lo) / (hi - lo)   # flat signs: one colour
                t = 0.6 + 0.4 * t
                px[x, y] = tuple(int(CARD_OUTLINE[i] + (colour[i] - CARD_OUTLINE[i]) * t) for i in range(3)) + (255,)
    out = Image.new("RGBA", (w + 2, h + 2))
    dark = Image.new("RGBA", (w, h), CARD_OUTLINE + (255,))
    for dx in range(3):
        for dy in range(3):
            out.paste(dark, (dx, dy), mask)
    out.alpha_composite(sign, (1, 1))
    return out


def warning_sign():
    """21 x 19: a yellow triangle with a dark rim and a black "!"."""
    img = Image.new("RGBA", (21, 19))
    d = ImageDraw.Draw(img)
    d.polygon([(10, 0), (20, 18), (0, 18)], fill=CARD_OUTLINE + (255,))
    d.polygon([(10, 3), (18, 17), (2, 17)], fill=HAZARD + (255,))
    d.rectangle((9, 7, 11, 12), fill=CARD_OUTLINE + (255,))
    d.rectangle((9, 14, 11, 15), fill=CARD_OUTLINE + (255,))
    return img


def card_icon(gt, name):
    base, sign, colour = CARDS[name]
    img = card_board(gt, base)
    mid = (CARD_BOX[1] + CARD_BOX[3] + 1) // 2
    if sign is None:                                                         # a component: its GT circuit in the middle
        circuit = opaque(gt_texture(gt, CARD_BASES[base][1]))
        img.alpha_composite(circuit, (17 - circuit.width // 2, mid - circuit.height // 2))
        return img
    chip = opaque(gt_texture(gt, CARD_CHIP))
    img.alpha_composite(chip, (6, mid - chip.height // 2))
    if sign == "warning":
        stripes = Image.new("RGBA", (TILE, TILE))
        ds = ImageDraw.Draw(stripes)
        ds.rounded_rectangle(CARD_BOX, radius=3, fill=HAZARD + (255,))
        ds.rectangle((0, 0, TILE, CARD_BOX[3] - 5), fill=(0, 0, 0, 0))       # only the bottom edge
        for x in range(-4, TILE, 4):
            ds.polygon([(x, CARD_BOX[3]), (x + 2, CARD_BOX[3]), (x + 5, CARD_BOX[3] - 4), (x + 3, CARD_BOX[3] - 4)],
                       fill=CARD_OUTLINE + (255,))
        img.alpha_composite(stripes)
        ImageDraw.Draw(img).rounded_rectangle(CARD_BOX, radius=3, outline=CARD_OUTLINE + (255,))
        w = warning_sign()
        img.alpha_composite(w, (TILE - 1 - w.width, 2))
        return img
    s = card_sign(opaque(gt_texture(gt, sign)), colour)
    img.alpha_composite(s, (TILE - 1 - s.width, mid - s.height // 2))
    return img


def cards_tech(gt):
    """256x256: three cards fanned out (Overflow Destruction behind, Fuzzy, Capacity in front)."""
    img = Image.new("RGBA", (40, 40))
    for i, name in enumerate(("me-overflow-destruction-card", "me-fuzzy-card", "me-capacity-card")):
        img.alpha_composite(card_icon(gt, name), (i * 4, i * 5))
    return upscale(img)


# The ME Cell Workbench: a 1x1 block like the other ME blocks (the MV casing edge of the interface sprite, a dark top)
# with a storage cell lying in a cradle on the left and four card slots on the right, two of them holding a card.
# Its shadow is a separate PNG (draw_as_shadow): the block's outline moved down and to the right.
WORKBENCH_SHADOW = (6, 4)          # pixels the shadow falls to the east and the south


def workbench_sprite():
    img = casing_ring(load(OUT_ENTITY / "me-interface.png"))
    d = ImageDraw.Draw(img)
    d.rectangle((3, 2, TILE - 4, 3), fill=FLUIX + (255,))                  # fluix rim at the top of the work surface
    d.rectangle((5, 6, 14, 27), fill=(12, 12, 16, 255), outline=(60, 60, 72, 255))   # the cradle
    d.rectangle((7, 8, 12, 25), fill=HOUSING + (255,), outline=(70, 70, 80, 255))    # the cell in it
    d.rectangle((8, 10, 11, 17), fill=(30, 30, 36, 255))                   # its component window
    d.rectangle((9, 12, 10, 15), fill=FLUIX_LIGHT + (255,))
    d.rectangle((9, 21, 10, 22), fill=(95, 225, 120, 255))                  # its LED
    slots = ((17, 7), (17, 17), (23, 7), (23, 17))
    held = {0: "me-capacity-card", 3: "me-inverter-card"}
    for i, (x, y) in enumerate(slots):
        d.rectangle((x, y, x + 4, y + 7), fill=(12, 12, 16, 255), outline=(85, 85, 100, 255))
        if i in held:
            base, _, colour = CARDS[held[i]]
            d.rectangle((x + 1, y + 1, x + 3, y + 6), fill=CARD_BASES[base][2] + (255,))
            d.rectangle((x + 1, y + 3, x + 3, y + 5), fill=colour + (255,))
    return img


def workbench_shadow():
    dx, dy = WORKBENCH_SHADOW
    img = Image.new("RGBA", (TILE + dx, TILE + dy))
    ImageDraw.Draw(img).rectangle((dx, dy, TILE + dx - 1, TILE + dy - 1), fill=(0, 0, 0, 160))
    return img


def cards(gt):
    written = []

    def save(img, path):
        img.save(path)
        written.append(path)

    for name in CARDS:
        save(card_icon(gt, name), OUT_ICON / f"{name}.png")
    save(cards_tech(gt), OUT_TECH / "me-upgrade-cards.png")
    bench = workbench_sprite()
    save(bench, OUT_ENTITY / "me-cell-workbench.png")
    save(workbench_shadow(), OUT_ENTITY / "me-cell-workbench-shadow.png")
    save(bench, OUT_ICON / "me-cell-workbench.png")
    return written


# --- me-network issue #20: the mod's thumbnail -------------------------------------------------------
# 144x144 from the mod's own sprites at twice their size: an ME Drive with lit cells and an ME Terminal side by side,
# joined by ME cable underneath, on a dark background with a fluix glow.
THUMB = 144


def lit_drive():
    """The drive sprite with a cell in every bay, lit as the runtime draws it (scripts/fork-me-network.lua: LED_*)."""
    img = load(OUT_ENTITY / "me-drive.png")
    d = ImageDraw.Draw(img)
    colours = [(77, 217, 102)] * 10
    colours[3], colours[8] = (255, 153, 25), (77, 217, 102)
    for slot in range(10):
        x0, y0 = DRIVE_BAY_X[slot % 2], DRIVE_BAY_Y[slot // 2]
        d.rectangle((x0 + 1, y0 + 1, x0 + 8, y0 + 2), fill=colours[slot] + (255,))
    return img


def thumbnail():
    img = Image.new("RGBA", (THUMB, THUMB), (18, 16, 26, 255))
    glow = Image.new("RGBA", (THUMB, THUMB))
    dg = ImageDraw.Draw(glow)
    for r in range(70, 0, -2):                                              # soft fluix glow from the middle
        a = int(90 * (1 - r / 70) ** 1.5)
        dg.ellipse((THUMB // 2 - r, THUMB // 2 - 8 - r, THUMB // 2 + r, THUMB // 2 - 8 + r), fill=FLUIX + (a,))
    img.alpha_composite(glow)
    terminal = load(OUT_ENTITY / "me-terminal-off.png")
    terminal.alpha_composite(load(OUT_ENTITY / "me-terminal-on.png"))
    parts = ((lit_drive(), (8, 21)), (terminal, (72, 21)),
             (cable_variation(1 | 2), (8, 85)), (cable_variation(1 | 8), (72, 85)))
    shadow = Image.new("RGBA", (THUMB, THUMB))
    for part, pos in parts[:2]:                                             # the blocks cast a shadow
        ImageDraw.Draw(shadow).rectangle((pos[0] + 6, pos[1] + 6, pos[0] + 69, pos[1] + 69), fill=(0, 0, 0, 120))
    img.alpha_composite(shadow)
    for part, pos in parts[2:] + parts[:2]:                                 # cable first, the blocks on top
        img.alpha_composite(up(part), pos)
    return img.convert("RGB")


# --- me-network issue #20: contact sheet -------------------------------------------------------------
# One PNG of the issue #20 graphics for the pull request: the cards at 32 px in inventory slots (as the player sees
# them) and enlarged, the placeholders of origin/main next to them, the technology icon, the workbench on the ground
# with its shadow and the thumbnail.
SHEET_BG, SHEET_PANEL, SHEET_TEXT, SHEET_DIM = (34, 34, 38), (52, 52, 58), (235, 235, 235), (150, 150, 160)
SLOT_BG, SLOT_EDGE = (66, 64, 66), (40, 38, 40)
GROUND = (88, 78, 52)


def before(path, ref="origin/main"):
    """The PNG at `ref` (None when it does not exist there)."""
    import io
    import subprocess
    rel = path.relative_to(ROOT).as_posix()
    r = subprocess.run(["git", "-C", str(ROOT), "show", f"{ref}:{rel}"], capture_output=True)
    return Image.open(io.BytesIO(r.stdout)).convert("RGBA") if r.returncode == 0 else None


def slot(img, size=40):
    """An inventory slot (Factorio's slot is 40 px around a 32 px icon) holding `img`."""
    s = Image.new("RGBA", (size, size), SLOT_EDGE + (255,))
    ImageDraw.Draw(s).rectangle((1, 1, size - 2, size - 2), fill=SLOT_BG + (255,))
    s.alpha_composite(img, ((size - img.width) // 2, (size - img.height) // 2))
    return s


def contact_sheet(out):
    from PIL import ImageFont
    font = ImageFont.load_default(size=14)
    small = ImageFont.load_default(size=12)
    W = 1180
    img = Image.new("RGBA", (W, 1080), SHEET_BG + (255,))
    d = ImageDraw.Draw(img)

    def title(y, text):
        d.text((16, y), text, font=font, fill=SHEET_TEXT)

    d.text((16, 12), "me-network issue #20: graphics of the upgrade cards, the ME Cell Workbench and the thumbnail",
           font=font, fill=SHEET_TEXT)
    d.text((16, 32), "tools/gen_ae2_sprites.py --cards <GT5-Unofficial> --thumbnail (cards: GT boards, chips and GUI "
           "signs; workbench and thumbnail: the mod's own GT-derived sprites; no AE2 textures)", font=small,
           fill=SHEET_DIM)

    # 1. the cards as the player sees them: a row of inventory slots at 1x and at 2x
    names = list(CARDS)
    title(60, "Upgrade cards in inventory slots, 32 px (1x) and 2x")
    for i, name in enumerate(names):
        img.alpha_composite(slot(load(OUT_ICON / f"{name}.png")), (16 + i * 42, 84))
        img.alpha_composite(up(slot(load(OUT_ICON / f"{name}.png"))), (340 + i * 82, 84))
    # 2. every card enlarged with its name, the placeholder of origin/main below it
    title(180, "Each card at 4x (new) and the placeholder of origin/main at 2x")
    for i, name in enumerate(names):
        x = 16 + i * 164
        d.rectangle((x, 204, x + 156, 420), fill=SHEET_PANEL)
        img.alpha_composite(up(load(OUT_ICON / f"{name}.png"), 4), (x + 14, 210))
        d.text((x + 6, 342), name.replace("me-", "").replace("-card", ""), font=small, fill=SHEET_TEXT)
        old = before(OUT_ICON / f"{name}.png")
        if old:
            d.text((x + 6, 362), "before:", font=small, fill=SHEET_DIM)
            img.alpha_composite(up(old, 2), (x + 70, 356))
    # 3. technology icon, new and old
    title(440, "Technology me-upgrade-cards (256 px), new and before")
    d.rectangle((16, 464, 16 + 264, 464 + 264), fill=SHEET_PANEL)
    img.alpha_composite(load(OUT_TECH / "me-upgrade-cards.png"), (20, 468))
    old = before(OUT_TECH / "me-upgrade-cards.png")
    if old:
        d.rectangle((296, 464, 296 + 136, 464 + 136), fill=SHEET_PANEL)
        img.alpha_composite(old.resize((128, 128), Image.LANCZOS), (300, 468))
        d.text((300, 604), "before (at 128 px)", font=small, fill=SHEET_DIM)
    # 4. the workbench: on the ground with its shadow at 1x and 4x, its icon in a slot, the old sprite
    x0 = 460
    d.text((x0, 440), "ME Cell Workbench: entity with shadow on the ground (4x, 1x), item icon, before", font=font,
           fill=SHEET_TEXT)
    ground = Image.new("RGBA", (200, 200), GROUND + (255,))
    big = Image.new("RGBA", (TILE + WORKBENCH_SHADOW[0], TILE + WORKBENCH_SHADOW[1]))
    big.alpha_composite(load(OUT_ENTITY / "me-cell-workbench-shadow.png"))
    big.alpha_composite(load(OUT_ENTITY / "me-cell-workbench.png"))
    ground.alpha_composite(up(big, 4), (16, 16))
    img.alpha_composite(ground, (x0, 464))
    small_ground = Image.new("RGBA", (64, 64), GROUND + (255,))
    small_ground.alpha_composite(big, (14, 14))
    img.alpha_composite(small_ground, (x0 + 216, 464))
    img.alpha_composite(slot(load(OUT_ICON / "me-cell-workbench.png")), (x0 + 216, 540))
    d.text((x0 + 216, 586), "icon", font=small, fill=SHEET_DIM)
    old = before(OUT_ENTITY / "me-cell-workbench.png")
    if old:
        img.alpha_composite(up(old, 4), (x0 + 300, 464))
        d.text((x0 + 300, 596), "before (4x)", font=small, fill=SHEET_DIM)
    # 5. the thumbnail
    title(750, "thumbnail.png (144 px) at 1x and 2x, and before")
    thumb = load(ROOT / "thumbnail.png")
    img.alpha_composite(thumb, (16, 774))
    img.alpha_composite(up(thumb, 2) if thumb.width <= 144 else thumb, (176, 774))
    old = before(ROOT / "thumbnail.png")
    if old:
        img.alpha_composite(old.resize((144, 144), Image.LANCZOS), (480, 774))
        d.text((480, 922), "before", font=small, fill=SHEET_DIM)
    out.parent.mkdir(parents=True, exist_ok=True)
    img.convert("RGB").save(out)
    return [out]


def assembler_sheet(out):
    """Contact sheet of the 1x1 ME Molecular Assembler (me-network issue #131): idle and the four working frames at game size
    (1x, 32 px per tile, on grass) and at 4x, the item icon in a slot, and the 3x3 picture of origin/main for comparison."""
    from PIL import ImageFont
    font = ImageFont.load_default(size=14)
    small = ImageFont.load_default(size=12)
    img = Image.new("RGBA", (760, 500), SHEET_BG + (255,))
    d = ImageDraw.Draw(img)
    d.text((16, 12), "me-network issue #131: the ME Molecular Assembler, 1x1 (tools/gen_ae2_sprites.py --assembler <GT5-Unofficial>)",
           font=font, fill=SHEET_TEXT)
    d.text((16, 32), "GT5 HV casing + drawn core and arms; no AE2 textures. Module icons and the alt-mode recipe icon are the game's.",
           font=small, fill=SHEET_DIM)
    idle = load(OUT_ENTITY / "me-molecular-assembler-idle.png")
    work = load(OUT_ENTITY / "me-molecular-assembler-working.png")
    frames = [idle] + [work.crop((0, i * TILE, TILE, (i + 1) * TILE)) for i in range(4)]
    names = ["idle", "working 1", "working 2", "working 3", "working 4"]
    d.text((16, 60), "Game size (1x), on the ground, with a pattern provider (1x1) below", font=font, fill=SHEET_TEXT)
    ground = Image.new("RGBA", (TILE * 12, TILE * 2), GROUND + (255,))
    for i, f in enumerate(frames):
        ground.alpha_composite(f, (TILE * (2 * i + 1), 0))
    prov = load(OUT_ENTITY / "me-pattern-provider.png")
    ground.alpha_composite(prov, (TILE * 3, TILE))
    img.alpha_composite(ground, (16, 84))
    d.text((16, 150), "Idle and the four working frames (4x)", font=font, fill=SHEET_TEXT)
    for i, f in enumerate(frames):
        x = 16 + i * 148
        d.rectangle((x, 174, x + 140, 174 + 140), fill=SHEET_PANEL)
        img.alpha_composite(up(f, 4), (x + 6, 180))
        d.text((x + 6, 322), names[i], font=small, fill=SHEET_TEXT)
    d.text((16, 350), "Item icon in a slot (1x, 2x)", font=font, fill=SHEET_TEXT)
    icon = load(OUT_ICON / "me-molecular-assembler.png")
    img.alpha_composite(slot(icon), (16, 374))
    img.alpha_composite(up(slot(icon)), (66, 374))
    old = before(OUT_ENTITY / "me-molecular-assembler-idle.png")
    d.text((250, 350), "origin/main: 3x3, 96 px", font=font, fill=SHEET_TEXT)
    if old:
        img.alpha_composite(old.resize((old.width * 3 // 4, old.height * 3 // 4), Image.NEAREST), (250, 366))
    out.parent.mkdir(parents=True, exist_ok=True)
    img.convert("RGB").save(out)
    return [out]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--gt", type=Path, help="path to the GT5-Unofficial checkout: generates everything")
    ap.add_argument("--fluids", action="store_true",
                    help="only the fluid graphics, derived from the existing item PNGs (no checkout needed)")
    ap.add_argument("--extras", action="store_true",
                    help="only the issue #38 graphics (CPU tiers, level maintainer, circuit interface), derived "
                         "from the existing PNGs (no checkout needed)")
    ap.add_argument("--r1", action="store_true",
                    help="only the issue #68 (R1) graphics (cable, controller, drive with cell bays, buses), "
                         "derived from the existing PNGs (no checkout needed)")
    ap.add_argument("--r2", action="store_true",
                    help="only the issue #68 (R2) graphics (fluid import and export bus), derived from the R1 PNGs")
    ap.add_argument("--underground", action="store_true",
                    help="only the ME Underground Cable (drawn from the cable colours)")
    ap.add_argument("--storage-bus", action="store_true",
                    help="only the ME Storage Bus, derived from the R1 PNGs")
    ap.add_argument("--fluid-storage-bus", action="store_true",
                    help="only the ME Fluid Storage Bus, derived from the R1 PNGs")
    ap.add_argument("--patterns", action="store_true",
                    help="only the blank and encoded pattern icons (issue #80, drawn with Pillow)")
    ap.add_argument("--cards", type=Path, metavar="GT",
                    help="only the upgrade card icons, their technology icon and the ME Cell Workbench with its shadow "
                         "(me-network issues #17 and #20): the cards from the textures of the GT5-Unofficial checkout "
                         "GT, the workbench from the interface PNG")
    ap.add_argument("--thumbnail", action="store_true",
                    help="only thumbnail.png, from the drive, terminal and cable PNGs (me-network issue #20)")
    ap.add_argument("--sheet", type=Path, metavar="PNG",
                    help="writes a contact sheet of the issue #20 graphics (new and origin/main) to PNG")
    ap.add_argument("--crafting-cpu", type=Path, metavar="GT",
                    help="only the crafting blocks of the multiblock crafting CPUs (me-network issue #6), from the "
                         "casings and screens of the GT5-Unofficial checkout GT")
    ap.add_argument("--unified", action="store_true",
                    help="only the ME Interface with its pipe sides (me-network issue #3), from the R1 PNGs")
    ap.add_argument("--assembler", type=Path, metavar="GT",
                    help="only the ME Molecular Assembler (1x1, me-network issue #131), from the casings of the "
                         "GT5-Unofficial checkout GT")
    ap.add_argument("--sheet-assembler", type=Path, metavar="PNG",
                    help="writes a contact sheet of the 1x1 ME Molecular Assembler (issue #131) to PNG")
    a = ap.parse_args()
    if not (a.gt or a.fluids or a.extras or a.r1 or a.r2 or a.underground or a.storage_bus or a.fluid_storage_bus
            or a.patterns or a.unified or a.cards or a.thumbnail or a.sheet or a.crafting_cpu or a.assembler or a.sheet_assembler):
        ap.error("--gt <checkout>, --fluids, --extras, --r1, --r2, --underground, --storage-bus, --fluid-storage-bus,"
                 " --patterns, --unified, --cards, --crafting-cpu, --assembler, --thumbnail, --sheet or --sheet-assembler is required")
    for d in (OUT_ENTITY, OUT_ICON, OUT_TECH):
        d.mkdir(parents=True, exist_ok=True)

    if a.gt:
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
        autocrafting(a.gt)
        print("ME sprites:", len(list(OUT_ENTITY.glob("*.png"))))
    if a.gt or a.fluids:
        written = fluids()
        print("ME fluid sprites:", len(written))
    if a.gt or a.extras:
        written = extras()
        print("ME issue #38 sprites:", len(written))
    if a.gt or a.r1:
        written = r1()
        print("ME issue #68 (R1) sprites:", len(written))
    if a.gt or a.r2:
        written = r2()
        print("ME issue #68 (R2) sprites:", len(written))
    if a.gt or a.underground:
        written = underground()
        print("ME underground cable sprites:", len(written))
    if a.gt or a.storage_bus:
        written = storage_bus()
        print("ME storage bus sprites:", len(written))
    if a.gt or a.fluid_storage_bus:
        written = fluid_storage_bus()
        print("ME fluid storage bus sprites:", len(written))
    if a.gt or a.patterns:
        written = patterns()
        print("ME pattern icons:", len(written))
    if a.gt or a.unified:
        written = unified()
        print("ME unified interface sprites:", len(written))
    if a.gt or a.cards:
        written = cards(a.gt or a.cards)
        print("ME card icons:", len(written))
    if a.gt or a.crafting_cpu:
        written = crafting_cpu(a.gt or a.crafting_cpu)
        print("ME crafting block sprites:", len(written))
    if a.gt or a.thumbnail:
        thumbnail().save(ROOT / "thumbnail.png")
        print("thumbnail.png")
    if a.assembler:
        assembler(a.assembler)
        print("ME Molecular Assembler sprites")
    if a.sheet:
        contact_sheet(a.sheet)
        print("contact sheet:", a.sheet)
    if a.sheet_assembler:
        assembler_sheet(a.sheet_assembler)
        print("contact sheet:", a.sheet_assembler)


if __name__ == "__main__":
    main()
