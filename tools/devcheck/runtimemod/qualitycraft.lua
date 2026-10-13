--- Runtime test of me-network issue #352: autocrafting in every quality. A network with normal and uncommon iron plates and
--- sticks, a CPU, a pattern provider with an assembler and a crafting pattern of the gear recipe in uncommon quality:
---   * the Pattern Terminal's editor makes that pattern (the recipe with its quality, also as the chooser's { name, quality }),
---     refuses a quality the force has not unlocked and fills a processing editor's rows in the recipe's quality;
---   * the network lists "iron-gear-wheel@uncommon" as craftable;
---   * a job for 10 uncommon gears ends: 10 uncommon gears, the uncommon plates and sticks used, the normal ones untouched;
---   * a level maintainer that keeps 14 uncommon gears crafts the 4 more.
--- Loaded by control.lua: require("qualitycraft")(H) returns { setup, tick, running }.

local NET, AC, C, PT = "gregtorio-me-network", "gregtorio-me-autocraft", "gregtorio-me-circuit", "gregtorio-me-pattern-terminal"
local BX, BY = -150, -110             -- (inside the cleared test area, TEST_RADIUS of control.lua; clear of the other tests)
local START, TIMEOUT = 120, 1500
local GEAR, GEAR_RECIPE = "iron-gear-wheel", "iron-gear-crafting-table"
local Q = "uncommon"
local PLATES, STICKS = 100, 200

