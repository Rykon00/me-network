--- Runtime test: a storage bus on a machine whose fluid boxes go away with its recipe (report on the mod portal: "Passed
--- index is out of range" in get_fluid_segment_id from the fluid side's visit, an error in on_tick on every visit).
--- One network, a storage bus facing an assembling machine 2 with a recipe that takes a fluid (the bus is on its fluid side):
---   * the recipe is cleared: the machine has fewer fluid boxes than the bus's box number. No error, neither from an insert
---     into the network before the bus's next visit nor from that visit (from the queue); the fluid is gone from the network
---     and the bus faces nothing;
---   * the recipe comes back with fluid in the box: the bus is on its fluid side again and the network sees the fluid.
--- Loaded by control.lua: require("busboxrange")(H) returns { setup, tick, running }.

local NET, SB = "gregtorio-me-network", "gregtorio-me-storagebus"
local BX, BY = -760, -330
local START, WAIT1, LAST = 200, 800, 1400                     -- (an idle bus is visited at its growing interval)
local AMOUNT = 50
local SOUTH = { direction = defines.direction.south }
local RECIPE = "concrete"

return function(H)
	local me_place, me_report, power = H.me_place, H.me_report, H.power
	local T = {}

	function T.setup(s)
		local fails = {}
		local what = "storage bus box range"
		local tiles = {}                                         -- (land under the scene)
		for x = BX - 4, BX + 20 do
			for y = BY - 6, BY + 10 do tiles[#tiles + 1] = { name = "grass-1", position = { x, y } } end
		end
		s.set_tiles(tiles)
		power(s, fails, what, BX, BY)
		local ctrl = me_place(s, fails, what, "me-network-controller", BX + 7, BY)
		local drive = H.me_drive(s, fails, what, BX + 8.5, BY - 0.5, {}, "16k", true)
		local bus = me_place(s, fails, what, "me-storage-bus", BX + 12.5, BY + 0.5, SOUTH)
		local machine = me_place(s, fails, what, "assembling-machine-2", BX + 12.5, BY + 2.5)
		if machine then
			machine.set_recipe(RECIPE)
			machine.set_fluid(1, { name = "water", amount = AMOUNT })
		end
		H.me_connect(fails, what, { ctrl, drive, bus })
		if drive then
			for slot = 1, 4 do remote.call(NET, "set_partition", drive, slot, { "fluid/steam" }) end
		end
		storage.busboxrange_scene = { bus = bus, machine = machine, drive = drive }
		return fails
	end

	function T.tick()
		local tick = game.tick
		local st = storage.busboxrange
		if not st then
			if tick < START then return end
			st = { problems = {}, done = false }
			storage.busboxrange = st
		end
		if st.done then return end
		local problems = st.problems
		local function expect(ok, what) if not ok then problems[#problems + 1] = what end end
		local sc = storage.busboxrange_scene or {}
		if not (sc.bus and sc.bus.valid and sc.machine and sc.machine.valid) then
			expect(false, "the scene is gone")
			st.done = true
			me_report("BUSBOXRANGE", "ME storage bus on a machine that loses its fluid boxes", problems)
			return
		end
		local function water() return remote.call(NET, "fluid_count", sc.bus, "water") end
		local function info() return remote.call(SB, "info", sc.bus) or {} end
		local function finish()
			st.done = true
			me_report("BUSBOXRANGE", "ME storage bus on a machine that loses its fluid boxes", problems)
		end
		st.phase = st.phase or 0
		if st.phase == 0 then
			st.phase = 1
			local i = info()
			expect(sc.machine.fluids_count >= 1, "the machine has no fluid box with its recipe")
			expect(i.side == "fluid", "the bus is not on its fluid side: " .. serpent.line(i))
			expect(math.abs(water() - AMOUNT) < 1, "the network does not see the water: " .. water())
			sc.machine.set_recipe(nil)
			expect(sc.machine.fluids_count == 0, "the machine kept its fluid boxes without a recipe (nothing tested): " .. sc.machine.fluids_count)
			--- the bus's handlers before its next visit: it cannot take the fluid, the cells take steam only
			expect(remote.call(NET, "insert_fluid", sc.bus, "water", 10) == 0, "water went into a machine without a recipe")
		elseif st.phase == 1 then
			local i = info()
			if i.side ~= "fluid" or tick >= WAIT1 then                -- (the visit that raised the error: from the fluid side's queue)
				st.phase = 2
				expect(i.side ~= "fluid", "the bus stayed on its fluid side: " .. serpent.line(i))
				expect(water() < 1, "the network still counts the water: " .. water())
				sc.machine.set_recipe(RECIPE)
				sc.machine.set_fluid(1, { name = "water", amount = AMOUNT })
			end
		elseif st.phase == 2 then
			local i = info()
			if (i.side == "fluid" and math.abs(water() - AMOUNT) < 1) or tick >= LAST then
				expect(i.side == "fluid", "the bus did not come back to its fluid side: " .. serpent.line(i))
				expect(math.abs(water() - AMOUNT) < 1, "the network does not see the water again: " .. water())
				finish()
			end
		end
	end

	function T.running(check) check(storage.busboxrange and storage.busboxrange.done, "ME storage bus on a machine that loses its fluid boxes") end

	return T
end
