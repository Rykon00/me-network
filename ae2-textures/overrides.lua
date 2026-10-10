--- The sprites of ME Network that this mod replaces (issue #239), read by data-final-fixes.lua. ME Network issue #236
--- lists the groups; issue #247 brought the first ones: the item icons of the cells, cards and patterns, from
--- AE2-Unofficial (MANIFEST.tsv), each scaled to the size of the icon it replaces (tools/scale_ae2_icons.py). Each
--- entry names its icon_size, so it stays right when ME Network draws its own icon at another size.
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
	["item-with-tags/me-1k-storage-cell"] = { filename = "__me-network-ae2-textures__/graphics/icons/cells/me-1k-storage-cell.png", icon_size = 64 },
	["item-with-tags/me-4k-storage-cell"] = { filename = "__me-network-ae2-textures__/graphics/icons/cells/me-4k-storage-cell.png", icon_size = 64 },
	["item-with-tags/me-16k-storage-cell"] = { filename = "__me-network-ae2-textures__/graphics/icons/cells/me-16k-storage-cell.png", icon_size = 64 },
	["item-with-tags/me-64k-storage-cell"] = { filename = "__me-network-ae2-textures__/graphics/icons/cells/me-64k-storage-cell.png", icon_size = 64 },
	["item-with-tags/me-256k-storage-cell"] = { filename = "__me-network-ae2-textures__/graphics/icons/cells/me-256k-storage-cell.png", icon_size = 64 },
	["item/me-1k-storage-component"] = { filename = "__me-network-ae2-textures__/graphics/icons/cells/me-1k-storage-component.png", icon_size = 32 },
	["item/me-4k-storage-component"] = { filename = "__me-network-ae2-textures__/graphics/icons/cells/me-4k-storage-component.png", icon_size = 32 },
	["item/me-16k-storage-component"] = { filename = "__me-network-ae2-textures__/graphics/icons/cells/me-16k-storage-component.png", icon_size = 32 },
	["item/me-64k-storage-component"] = { filename = "__me-network-ae2-textures__/graphics/icons/cells/me-64k-storage-component.png", icon_size = 32 },
	["item/me-256k-storage-component"] = { filename = "__me-network-ae2-textures__/graphics/icons/cells/me-256k-storage-component.png", icon_size = 32 },
	["item/basic-storage-housing"] = { filename = "__me-network-ae2-textures__/graphics/icons/cells/basic-storage-housing.png", icon_size = 32 },
	--- upgrade cards (32 px); the ME Interface Capacity Card has no AE2 counterpart and keeps its icon
	["item/me-basic-card"] = { filename = "__me-network-ae2-textures__/graphics/icons/cards/me-basic-card.png", icon_size = 32 },
	["item/me-advanced-card"] = { filename = "__me-network-ae2-textures__/graphics/icons/cards/me-advanced-card.png", icon_size = 32 },
	["item/me-capacity-card"] = { filename = "__me-network-ae2-textures__/graphics/icons/cards/me-capacity-card.png", icon_size = 32 },
	["item/me-overflow-destruction-card"] = { filename = "__me-network-ae2-textures__/graphics/icons/cards/me-overflow-destruction-card.png", icon_size = 32 },
	["item/me-fuzzy-card"] = { filename = "__me-network-ae2-textures__/graphics/icons/cards/me-fuzzy-card.png", icon_size = 32 },
	["item/me-pattern-capacity-card"] = { filename = "__me-network-ae2-textures__/graphics/icons/cards/me-pattern-capacity-card.png", icon_size = 32 },
	["item/me-sticky-card"] = { filename = "__me-network-ae2-textures__/graphics/icons/cards/me-sticky-card.png", icon_size = 32 },
	["item/me-inverter-card"] = { filename = "__me-network-ae2-textures__/graphics/icons/cards/me-inverter-card.png", icon_size = 32 },
	["item/me-equal-distribution-card"] = { filename = "__me-network-ae2-textures__/graphics/icons/cards/me-equal-distribution-card.png", icon_size = 32 },
	["module/me-acceleration-card"] = { filename = "__me-network-ae2-textures__/graphics/icons/cards/me-acceleration-card.png", icon_size = 32 },
	--- patterns (32 px)
	["item/me-blank-pattern"] = { filename = "__me-network-ae2-textures__/graphics/icons/patterns/me-blank-pattern.png", icon_size = 32 },
	["item-with-tags/me-encoded-pattern"] = { filename = "__me-network-ae2-textures__/graphics/icons/patterns/me-encoded-pattern.png", icon_size = 32 },
}
