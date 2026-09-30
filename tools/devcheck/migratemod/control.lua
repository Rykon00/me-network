--- Test helper for `devcheck.py migrate`. On the new map made with the older version (on_init) it builds a
--- small ME network with two loaded 1k fluid drives and a loaded drive outside any network. After the save
--- is loaded with the working copy it checks that every drive kept its contents, then destroys a drive: its
--- fluid must go into the other drive and the recovered fluid (issue #26) with nothing lost. A version with
--- recovered fluid also gets an entry outside any network in the old save; it must be kept, and after 5000
--- water are taken out of the network the drives must pull the destroyed drive's recovered water in by
--- themselves (issue #43).
--- Results are logged as DEVCHECK-MIGRATE-FLUIDS lines. Versions without fluid drives are skipped.
--- It also builds a large naquadah reactor full of steam under load, which must be stopped after the
--- update (DEVCHECK-MIGRATE-POWER, issue #25), and a LuV plasma turbine on helium plasma under full load
--- with a turbine output hatch, which must run after the update and return one helium per plasma
--- (DEVCHECK-MIGRATE-TURBINE, issue #28).
--- Pattern providers (issue #27): in the same network a Molecular Assembler and a fresh iron furnace with
--- providers. After the update the assembler must still be a pattern, the furnace must be counted as
--- "no-recipe", and a recipe chosen in the old provider must make the furnace a pattern
--- (DEVCHECK-MIGRATE-PATTERNS). Versions without pattern providers are skipped.
--- Crafting CPU (issue #38 changed its record to several job slots): the old save also has a powered CPU, a
--- drive with plates and sticks, and a gear job started with the old version on the assembler above. After
--- the update the job must finish with the gears in storage and the CPU must count as one job slot
--- (DEVCHECK-MIGRATE-JOB).
local F = "gregtorio-me-fluids"
local DRIVE = "me-fluid-drive-1k"
local Y = 40
local TOTAL = { water = 40000, chlorine = 10000 }      -- drive 1: 32000 water, drive 2: 8000 water + 10000 chlorine
local LONE = { water = 500 }
local OLD_POOL, OLD_POOL_AT = { chlorine = 700 }, { 60.5, Y + 0.5 }   -- recovered fluid of the old save, no network there

local function near(a, b) return math.abs((a or 0) - (b or 0)) <= 1e-3 end
local function same(a, b)
	for k, v in pairs(a) do if not near(v, b[k]) then return false end end
	for k, v in pairs(b) do if not near(v, a[k]) then return false end end
	return true
end

--- Endgame generators (issue #25): the old save has a UV large naquadah reactor full of steam under
--- full load (before the fuel check it burns steam). After the update it must be stopped with the
--- "Wrong fuel" status and keep its steam. Versions without the reactor are skipped.
local PW_REACTOR = "uv-large-naquadah-reactor"
local PW_POS = { 40.5, Y + 2.5 }
local PW_STEAM = 500

local function steam_in(e)
	local seg = e.fluidbox.get_fluid_segment_contents(1)
	return e.get_fluid_count("steam") + ((seg and seg.steam) or 0)
end

local function setup_power()
	if not prototypes.entity[PW_REACTOR] then
		storage.power = "skipped"
		log("DEVCHECK-MIGRATE-SETUP-POWER skipped (no large naquadah reactor in this version)")
		return
	end
	local s = game.surfaces[1]
	local r = s.create_entity{ name = PW_REACTOR, position = PW_POS, force = "player", raise_built = true }
	local got = r.insert_fluid{ name = "steam", amount = PW_STEAM }
	local eei = s.create_entity{ name = "electric-energy-interface", position = { PW_POS[1], PW_POS[2] + 6 }, force = "player" }
	eei.power_production = 0
	eei.power_usage = 327.68e6 / 60
	eei.electric_buffer_size = 1e8
	s.create_entity{ name = "substation", position = { PW_POS[1] + 4, PW_POS[2] + 6 }, force = "player" }
	storage.power = { reactor = r, steam = got, stopped_before = r.disabled_by_script }
	log("DEVCHECK-MIGRATE-SETUP-POWER " .. (got == PW_STEAM and "ok" or "failed") .. " (reactor with " .. got .. " steam)")
end

local function check_power()
	local p = storage.power
	if p == nil or p == "skipped" then
		log("DEVCHECK-MIGRATE-POWER skipped")
		return
	end
	local problems = {}
	local function expect(ok, what) if not ok then problems[#problems + 1] = what end end
	local r = p.reactor
	expect(r.valid, "the reactor is gone")
	local left = 0
	if r.valid then
		left = steam_in(r)
		local cs = r.custom_status
		expect(r.disabled_by_script, "the reactor on steam is not stopped")
		expect(cs and type(cs.label) == "table" and cs.label[1] == "entity-status.fork-wrong-fuel",
			"reactor status " .. serpent.line(cs))
		expect(math.abs(left - p.steam) < 1e-6, "the reactor holds " .. left .. " steam of " .. p.steam)
	end
	for _, m in pairs(problems) do log("DEVCHECK-MIGRATE-FAIL power: " .. m) end
	log("DEVCHECK-MIGRATE-POWER " .. (#problems == 0 and "ok" or "failed") .. string.format(" (steam %.1f of %.1f)", left, p.steam))
end

--- Plasma turbine (issue #28): placed with the old version (its old state), it must burn plasma after
--- the update and the hatch must get the cooled helium for it (hatch + owed + the energy of the current
--- step / fuel value, within 0.1 %), checked at tick 120. Versions without the turbine are skipped.
local TB = "luv-large-plasma-turbine"
local TB_POS = { 75.5, Y + 1.5 }
local TB_PLASMA, TB_POWER = 100, 81.92e6

local function setup_turbine()
	if not (prototypes.entity[TB] and prototypes.entity["turbine-output-hatch"]) then
		storage.turbine = "skipped"
		log("DEVCHECK-MIGRATE-SETUP-TURBINE skipped (no plasma turbine in this version)")
		return
	end
	local s = game.surfaces[1]
	local t = s.create_entity{ name = TB, position = TB_POS, force = "player", raise_built = true }
	local got = t.insert_fluid{ name = "helium-plasma", amount = TB_PLASMA }
	local h = s.create_entity{ name = "turbine-output-hatch", position = { TB_POS[1] + 2, TB_POS[2] }, force = "player", raise_built = true }
	local eei = s.create_entity{ name = "electric-energy-interface", position = { TB_POS[1], TB_POS[2] + 6 }, force = "player" }
	eei.power_production = 0
	eei.power_usage = TB_POWER / 60
	eei.electric_buffer_size = TB_POWER / 60
	s.create_entity{ name = "substation", position = { TB_POS[1] + 4, TB_POS[2] + 6 }, force = "player" }
	storage.turbine = { turbine = t, hatch = h, plasma = got }
	log("DEVCHECK-MIGRATE-SETUP-TURBINE " .. (got == TB_PLASMA and "ok" or "failed") .. " (turbine with " .. got .. " helium plasma)")
end

local function check_turbine()
	local p = storage.turbine
	if p == nil or p == "skipped" then
		log("DEVCHECK-MIGRATE-TURBINE skipped")
		return
	end
	local problems = {}
	local function expect(ok, what) if not ok then problems[#problems + 1] = what end end
	local t, h = p.turbine, p.hatch
	expect(t.valid and h.valid, "the turbine or its hatch is gone")
	local burnt, back = 0, 0
	if t.valid and h.valid then
		local seg = t.fluidbox.get_fluid_segment_contents(1)
		burnt = p.plasma - t.get_fluid_count("helium-plasma") - ((seg and seg["helium-plasma"]) or 0)
		local P = "gregtorio-power"
		back = h.get_fluid_count("helium") + remote.call(P, "debt", t, "helium")
			+ remote.call(P, "energy", t) / prototypes.fluid["helium-plasma"].fuel_value
		expect(burnt > 0.2, "the turbine burnt only " .. burnt .. " plasma")
		expect(math.abs(back - burnt) <= 1e-3 + 1e-3 * burnt, "the turbine burnt " .. burnt .. " plasma and returned " .. back .. " helium")
	end
	for _, m in pairs(problems) do log("DEVCHECK-MIGRATE-FAIL turbine: " .. m) end
	log("DEVCHECK-MIGRATE-TURBINE " .. (#problems == 0 and "ok" or "failed") .. string.format(" (%.4f plasma -> %.4f helium)", burnt, back))
end

local A = "gregtorio-me-autocraft"
local PT_ASSEMBLER, PT_FURNACE = { 14.5, Y + 8.5 }, { 19, Y + 13 }
local PT_PROVIDER_A, PT_PROVIDER_F = { 16.5, Y + 8.5 }, { 17.5, Y + 12.5 }
local PT_RECIPE, PT_FURNACE_RECIPE = "iron-gear-crafting-table", "iron-dust-smelter"
local JOB_GEARS = 5

--- after the ME network of the fluid drives exists (its controller)
local function setup_patterns(place)
	if not (remote.interfaces[A] and prototypes.entity["me-pattern-provider"]) then
		storage.patterns = "skipped"
		log("DEVCHECK-MIGRATE-SETUP-PATTERNS skipped (no pattern providers in this version)")
		return
	end
	local m = place("me-molecular-assembler", PT_ASSEMBLER[1], PT_ASSEMBLER[2])
	m.force.recipes[PT_RECIPE].enabled = true
	m.set_recipe(PT_RECIPE)
	place("me-pattern-provider", PT_PROVIDER_A[1], PT_PROVIDER_A[2])
	place("iron-furnace", PT_FURNACE[1], PT_FURNACE[2])
	local p = place("me-pattern-provider", PT_PROVIDER_F[1], PT_PROVIDER_F[2])
	local set = {}
	for _, k in pairs(remote.call(A, "craftable", p)) do set[k] = true end
	storage.patterns = { provider = p, ok = set["iron-gear-wheel"] == true }
	log("DEVCHECK-MIGRATE-SETUP-PATTERNS " .. (set["iron-gear-wheel"] and "ok" or "failed"))
	--- a job of the old version on a crafting CPU (own power for the CPU and the assembler)
	local eei = place("electric-energy-interface", 12, Y + 15)
	eei.power_production = 1e6
	eei.electric_buffer_size = 1e7
	place("substation", 12, Y + 12)
	place("me-crafting-cpu", 9, Y + 9)
	local drive = place("me-drive-16k", 8.5, Y + 12.5)
	drive.insert{ name = "iron-plate", count = 50 }
	drive.insert{ name = "iron-stick", count = 50 }
	local id, why = remote.call(A, "start", p, "iron-gear-wheel", JOB_GEARS)
	storage.job = { id = id, provider = p }
	log("DEVCHECK-MIGRATE-SETUP-JOB " .. (id and "ok" or ("failed (" .. tostring(why) .. ")")))
end

local function check_job()
	local st = storage.job
	if not (st and st.id) then
		log("DEVCHECK-MIGRATE-JOB " .. (st and "failed (no job in the old save)" or "skipped"))
		return
	end
	local problems = {}
	local function expect(ok, what) if not ok then problems[#problems + 1] = what end end
	local j = remote.call(A, "job", st.id)
	local m = game.surfaces[1].find_entity("me-molecular-assembler", PT_ASSEMBLER)
	local status = "gone"
	if m then for k, v in pairs(defines.entity_status) do if v == m.status then status = k end end end
	expect(j and j.status == "done", "the job of the old save: " .. serpent.line(j) .. ", assembler " .. status
		.. " progress " .. (m and m.crafting_progress or -1))
	local p = st.provider
	if p.valid then
		local net = p.surface.find_logistic_network_by_position(p.position, p.force)
		local gears = net and net.get_item_count{ name = "iron-gear-wheel", quality = "normal" } or 0
		expect(gears >= JOB_GEARS, "gears in storage after the job: " .. gears)
		local n, free, _, slots = remote.call(A, "cpus", p)
		expect(n == 1 and slots == 1 and free == 1, "the old CPU: " .. n .. " CPUs, " .. tostring(slots) .. " slots, " .. free .. " free")
	end
	for _, m in pairs(problems) do log("DEVCHECK-MIGRATE-FAIL job: " .. m) end
	log("DEVCHECK-MIGRATE-JOB " .. (#problems == 0 and "ok" or "failed"))
end

local function check_patterns()
	local st = storage.patterns
	if st == nil or st == "skipped" then
		log("DEVCHECK-MIGRATE-PATTERNS skipped")
		return
	end
	local problems = {}
	local function expect(ok, what) if not ok then problems[#problems + 1] = what end end
	local p = st.provider
	local function craftable()
		local set = {}
		for _, k in pairs(remote.call(A, "craftable", p)) do set[k] = true end
		return set
	end
	expect(st.ok, "the assembler was no pattern in the old save")
	expect(p.valid, "the old provider is gone")
	if p.valid then
		expect(craftable()["iron-gear-wheel"], "the assembler is no pattern after the update")
		local ignored = remote.call(A, "ignored", p)
		expect(ignored["no-recipe"] == 1, "the fresh furnace is not counted as no-recipe: " .. serpent.line(ignored))
		p.force.recipes[PT_FURNACE_RECIPE].enabled = true
		expect(remote.call(A, "set_recipe", p, PT_FURNACE_RECIPE), "set_recipe on the old provider failed")
		expect(craftable()["iron-ingot"], "the furnace is no pattern after choosing its recipe in the old provider")
	end
	for _, m in pairs(problems) do log("DEVCHECK-MIGRATE-FAIL patterns: " .. m) end
	log("DEVCHECK-MIGRATE-PATTERNS " .. (#problems == 0 and "ok" or "failed"))
end

--- the second part of the fluid check: the recovered water is pulled in by the fluid step (every 15 ticks)
function check_pull()
	local st = storage.pull
	if st.done or game.tick < st.tick + 30 then return end
	st.done = true
	local problems = {}
	local function expect(ok, what) if not ok then problems[#problems + 1] = what end end
	local d2 = st.drive
	local totals, pool = remote.call(F, "totals", d2), remote.call(F, "recovered", d2.surface, "player")
	expect(same(totals, { water = 22000, chlorine = 10000 }), "network after the pull-in " .. serpent.line(totals))
	expect(same(pool, st.pool), "recovered fluid after the pull-in " .. serpent.line(pool) .. ", expected " .. serpent.line(st.pool))
	for _, p in pairs(problems) do log("DEVCHECK-MIGRATE-FAIL " .. p) end
	log("DEVCHECK-MIGRATE-FLUIDS " .. (#problems == 0 and "ok" or "failed")
		.. " (on_configuration_changed " .. (storage.config_changed and "ran" or "did not run") .. ", old recovered fluid "
		.. (storage.old_pool and "kept" or "not in this version") .. ", pulled in)")
end

script.on_init(function()
	setup_power()
	setup_turbine()
	storage.patterns = "skipped"
	storage.state = "skipped"
	if not (remote.interfaces[F] and prototypes.entity[DRIVE] and prototypes.entity["me-controller"]) then
		log("DEVCHECK-MIGRATE-SETUP skipped (no ME fluid drives in this version)")
		log("DEVCHECK-MIGRATE-SETUP-PATTERNS skipped (no ME fluid drives in this version)")
		return
	end
	local s = game.surfaces[1]
	s.request_to_generate_chunks({ 0, Y }, 2)
	s.request_to_generate_chunks({ 120, Y }, 1)
	s.force_generate_chunk_requests()
	local function place(name, x, y)
		return s.create_entity{ name = name, position = { x, y }, force = "player", raise_built = true }
	end
	local eei = place("electric-energy-interface", 0, Y)
	eei.power_production = 1e6
	eei.electric_buffer_size = 1e7
	place("substation", 3, Y)
	place("me-controller", 6, Y)
	local d1, d2 = place(DRIVE, 8.5, Y + 3.5), place(DRIVE, 10.5, Y + 3.5)
	local lone = place(DRIVE, 120.5, Y + 0.5)
	local ok = near(remote.call(F, "insert", d1, "water", TOTAL.water), TOTAL.water)
		and near(remote.call(F, "insert", d1, "chlorine", TOTAL.chlorine), TOTAL.chlorine)
	remote.call(F, "unpack_drive", lone, { fork_me_fluids = LONE })
	if remote.interfaces[F].salvage_items then
		local inv = game.create_inventory(1)
		inv[1].set_stack{ name = DRIVE, count = 1 }
		inv[1].tags = { fork_me_fluids = OLD_POOL }
		remote.call(F, "salvage_items", inv, s, "player", OLD_POOL_AT)
		inv.destroy()
		storage.old_pool = remote.call(F, "recovered", s, "player")
		ok = ok and same(storage.old_pool, OLD_POOL)
	end
	storage.drives = {}
	for _, d in pairs({ d1, d2, lone }) do
		storage.drives[#storage.drives + 1] = { entity = d, contents = remote.call(F, "drive", d).contents }
	end
	storage.state = ok and "ready" or "setup-failed"
	log("DEVCHECK-MIGRATE-SETUP " .. (ok and "ok" or "failed"))
	setup_patterns(place)
end)

--- runs after every mod or prototype change: tells the check which path ran
script.on_configuration_changed(function() storage.config_changed = true end)

script.on_nth_tick(30, function(event)
	--- the turbine has to run first (this handler also fires at tick 0)
	if not storage.turbine_checked and event.tick >= 120 then
		storage.turbine_checked = true
		check_turbine()
	end
	--- the update resets the technology effects: the gear recipe, enabled by script in the old save, is
	--- researched in a real game
	if storage.job and not storage.job_recipe then
		storage.job_recipe = true
		game.forces.player.recipes[PT_RECIPE].enabled = true
	end
	if not storage.job_checked and event.tick >= 270 then
		storage.job_checked = true
		check_job()
	end
	if storage.pull then return check_pull() end
	if storage.checked then return end
	storage.checked = true
	check_power()
	check_patterns()
	if storage.state ~= "ready" then
		log("DEVCHECK-MIGRATE-FLUIDS " .. (storage.state == "skipped" and "skipped" or "failed (" .. tostring(storage.state) .. ")"))
		return
	end
	local problems = {}
	local function expect(ok, what) if not ok then problems[#problems + 1] = what end end
	for i, d in pairs(storage.drives) do
		expect(d.entity.valid, "drive " .. i .. " is gone")
		if d.entity.valid then
			local now = remote.call(F, "drive", d.entity)
			expect(now and same(now.contents, d.contents), "drive " .. i .. " holds " .. serpent.line(now and now.contents) .. ", before " .. serpent.line(d.contents))
		end
	end
	local d1, d2 = storage.drives[1].entity, storage.drives[2].entity
	if d1.valid and d2.valid then
		expect(same(remote.call(F, "totals", d2), TOTAL), "network holds " .. serpent.line(remote.call(F, "totals", d2)))
		if remote.interfaces[F].recovered then
			local old = storage.old_pool or {}
			expect(same(remote.call(F, "recovered", d2.surface, "player"), old), "recovered fluid of the old save " .. serpent.line(remote.call(F, "recovered", d2.surface, "player")))
			--- drive 2 has room for 14000 of drive 1's water, the other 18000 are recovered
			d1.die()
			local totals, pool = remote.call(F, "totals", d2), remote.call(F, "recovered", d2.surface, "player")
			expect(same(totals, { water = 22000, chlorine = 10000 }), "network after the destroyed drive " .. serpent.line(totals))
			local want = { water = 18000 }
			for k, v in pairs(old) do want[k] = (want[k] or 0) + v end
			expect(same(pool, want), "recovered fluid " .. serpent.line(pool))
			--- 5000 water leave the network (what an export does): drive 2 pulls 5000 recovered water in
			expect(near(remote.call(F, "remove", d2, "water", 5000), 5000), "could not take water out")
			if #problems == 0 then
				want.water = 13000
				storage.pull = { tick = event.tick, drive = d2, pool = want }
				return
			end
		end
	end
	for _, p in pairs(problems) do log("DEVCHECK-MIGRATE-FAIL " .. p) end
	log("DEVCHECK-MIGRATE-FLUIDS " .. (#problems == 0 and "ok" or "failed")
		.. " (on_configuration_changed " .. (storage.config_changed and "ran" or "did not run") .. ")")
end)

