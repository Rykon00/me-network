--- Runtime test of me-network issue #415: the crafting storage above 256k and the crafting accelerators (AE2-Unofficial's). One
--- network with plates and sticks, a pattern provider with an ME Molecular Assembler and the gear pattern, and two CPUs:
---   * A: a 1024k crafting storage and a 4x accelerator: 1 048 576 bytes, 4 co-processors, speed 5;
---   * B: a Singularity crafting storage and a 4096x accelerator: 2^53 bytes, 4096 co-processors, speed 4097; a job on it may hand
---     over at most the map setting "crafting operations per step" (1024) per step, not 6 * 4097, and it is crafted.
--- Loaded by control.lua: require("bigcpus")(H) returns { setup, tick, running }.

local NET, AC = "gregtorio-me-network", "gregtorio-me-autocraft"
local BX, BY = -150, 130              -- (inside the cleared test area, TEST_RADIUS of control.lua; clear of the other tests)
local START, TIMEOUT = 140, 1200
local GEAR, GEAR_RECIPE = "iron-gear-wheel", "iron-gear-crafting-table"

return function(H)
	local me_place, cable_row, power, me_report = H.me_place, H.cable_row, H.power, H.me_report
	local T = {}
	local function at(dx, dy) return { BX + dx + 0.5, BY + dy + 0.5 } end
	local function line(t) return serpent.line(t) end

	function T.setup(s)
		local fails = {}
		local what = "big CPUs"
		power(s, fails, what, BX, BY)
		power(s, fails, what, BX + 22, BY - 8)
		me_place(s, fails, what, "me-network-controller", BX + 7, BY)
		H.me_drive(s, fails, what, BX + 8.5, BY - 0.5, { ["iron-plate"] = 300, ["iron-stick"] = 600 })
		cable_row(s, fails, BX + 9, BX + 20, BY - 1)
		--- CPU A (tiles 10, 11 of row 0) and CPU B (tiles 13, 14), apart
		me_place(s, fails, what, "me-1024k-crafting-storage", BX + 10.5, BY + 0.5)
		me_place(s, fails, what, "me-crafting-accelerator-4x", BX + 11.5, BY + 0.5)
		me_place(s, fails, what, "me-singularity-crafting-storage", BX + 13.5, BY + 0.5)
		me_place(s, fails, what, "me-crafting-accelerator-4096x", BX + 14.5, BY + 0.5)
		me_place(s, fails, what, "me-pattern-provider", BX + 17.5, BY - 1.5)
		local m = me_place(s, fails, what, "me-molecular-assembler", BX + 17.5, BY - 2.5)
		if m then
			m.force.recipes[GEAR_RECIPE].enabled = true
			m.get_module_inventory().insert{ name = "me-acceleration-card", count = 5 }
		end
		local p = s.find_entity("me-pattern-provider", at(17, -2))
		if p then give_patterns(p, { { kind = "crafting", recipe = GEAR_RECIPE } }, fails) end
		return fails
	end

	function T.tick()
		local st = storage.bigcpus415
		if (st and st.done) or game.tick < START then return end
		local s = game.surfaces[1]
		local function find(name, dx, dy) return s.find_entity(name, at(dx, dy)) end
		if not st then
			st = { problems = {}, phase = "start" }
			storage.bigcpus415 = st
		end
		local problems = st.problems
		local function expect(ok, msg) if not ok then problems[#problems + 1] = msg end end
		local function finish()
			st.done = true
			me_report("BIGCPUS", "Crafting storage above 256k and the crafting accelerators", problems, "a 1024k storage and a 4x "
				.. "accelerator, a Singularity storage and a 4096x accelerator: bytes, co-processors, speed; a job on the fast CPU, its "
				.. "operations per step capped by the setting")
		end
		local a, b = find("me-1024k-crafting-storage", 10, 0), find("me-singularity-crafting-storage", 13, 0)
		local ctrl = find("me-network-controller", 6, -1) or s.find_entity("me-network-controller", { BX + 7, BY })
		if not (a and b and ctrl) then expect(false, "entities missing") return finish() end

		if st.phase == "start" then
			local ga, gb = remote.call(AC, "group_info", a) or {}, remote.call(AC, "group_info", b) or {}
			expect(ga.bytes == 1048576 and ga.coprocessors == 4 and ga.speed == 5, "CPU A: " .. line({ ga.bytes, ga.coprocessors, ga.speed,
				ga.status }))
			expect(gb.bytes == 2 ^ 53 and gb.coprocessors == 4096 and gb.speed == 4097, "CPU B: " .. line({ gb.bytes, gb.coprocessors,
				gb.speed, gb.status }))
			local id, why = remote.call(AC, "start", ctrl, GEAR, 60, nil, gb.id)
			expect(id ~= nil, "the job on CPU B did not start: " .. tostring(why))
			if not id then return finish() end
			local j = remote.call(AC, "job", id) or {}
			expect(j.group == gb.id, "the job runs on CPU B: " .. line({ j.group, gb.id }))
			expect(j.ops == 1024, "operations per step capped by the setting: " .. tostring(j.ops) .. " (6 * 4097 = 24582)")
			st.job, st.phase, st.tick = id, "job", game.tick
			return
		end

		if st.phase == "job" then
			local j = remote.call(AC, "job", st.job) or {}
			if j.status ~= "done" then
				if j.status == "failed" or j.status == "cancelled" or game.tick > st.tick + TIMEOUT then
					expect(false, "the job on CPU B: " .. line({ j.status, j.reason, j.done, j.total }))
					return finish()
				end
				return
			end
			expect(remote.call(NET, "count", ctrl, GEAR) == 60, "gears after the job: " .. remote.call(NET, "count", ctrl, GEAR))
			return finish()
		end
	end

	function T.running(check) check(storage.bigcpus415 and storage.bigcpus415.done, "Crafting storage above 256k and the accelerators") end

	return T
end
