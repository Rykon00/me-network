--- Runtime test of me-network issue #485: an item with tags that carries a label (Quality Turrets Reworked labels a turret
--- mined with kills "<name> (N Kills)", beside its tags and its description) is stored with its label: a key of its own whose
--- data holds the label, and every path that hands the key out puts the label back. The item is `zz-devcheck-tagged-wall` of
--- data.lua (it places a copy of the stone wall, so a stack of it can be damaged).
--- * Network A (a drive with one cell, a terminal, an import bus, an export bus, an ME Interface without rows): the terminal
---   stores a stack with tags, a label and a description and the same stack damaged; the import bus takes one that differs
---   from the first in its label only, a damaged one of other kills and one with a label alone; the interface holds one more.
---   Each is a key of its own, the terminal's text names the label, the terminal takes two of them out (into the hand, and
---   into an inventory that holds an unlabelled stack of the same tags: no merge) and stores them again. The export bus with
---   the item as its filter moves the plain ones only, and they do not merge into the labelled stack in its chest.
--- * The cell of A comes out of its drive (its contents in the cell's tags, with the labels) and goes back in; then it goes
---   into an ME IO Port of network B, which empties it: every key comes out of B (into an inventory, a chest entity and an
---   empty stack) with its label, tags, description and health.
--- On main every stack with a label is refused as `cannot-store-label` and stays where it is. Loaded by control.lua:
--- require("taglabel")(H) returns { setup, tick, running } like margin.lua.

local NET, TERM, IO, IOP, GUI = "gregtorio-me-network", "gregtorio-me-terminal", "gregtorio-me-io", "gregtorio-me-ioport", "gregtorio-me-gui"
local BX, BY = 380, 300                   -- (inside the cleared test area, TEST_RADIUS of control.lua; clear of tagcraft.lua)
local START, CHECK1, CHECK2 = 100, 450, 900
local ITEM = "zz-devcheck-tagged-wall"
local EPS = 1e-3

--- what network A must hold after the stores: count, health, kills (tags), label, own description, the path it went in by
local WANT = {
	{ n = 1, health = 1, kills = 5, label = "Wall (5 Kills)", desc = "Kills: 5", what = "the terminal's stack with a label" },
	{ n = 2, health = 0.4, kills = 5, label = "Wall (5 Kills)", desc = "Kills: 5", what = "the terminal's damaged stack with a label" },
	{ n = 1, health = 1, kills = 5, label = "Wall (5 Kills) renamed", desc = "Kills: 5", what = "the import bus's stack of another label" },
	{ n = 1, health = 0.6, kills = 7, label = "Wall (7 Kills)", desc = "Kills: 7", what = "the import bus's damaged stack with a label" },
	{ n = 2, health = 1, label = "named", what = "the import bus's stack with a label alone" },
	{ n = 1, health = 1, kills = 9, label = "Wall (9 Kills)", desc = "Kills: 9", what = "the interface's stack with a label" },
}

return function(H)
	local me_place, me_report, power = H.me_place, H.me_report, H.power
	local T = {}
	local SOUTH = { direction = defines.direction.south }

	function T.setup(s)
		local fails = {}
		local what = "taglabel"
		local sc = {}
		--- network A
		power(s, fails, what, BX, BY)
		sc.ctrl = me_place(s, fails, what, "me-network-controller", BX + 7, BY)
		sc.drive = me_place(s, fails, what, "me-drive", BX + 8.5, BY - 0.5)
		sc.term = me_place(s, fails, what, "me-terminal", BX + 9.5, BY - 0.5)
		sc.ibus = me_place(s, fails, what, "me-import-bus", BX + 10.5, BY + 0.5, SOUTH)
		sc.ichest = me_place(s, fails, what, "iron-chest", BX + 10.5, BY + 1.5)
		sc.ebus = me_place(s, fails, what, "me-export-bus", BX + 12.5, BY + 0.5, SOUTH)
		sc.echest = me_place(s, fails, what, "iron-chest", BX + 12.5, BY + 1.5)
		sc.iface = me_place(s, fails, what, "me-network-interface", BX + 14.5, BY - 0.5)
		me_connect(fails, what, { sc.ctrl, sc.drive, sc.term, sc.ibus, sc.ebus, sc.iface })
		if sc.drive then
			local inv = game.create_inventory(1)
			inv[1].set_stack{ name = "me-16k-storage-cell", count = 1 }
			remote.call(NET, "insert_cell", sc.drive, inv[1], 1)
			inv.destroy()
		end
		--- network B: cells and an IO Port; a chest to take into
		power(s, fails, what, BX, BY + 8)
		sc.ctrl_b = me_place(s, fails, what, "me-network-controller", BX + 7, BY + 8)
		sc.drive_b = me_drive(s, fails, what, BX + 8.5, BY + 7.5, {}, "4k")
		sc.port_b = me_place(s, fails, what, "me-io-port", BX + 10.5, BY + 7.5)
		sc.chest_b = me_place(s, fails, what, "iron-chest", BX + 14.5, BY + 9.5)
		me_connect(fails, what, { sc.ctrl_b, sc.drive_b, sc.port_b })
		storage.taglabel485_scene = sc
		return fails
	end

	local function inv_of(e) return e.get_inventory(defines.inventory.chest) end
	--- write the stack of WANT row `w` (or `n` of it) into an empty LuaItemStack
	local function make(stack, w, n)
		stack.set_stack{ name = ITEM, count = n or w.n, health = w.health }
		if w.kills then stack.tags = { kills = w.kills } end
		if w.desc then stack.custom_description = w.desc end
		stack.label = w.label
	end
	--- the one WANT row a stack matches (count, health, kills, label, description)
	local function match(st, n)
		if not (st.valid_for_read and st.name == ITEM) then return nil end
		local kills = next(st.tags) and st.tags.kills or nil
		local desc = st.custom_description
		if desc == "" then desc = nil end
		for i, w in ipairs(WANT) do
			if n == w.n and math.abs(st.health - w.health) < EPS and kills == w.kills and desc == w.desc and st.label == w.label then return i end
		end
		return nil
	end
	local function show(st)
		if not st.valid_for_read then return "nothing" end
		return serpent.line({ name = st.name, count = st.count, health = st.health, tags = st.tags, label = st.label,
			description = st.custom_description })
	end
	--- the items of the item in an inventory: plain (no tags, no label, whole), labelled, other
	local function census(inv)
		local c = { plain = 0, labelled = 0, other = 0 }
		for i = 1, #inv do
			local st = inv[i]
			if st.valid_for_read and st.name == ITEM then
				if st.label then c.labelled = c.labelled + st.count
				elseif next(st.tags) or st.health < 1 then c.other = c.other + st.count
				else c.plain = c.plain + st.count end
			end
		end
		return c
	end
	--- the keys of the item with data in a network: { key, n, data } sorted by key
	local function data_keys(e)
		local out = {}
		for key, n in pairs(remote.call(NET, "contents", e)) do
			if key:find(ITEM .. "@normal#", 1, true) == 1 then
				out[#out + 1] = { key = key, n = n, data = helpers.json_to_table(key:sub(key:find("#", 1, true) + 1)) or {} }
			end
		end
		table.sort(out, function(a, b) return a.key < b.key end)
		return out
	end
	--- the key of WANT row `i` among `keys` (by its data), or nil
	local function key_of_row(keys, i)
		local w = WANT[i]
		for _, k in ipairs(keys) do
			local d = k.data
			local kills = type(d.tags) == "table" and d.tags.kills or nil
			local h = type(d.health) == "number" and d.health or 1
			if d.label == w.label and kills == w.kills and math.abs(h - w.health) < EPS and k.n == w.n then return k end
		end
		return nil
	end
	--- does the localised string (or a nesting of them) hold the text `text`?
	local function holds(desc, text)
		if desc == text then return true end
		if type(desc) ~= "table" then return false end
		for _, v in ipairs(desc) do if holds(v, text) then return true end end
		return false
	end

	function T.tick()
		local tick = game.tick
		local sc = storage.taglabel485_scene
		local st = storage.taglabel485
		if not st then
			if tick < START or not sc then return end
			st = { problems = {}, done = false }
			storage.taglabel485 = st
			for _, e in pairs(sc) do
				if not (e and e.valid) then
					st.problems[#st.problems + 1] = "the test networks were not built"
					st.done = true
					return me_report("TAGLABEL", "ME items with a label", st.problems, "no network")
				end
			end
			local problems = st.problems
			remote.call(IO, "set_bus_filters", sc.ibus, {})                  -- (everything)
			remote.call(IO, "set_bus_filters", sc.ebus, { ITEM })
			local ic = inv_of(sc.ichest)
			make(ic[1], WANT[3])
			make(ic[2], WANT[4])
			make(ic[3], WANT[5])
			ic[4].set_stack{ name = ITEM, count = 3 }                         -- (plain ones, for the export bus)
			make(inv_of(sc.iface)[1], WANT[6])
			--- the export bus's chest holds a labelled stack of the item: the plain ones it gets must not merge into it
			make(inv_of(sc.echest)[1], { health = 1, kills = 1, label = "Wall (1 Kills)", desc = "Kills: 1" }, 1)
			--- the terminal's store (what a player's click with the stack in hand calls)
			local tmp = game.create_inventory(2)
			make(tmp[1], WANT[1])
			make(tmp[2], WANT[2])
			for i = 1, 2 do
				local n, why = remote.call(TERM, "store_stack", sc.term, tmp[i])
				if not (n == WANT[i].n and not tmp[i].valid_for_read) then
					problems[#problems + 1] = "the terminal did not store " .. WANT[i].what .. ": " .. tostring(n) .. ", " .. tostring(why)
				end
			end
			tmp.destroy()
			return
		end
		if st.done then return end
		local problems = st.problems
		local function expect(ok, text) if not ok then problems[#problems + 1] = text end end
		for _, e in pairs(sc) do
			if not (e and e.valid) then
				problems[#problems + 1] = "an entity of the test networks is gone"
				st.done = true
				return me_report("TAGLABEL", "ME items with a label", problems, "")
			end
		end
		if tick < CHECK1 then return end
		if not st.c1 then
			st.c1 = true
			local ic, fi, ec = census(inv_of(sc.ichest)), census(inv_of(sc.iface)), census(inv_of(sc.echest))
			expect(ic.plain + ic.labelled + ic.other == 0, "the import bus left stacks in its chest: " .. serpent.line(ic))
			expect(fi.labelled == 0, "the interface kept its stack with a label: " .. serpent.line(fi))
			expect(ec.plain == 3 and ec.labelled == 1 and ec.other == 0, "the export bus's chest holds " .. serpent.line(ec)
				.. ", not the 3 plain ones beside the labelled one")
			local e1 = inv_of(sc.echest)[1]
			expect(e1.valid_for_read and e1.count == 1 and e1.label == "Wall (1 Kills)", "the labelled stack in the export bus's chest: " .. show(e1))
			local keys = data_keys(sc.ctrl)
			expect(#keys == #WANT, "network A holds " .. #keys .. " keys of the item with data, not " .. #WANT .. ": " .. serpent.line(keys))
			for i, w in ipairs(WANT) do
				local k = key_of_row(keys, i)
				expect(k, "network A has no key for " .. w.what)
				--- the terminal's text of the key names its label
				if k then expect(holds(remote.call(GUI, "key_description", k.key), w.label), "the terminal's text of " .. k.key .. " does not name its label") end
			end
			--- the terminal's take: the first into the hand, the damaged one into an inventory with an unlabelled stack of its tags
			local hold, pinv = game.create_inventory(1), game.create_inventory(4)
			local k1, k2 = key_of_row(keys, 1), key_of_row(keys, 2)
			if k1 then
				local n = remote.call(TERM, "take", hold[1], pinv, sc.term, k1.key, "stack")
				expect(n == 1 and match(hold[1], 1) == 1, "the terminal's take into the hand: " .. tostring(n) .. ", " .. show(hold[1]))
				local back = remote.call(TERM, "store_stack", sc.term, hold[1])
				expect(back == 1, "the terminal did not store the stack with a label again: " .. tostring(back))
			end
			if k2 then
				--- one, then one more into the hand (the engine ignores a raised count on a stack with tags, a label or damage)
				local a = remote.call(TERM, "take", hold[1], pinv, sc.term, k2.key, "one")
				local b = remote.call(TERM, "take", hold[1], pinv, sc.term, k2.key, "one")
				expect(a == 1 and b == 1 and match(hold[1], 2) == 2, "the terminal's take of one and one more: " .. tostring(a) .. ", "
					.. tostring(b) .. ", " .. show(hold[1]))
				local back = remote.call(TERM, "store_stack", sc.term, hold[1])
				expect(back == 2 and not hold[1].valid_for_read, "the terminal did not store the 2 in the hand again: " .. tostring(back))
				pinv[1].set_stack{ name = ITEM, count = 1, health = 0.9 }
				pinv[1].tags = { kills = 5 }
				pinv[1].custom_description = "Kills: 5"
				local n = remote.call(TERM, "take", hold[1], pinv, sc.term, k2.key, "inventory")
				local at
				for i = 2, #pinv do if match(pinv[i], 2) == 2 then at = i end end
				expect(n == 2 and at and pinv[1].count == 1 and pinv[1].label == nil and math.abs(pinv[1].health - 0.9) < EPS,
					"the terminal's take into an inventory: " .. tostring(n) .. ", " .. show(pinv[1]) .. " / " .. show(pinv[2]))
				if at then
					local back = remote.call(TERM, "store_stack", sc.term, pinv[at])
					expect(back == 2, "the terminal did not store the damaged stack with a label again: " .. tostring(back))
				end
			end
			hold.destroy()
			pinv.destroy()
			--- A's cell out of its drive: its tags hold the labels; back in, the keys are A's again
			local cinv = game.create_inventory(2)
			remote.call(NET, "take_cell", sc.drive, 1, cinv)
			expect(cinv[1].valid_for_read, "network A's cell did not come out of its drive")
			if cinv[1].valid_for_read then
				local stored = cinv[1].tags and cinv[1].tags["fork_me_cell"]
				local labels = 0
				for _, d in pairs(type(stored) == "table" and stored.data or {}) do if type(d) == "table" and d.label then labels = labels + 1 end end
				expect(labels == #WANT, "the cell's tags hold " .. labels .. " keys with a label, not " .. #WANT)
				local slot = remote.call(NET, "insert_cell", sc.drive, cinv[1], 1)
				expect(slot == 1, "the cell did not go back into its drive: " .. tostring(slot))
				local again = data_keys(sc.ctrl)
				for i, w in ipairs(WANT) do expect(key_of_row(again, i), "network A lost " .. w.what .. " when its cell went out and back in") end
				remote.call(NET, "take_cell", sc.drive, 1, cinv)
				local why = remote.call(IOP, "cell_click", sc.port_b, 1, cinv[1], cinv, false)
				expect(why == nil, "the cell did not go into the IO Port: " .. tostring(why))
			end
			cinv.destroy()
			return
		end
		if tick < CHECK2 then return end
		local keys = data_keys(sc.ctrl_b)
		expect(#keys == #WANT, "network B holds " .. #keys .. " keys of the item with data after the IO Port, not " .. #WANT .. ": " .. serpent.line(keys))
		local seen = {}
		local chest = inv_of(sc.chest_b)
		chest.clear()
		for j, k in ipairs(keys) do
			--- in turn: into an inventory that holds an unlabelled stack of the item, into an empty stack, into a chest entity
			local how = j % 3
			local out = game.create_inventory(4)
			local got, b
			if how == 0 then
				out[1].set_stack{ name = ITEM, count = 1, tags = k.data.tags, health = k.data.health }
				got = remote.call(NET, "extract_to", sc.ctrl_b, out, k.key, k.n)
				b = out[2]
				expect(out[1].count == 1 and out[1].label == nil, k.key .. " merged into an unlabelled stack: " .. show(out[1]))
			elseif how == 1 then
				got = remote.call(NET, "extract_to", sc.ctrl_b, out[1], k.key, k.n)
				b = out[1]
			else
				chest.clear()
				got = remote.call(NET, "extract_to", sc.ctrl_b, sc.chest_b, k.key, k.n)
				b = chest[1]
			end
			local i = got == k.n and match(b, got)
			if i then seen[i] = true
			else expect(false, k.key .. " came out as " .. tostring(got) .. ": " .. show(b)) end
			out.destroy()
		end
		chest.clear()
		for i, w in ipairs(WANT) do expect(seen[i], w.what .. " did not come out with its count, health, tags, label and description") end
		st.done = true
		me_report("TAGLABEL", "ME items with a label", problems, "items with tags and a label stored through the terminal, the import bus and the "
			.. "interface as keys of their own (two labels: two keys), named by the terminal, taken out and stored again, kept in a cell's tags "
			.. "and moved by an IO Port, everything comes out with its label, health, tags and description")
	end

	function T.running(check) check(storage.taglabel485 and storage.taglabel485.done, "ME items with a label") end
	return T
end
