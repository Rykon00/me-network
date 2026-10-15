--- Runtime test of me-network issue #382 (docs/AE2.md "ME Import Bus / ME Export Bus"): an ME Export Bus feeds a recipe
--- that needs more than a stack of an item per craft (data.lua: zz-devcheck-bulk, 200 parts that stack to 100).
--- * Machine A has the recipe and two export buses with the part as their filter (north and west): the machine crafts, and
---   what its input holds never goes past two crafts (400), however many buses feed it.
--- * Machine B has a recipe that needs 10 parts (and an item the network lacks, so it never starts) and one bus: it gets one
---   stack, as before.
--- * Nothing is lost or made: the network, the inputs and the crafts (finished and running) add up to what the drive got.
--- Loaded by control.lua: require("bulkexport")(H) returns { setup, tick, running } like lab.lua.

local NET, IO = "gregtorio-me-network", "gregtorio-me-io"
local BX, BY = -360, -60                -- (inside the cleared test area, TEST_RADIUS of control.lua; clear of the other tests)
local START, CHECK = 100, 1100
local PART, RECIPE, MACHINE = "zz-devcheck-bulk-part", "zz-devcheck-bulk", "zz-devcheck-bulk-machine"
local TOTAL, NEED = 3000, 200

return function(H)
	local me_place, me_report, power = H.me_place, H.me_report, H.power
	local T = {}
	local SOUTH, EAST = { direction = defines.direction.south }, { direction = defines.direction.east }

	function T.setup(s)
		local fails = {}
		local what = "bulk export"
		power(s, fails, what, BX, BY)
		local ctrl = me_place(s, fails, what, "me-network-controller", BX + 7, BY)
		local drive = H.me_drive(s, fails, what, BX + 8.5, BY - 0.5, { [PART] = TOTAL })
		local a = me_place(s, fails, what, MACHINE, BX + 12.5, BY + 4.5)
		local bus_n = me_place(s, fails, what, "me-export-bus", BX + 12.5, BY + 2.5, SOUTH)
		local bus_w = me_place(s, fails, what, "me-export-bus", BX + 10.5, BY + 4.5, EAST)
		local b = me_place(s, fails, what, MACHINE, BX + 18.5, BY + 4.5)
		local bus_b = me_place(s, fails, what, "me-export-bus", BX + 18.5, BY + 2.5, SOUTH)
		if a then a.set_recipe(RECIPE) end
		if b then b.set_recipe(RECIPE .. "-small") end
		H.me_connect(fails, what, { ctrl, drive, bus_n, bus_w, bus_b })
		return fails
	end

	function T.tick()
		local tick = game.tick
		local st = storage.bulk382
		if not st then
			if tick < START then return end
			local s = game.surfaces[1]
			st = { problems = {}, done = false, max = 0,
				a = s.find_entity(MACHINE, { BX + 12.5, BY + 4.5 }), b = s.find_entity(MACHINE, { BX + 18.5, BY + 4.5 }),
				ctrl = s.find_entity("me-network-controller", { BX + 7, BY }),
				buses = { s.find_entity("me-export-bus", { BX + 12.5, BY + 2.5 }), s.find_entity("me-export-bus", { BX + 10.5, BY + 4.5 }),
					s.find_entity("me-export-bus", { BX + 18.5, BY + 2.5 }) } }
			storage.bulk382 = st
			for _, bus in pairs(st.buses) do
				if bus and bus.valid then remote.call(IO, "set_bus_filters", bus, { PART }) end
			end
		end
		if st.done then return end
		local problems = st.problems
		local function expect(ok, what) if not ok then problems[#problems + 1] = what end end
		local ok = st.a and st.a.valid and st.b and st.b.valid and st.ctrl and st.ctrl.valid
		for i = 1, 3 do ok = ok and st.buses[i] and st.buses[i].valid end
		if not ok then
			st.done = true
			problems[#problems + 1] = "the test network was not built"
			return me_report("BULK", "ME Export Bus into a recipe of more than a stack", problems, "no network")
		end
		local function held(m) return m.get_inventory(defines.inventory.crafter_input).get_item_count(PART) end
		local h = held(st.a)
		if h > st.max then st.max = h end
		if tick < CHECK then return end
		st.done = true
		local stack = prototypes.item[PART].stack_size
		local net = remote.call(NET, "count", st.ctrl, PART)
		local crafts = st.a.products_finished + (st.a.is_crafting() and 1 or 0)
		expect(st.a.products_finished >= 1, "machine A crafted nothing: its input held at most " .. st.max .. " parts, the recipe needs " .. NEED)
		expect(st.max > stack, "machine A's input held at most " .. st.max .. " parts, not more than a stack (" .. stack .. ")")
		expect(st.max <= 2 * NEED, "machine A's input held " .. st.max .. " parts, more than two crafts (" .. 2 * NEED .. ") with two buses")
		expect(held(st.b) == stack, "machine B (a recipe of 10) holds " .. held(st.b) .. " parts, not a stack (" .. stack .. ")")
		local total = net + h + held(st.b) + NEED * crafts
		expect(total == TOTAL, "parts: the network " .. net .. " + machine A " .. h .. " + machine B " .. held(st.b) .. " + " .. crafts
			.. " crafts of " .. NEED .. " = " .. total .. ", not " .. TOTAL)
		me_report("BULK", "ME Export Bus into a recipe of more than a stack", problems, st.a.products_finished .. " crafts, the input held at most "
			.. st.max .. " (two crafts: " .. 2 * NEED .. "), a recipe of 10 parts a stack")
	end

	function T.running(check) check(storage.bulk382 and storage.bulk382.done, "ME Export Bus into a recipe of more than a stack") end
	return T
end
