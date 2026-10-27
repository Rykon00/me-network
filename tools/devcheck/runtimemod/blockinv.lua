--- Runtime test of me-network issue #543: the card slots of the ME windows are the game's `inventory` element with the
--- game's handling off, so every click goes through the window's own click rule. The harness has no player: each block's
--- window is opened for a stand-in player (remote gregtorio-me-gui stand_in with `gui`, stand_in_open_entity: the open key's
--- path and one refresh), the element is looked up (bound to the block's card inventory, the game's cursor handling off, an
--- empty slot's tooltip), and its actions are called as on_gui_inventory_action calls them (block_action): a wrong item in the
--- hand is refused and stays there, a card goes in (one of the hand's stack, by click and by right click), shift + click takes
--- it into the inventory, control + click every card of that kind, a click in remote view takes it into the inventory; no
--- card is made or lost. Per window: ME Interface, Import Bus, Storage Bus, Pattern Provider, Logistic Interface, IO Port
--- (its cell slots stay buttons: a part of its inventory) and Wireless Access Point.
--- Loaded by control.lua: require("blockinv")(H) returns { setup, tick, running }.

local GUI = "gregtorio-me-gui"
local BX, BY = 40, -300
local START = 140

--- each block: its entity, where it stands, the flow of its card slots, an accepted card and how many of it the block takes
local BLOCKS = {
	{ name = "me-network-interface", x = 0.5, box = "fork_me_if_cards", card = "me-interface-capacity-card", limit = 3 },
	{ name = "me-import-bus", x = 4.5, box = "fork_me_bus_cards", card = "me-acceleration-card", limit = 4 },
	{ name = "me-storage-bus", x = 8.5, box = "fork_me_sbus_cards", card = "me-capacity-card", limit = 5 },
	{ name = "me-pattern-provider", x = 12.5, box = "fork_me_prov_cards", card = "me-pattern-capacity-card", limit = 3 },
	{ name = "me-logistic-interface", x = 16.5, box = "fork_me_lif_cards", card = "me-interface-capacity-card", limit = 3 },
	{ name = "me-io-port", x = 20.5, box = "fork_me_iop_cards", card = "me-acceleration-card", limit = 4, offset = 2,
	  buttons = { "fork_me_iop_in", "fork_me_iop_out" } },
	{ name = "me-wireless-access-point", x = 24.5, box = "fork_me_ap_cards", card = "me-wireless-booster", limit = 4 },
}

return function(H)
	local me_place, me_report = H.me_place, H.me_report
	local T = {}

	function T.setup(s)
		local fails = {}
		for _, b in ipairs(BLOCKS) do me_place(s, fails, "block inventories", b.name, BX + b.x, BY + 0.5) end
		return fails
	end

	function T.tick()
		local st = storage.blockinv
		if st or game.tick < START then return end
		st = { problems = {}, done = true }
		storage.blockinv = st
		local problems = st.problems
		local function expect(ok, text) if not ok then problems[#problems + 1] = text end end
		local g = function(fn, ...) return remote.call(GUI, fn, ...) end
		local s = game.surfaces[1]
		local pinv = game.create_inventory(20)
		local hold = game.create_inventory(1)
		local cursor = hold[1]
		g("stand_in", "blockinv", { main = pinv, index = 9401, gui = true })
		local done = {}
		for _, b in ipairs(BLOCKS) do
			local e = s.find_entity(b.name, { BX + b.x, BY + 0.5 })
			local what = b.name .. ": "
			local ok, view = pcall(g, "stand_in_open_entity", "blockinv", e)
			local el
			for _, x in ipairs(ok and view and view.elements or {}) do
				if x.box == b.box then el = x end
			end
			if not e then
				expect(false, what .. "not built")
			elseif not ok then
				expect(false, what .. "the window: " .. tostring(view))
			elseif not el then
				expect(false, what .. "no inventory element in " .. b.box .. ": " .. serpent.line(view))
			else
				local binv = el.inventory
				expect(binv and binv.valid and #binv == el.size and el.cursor_transfer == false and el.offset == (b.offset or 0)
					and el.empty ~= nil, what .. "the element: " .. serpent.line(el))
				for _, name in ipairs(b.buttons or {}) do
					expect((view.buttons[name] or 0) == 1, what .. name .. " stays a slot button: " .. serpent.line(view.buttons))
				end
				local function count(i, name) return i.get_item_count(name) end
				local function act(slot, mode) return g("block_action", e, binv, slot, mode, cursor, pinv, b.offset) end
				local function total() return count(binv, b.card) + count(pinv, b.card) + count(hold, b.card) end
				--- a wrong item in the hand: refused, it stays in the hand
				cursor.set_stack{ name = "iron-plate", count = 5 }
				local why = act(1, "click")
				expect(why ~= nil and cursor.valid_for_read and cursor.name == "iron-plate" and cursor.count == 5 and count(binv, "iron-plate") == 0,
					what .. "iron plates refused: " .. tostring(why))
				why = act(1, "right")
				expect(why ~= nil and cursor.count == 5 and count(binv, "iron-plate") == 0, what .. "iron plates by right click: " .. tostring(why))
				cursor.clear()
				--- a card: one of the hand's stack goes in, by click and by right click
				cursor.set_stack{ name = b.card, count = 3 }
				local before = total()
				why = act(1, "click")
				expect(why == nil and count(binv, b.card) == 1 and cursor.count == 2, what .. "a card by click: " .. tostring(why) .. ", "
					.. count(binv, b.card) .. " in")
				why = act(2, "right")
				expect(why == nil and count(binv, b.card) == 2 and cursor.count == 1, what .. "a card by right click: " .. tostring(why))
				pinv.insert(cursor)
				cursor.clear()
				--- shift + click: into the inventory; control + click: every card of the kind
				local slot
				for i = 1, #binv do if binv[i].valid_for_read then slot = i break end end
				why = act(slot, "shift")
				expect(why == nil and count(binv, b.card) == 1, what .. "shift + click takes a card out: " .. tostring(why))
				local p = pinv.find_item_stack(b.card)
				if p then cursor.transfer_stack(p, 1) end
				act(1, "click")
				cursor.clear()
				for i = 1, #binv do if binv[i].valid_for_read then slot = i break end end
				why = act(slot, "control")
				expect(why == nil and count(binv, b.card) == 0 and count(pinv, b.card) == 3, what .. "control + click takes every card: "
					.. tostring(why) .. ", " .. count(binv, b.card) .. " left")
				--- remote view: a click takes the card into the inventory
				p = pinv.find_item_stack(b.card)
				if p then cursor.transfer_stack(p, 1) end
				act(1, "click")
				why = act(1, "remote")
				expect(why == nil and count(binv, b.card) == 0, what .. "a click in remote view takes it out: " .. tostring(why))
				if cursor.valid_for_read then pinv.insert(cursor) end
				cursor.clear()
				expect(total() == before, what .. "cards made or lost: " .. before .. " -> " .. total())
				pinv.clear()
				done[#done + 1] = b.name
			end
		end
		g("stand_in_close_window", "blockinv", false)
		g("stand_in_forget", "blockinv")
		pinv.destroy()
		hold.destroy()
		me_report("BLOCKINV", "ME windows: block slots as inventory elements", problems, table.concat(done, ", ")
			.. ": the element, a wrong item refused by click and right click, a card by click and right click, shift, control, remote view")
	end

	function T.running(check) check(storage.blockinv and storage.blockinv.done, "ME windows: block slots as inventory elements") end

	return T
end
