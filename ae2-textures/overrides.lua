--- The sprites of ME Network that this mod replaces (issue #239), read by data-final-fixes.lua. Empty: no texture of
--- Applied Energistics 2 is imported yet (ME Network issue #236 chooses which).
---
--- A key is "<prototype type>/<prototype name>" of ME Network (it never renames a prototype). A value is either
---   a file of this mod, when the prototype uses exactly one file of ME Network (an item's icon):
---     ["item/me-drive"] = "__me-network-ae2-textures__/graphics/icons/me-drive.png",
---   or a table from ME Network's file to this mod's file, one entry per replaced layer or file:
---     ["assembling-machine/me-drive"] = {
---       ["__me-network__/graphics/entity/fork/ae2/hd/me-drive.png"] = "__me-network-ae2-textures__/graphics/entity/me-drive.png",
---     },
--- A replacement is a file name, or a table with `filename` and the sprite fields that differ from the replaced file's
--- (its size: `icon_size`, or `width`, `height`, `scale`):
---     ["item/me-drive"] = { filename = "__me-network-ae2-textures__/graphics/icons/me-drive.png", icon_size = 16 },
--- Only files of this mod, each listed in MANIFEST.tsv, never an image put together from AE2 and other pixels.
return {
}
