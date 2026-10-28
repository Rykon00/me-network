--------------------------------------------------------------------------------
--- devcheck migrate: a save of an older ME Network loaded with the working copy. Issue #146: only 0.5.0 and later are
--- converted; a save of an older version must be refused when it loads (devcheck.py checks the message), so the helper
--- builds nothing for one. For 0.5.0 and later: every kind of block in its old state (the scenario of issue #5 below).
--------------------------------------------------------------------------------

local NET, IO, FL, SB = "gregtorio-me-network", "gregtorio-me-io", "gregtorio-me-fluids", "gregtorio-me-storagebus"
local AREA = { { -10, -12 }, { 80, 30 } }
local EPS = 0.5

local AC = "gregtorio-me-autocraft"
local LIF = "gregtorio-me-logistic-interface"
local function L(key, msg) log("DEVCHECK-MIGRATE-" .. key .. " " .. msg) end
--- me-network issue #503: the stage of the helper's test items (settings.lua, data.lua)
local ITEMS = settings.startup["zz-me-network-devcheck-migrate-items"].value

local function place(s, fails, name, x, y, extra)
	local def = { name = name, position = { x, y }, force = "player", raise_built = true }
	for k, v in pairs(extra or {}) do def[k] = v end
	local ok, e = pcall(s.create_entity, def)
	if not (ok and e) then fails[#fails + 1] = "place " .. name .. " at " .. x .. "," .. y .. ": " .. tostring(e) return nil end
	return e
end

--- issue #487: the old save is made in the Factorio of its version (2.0: LuaFluidBox) and loaded in 2.1 (the fluid methods
--- of LuaEntity); this helper runs in both. The boxes of `e` as { count, segment id (nil: none), segment fluid
--- { name -> amount }, box fluid }
local major, minor = (script.active_mods.base or "2.0"):match("^(%d+)%.(%d+)")
local V21 = tonumber(major) > 2 or tonumber(minor) >= 1
local function boxes(e)
	if V21 then
		local ok, n = pcall(function() return e.fluids_count end)
		if not (ok and n and n > 0) then return nil end
		return {
			n = n,
			id = function(i) return e.has_fluid_segment(i) and e.get_fluid_segment_id(i) or nil end,
			segment = function(i)
				local f = e.get_fluid_segment_fluid(i)
				return f and { [f.name] = f.amount } or {}
			end,
			get = function(i) return e.get_fluid(i) end,
		}
	end
	local ok, fb = pcall(function() return e.fluidbox end)
	if not (ok and fb and #fb > 0) then return nil end
	return { n = #fb, id = function(i) return fb.get_fluid_segment_id(i) end,
		segment = function(i) return fb.get_fluid_segment_contents(i) end, get = function(i) return fb[i] end }
end

--- fluid in the area (each segment once, boxes without a segment alone) plus in the cells of the drives
local function fluid_totals(s)
	local out, seen = {}, {}
	local function add(name, n) out[name] = (out[name] or 0) + n end
	for _, e in pairs(s.find_entities_filtered{ area = AREA }) do
		local b = boxes(e)
		for i = 1, b and b.n or 0 do
			local id = b.id(i)
			if id then
				if not seen[id] then
					seen[id] = true
					for name, n in pairs(b.segment(i) or {}) do add(name, n) end
				end
			elseif b.get(i) then
				add(b.get(i).name, b.get(i).amount)
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
	--- me-network 0.5.11: an underground pair as the old rule built it (the run along the direction), the cables at its
	--- ends and a ghost; the load turns them to the vanilla underground pipe's rule and keeps them connected
	place(s, fails, "me-cable", 70.5, 10.5)
	place(s, fails, "me-underground-cable", 71.5, 10.5, { direction = defines.direction.east })
	place(s, fails, "me-underground-cable", 76.5, 10.5, { direction = defines.direction.west })
	place(s, fails, "me-cable", 77.5, 10.5)
	s.create_entity{ name = "entity-ghost", inner_name = "me-underground-cable", position = { 73.5, 12.5 },
		direction = defines.direction.north, force = "player" }
	local di = drive(10.5, "me-16k-storage-cell")
	local df = drive(11.5, "me-1k-fluid-storage-cell")
	place(s, fails, "me-terminal", 12.5, 0.5)
	if di then
		remote.call(NET, "store_in_drive", di, "iron-gear-wheel", 100)
		remote.call(NET, "store_in_drive", di, "copper-plate", 500)
	end
	if df then remote.call(NET, "store_fluid_in_drive", df, "sulfuric-acid", 640) end
	--- me-network issue #481: damaged stone walls stored by the old version (issue #102: a key of their own whose data holds the
	--- health and the terminal's damage text as `description`)
	local damaged
	if ctrl and remote.interfaces[NET].insert_stack then
		local inv = game.create_inventory(1)
		inv[1].set_stack{ name = "stone-wall", count = 6, health = 0.5 }
		damaged = remote.call(NET, "insert_stack", ctrl, inv[1]) == 6
		if not damaged then fails[#fails + 1] = "damaged stone walls not stored: " .. serpent.line(inv[1].valid_for_read and inv[1].count) end
		inv.destroy()
	end
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
	--- me-network issue #503 (`--removed-items`): the helper's items, which the load removes (devcheck-removed-item) or renames
	--- through ME_NETWORK.replace_item (devcheck-renamed-item -> devcheck-new-item), in a cell (normal and uncommon), a partition,
	--- an export bus's filter, an interface's row, two level maintainers and a circuit interface's filter
	local items
	if ITEMS == "old" and di then
		items = true
		remote.call(NET, "store_in_drive", di, "devcheck-renamed-item", 40)
		remote.call(NET, "store_in_drive", di, "devcheck-new-item", 25)
		remote.call(NET, "store_in_drive", di, "devcheck-removed-item", 30)
		local inv = game.create_inventory(1)
		inv[1].set_stack{ name = "devcheck-renamed-item", count = 5, quality = "uncommon" }
		if not (ctrl and remote.call(NET, "insert_stack", ctrl, inv[1]) == 5) then fails[#fails + 1] = "uncommon renamed items not stored" end
		inv.destroy()
		remote.call(NET, "set_partition", di, 4, { "devcheck-renamed-item", "devcheck-removed-item", "iron-plate" })
		local xb = place(s, fails, "me-export-bus", 52.5, 2.5, south)
		place(s, fails, "iron-chest", 52.5, 3.5)
		if xb then remote.call(IO, "set_bus_filters", xb, { "devcheck-renamed-item", "devcheck-removed-item" }) end
		local xi = place(s, fails, "me-network-interface", 47.5, 2.5)
		if xi then
			remote.call(IO, "set_interface_config", xi, { [1] = { name = "devcheck-renamed-item", quality = "normal", amount = 5 },
				[2] = { name = "devcheck-removed-item", quality = "normal", amount = 5 } })
		end
		local m1 = place(s, fails, "me-level-maintainer", 54.5, 2.5)
		if m1 then remote.call("gregtorio-me-circuit", "set_maintainer", m1, "devcheck-renamed-item", 10) end
		local m2 = place(s, fails, "me-level-maintainer", 55.5, 2.5)
		if m2 then remote.call("gregtorio-me-circuit", "set_maintainer", m2, "devcheck-removed-item", 10) end
		local c2 = place(s, fails, "me-circuit-interface", 56.5, 2.5)
		if c2 then remote.call("gregtorio-me-circuit", "set_circuit_filters", c2, { "devcheck-renamed-item", "devcheck-removed-item" }) end
	end
	--- me-network issue #537: an ME Logistic Interface in a logistic network (a version that has it). Built by a version without
	--- the automatic mode it must be Manual after the load; with `--removed-items` (a save of the working copy) it is in
	--- Automatic mode and a requester of the logistic network asks for the item the load removes: after the load its pass
	--- runs without an error (the game drops that filter)
	local lif
	if prototypes.entity["me-logistic-interface"] then
		place(s, fails, "roboport", 50, -8)
		local e = place(s, fails, "me-logistic-interface", 45.5, 0.5)
		if e then
			lif = { modes = remote.interfaces[LIF].set_mode ~= nil }
			if ITEMS == "old" then
				local rq = place(s, fails, "requester-chest", 49.5, -3.5)
				local p = rq and rq.get_logistic_point(defines.logistic_member_index.logistic_container)
				local sec = p and (p.get_section(1) or p.add_section())
				if sec then sec.set_slot(1, { value = { name = "devcheck-removed-item", quality = "normal", comparator = "=" }, min = 50 }) end
				if lif.modes then remote.call(LIF, "set_mode", e, "auto") end
			end
		end
	end
	--- me-network issue #556: a network of its own that draws 8.12 MW (four 4096x accelerators, a version that has them): until 0.5.10
	--- its controller's buffer was 100 kJ, so it never worked; after the load its buffer follows the draw and it works
	local big
	if prototypes.entity["me-crafting-accelerator-4096x"] then
		local e3 = place(s, fails, "electric-energy-interface", 2, -24)
		if e3 then e3.power_production = 1e7 e3.electric_buffer_size = 1e8 end
		place(s, fails, "substation", 5, -24)
		big = place(s, fails, "me-network-controller", 9, -24) ~= nil
		for i = 1, 4 do place(s, fails, "me-crafting-accelerator-4096x", 9.5 + i, -24.5) end
	end
	--- me-network issue #559: three ME Wireless Links of one frequency (a version that has them): until 0.5.10 a third link of a
	--- frequency linked nothing; after the load the three are one wireless network
	local links
	if prototypes.entity["me-wireless-link"] and remote.interfaces["gregtorio-me-qbridge"] then
		links = true
		for _, x in ipairs({ 0, 30, 60 }) do
			local e = place(s, fails, "electric-energy-interface", x - 6, 22)
			if e then e.power_production = 1e7 e.electric_buffer_size = 1e8 end
			place(s, fails, "substation", x - 3, 22)
			local l = place(s, fails, "me-wireless-link", x + 0.5, 22.5)
			if l then remote.call("gregtorio-me-qbridge", "set_frequency", l, 17) else links = nil end
		end
	end
	storage.mig = { unified = true, before = fluid_totals(s), fails = fails, start = nil, cards = cards, legacy_chest = legacy_chest,
		damaged = damaged, items = items, lif = lif, big = big, links = links }
	L("SETUP", (#fails == 0 and "ok" or "failed") .. " (unified blocks of " .. tostring(script.active_mods["me-network"]) .. "; "
		.. #fails .. " problems; fluid " .. string.format("%.1f", sum(storage.mig.before)) .. " units"
		.. (has_legacy and "; the legacy CPUs" or "") .. (cards and "; cards on a storage bus and a workbench's cell" or "")
		.. (damaged and "; damaged stone walls" or "") .. (big and "; an 8 MW network" or "")
		.. (links and "; three wireless links of one frequency" or "") .. ")"
		.. (#fails > 0 and (": " .. table.concat(fails, "; ")) or ""))
end

--- after the load: what moved (UNIFIED), then the fluid (FLUIDS)
local function check_unified(st)
	local s = game.surfaces[1]
	local function at(name, x, y) return s.find_entity(name, { x, y }) end
	local problems = {}
	local function expect(ok, what) if not ok then problems[#problems + 1] = what end end
	--- me-network 0.5.11: the old underground pair turned and still paired, its ghost turned
	local ua, ub = at("me-underground-cable", 71.5, 10.5), at("me-underground-cable", 76.5, 10.5)
	local ug = s.find_entities_filtered{ ghost_name = "me-underground-cable", position = { 73.5, 12.5 } }[1]
	expect(ua and ub and ua.direction == defines.direction.west and ub.direction == defines.direction.east
		and remote.call(NET, "underground_partner", ua) == ub.unit_number
		and ug and ug.direction == defines.direction.south, "the underground cables of the old save: "
		.. serpent.line({ ua and ua.direction, ub and ub.direction, ug and ug.direction }))
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
	if st.links then
		local l1, l2, l3 = at("me-wireless-link", 0.5, 22.5), at("me-wireless-link", 30.5, 22.5), at("me-wireless-link", 60.5, 22.5)
		local function same(a, b) return a and b and remote.call(NET, "same_network", a, b) end
		expect(same(l1, l2) and same(l1, l3), "the three wireless links of one frequency after the update (issue #559): "
			.. serpent.line({ same(l1, l2), same(l1, l3), l1 and remote.call("gregtorio-me-qbridge", "info", l1) }))
	end
	if st.big then
		local c = at("me-network-controller", 9, -24)
		local n = c and remote.call(NET, "network", c)
		expect(n and n.ok and n.power == 120000 + 4 * 2000000 and math.abs(c.electric_buffer_size - n.power / 60 * 30) < 1,
			"the controller of the 8 MW network after the update (issue #556): " .. serpent.line({ n and n.status, n and n.power,
			c and c.electric_buffer_size }))
	end
	local far_t, far_m = at("me-terminal", 60.5, 1.5), at("me-level-maintainer", 61.5, 1.5)
	if remote.interfaces["gregtorio-me-terminal"].problem and far_t then
		expect(remote.call("gregtorio-me-terminal", "problem", far_t) == nil, "the terminal far from every pole: "
			.. tostring(remote.call("gregtorio-me-terminal", "problem", far_t)))
		local sc = remote.interfaces[NET].screen and remote.call(NET, "screen", far_t)
		expect(sc and sc.on and sc.light, "the terminal of the old save has no lit screen: " .. serpent.line(sc))
		--- me-network issue #258: its screen moved one layer up, above the dark picture the game draws now
		expect(sc and sc.layer == "lower-object-above-shadow", "the terminal screen's layer after the update: " .. serpent.line(sc))
		local fm = far_m and remote.call("gregtorio-me-circuit", "get_maintainer", far_m)
		expect(fm and fm.status ~= "no-power" and fm.status ~= "no-network" and fm.stock ~= nil, "the level maintainer far from every pole: "
			.. serpent.line(fm))
		--- me-network issue #254: the level maintainers of an old save get their picture (their lamp pictures are empty now)
		for _, mm in pairs({ maint, far_m }) do
			local ms = remote.call(NET, "screen", mm)
			expect(ms and ms.on and ms.sprite == "me-level-maintainer-screen-on",
				"a level maintainer of the old save has no lit picture: " .. serpent.line(ms))
		end
		local list_ok, why = remote.call(NET, "screen_list_ok")
		expect(list_ok, "the screen list made for the old save: " .. tostring(why))
		--- me-network issue #267: the drives' lights of the old save (rectangles) are entities now, none left behind
		for _ = 1, 3 do remote.call(NET, "slow_step") end
		local rects = 0
		for _, o in pairs(rendering.get_all_objects("me-network")) do
			if o.valid and o.type == "rectangle" then rects = rects + 1 end
		end
		local lights = game.surfaces[1].count_entities_filtered{ name = "me-drive-light" }
		expect(rects == 0 and lights > 0, "the drives' lights after the update: " .. rects .. " rectangles left, " .. lights
			.. " light entities")
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
	--- me-network issue #481: the old save's damaged key loads as it was, a stack of the same health stored now joins it (the key
	--- of a damaged plain item did not change), the terminal names its health and it comes out at its health
	if st.damaged and t then
		local function walls()
			local out = {}
			for key, n in pairs(remote.call(NET, "contents", t)) do
				if key:find("stone-wall@normal#", 1, true) == 1 then out[#out + 1] = { key = key, n = n } end
			end
			return out
		end
		local old = walls()
		local inv = game.create_inventory(2)
		inv[1].set_stack{ name = "stone-wall", count = 2, health = 0.5 }
		local n = remote.call(NET, "insert_stack", t, inv[1])
		local now = walls()
		expect(#old == 1 and old[1].n == 6, "the damaged stone walls of the old save: " .. serpent.line(old))
		expect(n == 2 and #now == 1 and now[1].n == 8, "damaged stone walls of the same health stored now did not join the old key: "
			.. tostring(n) .. " " .. serpent.line(now))
		if now[1] then
			local desc = remote.call("gregtorio-me-gui", "key_description", now[1].key)
			expect(type(desc) == "table" and desc[1] == "fork-me-net.damaged-item" and desc[2] == 50, "the terminal's text of the old damaged key: "
				.. serpent.line(desc))
			local got = remote.call(NET, "extract_to", t, inv, now[1].key, 8)
			local b = inv[1]
			expect(got == 8 and b.valid_for_read and b.count == 8 and math.abs(b.health - 0.5) < 1e-3, "the old damaged key came out as "
				.. tostring(got) .. " " .. serpent.line(b.valid_for_read and { b.count, b.health }))
		end
		inv.destroy()
	end
	for _, p in pairs(problems) do L("FAIL", p) end
	L("UNIFIED", (#problems == 0 and "ok" or "failed") .. " (a save of unified blocks: buses, interfaces, storage buses, circuit "
		.. "interface and maintainer work after the load" .. (st.legacy_chest and "; legacy CPU items became 1k crafting storages" or "")
		.. (st.cards and "; the cards of a storage bus and a workbench's cell are items in their inventories" or "")
		.. (st.damaged and "; the old damaged key loads, takes new damaged items of its health and comes out at it" or "") .. ")")
end

--- me-network issue #503: after the load the renamed item is the new one everywhere (counts added up, the uncommon ones uncommon),
--- the removed one nowhere, and the circuit interfaces work (one built now too: the crash of the issue was its first write)
local function check_items(st)
	local s = game.surfaces[1]
	local function at(name, x, y) return s.find_entity(name, { x, y }) end
	local problems = {}
	local function expect(ok, what) if not ok then problems[#problems + 1] = what end end
	local t = at("me-terminal", 12.5, 0.5)
	local contents = t and remote.call(NET, "contents", t) or {}
	local old = {}
	for key, n in pairs(contents) do
		local name = key:match("^[^@#]*")
		if name == "devcheck-renamed-item" or name == "devcheck-removed-item" then old[#old + 1] = key .. " " .. n end
	end
	expect(#old == 0, "the network still holds the old items: " .. table.concat(old, ", "))
	local chest, xi = at("iron-chest", 52.5, 3.5), at("me-network-interface", 47.5, 2.5)
	local net_n = contents["devcheck-new-item"] or 0
	local chest_n = chest and chest.get_item_count("devcheck-new-item") or 0
	local xi_n = xi and xi.get_item_count("devcheck-new-item") or 0
	expect(net_n + chest_n + xi_n == 65, "the new item (25 + 40 renamed): network " .. net_n .. ", export bus chest " .. chest_n
		.. ", interface " .. xi_n)
	expect(chest_n > 0, "the export bus filtered on the renamed item exported nothing of the new one")
	expect((contents["devcheck-new-item@uncommon"] or 0) == 5, "the uncommon renamed items: "
		.. tostring(contents["devcheck-new-item@uncommon"]))
	local d = at("me-drive", 10.5, 0.5)
	local part = d and remote.call(NET, "get_partition", d, 4)
	expect(part and serpent.line(part) == serpent.line({ "devcheck-new-item", "iron-plate" }), "the partition: " .. serpent.line(part))
	local xb = at("me-export-bus", 52.5, 2.5)
	local b = xb and remote.call(IO, "get_bus", xb)
	expect(b and serpent.line(b.filters) == serpent.line({ "devcheck-new-item" }), "the export bus's filters: " .. serpent.line(b and b.filters))
	local cfg = xi and remote.call(IO, "get_interface", xi).config
	expect(cfg and cfg[1] and cfg[1].name == "devcheck-new-item" and cfg[1].amount == 5 and cfg[2] == nil,
		"the interface's rows: " .. serpent.line(cfg))
	expect(xi_n > 0, "the interface keeps none of the new item (the export bus takes from the same stock)")
	local m1 = remote.call("gregtorio-me-circuit", "get_maintainer", at("me-level-maintainer", 54.5, 2.5))
	expect(m1 and m1.key == "devcheck-new-item" and m1.amount == 10, "the level maintainer of the renamed item: " .. serpent.line(m1))
	local m2 = remote.call("gregtorio-me-circuit", "get_maintainer", at("me-level-maintainer", 55.5, 2.5))
	expect(m2 and m2.key == nil, "the level maintainer of the removed item: " .. serpent.line(m2))
	local c2 = at("me-circuit-interface", 56.5, 2.5)
	local ci = c2 and remote.call("gregtorio-me-circuit", "get_circuit", c2)
	expect(ci and serpent.line(ci.filters) == serpent.line({ "devcheck-new-item" }), "the circuit interface's filters: " .. serpent.line(ci))
	local fails = {}
	local built = place(s, fails, "me-circuit-interface", 57.5, 2.5)
	local cb = built and remote.call("gregtorio-me-circuit", "get_circuit", built)
	expect(built and #fails == 0 and cb and cb.signals and cb.signals > 0, "a circuit interface built after the load: "
		.. serpent.line(cb) .. " " .. table.concat(fails, "; "))
	local sec = built and built.get_or_create_control_behavior().get_section(1)
	local seen
	for _, f in pairs(sec and sec.filters or {}) do
		if f.value and f.value.name == "devcheck-new-item" and f.value.quality == "normal" then seen = f.min end
	end
	expect((seen or 0) == net_n, "its signal of the new item: " .. tostring(seen) .. " (network " .. net_n .. ")")
	for _, p in pairs(problems) do L("FAIL", p) end
	L("ITEMS", (#problems == 0 and "ok" or "failed") .. " (the renamed item under its new name with the counts added up and its "
		.. "quality, in the partition, the export bus, the interface, the level maintainer and the circuit interface; the removed "
		.. "one nowhere; a circuit interface built after the load writes its signals)")
end

--- me-network issue #537: the ME Logistic Interface after the load (LIF)
local function check_lif(st)
	local s = game.surfaces[1]
	local e = s.find_entity("me-logistic-interface", { 45.5, 0.5 })
	local d = e and remote.call(LIF, "info", e)
	local problems = {}
	local function expect(ok, what) if not ok then problems[#problems + 1] = what end end
	local what
	if not st.lif.modes then
		what = "a block built before the automatic mode is Manual"
		expect(d and d.mode == "manual", "the block of the old version: mode " .. serpent.line(d and d.mode))
	elseif ITEMS == "new" then
		--- (Factorio 2.1.23, measured: the load drops a logistic filter of a removed item from the section; the scan's check
		--- for a name without a prototype is a safety net, and a pass over the point must run without an error)
		what = "a requester of the removed item: its filter dropped by the game, the pass ran, nothing offered or counted"
		local rq = s.find_entity("requester-chest", { 49.5, -3.5 })
		local pt = rq and rq.get_logistic_point(defines.logistic_member_index.logistic_container)
		local sec = pt and pt.get_section(1)
		local demand = remote.call(LIF, "demand")
		expect(sec and #sec.filters == 0, "the game kept the filter of the removed item: " .. serpent.line(sec and sec.filters))
		expect(d and d.mode == "auto" and d.auto_unknown == 0 and d.auto_offered == 0 and demand and demand.auto
			and demand.auto[d.lid], "the block after the load: " .. serpent.line(d and { d.mode, d.auto_unknown, d.auto_offered, d.lid }))
	else
		what = "nothing to check: the save has the automatic mode and no removed item"
	end
	for _, p in pairs(problems) do L("FAIL", p) end
	L("LIF", (#problems == 0 and "ok" or "failed") .. " (" .. what .. ")")
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
		if st.items and ITEMS == "new" then check_items(st) end
		if st.lif then check_lif(st) end
		local after = fluid_totals(game.surfaces[1])
		local ok, diff = same_totals(st.before, after)
		if not ok then L("FAIL", "fluid differs: " .. diff) end
		L("FLUIDS", (ok and "ok" or "failed") .. " (" .. string.format("%.1f", sum(st.before)) .. " units before, "
			.. string.format("%.1f", sum(after)) .. " after)")
		return
	end
end)
