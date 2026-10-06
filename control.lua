--- ME Network: runtime. The modules keep their names from Gregtorio Continued, where this network was made
--- (scripts/fork-me-*.lua); their state keeps its storage keys, so the hand-over from Gregtorio needs no conversion.

--- the network core: cable graph, controller, drives and cells, storage API
local fork_net = require("scripts.fork-me-network")
--- ME Storage Bus: a chest or cargo wagon, or the fluid segment of a tank, as network storage (its visits run in the
--- I/O step; the fluid side is scripts/fork-me-fluid-storagebus.lua)
local fork_sbus = require("scripts.fork-me-storagebus")
--- ME Interface (items, and fluids through its four sides) and import/export buses, the I/O step (also runs the
--- storage bus visits)
local fork_io = require("scripts.fork-me-io")
--- issue #3: the old fluid blocks (ME Fluid Interface, ME Fluid Import / Export / Storage Bus) become the unified ones
local fork_unify = require("scripts.fork-me-unify")
--- migration of ME networks of Gregtorio Continued 0.3.2 and older (logistic network based)
local fork_migrate = require("scripts.fork-me-migrate")
--- ME terminal (the hub window), routes the GUI events of every ME window (scripts/fork-me-gui.lua)
local fork_me = require("scripts.fork-me-terminal")
--- autocrafting, pattern providers with encoded patterns and crafting CPUs (the pattern items in
--- scripts/fork-me-patterns.lua)
local fork_ae2 = require("scripts.fork-me-autocraft")
--- the fluid calls on top of the storage engine
local fork_fluids = require("scripts.fork-me-fluids")
--- level maintainer and circuit interface
local fork_circuit = require("scripts.fork-me-circuit")
--- the windows of the ME blocks (after the modules whose functions they call)
require("scripts.fork-me-windows")
--- a crafting machine's recipe pasted onto an ME Interface, import, export or storage bus (issue #12)
local fork_paste = require("scripts.fork-me-recipe-paste")
--- the ME Cell Workbench: a cell's partition and upgrade cards (issue #17)
local fork_bench = require("scripts.fork-me-workbench")
--- the one-time hand-over of the state of a Gregtorio Continued save
local handover = require("scripts.fork-me-handover")
--- the scheduler's settings (issue #5)
local sched = require("scripts.fork-me-schedule")
--- the command /me-stats (issue #38, part 3)
require("scripts.fork-me-stats")

--- the blueprint handler of the autocrafting module also tags ME Interfaces, buses and drives
fork_ae2.blueprint_hooks[#fork_ae2.blueprint_hooks + 1] = fork_io.tag_blueprint
fork_ae2.blueprint_hooks[#fork_ae2.blueprint_hooks + 1] = fork_net.tag_blueprint
fork_ae2.blueprint_hooks[#fork_ae2.blueprint_hooks + 1] = fork_sbus.tag_blueprint

local function on_built(entity, tags, event)
	if fork_unify.on_built(entity, tags) then return end      -- an old fluid block (or its ghost): replaced
	fork_net.on_built(entity, event)
	fork_io.on_built(entity, tags)                            -- (any other entity: the buses facing it wake)
	fork_sbus.on_built(entity, tags)
	if entity and entity.valid and not fork_net.kind_of(entity.name) then fork_sbus.wake_near(entity) end
	fork_ae2.on_built(entity, tags)
	fork_circuit.on_built(entity, tags)
	fork_bench.on_built(entity)
end

--- built by players and robots, by other scripts and on space platforms
script.on_event({ defines.events.on_built_entity, defines.events.on_robot_built_entity,
	defines.events.script_raised_built, defines.events.script_raised_revive,
	defines.events.on_space_platform_built_entity }, function(event)
	on_built(event.entity, event.tags, event)
end)

--- cloned entities (e.g. by other mods) need to be registered as well (the settings of drives, interfaces, buses,
--- providers, level maintainers and circuit interfaces are copied; an interface takes its cloned side tanks)
script.on_event(defines.events.on_entity_cloned, function(event)
	if fork_unify.on_built(event.destination) then return end
	fork_net.on_built(event.destination)
	fork_net.on_cloned(event.source, event.destination)
	fork_io.on_built(event.destination, nil, event.source)
	fork_sbus.on_built(event.destination, nil, event.source)
	fork_ae2.on_built(event.destination, nil, event.source)
	fork_circuit.on_built(event.destination, nil, event.source)
	fork_bench.on_built(event.destination)                     -- (a cloned workbench is empty: its cell is an item)
end)

--- the priority of an ME Pattern Provider (its patterns travel in blueprints, see fork-me-autocraft.lua) and the
--- settings of ME Drives, ME Interfaces, buses, storage buses, Level Maintainers and Circuit Interfaces are
--- copied by settings paste and stored in blueprints (the blueprint handler of fork-me-autocraft.lua tags all of them);
--- a crafting machine pasted onto an ME Interface or a bus sets it up for its recipe
script.on_event(defines.events.on_entity_settings_pasted, function(event)
	fork_net.on_entity_settings_pasted(event)
	fork_io.on_entity_settings_pasted(event)
	fork_sbus.on_entity_settings_pasted(event)
	fork_ae2.on_entity_settings_pasted(event)
	fork_circuit.on_entity_settings_pasted(event)
	fork_paste.on_entity_settings_pasted(event)
end)

script.on_event(defines.events.on_player_setup_blueprint, function(event)
	fork_ae2.on_player_setup_blueprint(event)
end)

--- removed ME members. Mined: an ME Drive's cells (with their items and fluids), an ME Pattern Provider's encoded
--- patterns, an ME Storage Bus's cards and the cell in an ME Cell Workbench go into the mined buffer, the fluid in an
--- ME Interface's sides back into the network; destroyed or removed by a script: the cells, patterns and cards are
--- spilled.
--- The I/O module runs first (it looks at the network the entity still belongs to), then the graph is updated.
local REMOVED_FILTER = {}
--- (logistic chests, infinity chests and cargo wagons: the inventory of a storage bus leaves the network at once; pipes,
--- underground pipes and pumps: a removed one may split the fluid segment of a storage bus on fluid)
for _, t in pairs({ "simple-entity-with-force", "storage-tank", "lamp", "electric-energy-interface", "container",
	"constant-combinator", "assembling-machine", "furnace", "logistic-container", "infinity-container", "cargo-wagon", "pipe", "pipe-to-ground",
	"pump" }) do
	REMOVED_FILTER[#REMOVED_FILTER + 1] = { filter = "type", type = t }
end
local function on_mined(event)
	fork_fluids.on_mined_event(event)
	fork_io.on_removed(event.entity, event.buffer or true)      -- (issue #110: a bus's cards go into the buffer)
	fork_sbus.on_removed(event.entity, event.buffer)
	fork_ae2.on_removed(event.entity, event.buffer)
	fork_bench.on_removed(event.entity, event.buffer)
	fork_net.on_removed(event.entity, event.buffer)
end
for _, name in pairs({ "on_player_mined_entity", "on_robot_mined_entity", "on_space_platform_mined_entity" }) do
	script.on_event(defines.events[name], on_mined, REMOVED_FILTER)
end
local function on_destroyed(event)
	fork_io.on_removed(event.entity)
	fork_sbus.on_removed(event.entity)
	fork_ae2.on_removed(event.entity, nil)
	fork_bench.on_removed(event.entity, nil)
	fork_net.on_removed(event.entity, nil)
end
script.on_event(defines.events.on_entity_died, on_destroyed, REMOVED_FILTER)
script.on_event(defines.events.script_raised_destroy, on_destroyed, REMOVED_FILTER)

--- Issue #5: every periodic visit of the network runs here, spread over the ticks (scripts/fork-me-schedule.lua):
--- interfaces and buses, storage buses, crafting jobs, provider rescans, level maintainers and circuit interfaces.
--- The terminal's 60 tick step stays (windows, drive lights, the sweep).
local function on_tick(tick)
	sched.mark(tick)
	fork_io.on_tick(tick)
	fork_sbus.on_tick(tick)
	fork_ae2.on_tick(tick)
	fork_me.on_tick(tick)
end
script.on_event(defines.events.on_tick, function(event) sched.metered(on_tick, event.tick) end)

script.on_event(defines.events.on_runtime_mod_setting_changed, function(event)
	if event.setting_type == "runtime-global" then sched.on_setting_changed() end
end)

--- a rotated import, export or storage bus faces another entity
script.on_event(defines.events.on_player_rotated_entity, function(event)
	fork_io.on_rotated(event.entity)
	fork_net.on_rotated(event.entity)
	fork_sbus.on_rotated(event.entity)
end)

--- a new game, or this mod added to a save: first the state of a Gregtorio Continued save, if there is one
script.on_init(function()
	handover.pull()
	fork_me.on_init()
end)

script.on_configuration_changed(function(data)
	--- recipes newly added to researched technologies are unlocked in existing saves (a mod that changes this
	--- mod's recipes or technologies, like Gregtorio Continued, does the same for its own updates)
	if data.mod_changes[script.mod_name] or data.mod_startup_settings_changed then
		for _, force in pairs(game.forces) do
			force.reset_technology_effects()
		end
	end
	handover.pull()
	--- the graph first (the only map scan), then the migration of old ME networks, then the modules that read it
	fork_net.rebuild()
	fork_migrate.run_fluids()
	fork_migrate.run()
	fork_unify.run()                -- issue #3: the old fluid blocks, their ghosts and items
	fork_me.on_configuration_changed()
	fork_fluids.on_configuration_changed()
	fork_ae2.on_configuration_changed()
	fork_circuit.on_configuration_changed()
	fork_io.on_configuration_changed()
	fork_sbus.on_configuration_changed()
	fork_bench.on_configuration_changed()
end)
