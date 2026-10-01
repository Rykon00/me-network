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
--- Issue #68 (the ME rework): the old save's ME network is a logistic network. It gets an old 1k drive with
--- items (also of another quality and a blueprint, which the new network cannot store), an old requester
--- interface with items in its inventory and its trash, an old terminal, a second old controller in the same
--- logistic network, a chest with 16 storage cells on one stack (cells become items with tags and stack size
--- 1), an old drive item in a chest and the ghost of an old drive. After the update every old entity must be
--- replaced, the network connected by cables (fluid drives, CPU, provider and terminal included), the item
--- totals of the old chests must be in the new network (job items aside, they move), the blueprint in an
--- overflow chest, the migration report without a difference, the cells and the old item kept
--- (DEVCHECK-MIGRATE-ITEMS).
local F = "gregtorio-me-fluids"
local NET = "gregtorio-me-network"
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
		local gears
		if remote.interfaces[NET] then
			gears = remote.call(NET, "count", p, "iron-gear-wheel")
		else
			local net = p.surface.find_logistic_network_by_position(p.position, p.force)
			gears = net and net.get_item_count{ name = "iron-gear-wheel", quality = "normal" } or 0
		end
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

--- issue #68: the old item network (see the top of the file); only for versions with the logistic ME network
local IT_DRIVE, IT_IFACE, IT_CTRL2 = { 12.5, Y + 3.5 }, { 14.5, Y + 3.5 }, { 22, Y }
local IT_TERMINAL, IT_CELLS, IT_GHOST = { 3.5, Y + 5.5 }, { 30.5, Y + 20.5 }, { 24.5, Y + 3.5 }
local IT_JOB = { ["iron-plate"] = true, ["iron-stick"] = true, ["iron-gear-wheel"] = true }

