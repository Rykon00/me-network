--- Runtime test of me-network issue #441: the Creative ME Storage Cell. A network whose only drive holds a creative cell that
--- lists iron plates, an export bus on chest A (filter iron plate) and an import bus on chest B:
---   * the network counts 2^50 iron plates; taking a million leaves the count as it was; storing 500 is taken (destroyed), the
---     count stays; a copper plate is not taken (the cell lists only iron);
---   * the export bus fills chest A from it, visit after visit, and the count stays; the import bus empties chest B's iron;
---   * a creative cell without a list counts nothing and takes nothing; the ME IO Port refuses it.
--- Loaded by control.lua: require("creativecell")(H) returns { setup, tick, running }.

local NET, IO, IOP = "gregtorio-me-network", "gregtorio-me-io", "gregtorio-me-ioport"
local BX, BY = -60, 330               -- (inside the cleared test area, TEST_RADIUS of control.lua; clear of the other tests)
local START = 180
local CELL = "me-creative-storage-cell"
local BIG = 2 ^ 50

return function(H)
	local me_place, me_report, power = H.me_place, H.me_report, H.power
	local T = {}

	function T.setup(s)
		local fails = {}
		local what = "creative cell"
		power(s, fails, what, BX, BY)
		local ctrl = me_place(s, fails, what, "me-network-controller", BX + 7, BY)
		local drive = me_place(s, fails, what, "me-drive", BX + 8.5, BY - 0.5)
		H.cable_row(s, fails, BX + 9, BX + 14, BY - 1)
		me_place(s, fails, what, "me-export-bus", BX + 10.5, BY - 1.5, { direction = defines.direction.north })
		me_place(s, fails, what, "iron-chest", BX + 10.5, BY - 2.5)
		me_place(s, fails, what, "me-import-bus", BX + 12.5, BY - 1.5, { direction = defines.direction.north })
		me_place(s, fails, what, "iron-chest", BX + 12.5, BY - 2.5)
		if drive then
			local inv = game.create_inventory(1)
			inv[1].set_stack{ name = CELL, count = 1, tags = { fork_me_cell = { partition = { ["iron-plate"] = true } } } }
			remote.call(NET, "insert_cell", drive, inv[1], 1)
			inv[1].set_stack{ name = CELL, count = 1 }
			remote.call(NET, "insert_cell", drive, inv[1], 2)
			inv.destroy()
		end
		H.me_connect(fails, what, { ctrl, drive })
		return fails
	end

	function T.tick()
		local st = storage.creativecell441
		if game.tick < START or (st and st.done) then return end
		local s = game.surfaces[1]
		local function find(name, x, y) return s.find_entity(name, { BX + x, BY + y }) end
		local function expect(ok, msg) if not ok then st.problems[#st.problems + 1] = msg end end
		local function report()
			st.done = true
			me_report("CREATIVECELL", "Creative ME Storage Cell", st.problems, "counts 2^50 of its list, gives and takes without end, "
				.. "nothing else; the export bus fills from it, the import bus empties into it; no list: nothing; no IO port")
		end
		local ctrl, drive, E, I, A, B = find("me-network-controller", 7, 0), find("me-drive", 8.5, -0.5), find("me-export-bus", 10.5, -1.5),
			find("me-import-bus", 12.5, -1.5), find("iron-chest", 10.5, -2.5), find("iron-chest", 12.5, -2.5)
		if not st then
			st = { problems = {} }
			storage.creativecell441 = st
			if not (ctrl and drive and E and I and A and B) then expect(false, "entities missing") return report() end
			local function count(n) return remote.call(NET, "count", ctrl, n) end
			expect(count("iron-plate") == BIG, "the network counts 2^50 iron plates: " .. count("iron-plate"))
			expect(remote.call(NET, "extract", ctrl, "iron-plate", 1000000) == 1000000 and count("iron-plate") == BIG,
				"a million taken, the count stays: " .. count("iron-plate"))
			expect(remote.call(NET, "insert", ctrl, "iron-plate", 500) == 500 and count("iron-plate") == BIG,
				"500 stored (destroyed), the count stays: " .. count("iron-plate"))
			expect(remote.call(NET, "insert", ctrl, "copper-plate", 5) == 0 and count("copper-plate") == 0,
				"a copper plate is not taken: " .. count("copper-plate"))
			--- the cell without a list (slot 2): it holds and takes nothing; no cards; the IO port refuses it
			local d = remote.call(NET, "drive", drive) or {}
			expect(d[2] and next(d[2].items) == nil, "a creative cell without a list holds nothing: " .. serpent.line(d[2] and d[2].items))
			local inv = game.create_inventory(2)
			inv[1].set_stack{ name = CELL, count = 1, tags = { fork_me_cell = { partition = { ["stone"] = true } } } }
			local port = s.create_entity{ name = "me-io-port", position = { BX + 20.5, BY + 4.5 }, force = "player" }
			if port then
				local why = remote.call(IOP, "cell_click", port, 1, inv[1], inv, false)
				expect(why ~= nil and inv[1].valid_for_read, "the ME IO Port refuses it: " .. tostring(why))
				port.destroy()
			end
			inv.destroy()
			--- the buses
			remote.call(IO, "set_bus_filters", E, { "iron-plate" })
			B.insert{ name = "iron-plate", count = 100 }
			remote.call(IO, "set_bus_filters", I, { "iron-plate" })
			for _ = 1, 3 do
				remote.call(IO, "step", E)
				remote.call(IO, "step", I)
			end
			local a = A.get_inventory(defines.inventory.chest).get_item_count("iron-plate")
			local b = B.get_inventory(defines.inventory.chest).get_item_count("iron-plate")
			expect(a >= 150 and count("iron-plate") == BIG, "the export bus fills from it: " .. a .. ", count " .. count("iron-plate"))
			expect(b < 100 and count("iron-plate") == BIG, "the import bus empties into it: " .. b .. " left, count " .. count("iron-plate"))
			return report()
		end
	end

	function T.running(check) check(storage.creativecell441 and storage.creativecell441.done, "Creative ME Storage Cell") end

	return T
end
