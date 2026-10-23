--- Runtime test of me-network issue #493: an ME Export Bus with a Fuzzy Card exports the keys with data of its filters'
--- items (tags, a label, damage), as AE2's fuzzy export ignores the NBT and the damage; without the card it exports the plain
--- keys only. The item with tags is `zz-devcheck-tagged-wall` of data.lua (it places a copy of the stone wall, so a stack of
--- it can be damaged); a damaged stone wall is a key with data as well (issue #104).
--- * One network (a drive with one cell, a terminal, two export buses on chests): the terminal stores plain stacks and five
---   stacks with data (a label with kills, the same damaged, kills alone, damaged alone, a damaged stone wall). The first bus,
---   without a card, with the two items as filters, moves the plain ones only; the keys with data stay in the network.
--- * Then the second bus gets a Fuzzy Card and the two filters: it moves every key with data into its chest, each stack
---   with its count, health, tags, label and description, and the network holds none of the two items any more.
--- On main the fuzzy bus moves nothing (gf_list skipped every key with data). Loaded by control.lua:
--- require("fuzzydata")(H) returns { setup, tick, running } like margin.lua.

local NET, TERM, IO = "gregtorio-me-network", "gregtorio-me-terminal", "gregtorio-me-io"
local BX, BY = 380, 330                   -- (inside the cleared test area, TEST_RADIUS of control.lua; clear of taglabel.lua)
local START, CHECK1, CHECK2 = 100, 400, 800
local ITEM, WALL, FUZZY = "zz-devcheck-tagged-wall", "stone-wall", "me-fuzzy-card"
local PLAIN_ITEM, PLAIN_WALL = 3, 4
local EPS = 1e-3

--- the stacks with data the terminal stores: item, count, health, kills (tags), label, own description
local WANT = {
	{ name = ITEM, n = 1, health = 1, kills = 5, label = "Wall (5 Kills)", desc = "Kills: 5", what = "the stack with a label" },
	{ name = ITEM, n = 2, health = 0.4, kills = 5, label = "Wall (5 Kills)", desc = "Kills: 5", what = "the damaged stack with a label" },
	{ name = ITEM, n = 1, health = 1, kills = 7, desc = "Kills: 7", what = "the stack with kills alone" },
	{ name = ITEM, n = 2, health = 0.6, what = "the damaged stack of the item with tags" },
	{ name = WALL, n = 3, health = 0.5, what = "the damaged stone walls" },
}

return function(H)
	local me_place, me_report, power = H.me_place, H.me_report, H.power
	local T = {}
	local SOUTH = { direction = defines.direction.south }

	function T.setup(s)
		local fails = {}
		local what = "fuzzydata"
		local sc = {}
		power(s, fails, what, BX, BY)
		sc.ctrl = me_place(s, fails, what, "me-network-controller", BX + 7, BY)
		sc.drive = me_place(s, fails, what, "me-drive", BX + 8.5, BY - 0.5)
		sc.term = me_place(s, fails, what, "me-terminal", BX + 9.5, BY - 0.5)
		sc.pbus = me_place(s, fails, what, "me-export-bus", BX + 10.5, BY + 0.5, SOUTH)
		sc.pchest = me_place(s, fails, what, "iron-chest", BX + 10.5, BY + 1.5)
		sc.fbus = me_place(s, fails, what, "me-export-bus", BX + 12.5, BY + 0.5, SOUTH)
		sc.fchest = me_place(s, fails, what, "iron-chest", BX + 12.5, BY + 1.5)
		me_connect(fails, what, { sc.ctrl, sc.drive, sc.term, sc.pbus, sc.fbus })
		if sc.drive then
			local inv = game.create_inventory(1)
			inv[1].set_stack{ name = "me-16k-storage-cell", count = 1 }
			remote.call(NET, "insert_cell", sc.drive, inv[1], 1)
			inv.destroy()
		end
		storage.fuzzydata493_scene = sc
		return fails
	end

	local function inv_of(e) return e.get_inventory(defines.inventory.chest) end
	--- write the stack of WANT row `w` into an empty LuaItemStack
	local function make(stack, w)
		stack.set_stack{ name = w.name, count = w.n, health = w.health }
		if w.kills then stack.tags = { kills = w.kills } end
		if w.desc then stack.custom_description = w.desc end
		if w.label then stack.label = w.label end
	end
	--- the one WANT row a stack matches (item, count, health, kills, label, description)
	local function match(st)
		if not st.valid_for_read then return nil end
		local tagged = st.name == ITEM
		local kills = tagged and next(st.tags) and st.tags.kills or nil
		local desc = tagged and st.custom_description or nil
		if desc == "" then desc = nil end
		local label = tagged and st.label or nil
		for i, w in ipairs(WANT) do
			if st.name == w.name and st.count == w.n and math.abs(st.health - w.health) < EPS and kills == w.kills
				and desc == w.desc and label == w.label then return i end
		end
		return nil
	end
	local function show(st)
		if not st.valid_for_read then return "nothing" end
		local tagged = st.name == ITEM
		return serpent.line({ name = st.name, count = st.count, health = st.health, tags = tagged and st.tags or nil,
			label = tagged and st.label or nil, description = tagged and st.custom_description or nil })
	end
	--- the stacks of an inventory: plain ones counted per item, the others listed
	local function census(inv)
		local c = { plain = {}, other = {} }
		for i = 1, #inv do
			local st = inv[i]
			if st.valid_for_read then
				local tagged = st.name == ITEM
				if st.health >= 1 and not (tagged and (st.label or next(st.tags) or (st.custom_description or "") ~= "")) then
					c.plain[st.name] = (c.plain[st.name] or 0) + st.count
				else c.other[#c.other + 1] = st end
			end
		end
		return c
	end
	--- the network's keys of the two items: plain count per item, keys with data
	local function keys_of(e)
		local plain, data = {}, {}
		for key, n in pairs(remote.call(NET, "contents", e)) do
			local name = key:match("^([^@#]*)")
			if name == ITEM or name == WALL then
				if key:find("#", 1, true) then data[#data + 1] = key .. " = " .. n
				else plain[name] = (plain[name] or 0) + n end
			end
		end
		table.sort(data)
		return plain, data
	end

	function T.tick()
		local tick = game.tick
		local sc = storage.fuzzydata493_scene
		local st = storage.fuzzydata493
		if not st then
			if tick < START or not sc then return end
			st = { problems = {}, done = false }
			storage.fuzzydata493 = st
			for _, e in pairs(sc) do
				if not (e and e.valid) then
					st.problems[#st.problems + 1] = "the test network was not built"
					st.done = true
					return me_report("FUZZYDATA", "ME fuzzy export of items with data", st.problems, "no network")
				end
			end
			local problems = st.problems
			local tmp = game.create_inventory(#WANT + 2)
			for i, w in ipairs(WANT) do make(tmp[i], w) end
			tmp[#WANT + 1].set_stack{ name = ITEM, count = PLAIN_ITEM }
			tmp[#WANT + 2].set_stack{ name = WALL, count = PLAIN_WALL }
			for i = 1, #tmp do
				local n, why = remote.call(TERM, "store_stack", sc.term, tmp[i])
				if not (n and n > 0 and not tmp[i].valid_for_read) then
					problems[#problems + 1] = "the terminal did not store " .. (WANT[i] and WANT[i].what or "the plain stack " .. i) .. ": "
						.. tostring(n) .. ", " .. tostring(why)
				end
			end
			tmp.destroy()
			remote.call(IO, "set_bus_filters", sc.pbus, { ITEM, WALL })
			remote.call(IO, "set_bus_filters", sc.fbus, {})
			return
		end
		if st.done then return end
		local problems = st.problems
		local function expect(ok, text) if not ok then problems[#problems + 1] = text end end
		for _, e in pairs(sc) do
			if not (e and e.valid) then
				problems[#problems + 1] = "an entity of the test network is gone"
				st.done = true
				return me_report("FUZZYDATA", "ME fuzzy export of items with data", problems, "")
			end
		end
		if tick < CHECK1 then return end
		if not st.c1 then
			st.c1 = true
			--- the bus without a card: the plain ones only, the keys with data stay
			local pc = census(inv_of(sc.pchest))
			expect((pc.plain[ITEM] or 0) == PLAIN_ITEM and (pc.plain[WALL] or 0) == PLAIN_WALL and #pc.other == 0,
				"the bus without a Fuzzy Card moved " .. serpent.line(pc.plain) .. " plain and " .. #pc.other .. " other stacks, not "
				.. PLAIN_ITEM .. " " .. ITEM .. " and " .. PLAIN_WALL .. " " .. WALL .. " plain ones only")
			local plain, data = keys_of(sc.ctrl)
			expect(next(plain) == nil and #data == #WANT, "after the bus without a card the network holds " .. serpent.line(plain)
				.. " plain and " .. #data .. " keys with data, not none and " .. #WANT .. ": " .. serpent.line(data))
			--- the Fuzzy Card and the two filters into the second bus
			local inv = game.create_inventory(2)
			inv[1].set_stack{ name = FUZZY, count = 1 }
			local why = remote.call(IO, "bus_card_click", sc.fbus, 1, inv[1], inv, false)
			expect(why == nil and not inv[1].valid_for_read, "the Fuzzy Card did not go into the bus: " .. tostring(why))
			inv.destroy()
			remote.call(IO, "set_bus_filters", sc.fbus, { ITEM, WALL })
			return
		end
		if tick < CHECK2 then return end
		local fc = inv_of(sc.fchest)
		local seen = {}
		for i = 1, #fc do
			local s = fc[i]
			if s.valid_for_read then
				local row = match(s)
				if row and not seen[row] then seen[row] = true
				else expect(false, "the fuzzy bus's chest holds " .. show(s) .. ", no stack of the network") end
			end
		end
		for i, w in ipairs(WANT) do expect(seen[i], w.what .. " did not come out of the fuzzy bus with its count, health, tags, label and description") end
		local plain, data = keys_of(sc.ctrl)
		expect(next(plain) == nil and #data == 0, "after the fuzzy bus the network still holds " .. serpent.line(plain) .. " plain and "
			.. serpent.line(data))
		st.done = true
		me_report("FUZZYDATA", "ME fuzzy export of items with data", problems, "an export bus without a Fuzzy Card moves the plain stacks "
			.. "only; with the card it moves every key with data of its filters' items (a label with kills, damaged, kills alone, a "
			.. "damaged wall), each with its count, health, tags, label and description")
	end

	function T.running(check) check(storage.fuzzydata493 and storage.fuzzydata493.done, "ME fuzzy export of items with data") end
	return T
end
