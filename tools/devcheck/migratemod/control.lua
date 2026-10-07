--------------------------------------------------------------------------------
--- devcheck migrate: a save of an older ME Network loaded with the working copy. Issue #146: only 0.5.0 and later are
--- converted; a save of an older version must be refused when it loads (devcheck.py checks the message), so the helper
--- builds nothing for one. For 0.5.0 and later: every kind of block in its old state (the scenario of issue #5 below).
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
--- An old version (0.5.0 and later; issue #5): a save of it has every kind of
--- block in its old state (no queues of the scheduler, no new fields), and when the version number did not change it
--- is loaded without on_configuration_changed. After the load the network must work: the import bus empties its
--- chest, the export bus fills its chest, the interface keeps its row and imports the rest, the interface on a tank
--- imports the tank, the storage buses show the chest and the tank, the circuit interface writes signals, the level
--- maintainer is checked; the fluid is the same before and after.
--------------------------------------------------------------------------------

--- issue #146: a version before the cut-off (0.5.0), whose save the working copy refuses
local function before_cut_off()
	local v = script.active_mods["me-network"] or "0.0.0"
	local a, b = v:match("^(%d+)%.(%d+)")
	return tonumber(a) == 0 and tonumber(b) < 5
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
	--- me-network issue #6: providers with a crafting pattern next to Molecular Assemblers; issue #145: the three legacy CPUs
	--- (no job: a lamp has no power at tick 0) are gone in the working copy, their items in a chest must have become 1k
	--- crafting storages
	--- copper cables are not unlocked at the start with Space Age: its technology researched (the load runs
	--- on_configuration_changed, which resets the technology effects)
	for _, tech in pairs(game.forces.player.technologies) do
		for _, e in pairs(tech.prototype.effects) do
			if e.type == "unlock-recipe" and e.recipe == "copper-cable" then tech.researched = true end
		end
	end
	game.forces.player.recipes["copper-cable"].enabled = true
	for _, x in pairs({ 28.5, 32.5, 36.5 }) do
		local m = place(s, fails, "me-molecular-assembler", x, -0.5)
		local p = place(s, fails, "me-pattern-provider", x, 0.5)
		local inv = game.create_inventory(2)
		inv.insert{ name = "me-blank-pattern", count = 1 }
		remote.call("gregtorio-me-pattern-terminal", "encode_def", inv, nil, { kind = "crafting", recipe = "copper-cable" })
		local stack = inv.find_item_stack("me-encoded-pattern")
		if not (m and p and stack and remote.call(AC, "insert_pattern", p, stack)) then fails[#fails + 1] = "pattern at " .. x end
		inv.destroy()
	end
	local has_legacy = prototypes.entity["me-crafting-cpu"] ~= nil
	local legacy_chest
	if has_legacy then
		legacy_chest = place(s, fails, "iron-chest", 40.5, -2.5)
		for _, name in ipairs({ "me-crafting-cpu", "me-co-processing-cpu", "me-quantum-crafting-cpu" }) do
			if legacy_chest and prototypes.item[name] then legacy_chest.insert{ name = name, count = 1 } end
		end
	end
	for _, cpu in ipairs(has_legacy and { { "me-crafting-cpu", 19 }, { "me-co-processing-cpu", 22 }, { "me-quantum-crafting-cpu", 25 } } or {}) do
		place(s, fails, cpu[1], cpu[2], 0)
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
	storage.mig = { unified = true, before = fluid_totals(s), fails = fails, start = nil, cards = cards, legacy_chest = legacy_chest }
	L("SETUP", (#fails == 0 and "ok" or "failed") .. " (unified blocks of " .. tostring(script.active_mods["me-network"]) .. "; "
		.. #fails .. " problems; fluid " .. string.format("%.1f", sum(storage.mig.before)) .. " units"
		.. (has_legacy and "; the legacy CPUs" or "") .. (cards and "; cards on a storage bus and a workbench's cell" or "") .. ")"
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
	--- issue #145: the legacy CPU items in a chest became 1k crafting storages (migrations/me-network-legacy-cpus.json)
	if st.legacy_chest and not prototypes.entity["me-crafting-cpu"] then
		local c = st.legacy_chest
		expect(c.valid and c.get_item_count("me-1k-crafting-storage") == 3, "the legacy CPU items in the chest: "
			.. (c.valid and serpent.line(c.get_inventory(defines.inventory.chest).get_contents()) or "chest gone"))
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
		.. "interface and maintainer work after the load" .. (st.legacy_chest and "; legacy CPU items became 1k crafting storages" or "")
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
	if before_cut_off() then
		storage.mig = { refused = true }
		L("SETUP", "ok (a save of me-network " .. tostring(script.active_mods["me-network"]) .. ", before the cut-off 0.5.0: the working "
			.. "copy must refuse it, issue #146)")
		return
	end
	setup_unified(s)
end)

script.on_nth_tick(10, function()
	local st = storage.mig
	if st and st.unified then
		st.start = st.start or game.tick
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
end)
