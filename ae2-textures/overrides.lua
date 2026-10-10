--- The sprites of ME Network that this mod replaces (issue #239), read by data-final-fixes.lua. ME Network issue #236
--- lists the groups; issue #247 brought the first ones: the item icons of the cells, cards and patterns, from
--- AE2-Unofficial (MANIFEST.tsv), each scaled to the size of the icon it replaces (tools/scale_ae2_icons.py); the fluid
--- cells (#250) and the interface capacity card (#251), which AE2-Unofficial has no icon for, are related icons of it
--- in other colours. Each entry names its icon_size, so it stays right when ME Network draws its own icon at another size.
--- Issue #260 brought the first blocks: their pictures and icons made from AE2-Unofficial faces (tools/ae2_blocks.py).
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
	--- storage cells (64 px), their components and the housing (32 px)
	["item-with-tags/me-1k-storage-cell"] = { filename = "__me-network-ae2-textures__/graphics/icons/cells/me-1k-storage-cell.png", icon_size = 64 },
	["item-with-tags/me-4k-storage-cell"] = { filename = "__me-network-ae2-textures__/graphics/icons/cells/me-4k-storage-cell.png", icon_size = 64 },
	["item-with-tags/me-16k-storage-cell"] = { filename = "__me-network-ae2-textures__/graphics/icons/cells/me-16k-storage-cell.png", icon_size = 64 },
	["item-with-tags/me-64k-storage-cell"] = { filename = "__me-network-ae2-textures__/graphics/icons/cells/me-64k-storage-cell.png", icon_size = 64 },
	["item-with-tags/me-256k-storage-cell"] = { filename = "__me-network-ae2-textures__/graphics/icons/cells/me-256k-storage-cell.png", icon_size = 64 },
	--- fluid storage cells (64 px, issue #250): AE2-Unofficial has none, so its item cell of the tier, frame and body blue
	["item-with-tags/me-1k-fluid-storage-cell"] = { filename = "__me-network-ae2-textures__/graphics/icons/cells/me-1k-fluid-storage-cell.png", icon_size = 64 },
	["item-with-tags/me-4k-fluid-storage-cell"] = { filename = "__me-network-ae2-textures__/graphics/icons/cells/me-4k-fluid-storage-cell.png", icon_size = 64 },
	["item-with-tags/me-16k-fluid-storage-cell"] = { filename = "__me-network-ae2-textures__/graphics/icons/cells/me-16k-fluid-storage-cell.png", icon_size = 64 },
	["item-with-tags/me-64k-fluid-storage-cell"] = { filename = "__me-network-ae2-textures__/graphics/icons/cells/me-64k-fluid-storage-cell.png", icon_size = 64 },
	["item-with-tags/me-256k-fluid-storage-cell"] = { filename = "__me-network-ae2-textures__/graphics/icons/cells/me-256k-fluid-storage-cell.png", icon_size = 64 },
	["item/me-1k-storage-component"] = { filename = "__me-network-ae2-textures__/graphics/icons/cells/me-1k-storage-component.png", icon_size = 32 },
	["item/me-4k-storage-component"] = { filename = "__me-network-ae2-textures__/graphics/icons/cells/me-4k-storage-component.png", icon_size = 32 },
	["item/me-16k-storage-component"] = { filename = "__me-network-ae2-textures__/graphics/icons/cells/me-16k-storage-component.png", icon_size = 32 },
	["item/me-64k-storage-component"] = { filename = "__me-network-ae2-textures__/graphics/icons/cells/me-64k-storage-component.png", icon_size = 32 },
	["item/me-256k-storage-component"] = { filename = "__me-network-ae2-textures__/graphics/icons/cells/me-256k-storage-component.png", icon_size = 32 },
	["item/basic-storage-housing"] = { filename = "__me-network-ae2-textures__/graphics/icons/cells/basic-storage-housing.png", icon_size = 32 },
	--- upgrade cards (32 px)
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
	--- issue #251: no AE2 counterpart, so the Capacity Card with the turquoise stripe of an advanced card
	["item/me-interface-capacity-card"] = { filename = "__me-network-ae2-textures__/graphics/icons/cards/me-interface-capacity-card.png", icon_size = 32 },
	--- patterns (32 px)
	["item/me-blank-pattern"] = { filename = "__me-network-ae2-textures__/graphics/icons/patterns/me-blank-pattern.png", icon_size = 32 },
	["item-with-tags/me-encoded-pattern"] = { filename = "__me-network-ae2-textures__/graphics/icons/patterns/me-encoded-pattern.png", icon_size = 32 },
	--- blocks, first group (issue #260, look B of #236: the whole block from AE2): the picture in the world and the icon
	--- (an entity names both; the cell workbench keeps ME Network's shadow layer)
	["simple-entity-with-force/me-drive"] = {
		["__me-network__/graphics/entity/fork/ae2/hd/me-drive.png"] = "__me-network-ae2-textures__/graphics/blocks/me-drive.png",
		["__me-network__/graphics/icons/hd/me-drive.png"] = { filename = "__me-network-ae2-textures__/graphics/icons/blocks/me-drive.png", icon_size = 64 },
	},
	["item/me-drive"] = { filename = "__me-network-ae2-textures__/graphics/icons/blocks/me-drive.png", icon_size = 64 },
	["container/me-chest"] = {
		["__me-network__/graphics/entity/fork/ae2/hd/me-chest.png"] = "__me-network-ae2-textures__/graphics/blocks/me-chest.png",
		["__me-network__/graphics/icons/hd/me-chest.png"] = { filename = "__me-network-ae2-textures__/graphics/icons/blocks/me-chest.png", icon_size = 64 },
	},
	["item/me-chest"] = { filename = "__me-network-ae2-textures__/graphics/icons/blocks/me-chest.png", icon_size = 64 },
	["container/me-network-interface"] = {
		["__me-network__/graphics/entity/fork/ae2/hd/me-interface-unified.png"] = "__me-network-ae2-textures__/graphics/blocks/me-interface.png",
		["__me-network__/graphics/icons/hd/me-interface.png"] = { filename = "__me-network-ae2-textures__/graphics/icons/blocks/me-interface.png", icon_size = 64 },
	},
	["item/me-interface"] = { filename = "__me-network-ae2-textures__/graphics/icons/blocks/me-interface.png", icon_size = 64 },
	["simple-entity-with-force/me-cell-workbench"] = {
		["__me-network__/graphics/entity/fork/ae2/hd/me-cell-workbench.png"] = "__me-network-ae2-textures__/graphics/blocks/me-cell-workbench.png",
		["__me-network__/graphics/icons/hd/me-cell-workbench.png"] = { filename = "__me-network-ae2-textures__/graphics/icons/blocks/me-cell-workbench.png", icon_size = 64 },
	},
	["item/me-cell-workbench"] = { filename = "__me-network-ae2-textures__/graphics/icons/blocks/me-cell-workbench.png", icon_size = 64 },
	["simple-entity-with-force/me-charger"] = {
		["__me-network__/graphics/entity/fork/ae2/hd/me-charger.png"] = "__me-network-ae2-textures__/graphics/blocks/me-charger.png",
		["__me-network__/graphics/icons/hd/me-charger.png"] = { filename = "__me-network-ae2-textures__/graphics/icons/blocks/me-charger.png", icon_size = 64 },
	},
	["item/me-charger"] = { filename = "__me-network-ae2-textures__/graphics/icons/blocks/me-charger.png", icon_size = 64 },
	--- the molecular assembler: idle the block, working the block with AE2's light animation (12 frames of 3 Minecraft
	--- ticks, 0.15 s each at the standalone crafting speed 2.5: the game runs it faster with the crafting speed)
	["assembling-machine/me-molecular-assembler"] = {
		["__me-network__/graphics/entity/fork/ae2/hd/me-molecular-assembler-idle.png"] = { filename = "__me-network-ae2-textures__/graphics/blocks/me-molecular-assembler-idle.png",
			repeat_count = 12 },
		["__me-network__/graphics/entity/fork/ae2/hd/me-molecular-assembler-working.png"] = {
			filename = "__me-network-ae2-textures__/graphics/blocks/me-molecular-assembler-working.png", frame_count = 12, line_length = 1,
			animation_speed = 0.045 },
		["__me-network__/graphics/icons/hd/me-molecular-assembler.png"] = { filename = "__me-network-ae2-textures__/graphics/icons/blocks/me-molecular-assembler.png", icon_size = 64 },
	},
	["item/me-molecular-assembler"] = { filename = "__me-network-ae2-textures__/graphics/icons/blocks/me-molecular-assembler.png", icon_size = 64 },
}
