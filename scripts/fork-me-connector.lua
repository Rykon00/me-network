--------------------------------------------------------------------------------
--- ME NETWORK: THE CIRCUIT CONNECTOR OF THE BUSES AND THE ME INTERFACE (issue #412; prototypes/connector.lua)
--- AE2's Redstone Card (AE2-Unofficial: Upgrades.REDSTONE, the RedstoneMode of PartSharedItemBus) as Factorio's circuit
--- condition, on the ME Import, Export and Storage Bus and the ME Interface, without a card (the maintainer's choice); issue
--- #429: on the ME Pattern Provider too, whose lock modes read it (AE2-Unofficial's Lock Crafting Card without the card). The
--- blocks take no wires and their prototype type cannot change, so each has a hidden lamp at its position, its connector:
--- the game's lamp window sets the condition, the wires go to it.
---   * A block whose connector has the condition on, a wire, and does not hold the condition is off: `off[unit]`, and the
---     block's own record gets `coff` through its module's setter (N.off_setters; the visits of fork-me-io.lua and
---     fork-me-storagebus.lua read only that field: the bench at 5000 showed a function call and the unit number per visit),
---     parked until it is on again. Without a wire the condition does nothing, as on an inserter. The setter also gets the
---     condition's level (true: it holds, false: it does not, nil: it does nothing), which the provider's locks read (#429).
---   * The blocks whose connector has the condition on, or that read the circuit (the export bus's pulse mode, the interface's
---     rows from the circuit), are in `list`; CHECKS_PER_TICK of them are checked per tick, each at most every INTERVAL ticks
---     (issue #5's rule: a list and a budget; a block without them costs nothing). A check reads the condition: a block that
---     turns on is woken; in pulse mode a rise of the condition gives one visit (`edge[unit]`, taken by M.take_pulse); for the
---     interface's rows the signals' signature, a change wakes it.
---   * The condition changes in the game's window (on_gui_closed), by settings paste, blueprints and clones: the block's place
---     in `list` follows then (M.update).
---   * A block gets its connector when a player first points at it (on_selected_entity_changed, scripts/fork-me-windows.lua),
---     opens its window, or a setting, a paste or a clone needs one (M.ensure): only the blocks a player looks at have one.
---     (Made for every built block, the connectors cost the build burst of the bench 8 to 12 % at once, or, a few per tick,
---     the window of the 5000 scene 5 %, whose blocks are built with events; made at a first visit, the first ticks after
---     a load. Issue #412's measurements in docs/PERFORMANCE.md.)
---   * Blueprints and copies hold a connector a block has (a hidden item places it) with its wires and condition; its ghost is
---     revived at once and waits by its position (`orphans`) for the block built there, which takes it. The connector of a
---     removed block goes with it; a connector with neither a block nor a block's ghost at its place is removed.
--- State: storage.fork_me_conn = { hosts = { [unit] = { host, conn, kind, cc, pulse, read, last, sig, due } },
--- by_conn = { [connector unit] = host unit }, off = { [unit] = true }, edge = { [unit] = true }, list = { units }, cursor,
--- orphans = { ["<surface>:<x>:<y>"] = connector waiting for its block } }
--------------------------------------------------------------------------------

local N = require("scripts.fork-me-network")

local M = {}

local NAME = "me-circuit-connector"
M.NAME = NAME
--- the blocks that have a connector, and which module visits them (the waker's name, N.wakers)
local HOSTS = { ["me-import-bus"] = "io", ["me-export-bus"] = "io", ["me-network-interface"] = "io", ["me-storage-bus"] = "sbus",
	["me-pattern-provider"] = "provider" }                     -- (issue #429: the provider's lock by the condition)
M.HOSTS = HOSTS
local CHECKS_PER_TICK = 16
local INTERVAL = 10                -- ticks: how late a block follows its condition at most, while the budget holds
local WIRES = { defines.wire_connector_id.circuit_red, defines.wire_connector_id.circuit_green }

--- the modules that visit the blocks put the off state into their records (`rec.coff`): N.off_setters[kind](unit, off, level),
--- `level` the condition's (issue #429: true, false, or nil when it does nothing)
N.off_setters = N.off_setters or {}
local function set_off(s, kind, unit, off, level)
	s.off[unit] = off or nil
	local f = N.off_setters[kind]
	if f then f(unit, off, level) end
end

local function state()
	local s = storage.fork_me_conn
	if not s then
		s = { hosts = {}, by_conn = {}, off = {}, edge = {}, list = {}, cursor = 1 }
		storage.fork_me_conn = s
	end
	return s
end

--- is block `unit` switched off by its connector's condition? (the visits; nil when no save state exists yet)
function M.is_off(unit)
	local s = storage.fork_me_conn
	return s ~= nil and s.off[unit] == true
end

--- issue #429: has the condition risen since the last take? (not taken: the windows)
function M.has_pulse(unit)
	local s = storage.fork_me_conn
	return s ~= nil and s.edge[unit] == true
end

--- pulse mode: has the condition risen since the last visit? (taken: true once per rise)
function M.take_pulse(unit)
	local s = storage.fork_me_conn
	if s and s.edge[unit] then
		s.edge[unit] = nil
		return true
	end
	return false
end

local function wired(c)
	for _, w in pairs(WIRES) do
		if c.get_circuit_network(w) then return true end
	end
	return false
end

--- the condition's level: true (it holds), false (it does not), nil (it does nothing: off, no wire)
local function level(h)
	local c = h.conn
	if not (c and c.valid) then return nil end
	local cb = c.get_control_behavior()
	if not (cb and cb.circuit_enable_disable) then return nil end
	if not wired(c) then return nil end
	return not cb.disabled
end

--- the signals on the connector's wires, red and green added: { [key] = count } with item keys "name" / "name@quality" and
--- fluid keys "fluid/<name>"; virtual signals left out (the interface's rows from the circuit)
function M.signals(unit)
	local s = storage.fork_me_conn
	local h = s and s.hosts[unit]
	local c = h and h.conn
	local out = {}
	if not (c and c.valid) then return out end
	for _, w in pairs(WIRES) do
		local net = c.get_circuit_network(w)
		for _, sig in pairs(net and net.signals or {}) do
			local id = sig.signal
			local t = id.type or "item"
			local key
			if t == "item" then key = N.key_of(id.name, id.quality or "normal")
			elseif t == "fluid" then key = "fluid/" .. id.name end
			if key then out[key] = (out[key] or 0) + sig.count end
		end
	end
	return out
end

local function signature(unit)
	local n, sum = 0, 0
	for key, count in pairs(M.signals(unit)) do
		n = n + 1
		sum = (sum + count * 31 + #key) % 2147483647
	end
	return n .. ":" .. sum
end

local function wake(h, unit)
	local w = N.wakers[h.kind]
	if w then w(unit) end
end

local function listed(s, unit)
	for _, u in ipairs(s.list) do if u == unit then return true end end
	return false
end
local function unlist(s, unit)
	for i = #s.list, 1, -1 do if s.list[i] == unit then table.remove(s.list, i) end end
	local h = s.hosts[unit]
	set_off(s, h and h.kind, unit, false)
	s.edge[unit] = nil
end

--- the block's connector was changed (its window, a paste, a blueprint) or its mode: its place in `list`, its state now
function M.update(unit)
	local s = state()
	local h = s.hosts[unit]
	if not h then return end
	local c = h.conn
	local cb = c and c.valid and c.get_control_behavior()
	h.cc = (cb and cb.circuit_enable_disable) and true or nil
	if h.cc or h.pulse or h.read then
		if not listed(s, unit) then s.list[#s.list + 1] = unit end
		local lv = level(h)
		local on = lv ~= false
		local was = not s.off[unit]
		set_off(s, h.kind, unit, not on, lv)
		if h.pulse then h.last = on end
		if h.read then h.sig = signature(unit) end
		if on ~= was or h.read then wake(h, unit) end
	else
		local was = s.off[unit]
		unlist(s, unit)
		if was then wake(h, unit) end
	end
end

--- pulse mode of an export bus, rows from the circuit of an interface (their modules keep the setting; this is the check)
function M.set_mode(unit, pulse, read)
	local s = state()
	local h = s.hosts[unit]
	if not h then return end
	h.pulse, h.read = pulse or nil, read or nil
	if not pulse then s.edge[unit] = nil end
	M.update(unit)
end

local function host_at(c)
	for _, e in pairs(c.surface.find_entities_filtered{ position = c.position, force = c.force }) do
		if e.valid and HOSTS[e.name] and e.position.x == c.position.x and e.position.y == c.position.y then return e end
	end
	return nil
end
local function connector_at(e)
	for _, c in pairs(e.surface.find_entities_filtered{ name = NAME, position = e.position }) do
		if c.valid and c.position.x == e.position.x and c.position.y == e.position.y then return c end
	end
	return nil
end
local function host_ghost_at(c)
	for _, g in pairs(c.surface.find_entities_filtered{ name = "entity-ghost", position = c.position }) do
		if g.valid and HOSTS[g.ghost_name] then return g end
	end
	return nil
end

local function attach(s, e, c)
	local unit = e.unit_number
	local h = s.hosts[unit]
	if h and h.conn and h.conn.valid and h.conn ~= c then
		s.by_conn[h.conn.unit_number] = nil
		h.conn.destroy()
	end
	h = h or { kind = HOSTS[e.name] }
	h.host, h.conn = e, c
	s.hosts[unit] = h
	s.by_conn[c.unit_number] = unit
	c.destructible = false
	M.update(unit)
	return h
end

--- the block's connector, made when it has none (a block of an older save, a block built from an item)
function M.ensure(e)
	if not (e and e.valid and HOSTS[e.name] and e.unit_number) then return nil end
	local s = state()
	local h = s.hosts[e.unit_number]
	if h and h.conn and h.conn.valid then return h.conn end
	local c = connector_at(e) or e.surface.create_entity{ name = NAME, position = e.position, force = e.force,
		create_build_effect_smoke = false }
	if not c then return nil end
	attach(s, e, c)
	return c
end

--- the key of a connector waiting for its block (by its position)
local function place_key(e) return e.surface.index .. ":" .. e.position.x .. ":" .. e.position.y end

--- the connector of block `unit` (tests, the windows)
function M.connector_of(unit)
	local s = storage.fork_me_conn
	local h = s and s.hosts[unit]
	return h and h.conn and h.conn.valid and h.conn or nil
end

--- copies the condition of block `src`'s connector to block `dst`'s (a settings paste of the blocks, a clone)
function M.copy(src, dst)
	if not (src and src.valid and dst and dst.valid) then return end
	local hs = storage.fork_me_conn and storage.fork_me_conn.hosts[src.unit_number]
	if not (hs and hs.conn and hs.conn.valid) then return end         -- (the original has no connector: no condition to copy)
	local a, b = M.ensure(src), M.ensure(dst)
	if not (a and b) then return end
	local ca, cb = a.get_control_behavior(), b.get_or_create_control_behavior()
	if cb then
		cb.circuit_enable_disable = ca and ca.circuit_enable_disable or false
		if ca and ca.circuit_condition then cb.circuit_condition = ca.circuit_condition end
	end
	M.update(dst.unit_number)
end

--- a block or a connector (or its ghost) was built; `source`: the original of a clone
function M.on_built(entity, source)
	if not (entity and entity.valid) then return end
	if entity.name == "entity-ghost" then
		if entity.ghost_name == NAME then
			--- revived at once: no robot brings the hidden item; the block built there later takes it
			local _, c = entity.revive{ raise_revive = false }
			if c and c.valid then M.on_built(c) end
		end
		return
	end
	local s = state()
	if entity.name == NAME then
		local e = host_at(entity)
		if e then
			local h = s.hosts[e.unit_number]
			if h and h.conn and h.conn.valid and h.conn ~= entity then
				--- (the block has one: a blueprint pasted over it, a clone of both) the newer one stays, with its wires
				s.by_conn[h.conn.unit_number] = nil
				h.conn.destroy()
			end
			attach(s, e, entity)
		elseif not host_ghost_at(entity) then
			entity.destroy()                                       -- (a connector alone: nothing it belongs to)
		else
			entity.destructible = false                            -- (waits for the block built at its ghost)
			s.orphans = s.orphans or {}
			s.orphans[place_key(entity)] = entity
		end
		return
	end
	if not HOSTS[entity.name] then return end
	--- a block built where a connector of a blueprint waits takes it (a table lookup: no search per built block)
	local waiting = s.orphans and s.orphans[place_key(entity)]
	if waiting then
		s.orphans[place_key(entity)] = nil
		if not next(s.orphans) then s.orphans = nil end
		if waiting.valid then attach(s, entity, waiting) end
	end
	if not (source and source.valid and HOSTS[source.name]) then return end
	--- a clone: a connector cloned with it took its place already (its wires came along); else the original's condition, when
	--- the original has a connector
	local hs = s.hosts[source.unit_number]
	if not (hs and hs.conn and hs.conn.valid) then return end
	M.ensure(entity)
	local h = s.hosts[entity.unit_number]
	local c = h and h.conn
	local cloned = c and c.valid and c.get_control_behavior()
	if not (cloned and cloned.circuit_enable_disable) then M.copy(source, entity) end
end

--- a block was removed: its connector goes; a connector that died (it cannot be damaged, but a script may) is made again
function M.on_removed(entity)
	if not (entity and entity.valid) then return end
	local s = storage.fork_me_conn
	if not s then return end
	if entity.name == NAME then
		local unit = s.by_conn[entity.unit_number]
		s.by_conn[entity.unit_number] = nil
		local h = unit and s.hosts[unit]
		if h and h.host and h.host.valid then h.conn = nil end    -- (the next check or visit of the block makes it again)
		return
	end
	if not HOSTS[entity.name] then return end
	local unit = entity.unit_number
	local h = s.hosts[unit]
	if not h then return end
	if h.conn and h.conn.valid then
		s.by_conn[h.conn.unit_number] = nil
		h.conn.destroy()
	end
	s.hosts[unit] = nil
	unlist(s, unit)
end

--- the game's lamp window of a connector was closed: its condition may have changed
function M.on_gui_closed(event)
	local e = event.entity
	if not (e and e.valid and e.name == NAME) then return end
	local s = storage.fork_me_conn
	local unit = s and s.by_conn[e.unit_number]
	if unit then M.update(unit) end
end

--- settings paste: connector onto connector (the game copies the condition), block onto block (the condition too)
function M.on_entity_settings_pasted(event)
	local src, dst = event.source, event.destination
	if not (src and src.valid and dst and dst.valid) then return end
	local s = storage.fork_me_conn
	if dst.name == NAME then
		local unit = s and s.by_conn[dst.unit_number]
		if unit then M.update(unit) end
	elseif HOSTS[src.name] and HOSTS[dst.name] then
		M.copy(src, dst)
	end
end

--- the checks of the listed blocks (control.lua's on_tick; at most CHECKS_PER_TICK, each at most every INTERVAL ticks)
function M.on_tick(tick)
	local s = storage.fork_me_conn
	if not s then return end
	local list = s.list
	local n = #list
	if n == 0 then return end
	local checks = math.min(CHECKS_PER_TICK, n)
	local i = s.cursor
	for _ = 1, checks do
		if i > #list then i = 1 end
		local unit = list[i]
		local h = s.hosts[unit]
		if not (h and h.host and h.host.valid) then
			table.remove(list, i)
			if h then s.hosts[unit] = nil end
			set_off(s, h and h.kind, unit, false)
			s.edge[unit] = nil
			if #list == 0 then break end
		else
			i = i + 1
			if (h.due or 0) <= tick then
				h.due = tick + INTERVAL
				if not (h.conn and h.conn.valid) then M.ensure(h.host) end
				local lv = level(h)
				local on = lv ~= false
				local was = not s.off[unit]
				set_off(s, h.kind, unit, not on, lv)        -- (every check: the record's field follows even a record made anew)
				if on ~= was and on then wake(h, unit) end
				if h.pulse then
					if on and not h.last then
						s.edge[unit] = true
						wake(h, unit)
					end
					h.last = on
				end
				if h.read then
					local sig = signature(unit)
					if sig ~= h.sig then
						h.sig = sig
						wake(h, unit)
					end
				end
			end
		end
	end
	s.cursor = i
end

--- the connectors that belong to no block are given to the block at their place or removed (a block gets one when a player
--- points at it, M.ensure)
function M.on_configuration_changed()
	local s = state()
	for _, surface in pairs(game.surfaces) do
		for _, c in pairs(surface.find_entities_filtered{ name = NAME }) do
			if not s.by_conn[c.unit_number] then M.on_built(c) end
		end
	end
	for unit, h in pairs(s.hosts) do
		if not (h.host and h.host.valid) then
			if h.conn and h.conn.valid then h.conn.destroy() end
			s.hosts[unit] = nil
			unlist(s, unit)
		end
	end
end

remote.add_interface("gregtorio-me-connector", {
	--- tests: the connector of a block, made when it has none
	connector = function(entity) return M.ensure(entity) end,
	--- tests: the block's connector was changed by a script (what closing its window does)
	update = function(entity) if entity and entity.valid then M.update(entity.unit_number) end end,
	is_off = function(entity) return entity and entity.valid and M.is_off(entity.unit_number) or false end,
	--- tests: the state { hosts, listed, off } of the checks
	stats = function()
		local s = state()
		local hosts, off = 0, 0
		for _ in pairs(s.hosts) do hosts = hosts + 1 end
		for _ in pairs(s.off) do off = off + 1 end
		return { hosts = hosts, listed = #s.list, off = off }
	end,
	on_built = function(entity, source) M.on_built(entity, source) end,
})

return M
