--- Runtime test of me-network issue #560: the ME Molecular Assembler carries the network and draws its power through the
--- controller. On a surface of its own ("me-asmnet-test", concrete): a powered network (controller, a drive with iron plates, a
--- 1024k crafting storage) and a cable row of 13 tiles that ends 18 tiles from the substation, then a row without cables:
--- provider P1, assembler A1, provider P2, assembler A2, provider P3 (the pattern of runtimemod's recipe zz-devcheck-fast-gear;
--- A2 is its machine).
--- * the row is one network with the controller; the assemblers have no electric energy source; the controller counts each at
---   a thirtieth of its energy usage (the kept draw equals the walk over the members)
--- * a job of gears is crafted by A2 through P3; while A2 works the slow step counts it at its full energy usage
--- * mined in the middle (A1), the row splits: P2, A2 and P3 form a network without a controller, A2 is switched off with the
---   status "no controller"; A1 placed again joins them, A2 is switched on
--- * the controller without power: A2 is switched off with "no power", on again with the power back
--- * issue #743, the mark in the world of an assembler that is switched off: none while it works; the game's "unplugged"
---   icon without a controller (also an assembler on its own), its "no power" icon without power, its warning icon in a controller
---   conflict, each blinking at 30 ticks and on the entity; gone (the render object too) when the assembler is switched on
---   or removed; an assembler that is off without a mark (a save from before the marks) gets one at the next slow step;
---   a rebuild of the graph (which makes every node anew) leaves exactly one mark on it; a block of assemblers that stops
---   at once is marked a step's share at a time (250 a second)
--- Loaded by control.lua: require("asmnet")(H) returns { setup, tick, running }.

local NET, AC = "gregtorio-me-network", "gregtorio-me-autocraft"
local SURFACE = "me-asmnet-test"
local START, TIMEOUT = 100, 1500
local GEAR, RUNS, RECIPE = "iron-gear-wheel", 200, "zz-devcheck-fast-gear"
local ROW = -1                          -- (the tile row of the cables and the block)
local P1, A1, P2, A2, P3 = 21, 22, 23, 24, 25   -- (tile columns of the block)
local ASM = "me-molecular-assembler"

