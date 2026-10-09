--- The sprites of ME Network that this mod replaces (issue #239), read by data-final-fixes.lua. ME Network issue #236
--- lists the groups; issue #247 brought the first ones: the item icons of the cells, cards and patterns, from
--- AE2-Unofficial (MANIFEST.tsv), each scaled to the size of the icon it replaces (tools/scale_ae2_icons.py).
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
	--- storage cells (64 px), their components and the housing (32 px); the fluid cells have no AE2-Unofficial icon
	["item-with-tags/me-1k-storage-cell"] = "__me-network-ae2-textures__/graphics/icons/cells/me-1k-storage-cell.png",
	["item-with-tags/me-4k-storage-cell"] = "__me-network-ae2-textures__/graphics/icons/cells/me-4k-storage-cell.png",
	["item-with-tags/me-16k-storage-cell"] = "__me-network-ae2-textures__/graphics/icons/cells/me-16k-storage-cell.png",
	["item-with-tags/me-64k-storage-cell"] = "__me-network-ae2-textures__/graphics/icons/cells/me-64k-storage-cell.png",
	["item-with-tags/me-256k-storage-cell"] = "__me-network-ae2-textures__/graphics/icons/cells/me-256k-storage-cell.png",
	["item/me-1k-storage-component"] = "__me-network-ae2-textures__/graphics/icons/cells/me-1k-storage-component.png",
	["item/me-4k-storage-component"] = "__me-network-ae2-textures__/graphics/icons/cells/me-4k-storage-component.png",
	["item/me-16k-storage-component"] = "__me-network-ae2-textures__/graphics/icons/cells/me-16k-storage-component.png",
	["item/me-64k-storage-component"] = "__me-network-ae2-textures__/graphics/icons/cells/me-64k-storage-component.png",
	["item/me-256k-storage-component"] = "__me-network-ae2-textures__/graphics/icons/cells/me-256k-storage-component.png",
	["item/basic-storage-housing"] = "__me-network-ae2-textures__/graphics/icons/cells/basic-storage-housing.png",
	--- upgrade cards (32 px); the ME Interface Capacity Card has no AE2 counterpart and keeps its icon
	["item/me-basic-card"] = "__me-network-ae2-textures__/graphics/icons/cards/me-basic-card.png",
	["item/me-advanced-card"] = "__me-network-ae2-textures__/graphics/icons/cards/me-advanced-card.png",
	["item/me-capacity-card"] = "__me-network-ae2-textures__/graphics/icons/cards/me-capacity-card.png",
	["item/me-overflow-destruction-card"] = "__me-network-ae2-textures__/graphics/icons/cards/me-overflow-destruction-card.png",
	["item/me-fuzzy-card"] = "__me-network-ae2-textures__/graphics/icons/cards/me-fuzzy-card.png",
	["item/me-pattern-capacity-card"] = "__me-network-ae2-textures__/graphics/icons/cards/me-pattern-capacity-card.png",
	["item/me-sticky-card"] = "__me-network-ae2-textures__/graphics/icons/cards/me-sticky-card.png",
	["item/me-inverter-card"] = "__me-network-ae2-textures__/graphics/icons/cards/me-inverter-card.png",
	["item/me-equal-distribution-card"] = "__me-network-ae2-textures__/graphics/icons/cards/me-equal-distribution-card.png",
	["module/me-acceleration-card"] = "__me-network-ae2-textures__/graphics/icons/cards/me-acceleration-card.png",
	--- patterns (32 px)
	["item/me-blank-pattern"] = "__me-network-ae2-textures__/graphics/icons/patterns/me-blank-pattern.png",
	["item-with-tags/me-encoded-pattern"] = "__me-network-ae2-textures__/graphics/icons/patterns/me-encoded-pattern.png",
}
