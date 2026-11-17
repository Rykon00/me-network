--- Runtime test of me-network issue #769: the steps of a job that share machines share them. One provider with two ME
--- Molecular Assemblers (five Acceleration Cards each) and two crafting patterns, both recipes of Gregtorio's crafting
--- table (the stand-in recipes of runtimemod's data.lua): iron sticks (1 iron ingot -> 1 stick) and the gear (1 plate + 2
--- sticks -> 1 gear). Issue #775: not the recipe `iron-stick`, which is a lathe recipe from an ingot with Gregtorio; the
--- assembler cannot craft it, so its pattern had no machine and the plan lacked the sticks. A job of JOB gears plans
--- 2 * JOB stick runs and JOB gear runs on the same two machines. Before, the stick step took every free machine at each
--- visit until all its runs were
--- handed out, and the first gear was crafted only then. Now a visit hands out in passes, one hand-over per step:
--- * while stick runs are still to be handed out, gear runs are handed out already (seen at some tick of the job), and
---   more than one hand-over of them: the gear step, which found no machine once its sticks were there, gets one of the
---   stick step's two machines (a lease that is not topped up any more) and keeps it;
--- * the job ends with JOB gears, no stick left over, the plates and ingots it took gone, nothing in the machines.
--- Loaded by control.lua: require("fairsteps")(H) returns { setup, tick, running }.

local NET, AC = "gregtorio-me-network", "gregtorio-me-autocraft"
local BX, BY = 820, -100
local START, TIMEOUT = 115, 1250
local GEAR, STICK = "iron-gear-crafting-table", "iron-rod-crafting-table"
local INGOT = "iron-ingot"
local JOB = 96

