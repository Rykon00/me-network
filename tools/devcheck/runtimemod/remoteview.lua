--- Runtime test of me-network issues #176 and #177: ME windows in remote view (a space platform). The harness has no
--- player and cannot make one in the remote controller (defines.controllers.remote), so a table standing for a
--- LuaPlayer is made by the mod's remote interface (gregtorio-me-gui stand_in): in remote view get_main_inventory()
--- returns nil, the hand holds nothing, the character (when there is one) has the inventory. Tested: the helper for the
--- player's inventory (a normal player, remote view with and without a character), that the hand-over buffer is not used in
--- remote view, that a cell taken out of a drive or the workbench and an item taken out of the terminal go into the
--- character's inventory (and stay in the block without an inventory or when it is full, with their own reasons), and
--- that give_back never spills from remote view (the items are parked and returned when there is an inventory), while it
--- spills outside remote view as before. The remote controller itself is tested in game.
--- Loaded by control.lua: require("remoteview")(H) returns { setup, tick, running }.

local NET, GUI, TERM, WB = "gregtorio-me-network", "gregtorio-me-gui", "gregtorio-me-terminal", "gregtorio-me-workbench"
local BX, BY = 10, -340
local START = 130

return function(H)
	local me_place, me_report, power = H.me_place, H.me_report, H.power
	local T = {}

	function T.setup(s)
		local fails = {}
		local what = "remote view"
		power(s, fails, what, BX, BY)
		local ctrl = me_place(s, fails, what, "me-network-controller", BX + 7, BY)
		local drive = H.me_drive(s, fails, what, BX + 8.5, BY - 0.5, {}, "16k")
		local term = me_place(s, fails, what, "me-terminal", BX + 12.5, BY - 2.5)
		local bench = me_place(s, fails, what, "me-cell-workbench", BX + 16.5, BY + 4.5)   -- no cable: it needs no network
		--- issue #179: the other take-out paths (their records need no network)
		local provider = me_place(s, fails, what, "me-pattern-provider", BX + 20.5, BY + 4.5)
		local bus = me_place(s, fails, what, "me-import-bus", BX + 22.5, BY + 4.5)
		local pterm = me_place(s, fails, what, "me-pattern-terminal", BX + 24.5, BY + 4.5)
		H.me_connect(fails, what, { ctrl, drive, term })
		storage.remoteview_scene = { term = term, drive = drive, bench = bench, provider = provider, bus = bus, pterm = pterm }
		return fails
	end

	local function ground_items(surface, around)
		return #surface.find_entities_filtered{ name = "item-on-ground", position = around, radius = 30 }
	end

	function T.tick()
		local st = storage.remoteview
		if st or game.tick < START then return end
		st = { problems = {}, done = true }
		storage.remoteview = st
		local problems = st.problems
		local function expect(ok, text) if not ok then problems[#problems + 1] = text end end
		local sc = storage.remoteview_scene
		local drive, term, bench = sc and sc.drive, sc and sc.term, sc and sc.bench
		if not (drive and drive.valid and term and term.valid and bench and bench.valid) then
			expect(false, "the scene was not built")
			return me_report("REMOTEVIEW", "ME windows in remote view", problems)
		end
		local g = function(fn, ...) return remote.call(GUI, fn, ...) end
		local surface = game.surfaces[1]
		local main, char = game.create_inventory(10), game.create_inventory(10)

		--- the helper: a normal player, remote view with a character, remote view without one
		g("stand_in", "normal", { main = main, character = char, index = 9001 })
		g("stand_in", "remote", { remote = true, character = char, index = 9002 })
		g("stand_in", "none", { remote = true, index = 9003 })
		expect(g("stand_in_inventory", "normal") == main, "a normal player: their main inventory")
		expect(g("stand_in_inventory", "remote") == char, "remote view with a character: the character's inventory")
		expect(g("stand_in_inventory", "none") == nil, "remote view without a character: nil")
		local c, inv, remote_view = g("stand_in_hand", "remote")
		expect(c == nil and inv == char and remote_view == true, "the hand in remote view: no cursor, the character's inventory, remote")
		c, inv, remote_view = g("stand_in_hand", "none")
		expect(c == nil and inv == nil and remote_view == true, "the hand in remote view without a character")
		expect(g("stand_in_uses_buffer", "normal") == true, "the hand-over buffer is used outside remote view")
		expect(g("stand_in_uses_buffer", "remote") == false and g("stand_in_uses_buffer", "none") == false,
			"the hand-over buffer is not used in remote view (the pane is)")

		--- a cell out of the drive (issue #177): no inventory -> it stays; a full inventory -> it stays; else it arrives
		local function cells() local n = 0 for _ in pairs(remote.call(NET, "drive", drive)) do n = n + 1 end return n end
		local before = cells()
		local why, out = remote.call(NET, "drive_click", nil, nil, drive, 2, true)
		expect(why == "no-inventory" and out == nil and cells() == before, "no inventory: " .. tostring(why) .. ", cells " .. cells())
		char.insert{ name = "iron-plate", count = 100 * #char }
		why, out = remote.call(NET, "drive_click", nil, char, drive, 2, true)
		expect(why == "inventory-full" and cells() == before, "full inventory: " .. tostring(why) .. ", cells " .. cells())
		char.clear()
		why, out = remote.call(NET, "drive_click", nil, char, drive, 2, true)
		expect(why == nil and out == "out" and cells() == before - 1 and char.get_item_count("me-16k-storage-cell") == 1,
			"the cell into the character's inventory: " .. tostring(why) .. "/" .. tostring(out) .. ", cells " .. cells())

		--- the workbench's cell slot (block_click, the window's click): the same
		local hand = game.create_inventory(1)
		hand[1].set_stack{ name = "me-1k-storage-cell", count = 1 }
		remote.call(WB, "cell_click", bench, hand[1], char, false)
		local function bench_cell() local i = remote.call(WB, "info", bench) return i and i.cell end
		expect(bench_cell() ~= nil, "a cell in the workbench")
		why, out = g("block_click", bench, 1, nil, nil, true)
		expect(why == "no-inventory" and bench_cell() ~= nil, "workbench without an inventory: " .. tostring(why))
		why, out = g("block_click", bench, 1, nil, char, true)
		expect(why == nil and out == "out" and bench_cell() == nil and char.get_item_count("me-1k-storage-cell") == 1,
			"workbench cell into the inventory: " .. tostring(why) .. "/" .. tostring(out))

		--- issue #179: every other take-out path refuses without an inventory and keeps the item, and takes into one
		local AC, IO, PT = "gregtorio-me-autocraft", "gregtorio-me-io", "gregtorio-me-pattern-terminal"
		--- the workbench's card slot: the cell back in, a Fuzzy Card into its first card slot
		local cell = char.find_item_stack("me-1k-storage-cell")
		if cell then hand[1].transfer_stack(cell) end
		remote.call(WB, "cell_click", bench, hand[1], char, false)
		hand[1].set_stack{ name = "me-fuzzy-card", count = 1 }
		expect(remote.call(WB, "card_click", bench, 1, hand[1], char, false) == nil and not hand[1].valid_for_read, "a card into the workbench")
		why = g("block_click", bench, 2, nil, nil, true)
		expect(why == "no-inventory" and remote.call(WB, "inventory", bench)[2].valid_for_read, "workbench card without an inventory: " .. tostring(why))
		why, out = g("block_click", bench, 2, nil, char, true)
		expect(why == nil and out == "out" and char.get_item_count("me-fuzzy-card") == 1, "workbench card into the inventory: " .. tostring(why))
		--- the provider's pattern slot
		local provider, bus, pterm = sc.provider, sc.bus, sc.pterm
		if provider and provider.valid and bus and bus.valid and pterm and pterm.valid then
			local tmp = game.create_inventory(2)
			tmp.insert{ name = "me-blank-pattern", count = 1 }
			local ew, ewhy = remote.call(PT, "encode_def", tmp, nil, { kind = "processing", inputs = { { key = "stone", amount = 2 } },
				outputs = { { key = "stone-brick", amount = 1 } } })
			local enc = tmp.find_item_stack("me-encoded-pattern")
			local ins, iwhy = remote.call(AC, "insert_pattern", provider, enc)
			expect(ins == 1, "a pattern into the provider: encode " .. tostring(ew) .. "/" .. tostring(ewhy) .. ", insert " .. tostring(ins) .. "/" .. tostring(iwhy))
			why = remote.call(AC, "provider_click", nil, nil, provider, 1, true)
			expect(why == "no-inventory" and remote.call(AC, "provider_info", provider).slots[1] ~= nil, "provider without an inventory: " .. tostring(why))
			why, out = remote.call(AC, "provider_click", nil, char, provider, 1, true)
			expect(why == nil and out == "out" and char.get_item_count("me-encoded-pattern") == 1, "provider pattern into the inventory: " .. tostring(why))
			--- the import bus's card slot
			hand[1].set_stack{ name = "me-acceleration-card", count = 1 }
			expect(remote.call(IO, "bus_card_click", bus, 1, hand[1], char, false) == nil, "a card into the bus")
			why = remote.call(IO, "bus_card_click", bus, 1, nil, nil, true)
			expect(why == "no-inventory" and remote.call(IO, "bus_inventory", bus)[1].valid_for_read, "bus card without an inventory: " .. tostring(why))
			why, out = remote.call(IO, "bus_card_click", bus, 1, nil, char, true)
			expect(why == nil and out == "out" and char.get_item_count("me-acceleration-card") == 1, "bus card into the inventory: " .. tostring(why))
			--- the pattern terminal's output slot
			local pat = char.find_item_stack("me-encoded-pattern")
			if pat then hand[1].transfer_stack(pat) else hand[1].clear() end
			expect(hand[1].valid_for_read and remote.call(PT, "click", pterm, 2, hand[1], char, false) == nil and not hand[1].valid_for_read,
				"a pattern into the output slot")
			why = remote.call(PT, "click", pterm, 2, nil, nil, true)
			expect(why == "no-inventory" and remote.call(PT, "inventory", pterm)[2].valid_for_read, "pattern terminal without an inventory: " .. tostring(why))
			why, out = remote.call(PT, "click", pterm, 2, nil, char, true)
			expect(why == nil and out == "out" and char.get_item_count("me-encoded-pattern") == 1, "pattern terminal into the inventory: " .. tostring(why))
			tmp.destroy()
		else
			expect(false, "the provider, the bus or the pattern terminal was not built")
		end
		char.clear()
		hand.destroy()

		--- the terminal's take buttons: remote view takes into the inventory (a stack, or one item), never the hand
		local before_plates = remote.call(NET, "count", term, "iron-plate")
		local size = prototypes.item["iron-plate"].stack_size
		local feed = game.create_inventory(4)
		feed.insert{ name = "iron-plate", count = 2 * size + 10 }
		remote.call(GUI, "buffer_absorb", feed, "terminal", term)
		expect(remote.call(NET, "count", term, "iron-plate") == before_plates + 2 * size + 10, "plates fed to the network")
		local n, tw = remote.call(TERM, "take", nil, nil, term, "iron-plate", "inventory-one")
		expect(n == nil and tw == "no-inventory", "terminal take without an inventory: " .. tostring(n) .. "/" .. tostring(tw))
		n = remote.call(TERM, "take", nil, char, term, "iron-plate", "inventory-one")
		expect(n == 1 and char.get_item_count("iron-plate") == 1, "terminal take one: " .. tostring(n))
		n = remote.call(TERM, "take", nil, char, term, "iron-plate", "inventory")
		expect(n == size and char.get_item_count("iron-plate") == size + 1, "terminal take a stack: " .. tostring(n))
		feed.destroy()
		char.clear()

		--- give_back (issue #177): from remote view never spilled; parked, and returned when there is an inventory
		local ground = ground_items(surface, { 0, 0 })
		local tmp = game.create_inventory(2)
		tmp.insert{ name = "copper-plate", count = 5 }
		g("stand_in_give_back", "none", tmp[1], term)
		expect(not tmp[1].valid_for_read and g("stand_in_parked", "none") == 5, "no inventory: parked " .. g("stand_in_parked", "none"))
		expect(ground_items(surface, { 0, 0 }) == ground, "nothing was spilled from remote view without an inventory")
		expect(#g("stand_in_texts", "none") >= 1, "the player was told that the items are kept")
		char.insert{ name = "iron-plate", count = 100 * #char }
		tmp.insert{ name = "copper-plate", count = 7 }
		g("stand_in_give_back", "remote", tmp[1], term)
		expect(not tmp[1].valid_for_read and g("stand_in_parked", "remote") == 7, "full inventory: parked " .. g("stand_in_parked", "remote"))
		expect(ground_items(surface, { 0, 0 }) == ground, "nothing was spilled from remote view with a full inventory")
		tmp.insert{ name = "copper-plate", count = 9 }          -- a part (the way the cards of a cell are given back)
		g("stand_in_give_back", "remote", tmp[1], term)
		expect(g("stand_in_parked", "remote") == 16, "parked again: " .. g("stand_in_parked", "remote"))
		--- the character gets room (a new stand-in with the same index, as the player's next window finds them)
		char.clear()
		g("stand_in", "remote", { remote = true, character = char, index = 9002 })
		local left = g("stand_in_return_parked", "remote")
		expect(left == 0 and g("stand_in_parked", "remote") == 0 and char.get_item_count("copper-plate") == 16,
			"parked items returned: " .. left .. ", " .. char.get_item_count("copper-plate"))
		g("stand_in", "none", { remote = true, character = main, index = 9003 })
		left = g("stand_in_return_parked", "none")
		expect(left == 0 and main.get_item_count("copper-plate") == 5, "parked items returned to another character: " .. left)
		--- with an inventory the item arrives there and nothing is parked
		tmp.insert{ name = "copper-plate", count = 3 }
		g("stand_in_give_back", "remote", tmp[1], term)
		expect(not tmp[1].valid_for_read and g("stand_in_parked", "remote") == 0 and char.get_item_count("copper-plate") == 19,
			"give back with an inventory: " .. char.get_item_count("copper-plate"))
		--- outside remote view it is as before: what the inventory cannot take is spilled at the character
		main.clear()
		main.insert{ name = "iron-plate", count = 100 * #main }
		tmp.insert{ name = "copper-plate", count = 2 }
		g("stand_in_give_back", "normal", tmp[1], term)
		expect(not tmp[1].valid_for_read and g("stand_in_parked", "normal") == 0 and ground_items(surface, { 0, 0 }) > ground,
			"a normal player with a full inventory: spilled")

		--- issue #179: a removed player's parked items go with the player (as the game drops a removed player's inventory)
		tmp.insert{ name = "copper-plate", count = 4 }
		g("stand_in", "gone", { remote = true, index = 9009 })
		g("stand_in_give_back", "gone", tmp[1], term)
		expect(g("stand_in_parked", "gone") == 4, "parked for a player who will be removed: " .. g("stand_in_parked", "gone"))
		g("forget_player", 9009)
		expect(g("stand_in_parked", "gone") == 0, "nothing is kept for a removed player: " .. g("stand_in_parked", "gone"))
		g("stand_in_forget", "gone")
		for _, name in ipairs{ "normal", "remote", "none" } do g("stand_in_forget", name) end
		tmp.destroy()
		main.destroy()
		char.destroy()
		me_report("REMOTEVIEW", "ME windows in remote view", problems,
			"the helper, no buffer, a cell and an item out into the character's inventory or kept, no spill, parked and returned")
	end

	function T.running(check) check(storage.remoteview and storage.remoteview.done, "ME windows in remote view") end

	return T
end
