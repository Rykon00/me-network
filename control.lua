--- ME Network: runtime. The modules keep their names from Gregtorio Continued, where this network was made
--- (scripts/fork-me-*.lua); their state keeps its storage keys, so the hand-over from Gregtorio needs no conversion.

--- the network core: cable graph, controller, drives and cells, storage API
local fork_net = require("scripts.fork-me-network")
local legacy_drives = require("scripts.fork-me-legacy-drives")   -- (issue #689: the old drive items, once per save)
--- ME Storage Bus: a chest or cargo wagon, or the fluid segment of a tank, as network storage (its visits run in the
--- I/O step; the fluid side is scripts/fork-me-fluid-storagebus.lua)
local fork_sbus = require("scripts.fork-me-storagebus")
--- ME Interface (items, and fluids through its four sides) and import/export buses, the I/O step (also runs the
--- storage bus visits)
local fork_io = require("scripts.fork-me-io")
--- ME terminal (the hub window), routes the GUI events of every ME window (scripts/fork-me-gui.lua)
local fork_me = require("scripts.fork-me-terminal")
--- autocrafting, pattern providers with encoded patterns and crafting CPUs (the pattern items in
--- scripts/fork-me-patterns.lua)
local fork_ae2 = require("scripts.fork-me-autocraft")
--- the fluid calls on top of the storage engine
local fork_fluids = require("scripts.fork-me-fluids")
--- level maintainer and circuit interface
local fork_circuit = require("scripts.fork-me-circuit")
--- the ME Pattern Terminal: the encoding window and its two slots (issue #130)
local fork_pt = require("scripts.fork-me-patternterm")
local fork_vc = require("scripts.fork-me-viewcells")          -- (issue #440)
--- the ME Toggle Bus and ME Inverted Toggle Bus (issue #355: their checks join and split networks)
local fork_toggle = require("scripts.fork-me-toggle")
--- the windows of the ME blocks (after the modules whose functions they call)
require("scripts.fork-me-windows")
--- the ME Interface Terminal: the list of the network's providers and interfaces (issue #336; it uses the windows above)
require("scripts.fork-me-ifaceterm")
--- the ME Storage, Conversion and Throughput Monitor (issue #353; it uses the windows above)
local fork_monitor = require("scripts.fork-me-monitor")
--- the ME Level Emitter (issue #355: a circuit signal by a resource's amount; its window comes with it)
local fork_emitter = require("scripts.fork-me-emitter")
--- issues #205 to #210: the access point, the wireless terminal and its hotkey, the charger, the equipment module
local fork_wl = require("scripts.fork-me-wireless")
--- issue #603: the wireless refill (the module's personal logistics from the ME network)
local fork_refill = require("scripts.fork-me-wireless-refill")
fork_wl.refill = fork_refill
--- a crafting machine's recipe pasted onto an ME Interface, import, export or storage bus (issue #12)
local fork_paste = require("scripts.fork-me-recipe-paste")
--- the ME Cell Workbench: a cell's partition and upgrade cards (issue #17)
local fork_bench = require("scripts.fork-me-workbench")
--- the one-time hand-over of the state of a Gregtorio Continued save
local handover = require("scripts.fork-me-handover")
--- the scheduler's settings (issue #5)
local sched = require("scripts.fork-me-schedule")
--- issue #295: the translated names of items and fluids, for the search fields
local names = require("scripts.fork-me-names")
--- the command /me-stats (issue #38, part 3)
require("scripts.fork-me-stats")
--- issue #383: a blueprint pasted over ME blocks that stand there already
local pasteover = require("scripts.fork-me-pasteover")
--- issue #670: the shape of ME Cable pasted over cable, and of cable ghosts
local cableshape = require("scripts.fork-me-cableshape")
local cableturn = require("scripts.fork-me-cableturn")    -- (issue #673: its own events: cursor, position, rotate/flip keys)
--- issue #386: the ME IO Port (a cell emptied into the network or filled from it; its own queue)
local fork_ioport = require("scripts.fork-me-ioport")
--- issue #531: the ME Logistic Interface (offers to the logistic robots, asks them for what the network lacks, takes their
--- trash; three hidden logistic chests, its own queue)
local fork_lif = require("scripts.fork-me-logistic-interface")
local fork_lc = require("scripts.fork-me-logistic-construction")   -- (issue #538)
--- issue #385: the ME Quantum Bridge (two networks joined at any distance and across surfaces)
local fork_qbridge = require("scripts.fork-me-qbridge")
--- issue #412: the circuit condition of the buses, the ME Interface and the provider (issue #628: on the blocks' own wires)
local fork_conn = require("scripts.fork-me-connector")
--- issue #628: the old buses and pattern providers (simple entities, renamed `<name>-legacy`) become the wired ones
local wired = require("scripts.fork-me-wired")
--- issue #527: settings paste of the ME Quantum Bridge and the ME Wireless Link by the mod's own copy and paste keys
local paste_keys = require("scripts.fork-me-paste-keys")
--- ME Cable dragged across an obstacle becomes a pair of underground cables (like belts)
local cabledrag = require("scripts.fork-me-cabledrag")
--- issue #561: the ME Memory Card (a selection tool: copy a block's settings, paste them onto blocks of its kind)
local memcard = require("scripts.fork-me-memorycard")
--- issue #629: the ME P2P Tunnels (frequencies; a pattern provider serves the machines their outputs face)
local fork_p2p = require("scripts.fork-me-p2p")
local ghostwin = require("scripts.fork-me-ghostwin")      -- (issue #659: the ME window of a ghost)
--- blocks another mod moves (a clone, then its source destroyed: a Space Exploration spaceship), surfaces that are deleted
local move = require("scripts.fork-me-move")
require("scripts.fork-me-highlight")                      -- (issue #699: the network highlighted while a member is hovered)

--- the blueprint handler of the autocrafting module also tags ME Interfaces, buses and drives
fork_ae2.blueprint_hooks[#fork_ae2.blueprint_hooks + 1] = fork_io.tag_blueprint
fork_ae2.blueprint_hooks[#fork_ae2.blueprint_hooks + 1] = fork_net.tag_blueprint
fork_ae2.blueprint_hooks[#fork_ae2.blueprint_hooks + 1] = fork_sbus.tag_blueprint
fork_ae2.blueprint_hooks[#fork_ae2.blueprint_hooks + 1] = fork_wl.tag_blueprint
fork_ae2.blueprint_hooks[#fork_ae2.blueprint_hooks + 1] = fork_ioport.tag_blueprint
fork_ae2.blueprint_hooks[#fork_ae2.blueprint_hooks + 1] = fork_qbridge.tag_blueprint
fork_ae2.blueprint_hooks[#fork_ae2.blueprint_hooks + 1] = fork_lif.tag_blueprint
fork_ae2.blueprint_hooks[#fork_ae2.blueprint_hooks + 1] = fork_p2p.tag_blueprint
fork_ae2.blueprint_hooks[#fork_ae2.blueprint_hooks + 1] = fork_conn.tag_blueprint   -- (issue #628: the circuit condition)

--- issue #558: the player who built an entity by hand (nil for robots, platforms and scripts); issue #590: the blocks with
--- card slots take the cards of a blueprint from its inventory first, as the provider takes its patterns
local function builder(event)
	local p = event and event.name == defines.events.on_built_entity and game.get_player(event.player_index)
	return p and p.valid and p or nil
end

local function on_built(entity, tags, event)
	entity = wired.on_built(entity)                           -- (issue #628: an old bus or provider, or its ghost, first)
	if not entity then return end
	local player = builder(event)
	fork_net.on_built(entity, event)
	fork_io.on_built(entity, tags, nil, player)               -- (any other entity: the buses facing it wake)
	fork_sbus.on_built(entity, tags, nil, player)
	if entity and entity.valid and not fork_net.kind_of(entity.name) then fork_sbus.wake_near(entity) end
	fork_ae2.on_built(entity, tags, nil, player)
	fork_circuit.on_built(entity, tags)
	fork_bench.on_built(entity)
	fork_pt.on_built(entity)
	fork_wl.on_built(entity, tags, nil, player)
	fork_monitor.on_built(entity, tags)
	fork_toggle.on_built(entity)                              -- (after the storage engine registered it, or not)
	fork_emitter.on_built(entity, tags)
	fork_ioport.on_built(entity, tags, nil, player)           -- (after the graph registered it)
	fork_lif.on_built(entity, tags, nil, player)              -- (issue #531; its hidden chests)
	fork_lc.on_built(entity)                                  -- (issue #538: a ghost or proxy in an automatic network)
	fork_qbridge.on_built(entity, tags)
	fork_p2p.on_built(entity, tags)                           -- (issue #629)
	fork_conn.on_built(entity, tags)                          -- (issues #412, #628: the condition; an old connector hands over)
	cableshape.on_built(entity)                               -- (issue #670: an ME ghost recorded, shaped on the next tick)
	cabledrag.on_built(entity, event)                         -- (last: a dragged cable may become an underground end)
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
	move.on_cloned(event.source, event.destination)          -- (a move when a script destroys the source in this tick)
	fork_ae2.on_machine_cloned(event.source, event.destination)   -- (issue #704: a pattern machine a job works with)
	fork_net.on_built(event.destination)
	fork_net.on_cloned(event.source, event.destination)
	fork_io.on_built(event.destination, nil, event.source)
	fork_sbus.on_built(event.destination, nil, event.source)
	fork_ae2.on_built(event.destination, nil, event.source)
	fork_circuit.on_built(event.destination, nil, event.source)
	fork_bench.on_built(event.destination)                     -- (a cloned workbench is empty: its cell is an item)
	fork_pt.on_built(event.destination)                        -- (a cloned pattern terminal has empty slots)
	fork_wl.on_built(event.destination, nil, event.source)     -- (an access point wants its boosters, a charger is empty)
	fork_monitor.on_built(event.destination, nil, event.source)
	fork_toggle.on_built(event.destination)                    -- (the game cloned its lamp condition)
	fork_emitter.on_built(event.destination, nil, event.source)
	fork_ioport.on_built(event.destination, nil, event.source)   -- (a cloned port is empty: its cells are items)
	fork_lif.on_built(event.destination, nil, event.source)      -- (issue #531: a cloned hidden chest goes to its block)
	fork_qbridge.on_built(event.destination, nil, event.source)
	fork_p2p.on_built(event.destination, nil, event.source)   -- (issue #629: the source's frequency and role)
	fork_conn.on_built(event.destination, nil, event.source)
	cableshape.on_built(event.destination)                    -- (issue #670: a cloned ME ghost)
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
	fork_wl.on_entity_settings_pasted(event)
	fork_monitor.on_entity_settings_pasted(event)
	fork_emitter.on_entity_settings_pasted(event)             -- (a toggle bus: the game pastes its lamp condition)
	fork_ioport.on_entity_settings_pasted(event)
	fork_lif.on_entity_settings_pasted(event)
	fork_qbridge.on_entity_settings_pasted(event)
	fork_p2p.on_entity_settings_pasted(event)                 -- (issue #629: bound as an output of the source's frequency)
	fork_conn.on_entity_settings_pasted(event)                -- (issue #412: the connector's condition)
end)

script.on_event(defines.events.on_player_selected_area, function(event) memcard.on_selected(event) end)
script.on_event(defines.events.on_player_alt_selected_area, function(event) memcard.on_alt_selected(event) end)

script.on_event(defines.events.on_player_setup_blueprint, function(event)
	fork_ae2.on_player_setup_blueprint(event)
	cableturn.on_player_setup_blueprint(event)                -- (issue #673: the cables stored as north; after the tags)
end)

--- issue #383: a blueprint (or the copy-paste tool's copy) pasted over ME blocks of the same kind makes no ghost and raises
--- no event in Factorio 2.0, so the settings in its tags are given to those blocks before the paste, as the build handlers
--- give them to a block built from a ghost (only the module whose tag the blueprint entity carries)
pasteover.apply = function(entity, tags, player)
	if type(tags.fork_me_drive) == "table" then fork_net.apply_drive_settings(entity, tags.fork_me_drive) end
	if tags.fork_me_interface or tags.fork_me_bus then fork_io.on_built(entity, tags, nil, player) end   -- (issue #590: cards)
	if tags.fork_me_storage_bus or tags.fork_me_fluid_storage_bus then fork_sbus.on_built(entity, tags, nil, player) end
	if tags.fork_me_provider then fork_ae2.on_built(entity, tags, nil, player) end   -- (issue #558: its inventory first)
	if tags.fork_me_maintainer or tags.fork_me_circuit then fork_circuit.on_built(entity, tags) end
	if tags.fork_me_access_point then fork_wl.on_built(entity, tags, nil, player) end
	if tags.fork_me_monitor then fork_monitor.on_built(entity, tags) end
	if tags.fork_me_emitter then fork_emitter.on_built(entity, tags) end
	if tags.fork_me_io_port then fork_ioport.on_built(entity, tags, nil, player) end
	if tags.fork_me_logistic_interface then fork_lif.on_built(entity, tags, nil, player) end
	if tags.fork_me_qbridge or tags.fork_me_wireless_link then fork_qbridge.on_built(entity, tags) end
	if tags.fork_me_p2p then fork_p2p.on_built(entity, tags) end                -- (issue #629)
	if tags[fork_conn.TAG] then fork_conn.apply_tag(entity, tags) end   -- (issue #628: the circuit condition)
end
script.on_event(defines.events.on_pre_build, function(event)
	cabledrag.on_pre_build(event)
	pasteover.on_pre_build(event)
end)

--- removed ME members. Mined: an ME Drive's cells (with their items and fluids), an ME Pattern Provider's encoded
--- patterns, an ME Storage Bus's cards and the cell in an ME Cell Workbench go into the mined buffer, the fluid in an
--- ME Interface's sides back into the network; destroyed or removed by a script: the cells, patterns and cards are
--- spilled.
--- The I/O module runs first (it looks at the network the entity still belongs to), then the graph is updated.
local REMOVED_FILTER = {}
--- (logistic chests, infinity chests and cargo wagons: the inventory of a storage bus leaves the network at once; pipes,
--- underground pipes and pumps: a removed one may split the fluid segment of a storage bus on fluid)
for _, t in pairs({ "simple-entity-with-force", "display-panel", "storage-tank", "lamp", "electric-energy-interface", "container",
	"constant-combinator", "assembling-machine", "furnace", "logistic-container", "infinity-container", "cargo-landing-pad", "linked-container", "cargo-wagon", "fluid-wagon", "pipe", "pipe-to-ground",
	"pump" }) do
	REMOVED_FILTER[#REMOVED_FILTER + 1] = { filter = "type", type = t }
end
local function on_mined(event)
	fork_fluids.on_mined_event(event)
	fork_io.on_removed(event.entity, event.buffer or true)      -- (issue #110: a bus's cards go into the buffer)
	fork_sbus.on_removed(event.entity, event.buffer)
	fork_ae2.on_removed(event.entity, event.buffer)
	fork_bench.on_removed(event.entity, event.buffer)
	fork_pt.on_removed(event.entity, event.buffer)          -- (issue #130: its two slots come along)
	fork_vc.on_removed(event.entity, event.buffer)          -- (issue #440: a terminal's view cells)
	fork_wl.on_removed(event.entity, event.buffer)          -- (an access point's boosters, a charger's terminal)
	fork_ioport.on_removed(event.entity, event.buffer)      -- (issue #386: its cells and cards)
	fork_lif.on_removed(event.entity, event.buffer)         -- (issue #531: its chests into the network, else the buffer)
	fork_qbridge.on_removed(event.entity)
	fork_p2p.on_removed(event.entity, event.buffer)          -- (issue #633: its chest's items into the buffer)
	fork_circuit.on_removed(event.entity)                    -- (issue #660: out of its queue at once)
	fork_conn.on_removed(event.entity)
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
	fork_pt.on_removed(event.entity, nil)                   -- (spilled where it stood)
	fork_vc.on_removed(event.entity, nil)
	fork_wl.on_removed(event.entity, nil)
	fork_ioport.on_removed(event.entity, nil)
	fork_lif.on_removed(event.entity, nil)
	fork_qbridge.on_removed(event.entity)
	fork_p2p.on_removed(event.entity)
	fork_circuit.on_removed(event.entity)
	fork_conn.on_removed(event.entity)
	fork_net.on_removed(event.entity, nil)
end
script.on_event(defines.events.on_entity_died, on_destroyed, REMOVED_FILTER)
--- issue #659: the stand-in of a ghost's window is built from the ghost's tags as a robot builds it, tagged by the blueprint
--- hooks, and mined into a buffer that goes back to the player
ghostwin.build = function(entity, tags)
	on_built(entity, tags, { name = defines.events.script_raised_built, entity = entity, tags = tags })   -- (the drive reads the event's)
end
ghostwin.remove = function(entity, buffer) on_mined{ entity = entity, buffer = buffer } end
ghostwin.tag = function(bp, mapping) fork_ae2.tag_blueprint(bp, mapping) end
--- a member marked for deconstruction carries no network from that moment (it leaves the graph as if it were mined, the modules
--- first), and joins again when the mark is cancelled; the blocks that work on the network wake then
local function wake_all(unit)
	fork_io.wake(unit)
	fork_sbus.wake(unit)
	fork_ioport.wake(unit)
	fork_lif.wake(unit)
end
script.on_event(defines.events.on_marked_for_deconstruction, function(event)
	local entity = event.entity
	if not (entity and entity.valid and fork_net.kind_of(entity.name)) then return end
	fork_io.on_marked(entity)                                 -- (an ME Interface's side fluid into the network first)
	fork_net.set_marked(entity, true)
end, REMOVED_FILTER)
script.on_event(defines.events.on_cancelled_deconstruction, function(event)
	local entity = event.entity
	if not (entity and entity.valid and fork_net.kind_of(entity.name)) then return end
	if fork_net.set_marked(entity, false) then wake_all(entity.unit_number) end
end, REMOVED_FILTER)

--- issue #538: what construction needs, for the ME Logistic Interface's automatic mode (scripts/fork-me-logistic-construction.lua)
script.on_event(defines.events.on_marked_for_upgrade, function(event) fork_lc.on_marked_for_upgrade(event) end)
script.on_event(defines.events.on_cancelled_upgrade, function(event) fork_lc.on_cancelled_upgrade(event) end)
script.on_event(defines.events.on_post_entity_died, function(event) fork_lc.on_post_entity_died(event) end)
script.on_event(defines.events.on_object_destroyed, function(event)
	fork_lc.on_object_destroyed(event)
	cableshape.on_object_destroyed(event)                     -- (issue #670: an ME ghost gone, its cable ghost neighbours follow)
end)
--- a block a script destroys in the tick it was cloned was moved (scripts/fork-me-move.lua): what it holds goes to its clone
--- first (the modules that hold items, the graph's cells last), then it leaves like any destroyed block, with nothing to spill
move.hooks = { fork_ae2.on_moved, fork_circuit.on_moved, fork_io.on_moved, fork_sbus.on_moved, fork_wl.on_moved, fork_ioport.on_moved,
	fork_lif.on_moved, fork_bench.on_moved, fork_pt.on_moved, fork_vc.on_moved, fork_p2p.on_moved, fork_net.on_moved }
move.destroyed = on_destroyed
script.on_event(defines.events.script_raised_destroy, function(event)
	local entity = event.entity
	--- (the ME Quantum Bridge and the ME Wireless Link are electric energy interfaces, as the ME Controller is)
	local link = entity and entity.valid and entity.type == "electric-energy-interface"
	local moved = move.before_destroyed(entity)
	on_destroyed(event)
	--- (a moved bridge or link: its frequency has two blocks again, linked now, not at the next slow step)
	if moved and link then fork_qbridge.step() end
end, REMOVED_FILTER)
--- a surface that is deleted or cleared takes its entities without an event: its members leave first
script.on_event({ defines.events.on_pre_surface_deleted, defines.events.on_pre_surface_cleared }, move.on_surface_gone)

--- Issue #5: every periodic visit of the network runs here, spread over the ticks (scripts/fork-me-schedule.lua):
--- interfaces and buses, storage buses, ME IO Ports (issue #386), crafting jobs, provider rescans, level maintainers and
--- circuit interfaces.
--- The terminal's 60 tick step stays (windows, drive lights, the sweep).
local function on_tick(tick)
	--- a save of a development build of the same version (no on_configuration_changed): the underground cables' turn once
	if not storage.fork_me_ug_vanilla then fork_net.migrate_underground_direction() end
	sched.mark(tick)
	fork_ae2.after_move()                                     -- (issue #704: a job carried over a move of the tick before)
	fork_io.on_tick(tick)
	fork_sbus.on_tick(tick)
	fork_ioport.on_tick(tick)
	fork_p2p.on_tick(tick)                                    -- (issue #633: the tunnels that carry on their own)
	fork_lif.on_tick(tick)                                    -- (issue #531)
	fork_refill.on_tick(tick)                                 -- (issue #603)
	fork_conn.on_tick(tick)                                   -- (issue #412: the conditions of the circuit connectors)
	fork_ae2.on_tick(tick)
	fork_me.on_tick(tick)
	fork_net.chest_tick(tick)                                 -- (issue #229: the ME Chest's input into its cell)
	names.step()                                              -- (issue #295: translation requests, while any wait)
	cableshape.on_tick(tick)                                  -- (issue #670: queued ghosts shaped, the cables under a paste)
	fork_net.highlight.on_tick()                              -- (issue #699: a highlight that still spreads)
end
script.on_event(defines.events.on_tick, function(event) sched.metered(on_tick, event.tick) end)

--- issue #603: a player whose character gets the ME Wireless Module (or comes back with it) is visited by the refill
local function refill_player(event)
	if event.equipment and event.equipment.name ~= fork_wl.MODULE then return end
	fork_refill.update_player(game.get_player(event.player_index))
end
script.on_event(defines.events.on_player_placed_equipment, refill_player)
script.on_event(defines.events.on_player_joined_game, refill_player)
script.on_event(defines.events.on_player_respawned, refill_player)
script.on_event(defines.events.on_player_armor_inventory_changed, refill_player)

script.on_event(defines.events.on_runtime_mod_setting_changed, function(event)
	if event.setting_type == "runtime-global" then sched.on_setting_changed() end
end)

--- a rotated import, export or storage bus (or ME P2P tunnel, issue #629) faces another entity
script.on_event(defines.events.on_player_rotated_entity, function(event)
	fork_io.on_rotated(event.entity)
	fork_net.on_rotated(event.entity)
	fork_sbus.on_rotated(event.entity)
	fork_p2p.on_rotated(event.entity)
	cableshape.on_rotated(event.entity)                       -- (issue #670: a rotated underground cable ghost)
end)

--- Issue #146: saves from before 0.5.0 are no longer converted (the old drives, controller and interface of before the
--- ME rework, the old fluid blocks of issue #3, the providers of before issue #80 are gone). Such a save is refused
--- before anything is changed: the engine aborts the load, the file stays as it was. `old`: the mod's version in the
--- save, or nil for the state of a Gregtorio Continued 0.4.x save (the hand-over).
local CUT_OFF = { 0, 5, 0 }
local function before_cut_off(version)
	local parts = {}
	for n in string.gmatch(version, "%d+") do parts[#parts + 1] = tonumber(n) end
	for i = 1, 3 do
		local a, b = parts[i] or 0, CUT_OFF[i]
		if a ~= b then return a < b end
	end
	return false
end
local function refuse_old_save(old)
	error("\n\nme-network: this save holds an ME network of " .. (old and ("me-network " .. old) or "Gregtorio Continued 0.4.x")
		.. ".\nSince 0.5.1 me-network no longer converts saves from before 0.5.0 (issue #146).\n"
		.. "Load the save once with me-network 0.5.0" .. (old and "" or " (and a Gregtorio Continued version that works with it)")
		.. ", save it, then update. The save file was not changed.\n", 0)
end
local function handover_pending()
	local iface = remote.interfaces["gregtorio-me-handover"]
	return iface and iface.pending and remote.call("gregtorio-me-handover", "pending") and true or false
end

--- a new game, or this mod added to a save: first the state of a Gregtorio Continued save, if there is one (issue #146:
--- that state is from before 0.5.0 and refused)
script.on_init(function()
	if handover_pending() then refuse_old_save(nil) end
	handover.pull()
	wired.migrate()                                           -- (issue #628: old buses and providers, before the graph)
	fork_net.migrate_underground_direction()                  -- (a handed-over save's underground cables, before the graph)
	fork_me.on_init()
	legacy_drives.on_init()
	cableshape.migrate()                                      -- (issue #670: ME ghosts of a handed-over save)
end)

script.on_configuration_changed(function(data)
	local change = data.mod_changes[script.mod_name]
	if change and change.old_version and before_cut_off(change.old_version) then refuse_old_save(change.old_version) end
	if handover_pending() then refuse_old_save(nil) end
	--- recipes newly added to researched technologies are unlocked in existing saves (a mod that changes this
	--- mod's recipes or technologies, like Gregtorio Continued, does the same for its own updates)
	if data.mod_changes[script.mod_name] or data.mod_startup_settings_changed then
		for _, force in pairs(game.forces) do
			force.reset_technology_effects()
		end
	end
	handover.pull()
	--- issue #628: the old buses and pattern providers become the wired ones, their state moved to the new units, before
	--- anything rebuilds from the records
	wired.migrate()
	--- issue #503: the keys of items that no longer exist (a mod removed or renamed them; a JSON migration renames items in the
	--- engine's inventories only), mapped onto their replacement (ME_NETWORK.replace_item) or dropped, before anything reads
	--- them: the cells and storage bus snapshots (the graph rebuild computes the totals and the index from them), the jobs, the
	--- signal lists, the rows and filters of the blocks (their modules' passes below drop what is still unknown)
	fork_net.clean_removed_items()
	fork_sbus.clean_removed_items()
	fork_ae2.clean_removed_items()
	fork_circuit.clean_removed_items()
	fork_io.clean_removed_items()
	--- issue #689: the old drive items of a save (in the drives' cells, inventories, hands, belts, on the ground) become ME Drives
	--- with their cells, once, before the graph rebuild computes the networks' totals from the cells
	legacy_drives.convert()
	--- the underground cables of a save from before 0.5.11 turned to the vanilla underground pipe's rule, then the graph first
	--- (the only map scan), then the modules that read it
	fork_net.migrate_underground_direction()
	fork_net.rebuild()
	cableshape.migrate()                                      -- (issue #670: the ME ghosts registered, cable ghosts shaped)
	--- issue #146: the reports of the conversions of old saves (0.5.0 and older) are gone with them
	storage.fork_me_migrate, storage.fork_me_migrate_fluids, storage.fork_me_unify = nil, nil, nil
	fork_me.on_configuration_changed()
	fork_fluids.on_configuration_changed()
	fork_ae2.on_configuration_changed()
	fork_circuit.on_configuration_changed()
	fork_io.on_configuration_changed()
	fork_sbus.on_configuration_changed()
	fork_bench.on_configuration_changed()
	fork_wl.on_configuration_changed()
	fork_refill.on_configuration_changed()                    -- (issue #603: the players who wear the module)
	fork_monitor.on_configuration_changed()
	fork_toggle.on_configuration_changed()
	fork_emitter.on_configuration_changed()
	fork_ioport.on_configuration_changed()
	fork_lif.on_configuration_changed()
	fork_lc.on_configuration_changed()
	fork_qbridge.on_configuration_changed()
	fork_p2p.on_configuration_changed()                       -- (issue #629)
	fork_conn.on_configuration_changed()                      -- (issue #628: old connectors hand their wires to the blocks)
	paste_keys.on_configuration_changed()
	names.on_configuration_changed()
	fork_net.log_removed_items()                              -- (issue #503: ME-REMOVED-ITEM / ME-REPLACED-ITEM, once per name)
end)
