--- Runtime test of me-network issue #85 (docs/ME-REWORK.md "An import bus with only refused stacks"): an ME Import Bus that
--- finds only stacks the network refuses itself (a used science pack, a blueprint) is no bus facing a full network. It
--- moves nothing and is "empty" (probed at its idle limit), not parked for room that does not change a refusal, so whole
--- items that come into its chest are taken within the idle limit, not when something wakes the parked bus (at the latest its
--- fallback visit, 3600 ticks). On main both buses are parked ("net-full"), which is what the test checks.
--- * Bus A: its chest holds refused stacks only. After it has looked it is "empty", not parked; plates put into the chest
---   afterwards are in the network within LIMIT ticks.
--- * Bus B: its chest holds plates and the same refused stacks: the plates go in at once, the refused stacks stay, and the
---   bus is "empty" too (what it left is no rest to come back for).
--- Loaded by control.lua: require("refused")(H) returns { setup, tick, running } like margin.lua.

local NET, IO = "gregtorio-me-network", "gregtorio-me-io"
local BX, BY = 500, -260
local START, CHECK1, DEADLINE = 100, 400, 1300
local LIMIT = 400           -- ticks: the idle limit of the import buses (300 by default) and a margin
local PACK = "automation-science-pack"
local PLATES = 40         -- iron plates per chest: one stack in every game (Gregtorio's plates stack to 64)

return function(H)
	local me_place, me_report, power = H.me_place, H.me_report, H.power
	local T = {}
	local SOUTH = { direction = defines.direction.south }

	function T.setup(s)
		local fails = {}
		local what = "refused"
		power(s, fails, what, BX, BY)
		local ctrl = me_place(s, fails, what, "me-network-controller", BX + 7, BY)
		local drive = me_drive(s, fails, what, BX + 8.5, BY - 0.5, {})
		local bus_a = me_place(s, fails, what, "me-import-bus", BX + 10.5, BY + 0.5, SOUTH)
		me_place(s, fails, what, "iron-chest", BX + 10.5, BY + 1.5)
		local bus_b = me_place(s, fails, what, "me-import-bus", BX + 14.5, BY + 0.5, SOUTH)
		me_place(s, fails, what, "iron-chest", BX + 14.5, BY + 1.5)
		for x = 9.5, 14.5 do me_place(s, fails, what, "me-cable", BX + x, BY - 0.5) end      -- (above both buses too)
		me_connect(fails, what, { ctrl, drive, bus_a, bus_b })
		return fails
	end

	function T.tick()
		local tick = game.tick
		local st = storage.refused85
		local s = game.surfaces[1]
		if not st then
			if tick < START then return end
			st = { problems = {}, done = false }
			storage.refused85 = st
			local function refused(inv)
				inv[1].set_stack{ name = PACK, count = 5, durability = 0.5 }      -- a used pack: refused as damaged
				inv[2].set_stack{ name = "blueprint", count = 1 }
			end
			st.chest_a = s.find_entity("iron-chest", { BX + 10.5, BY + 1.5 })
			st.chest_b = s.find_entity("iron-chest", { BX + 14.5, BY + 1.5 })
			st.bus_a = s.find_entity("me-import-bus", { BX + 10.5, BY + 0.5 })
			st.bus_b = s.find_entity("me-import-bus", { BX + 14.5, BY + 0.5 })
			st.ctrl = s.find_entity("me-network-controller", { BX + 7, BY })
			if st.chest_a and st.chest_b then
				refused(st.chest_a.get_inventory(defines.inventory.chest))
				refused(st.chest_b.get_inventory(defines.inventory.chest))
				st.chest_b.get_inventory(defines.inventory.chest)[3].set_stack{ name = "iron-plate", count = PLATES }
			end
			for _, bus in pairs({ st.bus_a, st.bus_b }) do
				if bus and bus.valid then remote.call(IO, "set_bus_filters", bus, {}) end        -- no filter: everything
			end
		end
		if st.done then return end
		local problems = st.problems
		local function expect(ok, what) if not ok then problems[#problems + 1] = what end end
		local ok = true
		for _, e in pairs({ st.chest_a, st.chest_b, st.bus_a, st.bus_b, st.ctrl }) do ok = ok and e and e.valid end
		if not ok then
			problems[#problems + 1] = "the test network was not built"
			st.done = true
			return me_report("REFUSED", "ME import bus with refused stacks", problems, "no network")
		end
		local function count(name) return remote.call(NET, "count", st.ctrl, name) end
		local function status(bus)
			local sch = remote.call(IO, "schedule", bus)
			return sch
		end
		if tick < CHECK1 then return end
		if not st.put then
			--- both buses have looked at their chests several times
			local a, b = status(st.bus_a), status(st.bus_b)
			expect(count("iron-plate") == PLATES, "bus B moved " .. count("iron-plate") .. " plates into the network, not " .. PLATES)
			expect(count(PACK) == 0, "the network took a used science pack")
			local inv_b = st.chest_b.get_inventory(defines.inventory.chest)
			expect(inv_b.get_item_count(PACK) == 5 and inv_b.get_item_count("blueprint") == 1,
				"the refused stacks did not stay in the chest of bus B")
			expect(a and a.parked == nil and a.block == "empty", "bus A (refused stacks only) is not empty and awake: " .. serpent.line(a))
			expect(b and b.parked == nil and b.block == "empty", "bus B (plates taken, refused stacks left) is not empty and awake: " .. serpent.line(b))
			--- whole items arrive in the chest of bus A
			st.chest_a.get_inventory(defines.inventory.chest)[3].set_stack{ name = "iron-plate", count = PLATES }
			st.put = tick
			return
		end
		if count("iron-plate") >= 2 * PLATES then
			local lat = tick - st.put
			expect(lat <= LIMIT, "the plates in the chest of bus A were taken after " .. lat .. " ticks, not within " .. LIMIT)
			st.done = true
			return me_report("REFUSED", "ME import bus with refused stacks", problems, "refused stacks do not park the bus: bus A took the plates that arrived "
				.. lat .. " ticks later (at most " .. LIMIT .. "), bus B took its plates at once and left the refused stacks")
		end
		if tick >= DEADLINE then
			problems[#problems + 1] = "the plates in the chest of bus A were not taken within " .. (DEADLINE - st.put) .. " ticks: " .. serpent.line(status(st.bus_a))
			st.done = true
			me_report("REFUSED", "ME import bus with refused stacks", problems, "")
		end
	end

	function T.running(check) check(storage.refused85 and storage.refused85.done, "ME import bus with refused stacks") end
	return T
end
