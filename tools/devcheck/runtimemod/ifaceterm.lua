--- Runtime test of me-network issue #336: the ME Interface Terminal. One network with three pattern providers (one next to a
--- molecular assembler, one next to a chest and full, one alone), four ME Interfaces (one with config rows) and the terminal;
--- a provider of no network. Its list: every provider and interface of the network, providers first by the machine next to them,
--- the machine filter and its choices, "only with free slots", the search over the patterns' products (by prototype name and by
--- a translated name), the interfaces' config rows and the providers' names, the pages, one entry's data and a page built into a
--- stand-in of the window; a pattern taken out and put back by the window's click, shift + click into the first free slot, a
--- provider of another network refused; renaming (trimmed, cleared, kept by a blueprint's tag and a clone, not by a settings
--- paste); the neighbour names follow a removed chest; the terminal's screen and its power through the controller.
--- Loaded by control.lua: require("ifaceterm")(H) returns { setup, tick, running }.

local NET, AC, IT, GUI = "gregtorio-me-network", "gregtorio-me-autocraft", "gregtorio-me-interface-terminal", "gregtorio-me-gui"
local PT, IO = "gregtorio-me-pattern-terminal", "gregtorio-me-io"
local BX, BY = 200, -370          -- (inside the cleared test area: TEST_RADIUS of control.lua)
local START = 150

