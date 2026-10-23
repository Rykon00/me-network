--- Runtime test of me-network issue #418: job merging (AE2-Unofficial's; only a player's request into a player's job). One
--- network with plates and sticks, one 16k CPU, a pattern provider with an ME Molecular Assembler and the gear pattern:
---   * a player's job of 10 gears runs; the CPU list for 5 more marks that CPU as one that merges;
---   * a second player's request of 5 gears joins it: the same job, 15 gears, more runs; the network gave the ingredients;
---   * a request of automation (an owner) for 5 gears does not join (no free CPU: refused);
---   * the job ends with 15 gears in the network.
--- Loaded by control.lua: require("mergejob")(H) returns { setup, tick, running }.

local NET, AC = "gregtorio-me-network", "gregtorio-me-autocraft"
local BX, BY = -150, 250              -- (inside the cleared test area, TEST_RADIUS of control.lua; clear of the other tests)
local START, TIMEOUT = 140, 1200
local GEAR, GEAR_RECIPE = "iron-gear-wheel", "iron-gear-crafting-table"

return function(H)
	local me_place, cable_row, power, me_report = H.me_place, H.cable_row, H.power, H.me_report
	local T = {}
	local function at(dx, dy) return { BX + dx + 0.5, BY + dy + 0.5 } end
	local function line(t) return serpent.line(t) end

	function T.setup(s)
		local fails = {}
		local what = "job merging"
		power(s, fails, what, BX, BY)
		power(s, fails, what, BX + 22, BY - 8)
		me_place(s, fails, what, "me-network-controller", BX + 7, BY)
		H.me_drive(s, fails, what, BX + 8.5, BY - 0.5, { ["iron-plate"] = 100, ["iron-stick"] = 200 })
		cable_row(s, fails, BX + 9, BX + 20, BY - 1)
		me_place(s, fails, what, "me-16k-crafting-storage", BX + 12.5, BY + 0.5)
		me_place(s, fails, what, "me-pattern-provider", BX + 16.5, BY - 1.5)
		local m = me_place(s, fails, what, "me-molecular-assembler", BX + 16.5, BY - 2.5)
		if m then m.force.recipes[GEAR_RECIPE].enabled = true end
		local p = s.find_entity("me-pattern-provider", at(16, -2))
		if p then give_patterns(p, { { kind = "crafting", recipe = GEAR_RECIPE } }, fails) end
		return fails
	end

	function T.tick()
		local st = storage.mergejob418
		if (st and st.done) or game.tick < START then return end
		local s = game.surfaces[1]
		if not st then
			st = { problems = {}, phase = "start" }
			storage.mergejob418 = st
		end
		local problems = st.problems
		local function expect(ok, msg) if not ok then problems[#problems + 1] = msg end end
		local function finish()
			st.done = true
			me_report("MERGEJOB", "Crafting job merging", problems, "a player's request joins a player's job of the item (the "
				.. "same job, the amounts and runs add up, the CPU list says so), automation's request does not; the job crafts all")
		end
		local ctrl = s.find_entity("me-network-controller", { BX + 7, BY })
		if not ctrl then expect(false, "entities missing") return finish() end
		local function count(name) return remote.call(NET, "count", ctrl, name) end

		if st.phase == "start" then
			local id, why = remote.call(AC, "start", ctrl, GEAR, 10)
			expect(id ~= nil, "the first job: " .. tostring(why))
			if not id then return finish() end
			local j1 = remote.call(AC, "job", id) or {}
			local list = remote.call(AC, "cpu_list", ctrl, 100, nil, GEAR) or {}
			expect(list[1] and list[1].merge == true and list[1].free == false, "the busy CPU merges a player's request: " .. line(list))
			local plates = count("iron-plate")
			local id2, why2 = remote.call(AC, "start", ctrl, GEAR, 5)
			expect(id2 == id, "the second player's request joins the job: " .. line({ id, id2, why2 }))
			local j2 = remote.call(AC, "job", id) or {}
			expect(j2.amount == 15 and j2.total > (j1.total or 0), "the job's amount and runs: " .. line({ j1.amount, j1.total, j2.amount,
				j2.total }))
			expect(count("iron-plate") == plates - 5, "the merge took the 5 plates of its plan: " .. plates .. " -> " .. count("iron-plate"))
			local id3, why3 = remote.call(AC, "start", ctrl, GEAR, 5, ctrl.unit_number)
			expect(id3 == nil, "automation's request joined or started: " .. line({ id3, why3 }))
			st.job, st.phase, st.tick = id, "run", game.tick
			return
		end

		if st.phase == "run" then
			local j = remote.call(AC, "job", st.job) or {}
			if j.status ~= "done" then
				if j.status == "failed" or j.status == "cancelled" or game.tick > st.tick + TIMEOUT then
					expect(false, "the merged job: " .. line({ j.status, j.reason, j.done, j.total }))
					return finish()
				end
				return
			end
			expect(count(GEAR) == 15, "gears after the merged job: " .. count(GEAR))
			return finish()
		end
	end

	function T.running(check) check(storage.mergejob418 and storage.mergejob418.done, "Crafting job merging") end

	return T
end
