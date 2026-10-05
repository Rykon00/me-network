--- Runtime test of me-network issue #76: what the network stores and refuses. Science packs (prototype type tool), ammo and
--- repair packs have a LuaItem like every item with a state, and `N.storable` took that for "carries data of its own"
--- and refused them. The network takes whole (unused) items of those types now and refuses a used one as damaged; items
--- that carry data of their own are refused with a message that names them. One network with a terminal, a drive,
--- an import bus on a chest, an export bus on a chest, two interfaces and a storage bus on a chest; every path with the
--- same items:
---   the terminal's store, the pane's shift + click and control + click at the terminal and at the other blocks,
---   an import bus (stack by stack), an interface (the stacks it imports, the surplus of a row), an export bus,
---   a storage bus (the chest's full items are the network's, a used stack is not), and what is taken out.
--- Each result is logged as a DEVCHECK-RUNTIME-STORABLE-CENSUS line (the table of docs/ME-REWORK.md). Loaded by control.lua:
--- require("storable")(H) returns { setup, tick, running }.

local NET, TERM, IO, GUI = "gregtorio-me-network", "gregtorio-me-terminal", "gregtorio-me-io", "gregtorio-me-gui"
local BX, BY = 500, -320
local FILL, CHECK1, CHECK2, CHECK3 = 100, 400, 650, 900

local PACK, PACK2, MAG, MAG2, REPAIR = "automation-science-pack", "logistic-science-pack", "firearm-magazine", "piercing-rounds-magazine", "repair-pack"
local SPACK, SMAG = "chemical-science-pack", "shotgun-shell"        -- the storage bus's chest