return function(H)
	local me_place, me_report, power = H.me_place, H.me_report, H.power
	local T = {}

	function T.setup(s)
		local fails = {}
		local what = "interface terminal"
		power(s, fails, what, BX, BY)
		local ctrl = me_place(s, fails, what, "me-network-controller", BX + 7, BY)
		local drive = H.me_drive(s, fails, what, BX + 8.5, BY - 0.5, {}, "16k")
		local term = me_place(s, fails, what, "me-terminal", BX + 10.5, BY - 0.5)
		H.cable_row(s, fails, BX + 11, BX + 24, BY - 1)
		me_place(s, fails, what, "me-interface-terminal", BX + 25.5, BY - 0.5)
		for _, x in ipairs({ 11.5, 13.5, 15.5 }) do me_place(s, fails, what, "me-pattern-provider", BX + x, BY + 0.5) end
		me_place(s, fails, what, "me-molecular-assembler", BX + 11.5, BY + 1.5)
		me_place(s, fails, what, "iron-chest", BX + 13.5, BY + 1.5)
		for _, x in ipairs({ 17.5, 19.5, 21.5, 23.5 }) do me_place(s, fails, what, "me-network-interface", BX + x, BY + 0.5) end
		me_place(s, fails, what, "me-pattern-provider", BX + 11.5, BY + 8.5)              -- of no network
		H.me_connect(fails, what, { ctrl, drive, term })
		return fails
	end

	function T.tick()
		local st = storage.ifaceterm336
		if st or game.tick < START then return end
		st = { problems = {}, done = true }
		storage.ifaceterm336 = st
		local problems = st.problems
		local function expect(ok, text) if not ok then problems[#problems + 1] = text end end
		local s = game.surfaces[1]
		local function find(name, x, y) return s.find_entity(name, { BX + x, BY + y }) end
		local it = find("me-interface-terminal", 25.5, -0.5)
		local p1, p2, p3 = find("me-pattern-provider", 11.5, 0.5), find("me-pattern-provider", 13.5, 0.5), find("me-pattern-provider", 15.5, 0.5)
		local lone = find("me-pattern-provider", 11.5, 8.5)
		local i1 = find("me-network-interface", 17.5, 0.5)
		local chest = find("iron-chest", 13.5, 1.5)
		if not (it and p1 and p2 and p3 and lone and i1 and chest) then
			return me_report("IFACETERM", "ME Interface Terminal", { "entities missing" })
		end
		local why0 = remote.call(IT, "problem", it)
		if why0 then return me_report("IFACETERM", "ME Interface Terminal", { "its network does not work: " .. why0 }) end

		--- patterns (processing: they need no recipe of the game) and an interface's config rows
		local n = 0
		local function pattern(e, output)
			n = n + 1
			local tmp = game.create_inventory(2)
			tmp.insert{ name = "me-blank-pattern", count = 1 }
			remote.call(PT, "encode_def", tmp, nil, { kind = "processing", inputs = { { key = "stone", amount = n } },
				outputs = { { key = output, amount = 1 } } })
			local got, why = remote.call(AC, "insert_pattern", e, (tmp.find_item_stack("me-encoded-pattern")))   -- (one value: the stack)
			tmp.destroy()
			return got, why
		end
		expect(pattern(p1, "iron-gear-wheel") == 1 and pattern(p1, "copper-cable") == 2, "patterns of the first provider")
		for i = 1, 9 do expect(pattern(p2, i == 1 and "pipe" or "stone-brick") == i, "pattern " .. i .. " of the second provider") end
		remote.call(IO, "set_interface_slot", i1, 1, "iron-plate", "normal", 50)
		for _, e in ipairs({ p1, p2, p3 }) do remote.call(AC, "provider_info", e) end       -- (a scan: what is next to them)

		local function list(opts, names) return remote.call(IT, "list", it, opts or {}, names) or { entries = {} } end
		local function units(l)
			local out = {}
			for _, e in ipairs(l.entries) do out[#out + 1] = e.unit end
			return table.concat(out, ",")
		end
		local u = function(...)
			local out = {}
			for _, e in ipairs({ ... }) do out[#out + 1] = e.unit_number end
			return table.concat(out, ",")
		end
		local ifs = {}
		for _, x in ipairs({ 17.5, 19.5, 21.5, 23.5 }) do ifs[#ifs + 1] = find("me-network-interface", x, 0.5) end
		table.sort(ifs, function(a, b) return a.unit_number < b.unit_number end)

		--- every provider and interface of the network: providers first by the machine next to them (none, the chest, the
		--- assembler), then the interfaces; not the provider of no network
		local all = list()
		expect(all.providers == 3 and all.interfaces == 4 and #all.entries == 7, "the network's blocks: " .. all.providers .. " providers, "
			.. all.interfaces .. " interfaces, " .. #all.entries .. " entries")
		expect(units(all) == u(p3, p2, p1, ifs[1], ifs[2], ifs[3], ifs[4]), "the order: " .. units(all))
		expect(serpent.line(all.machines) == serpent.line({ "iron-chest", "me-molecular-assembler" }), "the machines: " .. serpent.line(all.machines))
		local e2 = all.entries[2]
		expect(e2 and e2.size == 9 and e2.filled == 9 and serpent.line(e2.near) == serpent.line({ "iron-chest" }), "the full provider: "
			.. serpent.line(e2))

		--- the filters
		expect(units(list{ filter = "iron-chest" }) == u(p2), "by the chest: " .. units(list{ filter = "iron-chest" }))
		expect(units(list{ filter = "me-molecular-assembler" }) == u(p1), "by the assembler")
		expect(units(list{ filter = "@interfaces" }) == u(ifs[1], ifs[2], ifs[3], ifs[4]), "the interfaces alone: " .. units(list{ filter = "@interfaces" }))
		expect(units(list{ free = true }) == u(p3, p1), "only with free slots: " .. units(list{ free = true }))

		--- the search: a product by its prototype name, by a translated name, an interface's config row, a provider's name
		expect(units(list{ search = "pipe" }) == u(p2), "search pipe: " .. units(list{ search = "pipe" }))
		expect(units(list{ search = "gear" }) == u(p1), "search gear: " .. units(list{ search = "gear" }))
		expect(units(list({ search = "Zahnrad" }, { ["item/iron-gear-wheel"] = "zahnrad" })) == u(p1), "a translated name")
		expect(units(list{ search = "iron plate" }) == u(i1), "an interface's row: " .. units(list{ search = "iron plate" }))
		expect(#list{ search = "nothing-makes-this" }.entries == 0, "a search that matches nothing")

		--- renaming: trimmed, shown, searched, sorted first among the providers without a machine; empty clears it
		expect(remote.call(IT, "rename", it, p3.unit_number, "  Smelter row  ") == true, "rename")
		expect(remote.call(AC, "get_label", p3) == "Smelter row", "the label: " .. tostring(remote.call(AC, "get_label", p3)))
		expect(units(list{ search = "smelter" }) == u(p3), "search by the name")
		local named = list().entries[1]
		expect(named and named.label == "Smelter row", "the name in the list")
		local settings = remote.call(AC, "provider_settings", p3)
		expect(settings.label == "Smelter row", "the blueprint settings hold the name")
		remote.call(AC, "built", lone, { fork_me_provider = { priority = 0, patterns = {}, label = "From a blueprint" } })
		expect(remote.call(AC, "get_label", lone) == "From a blueprint", "a blueprint's tag: " .. tostring(remote.call(AC, "get_label", lone)))
		remote.call(AC, "built", lone, nil, p3)
		expect(remote.call(AC, "get_label", lone) == "Smelter row", "a clone: " .. tostring(remote.call(AC, "get_label", lone)))
		remote.call(AC, "paste", p3, p1)
		expect(remote.call(AC, "get_label", p1) == nil, "a settings paste does not copy the name")
		expect(remote.call(IT, "rename", it, lone.unit_number, "x") == false, "a provider of no network cannot be renamed here")

		--- one entry's data and a page into a stand-in of the window
		local v = remote.call(IT, "entry_view", it, {}, 3)
		expect(v and v.kind == "provider" and v.unit == p1.unit_number and #v.slots == 9 and v.slots[1] and v.slots[3] == false
			and v.slots[1].outputs and v.slots[1].outputs[1].key == "iron-gear-wheel", "the assembler's provider: " .. serpent.line(v and v.slots and v.slots[1]))
		local vi = remote.call(IT, "entry_view", it, { filter = "@interfaces" }, 1)
		expect(vi and vi.kind == "interface" and vi.rows[1] and vi.rows[1].key == "iron-plate" and vi.rows[1].amount == 50,
			"the interface's rows: " .. serpent.line(vi and vi.rows))
		local first, last, page, pages = remote.call(IT, "page_of", it, {}, 2)
		expect(first == 7 and last == 7 and page == 2 and pages == 2, "page 2: " .. serpent.line({ first, last, page, pages }))
		first, last, page = remote.call(IT, "page_of", it, {}, 5)
		expect(page == 2, "a page after the last is the last: " .. tostring(page))
		local built = remote.call(IT, "build_page", it, {}, 1) or {}
		local slot1 = built[2] and built[2].slots and built[2].slots[1]
		expect(#built == 6 and built[1].caption == "Smelter row" and #built[2].slots == 9 and slot1.sprite == "item/pipe"
			and slot1.style == "slot_button" and built[3].slots[3].style == "slot_button" and built[5].note ~= nil,
			"page 1 built: " .. #built .. " parts, " .. serpent.line(built[2]))
		local p2built = remote.call(IT, "build_page", it, {}, 2) or {}
		expect(#p2built == 1 and p2built[1].slots == nil, "page 2 built: " .. serpent.line(p2built))
		local ibuilt = remote.call(IT, "build_page", it, { filter = "@interfaces" }, 1) or {}
		expect(ibuilt[1] and ibuilt[1].slots and ibuilt[1].slots[1] and ibuilt[1].slots[1].sprite == "item/iron-plate"
			and ibuilt[1].slots[1].number == 50, "the interface's row button: " .. serpent.line(ibuilt[1]))
		local editing = remote.call(IT, "build_page", it, {}, 1, p3.unit_number) or {}
		expect(editing[1] and editing[1].caption == "textfield", "the name field while renaming: " .. serpent.line(editing[1]))
		local none = remote.call(IT, "build_page", it, { search = "nothing-makes-this" }, 1) or {}
		expect(#none == 1 and none[1].label ~= nil, "an empty list says so")

		--- the window's click: a pattern into the hand and back; a provider of no network is refused
		local inv = game.create_inventory(4)
		local hand, back = inv[1], game.create_inventory(10)
		local why = remote.call(IT, "click", it, p1.unit_number, 1, hand, back, false)
		expect(not why and hand.valid_for_read and hand.name == "me-encoded-pattern" and list{ filter = "me-molecular-assembler" }.entries[1].filled == 1,
			"taken into the hand: " .. tostring(why))
		why = remote.call(IT, "click", it, p1.unit_number, 1, hand, back, false)
		expect(not why and not hand.valid_for_read and list{ filter = "me-molecular-assembler" }.entries[1].filled == 2, "put back: " .. tostring(why))
		why = remote.call(IT, "click", it, p1.unit_number, 2, hand, back, true)
		expect(not why and back.get_item_count("me-encoded-pattern") == 1, "shift: into the inventory: " .. tostring(why))
		expect(remote.call(IT, "click", it, lone.unit_number, 1, hand, back, false) == "not-in-network", "a provider of no network")

		--- shift + click in the pane: into the first free slot of the list as filtered
		local stack = back.find_item_stack("me-encoded-pattern")
		expect(remote.call(IT, "shift_in", it, stack, { filter = "iron-chest" }) == "no-free-slot", "the chest's provider is full")
		expect(remote.call(IT, "shift_in", it, stack, {}) == nil and back.get_item_count("me-encoded-pattern") == 0
			and list().entries[1].filled == 1, "into the first provider listed: " .. serpent.line(list().entries[1]))

		--- the names next to a provider follow the world (its rescan)
		chest.destroy{ raise_destroy = true }
		remote.call(AC, "provider_info", p2)
		local after = list()
		expect(serpent.line(after.machines) == serpent.line({ "me-molecular-assembler" }) and #list{ filter = "iron-chest" }.entries == 0,
			"the chest is gone: " .. serpent.line(after.machines))

		--- the terminal is a member: its screen is lit, the controller draws its power
		local screen = remote.call(NET, "screen", it)
		expect(screen and screen.on == true and screen.variation == 2, "the screen: " .. serpent.line(screen))
		local found
		for _, row in ipairs(remote.call(GUI, "controller_data", find("me-network-controller", 7, 0)).power_rows or {}) do
			if row.key == "interface-terminal" then found = row end
		end
		expect(found and found.n == 1 and found.w == 8000, "its power: " .. serpent.line(found))
		expect(remote.call(GUI, "has_window", it), "it opens a window")

		inv.destroy()
		back.destroy()
		me_report("IFACETERM", "ME Interface Terminal", problems,
			"7 blocks in order, machine filter, free slots, search by product, translated name, interface row and name, pages, a page built, take and put, shift in, rename, tag, clone, paste, neighbours, screen, power")
	end

	function T.running(check) check(storage.ifaceterm336 and storage.ifaceterm336.done, "ME Interface Terminal") end

	return T
end