return function(H)
	local me_place, cable_row, power, me_report = H.me_place, H.cable_row, H.power, H.me_report
	local T = {}
	local function at(dx, dy) return { BX + dx + 0.5, BY + dy + 0.5 } end
	local function line(t) return serpent.line(t) end

	function T.setup(s)
		local fails = {}
		local what = "quality crafting"
		power(s, fails, what, BX, BY)
		power(s, fails, what, BX + 22, BY - 8)
		me_place(s, fails, what, "me-network-controller", BX + 7, BY)             -- tiles 6..7, -1..0
		H.me_drive(s, fails, what, BX + 8.5, BY - 0.5, { ["iron-plate"] = PLATES, ["iron-stick"] = STICKS })
		me_place(s, fails, what, "me-terminal", BX + 9.5, BY - 0.5)
		cable_row(s, fails, BX + 10, BX + 20, BY - 1)
		me_place(s, fails, what, "me-1k-crafting-storage", BX + 12.5, BY + 0.5)
		me_place(s, fails, what, "me-level-maintainer", BX + 11.5, BY - 1.5)
		me_place(s, fails, what, "me-pattern-provider", BX + 16.5, BY - 1.5)
		local m = me_place(s, fails, what, "me-molecular-assembler", BX + 16.5, BY - 2.5)
		if m then m.force.recipes[GEAR_RECIPE].enabled = true end
		local p = s.find_entity("me-pattern-provider", at(16, -2))
		if p then give_patterns(p, { { kind = "crafting", recipe = GEAR_RECIPE, quality = Q } }, fails) end
		return fails
	end

	function T.tick()
		local st = storage.qualitycraft352
		if (st and st.done) or game.tick < START then return end
		local s = game.surfaces[1]
		local function find(name, dx, dy) return s.find_entity(name, at(dx, dy)) end
		if not st then
			st = { problems = {}, phase = "start" }
			storage.qualitycraft352 = st
		end
		local problems = st.problems
		local function expect(ok, msg) if not ok then problems[#problems + 1] = msg end end
		local function finish()
			st.done = true
			me_report("QUALITYCRAFT", "Autocrafting in every quality", problems, "the editor's recipe with its quality, a locked "
				.. "quality refused, processing rows in the quality, craftable, a job of uncommon gears, normal items untouched, "
				.. "a maintainer in the quality")
		end
		local t, drive, maint = find("me-terminal", 9, -1), find("me-drive", 8, -1), find("me-level-maintainer", 11, -2)
		if not (t and drive and maint) then expect(false, "entities missing") return finish() end
		local function count(name, q) return remote.call(NET, "count", t, name, q or "normal") end
		local qkey = GEAR .. "@" .. Q

		if st.phase == "start" then
			local force = t.force
			force.unlock_quality(Q)
			remote.call(NET, "store_in_drive", drive, "iron-plate", 50, Q)
			remote.call(NET, "store_in_drive", drive, "iron-stick", 100, Q)
			expect(count("iron-plate", Q) == 50 and count("iron-stick", Q) == 100, "uncommon plates and sticks stored: "
				.. count("iron-plate", Q) .. ", " .. count("iron-stick", Q))
			--- the editor
			local ed = remote.call(PT, "new_editor")
			local ok, why
			ok, why, ed = remote.call(PT, "set_editor_recipe", force, ed, GEAR_RECIPE, Q)
			local def = ok and remote.call(PT, "pattern_of", force, ed)
			expect(def and def.quality == Q and def.outputs[1].key == qkey and def.inputs[1].key:find("@" .. Q, 1, true),
				"the editor's uncommon recipe: " .. line({ ok, why, def }))
			local ed2 = remote.call(PT, "new_editor")
			ok, why, ed2 = remote.call(PT, "set_editor_recipe", force, ed2, { name = GEAR_RECIPE, quality = Q })
			expect(ok and ed2.quality == Q, "the chooser's { name, quality }: " .. line({ ok, why, ed2 and ed2.quality }))
			local ed3 = remote.call(PT, "new_editor")
			ok, why = remote.call(PT, "set_editor_recipe", force, ed3, GEAR_RECIPE, "legendary")
			expect(not ok and why == "quality-locked", "a locked quality: " .. line({ ok, why }))
			local ed4 = remote.call(PT, "new_editor")
			ed4.mode = "processing"
			ok, why, ed4 = remote.call(PT, "set_editor_recipe", force, ed4, GEAR_RECIPE, Q)
			expect(ok and ed4.outputs[1] and ed4.outputs[1].key == qkey, "processing rows in the quality: " .. line({ ok, why,
				ed4 and ed4.outputs }))
			--- craftable and a job
			local keys = remote.call(AC, "craftable", t) or {}
			local listed = false
			for _, k in pairs(keys) do if k == qkey then listed = true end end
			expect(listed, "uncommon gears are not craftable: " .. line(keys))
			local id, why2 = remote.call(AC, "start", t, qkey, 10)
			expect(id ~= nil, "the uncommon gear job did not start: " .. tostring(why2))
			if not id then return finish() end
			st.job, st.phase, st.tick = id, "job", game.tick
			return
		end

		if st.phase == "job" then
			local j = remote.call(AC, "job", st.job) or {}
			st.status = j.status or st.status
			if st.status ~= "done" then
				if st.status == "failed" or st.status == "cancelled" or game.tick > st.tick + TIMEOUT then
					expect(false, "the uncommon gear job: " .. line({ st.status, j.problem, j.reason }))
					return finish()
				end
				return
			end
			expect(count(GEAR, Q) == 10, "uncommon gears after the job: " .. count(GEAR, Q))
			expect(count("iron-plate", Q) == 40 and count("iron-stick", Q) == 80, "uncommon plates and sticks used: "
				.. count("iron-plate", Q) .. ", " .. count("iron-stick", Q))
			expect(count("iron-plate") == PLATES and count("iron-stick") == STICKS and count(GEAR) == 0, "normal items untouched: "
				.. count("iron-plate") .. ", " .. count("iron-stick") .. ", gears " .. count(GEAR))
			remote.call(C, "set_maintainer", maint, qkey, 14, false)
			st.phase, st.tick = "maintainer", game.tick
			return
		end

		if st.phase == "maintainer" then
			if count(GEAR, Q) < 14 then
				if game.tick > st.tick + TIMEOUT then
					expect(false, "the maintainer kept " .. count(GEAR, Q) .. " uncommon gears, not 14: "
						.. line(remote.call(C, "get_maintainer", maint)))
					return finish()
				end
				return
			end
			expect(count(GEAR, Q) == 14 and count(GEAR) == 0, "the maintainer's uncommon gears: " .. count(GEAR, Q) .. ", normal "
				.. count(GEAR))
			return finish()
		end
	end

	function T.running(check) check(storage.qualitycraft352 and storage.qualitycraft352.done, "Autocrafting in every quality") end

	return T
end
