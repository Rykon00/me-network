--- Runtime test of me-network issue #59, lever 3 (docs/PERFORMANCE.md "Round five"): the machine a crafting job step takes.
--- One provider with a crafting pattern (gears) and three ME Molecular Assemblers around it, in the order the provider finds
--- its neighbours (north A, east B, south C): a free machine that has the recipe comes first, else the first free machine
--- with another recipe in that order is switched, and a machine switched off by script is never taken.
--- * case 1: A and C belts, B gears: B crafts, A and C keep their recipe.
--- * case 2: B belts too: A (the first) is switched to gears, B and C keep belts.
--- * case 3: A belts and switched off: B (the next) is switched, A and C keep belts.
--- * case 4 (issue #122): a job of 8 gears on B, whose recipe a player changes to belts while it crafts: the job fails with the
---   reason "recipe changed" (no test covered that path before).
--- Loaded by control.lua: require("crafter")(H) returns { setup, tick, running } like margin.lua.

local AC = "gregtorio-me-autocraft"
local BX, BY = 620, -100
local START, TIMEOUT = 100, 600
local GEAR, BELT = "iron-gear-crafting-table", "transport-belt"

return function(H)
	local me_place, me_report, power = H.me_place, H.me_report, H.power
	local T = {}

	local function recipe_of(m) local r = m.get_recipe() return r and r.name end

	function T.setup(s)
		local fails = {}
		local what = "crafter choice"
		local tiles = {}                                         -- (land under the scene: the map may have water there)
		for x = BX - 4, BX + 24 do
			for y = BY - 4, BY + 12 do tiles[#tiles + 1] = { name = "grass-1", position = { x, y } } end
		end
		s.set_tiles(tiles)
		power(s, fails, what, BX, BY)
		me_place(s, fails, what, "substation", BX + 20, BY + 5)
		local ctrl = me_place(s, fails, what, "me-network-controller", BX + 7, BY)
		local drive = me_drive(s, fails, what, BX + 8.5, BY - 0.5, { ["iron-plate"] = 400, ["iron-stick"] = 400 })
		local cpu = place_cpu(s, fails, what, BX + 11, BY)          -- (issue #145: a multiblock CPU)
		local prov = me_place(s, fails, what, "me-pattern-provider", BX + 14.5, BY + 5.5)
		local a = me_place(s, fails, what, "me-molecular-assembler", BX + 14.5, BY + 4.5)
		local b = me_place(s, fails, what, "me-molecular-assembler", BX + 15.5, BY + 5.5)
		local c = me_place(s, fails, what, "me-molecular-assembler", BX + 14.5, BY + 6.5)
		if a and b and c then
			for _, r in pairs({ GEAR, BELT }) do a.force.recipes[r].enabled = true end
			a.set_recipe(BELT)
			b.set_recipe(GEAR)
			c.set_recipe(BELT)
		end
		me_connect(fails, what, { ctrl, drive, cpu, prov })
		storage.crafter59_scene = { ctrl = ctrl, prov = prov, a = a, b = b, c = c }
		return fails
	end

	--- what a case expects: the recipes of A, B, C after the job and the machine that crafted
	local CASES = {
		{ before = function() end, want = { BELT, GEAR, BELT }, crafted = 2 },
		{ before = function(sc) sc.b.set_recipe(BELT) end, want = { GEAR, BELT, BELT }, crafted = 1 },
		{ before = function(sc) sc.a.set_recipe(BELT) sc.a.disabled_by_script = true end, want = { BELT, GEAR, BELT }, crafted = 2 },
	}

	function T.tick()
		local tick = game.tick
		local st = storage.crafter59
		if not st then
			if tick < START then return end
			st = { problems = {}, done = false, case = 0 }
			storage.crafter59 = st
		end
		if st.done then return end
		local problems = st.problems
		local function expect(ok, text) if not ok then problems[#problems + 1] = text end end
		local function finish(note)
			st.done = true
			me_report("CRAFTER", "ME crafter choice", problems, note)
		end
		local sc = storage.crafter59_scene
		if not (sc and sc.ctrl and sc.ctrl.valid and sc.prov and sc.prov.valid and sc.a and sc.a.valid and sc.b and sc.b.valid
			and sc.c and sc.c.valid) then
			expect(false, "the entities were not built")
			return finish()
		end
		local ms = { sc.a, sc.b, sc.c }
		local function start_case()
			st.case = st.case + 1
			CASES[st.case].before(sc)
			st.finished = {}
			for i, m in ipairs(ms) do st.finished[i] = m.products_finished end
			local why
			st.job, why = remote.call(AC, "start", sc.ctrl, "iron-gear-wheel", 1)
			st.since = tick
			expect(st.job ~= nil, "case " .. st.case .. ": the job did not start: " .. tostring(why))
			if not st.job then finish() end
		end
		if st.case == 0 then
			local fails = {}
			give_patterns(sc.prov, { { kind = "crafting", recipe = GEAR } }, fails)
			for _, f in pairs(fails) do expect(false, f) end
			local info = remote.call(AC, "provider_info", sc.prov)
			expect(info.slots[1] and info.slots[1].ok and info.slots[1].machines == 3, "the provider's slot: " .. serpent.line(info.slots[1]))
			if #problems > 0 then return finish() end
			return start_case()
		end
		local j = remote.call(AC, "job", st.job)
		if st.change then                                             -- case 4
			local over = j and (j.status == "done" or j.status == "failed" or j.status == "cancelled")
			if not st.changed then
				if j and (j.leases or 0) > 0 then
					sc.b.set_recipe(BELT)                                 -- (what it held comes back to nobody: not counted here)
					st.changed = tick
				elseif over or tick > st.since + TIMEOUT then
					expect(false, "case 4: the job had no lease: " .. serpent.line(j))
					return finish()
				end
				return
			end
			if not over then
				if tick > st.changed + TIMEOUT then
					expect(false, "case 4: the changed recipe was not found: " .. serpent.line(j))
					finish()
				end
				return
			end
			local reason = type(j.reason) == "table" and j.reason[1] or j.reason
			expect(j.status == "failed" and reason == "fork-me-craft.reason-recipe-changed",
				"case 4: the job ended as " .. j.status .. " " .. serpent.line(j.reason))
			sc.a.disabled_by_script = false
			return finish(#CASES .. " cases: a machine with the recipe first, else the first free one switched, none switched off; "
				.. "a changed recipe found after " .. (tick - st.changed) .. " ticks")
		end
		if not (j and (j.status == "done" or j.status == "failed" or j.status == "cancelled")) then
			if tick > st.since + TIMEOUT then
				expect(false, "case " .. st.case .. ": the job timed out: " .. serpent.line(j))
				finish()
			end
			return
		end
		local case = CASES[st.case]
		expect(j.status == "done", "case " .. st.case .. ": the job ended as " .. j.status .. " " .. serpent.line(j.reason))
		local got, crafted = {}, {}
		for i, m in ipairs(ms) do
			got[i] = tostring(recipe_of(m))
			if m.products_finished > st.finished[i] then crafted[#crafted + 1] = i end
		end
		expect(got[1] == case.want[1] and got[2] == case.want[2] and got[3] == case.want[3],
			"case " .. st.case .. ": recipes A, B, C " .. table.concat(got, ", ") .. ", expected " .. table.concat(case.want, ", "))
		expect(#crafted == 1 and crafted[1] == case.crafted, "case " .. st.case .. ": crafted by " .. serpent.line(crafted) .. ", expected " .. case.crafted)
		if st.case < #CASES and #problems == 0 then return start_case() end
		if #problems > 0 then
			sc.a.disabled_by_script = false
			return finish()
		end
		--- case 4: B has the gear recipe (case 3), A is switched off
		local why
		st.job, why = remote.call(AC, "start", sc.ctrl, "iron-gear-wheel", 8)
		st.since, st.change = tick, true
		expect(st.job ~= nil, "case 4: the job did not start: " .. tostring(why))
		if not st.job then
			sc.a.disabled_by_script = false
			finish()
		end
	end

	function T.running(check) check(storage.crafter59 and storage.crafter59.done, "ME crafter choice") end
	return T
end
