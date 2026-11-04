--------------------------------------------------------------------------------
--- ME NETWORK: THE BLOCKS THAT TAKE CIRCUIT WIRES THEMSELVES (issue #628; runtime: scripts/fork-me-connector.lua, the
--- replacement of old blocks: scripts/fork-me-wired.lua)
--- The ME Import, Export and Storage Bus and the ME Pattern Provider were simple entities, which take no wires: until 0.5.11
--- each had a hidden lamp at its position for the circuit condition (issue #412), a second hitbox in the corner of its tile.
--- Now they are display panels: 1x1, rotatable (Sprite4Way), with a circuit connector, and they send no signals (a display
--- panel only reads its wires); their own window is never shown (on_gui_opened opens the ME window instead). The ME
--- Interface stays a container, which takes the connector as it is (prototypes/network.lua).
--- A prototype's type cannot change in a save (the game would drop the blocks), so the old simple entities keep loading
--- under new names: migrations/me-network-wired-hosts.json renames every placed one, ghost and blueprint of a save
--- `<name>` -> `<name>-legacy` (the same entity, the same unit number), and the runtime replaces each by the wired block of
--- the original name. The wired blocks have the names the blocks always had, so the items, the settings paste, the texture
--- mod, Gregtorio and the blueprints made before (the library's, which no migration touches) need no other name.
--------------------------------------------------------------------------------

local M = {}

M.LEGACY_SUFFIX = "-legacy"

--- the connector box in the south-east corner of the tile, where the hidden lamp of issue #412 had it, in every direction
local function connector()
	local def = { variation = 26, main_offset = util.by_pixel(9, 8), shadow_offset = util.by_pixel(11, 10), show_shadow = true }
	return circuit_connector_definitions.create_vector(universal_connector_template, { def, def, def, def })
end
M.connector = connector

--- A wired block: a display panel with the fields of a block of prototypes/network.lua (block()). `def`: name, item, icon or
--- icons, health, mining_time, description, sprites (a Sprite4Way; one sprite for a block that looks the same in every
--- direction: it turns, but no flag "not-rotatable", which keeps a blueprint holding it from being built turned), collision_mask
--- (nil: solid).
--- (A display panel has no render_layer: the buses, walked over, are drawn in the object layer, no longer below the character.)
function M.block(def)
	local e = {
		type = "display-panel",
		name = def.name,
		icon = def.icon,
		icon_size = def.icon and (def.icon_size or 64) or nil,
		icons = def.icons,
		flags = { "placeable-neutral", "player-creation" },
		minable = { mining_time = def.mining_time or 0.2, result = def.item or def.name },
		placeable_by = { item = def.item or def.name, count = 1 },
		max_health = def.health or 200,
		is_military_target = false,
		corpse = "small-remnants",
		collision_box = def.collision_mask and { { -0.35, -0.35 }, { 0.35, 0.35 } } or ME_NETWORK.solid_box(),
		collision_mask = def.collision_mask,
		selection_box = { { -0.5, -0.5 }, { 0.5, 0.5 } },
		selection_priority = 60,
		sprites = def.sprites,
		circuit_connector = connector(),
		circuit_wire_max_distance = 9,                -- (the lamp's, which the connector of issue #412 was)
		localised_name = { "entity-name." .. def.name },
		localised_description = def.description,
	}
	data:extend({ e })
	return e
end

--- Makes `old` (the simple entity as it was, made under the legacy name `name .. LEGACY_SUFFIX` and placeable by the same
--- item: its ghosts in migrated blueprints are buildable, and the runtime replaces what is built at once) the legacy prototype
--- of `name`: hidden, and colliding with nothing, so the wired block is built on its tile while it still stands and its state
--- moves from the one to the other (scripts/fork-me-wired.lua).
function M.legacy(old, name)
	old.hidden = true
	old.hidden_in_factoriopedia = true
	old.localised_name = { "entity-name." .. name }
	old.collision_mask = { layers = {} }
	old.fast_replaceable_group = nil
	old.next_upgrade = nil
	return old
end

return M
