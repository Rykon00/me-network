--- Runtime test of me-network issue #562: the Singularity cell for fluids. Two networks, each with a controller and a drive:
---   * its spec: one type, 2^26 + 4096 bytes, 8 units per byte, so 2^29 units of one fluid;
---   * in drive 1 it takes water up to exactly 2^29 units (more is refused), the network counts them, a second fluid is
---     refused; 1000 units out and 0.125 in: the count is exact to the engine's 2^-24 grid at that size;
---   * taken out of drive 1 into drive 2 (another network): the water goes with it in its tags;
---   * after the save and load of the save-and-load run (tick 700) the count is the same.
--- Loaded by control.lua: require("singfluid")(H) returns { setup, tick, running }.

local NET = "gregtorio-me-network"
local BX, BY = 380, 60                -- (inside the cleared test area, TEST_RADIUS of control.lua; clear of the other tests)
local START, AFTER = 130, 700
local CELL = "me-singularity-fluid-storage-cell"
local LIMIT = 2 ^ 29

return function(H)
	local me_place, me_report = H.me_place, H.me_report
	local T = {}

	function T.setup(s)
		local fails = {}
		local what = "fluid Singularity cell"
		H.power(s, fails, what, BX, BY)
		H.power(s, fails, what, BX, BY + 6)
		for i, y in ipairs({ BY, BY + 6 }) do
			local ctrl = me_place(s, fails, what, "me-network-controller", BX + 7, y)
			local drive = me_place(s, fails, what, "me-drive", BX + 8.5, y - 0.5)
			H.me_connect(fails, what .. " " .. i, { ctrl, drive })
		end
		return fails
	end

	function T.tick()
		local st = storage.singfluid562
		local tick = game.tick
		if tick < START or (st and st.done) then return end
		local s = game.surfaces[1]
		local c1, c2 = s.find_entity("me-network-controller", { BX + 7, BY }), s.find_entity("me-network-controller", { BX + 7, BY + 6 })
		local d1, d2 = s.find_entity("me-drive", { BX + 8.5, BY - 0.5 }), s.find_entity("me-drive", { BX + 8.5, BY + 5.5 })
		local function report()
			st.done = true
			me_report("SINGFLUID", "Singularity cell for fluids (issue #562)", st.problems, "2^29 units of one fluid, exact at that "
				.. "size, a second fluid refused, carried in its tags into another drive, the same after the save and load")
		end
		if not st then
			st = { problems = {} }
			storage.singfluid562 = st
		end
		local problems = st.problems
		local function expect(ok, msg) if not ok then problems[#problems + 1] = msg end end
		if not (c1 and c2 and d1 and d2) then expect(false, "entities missing") return report() end
		local function water(c) return remote.call(NET, "fluid_count", c, "water") end
		local function f(n) return string.format("%.4f", n) end

		if not st.want then
			local sp = (remote.call(NET, "cell_specs") or {})[CELL] or {}
			expect(sp.kind == "fluid" and sp.types == 1 and sp.per_type == 4096 and sp.bytes == 2 ^ 26 + 4096 and sp.per_byte == 8,
				"the spec: " .. serpent.line(sp))
			local inv = game.create_inventory(1)
			inv[1].set_stack{ name = CELL, count = 1 }
			remote.call(NET, "insert_cell", d1, inv[1], 1)
			local got = remote.call(NET, "insert_fluid", c1, "water", LIMIT + 5000)
			expect(got == LIMIT and water(c1) == LIMIT, "the cell took " .. f(got) .. " units of water, the network counts "
				.. f(water(c1)) .. "; its limit is " .. f(LIMIT))
			expect(remote.call(NET, "insert_fluid", c1, "crude-oil", 10) == 0, "a second fluid went into the cell")
			expect(remote.call(NET, "extract_fluid", c1, "water", 1000) == 1000, "1000 units of water did not come out")
			expect(remote.call(NET, "insert_fluid", c1, "water", 0.125) == 0.125, "0.125 units of water did not go in")
			local want = LIMIT - 1000 + 0.125
			expect(water(c1) == want, "the count after 1000 out and 0.125 in: " .. f(water(c1)) .. ", " .. f(want) .. " expected")
			--- into drive 2 of the other network
			local out = game.create_inventory(1)
			remote.call(NET, "take_cell", d1, 1, out[1])
			expect(out[1].valid_for_read and out[1].name == CELL and water(c1) == 0, "the cell came out of drive 1: " .. f(water(c1)))
			remote.call(NET, "insert_cell", d2, out[1], 1)
			expect(water(c2) == want, "drive 2 counts " .. f(water(c2)) .. " units, " .. f(want) .. " expected")
			out.destroy()
			inv.destroy()
			st.want = want
			return
		end
		if tick < AFTER then return end
		expect(water(c2) == st.want, "after the save and load: " .. f(water(c2)) .. " units, " .. f(st.want) .. " expected")
		return report()
	end

	function T.running(check) check(storage.singfluid562 and storage.singfluid562.done, "Singularity cell for fluids") end
	return T
end
