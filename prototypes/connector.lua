--------------------------------------------------------------------------------
--- ME NETWORK: THE OLD CIRCUIT CONNECTOR (issue #412; since issue #628 only for saves and blueprints of 0.5.11 and before)
--- Until 0.5.11 the ME Import, Export and Storage Bus, the ME Interface and the ME Pattern Provider took no wires, so each had
--- this hidden lamp at its position: a small selection box in the south-east corner of the block's tile, the game's lamp window
--- for the circuit condition. Since issue #628 the blocks take the wires themselves (prototypes/wired.lua); the lamp and its
--- hidden item stay so that saves and blueprints holding them load: the runtime (scripts/fork-me-connector.lua, M.adopt)
--- gives a placed one's or a ghost's wires and condition to the block at its place and removes it. Nothing makes new ones.
--------------------------------------------------------------------------------

local ME = ME_NETWORK
local NAME = "me-circuit-connector"

ME.add_item{
	name = NAME,
	icon = ME.hd_icons .. "me-circuit-interface.png",
	icon_size = 64,
	subgroup = "fork-me-network",
	order = "z-c",
	stack_size = 50,
	place_result = NAME,
	hidden = true,
	recipe = false,                                   -- (no recipe: only old blueprints and copies hold it)
	fields = { hidden_in_factoriopedia = true },
}

local c = table.deepcopy(data.raw.lamp["small-lamp"])
c.name = NAME
c.icon = ME.hd_icons .. "me-circuit-interface.png"
c.icon_size = 64
c.flags = { "placeable-neutral", "player-creation", "not-on-map", "not-deconstructable", "not-upgradable", "not-repairable",
	"not-flammable", "hide-alt-info", "not-in-made-in", "no-automated-item-removal", "no-automated-item-insertion" }
c.hidden_in_factoriopedia = true
c.minable = nil
c.placeable_by = { item = NAME, count = 1 }
c.max_health = 100
c.is_military_target = false
c.corpse = nil
c.dying_explosion = nil
c.collision_box = { { -0.05, -0.05 }, { 0.05, 0.05 } }
c.collision_mask = { layers = {} }
--- the south-east corner of the block's tile, over the block
c.selection_box = { { 0.14, 0.14 }, { 0.48, 0.48 } }
c.selection_priority = 70                         -- (the ME blocks have 60, prototypes/network.lua block())
c.energy_source = { type = "void" }
c.energy_usage_per_tick = "1W"
c.always_on = true
c.light = nil
c.light_when_colored = nil
c.glow_size = 0
c.picture_off = util.empty_sprite()
c.picture_on = util.empty_sprite()
c.circuit_wire_max_distance = 9
c.circuit_connector = circuit_connector_definitions.create_single(universal_connector_template, {
	variation = 26, main_offset = util.by_pixel(9, 8), shadow_offset = util.by_pixel(11, 10), show_shadow = true })
c.fast_replaceable_group = nil
c.next_upgrade = nil
c.water_reflection = nil
c.localised_name = { "entity-name." .. NAME }
c.localised_description = { "entity-description." .. NAME }
data:extend({ c })

data.raw["mod-data"]["fork-me-network"].data.names.connector = NAME
