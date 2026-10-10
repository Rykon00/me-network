--- The sprites of ME Network that this mod replaces (issue #239), read by data-final-fixes.lua. ME Network issue #236
--- lists the groups; issue #247 brought the first ones: the item icons of the cells, cards and patterns, from
--- AE2-Unofficial (MANIFEST.tsv), each scaled to the size of the icon it replaces (tools/scale_ae2_icons.py); the fluid
--- cells (#250) and the interface capacity card (#251), which AE2-Unofficial has no icon for, are related icons of it
--- in other colours. Each entry names its icon_size, so it stays right when ME Network draws its own icon at another size.
--- Issue #260 brought the first blocks: their pictures and icons made from AE2-Unofficial faces (tools/ae2_blocks.py).
--- Issue #278 the ME Controller: its picture is AE2's controller without power; data-updates.lua gives ME Network the lit
--- and the conflict pictures for its controller view.
--- Issue #281 the ME Terminal and the ME Pattern Terminal: AE2's terminal panels, dark and lit.
--- Issue #282 the ME Import, Export and Storage Bus: AE2's fronts as blocks; ME Network's marker (the plate on the side a
--- bus faces and its arrows) is a layer of its own above them, which data-updates.lua moves onto the AE2 face.
--- Issue #283 the cable: AE2's Fluix glass cable in the 16 variations of ME Network's cable sheet.
--- Issue #302 the blocks of a Crafting CPU: AE2 cubes, without a CPU and in AE2's formed look, in ME Network's sheet.
--- Issue #303 the wireless group: the access point as a block, the terminal, its module and the booster as AE2's icons.
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
	--- issues #251, #294: no AE2 counterpart, so the Capacity Card with its capacity sign in orange (not the Pattern
	--- Capacity Card's look: a dark sign and a turquoise stripe)
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
	--- the pattern provider (issue #269): AE2-Unofficial has none, so its purple interface skin (BlockInterfaceAlternate_Purple)
	["simple-entity-with-force/me-pattern-provider"] = {
		["__me-network__/graphics/entity/fork/ae2/hd/me-pattern-provider.png"] = "__me-network-ae2-textures__/graphics/blocks/me-pattern-provider.png",
		["__me-network__/graphics/icons/hd/me-pattern-provider.png"] = { filename = "__me-network-ae2-textures__/graphics/icons/blocks/me-pattern-provider.png", icon_size = 64 },
	},
	["item/me-pattern-provider"] = { filename = "__me-network-ae2-textures__/graphics/icons/blocks/me-pattern-provider.png", icon_size = 64 },
	--- the controller (issue #278, 2 x 2 tiles): four AE2 controllers without power, 128 px like ME Network's picture
	["electric-energy-interface/me-network-controller"] = {
		["__me-network__/graphics/entity/fork/ae2/hd/me-network-controller.png"] = "__me-network-ae2-textures__/graphics/blocks/me-controller.png",
		["__me-network__/graphics/icons/hd/me-controller.png"] = { filename = "__me-network-ae2-textures__/graphics/icons/blocks/me-controller.png", icon_size = 64 },
	},
	["item/me-controller"] = { filename = "__me-network-ae2-textures__/graphics/icons/blocks/me-controller.png", icon_size = 64 },
	--- the terminals (issue #281): AE2's 12 x 12 panel x3, dark and with its screen in the Fluix colours. The terminal is a lamp
	--- with the dark picture; ME Network's script draws the screen (dark or lit) over it from the two sprites. The pattern
	--- terminal's sheet holds its two variations side by side (dark, lit), as ME Network's does.
	["lamp/me-terminal"] = {
		["__me-network__/graphics/entity/fork/ae2/hd/me-terminal-off.png"] = "__me-network-ae2-textures__/graphics/blocks/me-terminal-off.png",
		["__me-network__/graphics/icons/hd/me-terminal.png"] = { filename = "__me-network-ae2-textures__/graphics/icons/blocks/me-terminal.png", icon_size = 64 },
	},
	["sprite/me-terminal-screen-off"] = "__me-network-ae2-textures__/graphics/blocks/me-terminal-off.png",
	["sprite/me-terminal-screen-on"] = "__me-network-ae2-textures__/graphics/blocks/me-terminal-lit.png",
	["item/me-terminal"] = { filename = "__me-network-ae2-textures__/graphics/icons/blocks/me-terminal.png", icon_size = 64 },
	["simple-entity-with-force/me-pattern-terminal"] = {
		["__me-network__/graphics/entity/fork/ae2/hd/me-pattern-terminal.png"] = "__me-network-ae2-textures__/graphics/blocks/me-pattern-terminal.png",
		["__me-network__/graphics/icons/hd/me-pattern-terminal.png"] = { filename = "__me-network-ae2-textures__/graphics/icons/blocks/me-pattern-terminal.png", icon_size = 64 },
	},
	["item/me-pattern-terminal"] = { filename = "__me-network-ae2-textures__/graphics/icons/blocks/me-pattern-terminal.png", icon_size = 64 },
	--- the buses (issue #282): AE2's front of each, the same block in every direction (AE2's front shows none: ME Network's
	--- marker layer stays and shows it); only the first layer of each direction is replaced
	["simple-entity-with-force/me-import-bus"] = {
		["__me-network__/graphics/entity/fork/ae2/hd/me-import-bus-north.png"] = "__me-network-ae2-textures__/graphics/blocks/me-import-bus.png",
		["__me-network__/graphics/entity/fork/ae2/hd/me-import-bus-east.png"] = "__me-network-ae2-textures__/graphics/blocks/me-import-bus.png",
		["__me-network__/graphics/entity/fork/ae2/hd/me-import-bus-south.png"] = "__me-network-ae2-textures__/graphics/blocks/me-import-bus.png",
		["__me-network__/graphics/entity/fork/ae2/hd/me-import-bus-west.png"] = "__me-network-ae2-textures__/graphics/blocks/me-import-bus.png",
		["__me-network__/graphics/icons/hd/me-import-bus.png"] = { filename = "__me-network-ae2-textures__/graphics/icons/blocks/me-import-bus.png", icon_size = 64 },
	},
	["item/me-import-bus"] = { filename = "__me-network-ae2-textures__/graphics/icons/blocks/me-import-bus.png", icon_size = 64 },
	["simple-entity-with-force/me-export-bus"] = {
		["__me-network__/graphics/entity/fork/ae2/hd/me-export-bus-north.png"] = "__me-network-ae2-textures__/graphics/blocks/me-export-bus.png",
		["__me-network__/graphics/entity/fork/ae2/hd/me-export-bus-east.png"] = "__me-network-ae2-textures__/graphics/blocks/me-export-bus.png",
		["__me-network__/graphics/entity/fork/ae2/hd/me-export-bus-south.png"] = "__me-network-ae2-textures__/graphics/blocks/me-export-bus.png",
		["__me-network__/graphics/entity/fork/ae2/hd/me-export-bus-west.png"] = "__me-network-ae2-textures__/graphics/blocks/me-export-bus.png",
		["__me-network__/graphics/icons/hd/me-export-bus.png"] = { filename = "__me-network-ae2-textures__/graphics/icons/blocks/me-export-bus.png", icon_size = 64 },
	},
	["item/me-export-bus"] = { filename = "__me-network-ae2-textures__/graphics/icons/blocks/me-export-bus.png", icon_size = 64 },
	["simple-entity-with-force/me-storage-bus"] = {
		["__me-network__/graphics/entity/fork/ae2/hd/me-storage-bus-north.png"] = "__me-network-ae2-textures__/graphics/blocks/me-storage-bus.png",
		["__me-network__/graphics/entity/fork/ae2/hd/me-storage-bus-east.png"] = "__me-network-ae2-textures__/graphics/blocks/me-storage-bus.png",
		["__me-network__/graphics/entity/fork/ae2/hd/me-storage-bus-south.png"] = "__me-network-ae2-textures__/graphics/blocks/me-storage-bus.png",
		["__me-network__/graphics/entity/fork/ae2/hd/me-storage-bus-west.png"] = "__me-network-ae2-textures__/graphics/blocks/me-storage-bus.png",
		["__me-network__/graphics/icons/hd/me-storage-bus.png"] = { filename = "__me-network-ae2-textures__/graphics/icons/blocks/me-storage-bus.png", icon_size = 64 },
	},
	["item/me-storage-bus"] = { filename = "__me-network-ae2-textures__/graphics/icons/blocks/me-storage-bus.png", icon_size = 64 },
	--- the cable (issue #283): the sheet of its 16 variations, in ME Network's layout; the item and the entity show the crossing
	["simple-entity-with-force/me-cable"] = {
		["__me-network__/graphics/entity/fork/ae2/hd/me-cable.png"] = "__me-network-ae2-textures__/graphics/blocks/me-cable.png",
		["__me-network__/graphics/icons/hd/me-cable.png"] = { filename = "__me-network-ae2-textures__/graphics/icons/blocks/me-cable.png", icon_size = 64 },
	},
	["item/fluix-cable"] = { filename = "__me-network-ae2-textures__/graphics/icons/blocks/me-cable.png", icon_size = 64 },
	--- the crafting blocks (issue #302): each a sheet of ME Network's 48 variations (16 without a CPU, 32 of a CPU: AE2's
	--- formed look); a cube each, not ME Network's slab
	["simple-entity-with-force/me-crafting-unit"] = {
		["__me-network__/graphics/entity/fork/ae2/hd/me-crafting-unit.png"] = "__me-network-ae2-textures__/graphics/blocks/crafting/me-crafting-unit.png",
		["__me-network__/graphics/icons/hd/me-crafting-unit.png"] = { filename = "__me-network-ae2-textures__/graphics/icons/blocks/me-crafting-unit.png", icon_size = 64 },
	},
	["item/me-crafting-unit"] = { filename = "__me-network-ae2-textures__/graphics/icons/blocks/me-crafting-unit.png", icon_size = 64 },
	["simple-entity-with-force/me-crafting-co-processing-unit"] = {
		["__me-network__/graphics/entity/fork/ae2/hd/me-crafting-co-processing-unit.png"] = "__me-network-ae2-textures__/graphics/blocks/crafting/me-crafting-co-processing-unit.png",
		["__me-network__/graphics/icons/hd/me-crafting-co-processing-unit.png"] = { filename = "__me-network-ae2-textures__/graphics/icons/blocks/me-crafting-co-processing-unit.png", icon_size = 64 },
	},
	["item/me-crafting-co-processing-unit"] = { filename = "__me-network-ae2-textures__/graphics/icons/blocks/me-crafting-co-processing-unit.png", icon_size = 64 },
	["simple-entity-with-force/me-1k-crafting-storage"] = {
		["__me-network__/graphics/entity/fork/ae2/hd/me-1k-crafting-storage.png"] = "__me-network-ae2-textures__/graphics/blocks/crafting/me-1k-crafting-storage.png",
		["__me-network__/graphics/icons/hd/me-1k-crafting-storage.png"] = { filename = "__me-network-ae2-textures__/graphics/icons/blocks/me-1k-crafting-storage.png", icon_size = 64 },
	},
	["item/me-1k-crafting-storage"] = { filename = "__me-network-ae2-textures__/graphics/icons/blocks/me-1k-crafting-storage.png", icon_size = 64 },
	["simple-entity-with-force/me-4k-crafting-storage"] = {
		["__me-network__/graphics/entity/fork/ae2/hd/me-4k-crafting-storage.png"] = "__me-network-ae2-textures__/graphics/blocks/crafting/me-4k-crafting-storage.png",
		["__me-network__/graphics/icons/hd/me-4k-crafting-storage.png"] = { filename = "__me-network-ae2-textures__/graphics/icons/blocks/me-4k-crafting-storage.png", icon_size = 64 },
	},
	["item/me-4k-crafting-storage"] = { filename = "__me-network-ae2-textures__/graphics/icons/blocks/me-4k-crafting-storage.png", icon_size = 64 },
	["simple-entity-with-force/me-16k-crafting-storage"] = {
		["__me-network__/graphics/entity/fork/ae2/hd/me-16k-crafting-storage.png"] = "__me-network-ae2-textures__/graphics/blocks/crafting/me-16k-crafting-storage.png",
		["__me-network__/graphics/icons/hd/me-16k-crafting-storage.png"] = { filename = "__me-network-ae2-textures__/graphics/icons/blocks/me-16k-crafting-storage.png", icon_size = 64 },
	},
	["item/me-16k-crafting-storage"] = { filename = "__me-network-ae2-textures__/graphics/icons/blocks/me-16k-crafting-storage.png", icon_size = 64 },
	["simple-entity-with-force/me-64k-crafting-storage"] = {
		["__me-network__/graphics/entity/fork/ae2/hd/me-64k-crafting-storage.png"] = "__me-network-ae2-textures__/graphics/blocks/crafting/me-64k-crafting-storage.png",
		["__me-network__/graphics/icons/hd/me-64k-crafting-storage.png"] = { filename = "__me-network-ae2-textures__/graphics/icons/blocks/me-64k-crafting-storage.png", icon_size = 64 },
	},
	["item/me-64k-crafting-storage"] = { filename = "__me-network-ae2-textures__/graphics/icons/blocks/me-64k-crafting-storage.png", icon_size = 64 },
	["simple-entity-with-force/me-256k-crafting-storage"] = {
		["__me-network__/graphics/entity/fork/ae2/hd/me-256k-crafting-storage.png"] = "__me-network-ae2-textures__/graphics/blocks/crafting/me-256k-crafting-storage.png",
		["__me-network__/graphics/icons/hd/me-256k-crafting-storage.png"] = { filename = "__me-network-ae2-textures__/graphics/icons/blocks/me-256k-crafting-storage.png", icon_size = 64 },
	},
	["item/me-256k-crafting-storage"] = { filename = "__me-network-ae2-textures__/graphics/icons/blocks/me-256k-crafting-storage.png", icon_size = 64 },
	["simple-entity-with-force/me-crafting-monitor"] = {
		["__me-network__/graphics/entity/fork/ae2/hd/me-crafting-monitor.png"] = "__me-network-ae2-textures__/graphics/blocks/crafting/me-crafting-monitor.png",
		["__me-network__/graphics/icons/hd/me-crafting-monitor.png"] = { filename = "__me-network-ae2-textures__/graphics/icons/blocks/me-crafting-monitor.png", icon_size = 64 },
	},
	["item/me-crafting-monitor"] = { filename = "__me-network-ae2-textures__/graphics/icons/blocks/me-crafting-monitor.png", icon_size = 64 },
	--- the wireless group (issue #303): the access point an AE2 cube of its inside face (AE2's own model is an antenna); the
	--- terminal, its module (AE2 has none: the terminal's icon, also the equipment's sprite) and the booster AE2's icons
	["simple-entity-with-force/me-wireless-access-point"] = {
		["__me-network__/graphics/entity/fork/ae2/hd/me-wireless-access-point.png"] = "__me-network-ae2-textures__/graphics/blocks/me-wireless-access-point.png",
		["__me-network__/graphics/icons/hd/me-wireless-access-point.png"] = { filename = "__me-network-ae2-textures__/graphics/icons/blocks/me-wireless-access-point.png", icon_size = 64 },
	},
	["item/me-wireless-access-point"] = { filename = "__me-network-ae2-textures__/graphics/icons/blocks/me-wireless-access-point.png", icon_size = 64 },
	["item-with-tags/me-wireless-terminal"] = { filename = "__me-network-ae2-textures__/graphics/icons/wireless/me-wireless-terminal.png", icon_size = 32 },
	["item/me-wireless-module"] = { filename = "__me-network-ae2-textures__/graphics/icons/wireless/me-wireless-module.png", icon_size = 32 },
	["battery-equipment/me-wireless-module"] = "__me-network-ae2-textures__/graphics/icons/wireless/me-wireless-module.png",
	["item/me-wireless-booster"] = { filename = "__me-network-ae2-textures__/graphics/icons/wireless/me-wireless-booster.png", icon_size = 32 },
}
