--- Runtime test of me-network issue #590: the cards of a block built from a blueprint. A source pattern provider (on no network)
--- has two Pattern Capacity Cards and patterns in slots 1 and 12 (slot 12 needs a card); its blueprint settings are the tag of
--- the providers built here. Every other block with card slots (ME Interface, Export and Import Bus, Storage Bus, IO Port,
--- Wireless Access Point, Logistic Interface) gets a tag that asks for two cards. Each kind is built four times:
---   (a) by robots (a ghost revived: no player) next to the network, which has the cards: they come from the network;
---   (b) by robots on no network: the block waits for its cards (the provider shows it in its custom status and its data),
---       then a cable joins it to the network and the cards come from there (the block's own retry, not the build);
---   (c) by hand with the cards in the player's inventory (an inventory stands for it): they come from the inventory, the
---       network keeps its own; the provider takes its blanks for both patterns from the inventory too;
---   (d) by hand with an empty inventory: the cards come from the network.
--- Loaded by control.lua: require("bpcards")(H) returns { setup, tick, running }.

local NET, AC, PT, IO, SB, IOP, WL, LIF = "gregtorio-me-network", "gregtorio-me-autocraft", "gregtorio-me-pattern-terminal",
	"gregtorio-me-io", "gregtorio-me-storagebus", "gregtorio-me-ioport", "gregtorio-me-wireless", "gregtorio-me-logistic-interface"
local BX, BY = 280, 120               -- (inside the cleared test area, TEST_RADIUS of control.lua; clear of the other tests)
local START, DEADLINE = 200, 1350     -- (case b: the cards must have come by DEADLINE)
local BLANK = "me-blank-pattern"
local PCAP, ICAP, CAP, ACCEL, BOOSTER = "me-pattern-capacity-card", "me-interface-capacity-card", "me-capacity-card",
	"me-acceleration-card", "me-wireless-booster"
local SOUTH = defines.direction.south
local DEFS = {
	[1] = { kind = "processing", inputs = { { key = "iron-plate", amount = 3 } }, outputs = { { key = "iron-stick", amount = 5 } } },
	[12] = { kind = "processing", inputs = { { key = "copper-plate", amount = 3 } }, outputs = { { key = "copper-cable", amount = 5 } } },
}

--- the kinds of block: `n` cards of `card` wanted by the tag; `cards(e)` how many of them its slots hold
local function inv_count(iface, fn, card)
	return function(e)
		local inv = remote.call(iface, fn, e)
		return inv and inv.valid and inv.get_item_count(card) or -1
	end
end
local function info_count(iface, card)
	return function(e)
		local n = 0
		for _, name in pairs((remote.call(iface, "info", e) or {}).cards or {}) do if name == card then n = n + 1 end end
		return n
	end
end
local KINDS = {
	{ key = "provider", name = "me-pattern-provider", card = PCAP, iface = AC, cards = inv_count(AC, "provider_inventory", PCAP) },
	{ key = "interface", name = "me-network-interface", card = ICAP, iface = IO, cards = inv_count(IO, "interface_inventory", ICAP),
		tag = { fork_me_interface = { cards = { ICAP, ICAP } } } },
	{ key = "export bus", name = "me-export-bus", dir = SOUTH, card = CAP, iface = IO, cards = inv_count(IO, "bus_inventory", CAP),
		tag = { fork_me_bus = { filters = {}, cards = { CAP, CAP } } } },
	{ key = "import bus", name = "me-import-bus", dir = SOUTH, card = ACCEL, iface = IO, cards = inv_count(IO, "bus_inventory", ACCEL),
		tag = { fork_me_bus = { filters = {}, cards = { ACCEL, ACCEL } } } },
	{ key = "storage bus", name = "me-storage-bus", dir = SOUTH, card = CAP, iface = SB, cards = inv_count(SB, "inventory", CAP),
		tag = { fork_me_storage_bus = { cards = { CAP, CAP } } } },
	{ key = "io port", name = "me-io-port", card = ACCEL, iface = IOP, cards = info_count(IOP, ACCEL),
		tag = { fork_me_io_port = { cards = { ACCEL, ACCEL } } } },
	{ key = "access point", name = "me-wireless-access-point", card = BOOSTER, iface = WL, cards = inv_count(WL, "ap_inventory", BOOSTER),
		tag = { fork_me_access_point = { cards = { BOOSTER, BOOSTER } } } },
	{ key = "logistic interface", name = "me-logistic-interface", card = ICAP, iface = LIF, cards = info_count(LIF, ICAP),
		tag = { fork_me_logistic_interface = { cards = { ICAP, ICAP } } } },
}
local CASES = { a = 0, c = 2, d = 4 }  -- (x offsets in a kind's column, on the row below the cable; case b at 6, two rows lower)

return function(H)
	local me_place, me_report = H.me_place, H.me_report
	local T = {}
	local function col(i) return BX + 10 + (i - 1) * 10 end

	function T.setup(s)
		local fails = {}
		local what = "blueprint cards"
		H.power(s, fails, what, BX, BY)
		local ctrl = me_place(s, fails, what, "me-network-controller", BX + 6, BY)
		local drive = H.me_drive(s, fails, what, BX + 7.5, BY - 0.5, { [PCAP] = 10, [ICAP] = 20, [CAP] = 20, [ACCEL] = 20,
			[BOOSTER] = 10, [BLANK] = 10 }, "16k")      -- (enough that a case taking from the wrong source leaves case b its cards)
		H.cable_row(s, fails, BX + 8, col(#KINDS) + 8, BY - 1)
		if not (ctrl and drive) then fails[#fails + 1] = what .. ": the network was not built" end
		--- the source provider (on no network): two cards, patterns in slots 1 and 12
		local src = me_place(s, fails, what, "me-pattern-provider", BX + 0.5, BY + 10.5)
		if src then
			local hand = game.create_inventory(2)
			for slot = 1, 2 do
				hand[1].set_stack{ name = PCAP, count = 1 }
				local why = remote.call(AC, "provider_card_click", src, slot, hand[1], hand, false)
				if why then fails[#fails + 1] = what .. ": the source's card " .. slot .. ": " .. tostring(why) end
			end
			for slot, def in pairs(DEFS) do
				hand.clear()
				hand[1].set_stack{ name = BLANK, count = 1 }
				remote.call(PT, "encode_def", hand, nil, def)
				local got, why = remote.call(AC, "insert_pattern", src, hand[2], slot)
				if got ~= slot then fails[#fails + 1] = what .. ": the source's pattern " .. slot .. ": " .. tostring(why) end
			end
			hand.destroy()
		end
		return fails
	end

	function T.tick()
		local st = storage.bpcards590
		if game.tick < START or (st and st.done) then return end
		local s = game.surfaces[1]
		local ctrl = s.find_entity("me-network-controller", { BX + 6, BY })
		local src = s.find_entity("me-pattern-provider", { BX + 0.5, BY + 10.5 })
		local function count(name) return ctrl and remote.call(NET, "count", ctrl, name) or 0 end
		local function provider_status(p)
			local cs = remote.call(AC, "custom_status", p)
			return cs and cs.label and cs.label[1] or nil
		end
		local function pattern_ids(p)                                     -- the ids of the filled slots 1 and 12
			local info = remote.call(AC, "provider_info", p) or { slots = {} }
			local out = {}
			for slot in pairs(DEFS) do
				local d = info.slots[slot]
				out[slot] = d and not d.pending and d.id or false
			end
			return out, info
		end
		if not st then
			st = { problems = {}, b = {} }
			storage.bpcards590 = st
			local problems = st.problems
			local function expect(ok, msg) if not ok then problems[#problems + 1] = msg end end
			if not (ctrl and src) then expect(false, "entities missing") st.done = true return T.report() end
			local ptag = { fork_me_provider = remote.call(AC, "provider_settings", src) }
			local want = ptag.fork_me_provider and ptag.fork_me_provider.cards
			expect(type(want) == "table" and #want == 2, "the source's settings carry its two cards: " .. serpent.line(want))
			st.ids = pattern_ids(src)
			KINDS[1].tag = ptag
			local function ghost(k, x, y)
				local g = s.create_entity{ name = "entity-ghost", inner_name = k.name, position = { x, y }, force = "player",
					direction = k.dir, tags = k.tag }
				local _, e = g.revive{ raise_revive = true }
				return e
			end
			local function hand(k, x, y, inv)
				local e = me_place(s, problems, k.key, k.name, x, y, { direction = k.dir })
				if not e then return nil end
				local ok, err = pcall(remote.call, k.iface, "built", e, k.tag, nil, inv)
				expect(ok, k.key .. ": no build hook with an inventory: " .. tostring(err))
				return e
			end
			for i, k in ipairs(KINDS) do
				local x0, y0 = col(i), BY + 0.5
				local n = #k.tag[next(k.tag)].cards
				--- (a) robots, the cards in the network
				local before, blanks = count(k.card), count(BLANK)
				local a = ghost(k, x0 + CASES.a + 0.5, y0)
				expect(a and k.cards(a) == n and count(k.card) == before - n, k.key .. " (a) by robots, cards in the network: "
					.. (a and k.cards(a) or "not built") .. " of " .. n .. " cards, network " .. before .. " -> " .. count(k.card))
				if a and k.key == "provider" then
					local ids, info = pattern_ids(a)
					expect(ids[1] == st.ids[1] and ids[12] == st.ids[12] and info.slot_count == 27 and count(BLANK) == blanks - 2,
						"provider (a): patterns " .. serpent.line(ids) .. ", slots " .. tostring(info.slot_count) .. ", blanks "
						.. blanks .. " -> " .. count(BLANK))
				end
				--- (b) robots on no network (joined below, once every kind is built)
				local b = ghost(k, x0 + 6.5, BY + 2.5)
				expect(b and k.cards(b) == 0, k.key .. " (b) on no network: " .. (b and k.cards(b) or "not built") .. " cards")
				st.b[i] = b
				if b and k.key == "provider" then
					local info = remote.call(AC, "provider_info", b) or {}
					local label = provider_status(b)
					expect(#(info.want or {}) == n and (label == "fork-me-pattern.status-waiting-cards"
						or label == "fork-me-pattern.status-waiting-cards-patterns"), "provider (b) shows the waiting cards: want "
						.. serpent.line(info.want) .. ", status " .. tostring(label))
				end
				--- (c) by hand, the cards in the player's inventory
				local inv = game.create_inventory(10)
				inv.insert{ name = k.card, count = n }
				if k.key == "provider" then inv.insert{ name = BLANK, count = 2 } end
				before, blanks = count(k.card), count(BLANK)
				local c = hand(k, x0 + CASES.c + 0.5, y0, inv)
				expect(c and k.cards(c) == n and inv.get_item_count(k.card) == 0 and count(k.card) == before,
					k.key .. " (c) by hand, cards in the inventory: " .. (c and k.cards(c) or "not built") .. " of " .. n
					.. " cards, inventory keeps " .. inv.get_item_count(k.card) .. ", network " .. before .. " -> " .. count(k.card))
				if c and k.key == "provider" then
					local ids = pattern_ids(c)
					expect(ids[1] == st.ids[1] and ids[12] == st.ids[12] and inv.get_item_count(BLANK) == 0 and count(BLANK) == blanks,
						"provider (c): patterns " .. serpent.line(ids) .. ", blanks of the inventory left " .. inv.get_item_count(BLANK)
						.. ", network blanks " .. blanks .. " -> " .. count(BLANK))
				end
				inv.clear()
				--- (d) by hand, the cards in the network
				before = count(k.card)
				local d = hand(k, x0 + CASES.d + 0.5, y0, inv)
				expect(d and k.cards(d) == n and count(k.card) == before - n, k.key .. " (d) by hand, cards in the network: "
					.. (d and k.cards(d) or "not built") .. " of " .. n .. " cards, network " .. before .. " -> " .. count(k.card))
				inv.destroy()
			end
			--- the blocks of case (b) join the network
			for i in ipairs(KINDS) do
				for _, y in ipairs({ BY, BY + 1 }) do me_place(s, problems, "cable", "me-cable", col(i) + 6.5, y + 0.5) end
			end
			return
		end
		--- case (b): wait until every block has its cards (or the deadline)
		local all = true
		for i, k in ipairs(KINDS) do
			local b = st.b[i]
			if b and b.valid and k.cards(b) < 2 then all = false end
			if b and b.valid and k.key == "provider" then
				local ids = pattern_ids(b)
				if not (ids[1] and ids[12]) then all = false end
			end
		end
		if not all and game.tick < DEADLINE then return end
		local problems = st.problems
		for i, k in ipairs(KINDS) do
			local b = st.b[i]
			if b and b.valid then
				if k.cards(b) ~= 2 then
					problems[#problems + 1] = k.key .. " (b) joined to the network: " .. k.cards(b) .. " of 2 cards by tick " .. game.tick
				end
				if k.key == "provider" then
					local ids, info = pattern_ids(b)
					if not (ids[1] == st.ids[1] and ids[12] == st.ids[12] and provider_status(b) == nil and not info.want) then
						problems[#problems + 1] = "provider (b) joined: patterns " .. serpent.line(ids) .. ", status "
							.. tostring(provider_status(b)) .. ", want " .. serpent.line(info.want)
					end
				end
			end
		end
		st.done = true
		return T.report()
	end

	function T.report()
		me_report("BPCARDS", "Cards of blocks built from a blueprint (issue #590)", storage.bpcards590.problems, "provider, interface, "
			.. "export and import bus, storage bus, IO port, access point, logistic interface: by robots with the cards in the "
			.. "network, by robots on no network then joined, by hand from the inventory first, by hand from the network")
	end

	function T.running(check) check(storage.bpcards590 and storage.bpcards590.done, "Cards of blocks built from a blueprint") end
	return T
end
