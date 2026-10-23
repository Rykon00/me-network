--- Runtime test of me-network issue #481: a damaged item of the type item-with-tags (Quality Turrets Reworked makes every
--- turret one, and a turret mined while damaged keeps its health) is stored like a damaged plain item (issue #102): a key of
--- its own whose data holds its health and, when it has them, its tags and its own description. The item is
--- `zz-devcheck-tagged-wall` of data.lua (it places a copy of the stone wall, so a stack of it can be damaged).
--- * Network A (a drive with one cell, a terminal, an import bus, an export bus, an ME Interface without rows): the import
---   bus's chest holds a damaged untagged stack, a damaged stack with tags and a whole stack; the interface holds a damaged
---   stack with tags; the terminal stores a damaged untagged stack and a damaged stack with tags and a description of its
---   own. Each is a key of its own (the untagged one with the key a damaged plain item gets), the terminal's text names the
---   health below the stack's own description, and a damaged stack with a label is refused as `cannot-store-label`. The
---   export bus with the item as its filter moves the whole ones only.
--- * The cell of A goes into an ME IO Port of network B, which empties it: every damaged key comes out of B with its count,
---   its health, its tags and its description.
--- On main the damaged stacks with tags were refused as `cannot-store-damaged` ("tools, ammunition, repair packs") and stayed
--- in their chests. Loaded by control.lua: require("tagdamaged")(H) returns { setup, tick, running } like margin.lua.

local NET, TERM, IO, IOP, GUI = "gregtorio-me-network", "gregtorio-me-terminal", "gregtorio-me-io", "gregtorio-me-ioport", "gregtorio-me-gui"
local BX, BY = 380, 232                   -- (inside the cleared test area, TEST_RADIUS of control.lua; clear of tagitem.lua)
local START, CHECK1, CHECK2 = 100, 450, 900
local ITEM = "zz-devcheck-tagged-wall"
local EPS = 1e-3
local DAMAGE = "fork-me-net.damaged-item"

--- what network A must hold after the stores: count, health, kills (tags), own description, where it came from
local WANT = {
	{ n = 4, health = 0.3, what = "the import bus's damaged untagged stack" },
	{ n = 1, health = 0.6, kills = 9, what = "the import bus's damaged stack with tags" },
	{ n = 1, health = 0.7, kills = 11, what = "the interface's damaged stack with tags" },
	{ n = 3, health = 0.5, what = "the terminal's damaged untagged stack" },
	{ n = 2, health = 0.45, kills = 4, desc = "Veteran", what = "the terminal's damaged stack with tags and a description" },
}

return function(H)
	local me_place, me_report, power = H.me_place, H.me_report, H.power
	local T = {}
	local SOUTH = { direction = defines.direction.south }

	function T.setup(s)
		local fails = {}
		local what = "tagdamaged"
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
		--- network B: cells and an IO Port
		power(s, fails, what, BX, BY + 8)
		sc.ctrl_b = me_place(s, fails, what, "me-network-controller", BX + 7, BY + 8)
		sc.drive_b = me_drive(s, fails, what, BX + 8.5, BY + 7.5, {}, "4k")
		sc.port_b = me_place(s, fails, what, "me-io-port", BX + 10.5, BY + 7.5)
		me_connect(fails, what, { sc.ctrl_b, sc.drive_b, sc.port_b })
		storage.tagdamaged481_scene = sc
		return fails
	end

	local function inv_of(e) return e.get_inventory(defines.inventory.chest) end
	--- the items of the item in an inventory: whole (untagged and not damaged), damaged, tagged
	local function census(inv)
		local c = { whole = 0, damaged = 0, tagged = 0 }
		for i = 1, #inv do
			local st = inv[i]
			if st.valid_for_read and st.name == ITEM then
				if next(st.tags) or st.label then c.tagged = c.tagged + st.count
				elseif st.health < 1 then c.damaged = c.damaged + st.count
				else c.whole = c.whole + st.count end
			end
		end
		return c
	end
	--- the keys of the item with data in a network: { key, n } sorted by key
	local function data_keys(e)
		local out = {}
		for key, n in pairs(remote.call(NET, "contents", e)) do
			if key:find(ITEM .. "@normal#", 1, true) == 1 then out[#out + 1] = { key = key, n = n } end
		end
		table.sort(out, function(a, b) return a.key < b.key end)
		return out
	end
	--- does the localised string (or a nesting of them) hold the damage text of `pct` percent, and the text `own`?
	local function holds(desc, pct, own)
		local dmg, text = false, own == nil
		local function walk(d)
			if type(d) == "string" then
				if d == own then text = true end
			elseif type(d) == "table" then
				if d[1] == DAMAGE and d[2] == pct then dmg = true end
				for _, v in ipairs(d) do walk(v) end
			end
		end
		walk(desc)
		return dmg and text
	end
	--- the one WANT row a stack matches (count, health, kills, description)
	local function match(st, n)
		for i, w in ipairs(WANT) do
			local kills = next(st.tags) and st.tags.kills or nil
			local desc = st.custom_description
			if desc == "" then desc = nil end
			if n == w.n and math.abs(st.health - w.health) < EPS and kills == w.kills and desc == w.desc then return i end
		end
		return nil
	end

	function T.tick()
		local tick = game.tick
		local sc = storage.tagdamaged481_scene
		local st = storage.tagdamaged481
		if not st then
			if tick < START or not sc then return end
			st = { problems = {}, done = false }
			storage.tagdamaged481 = st
			for _, e in pairs(sc) do
				if not (e and e.valid) then
					st.problems[#st.problems + 1] = "the test networks were not built"
					st.done = true
					return me_report("TAGDAMAGED", "ME damaged items with tags", st.problems, "no network")
				end
			end
			remote.call(IO, "set_bus_filters", sc.ibus, {})                  -- (everything)
			remote.call(IO, "set_bus_filters", sc.ebus, { ITEM })
			local ic = inv_of(sc.ichest)
			ic[1].set_stack{ name = ITEM, count = 4, health = 0.3 }
			ic[2].set_stack{ name = ITEM, count = 1, health = 0.6 }
			ic[2].tags = { kills = 9 }
			ic[3].set_stack{ name = ITEM, count = 2 }
			local fi = inv_of(sc.iface)
			fi[1].set_stack{ name = ITEM, count = 1, health = 0.7 }
			fi[1].tags = { kills = 11 }
			--- the terminal's store (what a player's click with the stack in hand calls)
			local tmp = game.create_inventory(3)
			tmp[1].set_stack{ name = ITEM, count = 3, health = 0.5 }
			tmp[2].set_stack{ name = ITEM, count = 2, health = 0.45 }
			tmp[2].tags = { kills = 4 }
			tmp[2].custom_description = "Veteran"
			tmp[3].set_stack{ name = ITEM, count = 1, health = 0.5 }
			tmp[3].label = "veteran"
			local problems = st.problems
			for i = 1, 2 do
				local n, why = remote.call(TERM, "store_stack", sc.term, tmp[i])
				if not (n == WANT[3 + i].n and not tmp[i].valid_for_read) then
					problems[#problems + 1] = "the terminal did not store " .. WANT[3 + i].what .. ": " .. tostring(n) .. ", " .. tostring(why)
				end
			end
			local n3, why3 = remote.call(TERM, "store_stack", sc.term, tmp[3])
			if not (n3 == nil and why3 == "cannot-store-label" and tmp[3].valid_for_read and tmp[3].health == 0.5) then
				problems[#problems + 1] = "a damaged item with a label was not refused as cannot-store-label: " .. tostring(n3) .. ", " .. tostring(why3)
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
				return me_report("TAGDAMAGED", "ME damaged items with tags", problems, "")
			end
		end
		if tick < CHECK1 then return end
		if not st.c1 then
			st.c1 = true
			local ic, fi, ec = census(inv_of(sc.ichest)), census(inv_of(sc.iface)), census(inv_of(sc.echest))
			expect(ic.whole + ic.damaged + ic.tagged == 0, "the import bus left stacks in its chest: " .. serpent.line(ic))
			expect(fi.damaged + fi.tagged == 0, "the interface kept its damaged stack with tags: " .. serpent.line(fi))
			expect(ec.whole == 2 and ec.damaged == 0 and ec.tagged == 0, "the export bus moved " .. serpent.line(ec) .. ", not the 2 whole ones")
			expect(remote.call(NET, "count", sc.ctrl, ITEM) == 0, "network A still counts " .. remote.call(NET, "count", sc.ctrl, ITEM) .. " plain ones")
			local keys = data_keys(sc.ctrl)
			expect(#keys == #WANT, "network A holds " .. #keys .. " damaged keys of the item, not " .. #WANT .. ": " .. serpent.line(keys))
			--- the terminal's text of each key: its health, below the own description
			for _, k in ipairs(keys) do
				local data = helpers.json_to_table(k.key:sub(k.key:find("#", 1, true) + 1)) or {}
				local h = type(data.health) == "number" and data.health or nil
				local desc = remote.call(GUI, "key_description", k.key)
				local own = type(data.description) == "string" and data.description ~= "" and data.description or nil
				expect(h and holds(desc, math.floor(h * 100 + 0.5), own), "the terminal's text of " .. k.key .. ": " .. serpent.line(desc))
				if not (data.tags and next(data.tags)) then
					--- an untagged damaged one has the key a damaged plain item gets (issue #102): its health and the damage text
					expect(type(data.description) == "table" and data.description[1] == DAMAGE and data.tags == nil,
						"the damaged untagged key is not a damaged plain item's: " .. k.key)
				end
			end
			--- A's cell into B's IO Port
			local cinv = game.create_inventory(2)
			remote.call(NET, "take_cell", sc.drive, 1, cinv)
			expect(cinv[1].valid_for_read, "network A's cell did not come out of its drive")
			if cinv[1].valid_for_read then
				local why = remote.call(IOP, "cell_click", sc.port_b, 1, cinv[1], cinv, false)
				expect(why == nil, "the cell did not go into the IO Port: " .. tostring(why))
			end
			cinv.destroy()
			return
		end
		if tick < CHECK2 then return end
		local keys = data_keys(sc.ctrl_b)
		expect(#keys == #WANT, "network B holds " .. #keys .. " damaged keys of the item after the IO Port, not " .. #WANT .. ": " .. serpent.line(keys))
		local seen = {}
		for _, k in ipairs(keys) do
			local out = game.create_inventory(4)        -- (one inventory each: the game merges damaged stacks, averaging their health)
			local got = remote.call(NET, "extract_to", sc.ctrl_b, out, k.key, k.n)
			local b = out[1]
			local i = b.valid_for_read and got == k.n and match(b, got)
			if i then seen[i] = true
			else
				expect(false, k.key .. " came out as " .. tostring(got) .. ": " .. (b.valid_for_read and serpent.line({ count = b.count, health = b.health,
					tags = b.tags, description = b.custom_description }) or "nothing"))
			end
			out.destroy()
		end
		for i, w in ipairs(WANT) do expect(seen[i], w.what .. " did not come out with its count, health, tags and description") end
		st.done = true
		me_report("TAGDAMAGED", "ME damaged items with tags", problems, "damaged items with tags stored through the import bus, the interface and the "
			.. "terminal, untagged ones as damaged plain items, a label refused, the export bus moves whole ones only, an IO Port moves the keys, "
			.. "everything comes out with its health, tags and description")
	end

	function T.running(check) check(storage.tagdamaged481 and storage.tagdamaged481.done, "ME damaged items with tags") end
	return T
end