local function surface()
	local s = game.surfaces[SURFACE]
	if s then return s end
	s = game.create_surface(SURFACE, { default_enable_all_autoplace_controls = false,
		autoplace_settings = { entity = { treat_missing_as_default = false, settings = {} },
			decorative = { treat_missing_as_default = false, settings = {} } } })
	s.always_day = true
	s.request_to_generate_chunks({ 0, 0 }, 2)
	s.force_generate_chunk_requests()
	local tiles = {}
	for x = -16, 48 do for y = -16, 16 do tiles[#tiles + 1] = { name = "refined-concrete", position = { x, y } } end end
	s.set_tiles(tiles)
	return s
end

local function at(x) return { x + 0.5, ROW + 0.5 } end

return function(H)
	local me_place, me_report = H.me_place, H.me_report
	local T = {}

	function T.setup()
		local fails = {}
		local what = "assembler network"
		local s = surface()
		local eei = H.power(s, fails, what, 0, 0)
		if eei then eei.power_production, eei.electric_buffer_size = 1e9, 1e10 end   -- (Gregtorio's assembler draws more)
		if not prototypes.recipe[RECIPE] then fails[#fails + 1] = what .. ": no recipe " .. RECIPE return fails end
		game.forces.player.recipes[RECIPE].enabled = true
		me_place(s, fails, what, "me-network-controller", 6, 0)
		H.me_drive(s, fails, what, 7.5, -0.5, { ["iron-plate"] = 1000 })
		me_place(s, fails, what, "me-1024k-crafting-storage", 7.5, 0.5)
		H.cable_row(s, fails, 8, 20, ROW)
		local p3
		for _, x in ipairs({ P1, A1, P2, A2, P3 }) do
			local e = me_place(s, fails, what, (x == A1 or x == A2) and ASM or "me-pattern-provider", x + 0.5, ROW + 0.5)
			if x == P3 then p3 = e end
		end
		if p3 then give_patterns(p3, { { kind = "crafting", recipe = RECIPE } }, fails) end
		return fails
	end

	function T.tick()
		local st = storage.asmnet560
		local tick = game.tick
		if tick < START or (st and st.done) then return end
		local s = game.surfaces[SURFACE]
		if not st then
			st = { problems = {}, phase = "join" }
			storage.asmnet560 = st
		end
		local problems = st.problems
		local function expect(ok, msg) if not ok then problems[#problems + 1] = msg end end
		local function finish()
			st.done = true
			me_report("ASMNET", "ME Molecular Assembler carries the network (issue #560)", problems, "a row of providers and "
				.. "assemblers without cables is one network and crafts; the controller counts an assembler at 1/30 idle and at its "
				.. "energy usage while it works; mined in the middle the row splits and the far assembler is switched off (no "
				.. "controller), on again when it joins; off without power and on with it; the mark in the world of an assembler that is "
				.. "switched off (issue #743)")
		end
		local ctrl = s.find_entity("me-network-controller", { 6, 0 })
		local eei = s.find_entity("electric-energy-interface", { 0, 0 })
		local p2, p3 = s.find_entity("me-pattern-provider", at(P2)), s.find_entity("me-pattern-provider", at(P3))
		local a2 = s.find_entity(ASM, at(A2))
		if not (ctrl and eei and p2 and p3 and a2) then
			expect(false, "entities missing")
			return finish()
		end
		local usage = prototypes.entity[ASM].energy_usage * 60
		local idle, full = math.floor(usage / 30 + 0.5), math.floor(usage + 0.5)
		--- the controller's draw kept for the assemblers (row "assembler" of the breakdown) and whether the walk agrees
		local function draw()
			remote.call(NET, "network", ctrl)                         -- (a draw marked for the walk is walked here)
			local r = remote.call(NET, "power_recount", ctrl) or {}
			local function w(by) return by and by.assembler and tonumber(by.assembler:match("/(.+)$")) or 0 end
			return w(r.kept_by), r.kept == r.walked and w(r.kept_by) == w(r.walked_by), r
		end
		local function status_of(e)
			local cs = e.custom_status
			return cs and cs.label and cs.label[1] or nil
		end
		--- issue #743: the mark of `e` is `sprite` blinking at `blink` ticks on the entity (nil: no mark); returns its id
		local function want_mark(e, sprite, blink, when)
			local got, b, on, id = remote.call(NET, "assembler_mark", e)
			expect(got == sprite and (sprite == nil or (b == blink and on == true)), when .. ": the mark is " .. tostring(got) .. " (blink "
				.. tostring(b) .. ", on the entity: " .. tostring(on) .. "), expected " .. tostring(sprite) .. " (blink " .. tostring(blink) .. ")")
			return id
		end
		--- the sprites of ME Network's render objects that are on `e`
		local function marks_on(e)
			local n = 0
			for _, obj in pairs(rendering.get_all_objects("me-network")) do
				if obj.type == "sprite" then
					local target = obj.target
					if target and target.entity == e then n = n + 1 end
				end
			end
			return n
		end

		if st.phase == "join" then
			expect(remote.call(NET, "same_network", ctrl, p3) and remote.call(NET, "same_network", ctrl, a2),
				"the row without cables is not one network with the controller")
			expect(prototypes.entity[ASM].electric_energy_source_prototype == nil, "the assembler has an electric energy source")
			remote.call(NET, "slow_step")
			local w, same, r = draw()
			expect(w == 2 * idle and same, "the draw of two idle assemblers: " .. w .. " (expected " .. 2 * idle .. ") " .. serpent.line(r))
			expect(not a2.disabled_by_script and status_of(a2) == nil, "the assembler in the working network is switched off")
			want_mark(a2, nil, nil, "A2 in the working network")
			local id, why = remote.call(AC, "start", ctrl, GEAR, RUNS)
			expect(id ~= nil, "the job did not start: " .. tostring(why))
			if not id then return finish() end
			st.job, st.at, st.phase = id, tick, "craft"
		elseif st.phase == "craft" then
			if a2.status == defines.entity_status.working and not st.seen then
				remote.call(NET, "slow_step")
				local w, same, r = draw()
				st.seen = true
				expect(w == idle + full and same, "the draw while A2 works: " .. w .. " (expected " .. idle + full .. ") " .. serpent.line(r))
			end
			local j = remote.call(AC, "job", st.job) or {}
			if j.status == "done" then
				expect(st.seen, "A2 was never seen working")
				expect(remote.call(NET, "count", ctrl, GEAR) == RUNS, "gears after the job: " .. remote.call(NET, "count", ctrl, GEAR))
				st.phase, st.at = "idle", tick
			elseif j.status == "failed" or j.status == "cancelled" or tick > st.at + TIMEOUT then
				expect(false, "the job: " .. serpent.line({ j.status, j.reason, j.done, j.total }))
				return finish()
			end
		elseif st.phase == "idle" then
			if tick < st.at + 5 then return end
			remote.call(NET, "slow_step")
			local w, same, r = draw()
			expect(w == 2 * idle and same, "the draw after the job: " .. w .. " (expected " .. 2 * idle .. ") " .. serpent.line(r))
			--- mined in the middle: the row splits
			local a1 = s.find_entity(ASM, at(A1))
			if a1 then a1.destroy{ raise_destroy = true } end
			expect(not remote.call(NET, "same_network", ctrl, p3) and remote.call(NET, "same_network", p2, p3),
				"A1 removed: the row did not split from the controller's network")
			remote.call(NET, "slow_step")
			expect(a2.disabled_by_script and status_of(a2) == "fork-me-net.status-no-controller",
				"A2 without a controller: " .. tostring(a2.disabled_by_script) .. " " .. tostring(status_of(a2)))
			local mark = want_mark(a2, "utility/electricity_icon_unplugged", 30, "A2 without a controller")
			w, same, r = draw()
			expect(w == 0 and same, "the controller still counts the split assemblers: " .. serpent.line(r))
			--- placed again: joined and switched on
			me_place(s, problems, "A1 again", ASM, at(A1)[1], at(A1)[2])
			expect(remote.call(NET, "same_network", ctrl, p3), "A1 placed again: the row did not join the controller's network")
			remote.call(NET, "slow_step")
			expect(not a2.disabled_by_script and status_of(a2) == nil, "A2 joined again stays off: " .. tostring(status_of(a2)))
			want_mark(a2, nil, nil, "A2 joined again")
			expect(mark ~= nil and not remote.call(NET, "mark_alive", mark), "the render object of A2's mark is left after A2 was switched on")
			w, same, r = draw()
			expect(w == 2 * idle and same, "the draw after the join: " .. w .. " " .. serpent.line(r))
			eei.power_production = 0
			eei.energy = 0
			st.phase, st.at = "nopower", tick
		elseif st.phase == "nopower" then
			if tick < st.at + 60 then return end
			remote.call(NET, "slow_step")
			expect(a2.disabled_by_script and status_of(a2) == "fork-me-net.status-no-power",
				"A2 without power: " .. tostring(a2.disabled_by_script) .. " " .. tostring(status_of(a2)))
			want_mark(a2, "utility/electricity_icon", 30, "A2 without power")
			--- a save from before the marks: an assembler that is off and has none gets it at the next slow step
			remote.call(NET, "assembler_mark", a2, true)
			want_mark(a2, nil, nil, "A2's mark taken away")
			remote.call(NET, "slow_step")
			want_mark(a2, "utility/electricity_icon", 30, "A2 off without a mark, after a slow step")
			--- the graph made anew (a change of the mods): still one mark, the old render object is not left beside a new one.
			--- This rebuild is from the map and for every test's networks: each gets a new id, at a tick that depends on how
			--- long the job above took with the loaded mods. A test that watches a network over time has to stand it
			--- (perf420.lua makes its circuit phase again).
			remote.call(NET, "rebuild", true)
			remote.call(NET, "slow_step")
			want_mark(a2, "utility/electricity_icon", 30, "A2 off, after a rebuild of the graph")
			expect(marks_on(a2) == 1, "A2 has " .. marks_on(a2) .. " mark objects after a rebuild of the graph")
			eei.power_production = 1e9
			st.phase, st.at = "power", tick
		elseif st.phase == "power" then
			if tick < st.at + 60 then return end
			remote.call(NET, "slow_step")
			expect(not a2.disabled_by_script and status_of(a2) == nil, "A2 with the power back stays off: " .. tostring(status_of(a2)))
			want_mark(a2, nil, nil, "A2 with the power back")
			--- issue #743: a second controller next to P3: a conflict, the warning icon; removed: no mark
			local second = me_place(s, problems, "second controller", "me-network-controller", 27, 0)
			remote.call(NET, "network", ctrl)
			remote.call(NET, "slow_step")
			expect(a2.disabled_by_script and status_of(a2) == "fork-me-net.status-conflict",
				"A2 in a controller conflict: " .. tostring(a2.disabled_by_script) .. " " .. tostring(status_of(a2)))
			want_mark(a2, "utility/warning_icon", 30, "A2 in a controller conflict")
			if second then second.destroy{ raise_destroy = true } end
			remote.call(NET, "network", ctrl)
			remote.call(NET, "slow_step")
			expect(not a2.disabled_by_script and status_of(a2) == nil, "A2 after the conflict stays off: " .. tostring(status_of(a2)))
			want_mark(a2, nil, nil, "A2 after the conflict")
			--- an assembler on its own (a network of one block, no controller): the unplugged icon; removed: its render object
			--- goes with it
			local known, alive = remote.call(NET, "assembler_marks")
			local lone = me_place(s, problems, "lone assembler", ASM, 30.5, 5.5)
			if lone then
				remote.call(NET, "slow_step")
				expect(lone.disabled_by_script and status_of(lone) == "fork-me-net.status-no-controller",
					"an assembler on its own: " .. tostring(lone.disabled_by_script) .. " " .. tostring(status_of(lone)))
				local id = want_mark(lone, "utility/electricity_icon_unplugged", 30, "an assembler on its own")
				lone.destroy{ raise_destroy = true }
				expect(id ~= nil and not remote.call(NET, "mark_alive", id), "the render object of a removed assembler's mark is left")
				remote.call(NET, "slow_step")
				local known2, alive2 = remote.call(NET, "assembler_marks")
				expect(known2 == known and alive2 == alive, "the marks the mod remembers after a marked assembler was removed: " .. tostring(known2)
					.. " (" .. tostring(alive2) .. " exist), " .. tostring(known) .. " (" .. tostring(alive) .. ") before it was built")
			end
			--- a block of assemblers without a controller, more than a step marks: the first step marks its share, the next
			--- one the rest; removed, no mark is left
			local share = remote.call(NET, "assembler_mark_step")
			local cols = math.ceil((share + 10) / 10)
			local block = {}
			for x = 0, cols - 1 do
				for y = 0, 9 do block[#block + 1] = me_place(s, problems, "block of assemblers", ASM, 20.5 + x, 4.5 + y) end
			end
			remote.call(NET, "slow_step")
			local k1 = remote.call(NET, "assembler_marks")
			expect(k1 - known == share, "the first step marked " .. (k1 - known) .. " of " .. #block .. " assemblers that stopped at once, not " .. share)
			remote.call(NET, "slow_step")
			local k2, a2n = remote.call(NET, "assembler_marks")
			expect(k2 - known == #block and a2n - alive == #block, "after the second step " .. (k2 - known) .. " of " .. #block .. " are marked ("
				.. (a2n - alive) .. " exist)")
			for _, e in pairs(block) do e.destroy{ raise_destroy = true } end
			remote.call(NET, "slow_step")
			local k3, a3 = remote.call(NET, "assembler_marks")
			expect(k3 == known and a3 == alive, "the marks after the block was removed: " .. tostring(k3) .. " (" .. tostring(a3) .. " exist), "
				.. tostring(known) .. " (" .. tostring(alive) .. ") before")
			return finish()
		end
	end

	function T.running(check) check(storage.asmnet560 and storage.asmnet560.done, "ME Molecular Assembler carries the network") end
	return T
end
