--------------------------------------------------------------------------------
--- FORK AE2: ME STORAGE, CONVERSION AND THROUGHPUT MONITOR (issue #353; prototypes/network.lua)
--- AE2-Unofficial's monitors (appeng/parts/reporting/AbstractPartMonitor.java, PartStorageMonitor.java,
--- PartConversionMonitor.java, PartThroughputMonitor.java): a 1x1 network member that shows one item or fluid and what
--- the network holds of it, on its face (an icon and a number drawn on the block). The resource is set in its window; a
--- locked monitor keeps it (AE2's wrench toggles the lock; Factorio has no wrench, the window has a button).
---   * Storage Monitor: shows it.
---   * Conversion Monitor: a stack shift-clicked from the inventory while its window is open goes into the network (AE2:
---     shift right click with the item); its window's Take button gives a stack of the resource into the inventory, only
---     while it is locked (AE2: a click on the locked monitor).
---   * Throughput Monitor: the amount and its rate of change, per tick, second, minute or hour (AE2's TimeUnit, set in
---     the window), measured between its visits over a window of about RATE_WINDOW ticks.
--- Work (issue #5's rule: a queue and a budget, no tick handler of its own): a step hook of fork-me-autocraft.lua visits
--- at most VISITS_PER_TICK monitors per tick in the order of storage.fork_me_monitors.list, each at most every INTERVAL
--- ticks; a visit reads the count and writes the text only when it changed. State: storage.fork_me_monitors (lazy).
--------------------------------------------------------------------------------

local N = require("scripts.fork-me-network")
local G = require("scripts.fork-me-gui")
local autocraft = require("scripts.fork-me-autocraft")
local picker = require("scripts.fork-me-picker")

local M = {}

local KINDS = { ["me-storage-monitor"] = "storage", ["me-conversion-monitor"] = "conversion",
	["me-throughput-monitor"] = "throughput" }
M.KINDS = KINDS
local VISITS_PER_TICK = 4
local INTERVAL = 60
local RATE_WINDOW = 600          -- ticks the rate is measured over (the oldest sample in it is the base)
local UNITS = { "tick", "second", "minute", "hour" }
local UNIT_TICKS = { tick = 1, second = 60, minute = 3600, hour = 216000 }
local TAG = "fork_me_monitor"

local function state()
	local s = storage.fork_me_monitors
	if not s then
		s = { recs = {}, list = {}, cursor = 1 }
		storage.fork_me_monitors = s
	end
	return s
end

local function record(entity)
	local s = state()
	local unit = entity.unit_number
	local rec = s.recs[unit]
	if not rec then
		rec = { entity = entity, kind = KINDS[entity.name], unit = "second", samples = {} }
		s.recs[unit] = rec
		s.list[#s.list + 1] = unit
	end
	return rec
end

--- what the network holds of a key (an item with its quality, or a fluid key), nil without a working network
local function amount_of(entity, key)
	local net = N.active_of(entity)
	if not net then return nil end
	if N.is_fluid_key(key) then return N.count_key(net, key) end
	local name, quality = N.parse_key(key)
	return N.count(net, name, quality)
end

--- a number for the face: 1234 -> "1.2k"
local function short(n)
	local a = math.abs(n)
	if a >= 1e9 then return string.format("%.1fG", n / 1e9) end
	if a >= 1e6 then return string.format("%.1fM", n / 1e6) end
	if a >= 1e4 then return string.format("%.1fk", n / 1e3) end
	if a >= 100 or a == math.floor(a) then return string.format("%d", math.floor(n + 0.5)) end
	return string.format("%.1f", n)
end

--- the rate of a throughput monitor per its unit, from its samples ({ tick, amount }, oldest first)
local function rate_of(rec)
	local sm = rec.samples
	local first, last = sm[1], sm[#sm]
	if not (first and last) or last[1] <= first[1] then return 0 end
	return (last[2] - first[2]) / (last[1] - first[1]) * UNIT_TICKS[rec.unit or "second"]
end
M.rate_of = rate_of

--- the face: the resource's icon and the amount (and the rate) as render objects on the block
local function draw(rec, text)
	local e = rec.entity
	local sprite = rec.key and (N.is_fluid_key(rec.key) and ("fluid/" .. N.fluid_name(rec.key)) or ("item/" .. (N.parse_key(rec.key))))
	local redraw = sprite and (not (rec.icon and rec.icon.valid) or rec.sprite ~= sprite)
	--- (issue #503: a name the game does not know has no face; asked only when the icon is drawn)
	if not sprite or (redraw and not helpers.is_valid_sprite_path(sprite)) then
		if rec.icon and rec.icon.valid then rec.icon.destroy() end
		if rec.text and rec.text.valid then rec.text.destroy() end
		rec.icon, rec.text, rec.shown = nil, nil, nil
		return
	end
	if redraw then
		if rec.icon and rec.icon.valid then rec.icon.destroy() end
		rec.icon = rendering.draw_sprite{ sprite = sprite, target = { entity = e, offset = { 0, -0.1 } }, surface = e.surface,
			x_scale = 0.45, y_scale = 0.45, render_layer = "lower-object-above-shadow" }
		rec.sprite = sprite
	end
	if rec.shown == text and rec.text and rec.text.valid then return end
	if rec.text and rec.text.valid then
		rec.text.text = text
	else
		rec.text = rendering.draw_text{ text = text, target = { entity = e, offset = { 0, 0.12 } }, surface = e.surface,
			color = { 1, 1, 1 }, scale = 0.6, alignment = "center", vertical_alignment = "middle",
			render_layer = "lower-object-above-shadow" }
	end
	rec.shown = text
end

--- one visit: read the amount, keep the throughput samples, write the face when it changed
local function visit(rec)
	rec.last = game.tick
	if not rec.key then draw(rec) return end
	local n = amount_of(rec.entity, rec.key)
	rec.amount = n
	local text = n and short(n) or "-"
	if rec.kind == "throughput" and n then
		local sm = rec.samples
		sm[#sm + 1] = { game.tick, n }
		while #sm > 2 and sm[2][1] <= game.tick - RATE_WINDOW do table.remove(sm, 1) end
		local r = rate_of(rec)
		text = text .. "\n" .. (r >= 0 and "+" or "") .. short(r) .. "/" .. (rec.unit or "second"):sub(1, 1)
	end
	draw(rec, text)
end
M.visit = visit

--- the step hook (every tick): at most VISITS_PER_TICK monitors, each at most every INTERVAL ticks
local function on_tick(_, tick)
	local s = storage.fork_me_monitors
	if not (s and #s.list > 0) then return end
	local done = 0
	local tries = 0
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

--- Set a monitor's resource (a key; false clears it; nil keeps it), lock and throughput unit; a locked monitor keeps its
--- resource (unless `force`, as a blueprint or a paste does). Returns true when it is a monitor.
function M.set(entity, key, locked, unit, force)
	if not (entity and entity.valid and KINDS[entity.name]) then return false end
	local rec = record(entity)
	if key ~= nil and (force or not rec.locked) then
		local k = type(key) == "string" and key or nil
		if k and N.is_fluid_key(k) then
			--- (issue #159: a fluid of one temperature, the default one when none is named, as the level maintainer's)
			k = N.clean_fluid_filter(k)
			k = k and N.fluid_storage_key(k)
			if k and not prototypes.fluid[N.fluid_name(k)] then k = nil end
		elseif k and not prototypes.item[(N.parse_key(k))] then
			k = nil
		end
		if k ~= rec.key then rec.samples = {} end
		rec.key = k
	end
	if locked ~= nil then rec.locked = locked and true or nil end
	if unit ~= nil and UNIT_TICKS[unit] then rec.unit = unit rec.samples = {} end
	visit(rec)
	return true
end

--- { kind, key, locked, unit, amount, rate } of a monitor (nil for anything else)
function M.get(entity)
	if not (entity and entity.valid and KINDS[entity.name]) then return nil end
	local rec = record(entity)
	return { kind = rec.kind, key = rec.key, locked = rec.locked or false, unit = rec.unit, amount = rec.amount,
		rate = rec.kind == "throughput" and rate_of(rec) or nil, text = rec.shown }
end

local function settings_of(rec) return { key = rec.key, locked = rec.locked, unit = rec.unit } end

function M.on_built(entity, tags, source)
	if not (entity and entity.valid and KINDS[entity.name]) then return end
	record(entity)
	local t = type(tags) == "table" and tags[TAG] or nil
	if type(t) ~= "table" and source and source.valid and KINDS[source.name] then
		local from = state().recs[source.unit_number]
		t = from and settings_of(from) or nil
	end
	if type(t) == "table" then M.set(entity, t.key or false, t.locked or false, t.unit, true) end
end

function M.on_entity_settings_pasted(event)
	local src, dst = event.source, event.destination
	if not (src and src.valid and dst and dst.valid and KINDS[src.name] and KINDS[dst.name]) then return end
	local from = state().recs[src.unit_number]
	if from then M.set(dst, from.key or false, from.locked or false, from.unit, true) end
end

local function tag_blueprint(bp, mapping)
	local s = storage.fork_me_monitors
	if not s then return end
	for index, entity in pairs(mapping) do
		local rec = entity.valid and s.recs[entity.unit_number]
		if rec then bp.set_blueprint_entity_tag(index, TAG, settings_of(rec)) end
	end
end
autocraft.blueprint_hooks[#autocraft.blueprint_hooks + 1] = tag_blueprint

--- after a mod change: the monitors of the world, their settings kept by unit number, their faces drawn again
function M.on_configuration_changed()
	local s = state()
	local old = s.recs
	s.recs, s.list, s.cursor = {}, {}, 1
	local names = {}
	for n in pairs(KINDS) do if prototypes.entity[n] then names[#names + 1] = n end end
	if #names == 0 then return end
	for _, surface in pairs(game.surfaces) do
		for _, e in pairs(surface.find_entities_filtered{ name = names }) do
			local rec = record(e)
			local o = old[e.unit_number]
			if o then
				--- (issue #503: a replaced item's key is its replacement's, a removed one's none)
				local key = type(o.key) == "string" and N.live_key(o.key) or nil
				if key and not N.is_fluid_key(key) and not prototypes.quality[select(2, N.parse_key(key))] then key = nil end
				if key and N.is_fluid_key(key) and not prototypes.fluid[N.fluid_name(key)] then key = nil end
				rec.key, rec.locked, rec.unit, rec.icon, rec.text = key, o.locked, o.unit or "second", o.icon, o.text
				rec.sprite, rec.shown = o.sprite, nil
			end
			visit(rec)
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
	local _, content = G.open_window(player, "monitor", { "entity-name." .. entity.name }, { unit = entity.unit_number })
	G.label(content, { "fork-me-monitor.help-" .. d.kind }, WIDTH)
	local row = G.row(content)
	row.add{ type = "label", caption = { "fork-me-monitor.resource" } }
	row.add{ type = "flow", name = "fork_me_mon_key" }
	row.add{ type = "checkbox", name = "fork_me_mon_lock", state = d.locked, caption = { "fork-me-monitor.lock" },
		tooltip = { "fork-me-monitor.lock-tooltip" }, tags = G.act("mon_lock") }
	if d.kind == "throughput" then
		local r = G.row(content)
		r.add{ type = "label", caption = { "fork-me-monitor.unit" } }
		local items, sel = {}, 2
		for i, u in ipairs(UNITS) do
			items[i] = { "fork-me-monitor.unit-" .. u }
			if u == d.unit then sel = i end
		end
		r.add{ type = "drop-down", items = items, selected_index = sel, tags = G.act("mon_unit") }
	end
	if d.kind == "conversion" then
		local r = G.row(content)
		r.add{ type = "button", name = "fork_me_mon_take", caption = { "fork-me-monitor.take" },
			tooltip = { "fork-me-monitor.take-tooltip" }, tags = G.act("mon_take") }
	end
	G.label(content, "", WIDTH, nil, "fork_me_mon_amount")
	M.refresh(player, G.window_of(player))
end

function M.refresh(player, frame)
	local entity = G.entity_of(player, frame)
	if not entity then return false end
	local d = M.get(entity)
	if not d then return false end
	local box = G.find(frame, "fork_me_mon_key")
	local sig = (d.key or "-") .. tostring(d.locked)
	if box and box.tags.sig ~= sig then
		box.clear()
		box.tags = { sig = sig }
		local b = G.key_button(box, d.key, G.act("mon_key"), { "fork-me-monitor.key-tooltip" })
		b.enabled = not d.locked
	end
	local take = G.find(frame, "fork_me_mon_take")
	if take then take.enabled = d.locked and d.key ~= nil and not N.is_fluid_key(d.key) end
	local desc = d.key and autocraft.describe(d.key)
	local label = G.find(frame, "fork_me_mon_amount")
	if not desc then
		label.caption = { "fork-me-monitor.none" }
	elseif d.amount == nil then
		label.caption = { "fork-me-net.status-no-network" }
	elseif d.kind == "throughput" then
		label.caption = { "fork-me-monitor.rate", desc.localised_name, G.fmt(d.amount), short(d.rate or 0),
			{ "fork-me-monitor.unit-" .. d.unit } }
	else
		label.caption = { "fork-me-monitor.amount", desc.localised_name, G.fmt(d.amount) }
	end
	return true
end

--- a shift-clicked stack of the inventory: into the network through a conversion monitor (AE2's shift right click)
local function shift(entity, stack)
	local rec = KINDS[entity.name] == "conversion" and record(entity)
	if not rec then return "no-target" end
	local net = N.active_of(entity)
	if not net then return "no-network" end
	local n, why = N.insert_stack(net, stack)
	if not n then return why end
	visit(rec)
	return nil
end

G.window("monitor", { open = open, refresh = function(player, frame) return M.refresh(player, frame) end,
	entities = { "me-storage-monitor", "me-conversion-monitor", "me-throughput-monitor" },
	shift = shift, hint = { "fork-me-monitor.shift-help" } })

G.on("mon_key", function(event, player, el)
	if event.name ~= defines.events.on_gui_click then return end
	local entity = window_entity(player)
	if not entity then return end
	if event.button == defines.mouse_button_type.right then
		M.set(entity, false)
		G.refresh_one(player)
		return
	end
	local d = M.get(entity)
	if d.locked then return end
	picker.open(player, { callback = "mon_key", data = { unit = entity.unit_number }, kinds = { item = true, fluid = true },
		preset = picker.preset_of(d.key), quality = true })
end)

picker.on_confirm("mon_key", function(player, data, choice)
	local entity = window_entity(player)
	if not (entity and entity.unit_number == data.unit) then return end
	local key = picker.key_of(choice, true)
	if key then M.set(entity, key) end
	G.refresh_one(player)
end)

G.on("mon_lock", function(event, player, el)
	if event.name ~= defines.events.on_gui_checked_state_changed then return end
	local entity = window_entity(player)
	if entity then M.set(entity, nil, el.state) G.refresh_one(player) end
end)

G.on("mon_unit", function(event, player, el)
	if event.name ~= defines.events.on_gui_selection_state_changed then return end
	local entity = window_entity(player)
	if entity then M.set(entity, nil, nil, UNITS[el.selected_index]) G.refresh_one(player) end
end)

--- Take: a stack of the locked conversion monitor's item into the inventory (AE2: a click on the locked monitor)
function M.take(entity, target)
	local d = M.get(entity)
	if not (d and d.kind == "conversion" and d.locked and d.key and not N.is_fluid_key(d.key)) then return 0 end
	local net = N.active_of(entity)
	if not net then return 0 end
	local name = N.parse_key(d.key)
	local proto = prototypes.item[name]
	local moved = N.extract_to(net, target, d.key, proto and proto.stack_size or 1)
	visit(record(entity))
	return moved
end

G.on("mon_take", function(event, player, el)
	if event.name ~= defines.events.on_gui_click then return end
	local entity = window_entity(player)
	if entity then M.take(entity, player) G.refresh_one(player) end
end)

remote.add_interface("gregtorio-me-monitor", {
	--- (tests) key (false clears it), locked, unit ("tick", "second", "minute", "hour"); force sets a locked one's key
	set = function(entity, key, locked, unit, force) return M.set(entity, key, locked, unit, force) end,
	--- { kind, key, locked, unit, amount, rate, text }
	get = function(entity) return M.get(entity) end,
	--- a visit now (what the step does)
	visit = function(entity)
		if not (entity and entity.valid and KINDS[entity.name]) then return false end
		visit(record(entity))
		return true
	end,
	--- a stack (LuaItemStack) into the network through a conversion monitor; the reason it refused, nil when stored
	shift = function(entity, stack) return shift(entity, stack) end,
	take = function(entity, target) return M.take(entity, target) end,
	paste = function(source, destination) M.on_entity_settings_pasted{ source = source, destination = destination } end,
	built = function(entity, tags, source) M.on_built(entity, tags, source) end,
})

return M
