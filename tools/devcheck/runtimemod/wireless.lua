--- Runtime test of me-network issues #205 to #210 (the wireless terminal, docs/ME-WIRELESS.md). The harness has no player, so
--- the hotkey and the windows are not run; their functions are: the access point (a member, its power by the boosters, the range,
--- the nearest access point of a network in range, mined with its boosters, a blueprint tag that wants boosters from the network),
--- the terminal item (its data, linking, draining, the use rate), the charger (in and out, its power draw while it charges, the
--- charge per step, full), the module (issue #209's first step: the engine keeps the energy the script sets on a battery piece
--- in a grid; logged as DEVCHECK-RUNTIME-WIRELESS-EQUIPMENT) and the pattern mode's Encode into an inventory.
--- Loaded by control.lua: require("wireless")(H) returns { setup, tick, running }.

local NET, WL, PT = "gregtorio-me-network", "gregtorio-me-wireless", "gregtorio-me-pattern-terminal"
local BX, BY = 100, -380
local START = 160
local ITEM, BOOSTER = "me-wireless-terminal", "me-wireless-booster"

return function(H)
	local me_place, me_report, power = H.me_place, H.me_report, H.power
	local T = {}

	function T.setup(s)
		local fails = {}
		local what = "wireless"
		power(s, fails, what, BX, BY)
		local ctrl = me_place(s, fails, what, "me-network-controller", BX + 7, BY)
		local drive = H.me_drive(s, fails, what, BX + 8.5, BY - 0.5, {}, "16k")
		local term = me_place(s, fails, what, "me-terminal", BX + 10.5, BY - 0.5)
		H.cable_row(s, fails, BX + 11, BX + 22, BY - 1)
		me_place(s, fails, what, "me-wireless-access-point", BX + 12.5, BY + 0.5)    -- A: the one under test
		me_place(s, fails, what, "me-charger", BX + 14.5, BY + 0.5)
		me_place(s, fails, what, "me-wireless-access-point", BX + 16.5, BY + 0.5)    -- B: mined
		me_place(s, fails, what, "me-wireless-access-point", BX + 18.5, BY + 0.5)    -- C: built from a tag
		H.me_connect(fails, what, { ctrl, drive, term })
		return fails
	end

	local function rows_of(n, kind)
		for _, r in ipairs(n and n.power_rows or {}) do if r.key == kind then return r end end
		return nil
	end

	function T.tick()
		local st = storage.wireless205
		if st and st.done then return end
		if not st then
			if game.tick < START then return end
			st = { problems = {}, phase = "start" }
			storage.wireless205 = st
		end
		local problems = st.problems
		local function expect(ok, text) if not ok then problems[#problems + 1] = text end end
		local s = game.surfaces[1]
		local function find(name, x, y) return s.find_entity(name, { BX + x, BY + y }) end
		local t = find("me-terminal", 10.5, -0.5)
		local a, ch = find("me-wireless-access-point", 12.5, 0.5), find("me-charger", 14.5, 0.5)
		local function finish(note)
			st.done = true
			if st.inv and st.inv.valid then st.inv.destroy() end
			me_report("WIRELESS", "ME wireless terminal", problems, note)
		end
		if not (t and a and ch) then
			problems[#problems + 1] = "entities missing"
			return finish()
		end
		local function net() return remote.call(NET, "network", t) end
		local function count(name) return remote.call(NET, "count", t, name) end

		if st.phase == "start" then
			--- the access point is a member; it draws 20 kW without boosters
			local n0 = net()
			local r0 = rows_of(n0, "access-point")
			expect(r0 and r0.n == 3 and r0.w == 3 * 20000, "the access points' power without boosters: " .. serpent.line(r0))
			expect(remote.call(WL, "range_of", 0) == 32 and math.abs(remote.call(WL, "range_of", 4) - 224) < 0.01,
				"range: " .. remote.call(WL, "range_of", 0) .. ", " .. remote.call(WL, "range_of", 4))
			--- two boosters into A
			st.inv = game.create_inventory(20)
			local inv = st.inv
			local hand = inv[1]
			for slot = 1, 2 do
				hand.set_stack{ name = BOOSTER, count = 1 }
				expect(remote.call(WL, "ap_card_click", a, slot, hand, inv, false) == nil and not hand.valid_for_read, "booster " .. slot)
			end
			hand.set_stack{ name = "me-capacity-card", count = 1 }
			expect(remote.call(WL, "ap_card_click", a, 3, hand, inv, false) == "not-here", "a capacity card is refused")
			hand.clear()
			local n1 = net()
			local r1 = rows_of(n1, "access-point")
			local want = 2 * 20000 + remote.call(WL, "power_of", 2)
			expect(r1 and math.abs(r1.w - want) < 1, "the power with two boosters: " .. serpent.line(r1) .. ", expected " .. want)
			local r = remote.call(WL, "ap_range", a)
			expect(math.abs(r - (32 + 24 * 2 ^ 1.5)) < 0.01, "the range with two boosters: " .. r)
			--- the nearest access point in range
			local pos = { x = a.position.x, y = a.position.y + 60 }
			local found = remote.call(WL, "anchor_for", t, s, pos)
			expect(found == a, "a position 60 tiles away is in A's range: " .. tostring(found and found.position.x))
			found = remote.call(WL, "anchor_for", t, s, { x = a.position.x, y = a.position.y + 150 })
			expect(found == nil, "150 tiles away is out of range")
			--- the terminal item: no data, linked to the network of A (its controller)
			local item = inv[2]
			item.set_stack{ name = ITEM, count = 1 }
			local d = remote.call(WL, "item_data", item)
			expect(d and d.energy == 0 and d.link == nil, "a new terminal: " .. serpent.line(d))
			expect(remote.call(WL, "link_item", item, a) == true, "linked")
			d = remote.call(WL, "item_data", item)
			expect(d.link ~= nil and d.link == remote.call(WL, "controller_unit", a), "the link is the controller: " .. serpent.line(d))
			expect(remote.call(WL, "use_rate", "item", 50, 100) == 300000, "the use rate at half the range")
			--- the charger: the terminal goes in, the charger draws its charge rate
			local nb = remote.call(WL, "numbers")
			hand.transfer_stack(item)
			expect(remote.call(WL, "charger_click", ch, hand, inv, false) == nil and not hand.valid_for_read, "the terminal into the charger")
			local info = remote.call(WL, "charger_info", ch)
			expect(info.charging and info.charge == 0 and info.linked, "the charger charges: " .. serpent.line(info))
			local rc = rows_of(net(), "charger")
			expect(rc and rc.w == nb.charge_rate, "the charger draws its charge rate: " .. serpent.line(rc))
			st.phase, st.tick = "charging", game.tick
			return
		end

		if st.phase == "charging" then
			if game.tick < st.tick + 120 then return end
			local nb = remote.call(WL, "numbers")
			local info = remote.call(WL, "charger_info", ch)
			--- the network's slow step charged it about one charge rate per second
			expect(info.charge and info.charge > 0 and info.charge * nb.item_buffer <= nb.charge_rate * 3,
				"charged after two seconds: " .. serpent.line(info))
			--- almost full: the next step fills it and the charger goes idle
			local slot = remote.call(WL, "charger_inventory", ch)[1]
			remote.call(WL, "set_item_energy", slot, nb.item_buffer - 1)
			st.phase, st.tick = "full", game.tick
			return
		end

		if st.phase == "full" then
			if game.tick < st.tick + 70 then return end
			local nb = remote.call(WL, "numbers")
			local info = remote.call(WL, "charger_info", ch)
			expect(info.charge == 1 and not info.charging, "full: " .. serpent.line(info))
			local rc = rows_of(net(), "charger")
			expect(rc and rc.w == nb.charger_idle, "an idle charger draws " .. serpent.line(rc))
			--- out of the charger, drained
			local inv = st.inv
			local hand = inv[1]
			expect(remote.call(WL, "charger_click", ch, hand, inv, false) == nil and hand.valid_for_read and hand.name == ITEM, "taken out")
			local left = remote.call(WL, "drain_item", hand, 10000000)
			expect(math.abs(left - (nb.item_buffer - 10000000)) < 1, "drained by 10 MJ: " .. left)
			expect(remote.call(WL, "drain_item", hand, 1e12) == 0, "drained to empty, never below 0")
			--- B mined with two boosters: they go into the buffer
			local b = find("me-wireless-access-point", 16.5, 0.5)
			for slot = 1, 2 do
				hand.set_stack{ name = BOOSTER, count = 1 }
				remote.call(WL, "ap_card_click", b, slot, hand, inv, false)
			end
			local buffer = game.create_inventory(10)
			remote.call(WL, "on_removed", b, buffer)
			expect(buffer.get_item_count(BOOSTER) == 2, "B mined: " .. buffer.get_item_count(BOOSTER) .. " boosters")
			buffer.destroy()
			--- C built from a blueprint tag that asks for three boosters: they come from the network
			remote.call(NET, "insert", t, BOOSTER, 5)
			local before = count(BOOSTER)
			local c = find("me-wireless-access-point", 18.5, 0.5)
			remote.call(WL, "built", c, { fork_me_access_point = { cards = { BOOSTER, BOOSTER, BOOSTER } } })
			expect(math.abs(remote.call(WL, "ap_range", c) - (32 + 24 * 3 ^ 1.5)) < 0.01 and count(BOOSTER) == before - 3,
				"C took three boosters from the network: range " .. remote.call(WL, "ap_range", c) .. ", network " .. count(BOOSTER))
			--- the pattern mode: Encode into an inventory, the blank from the network
			remote.call(NET, "insert", t, "me-blank-pattern", 3)
			local blanks = count("me-blank-pattern")
			local ed = remote.call(PT, "new_editor")
			local ok
			ed.mode = "processing"                                      -- (a processing pattern: no recipe that must be researched)
			ok, ed = remote.call(PT, "set_editor_row", ed, "inputs", 1, "stone", 2)
			_, ed = remote.call(PT, "set_editor_row", ed, "outputs", 1, "stone-brick", 1)
			local out = game.create_inventory(2)
			local where, why = remote.call(PT, "encode_wireless", a, game.forces.player, ed, out)
			expect(ok and where == "inventory" and out.get_item_count("me-encoded-pattern") == 1 and count("me-blank-pattern") == blanks - 1,
				"wireless encode: " .. tostring(where) .. "/" .. tostring(why) .. ", " .. count("me-blank-pattern") .. " blanks")
			out[2].set_stack{ name = "iron-plate", count = 100 }
			out[1].set_stack{ name = "iron-plate", count = 100 }
			where, why = remote.call(PT, "encode_wireless", a, game.forces.player, ed, out)
			expect(where == nil and why == "inventory-full" and count("me-blank-pattern") == blanks - 1,
				"a full inventory is refused before a blank is used: " .. tostring(why))
			out.destroy()
			--- issue #209, first step: a battery piece in a grid keeps the energy the script sets
			local char = s.create_entity{ name = "character", position = { BX + 30, BY + 10 }, force = "player" }
			local note = "no character"
			if char then
				char.get_inventory(defines.inventory.character_armor).insert{ name = "modular-armor", count = 1 }
				local grid = char.grid
				local eq = grid and grid.put{ name = "me-wireless-module" }
				if eq then
					eq.energy = 5000000
					local left_eq = remote.call(WL, "drain_equipment", eq, 2000000)
					expect(math.abs(left_eq - 3000000) < 1 and math.abs(eq.energy - 3000000) < 1,
						"the module's energy after the script drained 2 MJ: " .. eq.energy)
					st.char, st.eq_energy = char, eq.energy
					note = "set 5 MJ, drained 2 MJ, read " .. eq.energy
				else
					expect(false, "the module did not go into a modular armour's grid")
				end
			end
			st.note = note
			st.phase, st.tick = "equipment", game.tick
			return
		end

		if st.phase == "equipment" then
			if game.tick < st.tick + 30 then return end
			local char = st.char
			local eq = char and char.valid and char.grid and char.grid.equipment[1]
			if eq then
				--- (no generator in the grid: nothing charges it; the engine must not reset what the script wrote)
				log("DEVCHECK-RUNTIME-WIRELESS-EQUIPMENT " .. st.note .. "; 30 ticks later: " .. eq.energy)
				expect(math.abs(eq.energy - st.eq_energy) < 1, "the module's energy kept 30 ticks later: " .. eq.energy)
				char.destroy()
			end
			finish("access point power and range, nearest in range, boosters, item link and drain, charger, mined, tag, pattern encode, module energy")
		end
	end

	function T.running(check) check(storage.wireless205 and storage.wireless205.done, "ME wireless terminal") end

	return T
end
