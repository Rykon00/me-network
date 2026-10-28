--- Runtime test of me-network issue #557: a fast machine is kept busy. One network with iron plates, a CPU (a 1024k crafting
--- storage), a pattern provider with the pattern of runtimemod's data-final-fixes recipe zz-devcheck-fast-gear (a plate into a
--- gear in 0.1 s) and one ME Molecular Assembler with five Acceleration Cards: it crafts several gears per tick, so 16 crafts
--- handed over at a job step were done long before the next step (the job left it idle most of the time). A job that lasts
--- about 510 ticks at its speed: over 300 ticks (from 60 ticks after its start) the assembler makes at least 85 % of what its
--- speed allows. (With Gregtorio's assembler, 5 crafts per tick, one stack of gears is made in less than a step: the job is
--- stepped earlier.)
--- Loaded by control.lua: require("fastcraft")(H) returns { setup, tick, running }.

local NET, AC = "gregtorio-me-network", "gregtorio-me-autocraft"
local BX, BY = 420, -40               -- (inside the cleared test area, TEST_RADIUS of control.lua; clear of the other tests)
local START, TIMEOUT = 150, 900
local RECIPE, GEAR = "zz-devcheck-fast-gear", "iron-gear-wheel"
local WINDOW = 300

return function(H)
	local me_place, me_report = H.me_place, H.me_report
	local T = {}
	local function at(dx, dy) return { BX + dx + 0.5, BY + dy + 0.5 } end

	function T.setup(s)
		local fails = {}
		local what = "fast machine"
		if not prototypes.recipe[RECIPE] then fails[#fails + 1] = what .. ": no recipe " .. RECIPE return fails end
		H.power(s, fails, what, BX, BY)
		me_place(s, fails, what, "substation", BX + 16, BY - 5)          -- (the assembler's power)
		me_place(s, fails, what, "me-network-controller", BX + 7, BY)
		H.me_drive(s, fails, what, BX + 8.5, BY - 0.5, { ["iron-plate"] = 5000 })
		H.cable_row(s, fails, BX + 9, BX + 16, BY - 1)
		me_place(s, fails, what, "me-1024k-crafting-storage", BX + 10.5, BY + 0.5)
		local p = me_place(s, fails, what, "me-pattern-provider", BX + 14.5, BY - 1.5)
		local m = me_place(s, fails, what, "me-molecular-assembler", BX + 14.5, BY - 2.5)
		if m then
			m.force.recipes[RECIPE].enabled = true
			m.get_module_inventory().insert{ name = "me-acceleration-card", count = 5 }
		end
		if p then give_patterns(p, { { kind = "crafting", recipe = RECIPE } }, fails) end
		return fails
	end

	function T.tick()
		local st = storage.fastcraft557
		local tick = game.tick
		if tick < START or (st and st.done) then return end
		local s = game.surfaces[1]
		local ctrl = s.find_entity("me-network-controller", { BX + 7, BY })
		local m = s.find_entity("me-molecular-assembler", at(14, -3))
		if not st then
			st = { problems = {}, phase = "start" }
			storage.fastcraft557 = st
		end
		local problems = st.problems
		local function expect(ok, msg) if not ok then problems[#problems + 1] = msg end end
		local function finish(note)
			st.done = true
			me_report("FASTCRAFT", "Fast machines kept busy (issue #557)", problems, note or "")
		end
		if not (ctrl and m) then expect(false, "entities missing") return finish() end
		local per_tick = m.crafting_speed / (prototypes.recipe[RECIPE].energy * 60)

		if st.phase == "start" then
			--- (a job that outlasts the window by about 150 ticks at the machine's speed: Gregtorio's assembler is faster)
			st.runs = math.ceil(per_tick * (60 + WINDOW + 150))
			local id, why = remote.call(AC, "start", ctrl, GEAR, st.runs)
			expect(id ~= nil, "the job did not start: " .. tostring(why))
			if not id then return finish() end
			st.job, st.at, st.phase = id, tick, "warm"
		elseif st.phase == "warm" then
			if tick < st.at + 60 then return end
			st.f0, st.t0, st.phase = m.products_finished, tick, "window"
		elseif st.phase == "window" then
			if tick < st.t0 + WINDOW then return end
			local made = m.products_finished - st.f0
			local share = made / ((tick - st.t0) * per_tick)
			st.share = share
			expect(share >= 0.85, string.format("the assembler made %d gears in %d ticks: %.0f %% of what its speed allows (%.2f per "
				.. "tick), at least 85 %% expected", made, tick - st.t0, share * 100, per_tick))
			st.phase = "done"
		elseif st.phase == "done" then
			local j = remote.call(AC, "job", st.job) or {}
			if j.status ~= "done" then
				if j.status == "failed" or j.status == "cancelled" or tick > st.at + TIMEOUT then
					expect(false, "the job: " .. serpent.line({ j.status, j.reason, j.done, j.total }))
					return finish()
				end
				return
			end
			expect(remote.call(NET, "count", ctrl, GEAR) == st.runs and remote.call(NET, "count", ctrl, "iron-plate") == 5000 - st.runs,
				"after the job: gears " .. remote.call(NET, "count", ctrl, GEAR) .. ", plates " .. remote.call(NET, "count", ctrl, "iron-plate"))
			return finish(string.format("an assembler at %.2f crafts per tick busy %.0f %% of 300 ticks; a job of %d gears done, "
				.. "nothing lost", per_tick, st.share * 100, st.runs))
		end
	end

	function T.running(check) check(storage.fastcraft557 and storage.fastcraft557.done, "Fast machines kept busy") end
	return T
end
