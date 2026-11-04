--------------------------------------------------------------------------------
--- ME NETWORK: THE CIRCUIT CONDITION OF THE BUSES, THE ME INTERFACE AND THE PATTERN PROVIDER (issues #412, #628)
--- AE2's Redstone Card (AE2-Unofficial: Upgrades.REDSTONE, the RedstoneMode of PartSharedItemBus) as Factorio's circuit
--- condition, on the ME Import, Export and Storage Bus and the ME Interface, without a card (the maintainer's choice); issue
--- #429: on the ME Pattern Provider too, whose lock modes read it (AE2-Unofficial's Lock Crafting Card without the card).
--- Issue #628: the blocks take the wires themselves (the buses and the provider are display panels, the interface a container
--- with a circuit connector, prototypes/wired.lua). Neither type has a condition of its own, so the condition (signal,
--- comparator, constant or second signal) is kept here per block and set in the block's ME window (scripts/fork-me-windows.lua).
--- Until 0.5.11 each block had a hidden lamp at its position for the wires and the condition (`me-circuit-connector`, the
--- second hitbox in the corner of its tile): a placed one or a ghost of one (a blueprint made before) hands its wires and its
--- condition to the block at its place and is removed (M.adopt; its prototype stays hidden for the saves and blueprints that
--- hold it).
---   * A block whose condition is on, that has a wire and whose condition does not hold is off: `off[unit]`, and the block's
---     own record gets `coff` through its module's setter (N.off_setters; the visits of fork-me-io.lua and
---     fork-me-storagebus.lua read only that field: the bench at 5000 showed a function call and the unit number per visit),
---     parked until it is on again. Without a wire the condition does nothing, as on an inserter. The setter also gets the
---     condition's level (true: it holds, false: it does not, nil: it does nothing), which the provider's locks read (#429).
---   * The blocks whose condition is on, or that read the circuit (the export bus's pulse mode, the interface's rows from the
---     circuit, the provider's lock modes), are in `list`; CHECKS_PER_TICK of them are checked per tick, each at most every
---     INTERVAL ticks (issue #5's rule: a list and a budget; a block without them has no record and costs nothing, wired or
---     not). A check reads the block's wires: a block that turns on is woken; in pulse mode a rise of the condition gives one
---     visit (`edge[unit]`, taken by M.take_pulse); for the interface's rows the signals' signature, a change wakes it.
---   * The condition changes in the block's window (M.set_condition), by settings paste, blueprints (the tag TAG), clones and
---     the ME Memory Card: the block's place in `list` follows (M.update).
---   * The ME Interface is a container, which puts its contents on its wires unless `read_contents` is off: the script keeps it
---     off (a block's record is made, a player points at it, its windows close, every interface at on_configuration_changed),
---     so its contents never mix with the signals its condition and its rows read.
---   * Issue #639: the logistic network condition, as on a vanilla inserter, belt or lamp: `lc` (connected to the logistic
---     network) and `lcond` (a condition on the network's contents: an item signal counts the network's items of its quality,
---     any other first signal never holds, as the game's). The network is the one whose logistic area covers the block
---     (LuaSurface.find_logistic_network_by_position), looked up at most every LOOKUP ticks (5 s) per block (`lnet`, `lnext`) or at
---     once when it became invalid. Measured on a real inserter (Factorio 2.1.24): connected outside every logistic network
---     (also inside a construction area only) it is off; a circuit condition without a wire does nothing. With both on, the
---     block works only while both hold: the level of both replaces the circuit's (the off state, the pulse's rise, the
---     provider's locks).
--- State: storage.fork_me_conn = { hosts = { [unit] = { host, kind, cc, cond, lc, lcond, lnet, lnext, pulse, read, last, sig,
--- due } },
--- off = { [unit] = true }, edge = { [unit] = true }, list = { units }, cursor,
--- orphans = { ["<surface>:<x>:<y>"] = { entity = an old connector's ghost waiting for its block's ghost, tick } } }
--- `cond` = { first_signal, comparator, constant, second_signal } (a CircuitCondition without `fulfilled`).
--------------------------------------------------------------------------------

local N = require("scripts.fork-me-network")

local M = {}

--- the hidden lamp of 0.5.11 and before (prototypes/connector.lua)
local NAME = "me-circuit-connector"
M.NAME = NAME
--- the blocks with a circuit condition, and which module visits them (the waker's name, N.wakers)
local HOSTS = { ["me-import-bus"] = "io", ["me-export-bus"] = "io", ["me-network-interface"] = "io", ["me-storage-bus"] = "sbus",
	["me-pattern-provider"] = "provider" }                     -- (issue #429: the provider's lock by the condition)
M.HOSTS = HOSTS
local INTERFACE = "me-network-interface"
--- the blueprint tag of a block's condition: { cc = true or nil, cond }
local TAG = "fork_me_condition"
M.TAG = TAG
local CHECKS_PER_TICK = 16
local INTERVAL = 10                -- ticks: how late a block follows its condition at most, while the budget holds
local RED, GREEN = defines.wire_connector_id.circuit_red, defines.wire_connector_id.circuit_green
local WIRES = { RED, GREEN }
--- the comparators as the ME Level Maintainer's window shows them (scripts/fork-me-circuit.lua); the game's own (a lamp's
--- condition reads back "≥", "≤", "≠") are taken as these
M.COMPARATORS = { ">", "<", "=", ">=", "<=", "!=" }
local COMPARATORS = { [">"] = ">", ["<"] = "<", ["="] = "=", [">="] = ">=", ["<="] = "<=", ["!="] = "!=",
	["≥"] = ">=", ["≤"] = "<=", ["≠"] = "!=" }
local LOOKUP = 300                 -- ticks: how often a block with a logistic condition looks up its logistic network (#639)
local ORPHAN_TICKS = 2             -- an old connector's ghost whose block's ghost did not come within this is removed

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
		s = { hosts = {}, off = {}, edge = {}, list = {}, cursor = 1 }
		storage.fork_me_conn = s
	end
	return s
end

--- is block `unit` switched off by its condition? (the visits; nil when no save state exists yet)
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

local function wired(e)
	for _, w in pairs(WIRES) do
		if e.get_circuit_network(w) then return true end
	end
	return false
end
M.wired = wired

--- an interface's contents stay off its wires (a container sends them by default)
local function quiet(e)
	if e.name ~= INTERFACE then return end
	local cb = e.get_or_create_control_behavior()
	if cb and cb.read_contents then cb.read_contents = false end
end

--------------------------------------------------------------------------------
--- the condition
--------------------------------------------------------------------------------

--- a copy of a condition as it is stored (nil: none or not one)
local function clean_signal(sig)
	if type(sig) ~= "table" or type(sig.name) ~= "string" then return nil end
	return { type = sig.type, name = sig.name, quality = sig.quality }
end
local function clean_condition(c)
	if type(c) ~= "table" then return nil end
	local out = { first_signal = clean_signal(c.first_signal), second_signal = clean_signal(c.second_signal),
		comparator = COMPARATORS[c.comparator] or "<", constant = math.floor(tonumber(c.constant) or 0) }
	if out.second_signal then out.constant = nil end
	return out
end
M.clean_condition = clean_condition

local function compare(a, op, b)
	if op == "<" then return a < b
	elseif op == ">" then return a > b
	elseif op == "=" then return a == b
	elseif op == ">=" then return a >= b
	elseif op == "<=" then return a <= b
	else return a ~= b end
end

--- does `cond` hold on the wires of `e`? (the lamp's rule: no first signal never holds; "everything" holds when every signal
--- does, also when there is none; "anything" when one does)
local function holds(e, cond)
	local first = cond and cond.first_signal
	if not first then return false end
	local op = cond.comparator or "<"
	local right = cond.second_signal and e.get_signal(cond.second_signal, RED, GREEN) or cond.constant or 0
	if first.type == "virtual" and (first.name == "signal-everything" or first.name == "signal-anything") then
		local all = first.name == "signal-everything"
		for _, sig in pairs(e.get_signals(RED, GREEN) or {}) do
			local ok = compare(sig.count, op, right)
			if all and not ok then return false end
			if ok and not all then return true end
		end
		return all
	end
	return compare(e.get_signal(first, RED, GREEN), op, right)
end

--- Issue #639: the ItemWithQualityID of an item signal, made once per name and quality (false: no item of this game); the
--- prototypes do not change while the game runs, so this is derived and kept outside `storage` (a check makes no table and
--- reads no prototype: the bench of issue #639)
local item_ids = {}
local function item_id(sig)
	local q = sig.quality or "normal"
	local by = item_ids[sig.name]
	if not by then
		by = {}
		item_ids[sig.name] = by
	end
	local id = by[q]
	if id == nil then
		id = prototypes.item[sig.name] ~= nil and prototypes.quality[q] ~= nil and { name = sig.name, quality = q } or false
		by[q] = id
	end
	return id
end

--- Issue #639: the count of an item signal in logistic network `net` (with its quality; nil: not an item, it counts nothing)
local function net_count(net, sig)
	if not (sig and (sig.type or "item") == "item") then return nil end
	local id = item_id(sig)
	if not id then return nil end
	return net.get_item_count(id)
end

--- Issue #639: does `cond` hold on the contents of logistic network `net`? (no network or no item as the first signal: never,
--- as on the game's inserter; a second signal that is no item counts 0)
local function net_holds(net, cond)
	if not (net and net.valid and cond) then return false end
	local left = net_count(net, cond.first_signal)
	if not left then return false end
	local right = cond.constant or 0
	if cond.second_signal then right = net_count(net, cond.second_signal) or 0 end
	return compare(left, cond.comparator or "<", right)
end
M.net_holds = net_holds

--- Issue #639: the logistic network whose logistic area covers block `e` (nil: none), found now (the windows)
local function find_network(e)
	return e.surface.find_logistic_network_by_position(e.position, e.force)
end
M.find_network = find_network

--- the block's logistic network as its checks see it: looked up at most every LOOKUP ticks (kept in the record, so a loaded
--- save follows the same checks), at once when the one it had became invalid
local function network(h, tick)
	local n = h.lnet
	if (h.lnext or 0) > tick and (n == nil or n.valid) then return n end
	n = find_network(h.host)
	h.lnet, h.lnext = n, tick + LOOKUP
	return n
end

--- the levels of the circuit and the logistic condition: true (it holds), false (it does not), nil (it does nothing: off, or
--- the circuit's without a wire); the logistic one without a network is false (the game's inserter is off then)
local function levels(h, tick)
	local e = h.host
	if not (e and e.valid) then return nil, nil end
	local cl, ll
	if h.cc and wired(e) then cl = holds(e, h.cond) end
	if h.lc then ll = net_holds(network(h, tick or game.tick), h.lcond) end
	return cl, ll
end

--- the level of both: nil when neither does anything, else true while each that does something holds
local function level(h, tick)
	local cl, ll = levels(h, tick)
	if cl == nil and ll == nil then return nil end
	return cl ~= false and ll ~= false
end

--- the signals on the block's wires, red and green added: { [key] = count } with item keys "name" / "name@quality" and fluid
--- keys "fluid/<name>"; virtual signals left out (the interface's rows from the circuit)
function M.signals(unit)
	local s = storage.fork_me_conn
	local h = s and s.hosts[unit]
	local e = h and h.host
	local out = {}
	if not (e and e.valid) then return out end
	for _, sig in pairs(e.get_signals(RED, GREEN) or {}) do
		local id = sig.signal
		local t = id.type or "item"
		local key
		if t == "item" then key = N.key_of(id.name, id.quality or "normal")
		elseif t == "fluid" then key = "fluid/" .. id.name end
		if key then out[key] = (out[key] or 0) + sig.count end
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

--- the block's condition or its mode changed (its window, a paste, a blueprint): its place in `list`, its state now
function M.update(unit)
	local s = state()
	local h = s.hosts[unit]
	if not h then return end
	if h.cc or h.lc or h.pulse or h.read then
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

--- the block's record, made when it has none (its condition, its modes)
function M.ensure(e)
	if not (e and e.valid and HOSTS[e.name] and e.unit_number) then return nil end
	local s = state()
	local h = s.hosts[e.unit_number]
	if h then
		h.host = e
		return h
	end
	h = { host = e, kind = HOSTS[e.name] }
	s.hosts[e.unit_number] = h
	quiet(e)
	return h
end

--- pulse mode of an export bus, rows from the circuit of an interface, the provider's pulse lock (their modules keep the
--- setting; this is the check)
function M.set_mode(unit, pulse, read)
	local s = state()
	local h = s.hosts[unit]
	if not h then return end
	h.pulse, h.read = pulse or nil, read or nil
	if not pulse then s.edge[unit] = nil end
	M.update(unit)
end

--- the block's condition: `cc` (it switches the block), `cond` (as stored; nil: none set)
function M.condition(e)
	local s = storage.fork_me_conn
	local h = e and e.valid and s and s.hosts[e.unit_number]
	if not h then return false, nil end
	return h.cc == true, h.cond and clean_condition(h.cond) or nil
end

--- sets the block's condition (its window, a paste, a blueprint, tests); `cond` nil keeps the one it has, false clears it
function M.set_condition(e, cc, cond)
	if not (e and e.valid and HOSTS[e.name]) then return false end
	local s = storage.fork_me_conn
	if not cc and not cond and not (s and s.hosts[e.unit_number]) then return true end   -- (nothing to clear: no record made)
	local h = M.ensure(e)
	if not h then return false end
	h.cc = cc and true or nil
	if cond ~= nil then h.cond = clean_condition(cond or nil) end
	M.update(e.unit_number)
	return true
end

--- Issue #639: the block's logistic condition: `lc` (connected to the logistic network), `lcond` (as stored; nil: none set)
function M.logistic(e)
	local s = storage.fork_me_conn
	local h = e and e.valid and s and s.hosts[e.unit_number]
	if not h then return false, nil end
	return h.lc == true, h.lcond and clean_condition(h.lcond) or nil
end

--- Issue #639: sets the block's logistic condition; `cond` nil keeps the one it has, false clears it
function M.set_logistic(e, lc, cond)
	if not (e and e.valid and HOSTS[e.name]) then return false end
	local s = storage.fork_me_conn
	if not lc and not cond and not (s and s.hosts[e.unit_number]) then return true end   -- (nothing to clear: no record made)
	local h = M.ensure(e)
	if not h then return false end
	h.lc = lc and true or nil
	if cond ~= nil then h.lcond = clean_condition(cond or nil) end
	h.lnet, h.lnext = nil, nil                               -- (looked up at the next check)
	M.update(e.unit_number)
	return true
end

--- whether the block's conditions hold now (the window: true, false, nil when it does nothing)
function M.level(e)
	local s = storage.fork_me_conn
	local h = e and e.valid and s and s.hosts[e.unit_number]
	if not h then return nil end
	return level(h)
end

--- Issue #639 (the panel): the levels of the circuit and the logistic condition apart, the logistic one with the network
--- found now (the checks' lookup is left as it is)
function M.levels(e)
	local s = storage.fork_me_conn
	local h = e and e.valid and s and s.hosts[e.unit_number]
	if not h then return nil, nil end
	local cl, ll
	if h.cc and wired(e) then cl = holds(e, h.cond) end
	if h.lc then ll = net_holds(find_network(e), h.lcond) end
	return cl, ll
end

--- copies the conditions of block `src` to block `dst` (a settings paste of the blocks, a clone)
function M.copy(src, dst)
	if not (src and src.valid and dst and dst.valid) then return end
	local cc, cond = M.condition(src)
	M.set_condition(dst, cc, cond or false)
	local lc, lcond = M.logistic(src)
	M.set_logistic(dst, lc, lcond or false)
end

--- the conditions of a block's blueprint tags applied to it (a block built from a ghost, pasted over, a Memory Card); a tag
--- made before #639 has no logistic part: the block's is cleared
function M.apply_tag(e, tags)
	local t = type(tags) == "table" and tags[TAG]
	if type(t) ~= "table" then return false end
	local ok = M.set_condition(e, t.cc, t.cond or false)
	M.set_logistic(e, t.lc, type(t.lcond) == "table" and t.lcond or false)
	return ok
end

--- the tag of a block's conditions (nil: it has none); the Memory Card and the blueprints
function M.tag_of(e)
	local cc, cond = M.condition(e)
	local lc, lcond = M.logistic(e)
	if not (cc or cond or lc or lcond) then return nil end
	return { cc = cc or nil, cond = cond, lc = lc or nil, lcond = lcond }
end

--- blueprints: the condition of every block that has one (control.lua's blueprint hooks)
function M.tag_blueprint(bp, mapping)
	local s = storage.fork_me_conn
	if not s then return end
	for index, e in pairs(mapping) do
		if e.valid and HOSTS[e.name] and s.hosts[e.unit_number] then
			local t = M.tag_of(e)
			if t then bp.set_blueprint_entity_tag(index, TAG, t) end
		end
	end
end

--------------------------------------------------------------------------------
--- the old connectors (0.5.11 and before)
--------------------------------------------------------------------------------

--- the key of a place (an old connector's ghost waiting for its block's ghost)
local function place_key(e) return e.surface.index .. ":" .. e.position.x .. ":" .. e.position.y end

local function at_place(e, x, y) return e.valid and e.position.x == x and e.position.y == y end

--- the block (or, `ghosts`, a block's ghost first) at the place of connector `c`
local function host_at(c, ghosts)
	local p = c.position
	if ghosts then
		for _, g in pairs(c.surface.find_entities_filtered{ name = "entity-ghost", position = p }) do
			if at_place(g, p.x, p.y) and HOSTS[g.ghost_name] then return g end
		end
	end
	for _, e in pairs(c.surface.find_entities_filtered{ position = p, force = c.force }) do
		if at_place(e, p.x, p.y) and HOSTS[e.name] then return e end
	end
	return nil
end
M.host_at = host_at

--- moves the wires of `src` onto `dst` (entities or ghosts), keeping each wire's other end
local function move_wires(src, dst)
	for _, w in pairs(WIRES) do
		local a = src.get_wire_connector(w, false)
		if a and a.connection_count > 0 then
			local b = dst.get_wire_connector(w, true)
			for _, c in pairs(a.connections) do
				if c.target.owner ~= dst then b.connect_to(c.target, false, c.origin) end
			end
		end
	end
end
M.move_wires = move_wires

--- the condition of an old connector (a lamp or its ghost): cc, cond
local function lamp_condition(c)
	local ok, cb = pcall(c.get_control_behavior)
	if not (ok and cb) then return false, nil end
	return cb.circuit_enable_disable == true, clean_condition(cb.circuit_condition)
end

--- An old connector `c` (placed or a ghost) hands its wires and condition to `target` (a block or a block's ghost) and goes.
local function hand_over(c, target)
	local cc, cond = lamp_condition(c)
	move_wires(c, target)
	if target.name == "entity-ghost" then
		local tags = target.tags or {}
		if cc or cond then tags[TAG] = { cc = cc or nil, cond = cond } end
		target.tags = tags
	else
		M.set_condition(target, cc, cond or false)
		quiet(target)
	end
	c.destroy()
end

--- An old connector (placed, built by a script, or a ghost of an old blueprint): its wires and condition go to the block at
--- its place (or that block's ghost). A ghost with no block's ghost there yet waits (`orphans`: the blueprint's block may come
--- after it in the same paste); a placed one alone is removed.
function M.adopt(c, tick)
	if not (c and c.valid) then return end
	local ghost = c.name == "entity-ghost"
	local target = host_at(c, ghost)
	if target then
		hand_over(c, target)
	elseif ghost then
		local s = state()
		s.orphans = s.orphans or {}
		s.orphans[place_key(c)] = { entity = c, tick = tick or game.tick }
	else
		c.destroy()
	end
end

--- an entry of `orphans`: a record { entity, tick } since #628; before, the connector itself (a save of a build before
--- #628 may still hold one, possibly invalid by now: only `valid` may be read on it)
local function orphan_entity(o)
	if type(o) == "table" then return o.entity end
	return o
end

--- a block or its ghost was built where an old connector's ghost waits: it takes it (a table lookup: no search per build)
local function take_orphan(e)
	local s = storage.fork_me_conn
	if not (s and s.orphans) then return end
	local key = place_key(e)
	local o = s.orphans[key]
	if not o then return end
	s.orphans[key] = nil
	if not next(s.orphans) then s.orphans = nil end
	local c = orphan_entity(o)
	if c and c.valid then hand_over(c, e) end
end

--------------------------------------------------------------------------------
--- events
--------------------------------------------------------------------------------

--- a block, its ghost or an old connector (or its ghost) was built; `tags`: the blueprint tags; `source`: the original of a clone
function M.on_built(entity, tags, source)
	if not (entity and entity.valid) then return end
	if entity.name == "entity-ghost" then
		if entity.ghost_name == NAME then M.adopt(entity)
		elseif HOSTS[entity.ghost_name] then take_orphan(entity) end
		return
	end
	if entity.name == NAME then
		M.adopt(entity)
		return
	end
	if not HOSTS[entity.name] then return end
	take_orphan(entity)
	if not M.apply_tag(entity, tags) and source and source.valid and HOSTS[source.name] then M.copy(source, entity) end
end

--- a block was removed: its record goes
function M.on_removed(entity)
	if not (entity and entity.valid and HOSTS[entity.name]) then return end
	local s = storage.fork_me_conn
	if not (s and s.hosts[entity.unit_number]) then return end
	unlist(s, entity.unit_number)
	s.hosts[entity.unit_number] = nil
end

--- a player points at a block: an interface's contents stay off its wires before it can be wired
function M.on_hover(e)
	if e and e.valid and e.name == INTERFACE then quiet(e) end
end

--- a window of an interface was closed (the game's container window, which the ME window's "Open inventory" shows, has the
--- circuit settings): its contents stay off the wire
function M.on_gui_closed(event)
	local e = event.entity
	if e and e.valid and e.name == INTERFACE then quiet(e) end
end

--- settings paste between two blocks of one kind: the condition too (the game pastes between any two display panels and
--- raises the event for them; the blocks' own pairs are those of prototypes/paste.lua)
function M.on_entity_settings_pasted(event)
	local src, dst = event.source, event.destination
	if not (src and src.valid and dst and dst.valid) then return end
	if HOSTS[src.name] and src.name == dst.name then M.copy(src, dst) end
end

--- `orphans` of a save made before #628 (0.5.11 and the builds before it): an entry was the connector itself, not a record
--- { entity, tick }, and may be invalid by now (only `valid` may be read on it). Each goes to M.adopt, which hands its
--- wires and condition to the block at its place, makes it a record again (a ghost with no block yet) or removes it.
--- Collected first: M.adopt may write into `orphans`, which a `pairs` over it must not see.
function M.legacy_orphans(s, tick)
	if not s.orphans then return end
	local old
	for key, o in pairs(s.orphans) do
		if type(o) ~= "table" then
			old = old or {}
			old[#old + 1] = o
			s.orphans[key] = nil
		end
	end
	if not old then return end
	if not next(s.orphans) then s.orphans = nil end
	for _, c in ipairs(old) do
		if c.valid then M.adopt(c, tick) end
	end
end

--- the checks of the listed blocks (control.lua's on_tick; at most CHECKS_PER_TICK, each at most every INTERVAL ticks)
function M.on_tick(tick)
	local s = storage.fork_me_conn
	if not s then return end
	if s.orphans then M.legacy_orphans(s, tick) end      -- (a save of 0.5.11 loaded without on_configuration_changed)
	if s.orphans then
		for key, o in pairs(s.orphans) do
			if tick - (o.tick or 0) >= ORPHAN_TICKS then
				s.orphans[key] = nil
				local c = o.entity
				if c and c.valid then c.destroy() end              -- (no block's ghost came: nothing it belongs to)
			end
		end
		if not next(s.orphans) then s.orphans = nil end
	end
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
				local lv = level(h, tick)
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

--- Issue #628 (scripts/fork-me-wired.lua): block `old` (a unit) was replaced by entity `new` at its place: its record (its
--- condition, its modes, its old connector) and its state move to the new unit
function M.rekey(old, new)
	local s = storage.fork_me_conn
	local h = s and s.hosts[old]
	if not h then return end
	local u = new.unit_number
	s.hosts[old], s.hosts[u] = nil, h
	h.host = new
	if s.by_conn and h.conn and h.conn.valid then s.by_conn[h.conn.unit_number] = u end
	if s.off[old] then s.off[old], s.off[u] = nil, true end
	if s.edge[old] then s.edge[old], s.edge[u] = nil, true end
	for i, unit in ipairs(s.list) do if unit == old then s.list[i] = u end end
end

--- Issue #628 (after scripts/fork-me-wired.lua replaced the old blocks): every old connector, placed or a ghost, hands its wires
--- and condition to the block at its place and goes; the records lose their connector; every interface keeps its contents off
--- its wires. Records of blocks that are gone are dropped.
function M.on_configuration_changed()
	local s = state()
	s.by_conn = nil                                          -- (0.5.11: connector unit -> block unit)
	M.legacy_orphans(s, game.tick)                           -- (before #628 an entry was the connector itself)
	for _, surface in pairs(game.surfaces) do
		for _, c in pairs(surface.find_entities_filtered{ name = NAME }) do M.adopt(c) end
		for _, g in pairs(surface.find_entities_filtered{ ghost_name = NAME }) do
			local target = host_at(g, true)
			if target then hand_over(g, target) else g.destroy() end
		end
		for _, e in pairs(surface.find_entities_filtered{ name = INTERFACE }) do quiet(e) end
	end
	for unit, h in pairs(s.hosts) do
		if h.conn then
			if h.conn.valid then h.conn.destroy() end           -- (a connector the search above did not reach)
			h.conn = nil
		end
		if not (h.host and h.host.valid) then
			s.hosts[unit] = nil
			unlist(s, unit)
		end
	end
	for unit in pairs(s.hosts) do M.update(unit) end
end

remote.add_interface("gregtorio-me-connector", {
	--- tests: the condition of a block (cc, cond) and setting it (what its window does)
	condition = function(entity) return { M.condition(entity) } end,
	set_condition = function(entity, cc, cond) return M.set_condition(entity, cc, cond) end,
	--- issue #639: the logistic condition (lc, lcond) and setting it; the levels of both conditions apart; the tag
	logistic = function(entity) return { M.logistic(entity) } end,
	set_logistic = function(entity, lc, cond) return M.set_logistic(entity, lc, cond) end,
	levels = function(entity) return { M.levels(entity) } end,
	level = function(entity) return M.level(entity) end,
	tag_of = function(entity) return M.tag_of(entity) end,
	apply_tag = function(entity, tags) return M.apply_tag(entity, tags) end,
	paste = function(source, destination) M.on_entity_settings_pasted{ source = source, destination = destination } end,
	--- tests: the block's wires were changed by a script (the next check sees it; this makes it now)
	update = function(entity) if entity and entity.valid then M.update(entity.unit_number) end end,
	is_off = function(entity) return entity and entity.valid and M.is_off(entity.unit_number) or false end,
	--- tests: the state { hosts, listed, off, orphans } of the checks
	stats = function()
		local s = state()
		local hosts, off, orphans = 0, 0, 0
		for _ in pairs(s.hosts) do hosts = hosts + 1 end
		for _ in pairs(s.off) do off = off + 1 end
		for _ in pairs(s.orphans or {}) do orphans = orphans + 1 end
		return { hosts = hosts, listed = #s.list, off = off, orphans = orphans }
	end,
	on_built = function(entity, tags, source) M.on_built(entity, tags, source) end,
})

return M
