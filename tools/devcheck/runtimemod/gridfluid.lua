--- Runtime test of me-network issue #261: fluid amounts of a processing pattern made from a recipe are clean numbers, and
--- a clean amount never makes a machine wait. The engine keeps fluid amounts on a grid of 2^-24 (Gregtorio rounds every
--- recipe's fluids up to it, its #117); runtimemod/data.lua has two recipes with water on that grid, as Gregtorio makes
--- them: ceil(14.4 * 2^24) / 2^24 (= 14.400000035762787) and ceil(0.1234564 * 2^24) / 2^24 (whose nearest 6 digits,
--- 0.123456, would be delivered short: it rounds up to 0.123457).
---   * "From recipe" in the pattern editor gives 14.4 and 0.123457; the rule over many values: an input's amount is
---     delivered at fixed_up of it, never less than the recipe's; an output's never more than the recipe gives;
---   * a job of each (one after the other: the network has one crafting CPU) runs in a machine next to a provider and is
---     done, every run started: the network gave fixed_up(14.4) and fixed_up(0.123457) per run.
--- Loaded by control.lua: require("gridfluid")(H) returns { setup, tick, running }.

local NET, AC, PT = "gregtorio-me-network", "gregtorio-me-autocraft", "gregtorio-me-pattern-terminal"
local BX, BY = -520, -420
local START, TIMEOUT = 150, 1500
local FIXED = 16777216
local function grid(a) return math.ceil(a * FIXED) / FIXED end
local RUNS_A, RUNS_B = 2, 3

return function(H)
	local me_place, me_report, power = H.me_place, H.me_report, H.power
	local T = {}

	function T.setup(s)
		local fails = {}
		local what = "fluid grid amounts"
		local tiles = {}                                         -- (land under the scene)
		for x = BX - 4, BX + 26 do
			for y = BY - 6, BY + 14 do tiles[#tiles + 1] = { name = "grass-1", position = { x, y } } end
		end
		s.set_tiles(tiles)
		power(s, fails, what, BX, BY)
		me_place(s, fails, what, "substation", BX + 14, BY + 6)
		local ctrl = me_place(s, fails, what, "me-network-controller", BX + 7, BY)
		local fdrive = H.me_drive(s, fails, what, BX + 8.5, BY - 0.5, {}, "16k", true)
		local cpu = place_cpu(s, fails, what, BX + 11, BY)
		local idrive = H.me_drive(s, fails, what, BX + 13.5, BY - 0.5, {})
		local term = me_place(s, fails, what, "me-terminal", BX + 12.5, BY - 2.5)
		local pa = me_place(s, fails, what, "me-pattern-provider", BX + 16.5, BY + 3.5)
		local ma = me_place(s, fails, what, "zz-devcheck-hot-machine", BX + 18.5, BY + 3.5)
		local pb = me_place(s, fails, what, "me-pattern-provider", BX + 16.5, BY + 8.5)
		local mb = me_place(s, fails, what, "zz-devcheck-hot-machine", BX + 18.5, BY + 8.5)
		if ma and mb then
			ma.set_recipe("zz-devcheck-grid-a")
			mb.set_recipe("zz-devcheck-grid-b")
		end
		H.me_connect(fails, what, { ctrl, fdrive, cpu, idrive, term, pa, pb })
		storage.gridfluid261_scene = { term = term, pa = pa, pb = pb, ma = ma, mb = mb }
		return fails
	end

	function T.tick()
		local tick = game.tick
		local st = storage.gridfluid261
		if not st then
			if tick < START then return end
			st = { problems = {}, done = false, phase = 0 }
			storage.gridfluid261 = st
		end
		if st.done then return end
		local problems = st.problems
		local function expect(ok, text) if not ok then problems[#problems + 1] = text end end
		local function finish(note)
			st.done = true
			me_report("GRIDFLUID", "ME pattern fluid amounts on the engine's grid", problems, note)
		end
		local sc = storage.gridfluid261_scene
		for k, e in pairs(sc or {}) do
			if not e.valid then
				expect(false, "the entities were not built (" .. k .. ")")
				return finish()
			end
		end
		local t = sc.term

		if st.phase == 0 then
			st.phase = 1
			--- the rule over many values (inputs never short, outputs never more, at most 6 significant digits)
			for i = 1, 400 do
				local a = grid(i * 0.0371 + (i % 7) * 13.31 + 1 / (i + 2))
				local up = remote.call(PT, "clean_amount", a, true)
				local down = remote.call(PT, "clean_amount", a, false)
				expect(grid(up) >= a and down <= a and tonumber(string.format("%.6g", up)) == up
					and tonumber(string.format("%.6g", down)) == down,
					"clean amount of " .. string.format("%.17g", a) .. ": input " .. string.format("%.17g", up) .. ", output "
					.. string.format("%.17g", down))
			end
			--- "From recipe" in the editor
			local force = t.force
			local function rows(recipe)
				local ed = remote.call(PT, "new_editor")
				ed.mode = "processing"
				local ok, why
				ok, why, ed = remote.call(PT, "set_editor_recipe", force, ed, recipe)
				expect(ok, "From recipe " .. recipe .. ": " .. tostring(why))
				return ed
			end
			local ea, eb = rows("zz-devcheck-grid-a"), rows("zz-devcheck-grid-b")
			expect(ea.inputs[1] and ea.inputs[1].amount == 14.4, "the input of 14.4 on the grid: " .. serpent.line(ea.inputs))
			expect(eb.inputs[1] and eb.inputs[1].amount == 0.123457, "the input of 0.1234564 on the grid: " .. serpent.line(eb.inputs))
			--- the patterns into the providers, water into the network, a job of each
			give_patterns(sc.pa, { { kind = "processing", inputs = ea.inputs, outputs = ea.outputs } }, problems)
			give_patterns(sc.pb, { { kind = "processing", inputs = eb.inputs, outputs = eb.outputs } }, problems)
			st.water = remote.call(NET, "insert_fluid", t, "water", 1000)
			expect(st.water == 1000, "water into the network: " .. tostring(st.water))
			if #problems > 0 then return finish() end
		end

		--- the jobs one after the other: start, wait until it ended
		local function over(j) return not j or j.status == "done" or j.status == "failed" or j.status == "cancelled" end
		for _, k in ipairs({ { "ja", "zz-devcheck-grid-token-a", RUNS_A, "ma" }, { "jb", "zz-devcheck-grid-token-b", RUNS_B, "mb" } }) do
			local field, item, runs, machine = k[1], k[2], k[3], k[4]
			if not st[field] then
				local id, why = remote.call(AC, "start", t, item, runs)
				expect(id, "the job for " .. item .. " did not start: " .. tostring(why))
				if not id then return finish() end
				st[field], st.started = id, tick
				return
			end
			local j = remote.call(AC, "job", st[field])
			if not over(j) then
				if tick - st.started > TIMEOUT then
					expect(false, "the job for " .. item .. " did not end in " .. TIMEOUT .. " ticks: " .. serpent.line(j and j.steps)
						.. "; the machine's water " .. serpent.line(sc[machine].fluidbox[1]))
					return finish()
				end
				return
			end
			if not st[field .. "_checked"] then
				st[field .. "_checked"] = true
				expect(j and j.status == "done", "the job for " .. item .. " ended as " .. tostring(j and j.status))
			end
		end
		expect(remote.call(NET, "count", t, "zz-devcheck-grid-token-a") == RUNS_A
			and remote.call(NET, "count", t, "zz-devcheck-grid-token-b") == RUNS_B, "tokens made: "
			.. remote.call(NET, "count", t, "zz-devcheck-grid-token-a") .. ", " .. remote.call(NET, "count", t, "zz-devcheck-grid-token-b"))
		local given = RUNS_A * grid(14.4) + RUNS_B * grid(0.123457)
		local water = remote.call(NET, "fluid_count", t, "water")
		expect(math.abs(1000 - given - water) < 1e-4, "water left: " .. string.format("%.9f", water) .. ", expected "
			.. string.format("%.9f", 1000 - given))
		finish(RUNS_A .. " runs of 14.4 and " .. RUNS_B .. " of 0.123457 water (recipes on the 2^-24 grid) done; 400 amounts rounded safely")
	end

	function T.running(check) check(storage.gridfluid261 and storage.gridfluid261.done, "ME pattern fluid amounts on the engine's grid") end
	return T
end