return function(H)
	local me_place, me_report = H.me_place, H.me_report
	local T = {}
	local SOUTH = { direction = defines.direction.south }

	--- a stack definition; `extra`: durability for a tool or repair pack, ammo for a magazine, health, quality
	local function def(name, count, extra)
		local d = { name = name, count = count }
		for k, v in pairs(extra or {}) do d[k] = v end
		return d
	end

	--- is this stack used (its top item)? Written without the mod's function: the test must not share its mistakes
	local function used(st)
		local p = st.prototype
		if st.health < 1 then return true end
		if p.type == "tool" or p.type == "repair-tool" then
			local full = p.get_durability(st.quality)
			return full ~= nil and st.durability < full
		end
		if p.type == "ammo" then return st.ammo < p.magazine_size end
		return false
	end

	--- the items of `name` and `quality` in an inventory: the count, the count in used stacks, the used stacks
	local function scan(inv, name, quality)
		local n, usedn, stacks = 0, 0, 0
		for i = 1, #inv do
			local st = inv[i]
			if st.valid_for_read and st.name == name and st.quality.name == (quality or "normal") then
				n = n + st.count
				if used(st) then usedn = usedn + st.count stacks = stacks + 1 end
			end
		end
		return n, usedn, stacks
	end

	function T.setup(s)
		local fails = {}
		local what = "storable"
		local eei = me_place(s, fails, what, "electric-energy-interface", BX + 12.5, BY + 6.5)
		if eei then
			eei.power_production = 1e6
			eei.electric_buffer_size = 1e7
		end
		me_place(s, fails, what, "substation", BX + 13, BY + 2)
		local ctrl = me_place(s, fails, what, "me-network-controller", BX + 6, BY)
		local drive = me_drive(s, fails, what, BX + 8.5, BY - 2.5, {}, "256k")
		local term = me_place(s, fails, what, "me-terminal", BX + 12.5, BY - 2.5)
		local ibus = me_place(s, fails, what, "me-import-bus", BX + 1.5, BY + 0.5, SOUTH)
		local ichest = me_place(s, fails, what, "steel-chest", BX + 1.5, BY + 1.5)
		local ibus2 = me_place(s, fails, what, "me-import-bus", BX + 5.5, BY + 0.5, SOUTH)
		local ichest2 = me_place(s, fails, what, "steel-chest", BX + 5.5, BY + 1.5)
		local ebus = me_place(s, fails, what, "me-export-bus", BX + 3.5, BY + 0.5, SOUTH)
		local echest = me_place(s, fails, what, "steel-chest", BX + 3.5, BY + 1.5)
		local sbus = me_place(s, fails, what, "me-storage-bus", BX + 7.5, BY + 0.5, SOUTH)
		local schest = me_place(s, fails, what, "steel-chest", BX + 7.5, BY + 1.5)
		local if1 = me_place(s, fails, what, "me-network-interface", BX + 4.5, BY - 2.5)
		local if2 = me_place(s, fails, what, "me-network-interface", BX + 5.5, BY - 2.5)
		me_connect(fails, what, { ctrl, drive, term, ibus, ibus2, ebus, sbus, if1, if2 })
		storage.storable76_scene = { ctrl = ctrl, term = term, ibus = ibus, ichest = ichest, ibus2 = ibus2, ichest2 = ichest2, ebus = ebus, echest = echest,
			sbus = sbus, schest = schest, if1 = if1, if2 = if2 }
		return fails
	end

	function T.tick()
		local tick = game.tick
		local sc = storage.storable76_scene
		local st = storage.storable76
		if not st then
			if tick < FILL or not sc then return end
			st = { problems = {}, done = false, phase = 0, base = {} }
			storage.storable76 = st
		end
		if st.done then return end
		local problems = st.problems
		local function expect(ok, text) if not ok then problems[#problems + 1] = text end end
		local function note(path, case, result) log("DEVCHECK-RUNTIME-STORABLE-CENSUS " .. path .. " | " .. case .. " | " .. tostring(result)) end
		for _, e in pairs(sc) do
			if not e.valid then
				problems[#problems + 1] = "the test network was not built"
				st.done = true
				me_report("STORABLE", "ME storable items", problems, "no network")
				return
			end
		end
		local t = sc.term
		local function count(name, quality) return remote.call(NET, "count", t, name, quality) end
		local function key_of(name, quality) return (quality and quality ~= "normal") and (name .. "@" .. quality) or name end

		-------------------------------------------------------------------------------------------------------------
		--- phase 1: the clicks and the functions of the terminal, and the contents of the chests and interfaces
		-------------------------------------------------------------------------------------------------------------
		if st.phase == 0 then
			st.phase = 1
			local pinv, hold = game.create_inventory(40), game.create_inventory(1)
			local function click(e, slot, mode, window) return remote.call(GUI, "inventory_click", hold[1], pinv, slot, mode, e, window) end
			local function reset() pinv.clear() hold.clear() end
			local function terminal_store()
				local _, why = remote.call(TERM, "store_stack", t, pinv[1])
				return why
			end

			--- what goes in and comes out again, by path: the count that went in is the count that comes out
			local function round_trip(path, name, quality, n, put)
				reset()
				pinv[1].set_stack(def(name, n, { quality = quality }))
				local before = count(name, quality)
				local why = put()
				local went = count(name, quality) - before
				local case = name .. (quality and quality ~= "normal" and ("@" .. quality) or "") .. " x" .. n .. " full"
				note(path, case, "stored " .. went .. ", reason " .. tostring(why))
				expect(why == nil and went == n and pinv[1].valid_for_read == false, path .. ": " .. n .. " " .. name .. " (" .. (quality or "normal")
					.. ") were not stored: " .. tostring(why) .. ", " .. went .. " in the network")
				local got = remote.call(TERM, "take", hold[1], pinv, t, key_of(name, quality), "inventory")
				local total, usedn = scan(pinv, name, quality)
				note(path, case .. ", taken out", "took " .. tostring(got) .. ", inventory holds " .. total .. ", used " .. usedn)
				expect(got == n and total == n and usedn == 0 and count(name, quality) == before, path .. ": " .. n .. " " .. name .. " came out as "
					.. tostring(got) .. " (inventory " .. total .. ", used " .. usedn .. ", network " .. count(name, quality) .. " of " .. before .. ")")
			end
			for _, case in ipairs({ { PACK, "normal", 20 }, { MAG, "normal", 30 }, { REPAIR, "normal", 10 }, { PACK, "legendary", 7 },
				{ "pistol", "normal", 1 }, { "iron-plate", "normal", 40 } }) do
				if prototypes.item[case[1]] and prototypes.quality[case[2]] then
					round_trip("terminal store", case[1], case[2], case[3], terminal_store)
					round_trip("pane shift + click at the terminal", case[1], case[2], case[3], function() return click(t, 1, "shift") end)
					round_trip("pane shift + click at the controller", case[1], case[2], case[3], function() return click(sc.ctrl, 1, "shift") end)
				end
			end
			--- the cursor: a click with a stack in hand stores it, a right click adds one of the same from the network
			reset()
			hold[1].set_stack(def(PACK, 5))
			local before = count(PACK)
			local n = remote.call(TERM, "take", hold[1], pinv, t, PACK, "stack")
			note("terminal click with a stack in hand", PACK .. " x5 full", "returned " .. tostring(n))
			expect(n == -5 and not hold[1].valid_for_read and count(PACK) == before + 5, "a click with five packs in hand: " .. tostring(n))
			remote.call(TERM, "take", hold[1], pinv, t, PACK, "one")
			expect(hold[1].valid_for_read and hold[1].count == 1 and not used(hold[1]), "one pack taken into the hand: " .. (hold[1].valid_for_read and hold[1].count or "nothing"))
			remote.call(TERM, "take", hold[1], pinv, t, PACK, "one")
			expect(hold[1].valid_for_read and hold[1].count == 2 and not used(hold[1]), "one more pack into the hand: " .. (hold[1].valid_for_read and hold[1].count or "nothing"))
			remote.call(TERM, "take", hold[1], pinv, t, PACK, "stack")        -- (stores the hand)
			expect(not hold[1].valid_for_read and count(PACK) == before + 5, "the hand's packs stored again: " .. count(PACK))
			--- a used stack in hand is refused and a "one more" does not add to it
			hold[1].set_stack(def(PACK, 2, { durability = 0.5 }))
			local n2, why2 = remote.call(TERM, "take", hold[1], pinv, t, PACK, "stack")
			expect(n2 == nil and why2 == "cannot-store-damaged" and hold[1].count == 2 and hold[1].durability == 0.5, "used packs in hand: " .. tostring(n2) .. " " .. tostring(why2))
			remote.call(TERM, "take", hold[1], pinv, t, PACK, "one")
			expect(hold[1].count == 2 and hold[1].durability == 0.5, "one pack added to a used stack in hand")
			hold.clear()
			remote.call(NET, "extract", t, PACK, 5)

			--- control + click: every stack of that item, the used one in front of the full ones does not stop it
			for _, path in ipairs({ { "pane control + click at the terminal", t }, { "pane control + click at the interface", sc.if1 } }) do
				reset()
				pinv[1].set_stack(def(REPAIR, 3, { durability = 100 }))
				pinv[2].set_stack(def(REPAIR, 6))
				pinv[3].set_stack(def(REPAIR, 4))
				local b = count(REPAIR)
				local why = click(path[2], 2, "control")
				local total, usedn = scan(pinv, REPAIR)
				note(path[1], REPAIR .. " 3 used (first), 6 + 4 full", "reason " .. tostring(why) .. ", stored " .. (count(REPAIR) - b) .. ", inventory keeps " .. total .. " (used " .. usedn .. ")")
				expect(count(REPAIR) == b + 10 and total == 3 and usedn == 3, path[1] .. ": repair packs " .. (count(REPAIR) - b) .. " stored, " .. total .. " left, " .. usedn .. " of them used")
				remote.call(NET, "extract", t, REPAIR, 10)
			end

			--- used items are refused with the existing message and stay as they were
			local USED = {
				{ PACK, def(PACK, 5, { durability = 0.5 }), "used science packs" }, { MAG, def(MAG, 5, { ammo = 3 }), "used magazines" },
				{ REPAIR, def(REPAIR, 5, { durability = 100 }), "used repair packs" },
			}
			for _, case in ipairs(USED) do
				for _, path in ipairs({ "terminal store", "pane shift + click at the terminal", "pane shift + click at the controller" }) do
					reset()
					pinv[1].set_stack(case[2])
					local b = count(case[1])
					local why
					if path == "terminal store" then why = terminal_store()
					elseif path == "pane shift + click at the terminal" then why = click(t, 1, "shift")
					else why = click(sc.ctrl, 1, "shift") end
					note(path, case[3], "reason " .. tostring(why) .. ", stack " .. (pinv[1].valid_for_read and (pinv[1].count .. " kept") or "gone"))
					expect(why == "cannot-store-damaged" and pinv[1].valid_for_read and pinv[1].count == case[2].count and count(case[1]) == b and used(pinv[1]),
						path .. ": " .. case[3] .. " were refused as " .. tostring(why) .. ", " .. (pinv[1].valid_for_read and pinv[1].count or "no") .. " left")
				end
			end

			--- items that carry data of their own are refused, each with its reason
			local OWN = {
				{ "blueprint", "cannot-store-blueprint" }, { "blueprint-book", "cannot-store-blueprint" },
				{ "deconstruction-planner", "cannot-store-planner" }, { "upgrade-planner", "cannot-store-planner" },
				{ "copy-paste-tool", "cannot-store-planner" }, { "zz-devcheck-selection-tool", "cannot-store-planner" },
				{ "spidertron-remote", "cannot-store-remote" }, { "car", "cannot-store-entity" }, { "locomotive", "cannot-store-entity" },
				{ "modular-armor", "cannot-store-armor" }, { "light-armor", "cannot-store-armor" },
				{ "zz-devcheck-inventory-item", "cannot-store-inventory" }, { "zz-devcheck-label-item", "cannot-store-label", true },
				{ "me-4k-storage-cell", "cannot-store-label", true },
			}
			for _, case in ipairs(OWN) do
				local name, reason, labelled = case[1], case[2], case[3]
				if prototypes.item[name] then
					reset()
					pinv[1].set_stack{ name = name, count = 1 }
					if name == "modular-armor" then pinv[1].grid.put{ name = "battery-equipment" } end
					if labelled then pinv[1].label = "named by a player" end
					local why = terminal_store()
					local why2 = click(t, 1, "shift")
					note("terminal store and shift + click", name .. (labelled and " with a label" or ""), "reason " .. tostring(why) .. " / " .. tostring(why2))
					expect(why == reason and why2 == reason and pinv[1].valid_for_read, name .. " was refused as " .. tostring(why) .. " / " .. tostring(why2) .. ", not " .. reason)
				end
			end
			--- an item with tags still goes in with its tags and comes out with them
			reset()
			pinv[1].set_stack{ name = "me-4k-storage-cell", count = 1 }
			pinv[1].tags = { fork_me_test = 7 }
			local why = terminal_store()
			local found
			for _, e in pairs(remote.call(TERM, "entries", t, "", "count", "items")) do
				if e.name == "me-4k-storage-cell" and e.key:find("#", 1, true) then found = e.key end
			end
			expect(why == nil and found, "a cell with tags: " .. tostring(why) .. " " .. tostring(found))
			if found then
				remote.call(TERM, "take", hold[1], pinv, t, found, "stack")
				expect(hold[1].valid_for_read and hold[1].tags and hold[1].tags.fork_me_test == 7, "a cell with tags came back without them")
				hold.clear()
				remote.call(NET, "extract", t, found, 1)
			end
			reset()
			pinv.destroy()
			hold.destroy()

			-----------------------------------------------------------------------------------------------------
			--- the chests and interfaces, filled for the visits of the buses and interfaces
			-----------------------------------------------------------------------------------------------------
			local base = st.base
			for _, name in ipairs({ PACK, PACK2, MAG, MAG2, REPAIR, SPACK, SMAG, "iron-plate" }) do base[name] = count(name) end
			base.legendary = count(PACK, "legendary")
			base.uncommon = count(REPAIR, "uncommon")
			--- the import bus's chest: full and used stacks of everything, and what the network refuses; every tool of the game once
			local ic = sc.ichest.get_inventory(defines.inventory.chest)
			local slots = {
				def(PACK, 20), def(PACK, 5, { durability = 0.5 }), def(MAG, 30), def(MAG, 5, { ammo = 3 }), def(REPAIR, 10),
				def(REPAIR, 5, { durability = 100 }), { name = "blueprint", count = 1 },
				{ name = "blueprint-book", count = 1 }, def("iron-plate", 50), { name = "car", count = 1 }, { name = "light-armor", count = 1 },
			}
			if prototypes.quality["legendary"] then slots[#slots + 1] = def(PACK, 7, { quality = "legendary" }) end
			local i = 1
			for _, d in ipairs(slots) do ic[i].set_stack(d) i = i + 1 end
			st.tools = {}
			local names = {}
			for name, p in pairs(prototypes.item) do
				if p.type == "tool" and p.get_spoil_ticks("normal") == 0 and name ~= PACK and name ~= PACK2 and name ~= SPACK then names[#names + 1] = name end
			end
			table.sort(names)
			for _, name in ipairs(names) do
				ic[i].set_stack(def(name, 3))
				st.tools[#st.tools + 1] = name
				base["tool:" .. name] = count(name)
				i = i + 1
			end
			--- the first interface: what it imports by itself (stack by stack)
			local f1 = sc.if1.get_inventory(defines.inventory.chest)
			f1[1].set_stack(def(PACK2, 15))
			f1[2].set_stack(def(PACK2, 4, { durability = 0.25 }))
			f1[3].set_stack(def(MAG2, 12))
			f1[4].set_stack(def(MAG2, 3, { ammo = 4 }))
			f1[5].set_stack(def(REPAIR, 6, { quality = "uncommon" }))
			f1[6].set_stack{ name = "blueprint", count = 1 }
			--- the second interface: a row of 5 science packs holds 5 used and 5 full ones (the used stack first): the surplus is
			--- the full ones
			local f2 = sc.if2.get_inventory(defines.inventory.chest)
			f2[1].set_stack(def(PACK, 5, { durability = 0.5 }))
			f2[2].set_stack(def(PACK, 5))
			remote.call(IO, "set_interface_slot", sc.if2, 1, PACK, "normal", 5)
			--- the storage bus's chest: 20 full and 5 used packs, 10 full and 5 used shells
			local sci = sc.schest.get_inventory(defines.inventory.chest)
			sci[1].set_stack(def(SPACK, 20))
			sci[2].set_stack(def(SPACK, 5, { durability = 0.5 }))
			sci[3].set_stack(def(SMAG, 10))
			sci[4].set_stack(def(SMAG, 5, { ammo = 4 }))
			remote.call(IO, "set_bus_filters", sc.ibus, {})                   -- (every item)
			remote.call(IO, "set_bus_filters", sc.ibus2, {})
			return
		end

		-------------------------------------------------------------------------------------------------------------
		--- phase 2: the import bus, the interfaces and the storage bus have had their visits
		-------------------------------------------------------------------------------------------------------------
		if st.phase == 1 and tick >= CHECK1 then
			st.phase = 2
			local base = st.base
			local function delta(name, quality) return count(name, quality) - (quality == "legendary" and base.legendary or quality == "uncommon" and base.uncommon or base[name] or 0) end
			local ic = sc.ichest.get_inventory(defines.inventory.chest)
			--- the import bus
			local function chest(name, quality, what, want_n, want_used, want_stacks)
				local n, usedn, stacks = scan(ic, name, quality)
				note("import bus on a chest", what, "network +" .. delta(name, quality) .. ", chest keeps " .. n .. " (used " .. usedn .. ")")
				expect(delta(name, quality) == want_n, "import bus: " .. what .. ": " .. delta(name, quality) .. " in the network, expected " .. want_n)
				expect(n == want_used and usedn == want_used and stacks == want_stacks, "import bus: " .. what .. ": the chest keeps " .. n .. " (used " .. usedn .. "), expected " .. want_used .. " used")
			end
			chest(PACK, "normal", PACK .. " 20 full + 5 used (+ 5 from the second interface's row)", 25, 5, 1)
			chest(MAG, "normal", MAG .. " 30 full + 5 used", 30, 5, 1)
			chest(REPAIR, "normal", REPAIR .. " 10 full + 5 used", 10, 5, 1)
			if prototypes.quality["legendary"] then chest(PACK, "legendary", PACK .. " 7 full, legendary", 7, 0, 0) end
			expect(delta("iron-plate") == 50 and scan(ic, "iron-plate") == 0, "import bus: iron plates by count: " .. delta("iron-plate"))
			local kept = {}
			for i = 1, #ic do if ic[i].valid_for_read then kept[ic[i].name] = (kept[ic[i].name] or 0) + ic[i].count end end
			note("import bus on a chest", "blueprint, blueprint-book, car, light-armor", "left in the chest: " .. serpent.line(kept, { comment = false }))
			expect(kept["blueprint"] == 1 and kept["blueprint-book"] == 1 and kept["car"] == 1 and kept["light-armor"] == 1,
				"import bus: what carries data stays in the chest: " .. serpent.line(kept, { comment = false }))
			local all_in = true
			for _, name in ipairs(st.tools) do
				local in_net, left = count(name) - base["tool:" .. name], scan(ic, name)
				if in_net ~= 3 or left ~= 0 then all_in = false end
				expect(in_net == 3 and left == 0, "import bus: 3 " .. name .. " (every tool of the game): " .. in_net .. " in the network, " .. left .. " left in the chest")
			end
			note("import bus on a chest", #st.tools .. " other tools (science packs) x3 full", "all went in: " .. tostring(all_in))
			--- the first interface imports the stacks itself
			local f1 = sc.if1.get_inventory(defines.inventory.chest)
			local function iface(name, quality, what, want_n, want_used)
				local n, usedn = scan(f1, name, quality)
				note("interface (stacks it imports)", what, "network +" .. delta(name, quality) .. ", interface keeps " .. n .. " (used " .. usedn .. ")")
				expect(delta(name, quality) == want_n and n == want_used and usedn == want_used, "interface: " .. what .. ": " .. delta(name, quality) .. " in the network, "
					.. n .. " (used " .. usedn .. ") kept, expected " .. want_n .. " and " .. want_used .. " used")
			end
			iface(PACK2, "normal", PACK2 .. " 15 full + 4 used", 15, 4)
			iface(MAG2, "normal", MAG2 .. " 12 full + 3 used", 12, 3)
			iface(REPAIR, "uncommon", REPAIR .. " 6 full, uncommon", 6, 0)
			expect(scan(f1, "blueprint") == 1, "interface: the blueprint stays")
			--- the second interface: a row of 5 packs; the surplus is the full stack, the used one stays
			local f2 = sc.if2.get_inventory(defines.inventory.chest)
			local n2, used2 = scan(f2, PACK)
			note("interface (surplus of a row)", PACK .. " row of 5; 5 used first, 5 full", "network +" .. (count(PACK) - base[PACK]) .. " (20 of them from the import bus), interface keeps " .. n2 .. " (used " .. used2 .. ")")
			expect(n2 == 5 and used2 == 5, "interface surplus: the row's used packs were stored as full ones: the interface keeps " .. n2 .. " (used " .. used2 .. ")")
			expect(count(PACK) == base[PACK] + 20 + 5, "interface surplus: " .. (count(PACK) - base[PACK]) .. " packs in the network, 25 expected (import bus 20, surplus 5)")
			--- the storage bus: the chest's full items are the network's, the used stack is not
			local sch = sc.schest.get_inventory(defines.inventory.chest)
			note("storage bus on a chest", SPACK .. " 20 full + 5 used", "the network counts " .. count(SPACK))
			note("storage bus on a chest", SMAG .. " 10 full + 5 used", "the network counts " .. count(SMAG))
			expect(count(SPACK) == 20, "storage bus: the network counts " .. count(SPACK) .. " " .. SPACK .. ", the chest holds 20 full and 5 used")
			expect(count(SMAG) == 10, "storage bus: the network counts " .. count(SMAG) .. " " .. SMAG .. ", the chest holds 10 full and 5 used")
			--- taking them out takes the full ones, the used ones stay in the chest
			local pinv, hold = game.create_inventory(10), game.create_inventory(1)
			local got = remote.call(TERM, "take", hold[1], pinv, t, SPACK, "inventory")
			local total, usedn = scan(pinv, SPACK)
			local left, left_used = scan(sch, SPACK)
			note("storage bus on a chest", SPACK .. ", taken out at the terminal", "took " .. tostring(got) .. " (used " .. usedn .. "), the chest keeps " .. left .. " (used " .. left_used .. ")")
			expect(got == 20 and total == 20 and usedn == 0 and left == 5 and left_used == 5, "storage bus: taking packs out gave " .. tostring(got) .. " (used " .. usedn .. "), the chest keeps " .. left .. " (used " .. left_used .. ")")
			local got2 = remote.call(TERM, "take", hold[1], pinv, t, SMAG, "inventory")
			local total2, usedn2 = scan(pinv, SMAG)
			local left2, left_used2 = scan(sch, SMAG)
			expect(got2 == 10 and total2 == 10 and usedn2 == 0 and left2 == 5 and left_used2 == 5, "storage bus: taking shells out gave " .. tostring(got2) .. ", the chest keeps " .. left2 .. " (used " .. left_used2 .. ")")
			--- ... and a full stack put into the network goes into the chest or the drive, and is the network's again
			pinv.clear()
			pinv[1].set_stack(def(SPACK, 8))
			local sn, swhy = remote.call(TERM, "store_stack", t, pinv[1])
			note("storage bus on a chest", SPACK .. " x8 stored while the chest holds a used stack", "stored " .. tostring(sn) .. " reason " .. tostring(swhy) .. ", the network counts " .. count(SPACK))
			expect(sn == 8 and count(SPACK) == 8, "storing packs next to a used stack in a storage bus's chest: " .. tostring(sn) .. " " .. tostring(swhy) .. ", the network counts " .. count(SPACK))
			pinv.destroy()
			hold.destroy()
			--- the export bus: packs, magazines and repair packs out into its chest (all there is)
			st.exported = { [PACK] = count(PACK), [MAG] = count(MAG), [REPAIR] = count(REPAIR) }
			remote.call(IO, "set_bus_filters", sc.ebus, { PACK, MAG, REPAIR })
			return
		end

		-------------------------------------------------------------------------------------------------------------
		--- phase 3: the export bus has had its visits
		-------------------------------------------------------------------------------------------------------------
		if st.phase == 2 and tick >= CHECK2 then
			st.phase = 3
			local ec = sc.echest.get_inventory(defines.inventory.chest)
			for _, name in ipairs({ PACK, MAG, REPAIR }) do
				local n, usedn = scan(ec, name)
				note("export bus into a chest", name, "the chest holds " .. n .. " (used " .. usedn .. "), the network " .. count(name) .. " of " .. st.exported[name])
				expect(n == st.exported[name] and usedn == 0 and count(name) == 0, "export bus: " .. name .. ": the chest holds " .. n .. " (used " .. usedn .. ") of "
					.. st.exported[name] .. ", the network " .. count(name))
			end
			--- the chest's packs go back through a second import bus (the first one holds stacks it refuses: it is parked,
			--- and a parked bus looks again about once a minute): nothing made, nothing lost
			remote.call(IO, "set_bus_filters", sc.ebus, {})
			local ic2 = sc.ichest2.get_inventory(defines.inventory.chest)
			for i = 1, #ec do ic2[i].transfer_stack(ec[i]) end
			return
		end

		if st.phase == 3 and tick >= CHECK3 then
			st.phase = 4
			local ic2 = sc.ichest2.get_inventory(defines.inventory.chest)
			local ec = sc.echest.get_inventory(defines.inventory.chest)
			local want = st.exported[PACK]
			note("export bus into a chest, then import bus", PACK .. " x" .. want, "the network counts " .. count(PACK) .. ", the chest keeps " .. scan(ic2, PACK))
			expect(count(PACK) == want and scan(ic2, PACK) == 0 and scan(ec, PACK) == 0, "science packs out through the export bus and back through the import bus: network "
				.. count(PACK) .. " of " .. want .. ", " .. scan(ic2, PACK) .. " left in the chest")
			st.done = true
			me_report("STORABLE", "ME storable items", problems, "terminal, pane clicks, import and export bus, interfaces, storage bus; " .. #st.tools .. " other tools by the import bus")
		end
	end

	function T.running(check) check(storage.storable76 and storage.storable76.done, "ME storable items") end
	return T
end