function setup_items(place)
	local s = game.surfaces[1]
	if not (prototypes.entity["me-drive-1k"] and prototypes.entity["me-drive-1k"].type == "logistic-container"
		and prototypes.entity["me-controller"] and prototypes.entity["me-controller"].type == "roboport") then
		storage.items = "skipped"
		log("DEVCHECK-MIGRATE-SETUP-ITEMS skipped (no logistic ME network in this version)")
		return
	end
	local drive = place("me-drive-1k", IT_DRIVE[1], IT_DRIVE[2])
	drive.insert{ name = "copper-plate", count = 100 }
	drive.insert{ name = "stone", count = 37 }
	drive.insert{ name = "iron-plate", count = 5, quality = "uncommon" }
	drive.insert{ name = "blueprint", count = 1 }
	local iface = place("me-interface", IT_IFACE[1], IT_IFACE[2])
	iface.get_inventory(defines.inventory.chest).insert{ name = "copper-cable", count = 20 }
	iface.get_inventory(defines.inventory.logistic_container_trash).insert{ name = "stone-brick", count = 10 }
	place("me-terminal", IT_TERMINAL[1], IT_TERMINAL[2])
	place("me-controller", IT_CTRL2[1], IT_CTRL2[2])
	local chest = place("iron-chest", IT_CELLS[1], IT_CELLS[2])
	chest.insert{ name = "me-1k-storage-cell", count = 16 }
	chest.insert{ name = "me-drive-4k", count = 2 }
	local ghost = s.create_entity{ name = "entity-ghost", inner_name = "me-drive-4k", position = IT_GHOST, force = "player" }
	--- the totals of every old ME chest (the job's items move while the job runs: counted, not compared)
	local totals = {}
	for _, e in pairs(s.find_entities_filtered{ name = { "me-drive-1k", "me-drive-16k", "me-interface" } }) do
		for _, id in pairs({ defines.inventory.chest, defines.inventory.logistic_container_trash }) do
			local inv = e.get_inventory(id)
			for _, c in pairs(inv and inv.get_contents() or {}) do
				local key = c.name .. "@" .. (c.quality or "normal")
				totals[key] = (totals[key] or 0) + c.count
			end
		end
	end
	local ln = s.find_logistic_network_by_position({ 6, Y }, "player")
	local ln2 = s.find_logistic_network_by_position(IT_CTRL2, "player")
	storage.items = { totals = totals, one_network = ln and ln2 and ln.network_id == ln2.network_id, ghost = ghost and ghost.valid }
	log("DEVCHECK-MIGRATE-SETUP-ITEMS " .. (storage.items.one_network and "ok" or "failed (the second controller is in another logistic network)")
		.. " (ghost of an old drive: " .. tostring(storage.items.ghost) .. ")")
end

function check_items()
	local st = storage.items
	if st == nil or st == "skipped" then
		log("DEVCHECK-MIGRATE-ITEMS skipped")
		return
	end
	local s = game.surfaces[1]
	local problems = {}
	local function expect(ok, what) if not ok then problems[#problems + 1] = what end end
	expect(st.one_network, "test setup: the two old controllers were not in one logistic network")
	--- every old entity is replaced
	for _, name in pairs({ "me-drive-1k", "me-drive-4k", "me-drive-16k", "me-drive-64k", "me-drive-256k" }) do
		expect(#s.find_entities_filtered{ name = name, type = "logistic-container" } == 0, "an old " .. name .. " is left")
	end
	expect(#s.find_entities_filtered{ name = "me-controller", type = "roboport" } == 0, "an old controller is left")
	expect(#s.find_entities_filtered{ name = "me-interface", type = "logistic-container" } == 0, "an old interface is left")
	local ctrl = s.find_entity("me-network-controller", { 6, Y })
	local drive = s.find_entity("me-drive", IT_DRIVE)
	local iface = s.find_entity("me-network-interface", IT_IFACE)
	local terminal = s.find_entity("me-terminal", IT_TERMINAL)
	expect(ctrl and drive and iface and terminal, "new entities missing: controller " .. tostring(ctrl ~= nil) .. ", drive "
		.. tostring(drive ~= nil) .. ", interface " .. tostring(iface ~= nil) .. ", terminal " .. tostring(terminal ~= nil))
	if #problems == 0 then
		local n = remote.call(NET, "network", ctrl)
		expect(n and n.ok and n.controllers == 1, "the new network " .. serpent.line(n))
		for _, e in pairs({ drive, iface, terminal, storage.drives[1].entity, storage.drives[2].entity,
			s.find_entity("me-crafting-cpu", { 9, Y + 9 }), storage.patterns.provider, s.find_entity("me-drive", { 8.5, Y + 12.5 }) }) do
			expect(e and e.valid and remote.call(NET, "same_network", ctrl, e), (e and e.valid and e.name or "?") .. " is not connected to the controller")
		end
		--- the drive has four 1k cells, the 16k drive four 16k cells
		local cells = remote.call(NET, "drive", drive)
		expect(cells[4] and cells[4].name == "me-1k-storage-cell" and not cells[5], "new 1k drive " .. serpent.line(cells))
		local big = remote.call(NET, "drive", s.find_entity("me-drive", { 8.5, Y + 12.5 }))
		expect(big[4] and big[4].name == "me-16k-storage-cell", "new 16k drive " .. serpent.line(big))
		--- item totals: what the old chests held (+ the second controller) is in the network, the blueprint in a chest
		local report = remote.call("gregtorio-me-migrate", "report")
		expect(report and report.diff == 0 and report.groups >= 1, "migration report " .. serpent.line(report and { report.groups, report.diff }))
		local want = {}
		for k, v in pairs(st.totals) do want[k] = v end
		want["me-controller@normal"] = (want["me-controller@normal"] or 0) + 1
		for k, v in pairs(want) do
			expect(report and report.before[k] == v, "the migration counted " .. tostring(report and report.before[k]) .. " " .. k .. ", the old save had " .. v)
		end
		local contents = remote.call(NET, "contents", ctrl)
		local overflow = {}
		for _, c in pairs(s.find_entities_filtered{ name = "iron-chest", position = { 6, Y }, radius = 40 }) do
			for _, it in pairs(c.get_inventory(defines.inventory.chest).get_contents()) do
				local k = it.name .. "@" .. (it.quality or "normal")
				overflow[k] = (overflow[k] or 0) + it.count
			end
		end
		for k, v in pairs(want) do
			local name, q = k:match("^([^@]+)@(.+)$")
			if not IT_JOB[name] then
				local key = q == "normal" and name or k
				local got = (contents[key] or 0) + (overflow[k] or 0)
				expect(got == v, k .. ": " .. got .. " after the update (network " .. (contents[key] or 0) .. ", chests "
					.. (overflow[k] or 0) .. "), " .. v .. " before")
			end
		end
		expect((overflow["blueprint@normal"] or 0) == 1, "the blueprint is not in an overflow chest: " .. serpent.line(overflow))
		--- the cells of the stack of 16 and the old drive items are kept; the ghost is an ME Drive ghost
		local chest = s.find_entity("iron-chest", IT_CELLS)
		expect(chest and chest.get_item_count("me-1k-storage-cell") == 16, "cells in the chest: " .. (chest and chest.get_item_count("me-1k-storage-cell") or -1))
		expect(chest and chest.get_item_count("me-drive-4k") == 2, "old drive items in the chest: " .. (chest and chest.get_item_count("me-drive-4k") or -1))
		--- the ghost of an old drive: the game removes it when the save is loaded (no item builds the old prototype
		--- any more), before any script runs; if one is left, the migration makes it an ME Drive ghost
		local ghosts = s.find_entities_filtered{ ghost_name = "me-drive", position = IT_GHOST, radius = 0.5 }
		local old = s.find_entities_filtered{ ghost_name = "me-drive-4k", position = IT_GHOST, radius = 0.5 }
		expect(#old == 0, "the ghost of an old drive is left")
		st.ghost_note = #ghosts == 1 and "old ghost became an ME Drive ghost" or "old ghost removed by the game on load"
		local total = 0
		for _, v in pairs(st.totals) do total = total + v end
		for _, m in pairs(problems) do log("DEVCHECK-MIGRATE-FAIL items: " .. m) end
		log("DEVCHECK-MIGRATE-ITEMS " .. (#problems == 0 and "ok" or "failed") .. " (" .. total .. " items in the old chests, "
			.. (report and report.cables or 0) .. " cables placed, " .. (report and report.chests or 0) .. " overflow chests, "
			.. st.ghost_note .. ")")
		return
	end
	for _, m in pairs(problems) do log("DEVCHECK-MIGRATE-FAIL items: " .. m) end
	log("DEVCHECK-MIGRATE-ITEMS failed")
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
	storage.items = "skipped"
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
	--- issue #68: the migration lays cables between the old ME blocks; on water it cannot (the player connects such
	--- a block), so the test area is land
	local land = {}
	for _, t in pairs(s.find_tiles_filtered{ area = { { -40, Y - 40 }, { 140, Y + 60 } }, collision_mask = "water_tile" }) do
		land[#land + 1] = { name = "landfill", position = t.position }
	end
	s.set_tiles(land)
	for _, e in pairs(s.find_entities_filtered{ area = { { -40, Y - 40 }, { 140, Y + 60 } }, type = { "tree", "simple-entity", "cliff" } }) do
		e.destroy()
	end
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
	setup_items(place)
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
	check_items()
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

