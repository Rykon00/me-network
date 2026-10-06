--------------------------------------------------------------------------------
--- devcheck migrate (issue #3): a save of an older ME Network (0.1.0) with every old fluid block, loaded with the
--- working copy (an old version with the unified blocks, 0.2.0 or later: the scenario of issue #5 below). on_init (old version): a network with item and fluid cells, three ME Fluid Interfaces (import with
--- a tank, export with fluid and pipes, export alone), an ME Fluid Import Bus and Export Bus with filters on tanks,
--- an ME Fluid Storage Bus (read only, priority, filter) on a tank, an item ME Interface next to a pipe with water,
--- a level maintainer and a pattern provider that name the old items, ghosts of the four old blocks with their
--- tags, the old items in a chest, in a blueprint, in the network's cells and in a cell taken out of a drive. The
--- fluid in the area (every segment once) and in the cells is counted. on_configuration_changed (working copy): the
--- unified blocks with the settings, no old entity, ghost or item left, the same fluid; at tick + 150 (after the
--- I/O steps) the fluid again and the side next to the old pipe still off.
--------------------------------------------------------------------------------

local NET, IO, FL, SB = "gregtorio-me-network", "gregtorio-me-io", "gregtorio-me-fluids", "gregtorio-me-storagebus"
local AREA = { { -10, -12 }, { 80, 30 } }
local EPS = 0.5

local AC = "gregtorio-me-autocraft"
local function L(key, msg) log("DEVCHECK-MIGRATE-" .. key .. " " .. msg) end

local function place(s, fails, name, x, y, extra)
	local def = { name = name, position = { x, y }, force = "player", raise_built = true }
	for k, v in pairs(extra or {}) do def[k] = v end
	local ok, e = pcall(s.create_entity, def)
	if not (ok and e) then fails[#fails + 1] = "place " .. name .. " at " .. x .. "," .. y .. ": " .. tostring(e) return nil end
	return e
end

--- fluid in the area (each segment once, boxes without a segment alone) plus in the cells of the drives
local function fluid_totals(s)
	local out, seen = {}, {}
	local function add(name, n) out[name] = (out[name] or 0) + n end
	for _, e in pairs(s.find_entities_filtered{ area = AREA }) do
		local ok, fb = pcall(function() return e.fluidbox end)
		if ok and fb and #fb > 0 then
			for i = 1, #fb do
				local id = fb.get_fluid_segment_id(i)
				if id then
					if not seen[id] then
						seen[id] = true
						for name, n in pairs(fb.get_fluid_segment_contents(i) or {}) do add(name, n) end
					end
				elseif fb[i] then
					add(fb[i].name, fb[i].amount)
				end
			end
		end
	end
	for _, d in pairs(s.find_entities_filtered{ area = AREA, name = "me-drive" }) do
		for _, cell in pairs(remote.call(NET, "drive", d) or {}) do
			for key, n in pairs(cell.items or {}) do
				if key:sub(1, 6) == "fluid/" then add(key:sub(7), n) end
			end
		end
	end
	return out
end

local function same_totals(a, b)
	local diff = {}
	for name, n in pairs(a) do
		if math.abs(n - (b[name] or 0)) > EPS then diff[#diff + 1] = name .. " " .. n .. " -> " .. (b[name] or 0) end
	end
	for name, n in pairs(b) do
		if a[name] == nil and n > EPS then diff[#diff + 1] = name .. " 0 -> " .. n end
	end
	table.sort(diff)
	return #diff == 0, table.concat(diff, ", ")
end

local function sum(t) local n = 0 for _, v in pairs(t) do n = n + v end return n end

--------------------------------------------------------------------------------
--- An old version that already has the unified blocks (0.2.0 and later; issue #5): a save of it has every kind of
--- block in its old state (no queues of the scheduler, no new fields), and when the version number did not change it
--- is loaded without on_configuration_changed. After the load the network must work: the import bus empties its
--- chest, the export bus fills its chest, the interface keeps its row and imports the rest, the interface on a tank
--- imports the tank, the storage buses show the chest and the tank, the circuit interface writes signals, the level
--- maintainer is checked; the fluid is the same before and after.
--------------------------------------------------------------------------------

local function unified_old()
	local v = script.active_mods["me-network"] or "0.0.0"
	local a, b = v:match("^(%d+)%.(%d+)")
	return tonumber(a) > 0 or tonumber(b) >= 2
end

local function setup_unified(s)
	local fails = {}
	local eei = place(s, fails, "electric-energy-interface", 2, -4)
	if eei then eei.power_production = 1e7 eei.electric_buffer_size = 1e8 end
	place(s, fails, "substation", 5, -4)
	place(s, fails, "substation", 25, -4)
	place(s, fails, "substation", 42, -4)                                  -- (not wired to the first one: its own source)
	local eei2 = place(s, fails, "electric-energy-interface", 45, -4)
	if eei2 then eei2.power_production = 1e7 eei2.electric_buffer_size = 1e8 end
	local ctrl = place(s, fails, "me-network-controller", 9, 0)
	--- issue #6: the save is made at tick 0; the controller gets its energy by script before anything asks whether the
	--- network works (that answer is kept for the tick), so the jobs below can start
	if ctrl then ctrl.energy = 1e9 end
	for x = 8, 45 do place(s, fails, "me-cable", x + 0.5, 1.5) end
	local function drive(x, cell)
		local d = place(s, fails, "me-drive", x, 0.5)
		local inv = game.create_inventory(1)
		for slot = 1, 4 do
			inv[1].set_stack{ name = cell, count = 1 }
			if d then remote.call(NET, "insert_cell", d, inv[1], slot) end
		end
		inv.destroy()
		return d
	end
	local di = drive(10.5, "me-16k-storage-cell")
	local df = drive(11.5, "me-1k-fluid-storage-cell")
	place(s, fails, "me-terminal", 12.5, 0.5)
	if di then
		remote.call(NET, "store_in_drive", di, "iron-gear-wheel", 100)
		remote.call(NET, "store_in_drive", di, "copper-plate", 500)
	end
	if df then remote.call(NET, "store_fluid_in_drive", df, "sulfuric-acid", 640) end
	local south = { direction = defines.direction.south }
	local ib = place(s, fails, "me-import-bus", 14.5, 2.5, south)
	local c1 = place(s, fails, "iron-chest", 14.5, 3.5)
	if c1 then c1.insert{ name = "iron-plate", count = 200 } end
	local eb = place(s, fails, "me-export-bus", 16.5, 2.5, south)
	place(s, fails, "iron-chest", 16.5, 3.5)
	if eb then remote.call(IO, "set_bus_filters", eb, { "iron-gear-wheel" }) end
	local iface = place(s, fails, "me-network-interface", 18.5, 2.5)
	if iface then
		remote.call(IO, "set_interface_config", iface, { [1] = { name = "copper-plate", quality = "normal", amount = 50 } })
		iface.insert{ name = "stone", count = 30 }
	end
	local fi = place(s, fails, "me-network-interface", 24.5, 2.5)          -- the tank's north connection meets its south side
	local t1 = place(s, fails, "storage-tank", 25.5, 4.5)
	if t1 then t1.insert_fluid{ name = "crude-oil", amount = 3000 } end
	local sb = place(s, fails, "me-storage-bus", 30.5, 2.5, south)
	local c3 = place(s, fails, "iron-chest", 30.5, 3.5)
	if c3 then c3.insert{ name = "wood", count = 77 } end
	place(s, fails, "me-storage-bus", 34.5, 2.5, south)
	local t2 = place(s, fails, "storage-tank", 34.5, 4.5)
	if t2 then t2.insert_fluid{ name = "lubricant", amount = 4000 } end
	local ci = place(s, fails, "me-circuit-interface", 38.5, 2.5)
	local maint = place(s, fails, "me-level-maintainer", 40.5, 2.5)
	if maint then remote.call("gregtorio-me-circuit", "set_maintainer", maint, "iron-gear-wheel", 500) end
	--- me-network issue #128: a terminal and a level maintainer far from every pole (the substation at 42 reaches to 51): an
	--- old version leaves them without power, this one lets the network power them
	for x = 46, 59 do place(s, fails, "me-cable", x + 0.5, 1.5) end
	place(s, fails, "me-terminal", 60.5, 1.5)
	local far = place(s, fails, "me-level-maintainer", 61.5, 1.5)
	if far then remote.call("gregtorio-me-circuit", "set_maintainer", far, "iron-gear-wheel", 5) end
	--- me-network issue #6: the three legacy CPUs, each running a job (copper cables on three Molecular Assemblers)
	local jobs = {}
	local term = s.find_entity("me-terminal", { 12.5, 0.5 })
	--- copper cables are not unlocked at the start with Space Age: its technology researched (the load runs
	--- on_configuration_changed, which resets the technology effects)
	for _, tech in pairs(game.forces.player.technologies) do
		for _, e in pairs(tech.prototype.effects) do
			if e.type == "unlock-recipe" and e.recipe == "copper-cable" then tech.researched = true end
		end
	end
	game.forces.player.recipes["copper-cable"].enabled = true
	for _, x in pairs({ 28.5, 32.5, 36.5 }) do
		local m = place(s, fails, "me-molecular-assembler", x, -1.5)
		local p = place(s, fails, "me-pattern-provider", x, 0.5)
		local inv = game.create_inventory(1)
		inv.insert{ name = "me-blank-pattern", count = 1 }
		remote.call("gregtorio-me-terminal", "encode_def", false, inv, false, { kind = "crafting", recipe = "copper-cable" })
		local stack = inv.find_item_stack("me-encoded-pattern")
		if not (m and p and stack and remote.call(AC, "insert_pattern", p, stack)) then fails[#fails + 1] = "pattern at " .. x end
		inv.destroy()
	end
	--- (an old version with the multiblock CPUs of issue #6 starts no new job on a legacy CPU: no jobs then)
	local legacy_jobs = not prototypes.entity["me-crafting-unit"]
	if not legacy_jobs then jobs = nil end
	--- me-network issue #131: such a version runs the job on a multiblock CPU (one crafting storage next to the terminal); the
	--- assemblers of the three providers above are 3x3 there and one tile in the working copy, so the provider that touched the
	--- edge of the big block has no machine after the load, and the job that waited for it must not hang
	local multi_job
	if not legacy_jobs and term then
		place(s, fails, "me-1k-crafting-storage", 13.5, 0.5)
		local id, why = remote.call(AC, "start", term, "copper-cable", 8)
		if id then multi_job = id else fails[#fails + 1] = "the job on the crafting storage: " .. tostring(why) end
	end
	for i, cpu in ipairs(legacy_jobs and { { "me-crafting-cpu", 19 }, { "me-co-processing-cpu", 22 }, { "me-quantum-crafting-cpu", 25 } } or {}) do
		local c = place(s, fails, cpu[1], cpu[2], 0)
		local id, why
		if term then id, why = remote.call(AC, "start", term, "copper-cable", 8) end
		local j = id and remote.call(AC, "job", id)
		if not (c and j and j.status == "running" and j.cpu_name == cpu[1]) then
			fails[#fails + 1] = "job " .. i .. " on " .. cpu[1] .. ": " .. tostring(why) .. " " .. serpent.line(j and { j.status, j.cpu_name })
		end
		jobs[i] = { id = id, cpu = cpu[1] }
	end
	--- me-network issue #28: an old version with upgrade cards (0.3.0 / main before #28) keeps a storage bus's cards as
	--- names in its record and a workbench's cell (its cards in its tags) in an inventory of one slot: a bus with two
	--- cards and a workbench with a cell that has a partition and two cards
	local cards
	if remote.interfaces[SB] and remote.interfaces[SB].card_click and prototypes.entity["me-cell-workbench"] then
		cards = true
		local bus = place(s, fails, "me-storage-bus", 43.5, 2.5, south)
		local wb = place(s, fails, "me-cell-workbench", 20.5, 8.5)
		local inv = game.create_inventory(2)
		local hand = inv[1]
		local function card(name)
			hand.set_stack{ name = name, count = 1 }
			return hand
		end
		if bus then
			if remote.call(SB, "card_click", bus, 1, card("me-capacity-card"), inv, false)
				or remote.call(SB, "card_click", bus, 3, card("me-inverter-card"), inv, false) then
				fails[#fails + 1] = "cards on the storage bus"
			end
		end
		if wb then
			local WB = "gregtorio-me-workbench"
			hand.set_stack{ name = "me-4k-storage-cell", count = 1 }
			remote.call(WB, "cell_click", wb, hand, inv, false)
			remote.call(WB, "set_partition_slot", wb, 1, "wood")
			if remote.call(WB, "card_click", wb, 1, card("me-inverter-card"), inv, false)
				or remote.call(WB, "card_click", wb, 2, card("me-overflow-destruction-card"), inv, false) then
				fails[#fails + 1] = "cards on the workbench's cell"
			end
		end
		inv.destroy()
	end
	storage.mig = { unified = true, before = fluid_totals(s), fails = fails, start = nil, jobs = jobs, cards = cards, multi_job = multi_job }
	L("SETUP", (#fails == 0 and "ok" or "failed") .. " (unified blocks of " .. tostring(script.active_mods["me-network"]) .. "; "
		.. #fails .. " problems; fluid " .. string.format("%.1f", sum(storage.mig.before)) .. " units"
		.. (jobs and "; jobs on the legacy CPUs" or "") .. (cards and "; cards on a storage bus and a workbench's cell" or "") .. ")"
		.. (#fails > 0 and (": " .. table.concat(fails, "; ")) or ""))
end

--- after the load: what moved (UNIFIED), then the fluid (FLUIDS)
local function check_unified(st)
	local s = game.surfaces[1]
	local function at(name, x, y) return s.find_entity(name, { x, y }) end
	local problems = {}
	local function expect(ok, what) if not ok then problems[#problems + 1] = what end end
	local t = at("me-terminal", 12.5, 0.5)
	local function count(name) return t and remote.call(NET, "count", t, name) or -1 end
	local c1, c2, c3 = at("iron-chest", 14.5, 3.5), at("iron-chest", 16.5, 3.5), at("iron-chest", 30.5, 3.5)
	expect(c1 and c1.get_item_count("iron-plate") == 0 and count("iron-plate") == 200, "import bus: chest "
		.. tostring(c1 and c1.get_item_count("iron-plate")) .. ", network " .. count("iron-plate"))
	expect(c2 and c2.get_item_count("iron-gear-wheel") == 100 and count("iron-gear-wheel") == 0, "export bus: chest "
		.. tostring(c2 and c2.get_item_count("iron-gear-wheel")) .. ", network " .. count("iron-gear-wheel"))
	local iface = at("me-network-interface", 18.5, 2.5)
	expect(iface and iface.get_item_count("copper-plate") == 50 and iface.get_item_count("stone") == 0 and count("stone") == 30,
		"interface: copper " .. tostring(iface and iface.get_item_count("copper-plate")) .. ", stone in it "
		.. tostring(iface and iface.get_item_count("stone")) .. ", stone in the network " .. count("stone"))
	expect(count("wood") == 77 and c3 and c3.get_item_count("wood") == 77, "storage bus on a chest: network " .. count("wood"))
	local fluids = t and remote.call(NET, "fluid_contents", t) or {}
	expect(math.abs((fluids["crude-oil"] or 0) - 3000) < EPS, "interface on a tank: crude oil in the network " .. tostring(fluids["crude-oil"]))
	expect(math.abs((fluids["lubricant"] or 0) - 4000) < EPS, "storage bus on a tank: lubricant " .. tostring(fluids["lubricant"]))
	local ci = at("me-circuit-interface", 38.5, 2.5)
	local cinfo = ci and remote.call("gregtorio-me-circuit", "get_circuit", ci)
	expect(cinfo and cinfo.signals and cinfo.signals > 0, "circuit interface: " .. serpent.line(cinfo))
	local maint = at("me-level-maintainer", 40.5, 2.5)
	local m = maint and remote.call("gregtorio-me-circuit", "get_maintainer", maint)
	expect(m and m.status and m.status ~= "no-target" and m.stock ~= nil, "level maintainer not checked: " .. serpent.line(m))
	--- me-network issue #128: the terminal and the level maintainer without a pole work in the network that has the power
	local far_t, far_m = at("me-terminal", 60.5, 1.5), at("me-level-maintainer", 61.5, 1.5)
	if remote.interfaces["gregtorio-me-terminal"].problem and far_t then
		expect(remote.call("gregtorio-me-terminal", "problem", far_t) == nil, "the terminal far from every pole: "
			.. tostring(remote.call("gregtorio-me-terminal", "problem", far_t)))
		local sc = remote.interfaces[NET].screen and remote.call(NET, "screen", far_t)
		expect(sc and sc.on and sc.light, "the terminal of the old save has no lit screen: " .. serpent.line(sc))
		local fm = far_m and remote.call("gregtorio-me-circuit", "get_maintainer", far_m)
		expect(fm and fm.status ~= "no-power" and fm.status ~= "no-network" and fm.stock ~= nil, "the level maintainer far from every pole: "
			.. serpent.line(fm))
	end
	--- me-network issue #17: a storage bus and an interface of the old version have no cards and the defaults
	local sbus = remote.interfaces["gregtorio-me-storagebus"]
	if sbus and sbus.card_click then
		local b = at("me-storage-bus", 30.5, 2.5)
		local bi = b and remote.call("gregtorio-me-storagebus", "info", b)
		local bs = b and remote.call("gregtorio-me-storagebus", "get_settings", b)
		expect(bi and bi.max == 18 and next(bi.cards) == nil and bi.extract and not bi.inverted and not bi.fuzzy and not bi.void
			and bi.voided == 0 and bs.extract == nil and bs.cards == nil, "old storage bus not at the defaults: " .. serpent.line(bi))
		expect(iface and remote.call(IO, "get_interface_priority", iface) == 0 and next(remote.call(IO, "get_interface", iface).short) == nil,
			"old interface: priority or shortfalls")
	end
	local ib = at("me-import-bus", 14.5, 2.5)
	if remote.interfaces[IO].schedule then
		local sch = ib and remote.call(IO, "schedule", ib)
		expect(sch and sch.due and sch.due > game.tick, "the import bus has no due tick: " .. serpent.line(sch))
	end
	--- me-network issue #6: the jobs on the three legacy CPUs went on and are done (each 8 copper cables)
	for i, j in ipairs(st.jobs or {}) do
		local info = j.id and remote.call(AC, "job", j.id)
		expect(info and info.status == "done" and info.done == info.total and j.after == j.cpu, "job " .. i .. " on the legacy " .. j.cpu .. ": "
			.. serpent.line(info and { info.status, info.done, info.total, info.wait, j.after }))
	end
	if st.jobs then expect(count("copper-cable") == 24, "copper cables of the three jobs: " .. count("copper-cable")) end
	--- me-network issue #131: the old save's assemblers are one tile now; each stays where its centre was, with its recipe, and the
	--- provider that touched the edge of the 3x3 block is one tile away: its patterns have no machine (a provider window and the
	--- pattern status say so), and the job that ran on it was not left hanging
	if prototypes.entity["me-molecular-assembler"].tile_width == 1 then
		for i, x in ipairs({ 28.5, 32.5, 36.5 }) do
			local prov, asm = at("me-pattern-provider", x, 0.5), at("me-molecular-assembler", x, -1.5)
			local info = prov and remote.call(AC, "provider_info", prov)
			local slot = info and info.slots and info.slots[1]
			expect(asm and asm.valid, "the assembler of provider " .. i .. " is gone")
			expect(slot and slot.reason == "no-machine" and slot.machines == 0 and not slot.ok,
				"provider " .. i .. " still points at an assembler that is one tile too far: " .. serpent.line(slot))
		end
	end
	if st.multi_job then
		--- the job that was waiting for the provider's machine is not lost and not stuck: it waits for a machine ("machine"), holding its
		--- plates, and a new job for the same pattern is refused at once (no pattern with a machine); the player moves the first
		--- assembler next to its provider (the other two stay): the job goes on and ends done
		local info = remote.call(AC, "job", st.multi_job)
		expect(info and info.status == "running" and info.wait == "machine" and info.done == 0,
			"the job of the old save after the load: " .. serpent.line(info and { status = info.status, wait = info.wait, done = info.done }))
		local again, why = remote.call(AC, "start", t, "copper-cable", 8)
		expect(again == nil and why == "no-pattern", "a new job for a pattern without a machine: " .. tostring(again) .. " " .. tostring(why))
		local asm, recipe = at("me-molecular-assembler", 28.5, -1.5), nil
		if asm then
			recipe = asm.get_recipe()
			asm.destroy{ raise_destroy = true }
			local moved = place(s, {}, "me-molecular-assembler", 28.5, -0.5)
			if moved and recipe then moved.set_recipe(recipe) end
			expect(moved ~= nil, "the assembler could not be moved")
		end
		st.recover = { id = st.multi_job, tick = game.tick, cables = count("copper-cable") }
		L("INFO", "the job of the old save after the load: " .. serpent.line(info and { status = info.status, wait = info.wait, done = info.done,
			total = info.total, pool = info.pool }) .. "; a new job: " .. tostring(why))
	end
	--- me-network issue #28: the cards of the old save are items in the script inventories now, none lost or doubled
	if st.cards and remote.interfaces[SB].inventory then
		local bus = at("me-storage-bus", 43.5, 2.5)
		local inv = bus and remote.call(SB, "inventory", bus)
		local bi = bus and remote.call(SB, "info", bus)
		expect(inv and inv.get_item_count("me-capacity-card") == 1 and inv.get_item_count("me-inverter-card") == 1
			and inv[1].valid_for_read and inv[3].valid_for_read and bi.max == 27 and bi.inverted,
			"storage bus cards after the load: " .. serpent.line(inv and inv.get_contents()) .. " " .. serpent.line(bi and bi.cards))
		local WB = "gregtorio-me-workbench"
		local wb = at("me-cell-workbench", 20.5, 8.5)
		local winv = wb and remote.call(WB, "inventory", wb)
		local wi = wb and remote.call(WB, "info", wb)
		local cell = winv and winv[1]
		local tagged = cell and cell.valid_for_read and cell.is_item_with_tags and cell.tags.fork_me_cell
		expect(winv and #winv == 5 and cell.valid_for_read and cell.name == "me-4k-storage-cell" and tagged and not tagged.cards
			and winv.get_item_count("me-inverter-card") == 1 and winv.get_item_count("me-overflow-destruction-card") == 1
			and wi.cell and wi.cell.inverted and wi.cell.void and serpent.line(wi.cell.partition) == serpent.line({ "wood" }),
			"workbench after the load: " .. serpent.line(winv and winv.get_contents()) .. " " .. serpent.line(wi and wi.cell))
	end
	for _, p in pairs(problems) do L("FAIL", p) end
	L("UNIFIED", (#problems == 0 and "ok" or "failed") .. " (a save of unified blocks: buses, interfaces, storage buses, circuit "
		.. "interface and maintainer work after the load" .. (st.jobs and "; the jobs running on the three legacy CPUs are done" or "")
		.. (st.cards and "; the cards of a storage bus and a workbench's cell are items in their inventories" or "") .. ")")
end

script.on_init(function()
	local s = game.surfaces[1]
	s.always_day = true
	s.request_to_generate_chunks({ 30, 10 }, 3)
	s.force_generate_chunk_requests()
	for _, e in pairs(s.find_entities_filtered{ area = AREA }) do
		if e.valid and e.type ~= "character" then e.destroy() end
	end
	local tiles = {}
	for x = AREA[1][1], AREA[2][1] do
		for y = AREA[1][2], AREA[2][2] do tiles[#tiles + 1] = { name = "grass-1", position = { x, y } } end
	end
	s.set_tiles(tiles)
	if unified_old() then setup_unified(s) return end
	local force = game.forces.player
	for _, r in pairs({ "me-fluid-interface", "me-fluid-import-bus", "me-fluid-export-bus", "me-fluid-storage-bus" }) do
		if force.recipes[r] then force.recipes[r].enabled = true end
	end
	local fails = {}
	local eei = place(s, fails, "electric-energy-interface", 2, -4)
	if eei then eei.power_production = 1e7 eei.electric_buffer_size = 1e8 end
	place(s, fails, "substation", 5, -4)
	place(s, fails, "me-network-controller", 9, 0)
	for x = 8, 70 do place(s, fails, "me-cable", x + 0.5, 1.5) end
	local function drive(x, cell, n)
		local d = place(s, fails, "me-drive", x, 0.5)
		local inv = game.create_inventory(1)
		for slot = 1, n do
			inv[1].set_stack{ name = cell, count = 1 }
			if d then remote.call(NET, "insert_cell", d, inv[1], slot) end
		end
		inv.destroy()
		return d
	end
	local di = drive(10.5, "me-16k-storage-cell", 4)
	local df = drive(11.5, "me-1k-fluid-storage-cell", 4)
	local dc = drive(13.5, "me-16k-storage-cell", 1)
	place(s, fails, "me-terminal", 12.5, 0.5)
	if df then remote.call(NET, "store_fluid_in_drive", df, "sulfuric-acid", 640) end
	local south = { direction = defines.direction.south }
	--- the three fluid interfaces
	local fi1 = place(s, fails, "me-fluid-interface", 14.5, 2.5)
	local t1 = place(s, fails, "storage-tank", 15.5, 4.5)            -- its north connection meets FI1
	if t1 then t1.insert_fluid{ name = "crude-oil", amount = 3000 } end
	local fi2 = place(s, fails, "me-fluid-interface", 20.5, 2.5)
	place(s, fails, "pipe", 19.5, 2.5)
	place(s, fails, "pipe", 21.5, 2.5)
	if fi2 then
		remote.call(FL, "set_interface", fi2, "export", "water", 2000)
		fi2.insert_fluid{ name = "water", amount = 1500 }
	end
	local fi3 = place(s, fails, "me-fluid-interface", 24.5, 2.5)
	if fi3 then
		remote.call(FL, "set_interface", fi3, "export", "petroleum-gas", 800)
		fi3.insert_fluid{ name = "petroleum-gas", amount = 300 }
	end
	--- the fluid buses and the fluid storage bus on tanks
	local fib = place(s, fails, "me-fluid-import-bus", 28.5, 2.5, south)
	local t2 = place(s, fails, "storage-tank", 28.5, 4.5)
	if t2 then t2.insert_fluid{ name = "crude-oil", amount = 1000 } end
	if fib then remote.call(IO, "set_bus_filters", fib, { "crude-oil" }) end
	local feb = place(s, fails, "me-fluid-export-bus", 33.5, 2.5, south)
	place(s, fails, "storage-tank", 33.5, 4.5)
	if feb then remote.call(IO, "set_bus_filters", feb, { "water", "steam" }) end
	local fsb = place(s, fails, "me-fluid-storage-bus", 38.5, 2.5, south)
	local t4 = place(s, fails, "storage-tank", 38.5, 4.5)
	if t4 then t4.insert_fluid{ name = "lubricant", amount = 4000 } end
	if fsb then remote.call("gregtorio-me-fluid-storagebus", "set_settings", fsb, { mode = "read", priority = 5, filters = { "lubricant" } }) end
	--- an item ME Interface with a row, a pipe with water on its east side (the new side must not drain it)
	local iface = place(s, fails, "me-network-interface", 43.5, 2.5)
	local pipe = place(s, fails, "pipe", 44.5, 2.5)
	if pipe then pipe.fluidbox[1] = { name = "water", amount = 100 } end
	if iface then remote.call(IO, "set_interface_config", iface, { [1] = { name = "iron-plate", quality = "normal", amount = 10 } }) end
	--- a level maintainer and a pattern provider that name the old items
	local maint = place(s, fails, "me-level-maintainer", 47.5, 2.5)
	if maint then remote.call("gregtorio-me-circuit", "set_maintainer", maint, "me-fluid-import-bus", 3) end
	local prov = place(s, fails, "me-pattern-provider", 49.5, 2.5)
	if prov then
		local inv = game.create_inventory(1)
		for slot, def in ipairs({ { kind = "crafting", recipe = "me-fluid-import-bus" },
			{ kind = "processing", inputs = { { key = "iron-plate", amount = 1 } }, outputs = { { key = "me-fluid-export-bus", amount = 1 } } } }) do
			inv[1].set_stack{ name = "me-encoded-pattern", count = 1, tags = { fork_me_pattern = def } }
			remote.call("gregtorio-me-autocraft", "insert_pattern", prov, inv[1], slot)
		end
		inv.destroy()
	end
	--- ghosts of the four old blocks with their old tags
	local ghosts = {
		{ "me-fluid-interface", 14.5, { fork_me_fluid_interface = { mode = "export", fluid = "water", level = 1234 } } },
		{ "me-fluid-import-bus", 16.5, { fork_me_bus = { filters = { "crude-oil" } } }, defines.direction.east },
		{ "me-fluid-export-bus", 18.5, { fork_me_bus = { filters = { "water" } } } },
		{ "me-fluid-storage-bus", 20.5, { fork_me_fluid_storage_bus = { mode = "write", priority = -2, filters = { "steam" } } } },
	}
	for _, g in ipairs(ghosts) do
		place(s, fails, "entity-ghost", g[2], 8.5, { inner_name = g[1], tags = g[3], direction = g[4], raise_built = false })
	end
	--- the old items: a chest, a blueprint in it, the network's cells, a cell taken out of a drive
	local chest = place(s, fails, "iron-chest", 14.5, 12.5)
	local net_items = 0
	if chest then
		local inv = chest.get_inventory(defines.inventory.chest)
		inv.insert{ name = "me-fluid-interface", count = 3 }
		inv.insert{ name = "me-fluid-import-bus", count = 2 }
		inv.insert{ name = "me-fluid-export-bus", count = 1 }
		inv.insert{ name = "me-fluid-storage-bus", count = 4 }
		inv.insert{ name = "blueprint", count = 1 }
		for i = 1, #inv do
			if inv[i].valid_for_read and inv[i].name == "blueprint" then
				inv[i].set_blueprint_entities({
					{ entity_number = 1, name = "me-fluid-interface", position = { 0.5, 0.5 },
						tags = { fork_me_fluid_interface = { mode = "export", fluid = "steam", level = 99 } } },
					{ entity_number = 2, name = "me-fluid-storage-bus", position = { 2.5, 0.5 }, direction = defines.direction.south,
						tags = { fork_me_fluid_storage_bus = { mode = "readwrite", priority = 1, filters = { "water" } } } },
					{ entity_number = 3, name = "me-cable", position = { 1.5, 0.5 } },
				})
			end
		end
		if dc then
			remote.call(NET, "store_in_drive", dc, "me-fluid-export-bus", 2)
			remote.call(NET, "take_cell", dc, 1, inv)
		end
	end
	if di then net_items = remote.call(NET, "store_in_drive", di, "me-fluid-storage-bus", 5) end
	storage.mig = {
		before = fluid_totals(s),
		net_items = net_items,
		fails = fails,
	}
	L("SETUP", (#fails == 0 and "ok" or "failed") .. " (" .. #fails .. " problems; fluid " .. string.format("%.1f", sum(storage.mig.before))
		.. " units)" .. (#fails > 0 and (": " .. table.concat(fails, "; ")) or ""))
end)

--------------------------------------------------------------------------------
--- after the update
--------------------------------------------------------------------------------

local function check(problems)
	local s = game.surfaces[1]
	local function expect(ok, what) if not ok then problems[#problems + 1] = what end end
	local function at(name, x, y) return s.find_entity(name, { x, y }) end
	--- no old entity, ghost or item left
	for _, name in pairs({ "me-fluid-interface", "me-fluid-import-bus", "me-fluid-export-bus", "me-fluid-storage-bus" }) do
		expect(s.count_entities_filtered{ name = name } == 0, "an old " .. name .. " is left")
		expect(s.count_entities_filtered{ ghost_name = name } == 0, "a ghost of an old " .. name .. " is left")
	end
	--- the interfaces
	local i1, i2, i3 = at("me-network-interface", 14.5, 2.5), at("me-network-interface", 20.5, 2.5), at("me-network-interface", 24.5, 2.5)
	expect(i1 and i2 and i3, "the fluid interfaces were not replaced")
	if i1 and i2 and i3 then
		expect(next(remote.call(IO, "get_interface_config", i1)) == nil and next(remote.call(IO, "get_interface_sides", i1)) == nil,
			"import interface: " .. serpent.line(remote.call(IO, "get_interface_config", i1)))
		local c2, s2 = remote.call(IO, "get_interface_config", i2), remote.call(IO, "get_interface_sides", i2)
		expect(c2[1] and c2[1].type == "fluid" and c2[1].name == "water" and c2[1].amount == 2000 and serpent.line(s2) == serpent.line({ 1, 1, 1, 1 }),
			"export interface: " .. serpent.line(c2) .. " " .. serpent.line(s2))
		local c3 = remote.call(IO, "get_interface_config", i3)
		expect(c3[1] and c3[1].name == "petroleum-gas" and c3[1].amount == 800, "export interface alone: " .. serpent.line(c3))
		local t1 = remote.call(IO, "interface_tanks", i1)
		expect(t1 and #t1 == 4 and #t1[3].fluidbox.get_connections(1) > 0, "the import interface's south side is not connected to the tank")
	end
	--- the buses
	local ib, eb, sb = at("me-import-bus", 28.5, 2.5), at("me-export-bus", 33.5, 2.5), at("me-storage-bus", 38.5, 2.5)
	expect(ib and ib.direction == defines.direction.south and serpent.line(remote.call(IO, "get_bus", ib).filters) == serpent.line({ "fluid/crude-oil" }),
		"import bus: " .. serpent.line(ib and remote.call(IO, "get_bus", ib)))
	expect(eb and serpent.line(remote.call(IO, "get_bus", eb).filters) == serpent.line({ "fluid/water", "fluid/steam" }),
		"export bus: " .. serpent.line(eb and remote.call(IO, "get_bus", eb)))
	local ss = sb and remote.call(SB, "get_settings", sb)
	expect(ss and ss.mode == "read" and ss.priority == 5 and serpent.line(ss.filters) == serpent.line({ "fluid/lubricant" }),
		"storage bus: " .. serpent.line(ss))
	local si = sb and remote.call(SB, "info", sb)
	expect(si and si.side == "fluid" and si.fluid == "lubricant", "storage bus info: " .. serpent.line(si))
	--- the item interface next to the old pipe: its east side is off
	local iface = at("me-network-interface", 43.5, 2.5)
	local sides = iface and remote.call(IO, "get_interface_sides", iface)
	local conf = iface and remote.call(IO, "get_interface_config", iface)
	expect(sides and sides[2] == "off" and conf[1] and conf[1].name == "iron-plate", "item interface next to a pipe: " .. serpent.line(sides) .. " " .. serpent.line(conf))
	--- the maintainer and the patterns
	local maint = at("me-level-maintainer", 47.5, 2.5)
	local m = maint and remote.call("gregtorio-me-circuit", "get_maintainer", maint)
	expect(m and m.key == "me-import-bus", "maintainer: " .. serpent.line(m))
	local prov = at("me-pattern-provider", 49.5, 2.5)
	local pi = prov and remote.call("gregtorio-me-autocraft", "provider_info", prov)
	expect(pi and pi.slots[1] and pi.slots[1].recipe == "me-import-bus" and pi.slots[2] and pi.slots[2].outputs
		and pi.slots[2].outputs[1].key == "me-export-bus", "patterns: " .. serpent.line(pi and pi.slots))
	--- the ghosts with their settings in the tags
	local function ghost(x) return s.find_entities_filtered{ type = "entity-ghost", position = { x, 8.5 } }[1] end
	local g1, g2, g3, g4 = ghost(14.5), ghost(16.5), ghost(18.5), ghost(20.5)
	expect(g1 and g1.ghost_name == "me-network-interface" and g1.tags and g1.tags.fork_me_interface
		and g1.tags.fork_me_interface.config[1].amount == 1234, "interface ghost: " .. serpent.line(g1 and g1.tags))
	expect(g2 and g2.ghost_name == "me-import-bus" and g2.direction == defines.direction.east and g2.tags
		and g2.tags.fork_me_bus.filters[1] == "fluid/crude-oil", "import bus ghost: " .. serpent.line(g2 and g2.tags))
	expect(g3 and g3.ghost_name == "me-export-bus" and g3.tags and g3.tags.fork_me_bus.filters[1] == "fluid/water",
		"export bus ghost: " .. serpent.line(g3 and g3.tags))
	expect(g4 and g4.ghost_name == "me-storage-bus" and g4.tags and g4.tags.fork_me_storage_bus
		and g4.tags.fork_me_storage_bus.mode == "write" and g4.tags.fork_me_storage_bus.filters[1] == "fluid/steam",
		"storage bus ghost: " .. serpent.line(g4 and g4.tags))
	--- the items
	local chest = at("iron-chest", 14.5, 12.5)
	local inv = chest and chest.get_inventory(defines.inventory.chest)
	if inv then
		local want = { ["me-interface"] = 3, ["me-import-bus"] = 2, ["me-export-bus"] = 1, ["me-storage-bus"] = 4 }
		for name, n in pairs(want) do expect(inv.get_item_count(name) == n, "chest: " .. inv.get_item_count(name) .. " " .. name) end
		for _, name in pairs({ "me-fluid-interface", "me-fluid-import-bus", "me-fluid-export-bus", "me-fluid-storage-bus" }) do
			expect(inv.get_item_count(name) == 0, "chest: old items " .. name)
		end
		for i = 1, #inv do
			local st = inv[i]
			if st.valid_for_read and st.is_blueprint then
				local ents = st.get_blueprint_entities() or {}
				local names = {}
				for _, be in pairs(ents) do names[be.name] = be end
				expect(names["me-network-interface"] and names["me-network-interface"].tags.fork_me_interface
					and names["me-storage-bus"] and names["me-storage-bus"].tags.fork_me_storage_bus.filters[1] == "fluid/water"
					and not names["me-fluid-interface"], "blueprint: " .. serpent.line(ents))
			end
		end
		--- the cell taken out of the drive (old keys in its tags): put into a drive, it holds the unified item
		local dc = at("me-drive", 13.5, 0.5)
		for i = 1, #inv do
			if inv[i].valid_for_read and inv[i].name == "me-16k-storage-cell" and dc then
				remote.call(NET, "insert_cell", dc, inv[i], 2)
			end
		end
	else
		expect(false, "the item chest is gone")
	end
	--- no recipe and no technology for the old blocks
	for _, name in pairs({ "me-fluid-interface", "me-fluid-import-bus", "me-fluid-export-bus", "me-fluid-storage-bus" }) do
		expect(game.forces.player.recipes[name] == nil, "the recipe " .. name .. " still exists")
	end
end

script.on_configuration_changed(function()
	local st = storage.mig
	if not st or st.checked or st.unified then return end
	st.checked = true
	local problems = {}
	check(problems)
	local after = fluid_totals(game.surfaces[1])
	local ok, diff = same_totals(st.before, after)
	if not ok then problems[#problems + 1] = "fluid differs after the update: " .. diff end
	st.after_tick = game.tick + 150
	for _, p in pairs(problems) do L("FAIL", p) end
	L("UNIFIED", (#problems == 0 and "ok" or "failed") .. " (fluid " .. string.format("%.1f", sum(st.before)) .. " units before, "
		.. string.format("%.1f", sum(after)) .. " after)")
end)

script.on_nth_tick(10, function()
	local st = storage.mig
	if st and st.unified then
		if not st.start then                                    -- issue #6: the CPU each job runs on after the load
			for _, j in ipairs(st.jobs or {}) do
				local info = j.id and remote.call(AC, "job", j.id)
				j.after = info and info.cpu_name
			end
		end
		st.start = st.start or game.tick
		--- issue #131: 100 ticks after the player moved the assembler, the job of the old save has gone on and ended
		if st.recover and not st.recovered and game.tick >= st.recover.tick + 100 then
			st.recovered = true
			local info = remote.call(AC, "job", st.recover.id)
			local t = game.surfaces[1].find_entity("me-terminal", { 12.5, 0.5 })
			local made = (t and remote.call(NET, "count", t, "copper-cable") or 0) - st.recover.cables
			if not (info and info.status == "done" and made == 8) then
				L("FAIL", "the job of the old save after the assembler was moved: " .. serpent.line(info and { info.status, info.wait, info.done }) .. ", cables made " .. made)
			end
			L("RECOVER", ((info and info.status == "done" and made == 8) and "ok" or "failed") .. " (the job that waited for a machine went on when the assembler was moved next to its provider: "
				.. tostring(info and info.status) .. ", " .. made .. " copper cables)")
		end
		if st.ticked or game.tick < st.start + 150 then return end
		st.ticked = true
		check_unified(st)
		local after = fluid_totals(game.surfaces[1])
		local ok, diff = same_totals(st.before, after)
		if not ok then L("FAIL", "fluid differs: " .. diff) end
		L("FLUIDS", (ok and "ok" or "failed") .. " (" .. string.format("%.1f", sum(st.before)) .. " units before, "
			.. string.format("%.1f", sum(after)) .. " after)")
		return
	end
	if not (st and st.after_tick) or st.ticked or game.tick < st.after_tick then return end
	st.ticked = true
	local s = game.surfaces[1]
	local problems = {}
	local after = fluid_totals(s)
	local ok, diff = same_totals(st.before, after)
	if not ok then problems[#problems + 1] = "fluid differs after the I/O steps: " .. diff end
	--- the network works now (the save was made at tick 0, before the controller had power): its counts
	local function expect(c, what) if not c then problems[#problems + 1] = what end end
	local t = s.find_entity("me-terminal", { 12.5, 0.5 })
	expect(t and remote.call(NET, "count", t, "me-export-bus") == 2 and remote.call(NET, "count", t, "me-fluid-export-bus") == 0,
		"a cell with old items: " .. tostring(t and remote.call(NET, "count", t, "me-export-bus")))
	expect(t and remote.call(NET, "count", t, "me-storage-bus") == storage.mig.net_items
		and remote.call(NET, "count", t, "me-fluid-storage-bus") == 0, "the network's cells: "
		.. tostring(t and remote.call(NET, "count", t, "me-storage-bus")) .. " of " .. storage.mig.net_items
		.. " (network " .. serpent.line(t and remote.call(NET, "network", t)) .. ", drive " .. serpent.line(remote.call(NET, "drive", s.find_entity("me-drive", { 10.5, 0.5 }))) .. ")")
	local pipe = s.find_entity("pipe", { 44.5, 2.5 })
	local seg = pipe and pipe.fluidbox.get_fluid_segment_contents(1) or {}
	if math.abs((seg.water or 0) - 100) > EPS then problems[#problems + 1] = "the pipe next to the old item interface was drained: " .. serpent.line(seg) end
	for _, p in pairs(problems) do L("FAIL", p) end
	L("FLUIDS", (#problems == 0 and "ok" or "failed") .. " (" .. string.format("%.1f", sum(after)) .. " units after the I/O steps)")
end)
