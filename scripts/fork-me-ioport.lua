--------------------------------------------------------------------------------
--- ME IO PORT (me-network issue #386; AE2's ME IO Port, appeng/tile/storage/TileIOPort.java of AE2-Unofficial; prototypes:
--- prototypes/network.lua; guide: docs/AE2.md "ME IO Port")
---   * A 1x1 block of the network with two cell slots (a script inventory, `rec.cells`, shown in its window): a storage
---     cell put into the input slot is worked on, a cell that is done goes into the output slot. The mode (`rec.mode`):
---     "empty" moves everything the cell holds into the network (the network's insert, its partitions and priorities;
---     the cell is done when it is empty), "fill" moves what the network holds and the cell takes (its partition and
---     cards, N.cell_room) into the cell (done when a pass over the network's keys moved nothing: the cell is full, or the
---     network has nothing more it takes). AE2's port has six slots of each and a fullness mode; this one is the
---     simplified port the issue asks for. A void cell is refused (filled, it would destroy what it takes).
---   * Speed: the bus speed (map settings "bus speed", items and fluid per second) times the factor of its speed cards
---     (the cards and factors of the import and export bus, `N.card_rules().io_port`, scripts/fork-me-cardslots.lua),
---     times the ticks since its last visit (at most MAX_CATCH_UP). AE2's port speeds fluid cells as well: so does this.
---   * Visits (CLAUDE.md, issue #5): a queue of its own (`s.q`, tag "io_port") with a budget (map settings "ME IO Port visits
---     per tick", at least and at most), run by control.lua's on_tick. A port with work comes back after MIN_INTERVAL
---     ticks when it moved all its speed allowed, else after ACTIVE_INTERVAL. A port without work is parked (no visit):
---     no cell, or a done cell and a full output slot ("no-cell", "out-full": its window and blueprints wake it), no network
---     or no power ("no-network", "no-power": N.wait_usable), a network without room for what the cell holds
---     ("net-full": N.wait_room); a parked port gets the scheduler's slow fallback visit.
---   * A visit reads the cell from its stack (N.cell_from_stack), moves at most MAX_KEYS keys of it, and writes it back
---     (N.cell_stack): the stack always holds the cell's contents, also when the port is mined or the cell taken out.
---     The fill mode goes through the network's keys in a list made at the start of a pass (`rec.fkeys`, `rec.fpos`):
---     the keys the cell takes then, or only the ones it holds once its types are used up.
---   * Kept in blueprints, settings paste and clones: the mode and the cards (tag fork_me_io_port).
--- State: storage.fork_me_ioport = { recs = { [unit] = { entity, cells, mode, inv (cards), cards, want, where, last,
--- fkeys, fpos, fmoved, status, ... the scheduler's fields } }, list, q }.
--------------------------------------------------------------------------------

local N = require("scripts.fork-me-network")
local G = require("scripts.fork-me-gui")
local Sched = require("scripts.fork-me-schedule")
local CS = require("scripts.fork-me-cardslots")

local M = {}

local NAME = "me-io-port"
local TAG = "fork_me_io_port"
local SLOT_IN, SLOT_OUT = 1, 2
local MIN_INTERVAL = 15              -- ticks until the next visit of a port that moved all it was allowed to
local ACTIVE_INTERVAL = 30           -- ... of a port that moved less
local MAX_CATCH_UP = 600             -- ticks of speed a visit may catch up at most
local MAX_KEYS = 16                  -- keys a visit moves at most
local MAX_SCAN = 256                 -- keys of the network a fill visit looks at at most
local MAX_COUNT = 2 ^ 31 - 1         -- items a visit moves at most (an engine count is 32 bit)
local MODES = { empty = true, fill = true }

local function state()
	local s = storage.fork_me_ioport
	if not s then
		s = { recs = {}, list = {}, q = Sched.new("io_port") }
		storage.fork_me_ioport = s
	end
	return s
end

local function is_port(entity) return entity and entity.valid and entity.name == NAME end

local function rec_of(entity)
	local s = storage.fork_me_ioport
	return s and is_port(entity) and s.recs[entity.unit_number] or nil
end

local function unit_rec(unit)
	local s = storage.fork_me_ioport
	return s and s.recs[unit]
end

--- the cell slots of a port (a script inventory of 2)
local function cells_of(rec)
	local inv = rec.cells
	if inv and inv.valid then return inv end
	local e = rec.entity
	inv = game.create_inventory(2, e and e.valid and e.localised_name or { "entity-name." .. NAME })
	rec.cells = inv
	return inv
end

--- visit the port at the next tick (a cell came or left, the mode or the cards changed, the network woke it)
local function wake(unit)
	local s = storage.fork_me_ioport
	local rec = s and s.recs[unit]
	if not rec then return end
	if rec.park then rec.last = nil end                     -- (parked: how long it could have moved is unknown)
	Sched.wake(s.q, rec, unit)
end
M.wake = wake
N.wakers.io_port = wake

local cards
cards = CS.new{
	rules = function() return N.card_rules().io_port end,
	title = function(rec) return rec.entity and rec.entity.valid and rec.entity.localised_name or { "entity-name." .. NAME } end,
	rec_of = rec_of,
	on_cards = function(rec, light)
		local counts, r = cards.counts(rec), N.card_rules()
		local f = r.speed[(counts.speed or 0) + 1]
		if counts.superspeed then f = f + r.superspeed[counts.superspeed] end
		if counts.superluminal then f = f + r.superluminal[counts.superluminal] end
		rec.accel = f > 1 and f or nil
		if not light and rec.entity and rec.entity.valid then wake(rec.entity.unit_number) end
	end,
}
M.cards = cards

local function register(entity)
	local s = state()
	local unit = entity.unit_number
	local rec = s.recs[unit]
	if not rec then
		rec = { entity = entity, mode = "empty",
			where = { surface = entity.surface.index, x = entity.position.x, y = entity.position.y } }
		s.recs[unit] = rec
		s.list[#s.list + 1] = unit
	end
	cells_of(rec)
	cards.inv_of(rec)
	return rec
end

--- the port leaves: its cells go to `buffer` (mined) or onto the ground where it stood, its cards too
local function forget(s, unit, buffer)
	local rec = s.recs[unit]
	if not rec then return end
	Sched.forget(s.q, rec)
	local inv = rec.cells
	if inv and inv.valid then
		local w = rec.where
		local surface = w and game.surfaces[w.surface]
		for i = 1, #inv do
			local st = inv[i]
			if st.valid_for_read then
				if buffer and buffer.valid then buffer.insert(st) st.clear() end
				if st.valid_for_read and surface then
					surface.spill_item_stack{ position = { w.x, w.y }, stack = st, enable_looted = true }
					st.clear()
				end
			end
		end
		inv.destroy()
	end
	if buffer and buffer.valid then cards.give_cards(rec, buffer) else cards.spill_cards(rec) end
	cards.detach(rec)
	s.recs[unit] = nil
	for i = #s.list, 1, -1 do if s.list[i] == unit then table.remove(s.list, i) break end end
end

--- the items (and fluid units) a visit of `dt` ticks may move
local function caps(rec, dt)
	local f = (rec.accel or 1) * dt / 60
	return math.min(MAX_COUNT, math.floor(Sched.setting("bus_items") * f)), Sched.setting("bus_fluid") * f
end

--- the empty mode: up to MAX_KEYS keys of the cell into the network. Returns what moved, whether all the speed allowed
--- went, and whether the network refused some (full).
local function empty_cell(net, cell, icap, fcap)
	local keys = {}
	for key in pairs(cell.items) do keys[#keys + 1] = key end
	table.sort(keys)
	local moved, full, refused = 0, false, false
	local n = 0
	for _, key in ipairs(keys) do
		if n >= MAX_KEYS then break end
		local fluid = N.is_fluid_key(key)
		local cap = fluid and fcap or icap
		if cap > 0 then
			n = n + 1
			local want = math.min(cell.items[key], cap)
			local got = N.cell_to_network(net, cell, key, want)
			if fluid then fcap = fcap - got else icap = icap - got end
			moved = moved + got
			if got < want - 1e-6 then
				if (fluid and fcap > 0) or (not fluid and icap > 0) then refused = true end
			end
		end
	end
	full = icap <= 0 or fcap <= 0
	return moved, full, refused
end

--- the fill mode: the network's keys the cell takes, in turn (rec.fkeys), into the cell. Returns what moved, whether all
--- the speed allowed went, and whether the pass is over and moved nothing (the cell is done).
local function fill_cell(rec, net, cell, icap, fcap)
	local spec = N.cell_spec(cell.name)
	if cell.bytes >= spec.bytes then return 0, false, true end
	if not rec.fkeys then
		local list = {}
		if cell.types >= spec.types then
			for key in pairs(cell.items) do list[#list + 1] = key end    -- (no room for a new kind: only the ones it holds)
		else
			for key in pairs(net.items) do
				if N.cell_room(cell, key) > 0 then list[#list + 1] = key end
			end
		end
		table.sort(list)
		rec.fkeys, rec.fpos, rec.fmoved = list, 1, false
	end
	local list, i = rec.fkeys, rec.fpos
	local moved, n, scanned = 0, 0, 0
	while i <= #list and n < MAX_KEYS and scanned < MAX_SCAN and (icap > 0 or fcap > 0) do
		local key = list[i]
		scanned = scanned + 1
		local fluid = N.is_fluid_key(key)
		local cap = fluid and fcap or icap
		local got = 0
		if cap > 0 then
			got = N.network_to_cell(net, cell, key, cap)
			if got > 0 then
				n = n + 1
				if fluid then fcap = fcap - got else icap = icap - got end
				moved = moved + got
			end
		end
		--- a key that still has more and the cell room for it is visited again, the next key otherwise
		if got <= 0 or (N.count_key(net, key) <= 0) or N.cell_room(cell, key) <= 0 then i = i + 1 end
	end
	rec.fpos = i
	if moved > 0 then rec.fmoved = true end
	local full = icap <= 0 or fcap <= 0
	if i > #list then                                   -- (the pass is over: a new one, or the cell is done)
		local done = not rec.fmoved
		rec.fkeys, rec.fpos, rec.fmoved = nil, nil, nil
		return moved, full, done
	end
	return moved, full, false
end

--- the cell in the input slot is done: into the output slot (false when that is taken)
local function finish(rec, inv)
	rec.fkeys, rec.fpos, rec.fmoved = nil, nil, nil
	if inv[SLOT_OUT].valid_for_read then return false end
	inv[SLOT_OUT].transfer_stack(inv[SLOT_IN])
	return true
end

--- One visit (Sched.run): moves what the speed allows, schedules the next visit or parks the port. `fallback`: the slow
--- visit of a parked port (work found then is a missed wake). Returns the class of the counters (0 nothing, 1 something,
--- 2 all it was allowed to).
local function visit(rec, unit, fallback)
	local s = storage.fork_me_ioport
	local e = rec.entity
	if not (e and e.valid) then
		forget(s, unit, nil)
		return nil
	end
	local now = game.tick
	local dt = math.min(MAX_CATCH_UP, now - (rec.last or (now - MIN_INTERVAL)))
	rec.last = now
	local inv = cells_of(rec)
	local stack = inv[SLOT_IN]
	local function park(reason)
		rec.status = reason
		Sched.park(s.q, rec, unit, reason)
		return 0
	end
	if not stack.valid_for_read then return park("no-cell") end
	local net = N.network_of(e)
	if not net then return park("no-network") end
	if not N.usable(net) then
		N.wait_usable(net, "io_port", unit)
		return park("no-power")
	end
	local cell = N.cell_from_stack(stack)
	local icap, fcap = caps(rec, dt)
	local moved, full, done, refused
	if rec.mode == "fill" then
		moved, full, done = fill_cell(rec, net, cell, icap, fcap)
	else
		moved, full, refused = empty_cell(net, cell, icap, fcap)
		done = next(cell.items) == nil
	end
	if moved > 0 then stack.set_stack(N.cell_stack(cell)) end
	if fallback and moved > 0 then Sched.missed("io_port") end
	if done then
		if not finish(rec, inv) then return park("out-full") end
		rec.status = "done"
		Sched.park(s.q, rec, unit, "no-cell")             -- (the next cell put in wakes it)
		return moved > 0 and 1 or 0
	end
	if refused and moved <= 0 then
		N.wait_room(net, "io_port", unit)
		return park("net-full")
	end
	rec.status = moved > 0 and "working" or "waiting"
	Sched.at(s.q, rec, unit, now + (full and MIN_INTERVAL or ACTIVE_INTERVAL))
	if full then return 2 end
	return moved > 0 and 1 or 0
end

--- a probe (the parked ports' slow fallback): a full visit
local function probe(rec, unit) return visit(rec, unit, rec.park ~= nil) end

function M.on_tick(tick)
	local s = storage.fork_me_ioport
	if s and #s.list > 0 then
		Sched.run(s.q, tick, Sched.setting("io_port"), Sched.setting("io_port_max"), unit_rec, visit, probe, "io_port")
	end
end

--------------------------------------------------------------------------------
--- the window's actions (scripts/fork-me-windows.lua) and the settings
--------------------------------------------------------------------------------

--- a click on cell slot `slot` (1 input, 2 output) with `cursor` (a LuaItemStack) and `inventory` (the player's, for
--- shift); returns the reason of a refusal (a locale key suffix of fork-me-gui.refused-*)
function M.cell_click(entity, slot, cursor, inventory, shift)
	local rec = rec_of(entity)
	if not rec then return "no-target" end
	local inv = cells_of(rec)
	local st = inv[slot]
	if not st then return "no-target" end
	if cursor and cursor.valid_for_read then
		if slot ~= SLOT_IN then return "io-port-output" end
		local spec = N.cell_spec(cursor.name)
		if not spec then return "not-a-cell" end
		if spec.void then return "io-port-void" end
		if st.valid_for_read then
			local held = game.create_inventory(1)
			held[1].transfer_stack(cursor)
			cursor.transfer_stack(st)
			st.transfer_stack(held[1])
			held.destroy()
		else
			st.transfer_stack(cursor)
		end
	elseif st.valid_for_read then
		if shift then
			if not (inventory and inventory.valid) then return "no-inventory" end
			if inventory.insert(st) < 1 then return "inventory-full" end
			st.clear()
		elseif not (cursor and cursor.transfer_stack(st)) then
			return "inventory-full"
		end
	else
		return nil
	end
	rec.fkeys, rec.fpos, rec.fmoved = nil, nil, nil
	wake(entity.unit_number)
	return nil
end

--- shift + click on a stack of the player's inventory in the window: a cell into the input slot, a card into the card slots
function M.shift_in(entity, stack)
	local rec = rec_of(entity)
	if not rec then return "no-target" end
	if not (stack and stack.valid_for_read) then return nil end
	local spec = N.cell_spec(stack.name)
	if spec then
		if spec.void then return "io-port-void" end
		local st = cells_of(rec)[SLOT_IN]
		if st.valid_for_read then return "io-port-occupied" end
		local one = stack.count > 1
		if one then
			st.set_stack{ name = stack.name, count = 1, quality = stack.quality.name }
			stack.count = stack.count - 1
		else
			st.transfer_stack(stack)
		end
		rec.fkeys, rec.fpos, rec.fmoved = nil, nil, nil
		wake(entity.unit_number)
		return nil
	end
	return cards.shift_in(entity, stack)
end

function M.set_mode(entity, mode)
	local rec = rec_of(entity)
	if not (rec and MODES[mode]) then return false end
	if rec.mode ~= mode then
		rec.mode = mode
		rec.fkeys, rec.fpos, rec.fmoved = nil, nil, nil
		wake(entity.unit_number)
	end
	return true
end

--- what the window shows: { mode, status, accel (the speed factor), items and fluid per second, in, out (the cells' stacks
--- as names, nil: empty) }
function M.info(entity)
	local rec = rec_of(entity)
	if not rec then return nil end
	local inv = cells_of(rec)
	local f = rec.accel or 1
	local function name_of(st) return st.valid_for_read and st.name or nil end
	return { mode = rec.mode, status = rec.status or (inv[SLOT_IN].valid_for_read and "waiting" or "no-cell"), accel = f,
		items = Sched.setting("bus_items") * f, fluid = Sched.setting("bus_fluid") * f,
		input = name_of(inv[SLOT_IN]), output = name_of(inv[SLOT_OUT]), parked = rec.park, cards = cards.card_list(rec) }
end

function M.cells(entity)
	local rec = rec_of(entity)
	return rec and cells_of(rec) or nil
end

--- the card slots (a script inventory, scripts/fork-me-cardslots.lua)
function M.card_inventory(entity)
	local rec = rec_of(entity)
	return rec and cards.inv_of(rec) or nil
end

local function settings_of(rec)
	local list = rec.want and { table.unpack(rec.want) } or cards.card_list(rec)
	return { mode = rec.mode, cards = list }
end

local function apply(entity, t)
	if type(t) ~= "table" then return end
	if MODES[t.mode] then M.set_mode(entity, t.mode) end
	if type(t.cards) == "table" and #t.cards > 0 then cards.want_cards(entity, t.cards, nil) end   -- (from the network)
end

--------------------------------------------------------------------------------
--- events
--------------------------------------------------------------------------------

--- `tags`: blueprint tags of a built ghost (or of a paste over a port, issue #383); `source`: the original of a clone
function M.on_built(entity, tags, source)
	if not is_port(entity) then return end
	register(entity)
	local t = type(tags) == "table" and tags[TAG] or nil
	if type(t) == "table" then
		apply(entity, t)
	elseif is_port(source) then
		local from = rec_of(source)
		if from then apply(entity, settings_of(from)) end
	end
	wake(entity.unit_number)
end

--- mined (`buffer`: the cells and cards go there) or destroyed (nil: they are spilled where it stood)
function M.on_removed(entity, buffer)
	if not (is_port(entity) and entity.unit_number) then return end
	local s = storage.fork_me_ioport
	if s then forget(s, entity.unit_number, buffer) end
end

function M.on_entity_settings_pasted(event)
	local src, dst = event.source, event.destination
	if not (is_port(src) and is_port(dst)) then return end
	local from = rec_of(src)
	if not from then return end
	M.set_mode(dst, from.mode)
	local player = event.player_index and game.get_player(event.player_index) or nil
	cards.want_cards(dst, settings_of(from).cards or {}, player)
end

function M.tag_blueprint(bp, mapping)
	local s = storage.fork_me_ioport
	if not s then return end
	for index, entity in pairs(mapping) do
		local rec = entity.valid and entity.name == NAME and s.recs[entity.unit_number]
		if rec then bp.set_blueprint_entity_tag(index, TAG, settings_of(rec)) end
	end
end

--- after a mod change: the ports of the world (records kept by unit number, new ones made), every one visited again
function M.on_configuration_changed()
	local s = state()
	if not s.q then s.q = Sched.new("io_port") end
	for unit, rec in pairs(s.recs) do
		if not (rec.entity and rec.entity.valid) then forget(s, unit, nil) end
	end
	for _, surface in pairs(game.surfaces) do
		for _, e in pairs(surface.find_entities_filtered{ name = NAME }) do register(e) end
	end
	for unit in pairs(s.recs) do wake(unit) end
end

--- the port of a window by its unit number
function M.by_unit(unit)
	local rec = unit_rec(unit)
	return rec and rec.entity and rec.entity.valid and rec.entity or nil
end

remote.add_interface("gregtorio-me-ioport", {
	info = function(entity) return M.info(entity) end,
	set_mode = function(entity, mode) return M.set_mode(entity, mode) end,
	--- the cell slots (1 input, 2 output) and the card slots, as the window's clicks reach them
	cells = function(entity) return M.cells(entity) end,
	cell_click = function(entity, slot, cursor, inventory, shift) return M.cell_click(entity, slot, cursor, inventory, shift) end,
	shift_in = function(entity, stack) return M.shift_in(entity, stack) end,
	card_click = function(entity, slot, cursor, inventory, shift) return cards.card_click(entity, slot, cursor, inventory, shift) end,
	--- the runtime test's save and load check (issue #38): the port's schedule
	schedule = function(entity)
		local rec = rec_of(entity)
		if not rec then return nil end
		local due = rec.due
		return { due = (due and due > 0) and due or nil, last = rec.last, probing = rec.sq == true and not rec.park,
			front = due == Sched.FRONT, backlog = due == Sched.BACKLOG, parked = rec.park }
	end,
	removed = function(entity, buffer) M.on_removed(entity, buffer) end,
})

M.NAME = NAME
return M
