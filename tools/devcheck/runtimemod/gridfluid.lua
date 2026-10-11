--- Runtime test of me-network issue #261: fluid amounts of a processing pattern made from a recipe are clean numbers, and
--- a clean amount never makes a machine wait. The engine keeps fluid amounts on a grid of 2^-24 (Gregtorio rounds every
--- recipe's fluids up to it, its #117); runtimemod/data.lua has two recipes with water on that grid, as Gregtorio makes
--- them: ceil(14.4 * 2^24) / 2^24 (= 14.400000035762787) and ceil(0.1234564 * 2^24) / 2^24 (no decimal of 6 digits lies on
--- its grid step: it stays as it is; 0.123457 would hand the machine a surplus each run, which stalled the job).
---   * "From recipe" in the pattern editor gives 14.4 and the exact second amount; the rule over many values: the clean
---     amount lies on the same grid step (a job hands out exactly what the machine needs), decimals of up to 6 digits
---     come back as themselves;
---   * a job of each runs in a machine next to a provider and is done: the network gave exactly the recipes' amounts per
---     run;
---   * issue #270: a pattern that asks for a little more (0.123457 for the recipe's 0.1234564) or much more (15 for 14.4)
---     than the machine takes: its job finishes every run too (the rest below one run in the machine was counted as an
---     unused run, the machine rejected, the job waited forever). The four jobs run at once on four crafting CPUs; the
---     network keeps everything the machines did not use.
--- Loaded by control.lua: require("gridfluid")(H) returns { setup, tick, running }.

local NET, AC, PT = "gregtorio-me-network", "gregtorio-me-autocraft", "gregtorio-me-pattern-terminal"
local BX, BY = -520, -420
local START, TIMEOUT = 150, 500
local FIXED = 16777216
local function grid(a) return math.ceil(a * FIXED) / FIXED end
--- the jobs: { recipe and token suffix, pattern amount of water (nil: from the recipe), runs, the recipe's amount }
local JOBS = {
	{ "a", nil, 2, 14.4 },
	{ "b", nil, 3, 0.1234564 },
	{ "c", 0.123457, 3, 0.1234564 },
	{ "d", 15, 3, 14.4 },
}

return function(H)
	local me_place, me_report, power = H.me_place, H.me_report, H.power
	local T = {}

	function T.setup(s)
		local fails = {}
		local what = "fluid grid amounts"
		local tiles = {}                                         -- (land under the scene)
		for x = BX - 4, BX + 26 do
			for y = BY - 6, BY + 24 do tiles[#tiles + 1] = { name = "grass-1", position = { x, y } } end
		end
		s.set_tiles(tiles)
		power(s, fails, what, BX, BY)
		me_place(s, fails, what, "substation", BX + 14, BY + 6)
		me_place(s, fails, what, "substation", BX + 14, BY + 17)
		local ctrl = me_place(s, fails, what, "me-network-controller", BX + 7, BY)
		local fdrive = H.me_drive(s, fails, what, BX + 8.5, BY - 0.5, {}, "16k", true)
		local cpu = place_cpu(s, fails, what, BX + 11, BY)
		local cpus = { cpu }
		for i = 1, 3 do cpus[#cpus + 1] = place_cpu(s, fails, what, BX + 11, BY + 3 * i) end
		local idrive = H.me_drive(s, fails, what, BX + 13.5, BY - 0.5, {})
		local term = me_place(s, fails, what, "me-terminal", BX + 12.5, BY - 2.5)
		local scene, members = { term = term }, { ctrl, fdrive, idrive, term }
		for _, c in pairs(cpus) do members[#members + 1] = c end
		for i, j in ipairs(JOBS) do
			local y = BY - 2 + 5 * i
			local p = me_place(s, fails, what, "me-pattern-provider", BX + 16.5, y + 0.5)
			local m = me_place(s, fails, what, "zz-devcheck-hot-machine", BX + 18.5, y + 0.5)
			if m then m.set_recipe("zz-devcheck-grid-" .. j[1]) end
			scene["p" .. j[1]], scene["m" .. j[1]] = p, m
			members[#members + 1] = p
		end
		H.me_connect(fails, what, members)
		storage.gridfluid261_scene = scene
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
			--- the rule over many values: on the same grid step; a decimal of up to 6 digits comes back as itself
			for i = 1, 400 do
				local a = grid(i * 0.0371 + (i % 7) * 13.31 + 1 / (i + 2))
				local r = remote.call(PT, "clean_amount", a)
				expect(grid(r) == a and (r == a or tonumber(string.format("%.6g", r)) == r),
					"clean amount of " .. string.format("%.17g", a) .. ": " .. string.format("%.17g", r))
				local d = tonumber(string.format("%.6g", (i * 7.919) % 5000 + 0.001))
				expect(remote.call(PT, "clean_amount", grid(d)) == d, "the decimal " .. d .. " on the grid came back as "
					.. string.format("%.17g", remote.call(PT, "clean_amount", grid(d))))
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
			--- the patterns into the providers (from the recipe, or with the job's own amount), water into the network
			for _, j in ipairs(JOBS) do
				local ed = rows("zz-devcheck-grid-" .. j[1])
				if j[1] == "a" then
					expect(ed.inputs[1] and ed.inputs[1].amount == 14.4, "the input of 14.4 on the grid: " .. serpent.line(ed.inputs))
				elseif j[1] == "b" then
					expect(ed.inputs[1] and ed.inputs[1].amount == grid(0.1234564), "the input of 0.1234564 on the grid stays: "
						.. serpent.line(ed.inputs))
				end
				if j[2] and ed.inputs[1] then ed.inputs[1].amount = j[2] end
				give_patterns(sc["p" .. j[1]], { { kind = "processing", inputs = ed.inputs, outputs = ed.outputs } }, problems)
			end
			st.water = remote.call(NET, "insert_fluid", t, "water", 1000)
			expect(st.water == 1000, "water into the network: " .. tostring(st.water))
			if #problems > 0 then return finish() end
			--- the jobs at once (four CPUs)
			st.jobs = {}
			for _, j in ipairs(JOBS) do
				local id, why = remote.call(AC, "start", t, "zz-devcheck-grid-token-" .. j[1], j[3])
				expect(id, "the job for token " .. j[1] .. " did not start: " .. tostring(why))
				st.jobs[j[1]] = id
			end
			if #problems > 0 then return finish() end
			st.started = tick
			return
		end

		--- wait until every job ended
		local function over(j) return not j or j.status == "done" or j.status == "failed" or j.status == "cancelled" end
		local all = true
		for _, j in ipairs(JOBS) do
			if not over(remote.call(AC, "job", st.jobs[j[1]])) then all = false end
		end
		if not all then
			if tick - st.started > TIMEOUT then
				for _, j in ipairs(JOBS) do
					local job = remote.call(AC, "job", st.jobs[j[1]])
					expect(over(job), "the job for token " .. j[1] .. " did not end in " .. TIMEOUT .. " ticks: " .. serpent.line(job)
						.. "; the machine's water " .. serpent.line(sc["m" .. j[1]].fluidbox[1]))
				end
				return finish()
			end
			return
		end
		local used = 0
		for _, j in ipairs(JOBS) do
			local job = remote.call(AC, "job", st.jobs[j[1]])
			expect(job and job.status == "done", "the job for token " .. j[1] .. " ended as " .. tostring(job and job.status))
			local n = remote.call(NET, "count", t, "zz-devcheck-grid-token-" .. j[1])
			expect(n == j[3], "tokens " .. j[1] .. " made: " .. n .. ", expected " .. j[3])
			used = used + n * grid(j[4])                 -- (what the machines took; the rest came back into the network)
		end
		local water = remote.call(NET, "fluid_count", t, "water")
		expect(math.abs(1000 - used - water) < 1e-4, "water left: " .. string.format("%.9f", water) .. ", expected "
			.. string.format("%.9f", 1000 - used))
		finish("four jobs done: patterns from recipes on the 2^-24 grid (14.4, the exact 0.1234564) and with a surplus (0.123457, "
			.. "15); 800 amounts cleaned on their grid step")
	end

	function T.running(check) check(storage.gridfluid261 and storage.gridfluid261.done, "ME pattern fluid amounts on the engine's grid") end
	return T
end
