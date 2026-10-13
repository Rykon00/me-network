--- Runtime test of me-network issue #353: the ME Storage, Conversion and Throughput Monitor. A network with 100 iron plates:
---   * the storage monitor set to iron plates shows 100; after the conversion monitor's steps 50 more come in and the step
---     (no explicit visit) shows the new amount within two seconds;
---   * the conversion monitor stores a stack shift-clicked into it (20 plates); Take gives nothing while it is unlocked, a
---     stack (the plate's stack size) once it is locked; a locked monitor keeps its resource;
---   * the throughput monitor's rate is positive after plates came in, in its unit;
---   * a settings paste and blueprint tags carry resource, lock and unit; an unknown resource is none.
--- Loaded by control.lua: require("monitors")(H) returns { setup, tick, running }.

local MON, NET = "gregtorio-me-monitor", "gregtorio-me-network"
local BX, BY = -40, -380                -- (inside the cleared test area, TEST_RADIUS of control.lua)
local START, TIMEOUT = 180, 400

return function(H)
	local me_place, me_report, power = H.me_place, H.me_report, H.power
	local T = {}

	function T.setup(s)
		local fails = {}
		local what = "monitors"
		power(s, fails, what, BX, BY)
		local ctrl = me_place(s, fails, what, "me-network-controller", BX + 7, BY)
		local drive = H.me_drive(s, fails, what, BX + 8.5, BY - 0.5, { ["iron-plate"] = 100 }, "16k")
		local term = me_place(s, fails, what, "me-terminal", BX + 10.5, BY - 0.5)
		H.cable_row(s, fails, BX + 11, BX + 18, BY - 1)
		me_place(s, fails, what, "me-storage-monitor", BX + 12.5, BY - 1.5)
		me_place(s, fails, what, "me-conversion-monitor", BX + 13.5, BY - 1.5)
		me_place(s, fails, what, "me-throughput-monitor", BX + 14.5, BY - 1.5)
		me_place(s, fails, what, "me-storage-monitor", BX + 12.5, BY + 8.5)        -- (of no network: the settings checks)
		H.me_connect(fails, what, { ctrl, drive, term })
		return fails
	end

	local function report()
		local s = storage.monitors353
		s.done = true
		if s.inv and s.inv.valid then s.inv.destroy() end
		me_report("MONITORS", "ME Storage, Conversion and Throughput Monitor", s.problems,
			"amount on the face, the step refreshes it, conversion store and take when locked, throughput rate, paste and tags")
	end

	function T.tick()
		local s = storage.monitors353
		if game.tick < START or (s and s.done) then return end
		local surface = game.surfaces[1]
		local function find(name, x, y) return surface.find_entity(name, { BX + x, BY + y }) end
		local function expect(ok, text) if not ok then s.problems[#s.problems + 1] = text end end
		if not s then
			s = { problems = {} }
			storage.monitors353 = s
			s.ctrl = find("me-network-controller", 7, 0)
			s.sm, s.cm, s.tm = find("me-storage-monitor", 12.5, -1.5), find("me-conversion-monitor", 13.5, -1.5),
				find("me-throughput-monitor", 14.5, -1.5)
			s.lone = find("me-storage-monitor", 12.5, 8.5)
			if not (s.ctrl and s.sm and s.cm and s.tm and s.lone) then expect(false, "entities missing") return report() end
			remote.call(MON, "set", s.sm, "iron-plate")
			local d = remote.call(MON, "get", s.sm)
			expect(d.amount == 100 and d.text == "100", "the storage monitor shows 100: " .. serpent.line({ d.amount, d.text }))
			--- the conversion monitor
			s.inv = game.create_inventory(4)
			s.inv.insert{ name = "iron-plate", count = 20 }
			remote.call(MON, "set", s.cm, "iron-plate")
			local why = remote.call(MON, "shift", s.cm, s.inv[1])
			expect(why == nil and s.inv.get_item_count("iron-plate") == 0, "a shift-clicked stack is stored: " .. tostring(why))
			expect(remote.call(MON, "get", s.cm).amount == 120, "120 in the network: " .. tostring(remote.call(MON, "get", s.cm).amount))
			expect(remote.call(MON, "take", s.cm, s.inv) == 0, "unlocked: Take gives nothing")
			remote.call(MON, "set", s.cm, nil, true)
			local stack = prototypes.item["iron-plate"].stack_size              -- (100 in the base game, 64 in Gregtorio)
			s.taken = remote.call(MON, "take", s.cm, s.inv)
			expect(s.taken == stack and s.inv.get_item_count("iron-plate") == stack,
				"locked: Take gives a stack: " .. s.inv.get_item_count("iron-plate") .. " of " .. stack)
			remote.call(MON, "set", s.cm, "copper-plate")
			expect(remote.call(MON, "get", s.cm).key == "iron-plate", "a locked monitor keeps its resource")
			--- the throughput monitor: a sample now, more plates, a sample a second later
			remote.call(MON, "set", s.tm, "iron-plate", nil, "minute")
			--- the settings
			remote.call(MON, "paste", s.cm, s.lone)
			local l = remote.call(MON, "get", s.lone)
			expect(l.key == "iron-plate" and l.locked, "a settings paste: " .. serpent.line(l))
			remote.call(MON, "built", s.lone, { fork_me_monitor = { key = "fluid/water", locked = false, unit = "hour" } })
			l = remote.call(MON, "get", s.lone)
			expect(l.key ~= nil and l.key:find("^fluid/water") and not l.locked, "blueprint tags: " .. serpent.line(l))
			remote.call(MON, "set", s.lone, "no-such-item", false)
			expect(remote.call(MON, "get", s.lone).key == nil, "an unknown resource is none")
			remote.call(NET, "insert", s.ctrl, "iron-plate", 50)
			s.phase, s.since = 1, game.tick
			return
		end
		local late = game.tick > s.since + TIMEOUT
		if s.phase == 1 then
			--- the step refreshes the face (no explicit visit), and the throughput monitor has two samples
			local d = remote.call(MON, "get", s.sm)
			if d.text ~= tostring(120 - (s.taken or 0) + 50) then           -- (100 + 20 stored - a stack taken + 50 in)
				if late then expect(false, "the step did not refresh the face: " .. serpent.line({ d.amount, d.text })) return report() end
				return
			end
			if game.tick < s.since + 130 then return end
			remote.call(MON, "visit", s.tm)
			local t = remote.call(MON, "get", s.tm)
			expect(t.rate and t.rate > 0 and t.unit == "minute" and t.text and t.text:find("/m"),
				"the throughput monitor's rate: " .. serpent.line({ t.rate, t.unit, t.text }))
			return report()
		end
	end

	function T.running(check) check(storage.monitors353 and storage.monitors353.done, "ME monitors") end

	return T
end
