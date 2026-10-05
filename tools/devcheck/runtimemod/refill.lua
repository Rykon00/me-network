--- Runtime test of me-network issue #67 (docs/AE2.md "ME Storage Bus"): a chest behind an idle storage bus that is refilled
--- is seen again within a few ticks after the network took its stack, not at the bus's next regular read.
--- * Bus A faces an infinity chest that holds exactly one stack of iron plates (it refills one tick after it was
---   emptied). After the bus has been idle for SETTLE ticks (its interval at the idle limit) the network takes the stack,
---   three times; each time the network must have the next stack within LATENCY ticks (the test runs every 10 ticks, so
---   that is the next check). Before #67 it took the bus's interval: up to the idle limit the first time, 30 ticks after.
--- * The map holds BUSES more storage buses (on chests, unconnected), so the idle limit of the item side is the real one
---   (the setting's 120 ticks: a list shorter than 64 buses caps it lower, `Sched.idle_limit`), not the 30 ticks of a
---   small map.
--- * Bus B faces a chest with three item types and nothing refills it. The bound: after the re-read that found nothing,
---   taking the next type out does not schedule another one; once a regular read finds something new (a plate put into the
---   chest by script), it does again.
--- Loaded by control.lua: require("refill")(H) returns { setup, tick, running } like margin.lua.

local NET, SB = "gregtorio-me-network", "gregtorio-me-storagebus"
local RX, RY = -300, 100
local START, DEADLINE = 120, 1350
local BUSES = 70
local PLATES = 100
local LATENCY = 10          -- ticks until the network has the next stack
local REREAD = 5            -- storagebus.lua: the re-read comes this many ticks after the take
local ROUNDS = 3
local SETTLE = 450          -- ticks the bus is left alone before the first take: it reads at its idle limit by then
local IDLE = 120            -- the setting's default; the 70 buses of the map make it the limit of the item side

return function(H)
	local me_place, me_report, power = H.me_place, H.me_report, H.power
	local T = {}
	local SOUTH = { direction = defines.direction.south }

	function T.setup(s)
		local fails = {}
		local what = "refill"
		power(s, fails, what, RX, RY)
		me_place(s, fails, what, "me-network-controller", RX + 7, RY)
		me_place(s, fails, what, "me-drive", RX + 8.5, RY - 0.5)              -- (the buses below touch it)
		me_place(s, fails, what, "me-storage-bus", RX + 8.5, RY + 0.5, SOUTH)   -- bus A
		me_place(s, fails, what, "infinity-chest", RX + 8.5, RY + 1.5)
		me_place(s, fails, what, "me-storage-bus", RX + 9.5, RY + 0.5, SOUTH)   -- bus B
		me_place(s, fails, what, "iron-chest", RX + 9.5, RY + 1.5)
		for i = 0, BUSES - 1 do                                              -- the rest of the item side's list
			me_place(s, fails, what, "me-storage-bus", RX + 20 + 2 * i, RY + 14.5, SOUTH)
			me_place(s, fails, what, "iron-chest", RX + 20 + 2 * i, RY + 15.5)
		end
		return fails
	end

	local function finish(st, tick, extra)
		st.done = true
		local rounds = {}
		for _, l in ipairs(st.lat) do rounds[#rounds + 1] = tostring(l) end
		me_report("REFILL", "ME storage bus refill", st.problems, "the infinity chest's next stack after " .. table.concat(rounds, ", ")
			.. " ticks (at most " .. LATENCY .. "); " .. (extra or ""))
	end

	function T.tick()
		local tick = game.tick
		local s = game.surfaces[1]
		local st = storage.refill67
		if not st then
			if tick < START then return end
			st = { problems = {}, done = false, lat = {}, phase = "wait", bphase = "wait" }
			storage.refill67 = st
			local chest = s.find_entity("infinity-chest", { RX + 8.5, RY + 1.5 })
			if chest then
				chest.remove_unfiltered_items = false
				chest.set_infinity_container_filter(1, { name = "iron-plate", count = PLATES, mode = "exactly" })
			end
			local b = s.find_entity("iron-chest", { RX + 9.5, RY + 1.5 })
			if b then
				for _, name in ipairs({ "copper-plate", "stone", "coal" }) do b.insert{ name = name, count = 100 } end
			end
		end
		if st.done then return end
		local problems = st.problems
		local function expect(ok, msg) if not ok then problems[#problems + 1] = msg end end
		local ctrl = s.find_entity("me-network-controller", { RX + 7, RY })
		local bus_a = s.find_entity("me-storage-bus", { RX + 8.5, RY + 0.5 })
		local bus_b = s.find_entity("me-storage-bus", { RX + 9.5, RY + 0.5 })
		local chest_b = s.find_entity("iron-chest", { RX + 9.5, RY + 1.5 })
		if not (ctrl and bus_a and bus_b and chest_b) then
			problems[#problems + 1] = "the test network was not built"
			return finish(st, tick)
		end
		local function count(name) return remote.call(NET, "count", ctrl, name) end
		local function take(name) return remote.call(NET, "extract", ctrl, name, PLATES) end
		if tick >= DEADLINE then
			problems[#problems + 1] = "the test did not finish: A " .. st.phase .. " after " .. #st.lat .. " rounds, B " .. st.bphase
				.. ", " .. count("iron-plate") .. " plates in the network"
			return finish(st, tick)
		end

		--- bus A: the infinity chest
		if st.phase == "wait" then
			if count("iron-plate") >= PLATES then st.seen, st.phase = tick, "settle" end
		elseif st.phase == "settle" then
			--- the bus found nothing new for a while: idle, at the idle limit, which is what a player meets
			if tick >= st.seen + SETTLE then
				local sch = remote.call(SB, "schedule", bus_a)
				expect(sch and sch.interval and sch.interval >= IDLE, "bus A is not idle at the limit before the first take: " .. serpent.line(sch))
				expect(take("iron-plate") == PLATES, "the first stack could not be taken")
				st.t0, st.phase = tick, "refill"
			end
		elseif st.phase == "refill" and count("iron-plate") >= PLATES then
			local lat = tick - st.t0
			st.lat[#st.lat + 1] = lat
			expect(lat <= LATENCY, "round " .. #st.lat .. ": the network had the next stack " .. lat .. " ticks after it took the last, not within " .. LATENCY)
			if #st.lat < ROUNDS then
				take("iron-plate")
				st.t0 = tick
			else
				st.phase = "done"
			end
		end

		--- bus B: nothing refills it
		local function due_after(now)
			local sch = remote.call(SB, "schedule", bus_b)
			return sch and sch.due, sch
		end
		if st.bphase == "wait" then
			if count("copper-plate") >= 100 and count("stone") >= 100 and count("coal") >= 100 then
				take("copper-plate")
				st.bt, st.bphase = tick, "emptied-once"
			end
		elseif st.bphase == "emptied-once" and tick >= st.bt + REREAD + 3 then
			--- the re-read has happened and found nothing: the next type that runs out schedules no other
			local sch = remote.call(SB, "schedule", bus_b)
			expect(count("copper-plate") == 0, "the copper plates were not taken out of bus B's snapshot")
			take("stone")
			local due = due_after(tick)
			expect(due == nil or due > tick + REREAD, "bus B was due at tick " .. tostring(due) .. " (now " .. tick
				.. ") after its second type ran out: a re-read after an empty one, the bound is missing")
			st.bphase = "refill-chest"
			chest_b.insert{ name = "copper-plate", count = 100 }
		elseif st.bphase == "refill-chest" and count("copper-plate") >= 100 then
			--- a regular read found something new: the next type that runs out is read again soon
			take("coal")
			local due = due_after(tick)
			expect(due == tick + REREAD, "bus B was due at tick " .. tostring(due) .. " (now " .. tick
				.. ") after its coal ran out following a regular read that found the copper: not " .. REREAD .. " ticks later")
			st.bphase = "done"
		end

		if st.phase == "done" and st.bphase == "done" then
			finish(st, tick, "bus B: a second re-read only after a regular read found something new")
		end
	end

	function T.running(check) check(storage.refill67 and storage.refill67.done, "ME storage bus refill") end
	return T
end
