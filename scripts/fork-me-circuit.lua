--------------------------------------------------------------------------------
--- FORK AE2: LEVEL MAINTAINER AND CIRCUIT INTERFACE (issue #38; runtime, see
--- prototypes/121-fork-ae2-autocrafting.lua)
---   * ME Level Maintainer: keeps N of one item or fluid in its ME network. When the network holds
---     less, it starts a crafting job for the difference (scripts/fork-me-autocraft.lua), provided a
---     pattern exists and a powered CPU has a free job slot. It starts no second job while a job of
---     that network crafts the same resource (its own or anyone's). The lamp's circuit condition
---     (kept on the lamp entity, copied and blueprinted by the game) switches it off; "amount from the circuit"
---     takes the target amount from the signal of the resource on its wires. Resource, amount and the
---     circuit option are set in its ME window (scripts/fork-me-windows.lua), which also edits the condition.
---   * ME Circuit Interface: a constant combinator. The runtime writes its first section: every item
---     (with its quality) and fluid of its ME network, or only the filtered resources. Other sections
---     are removed, so the output always equals the network contents.
---   * Settings of both are copied by settings paste and cloning and kept in blueprints (entity tags
---     "fork_me_maintainer" and "fork_me_circuit").
--- Work per autocrafting step (every 20 ticks, a step hook of fork-me-autocraft.lua): MAINTAINERS_PER_STEP
--- maintainer checks and at most STARTS_PER_STEP job starts (a start plans with a provider rescan; a
--- maintainer whose start failed waits RETRY_TICKS), CIRCUITS_PER_STEP interface updates, both round
--- robin. Nothing runs per tick.
--- State: storage.fork_ae2.maintainers, mlist, mcursor, circuits, clist, ccursor (created lazily, so
--- older saves need nothing). GUI state lives in the GUI elements (tags).
--------------------------------------------------------------------------------

local autocraft = require("scripts.fork-me-autocraft")
local fluids = require("scripts.fork-me-fluids")
local N = require("scripts.fork-me-network")

local M = {}

local MAINTAINER, CIRCUIT = "me-level-maintainer", "me-circuit-interface"
local MAINTAINERS_PER_STEP = 4
local STARTS_PER_STEP = 1
local RETRY_TICKS = 300
local CIRCUITS_PER_STEP = 2
local MAX_SIGNALS = 1000            -- per circuit interface, the largest amounts first
local MAX_FILTERS = 20
local SIGNAL_MAX = 2147483647       -- signals are 32 bit
local MAINT_TAG, CIRCUIT_TAG = "fork_me_maintainer", "fork_me_circuit"
local WIRES = { defines.wire_connector_id.circuit_red, defines.wire_connector_id.circuit_green }

local is_fluid, fluid_name = autocraft.is_fluid, autocraft.fluid_name

--------------------------------------------------------------------------------
--- state and helpers
--------------------------------------------------------------------------------

local function state()
	local s = autocraft.state()
	if not s.maintainers then
		s.maintainers = {}   -- unit_number -> { entity, key, amount, circuit, job, status, stock, target, missing, retry }
		s.mlist = {}
		s.mcursor = 1
	end
	if not s.circuits then
		s.circuits = {}      -- unit_number -> { entity, filters = { key, ... }, signals }
		s.clist = {}
		s.ccursor = 1
	end
	return s
end

--- the working ME network of an entity (scripts/fork-me-network.lua)
local function network_of(entity)
	return N.active_of(entity)
end

local function remove_value(list, value)
	for i = #list, 1, -1 do
		if list[i] == value then table.remove(list, i) end
	end
end

--- a resource key (item name or "fluid/<name>") that still has a prototype, else nil
local function valid_key(key)
	if type(key) ~= "string" then return nil end
	if is_fluid(key) then return prototypes.fluid[fluid_name(key)] and key or nil end
	return prototypes.item[key] and key or nil
end

--- SignalID of a key, and the key of a SignalID (items and fluids only)
local function signal_of(key)
	if is_fluid(key) then return { type = "fluid", name = fluid_name(key) } end
	return { type = "item", name = key }
end

local function key_of_signal(sig)
	if type(sig) ~= "table" or not sig.name then return nil end
	if sig.type == "fluid" then return valid_key("fluid/" .. sig.name) end
	if sig.type == nil or sig.type == "item" then return valid_key(sig.name) end
	return nil
end

--- what the network holds of a key (normal quality items)
local function stock_of(net, key)
	if is_fluid(key) then return fluids.count(net, fluid_name(key)) end
	return N.count(net, key, "normal")
end

--- the sum of the key's signal on the red and green wire
local function circuit_amount(entity, key)
	local sig, n = signal_of(key), 0
	for _, w in pairs(WIRES) do
		local cn = entity.get_circuit_network(w)
		if cn then n = n + cn.get_signal(sig) end
	end
	return math.max(0, n)
end

local function clamp_amount(key, n)
	n = math.floor(tonumber(n) or 0)
	return math.max(0, math.min(n, is_fluid(key or "") and autocraft.MAX_FLUID_AMOUNT or autocraft.MAX_AMOUNT))
end

--------------------------------------------------------------------------------
--- level maintainer
--------------------------------------------------------------------------------

local function maintainer_record(s, entity)
	local unit = entity.unit_number
	local rec = s.maintainers[unit]
	if not rec then
		rec = { entity = entity, amount = 0, circuit = false, status = "no-target" }
		s.maintainers[unit] = rec
		s.mlist[#s.mlist + 1] = unit
	end
	return rec
end

local function drop_maintainer(s, unit)
	s.maintainers[unit] = nil
	remove_value(s.mlist, unit)
end

--- The target the maintainer keeps right now (the circuit signal if it takes the amount from there)
local function target_of(rec)
	if rec.circuit then return clamp_amount(rec.key, circuit_amount(rec.entity, rec.key)) end
	return rec.amount
end

--- One check. `budget.starts`: job starts left in this step. Sets rec.status (a locale key suffix).
local function maintainer_step(rec, budget)
	local e = rec.entity
	rec.stock, rec.target = nil, nil
	if not rec.key then rec.status = "no-target" return end
	if e.status == defines.entity_status.no_power then rec.status = "no-power" return end
	--- only while a condition is switched on: a freshly wired lamp reads disabled until its next circuit update
	local cb = e.get_control_behavior()
	if cb and (cb.circuit_enable_disable or cb.connect_to_logistic_network) and cb.disabled then
		rec.status = "disabled"
		return
	end
	local net = network_of(e)
	if not net then rec.status = "no-network" return end
	local target = target_of(rec)
	local stock = stock_of(net, rec.key)
	rec.stock, rec.target = stock, target
	if rec.job then
		local j = autocraft.job(rec.job)
		if j and (j.status == "queued" or j.status == "running") then rec.status = "running" return end
		rec.job = nil
	end
	if stock >= target then
		rec.status, rec.missing, rec.retry = "stocked", nil, nil
		return
	end
	if autocraft.active_job_for(net, rec.key) then rec.status = "other-job" return end
	if rec.retry and game.tick < rec.retry then return end            -- keeps the status of the failed start
	if budget.starts <= 0 then rec.status = "waiting" return end
	if not autocraft.free_slot(net) then rec.status = "no-cpu" return end
	budget.starts = budget.starts - 1
	local want = clamp_amount(rec.key, math.ceil(target - stock - 1e-9))
	local id, why, plan = autocraft.start(e, rec.key, want, e.unit_number)
	if id then
		rec.job, rec.status, rec.missing, rec.retry = id, "running", nil, nil
	else
		rec.status = why or "failed"
		rec.missing = why == "missing" and plan and plan.missing or nil
		rec.retry = game.tick + RETRY_TICKS
	end
end

--- Set a maintainer's resource (key or nil), amount and circuit option; nil arguments stay as they are
--- (`key = false` clears the resource). Returns true when the entity is a maintainer.
function M.set_maintainer(entity, key, amount, circuit)
	if not (entity and entity.valid and entity.name == MAINTAINER) then return false end
	local rec = maintainer_record(state(), entity)
	if key ~= nil then
		local new = key and valid_key(key) or nil
		if new ~= rec.key then rec.job, rec.missing = nil, nil end
		rec.key = new
	end
	if amount ~= nil then rec.amount = clamp_amount(rec.key, amount) end
	if circuit ~= nil then rec.circuit = circuit and true or false end
	rec.retry = nil
	return true
end

function M.get_maintainer(entity)
	local s = storage.fork_ae2
	local rec = entity and entity.valid and s and s.maintainers and s.maintainers[entity.unit_number]
	if not rec then return nil end
	return { key = rec.key, amount = rec.amount, circuit = rec.circuit, status = rec.status, job = rec.job,
		stock = rec.stock, target = rec.target, missing = rec.missing }
end

--------------------------------------------------------------------------------
--- circuit interface
--------------------------------------------------------------------------------

local function circuit_record(s, entity)
	local unit = entity.unit_number
	local rec = s.circuits[unit]
	if not rec then
		rec = { entity = entity, filters = {}, signals = 0 }
		s.circuits[unit] = rec
		s.clist[#s.clist + 1] = unit
	end
	return rec
end

local function drop_circuit(s, unit)
	s.circuits[unit] = nil
	remove_value(s.clist, unit)
end

--- the signals of a network: { { type, name, quality, count } }, largest first, at most MAX_SIGNALS;
--- `filter` (key -> true) limits them to those resources
local function network_signals(net, filter)
	local out, by_item = {}, {}
	for _, c in pairs(N.contents(net)) do          -- items with tags count under their item and quality
		if not filter or filter[c.name] then
			local k = c.name .. "@" .. c.quality
			local sig = by_item[k]
			if sig then sig.count = sig.count + c.count
			else
				sig = { type = "item", name = c.name, quality = c.quality, count = c.count }
				by_item[k] = sig
				out[#out + 1] = sig
			end
		end
	end
	for name, amount in pairs(fluids.totals(net)) do
		if (not filter or filter["fluid/" .. name]) and amount >= 1 then
			out[#out + 1] = { type = "fluid", name = name, count = math.floor(amount) }
		end
	end
	table.sort(out, function(a, b)
		if a.count ~= b.count then return a.count > b.count end
		if a.type ~= b.type then return a.type < b.type end
		if a.name ~= b.name then return a.name < b.name end
		return (a.quality or "") < (b.quality or "")
	end)
	while #out > MAX_SIGNALS do out[#out] = nil end
	return out
end

--- write the network contents into the interface's first section (the only one)
local function circuit_step(rec)
	local e = rec.entity
	local cb = e.get_or_create_control_behavior()
	for i = cb.sections_count, 2, -1 do cb.remove_section(i) end
	local section = cb.get_section(1) or cb.add_section()
	if not section then return end
	local net = network_of(e)
	local filter
	if #rec.filters > 0 then
		filter = {}
		for _, key in pairs(rec.filters) do filter[key] = true end
	end
	local filters = {}
	if net then
		for i, sig in ipairs(network_signals(net, filter)) do
			filters[i] = {
				value = { type = sig.type, name = sig.name, quality = sig.quality or "normal", comparator = "=" },
				min = math.min(sig.count, SIGNAL_MAX),
			}
		end
	end
	section.filters = filters
	rec.signals = #filters
	rec.net = net and net.id or nil
end

--- Set the filter of an interface: a list of keys (items, "fluid/<name>"), empty for everything
function M.set_circuit_filters(entity, keys)
	if not (entity and entity.valid and entity.name == CIRCUIT) then return false end
	local rec = circuit_record(state(), entity)
	local list, seen = {}, {}
	for _, k in pairs(keys or {}) do
		local key = valid_key(k)
		if key and not seen[key] and #list < MAX_FILTERS then
			seen[key] = true
			list[#list + 1] = key
		end
	end
	rec.filters = list
	circuit_step(rec)
	return true
end

function M.get_circuit(entity)
	local s = storage.fork_ae2
	local rec = entity and entity.valid and s and s.circuits and s.circuits[entity.unit_number]
	if not rec then return nil end
	return { filters = { table.unpack(rec.filters) }, signals = rec.signals, network = rec.net }
end

--------------------------------------------------------------------------------
--- the windows' logic (the windows themselves: scripts/fork-me-windows.lua, issue #68 step R3)
--------------------------------------------------------------------------------

--- the maintainer's status as a LocalisedString
function M.maintainer_status(entity)
	local rec = M.get_maintainer(entity)
	local st = rec and rec.status or "no-target"
	if st == "running" then
		local j = rec.job and autocraft.job(rec.job)
		return { "fork-me-circuit.maintainer-running", rec.job or "?", j and j.done or 0, j and j.total or 0 }
	elseif st == "missing" and rec.missing then
		return { "fork-me-circuit.maintainer-missing", autocraft.item_list(rec.missing, 6) }
	end
	return { "fork-me-circuit.maintainer-" .. st }
end

local COMPARATORS = { ">", "<", "=", ">=", "<=", "!=" }
M.COMPARATORS = COMPARATORS

--- The maintainer's on/off condition (the lamp's circuit condition, kept on the entity, so the game copies it
--- with blueprints and settings paste): { enabled, signal = SignalID or nil, comparator, constant }
function M.get_condition(entity)
	if not (entity and entity.valid and entity.name == MAINTAINER) then return nil end
	local cb = entity.get_or_create_control_behavior()
	local c = cb.circuit_condition or {}
	return { enabled = cb.circuit_enable_disable, signal = c.first_signal, comparator = c.comparator or ">",
		constant = c.constant or 0 }
end

--- Set the condition; nil arguments stay as they are (`signal = false` clears the signal)
function M.set_condition(entity, enabled, signal, comparator, constant)
	if not (entity and entity.valid and entity.name == MAINTAINER) then return false end
	local cb = entity.get_or_create_control_behavior()
	if enabled ~= nil then cb.circuit_enable_disable = enabled and true or false end
	local c = cb.circuit_condition or {}
	local cond = { first_signal = c.first_signal, comparator = c.comparator or ">", constant = c.constant or 0 }
	if signal ~= nil then cond.first_signal = signal or nil end
	if comparator ~= nil then
		for _, v in pairs(COMPARATORS) do if v == comparator then cond.comparator = v end end
	end
	if constant ~= nil then cond.constant = math.floor(tonumber(constant) or 0) end
	cb.circuit_condition = cond
	local rec = maintainer_record(state(), entity)
	rec.retry = nil
	return true
end

--- the circuit interface's output switch (the combinator's own on/off)
function M.get_circuit_enabled(entity)
	if not (entity and entity.valid and entity.name == CIRCUIT) then return nil end
	return entity.get_or_create_control_behavior().enabled
end

function M.set_circuit_enabled(entity, on)
	if not (entity and entity.valid and entity.name == CIRCUIT) then return false end
	entity.get_or_create_control_behavior().enabled = on and true or false
	return true
end

--- the SignalID of a resource key and the key of a SignalID (for the windows' signal buttons)
M.signal_of = signal_of
M.key_of_signal = key_of_signal

--------------------------------------------------------------------------------
--- step (a hook of the autocrafting step, every 20 ticks)
--------------------------------------------------------------------------------

local function on_step(s)
	if not (s.maintainers or s.circuits) then return end
	s = state()
	local n = #s.mlist
	if n > 0 then
		local budget = { starts = STARTS_PER_STEP }
		for _ = 1, math.min(MAINTAINERS_PER_STEP, n) do
			if s.mcursor > #s.mlist then s.mcursor = 1 end
			local unit = s.mlist[s.mcursor]
			local rec = s.maintainers[unit]
			if rec and rec.entity.valid then
				maintainer_step(rec, budget)
				s.mcursor = s.mcursor + 1
			else
				drop_maintainer(s, unit)
			end
			if #s.mlist == 0 then break end
		end
	end
	n = #s.clist
	if n > 0 then
		for _ = 1, math.min(CIRCUITS_PER_STEP, n) do
			if s.ccursor > #s.clist then s.ccursor = 1 end
			local unit = s.clist[s.ccursor]
			local rec = s.circuits[unit]
			if rec and rec.entity.valid then
				circuit_step(rec)
				s.ccursor = s.ccursor + 1
			else
				drop_circuit(s, unit)
			end
			if #s.clist == 0 then break end
		end
	end
end
autocraft.step_hooks[#autocraft.step_hooks + 1] = on_step

--------------------------------------------------------------------------------
--- build, paste, blueprints, clones
--------------------------------------------------------------------------------

--- `tags`: blueprint tags of a built ghost; `source`: the original of a cloned entity
function M.on_built(entity, tags, source)
	if not (entity and entity.valid) then return end
	if entity.name == MAINTAINER then
		maintainer_record(state(), entity)
		local t = type(tags) == "table" and tags[MAINT_TAG] or nil
		if type(t) == "table" then
			M.set_maintainer(entity, t.key or false, t.amount or 0, t.circuit or false)
		elseif source and source.valid and source.name == MAINTAINER then
			local from = M.get_maintainer(source)
			if from then M.set_maintainer(entity, from.key or false, from.amount, from.circuit) end
		end
	elseif entity.name == CIRCUIT then
		local rec = circuit_record(state(), entity)
		local t = type(tags) == "table" and tags[CIRCUIT_TAG] or nil
		if type(t) == "table" and type(t.filters) == "table" then
			M.set_circuit_filters(entity, t.filters)
		elseif source and source.valid and source.name == CIRCUIT then
			local from = M.get_circuit(source)
			M.set_circuit_filters(entity, from and from.filters or {})
		else
			circuit_step(rec)              -- a blueprint also carries the signals of the moment: replace them
		end
	end
end

--- copy the settings (shift right click, shift left click); the game copies the lamp's circuit condition
--- and the combinator's signals itself, the interface rewrites them at once
function M.on_entity_settings_pasted(event)
	local src, dst = event.source, event.destination
	if not (src and src.valid and dst and dst.valid and src.name == dst.name) then return end
	if src.name == MAINTAINER then
		local from = M.get_maintainer(src) or { amount = 0, circuit = false }
		M.set_maintainer(dst, from.key or false, from.amount, from.circuit)
	elseif src.name == CIRCUIT then
		local from = M.get_circuit(src)
		M.set_circuit_filters(dst, from and from.filters or {})
	else
		return
	end
end

--- blueprint hook of the autocrafting module: the settings as entity tags
local function tag_blueprint(bp, mapping)
	local s = storage.fork_ae2
	if not (s and (s.maintainers or s.circuits)) then return end
	for index, entity in pairs(mapping) do
		if entity.valid then
			if entity.name == MAINTAINER and s.maintainers then
				local rec = s.maintainers[entity.unit_number]
				if rec then bp.set_blueprint_entity_tag(index, MAINT_TAG, { key = rec.key, amount = rec.amount, circuit = rec.circuit }) end
			elseif entity.name == CIRCUIT and s.circuits then
				local rec = s.circuits[entity.unit_number]
				if rec then bp.set_blueprint_entity_tag(index, CIRCUIT_TAG, { filters = { table.unpack(rec.filters) } }) end
			end
		end
	end
end
autocraft.blueprint_hooks[#autocraft.blueprint_hooks + 1] = tag_blueprint

--- Rebuild the registries from the world; settings are kept by unit number, resources that no longer
--- exist are dropped.
function M.on_configuration_changed()
	local s = state()
	local old_m, old_c = s.maintainers, s.circuits
	s.maintainers, s.mlist, s.mcursor = {}, {}, 1
	s.circuits, s.clist, s.ccursor = {}, {}, 1
	for _, surface in pairs(game.surfaces) do
		for _, e in pairs(surface.find_entities_filtered{ name = { MAINTAINER, CIRCUIT } }) do
			local unit = e.unit_number
			if e.name == MAINTAINER then
				local rec = maintainer_record(s, e)
				local old = old_m[unit]
				if old then
					rec.key = valid_key(old.key)
					rec.amount = clamp_amount(rec.key, old.amount)
					rec.circuit = old.circuit and true or false
					rec.job = old.job
				end
			else
				local rec = circuit_record(s, e)
				local old = old_c[unit]
				if old then
					for _, k in pairs(old.filters or {}) do
						if valid_key(k) and #rec.filters < MAX_FILTERS then rec.filters[#rec.filters + 1] = k end
					end
				end
			end
		end
	end
	table.sort(s.mlist)
	table.sort(s.clist)
end

--- Other mods and the devcheck runtime test use the same code paths. Keys are item names or
--- "fluid/<name>".
remote.add_interface("gregtorio-me-circuit", {
	--- key (false clears it), amount, circuit (take the amount from the circuit signal); nil keeps a value
	set_maintainer = function(entity, key, amount, circuit) return M.set_maintainer(entity, key, amount, circuit) end,
	--- { key, amount, circuit, status, job, stock, target, missing } (stock and target of the last check)
	get_maintainer = function(entity) return M.get_maintainer(entity) end,
	--- list of keys, empty for everything; writes the signals at once
	set_circuit_filters = function(entity, keys) return M.set_circuit_filters(entity, keys) end,
	--- { filters, signals = number of signals written, network = network id }
	get_circuit = function(entity) return M.get_circuit(entity) end,
	--- the windows (R3): the maintainer's circuit condition, the circuit interface's output switch, the status
	get_condition = function(entity) return M.get_condition(entity) end,
	set_condition = function(entity, enabled, signal, comparator, constant)
		return M.set_condition(entity, enabled, signal, comparator, constant)
	end,
	get_circuit_enabled = function(entity) return M.get_circuit_enabled(entity) end,
	set_circuit_enabled = function(entity, on) return M.set_circuit_enabled(entity, on) end,
	maintainer_status = function(entity) return M.maintainer_status(entity) end,
	--- writes the signals of an interface now (what the step does)
	update_circuit = function(entity)
		if not (entity and entity.valid and entity.name == CIRCUIT) then return false end
		circuit_step(circuit_record(state(), entity))
		return true
	end,
	paste = function(source, destination) M.on_entity_settings_pasted{ source = source, destination = destination } end,
	built = function(entity, tags) M.on_built(entity, tags) end,
})

return M
