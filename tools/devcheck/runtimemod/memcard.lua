--- Runtime test of me-network issue #561: the ME Memory Card (scripts/fork-me-memorycard.lua), through its handlers with a card in
--- a script inventory (no player). One network with a source pattern provider (patterns A and B), two empty providers T1 and
--- T2 and two ME Interfaces:
---   * the card has an item number (the engine fact the card's content rests on) and takes a label;
---   * select over the source and T1 with the area's centre on the source: the source is copied (its name, two patterns), the
---     label names it;
---   * alt-select over T1, T2 and an interface, with an inventory holding one blank and the network two: both providers take
---     the settings (the interface does not: another kind); T1 fills one slot from the inventory's blank and one from the
---     network's, T2 one from the network's, its second waits (#558);
---   * an interface with a row copied and pasted onto the other interface: the row is there;
---   * a select over nothing empties the card; a paste of an empty card does nothing.
--- Loaded by control.lua: require("memcard")(H) returns { setup, tick, running }.

local NET, AC, IO, MC = "gregtorio-me-network", "gregtorio-me-autocraft", "gregtorio-me-io", "gregtorio-me-memorycard"
local BX, BY = 320, 20                -- (inside the cleared test area, TEST_RADIUS of control.lua; clear of the other tests)
local START = 170
local PROVIDER, IFACE, BLANK = "me-pattern-provider", "me-network-interface", "me-blank-pattern"
local DEFS = {
	{ kind = "processing", inputs = { { key = "iron-plate", amount = 1 } }, outputs = { { key = "iron-stick", amount = 2 } } },
	{ kind = "processing", inputs = { { key = "copper-plate", amount = 1 } }, outputs = { { key = "copper-cable", amount = 2 } } },
}

return function(H)
	local me_place, me_report = H.me_place, H.me_report
	local T = {}
	local function at(dx) return { BX + dx + 0.5, BY - 1.5 } end

	function T.setup(s)
		local fails = {}
		local what = "memory card"
		H.power(s, fails, what, BX, BY)
		me_place(s, fails, what, "me-network-controller", BX + 6, BY)
		H.me_drive(s, fails, what, BX + 7.5, BY - 0.5, { ["iron-plate"] = 10 })
		H.cable_row(s, fails, BX + 8, BX + 22, BY - 1)
		local src = me_place(s, fails, what, PROVIDER, at(10)[1], at(10)[2])
		me_place(s, fails, what, PROVIDER, at(12)[1], at(12)[2])
		me_place(s, fails, what, PROVIDER, at(14)[1], at(14)[2])
		me_place(s, fails, what, IFACE, at(17)[1], at(17)[2])
		me_place(s, fails, what, IFACE, at(19)[1], at(19)[2])
		if src and give_patterns(src, DEFS, fails) ~= 2 then fails[#fails + 1] = what .. ": the source has not two patterns" end
		return fails
	end

	function T.tick()
		local st = storage.memcard561
		if game.tick < START or (st and st.done) then return end
		st = { problems = {} }
		storage.memcard561 = st
		local s = game.surfaces[1]
		local problems = st.problems
		local function expect(ok, msg) if not ok then problems[#problems + 1] = msg end end
		local function finish()
			st.done = true
			me_report("MEMCARD", "ME Memory Card (issue #561)", problems, "item number and label; a provider copied with its "
				.. "patterns and pasted onto two providers at once (an inventory's blank, the network's blanks, one waiting); an "
				.. "interface's row copied and pasted; another kind left alone; emptied")
		end
		local function find(name, dx) return s.find_entity(name, at(dx)) end
		local src, t1, t2, i1, i2 = find(PROVIDER, 10), find(PROVIDER, 12), find(PROVIDER, 14), find(IFACE, 17), find(IFACE, 19)
		local ctrl = s.find_entity("me-network-controller", { BX + 6, BY })
		if not (src and t1 and t2 and i1 and i2 and ctrl) then expect(false, "entities missing") return finish() end
		local function area(e) return { left_top = { x = e.position.x - 1, y = e.position.y - 1 },
			right_bottom = { x = e.position.x + 1, y = e.position.y + 1 } } end
		local function filled(p)
			local info = remote.call(AC, "provider_info", p) or { slots = {} }
			local n = 0
			for _, d in pairs(info.slots) do if not d.pending then n = n + 1 end end
			return n, info.pending
		end

		local inv = game.create_inventory(1)
		inv[1].set_stack{ name = "me-memory-card" }
		local card = inv[1]
		expect(card.valid_for_read and card.item_number ~= nil, "the card has no item number: " .. tostring(card.item_number))
		--- copy the source (T1 in the area too, farther from the centre)
		local copied = remote.call(MC, "copy", card, { t1, src }, area(src))
		local c = remote.call(MC, "content", card)
		expect(copied == src.unit_number and c and c.name == PROVIDER and c.patterns == 2, "the copy of the source: "
			.. serpent.line({ copied, src.unit_number, c and c.name, c and c.patterns }))
		expect(card.label and card.label:find("[entity=" .. PROVIDER .. "]", 1, true) ~= nil, "the card's label: " .. tostring(card.label))
		--- paste onto T1, T2 and an interface: one blank in the inventory, two in the network
		local pinv = game.create_inventory(10)
		pinv.insert{ name = BLANK, count = 1 }
		remote.call(NET, "insert", ctrl, BLANK, 2)
		local n = remote.call(MC, "paste", card, { t1, t2, i1 }, pinv)
		local f1, w1 = filled(t1)
		local f2, w2 = filled(t2)
		expect(n == 2 and f1 == 2 and w1 == 0 and f2 == 1 and w2 == 1 and pinv.is_empty()
			and remote.call(NET, "count", ctrl, BLANK) == 0, "the paste onto two providers: " .. serpent.line({ pasted = n,
			t1 = { f1, w1 }, t2 = { f2, w2 }, inventory = pinv.get_contents(), blanks = remote.call(NET, "count", ctrl, BLANK) }))
		pinv.destroy()
		--- an interface's row
		remote.call(IO, "set_interface_config", i1, { [1] = { name = "iron-plate", amount = 5 } })
		copied = remote.call(MC, "copy", card, { i1 }, area(i1))
		c = remote.call(MC, "content", card)
		expect(copied == i1.unit_number and c and c.name == IFACE, "the copy of an interface: " .. serpent.line(c and c.name))
		n = remote.call(MC, "paste", card, { i2, t1 }, nil)
		local cfg = remote.call(IO, "get_interface_config", i2)
		expect(n == 1 and cfg and cfg[1] and cfg[1].name == "iron-plate" and cfg[1].amount == 5, "the interface's row pasted: "
			.. serpent.line({ n, cfg }))
		--- emptied
		copied = remote.call(MC, "copy", card, {}, area(i1))
		expect(copied == nil and remote.call(MC, "content", card) == nil and (card.label or "") == "", "the card after a select over nothing: "
			.. serpent.line({ remote.call(MC, "content", card), card.label }))
		expect(remote.call(MC, "paste", card, { i2 }, nil) == 0, "an empty card pasted something")
		inv.destroy()
		return finish()
	end

	function T.running(check) check(storage.memcard561 and storage.memcard561.done, "ME Memory Card") end
	return T
end
