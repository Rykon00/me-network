--- Runtime test of me-network issue #351: the level maintainer's rows and "craft what the circuit asks". A network with
--- two Crafting CPUs and a provider (processing patterns stone -> pipe and stone -> iron stick, a chest next to it):
---   * row 1 pipe 50 with a batch of 20 and row 2 iron stick 30: both rows start a job (20 pipes, 30 sticks), the
---     maintainer's status is "running";
---   * the rows cleared and "craft what the circuit asks" on, a constant combinator with pipe = 40 on its red wire: a job
---     of 40 pipes, listed in the rows of the signals;
---   * a settings paste and blueprint tags carry the rows, the batch and the option; a tag of a save from before (no rows)
---     sets row 1;
---   * issue #378: five rows (rows 2 to 5 with their batches) and "craft what the circuit asks" through a real blueprint
---     round trip of the maintainer of no network.
--- Loaded by control.lua: require("maintrows")(H) returns { setup, tick, running }.

local AC, PT, CI = "gregtorio-me-autocraft", "gregtorio-me-pattern-terminal", "gregtorio-me-circuit"
local BX, BY = -120, -380               -- (inside the cleared test area, TEST_RADIUS of control.lua)
local START, TIMEOUT = 170, 900

return function(H)
	local me_place, me_report, power = H.me_place, H.me_report, H.power
	local T = {}

	function T.setup(s)
		local fails = {}
		local what = "level maintainer rows"
		power(s, fails, what, BX, BY)
		local ctrl = me_place(s, fails, what, "me-network-controller", BX + 7, BY)
		local drive = H.me_drive(s, fails, what, BX + 8.5, BY - 0.5, { stone = 500 }, "16k")
		local term = me_place(s, fails, what, "me-terminal", BX + 10.5, BY - 0.5)
		H.cable_row(s, fails, BX + 11, BX + 20, BY - 1)
		for _, x in ipairs({ 12.5, 15.5 }) do me_place(s, fails, what, "me-256k-crafting-storage", BX + x, BY - 1.5) end
		me_place(s, fails, what, "me-pattern-provider", BX + 13.5, BY + 0.5)
		me_place(s, fails, what, "iron-chest", BX + 13.5, BY + 1.5)
		me_place(s, fails, what, "me-level-maintainer", BX + 18.5, BY - 1.5)
		me_place(s, fails, what, "constant-combinator", BX + 18.5, BY - 3.5)
		me_place(s, fails, what, "me-level-maintainer", BX + 18.5, BY + 8.5)       -- (of no network: the settings checks)
		H.me_connect(fails, what, { ctrl, drive, term })
		return fails
	end

	local function report()
		local s = storage.maintrows351
		s.done = true
		for _, id in pairs(s.jobs or {}) do pcall(remote.call, AC, "cancel", id) end
		me_report("MAINTROWS", "ME level maintainer rows", s.problems,
			"two rows with a batch, craft what the circuit asks, paste and blueprint tags, five rows through a blueprint")
	end

	local function encode(p, out)
		local tmp = game.create_inventory(2)
		tmp.insert{ name = "me-blank-pattern", count = 1 }
		remote.call(PT, "encode_def", tmp, nil, { kind = "processing", inputs = { { key = "stone", amount = 1 } },
			outputs = { { key = out, amount = 1 } } })
		local ok = remote.call(AC, "insert_pattern", p, (tmp.find_item_stack("me-encoded-pattern"))) ~= nil
		tmp.destroy()
		return ok
	end

	function T.tick()
		local s = storage.maintrows351
		if game.tick < START or (s and s.done) then return end
		local surface = game.surfaces[1]
		local function find(name, x, y) return surface.find_entity(name, { BX + x, BY + y }) end
		local function expect(ok, text) if not ok then s.problems[#s.problems + 1] = text end end
		local function job(id) return id and remote.call(AC, "job", id) end
		if not s then
			s = { problems = {}, jobs = {} }
			storage.maintrows351 = s
			s.p, s.m = find("me-pattern-provider", 13.5, 0.5), find("me-level-maintainer", 18.5, -1.5)
			s.cc, s.lone = find("constant-combinator", 18.5, -3.5), find("me-level-maintainer", 18.5, 8.5)
			if not (s.p and s.m and s.cc and s.lone) then expect(false, "entities missing") return report() end
			expect(encode(s.p, "pipe") and encode(s.p, "iron-stick"), "the patterns")
			remote.call(CI, "set_maintainer", s.m, "pipe", 50, false, 1, 20)
			remote.call(CI, "set_maintainer", s.m, "iron-stick", 30, false, 2, 0)
			s.phase, s.since = 1, game.tick
			return
		end
		local late = game.tick > s.since + TIMEOUT
		local d = remote.call(CI, "get_maintainer", s.m)
		if s.phase == 1 then
			local r1, r2 = d.rows[1], d.rows[2]
			if not (r1 and r2 and r1.status == "running" and r2.status == "running") then
				if late then expect(false, "the rows did not start: " .. serpent.line({ r1 and r1.status, r2 and r2.status })) return report() end
				return
			end
			local j1, j2 = job(r1.job), job(r2.job)
			s.jobs = { r1.job, r2.job }
			expect(j1 and j1.item == "pipe" and j1.amount == 20, "row 1 with a batch of 20: " .. serpent.line(j1 and { j1.item, j1.amount }))
			expect(j2 and j2.item == "iron-stick" and j2.amount == 30, "row 2: " .. serpent.line(j2 and { j2.item, j2.amount }))
			expect(d.status == "running" and d.key == "pipe" and d.amount == 50, "the maintainer's own fields are row 1: "
				.. serpent.line({ d.status, d.key, d.amount }))
			--- the settings: paste, blueprint tags
			remote.call(CI, "set_circuit_all", s.m, true)
			remote.call(CI, "paste", s.m, s.lone)
			local l = remote.call(CI, "get_maintainer", s.lone)
			expect(l.rows[2] and l.rows[2].key == "iron-stick" and l.rows[2].amount == 30 and l.rows[1].batch == 20 and l.circuit_all,
				"a settings paste: " .. serpent.line(l.rows))
			remote.call(CI, "built", s.lone, { fork_me_maintainer = { key = "pipe", amount = 7, circuit = false } })
			l = remote.call(CI, "get_maintainer", s.lone)
			expect(l.key == "pipe" and l.amount == 7 and not (l.rows[2] and l.rows[2].key) and not l.circuit_all,
				"a tag of a save from before: " .. serpent.line({ l.key, l.amount, l.rows[2], l.circuit_all }))
			remote.call(CI, "built", s.lone, { fork_me_maintainer = { rows = { { key = "pipe", amount = 1 },
				{ key = "iron-stick", amount = 2, batch = 3 } }, circuit_all = true } })
			l = remote.call(CI, "get_maintainer", s.lone)
			expect(l.rows[2] and l.rows[2].batch == 3 and l.circuit_all, "blueprint tags with rows: " .. serpent.line(l.rows))
			--- issue #378: five rows, their batches and the option through a real blueprint round trip
			local set = { { "pipe", 10, false, 0 }, { "iron-stick", 20, false, 5 }, { "iron-plate", 30, false, 0 },
				{ "copper-plate", 40, true, 0 }, { "stone", 50, false, 7 } }
			for i, r in ipairs(set) do remote.call(CI, "set_maintainer", s.lone, r[1], r[2], r[3], i, r[4]) end
			remote.call(CI, "set_circuit_all", s.lone, true)
			local copy, why = H.blueprint_copy(s.lone, 12, 0)
			local c = copy and remote.call(CI, "get_maintainer", copy) or {}
			local got, same = {}, copy ~= nil and c.circuit_all == true
			for i, w in ipairs(set) do
				local row = (c.rows or {})[i] or {}
				got[i] = { row.key, row.amount, row.circuit, row.batch }
				if not (row.key == w[1] and row.amount == w[2] and row.circuit == w[3] and (row.batch or 0) == w[4]) then same = false end
			end
			expect(same, "a blueprint round trip with five rows: " .. serpent.line(got) .. ", circuit_all " .. tostring(c.circuit_all)
				.. (why and (" (" .. why .. ")") or ""))
			remote.call(CI, "set_circuit_all", s.lone, false)
			if copy then remote.call(CI, "set_circuit_all", copy, false) end
			--- craft what the circuit asks: the rows cleared, a combinator with pipe = 40
			remote.call(CI, "set_circuit_all", s.m, false)
			for _, id in pairs(s.jobs) do remote.call(AC, "cancel", id) end
			remote.call(CI, "set_maintainer", s.m, false, 0, false, 1, 0)
			remote.call(CI, "set_maintainer", s.m, false, 0, false, 2, 0)
			local cb = s.cc.get_or_create_control_behavior()
			local section = cb.get_section(1) or cb.add_section()
			section.set_slot(1, { value = { type = "item", name = "pipe", quality = "normal" }, min = 40 })
			local ok = s.cc.get_wire_connector(defines.wire_connector_id.circuit_red, true)
				.connect_to(s.m.get_wire_connector(defines.wire_connector_id.circuit_red, true))
			expect(ok, "the red wire")
			remote.call(CI, "set_circuit_all", s.m, true)
			s.phase, s.since = 2, game.tick
			return
		end
		if s.phase == 2 then
			local row
			for _, r in ipairs(d.crows or {}) do if r.key == "pipe" then row = r end end
			if not (row and row.status == "running" and row.job) then
				if late then expect(false, "craft what the circuit asks: " .. serpent.line({ d.status, d.crows })) return report() end
				return
			end
			local j = job(row.job)
			s.jobs = { row.job }
			expect(j and j.item == "pipe" and j.amount == 40 and row.target == 40, "a job of 40 pipes: " .. serpent.line(j and { j.item, j.amount }))
			return report()
		end
	end

	function T.running(check) check(storage.maintrows351 and storage.maintrows351.done, "ME level maintainer rows") end

	return T
end
