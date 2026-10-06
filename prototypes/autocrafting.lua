--------------------------------------------------------------------------------
--- ME NETWORK: AUTOCRAFTING (on top of the ME network of network.lua)
---   * Molecular Assembler = assembling machine for item-only crafting recipes. Set its
---                           recipe like any assembler; the recipe becomes a pattern.
---   * Pattern Provider    = small ME block with 9 slots for encoded patterns (issue #80), placed
---                           next to machines (any crafting machine, furnace, Molecular Assembler) or a chest.
---                           Each pattern in it is a pattern of the ME network it is connected to:
---                           a crafting pattern sets its recipe on an assembling machine next to it,
---                           a processing pattern pushes its inputs into a machine or chest.
---   * Blank Pattern       = cheap item, encoded in the Patterns tab of the ME Terminal into an
---     Encoded Pattern       item with tags (stack size 1) that carries the pattern; clearing it
---                           there gives the blank back (scripts/fork-me-patterns.lua).
---   * Crafting CPU        = powered entity of the ME network, runs one crafting job at a time.
---                           Two bigger tiers (issue #38) run more jobs at once and move more
---                           items per step: Co-Processing and Quantum Crafting CPU.
---   * Level Maintainer    = 1x1 block (power through the controller) that keeps N of an item or fluid in stock: it starts
---                           a crafting job for the difference (issue #38). Its lamp circuit
---                           condition switches it on and off.
---   * Circuit Interface   = constant combinator that puts the items and fluids of its ME network
---                           (all, or a filtered set) onto the circuit wire (issue #38).
---   * The planning and item moving is done by scripts/fork-me-autocraft.lua, the GUI is part of
---     the ME Terminal (scripts/fork-me-terminal.lua); maintainer and circuit interface live in
---     scripts/fork-me-circuit.lua. CPU tier numbers go to the runtime through the mod-data
---     "fork-me-autocraft".
--- Sprites and icons: tools/gen_ae2_sprites.py.
--------------------------------------------------------------------------------

local ME = ME_NETWORK
local ENTITY_PATH = ME.entity_path
local ICON_FORK = ME.icons .. "fork/"
local function I(list) local t = {} for i = 1, #list, 2 do t[#t + 1] = { type = "item", name = list[i], amount = list[i + 1] } end return t end

--------------------------------------------------------------------------------
--- ITEMS AND RECIPES
--------------------------------------------------------------------------------

ME.add_item{
	name = "me-pattern-provider",
	icon = ICON_FORK .. "me-pattern-provider.png",
	subgroup = "fork-me-network",
	order = "e",
	stack_size = 50,
	place_result = "me-pattern-provider",
	recipe = { energy_required = 5, ingredients = I{ "me-interface", 1, "processing-unit", 2, "fluix-cable", 4 } },
}

--- issue #80: a cheap blank pattern (AE2: quartz glass, certus quartz, iron)
ME.add_item{
	name = "me-blank-pattern",
	icon = ICON_FORK .. "me-blank-pattern.png",
	subgroup = "fork-me-network",
	order = "e1",
	stack_size = 64,
	recipe = { energy_required = 1, ingredients = I{ "iron-plate", 2, "electronic-circuit", 1, "fluix-cable", 1 } },
}

--- the encoded pattern: no recipe, made from a blank pattern in the ME Terminal (its tag fork_me_pattern holds it)
data:extend({ {
	type = "item-with-tags",
	name = "me-encoded-pattern",
	icon = ICON_FORK .. "me-encoded-pattern.png",
	icon_size = 32,
	subgroup = "fork-me-network",
	order = "e2",
	stack_size = 1,
	localised_description = { "item-description.me-encoded-pattern" },
} })

ME.add_item{
	name = "me-molecular-assembler",
	icon = ICON_FORK .. "me-molecular-assembler.png",
	subgroup = "fork-me-network",
	order = "f",
	stack_size = 10,
	place_result = "me-molecular-assembler",
	recipe = { energy_required = 5, ingredients = I{ "assembling-machine-2", 1, "processing-unit", 2, "fluix-cable", 4 } },
}

ME.add_item{
	name = "me-crafting-cpu",
	icon = ICON_FORK .. "me-crafting-cpu.png",
	subgroup = "fork-me-network",
	order = "g",
	stack_size = 10,
	place_result = "me-crafting-cpu",
	recipe = { energy_required = 10, ingredients = I{ "me-controller", 1, "me-64k-storage-component", 2, "processing-unit", 4, "fluix-cable", 8 } },
}



--------------------------------------------------------------------------------
--- PATTERN PROVIDER (passive marker, no power: it only tells the network which machine to use)
--------------------------------------------------------------------------------

data:extend({ {
	type = "simple-entity-with-force",
	name = "me-pattern-provider",
	icon = ICON_FORK .. "me-pattern-provider.png",
	icon_size = 32,
	flags = { "placeable-neutral", "player-creation" },
	minable = { mining_time = 0.2, result = "me-pattern-provider" },
	max_health = 150,
	corpse = "small-remnants",
	collision_box = { { -0.35, -0.35 }, { 0.35, 0.35 } },
	selection_box = { { -0.5, -0.5 }, { 0.5, 0.5 } },
	selection_priority = 60,
	additional_pastable_entities = { "me-pattern-provider" },   -- settings paste copies the priority (issue #80)
	picture = {
		filename = ENTITY_PATH .. "me-pattern-provider.png",
		priority = "extra-high",
		width = 32, height = 32,
	},
	localised_description = { "entity-description.me-pattern-provider" },
} })



--------------------------------------------------------------------------------
--- MOLECULAR ASSEMBLER (item recipes only, so no fluid boxes; prototypes/api.lua builds it)
--------------------------------------------------------------------------------

--- standalone: a copy of the assembling machine 2 for its item categories (no fluid boxes), faster
local item_categories = {}
for _, c in pairs(data.raw["assembling-machine"]["assembling-machine-2"].crafting_categories) do
	if not c:find("fluid") then item_categories[#item_categories + 1] = c end
end
ME.make_molecular_assembler{ base = "assembling-machine-2", crafting_categories = item_categories,
	crafting_speed = 2.5, energy_usage = "375kW" }



--------------------------------------------------------------------------------
--- CRAFTING CPU (2x2 lamp like the ME Terminal: needs power, shows "no power" otherwise)
--------------------------------------------------------------------------------

local cpu = table.deepcopy(data.raw.lamp["small-lamp"])
cpu.name = "me-crafting-cpu"
cpu.icon = ICON_FORK .. "me-crafting-cpu.png"
cpu.icon_size = 32
cpu.minable = { mining_time = 0.3, result = "me-crafting-cpu" }
cpu.max_health = 300
cpu.corpse = "small-remnants"
cpu.dying_explosion = nil
cpu.collision_box = { { -0.8, -0.8 }, { 0.8, 0.8 } }
cpu.selection_box = { { -1, -1 }, { 1, 1 } }
cpu.energy_usage_per_tick = "60kW"
cpu.always_on = true
cpu.light = nil
cpu.light_when_colored = nil
cpu.picture_off = { layers = { {
	filename = ENTITY_PATH .. "me-crafting-cpu-off.png",
	priority = "high", width = 64, height = 64,
} } }
cpu.picture_on = {
	filename = ENTITY_PATH .. "me-crafting-cpu-on.png",
	priority = "high", width = 64, height = 64,
}
cpu.fast_replaceable_group = "me-crafting-cpu"
cpu.next_upgrade = "me-co-processing-cpu"
cpu.localised_description = { "entity-description.me-crafting-cpu" }
data:extend({ cpu })



--------------------------------------------------------------------------------
--- CPU TIERS (issue #38): the same 2x2 block, more jobs at once and more machine hand-overs per
--- step. Upgrade planner and fast replace swap the tiers (a job on a replaced CPU pauses and goes on
--- on the next free one).
--------------------------------------------------------------------------------

--- name -> parallel jobs, speed (machine hand-overs per step, times the base CPU's), power, tier of the sprite
local CPU_TIERS = {
	{ name = "me-crafting-cpu",         jobs = 1, speed = 1, power = "60kW" },
	{ name = "me-co-processing-cpu",    jobs = 2, speed = 2, power = "240kW", next = "me-quantum-crafting-cpu" },
	{ name = "me-quantum-crafting-cpu", jobs = 4, speed = 4, power = "960kW" },
}

for i, t in ipairs(CPU_TIERS) do
	if i > 1 then
		local e = table.deepcopy(cpu)
		e.name = t.name
		e.icon = ICON_FORK .. t.name .. ".png"
		e.minable = { mining_time = 0.3, result = t.name }
		e.energy_usage_per_tick = t.power
		e.picture_off = { layers = { {
			filename = ENTITY_PATH .. t.name .. "-off.png",
			priority = "high", width = 64, height = 64,
		} } }
		e.picture_on = {
			filename = ENTITY_PATH .. t.name .. "-on.png",
			priority = "high", width = 64, height = 64,
		}
		e.next_upgrade = t.next
		e.localised_description = { "entity-description.fork-me-crafting-cpu-tier", tostring(t.jobs), tostring(t.speed) }
		data:extend({ e })
	end
end

ME.add_item{
	name = "me-co-processing-cpu",
	icon = ICON_FORK .. "me-co-processing-cpu.png",
	subgroup = "fork-me-network",
	order = "g2",
	stack_size = 10,
	place_result = "me-co-processing-cpu",
	recipe = { energy_required = 10, ingredients = I{ "me-crafting-cpu", 1, "me-256k-storage-component", 2, "processing-unit", 10, "fluix-cable", 16 } },
}

ME.add_item{
	name = "me-quantum-crafting-cpu",
	icon = ICON_FORK .. "me-quantum-crafting-cpu.png",
	subgroup = "fork-me-network",
	order = "g3",
	stack_size = 10,
	place_result = "me-quantum-crafting-cpu",
	recipe = { energy_required = 10, ingredients = I{ "me-co-processing-cpu", 1, "me-256k-storage-component", 4, "processing-unit", 20, "fluix-cable", 32 } },
}

local cpu_data = {}
for _, t in ipairs(CPU_TIERS) do cpu_data[t.name] = { jobs = t.jobs, speed = t.speed } end

--- issue #6: the three single-entity CPUs are legacy blocks. They keep working (job slots, speed, no byte limit), but
--- no recipe makes them any more (data-final-fixes.lua also deletes the recipes another mod gives them); a player who
--- holds one can still place it. Their technologies unlock the crafting blocks below.
for _, t in ipairs(CPU_TIERS) do
	ME.removed[t.name] = "me-1k-crafting-storage"
	data.raw.item[t.name].localised_description = { "item-description.fork-me-legacy-cpu" }
end



--------------------------------------------------------------------------------
--- CRAFTING CPU MULTIBLOCKS (issue #6, docs/ME-REWORK.md "Crafting CPUs as multiblocks"): 1x1 crafting blocks; any
--- group of touching blocks that is a solid rectangle with at least one crafting storage is a Crafting CPU running one
--- job (scripts/fork-me-autocraft.lua). The blocks are ME network members without a power connection of their own:
--- the ME Controller draws their power (`power`, in W, read by scripts/fork-me-network.lua). Picture variation 1: the
--- block of a group that is no CPU (dark), 2: of a CPU (lit). AE2's numbers: block/crafting/CraftingUnitType.java.
--------------------------------------------------------------------------------

--- name, bytes of crafting storage, co-processors, monitor, power, order, recipe (besides the crafting unit), tech
local BLOCKS = {
	{ name = "me-crafting-unit", bytes = 0, power = 4000, order = "h0",
	  ingredients = I{ "iron-plate", 4, "advanced-circuit", 2, "fluix-cable", 2, "electronic-circuit", 1 }, tech = "me-autocrafting" },
	{ name = "me-1k-crafting-storage", bytes = 1024, power = 4000, order = "h1", component = "me-1k-storage-component", tech = "me-autocrafting" },
	{ name = "me-4k-crafting-storage", bytes = 4096, power = 8000, order = "h2", component = "me-4k-storage-component", tech = "me-autocrafting" },
	{ name = "me-16k-crafting-storage", bytes = 16384, power = 16000, order = "h3", component = "me-16k-storage-component", tech = "me-co-processing" },
	{ name = "me-64k-crafting-storage", bytes = 65536, power = 32000, order = "h4", component = "me-64k-storage-component", tech = "me-co-processing" },
	{ name = "me-256k-crafting-storage", bytes = 262144, power = 64000, order = "h5", component = "me-256k-storage-component", tech = "me-quantum-crafting" },
	{ name = "me-crafting-co-processing-unit", bytes = 0, coprocessors = 1, power = 32000, order = "h6",
	  ingredients = I{ "me-crafting-unit", 1, "processing-unit", 1 }, tech = "me-co-processing" },
	{ name = "me-crafting-monitor", bytes = 0, monitor = true, power = 4000, order = "h7",
	  ingredients = I{ "me-crafting-unit", 1, "small-lamp", 1, "electronic-circuit", 1 }, tech = "me-autocrafting" },
}

data:extend({ { type = "item-subgroup", name = "fork-me-crafting-cpu", group = data.raw["item-subgroup"]["fork-me-network"].group,
	order = "b-me-c" } })

local block_data, block_tech = {}, {}
for _, b in ipairs(BLOCKS) do
	local ingredients = b.ingredients or I{ "me-crafting-unit", 1, b.component, 1 }
	local description = b.bytes > 0 and { "entity-description.fork-me-crafting-storage", tostring(b.bytes) }
		or { "entity-description." .. b.name }
	ME.add_item{
		name = b.name,
		icon = ICON_FORK .. b.name .. ".png",
		subgroup = "fork-me-crafting-cpu",
		order = b.order,
		stack_size = 50,
		place_result = b.name,
		localised_description = description,
		recipe = { energy_required = 2, ingredients = ingredients },
	}
	data:extend({ {
		type = "simple-entity-with-force",
		name = b.name,
		icon = ICON_FORK .. b.name .. ".png",
		icon_size = 32,
		flags = { "placeable-neutral", "player-creation" },
		minable = { mining_time = 0.2, result = b.name },
		placeable_by = { item = b.name, count = 1 },
		max_health = 200,
		is_military_target = false,
		corpse = "small-remnants",
		collision_box = { { -0.35, -0.35 }, { 0.35, 0.35 } },
		selection_box = { { -0.5, -0.5 }, { 0.5, 0.5 } },
		fast_replaceable_group = "me-crafting-block",
		--- the sheet holds the dark and the lit picture side by side (tools/gen_ae2_sprites.py --crafting-cpu)
		pictures = {
			{ filename = ENTITY_PATH .. b.name .. ".png", priority = "high", width = 32, height = 32, x = 0 },
			{ filename = ENTITY_PATH .. b.name .. ".png", priority = "high", width = 32, height = 32, x = 32 },
		},
		localised_description = description,
	} })
	block_data[b.name] = { bytes = b.bytes, coprocessors = b.coprocessors or 0, monitor = b.monitor or false, power = b.power }
	block_tech[b.tech] = block_tech[b.tech] or {}
	table.insert(block_tech[b.tech], b.name)
end



--------------------------------------------------------------------------------
--- LEVEL MAINTAINER (issue #38): keeps N of an item or fluid in stock. A 1x1 lamp like the ME
--- Terminal; since issue #128 it needs no pole: the ME Controller draws its power (a lamp with a void energy source,
--- `member_power` of the mod-data "fork-me-network"). The lamp's circuit condition (kept on the entity, so the game
--- copies and blueprints it) switches it on and off. Target, amount and the condition are set in its ME window
--- (scripts/fork-me-windows.lua), which replaces the lamp's window.
--------------------------------------------------------------------------------

ME.add_item{
	name = "me-level-maintainer",
	icon = ICON_FORK .. "me-level-maintainer.png",
	subgroup = "fork-me-network",
	order = "g4",
	stack_size = 50,
	place_result = "me-level-maintainer",
	recipe = { energy_required = 5, ingredients = I{ "me-interface", 1, "decider-combinator", 1, "advanced-circuit", 2, "fluix-cable", 4 } },
}

local maintainer = table.deepcopy(data.raw.lamp["small-lamp"])
maintainer.name = "me-level-maintainer"
maintainer.icon = ICON_FORK .. "me-level-maintainer.png"
maintainer.icon_size = 32
maintainer.minable = { mining_time = 0.2, result = "me-level-maintainer" }
maintainer.max_health = 200
maintainer.corpse = "small-remnants"
maintainer.dying_explosion = nil
maintainer.collision_box = { { -0.35, -0.35 }, { 0.35, 0.35 } }
maintainer.selection_box = { { -0.5, -0.5 }, { 0.5, 0.5 } }
local MAINTAINER_POWER = 30000          -- W drawn through the ME Controller (issue #128: what it drew from a pole before)
maintainer.energy_source = { type = "void" }
maintainer.energy_usage_per_tick = (MAINTAINER_POWER / 1000) .. "kW"
maintainer.always_on = true
maintainer.light = nil
maintainer.light_when_colored = nil
maintainer.picture_off = { layers = { {
	filename = ENTITY_PATH .. "me-level-maintainer-off.png",
	priority = "high", width = 32, height = 32,
} } }
maintainer.picture_on = {
	filename = ENTITY_PATH .. "me-level-maintainer-on.png",
	priority = "high", width = 32, height = 32,
}
maintainer.fast_replaceable_group = nil
maintainer.next_upgrade = nil
maintainer.localised_description = { "entity-description.me-level-maintainer", tostring(MAINTAINER_POWER / 1000) }
data:extend({ maintainer })
data.raw["mod-data"]["fork-me-network"].data.member_power.maintainer = MAINTAINER_POWER



--------------------------------------------------------------------------------
--- CIRCUIT INTERFACE (issue #38): a constant combinator whose signals the runtime writes: the
--- items and fluids of its ME network, or the filtered ones. No power (like the pattern provider).
--------------------------------------------------------------------------------

ME.add_item{
	name = "me-circuit-interface",
	icon = ICON_FORK .. "me-circuit-interface.png",
	subgroup = "fork-me-network",
	order = "g5",
	stack_size = 50,
	place_result = "me-circuit-interface",
	recipe = { energy_required = 5, ingredients = I{ "me-interface", 1, "constant-combinator", 1, "advanced-circuit", 2, "fluix-cable", 4 } },
}

local circuit = table.deepcopy(data.raw["constant-combinator"]["constant-combinator"])
circuit.name = "me-circuit-interface"
circuit.icon = ICON_FORK .. "me-circuit-interface.png"
circuit.icon_size = 32
circuit.icons = nil
circuit.minable = { mining_time = 0.2, result = "me-circuit-interface" }
circuit.max_health = 200
circuit.corpse = "small-remnants"
circuit.dying_explosion = nil
circuit.sprites = {
	filename = ENTITY_PATH .. "me-circuit-interface.png",
	priority = "high", width = 32, height = 32,
}
circuit.fast_replaceable_group = nil
circuit.next_upgrade = nil
circuit.localised_description = { "entity-description.me-circuit-interface" }
data:extend({ circuit })



--------------------------------------------------------------------------------
--- MOD DATA (read by scripts/fork-me-autocraft.lua: no duplicated numbers)
--------------------------------------------------------------------------------

data:extend({ {
	type = "mod-data",
	name = "fork-me-autocraft",
	--- issue #6: the crafting blocks; a fluid ingredient costs 1 byte per this many units (items 1 byte each); at most
	--- this many co-processors of a CPU count
	data = { cpus = cpu_data, blocks = block_data, fluid_units_per_byte = 10, max_coprocessors = 16 },
} })



--------------------------------------------------------------------------------
--- TECHNOLOGIES (standalone: vanilla science)
--------------------------------------------------------------------------------

--- issue #6: the legacy CPUs have no recipe any more (ME.removed: data-final-fixes.lua drops their unlocks); the
--- technologies unlock the crafting blocks (block_tech)
local function with_blocks(tech, recipes)
	for _, name in ipairs(block_tech[tech] or {}) do recipes[#recipes + 1] = name end
	return recipes
end

ME.add_technology{ name = "me-autocrafting", prerequisites = { "me-storage-64k", "automation-2" }, unit = ME.unit(3, 500),
	recipes = with_blocks("me-autocrafting", { "me-pattern-provider", "me-blank-pattern", "me-molecular-assembler" }) }

--- issue #38: level maintainer and circuit interface, bigger CPUs
ME.add_technology{ name = "me-automation", prerequisites = { "me-autocrafting", "circuit-network" }, unit = ME.unit(3, 500),
	recipes = { "me-level-maintainer", "me-circuit-interface" } }
ME.add_technology{ name = "me-co-processing", prerequisites = { "me-autocrafting", "me-storage-256k" },
	unit = ME.unit(4, 800), recipes = with_blocks("me-co-processing", {}) }
ME.add_technology{ name = "me-quantum-crafting", prerequisites = { "me-co-processing", "utility-science-pack" },
	unit = ME.unit(5, 1000), recipes = with_blocks("me-quantum-crafting", {}) }

--- issue #6: data-final-fixes.lua puts a crafting block recipe that no technology unlocks (another mod replaced the
--- technology's recipe list) back on its technology
ME.crafting_block_tech = {}
for tech, names in pairs(block_tech) do
	for _, name in ipairs(names) do ME.crafting_block_tech[name] = tech end
end
