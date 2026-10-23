--- Runtime test of me-network issue #468: the light of a cell that takes no new type but has bytes left is orange ("high", as
--- AE2-Unofficial's status 3), not red. A network with a controller and an empty drive:
---   * an empty Singularity cell is "room"; with 1000 iron plates (its one type) it is "high", not "full";
---   * a 1k cell with all its 63 types is "high" while it has bytes left, "full" once they are used up;
---   * an empty 1k cell is "room";
---   * the drive's lights follow: variation (bay - 1) * 4 + 1 (room), 2 (high), 3 (full).
--- Loaded by control.lua: require("celllight")(H) returns { setup, tick, running }.

local NET = "gregtorio-me-network"
local BX, BY = -150, -190             -- (inside the cleared test area, TEST_RADIUS of control.lua; clear of the other tests)
local START = 120
local LIGHT = { room = 1, high = 2, full = 3 }

return function(H)
	local me_place, me_report, power = H.me_place, H.me_report, H.power
	local T = {}
	local function line(t) return serpent.line(t) end

	function T.setup(s)
		local fails = {}
		local what = "cell light"
		power(s, fails, what, BX, BY)
		local ctrl = me_place(s, fails, what, "me-network-controller", BX + 7, BY)
		local drive = me_place(s, fails, what, "me-drive", BX + 8.5, BY - 0.5)
		H.me_connect(fails, what, { ctrl, drive })
		return fails
	end

	function T.tick()
		local st = storage.celllight468
		if (st and st.done) or game.tick < START then return end
		st = { problems = {}, done = true }
		storage.celllight468 = st
		local problems = st.problems
		local function expect(ok, msg) if not ok then problems[#problems + 1] = msg end end
		local s = game.surfaces[1]
		local function report()
			me_report("CELLLIGHT", "Cell light with all types used (issue #468)", problems, "a Singularity cell of one type and a 1k "
				.. "cell of 63 types orange while bytes are left, red when none are; empty cells green; the drive's lights")
		end
		local drive = s.find_entity("me-drive", { BX + 8.5, BY - 0.5 })
		if not drive then expect(false, "entities missing") return report() end
		local inv = game.create_inventory(1)
		local function put(name, slot)
			inv[1].set_stack{ name = name, count = 1 }
			return remote.call(NET, "insert_cell", drive, inv[1], slot)
		end
		local function cell(slot) return (remote.call(NET, "drive", drive) or {})[slot] or {} end
		local function state(slot, want, what)
			local c = cell(slot)
			expect(c.state == want, what .. ": state " .. tostring(c.state) .. ", expected " .. want .. " ("
				.. line({ bytes = c.bytes, bytes_total = c.bytes_total, types = c.types, types_total = c.types_total }) .. ")")
			remote.call(NET, "slow_step")
			local l = (remote.call(NET, "drive_lights", drive) or {})[slot]
			local v = (slot - 1) * 4 + LIGHT[want]
			expect(l and l.light and l.light.variation == v, what .. ": light " .. line(l and l.light) .. ", expected variation " .. v)
		end

		--- bay 1: the Singularity cell (one type)
		put("me-singularity-storage-cell", 1)
		state(1, "room", "an empty Singularity cell")
		expect(remote.call(NET, "store_in_drive", drive, "iron-plate", 1000) == 1000, "1000 iron plates into the Singularity cell")
		state(1, "high", "a Singularity cell of iron plates")

		--- bay 2: a 1k cell with one item of each of 63 types (the Singularity cell takes no second type)
		put("me-1k-storage-cell", 2)
		local names = {}
		for name, p in pairs(prototypes.item) do
			if p.type == "item" and not p.hidden and not p.parameter and name ~= "iron-plate" and not name:find("^me%-") then
				names[#names + 1] = name
			end
		end
		table.sort(names)
		local types, last = 0, nil
		for _, name in ipairs(names) do
			if types >= 63 then break end
			if remote.call(NET, "store_in_drive", drive, name, 1) == 1 then types, last = types + 1, name end
		end
		expect(cell(2).types == 63, "the 1k cell's types: " .. tostring(cell(2).types))
		state(2, "high", "a 1k cell of 63 types with bytes left")
		--- its bytes used up with more of one of its types
		local got = remote.call(NET, "store_in_drive", drive, last, 1e6)
		expect(got > 0 and cell(2).bytes == cell(2).bytes_total, "the 1k cell filled up: " .. got .. ", " .. line(cell(2)))
		state(2, "full", "a 1k cell without bytes left")

		--- bay 3: an empty 1k cell
		put("me-1k-storage-cell", 3)
		state(3, "room", "an empty 1k cell")
		inv.destroy()
		report()
	end

	function T.running(check) check(storage.celllight468 and storage.celllight468.done, "Cell light with all types used") end

	return T
end