return function(H)
	local me_place, me_report, power = H.me_place, H.me_report, H.power
	local T = {}

	function T.setup(s)
		local fails = {}
		local what = "fair steps"
		local tiles = {}
		for x = BX - 4, BX + 24 do
			for y = BY - 4, BY + 12 do tiles[#tiles + 1] = { name = "grass-1", position = { x, y } } end
		end
		s.set_tiles(tiles)
		power(s, fails, what, BX, BY)
		me_place(s, fails, what, "substation", BX + 20, BY + 5)
		local ctrl = me_place(s, fails, what, "me-network-controller", BX + 7, BY)
		local drive = me_drive(s, fails, what, BX + 8.5, BY - 0.5, { ["iron-plate"] = JOB, [INGOT] = 2 * JOB })
		local cpu = place_cpu(s, fails, what, BX + 11, BY)
		local prov = me_place(s, fails, what, "me-pattern-provider", BX + 14.5, BY + 5.5)
		local a = me_place(s, fails, what, "me-molecular-assembler", BX + 14.5, BY + 4.5)
		local b = me_place(s, fails, what, "me-molecular-assembler", BX + 15.5, BY + 5.5)
		--- (five Acceleration Cards each, as fastcraft.lua: the job of some hundred crafts ends within the test's ticks)
		for _, m in pairs({ a, b }) do m.get_module_inventory().insert{ name = "me-acceleration-card", count = 5 } end
		if a then
			for _, r in pairs({ GEAR, STICK }) do
				if a.force.recipes[r] then a.force.recipes[r].enabled = true else fails[#fails + 1] = what .. ": no recipe " .. r end
			end
		end
		if prov then give_patterns(prov, { { kind = "crafting", recipe = STICK }, { kind = "crafting", recipe = GEAR } }, fails) end
		me_connect(fails, what, { ctrl, drive, cpu, prov })
		storage.fairsteps769_scene = { ctrl = ctrl, a = a, b = b }
		return fails
	end

	function T.tick()
		local tick = game.tick
		local st = storage.fairsteps769
		if tick < START or (st and st.done) then return end
		if not st then
			st = { problems = {}, phase = "start" }
			storage.fairsteps769 = st
		end
		local problems = st.problems
		local function expect(ok, msg) if not ok then problems[#problems + 1] = msg end end
		local function finish(note)
			st.done = true
			me_report("FAIRSTEPS", "steps of a job share their machines (issue #769)", problems, note or "")
		end
		local sc = storage.fairsteps769_scene
		if not (sc and sc.ctrl and sc.ctrl.valid and sc.a and sc.a.valid and sc.b and sc.b.valid) then
			expect(false, "entities missing")
			return finish()
		end
		local function count(name) return remote.call(NET, "count", sc.ctrl, name) end
		if st.phase == "start" then
			local id, why, missing = remote.call(AC, "start", sc.ctrl, "iron-gear-wheel", JOB)
			--- (issue #775: what the plan lacks and the two recipes as this mod set has them)
			if not id then
				local function recipe(name)
					local p = prototypes.recipe[name]
					if not p then return name .. ": no recipe" end
					local parts = {}
					for _, g in ipairs(p.ingredients) do parts[#parts + 1] = g.amount .. " " .. g.name end
					return name .. " (" .. table.concat(p.categories, ", ") .. "): " .. table.concat(parts, " + ")
				end
				expect(false, "the job did not start: " .. tostring(why) .. ", the plan lacks " .. serpent.line(missing) .. "; "
					.. recipe(STICK) .. "; " .. recipe(GEAR))
			end
			if not id then return finish() end
			st.job, st.at, st.phase = id, tick, "run"
			return
		end
		local j = remote.call(AC, "job", st.job)
		if st.phase == "run" then
			if not j then expect(false, "the job is gone") return finish() end
			local sticks, gears
			for _, step in ipairs(j.steps or {}) do
				if step.recipe == STICK then sticks = step elseif step.recipe == GEAR then gears = step end
			end
			if not (sticks and gears) then
				expect(false, "the plan has no stick and gear step: " .. serpent.line(j.steps))
				return finish()
			end
			--- (the gear step keeps a machine of its own, taken from the stick step, and is topped up next to it: the gears
			--- handed out while stick runs are left grow past one hand-over)
			if sticks.issued < sticks.runs and gears.issued > (st.most or 0) then st.most = gears.issued end
			if not st.shared and gears.issued > 0 and sticks.issued < sticks.runs then
				st.shared = string.format("at tick %d of the job: gears %d of %d handed out, sticks %d of %d", tick - st.at, gears.issued,
					gears.runs, sticks.issued, sticks.runs)
			end
			if j.status == "done" then
				st.phase, st.took = "end", tick - st.at
			elseif j.status == "failed" or j.status == "cancelled" or tick > st.at + TIMEOUT then
				expect(false, "the job: " .. serpent.line({ j.status, j.reason, j.done, j.total, j.wait }))
				return finish()
			end
			return
		end
		expect(st.shared ~= nil, "the gear step got no machine before every stick run was handed out")
		expect((st.most or 0) > 16, "the gear step kept no machine next to the stick step: at most " .. tostring(st.most)
			.. " gears were handed out while stick runs were left (one hand-over is 16)")
		expect(count("iron-gear-wheel") == JOB and count("iron-stick") == 0 and count("iron-plate") == 0 and count(INGOT) == 0,
			"after the job: " .. count("iron-gear-wheel") .. " gears, " .. count("iron-stick") .. " sticks, " .. count("iron-plate")
				.. " plates, " .. count(INGOT) .. " ingots")
		for _, m in ipairs({ sc.a, sc.b }) do
			expect(m.get_inventory(defines.inventory.crafter_input).is_empty() and m.get_inventory(defines.inventory.crafter_output).is_empty(),
				"something is left in a machine")
		end
		finish(tostring(st.shared) .. "; up to " .. tostring(st.most) .. " gears handed out while stick runs were left; done after "
			.. tostring(st.took) .. " ticks")
	end

	function T.running(check) check(storage.fairsteps769 and storage.fairsteps769.done, "steps of a job share their machines") end

	return T
end
