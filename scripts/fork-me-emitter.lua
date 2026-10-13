--------------------------------------------------------------------------------
--- FORK AE2: ME LEVEL EMITTER (issue #355; prototypes/autocrafting.lua)
--- AE2-Unofficial's level emitter (appeng/parts/automation/PartLevelEmitter.java: settings :113-115, logic :159-194): it
--- emits redstone while what the network holds of its resource is at or above its threshold (REDSTONE_EMITTER "high"), or
--- below it ("low"); LEVEL_TYPE "energy" compares the network's stored energy instead. Here a constant combinator whose first
--- (only) section the runtime writes: its output signal with the value 1 while it emits, nothing otherwise. The output signal
--- is a setting (the green check by default). A network that does not work emits nothing (AE2: an unpowered part is off).
--- AE2's Crafting Card mode (emit to craft) belongs to the level maintainer (issue #351), the Fuzzy Card is not taken over.
--- Work (issue #5's rule: a queue and a budget, no tick handler of its own): a step hook of fork-me-autocraft.lua visits at
--- most VISITS_PER_TICK emitters per tick in the order of storage.fork_me_emitters.list, each at most every INTERVAL ticks;
--- a visit reads one amount and writes the section only when the output changed. State: storage.fork_me_emitters (lazy).
--------------------------------------------------------------------------------

local N = require("scripts.fork-me-network")
local G = require("scripts.fork-me-gui")
local autocraft = require("scripts.fork-me-autocraft")
local picker = require("scripts.fork-me-picker")
local W = require("scripts.fork-me-windows")       -- (loaded before this module: control.lua)

local M = {}

local NAME = "me-level-emitter"
M.NAME = NAME
local VISITS_PER_TICK = 8
local INTERVAL = 10
local TAG = "fork_me_emitter"
local MODES = { "high", "low" }
local DEFAULT_SIGNAL = { type = "virtual", name = "signal-check" }
local MAX_AMOUNT = 1e15

local function state()
	local s = storage.fork_me_emitters
	if not s then
		s = { recs = {}, list = {}, cursor = 1 }
		storage.fork_me_emitters = s
	end
	return s
end

local function record(entity)
	local s = state()
	local unit = entity.unit_number
	local rec = s.recs[unit]
	if not rec then
		rec = { entity = entity, amount = 0, mode = "high" }
		s.recs[unit] = rec
		s.list[#s.list + 1] = unit
	end
	return rec
end

--- what is compared: the amount of the key in the working network, or its stored energy (J); nil without a working network
local function level_of(rec)
	local net = N.active_of(rec.entity)
	if not net then return nil end
	if rec.energy then return N.stored_energy(net) end
	if not rec.key then return nil end
	if N.is_fluid_key(rec.key) then return N.count_key(net, rec.key) end
	local name, quality = N.parse_key(rec.key)
	return N.count(net, name, quality)
end

--- does it emit at this level? (AE2: high = at or above the threshold, low = below it)
local function emits(rec, level)
	if level == nil then return false end
	if rec.mode == "low" then return level < rec.amount end
	return level >= rec.amount
end

--- the output: the signal (1) or nothing, written when it changed (`force`: a setting changed)
local function write(rec, on, force)
	if rec.on == on and not force then return end
	local cb = rec.entity.get_or_create_control_behavior()
	for i = cb.sections_count, 2, -1 do cb.remove_section(i) end
	local section = cb.get_section(1) or cb.add_section()
	if not section then return end
	local sig = rec.signal or DEFAULT_SIGNAL
	section.filters = on and { { value = { type = sig.type or "item", name = sig.name, quality = "normal", comparator = "=" },
		min = 1 } } or {}
	rec.on = on
end

--- one visit: read the level, write the output when it changed
local function visit(rec, force)
	rec.last = game.tick
	local level = level_of(rec)
	rec.level = level
	write(rec, emits(rec, level), force)
end
M.visit = visit

--- the step hook (every tick): at most VISITS_PER_TICK emitters, each at most every INTERVAL ticks
local function on_tick(_, tick)
	local s = storage.fork_me_emitters
	if not (s and #s.list > 0) then return end
	local done, tries = 0, 0
	while done < VISITS_PER_TICK and tries < #s.list do
		tries = tries + 1
		if s.cursor > #s.list then s.cursor = 1 end
		local unit = s.list[s.cursor]
		local rec = s.recs[unit]
		if not (rec and rec.entity.valid) then
			s.recs[unit] = nil
			table.remove(s.list, s.cursor)
		else
			if rec.last and tick - rec.last < INTERVAL then break end    -- (in this order the rest is newer)
			visit(rec)
			done = done + 1
			s.cursor = s.cursor + 1
		end
	end
end
autocraft.step_hooks[#autocraft.step_hooks + 1] = on_tick

--------------------------------------------------------------------------------
--- settings (the window, blueprints, paste, clones)
--------------------------------------------------------------------------------

--- a resource key checked against the prototypes (a fluid of one temperature, the default one when none is named, as the
--- level maintainer's), or nil
local function clean_key(key)
	if type(key) ~= "string" then return nil end
	if N.is_fluid_key(key) then
		local k = N.clean_fluid_filter(key)
		k = k and N.fluid_storage_key(k)
		return k and prototypes.fluid[N.fluid_name(k)] and k or nil
	end
	local name, quality = N.parse_key(key)
	return prototypes.item[name] and prototypes.quality[quality] and key or nil
end

local function clean_signal(sig)
	if type(sig) ~= "table" or type(sig.name) ~= "string" then return nil end
	local t = sig.type or "item"
	local protos = ({ item = prototypes.item, fluid = prototypes.fluid, virtual = prototypes.virtual_signal })[t]
	if not (protos and protos[sig.name]) then return nil end
	return { type = t, name = sig.name }
end

--- Set an emitter's settings; missing fields stay: { key (false clears it), energy, amount, mode, signal (false: the
--- default) }. Returns true when it is an emitter.
function M.set(entity, t)
	if not (entity and entity.valid and entity.name == NAME and type(t) == "table") then return false end
	local rec = record(entity)
	if t.key ~= nil then rec.key = clean_key(t.key) end
	if t.energy ~= nil then rec.energy = t.energy and true or nil end
	if t.amount ~= nil then rec.amount = math.max(0, math.min(MAX_AMOUNT, tonumber(t.amount) or 0)) end
	if t.mode ~= nil then rec.mode = t.mode == "low" and "low" or "high" end
	if t.signal ~= nil then rec.signal = clean_signal(t.signal) end
	visit(rec, true)
	return true
end

local function settings_of(rec)
	return { key = rec.key or false, energy = rec.energy or false, amount = rec.amount, mode = rec.mode,
		signal = rec.signal or false }
end

--- { key, energy, amount, mode, signal, level, on } of an emitter (nil for anything else)
function M.get(entity)
	if not (entity and entity.valid and entity.name == NAME) then return nil end
	local rec = record(entity)
	return { key = rec.key, energy = rec.energy or false, amount = rec.amount, mode = rec.mode,
		signal = rec.signal or DEFAULT_SIGNAL, level = rec.level, on = rec.on or false }
end

function M.on_built(entity, tags, source)
	if not (entity and entity.valid and entity.name == NAME) then return end
	local rec = record(entity)
	local t = type(tags) == "table" and tags[TAG] or nil
	if type(t) ~= "table" and source and source.valid and source.name == NAME then
		local from = state().recs[source.unit_number]
		t = from and settings_of(from) or nil
	end
	if type(t) == "table" then M.set(entity, t) else visit(rec, true) end
end

function M.on_entity_settings_pasted(event)
	local src, dst = event.source, event.destination
	if not (src and src.valid and dst and dst.valid and src.name == NAME and dst.name == NAME) then return end
	local from = state().recs[src.unit_number]
	if from then M.set(dst, settings_of(from)) end
end

local function tag_blueprint(bp, mapping)
	local s = storage.fork_me_emitters
	if not s then return end
	for index, entity in pairs(mapping) do
		local rec = entity.valid and s.recs[entity.unit_number]
		if rec then bp.set_blueprint_entity_tag(index, TAG, settings_of(rec)) end
	end
end
autocraft.blueprint_hooks[#autocraft.blueprint_hooks + 1] = tag_blueprint

--- after a mod change: the emitters of the world, their settings kept by unit number
function M.on_configuration_changed()
	local s = state()
	local old = s.recs
	s.recs, s.list, s.cursor = {}, {}, 1
	if not prototypes.entity[NAME] then return end
	for _, surface in pairs(game.surfaces) do
		for _, e in pairs(surface.find_entities_filtered{ name = NAME }) do
			local rec = record(e)
			local o = old[e.unit_number]
			if o then
				rec.key, rec.energy, rec.amount, rec.mode = clean_key(o.key), o.energy, o.amount or 0, o.mode or "high"
				rec.signal = clean_signal(o.signal)
			end
			visit(rec, true)
		end
	end
	table.sort(s.list)
end

--------------------------------------------------------------------------------
--- the window
--------------------------------------------------------------------------------

local WIDTH = 360

local function window_entity(player)
	local frame = G.window_of(player)
	return frame and G.entity_of(player, frame)
end

local function open(player, entity)
	local d = M.get(entity)
	local _, content = G.open_window(player, "level-emitter", { "entity-name." .. NAME }, { unit = entity.unit_number })
	G.label(content, { "fork-me-emitter.help" }, WIDTH)
	local row = G.row(content)
	row.add{ type = "label", caption = { "fork-me-emitter.resource" } }
	row.add{ type = "flow", name = "fork_me_em_key" }
	row.add{ type = "checkbox", name = "fork_me_em_energy", state = d.energy, caption = { "fork-me-emitter.energy" },
		tooltip = { "fork-me-emitter.energy-tooltip" }, tags = G.act("em_energy") }
	row = G.row(content)
	row.add{ type = "drop-down", name = "fork_me_em_mode", items = { { "fork-me-emitter.mode-high" }, { "fork-me-emitter.mode-low" } },
		selected_index = d.mode == "low" and 2 or 1, tags = G.act("em_mode") }
	G.number_field(row, d.amount, G.act("em_amount"), 120).tooltip = { "fork-me-emitter.amount-tooltip" }
	row = G.row(content)
	row.add{ type = "label", caption = { "fork-me-emitter.signal" }, tooltip = { "fork-me-emitter.signal-tooltip" } }
	row.add{ type = "choose-elem-button", name = "fork_me_em_signal", elem_type = "signal", signal = d.signal,
		tags = G.act("em_signal") }
	G.label(content, "", WIDTH, nil, "fork_me_em_state")
	M.refresh(player, G.window_of(player))
end

function M.refresh(player, frame)
	local entity = G.entity_of(player, frame)
	local d = entity and M.get(entity)
	if not d then return false end
	local box = G.find(frame, "fork_me_em_key")
	local sig = (d.key or "-") .. tostring(d.energy)
	if box and box.tags.sig ~= sig then
		box.clear()
		box.tags = { sig = sig }
		G.key_button(box, d.key, G.act("em_key"), { "fork-me-emitter.key-tooltip" }).enabled = not d.energy
	end
	local what
	if d.energy then what = { "fork-me-emitter.what-energy" }
	elseif d.key then
		local desc = autocraft.describe(d.key)
		what = desc and desc.localised_name or d.key
	end
	local label = G.find(frame, "fork_me_em_state")
	if not what then
		label.caption = { "fork-me-emitter.none" }
	elseif d.level == nil then
		label.caption = { "fork-me-net.status-no-network" }
	else
		label.caption = { "fork-me-emitter.state-" .. (d.on and "on" or "off"), what, G.fmt(d.level), G.fmt(d.amount) }
	end
	return true
end

--- (shift + click in the inventory pane stores the stack in the network, as in the circuit interface's window)
G.window("level-emitter", { open = open, refresh = function(player, frame) return M.refresh(player, frame) end,
	entities = { NAME }, shift = W.store_shift, control = W.store_all, message = G.net_message, hint = { "fork-me-gui.store-help" } })

G.on("em_key", function(event, player, el)
	if event.name ~= defines.events.on_gui_click then return end
	local entity = window_entity(player)
	if not entity then return end
	if event.button == defines.mouse_button_type.right then
		M.set(entity, { key = false })
		G.refresh_one(player)
		return
	end
	local d = M.get(entity)
	if d.energy then return end
	picker.open(player, { callback = "em_key", data = { unit = entity.unit_number }, kinds = { item = true, fluid = true },
		preset = picker.preset_of(d.key), quality = true })
end)

picker.on_confirm("em_key", function(player, data, choice)
	local entity = window_entity(player)
	if not (entity and entity.unit_number == data.unit) then return end
	local key = picker.key_of(choice, true)
	if key then M.set(entity, { key = key }) end
	G.refresh_one(player)
end)

G.on("em_energy", function(event, player, el)
	if event.name ~= defines.events.on_gui_checked_state_changed then return end
	local entity = window_entity(player)
	if entity then M.set(entity, { energy = el.state }) G.refresh_one(player) end
end)

G.on("em_mode", function(event, player, el)
	if event.name ~= defines.events.on_gui_selection_state_changed then return end
	local entity = window_entity(player)
	if entity then M.set(entity, { mode = MODES[el.selected_index] or "high" }) G.refresh_one(player) end
end)

G.on("em_amount", function(event, player, el)
	if event.name ~= defines.events.on_gui_text_changed and event.name ~= defines.events.on_gui_confirmed then return end
	local entity = window_entity(player)
	if entity then M.set(entity, { amount = tonumber(el.text) or 0 }) end
	if event.name == defines.events.on_gui_confirmed then G.refresh_one(player) end
end)

G.on("em_signal", function(event, player, el)
	if event.name ~= defines.events.on_gui_elem_changed then return end
	local entity = window_entity(player)
	if entity then M.set(entity, { signal = el.elem_value or false }) G.refresh_one(player) end
end)

remote.add_interface("gregtorio-me-emitter", {
	--- (tests) { key (false clears it), energy, amount, mode ("high", "low"), signal (SignalID; false: the green check) }
	set = function(entity, t) return M.set(entity, t) end,
	--- { key, energy, amount, mode, signal, level, on }
	get = function(entity) return M.get(entity) end,
	--- a visit now (what the step does)
	visit = function(entity)
		if not (entity and entity.valid and entity.name == NAME) then return false end
		visit(record(entity))
		return true
	end,
	paste = function(source, destination) M.on_entity_settings_pasted{ source = source, destination = destination } end,
	built = function(entity, tags, source) M.on_built(entity, tags, source) end,
})

return M
