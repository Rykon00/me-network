--- Runtime test of me-network issue #585: the settings paste of a pattern provider fills its empty slots with the source's
--- patterns, the bulk clearing of encoded patterns in the ME Pattern Terminal and the provider's "Return all patterns".
---   * Settings paste: a source provider (on no network) holds A, B, C, D in slots 1 to 4, priority 7; the destination (on
---     network 1) holds E in slot 2. An inventory with an encoded C and one blank, the network with an encoded C and D: slot 1 A
---     from the inventory's blank, slot 2 keeps E (B is not copied), slot 3 C from the inventory's encoded one (the network's C
---     stays), slot 4 D from the network's; the inventory is empty, the priority 7. A second destination with an empty
---     inventory: C from the network's encoded one, A, B, D wait (yellow status 3).
---   * Clear patterns in inventory: an inventory with three encoded patterns (one broken), two blanks and iron plates: the count
---     is 3; after the clear no encoded pattern, five blanks, the plates as they were.
---   * Clear unused network patterns: network 1 stores X twice, Y, a broken pattern and A (held by the first destination): the
---     count is 4; after the clear only A is left encoded and the network has four more blanks.
---   * The same through the window (a stand-in player): the button asks with the count, Cancel forgets it, Confirm clears.
---   * Return all patterns: a provider with P and Q on network 1 is emptied, both are encoded in the network.
---   * Network 2 is full (1k cells full of iron plates, X stored twice): the clear clears none and says 2 are left, nothing is
---     made or lost; "Return all patterns" of its provider moves none and leaves its pattern in the slot.
--- Loaded by control.lua: require("patternbulk")(H) returns { setup, tick, running }.

local NET, AC, PT, GUI = "gregtorio-me-network", "gregtorio-me-autocraft", "gregtorio-me-pattern-terminal", "gregtorio-me-gui"
local BX, BY = 210, 200               -- (inside the cleared test area, TEST_RADIUS of control.lua; clear of the other tests)
local START = 170
local BLANK, ENCODED = "me-blank-pattern", "me-encoded-pattern"
local PREFIX = ENCODED .. "@normal#"
local function processing(input, output)
	return { kind = "processing", inputs = { { key = input, amount = 1 } }, outputs = { { key = output, amount = 1 } } }
end
--- (each pattern makes an item of its own: the tests tell them apart by their first output)
local DEFS = {
	A = processing("iron-plate", "iron-stick"), B = processing("copper-plate", "copper-cable"),
	C = processing("stone", "stone-brick"), D = processing("iron-plate", "iron-gear-wheel"),
	E = processing("wood", "wooden-chest"), X = processing("coal", "pipe"), Y = processing("iron-ore", "iron-chest"),
	P = processing("copper-ore", "small-electric-pole"), Q = processing("stone-brick", "stone-furnace"),
	R = processing("copper-ore", "copper-plate"),
}
local BROKEN = { kind = "crafting", recipe = "zz-devcheck-no-such-recipe" }

return function(H)
	local me_place, me_report = H.me_place, H.me_report
	local T = {}
	local function at(dx, dy) return { BX + dx + 0.5, BY + dy + 0.5 } end

	--- one encoded pattern of `def` (BROKEN: written as tags) into `target` (an inventory)
	local function encode_into(target, def)
		local tmp = game.create_inventory(2)
		if def == BROKEN then
			tmp[2].set_stack{ name = ENCODED, count = 1, tags = { fork_me_pattern = BROKEN } }
		else
			tmp[1].set_stack{ name = BLANK, count = 1 }
			remote.call(PT, "encode_def", tmp, nil, def)
		end
		local ok = tmp[2].valid_for_read and target.insert(tmp[2]) == 1
		tmp.destroy()
		return ok
	end

	--- a network: power, controller, a drive (4 cells of `tier`), a cable row at y = dy - 1 with the blocks on top of it
	local function network(s, fails, what, dy, tier)
		H.power(s, fails, what, BX, BY + dy)
		local ctrl = me_place(s, fails, what, "me-network-controller", BX + 6, BY + dy)
		local drive = H.me_drive(s, fails, what, BX + 7.5, BY + dy - 0.5, nil, tier)
		H.cable_row(s, fails, BX + 8, BX + 24, BY + dy - 1)
		if not (ctrl and drive) then fails[#fails + 1] = what .. ": the network was not built" end
	end

	function T.setup(s)
		local fails = {}
		local what = "pattern bulk"
		network(s, fails, what, 0, "16k")
		network(s, fails, what .. " (full network)", 30, "1k")
		local src = me_place(s, fails, what, "me-pattern-provider", BX + 0.5, BY + 10.5)    -- (on no network)
		if src and give_patterns(src, { DEFS.A, DEFS.B, DEFS.C, DEFS.D }, fails) ~= 4 then
			fails[#fails + 1] = what .. ": the source provider has not four patterns"
		end
		if src then remote.call(AC, "set_priority", src, 7) end
		local dst = me_place(s, fails, what, "me-pattern-provider", at(10, -2)[1], at(10, -2)[2])
		if dst then
			local inv = game.create_inventory(1)
			if not (encode_into(inv, DEFS.E) and remote.call(AC, "insert_pattern", dst, inv[1], 2) == 2) then
				fails[#fails + 1] = what .. ": E did not go into slot 2 of the destination"
			end
			inv.destroy()
		end
		me_place(s, fails, what, "me-pattern-provider", at(13, -2)[1], at(13, -2)[2])            -- the second destination
		local ret = me_place(s, fails, what, "me-pattern-provider", at(16, -2)[1], at(16, -2)[2])
		if ret then give_patterns(ret, { DEFS.P, DEFS.Q }, fails) end
		me_place(s, fails, what, "me-pattern-terminal", at(19, -2)[1], at(19, -2)[2])
		local ret2 = me_place(s, fails, what, "me-pattern-provider", at(16, 28)[1], at(16, 28)[2])
		if ret2 then give_patterns(ret2, { DEFS.R }, fails) end
		return fails
	end

	function T.tick()
		local st = storage.patternbulk585
		if game.tick < START or (st and st.done) then return end
		if not st then
			st = { problems = {} }
			storage.patternbulk585 = st
		end
		local s = game.surfaces[1]
		local problems = st.problems
		local function expect(ok, msg) if not ok then problems[#problems + 1] = msg end end
		local function finish()
			st.done = true
			me_report("PATTERNBULK", "Pattern paste and bulk clearing (issue #585)", problems, "settings paste fills the empty "
				.. "slots in the fill order and keeps full ones; inventory and unused network patterns cleared to blanks (a held "
				.. "one stays, a broken one counts as unused), through the window with its question; Return all patterns; a full "
				.. "network clears and returns nothing and loses nothing")
		end
		local ctrl = s.find_entity("me-network-controller", { BX + 6, BY })
		local ctrl2 = s.find_entity("me-network-controller", { BX + 6, BY + 30 })
		local src = s.find_entity("me-pattern-provider", at(0, 10))
		local dst = s.find_entity("me-pattern-provider", at(10, -2))
		local dst2 = s.find_entity("me-pattern-provider", at(13, -2))
		local ret = s.find_entity("me-pattern-provider", at(16, -2))
		local pterm = s.find_entity("me-pattern-terminal", at(19, -2))
		local ret2 = s.find_entity("me-pattern-provider", at(16, 28))
		if not (ctrl and ctrl2 and src and dst and dst2 and ret and pterm and ret2) then expect(false, "entities missing") return finish() end
		--- the letter of a pattern (by its first output; "broken" for one without), nil for none
		local function letter(raw)
			if type(raw) ~= "table" then return nil end
			if raw.kind == "crafting" then return "broken" end
			local out = raw.outputs and raw.outputs[1] and raw.outputs[1].key
			for k, d in pairs(DEFS) do
				if d.outputs[1].key == out then return k end
			end
			return "?"
		end
		--- the encoded patterns of a network by letter, and its blanks
		local function net_patterns(c)
			local out = {}
			for key, n in pairs(remote.call(NET, "contents", c)) do
				if key:sub(1, #PREFIX) == PREFIX then
					local data = helpers.json_to_table(key:sub(#PREFIX + 1))
					local k = letter(data and data.tags and data.tags.fork_me_pattern) or "?"
					out[k] = (out[k] or 0) + n
				end
			end
			return out, remote.call(NET, "contents", c)[BLANK] or 0
		end
		--- the letters of a provider's slots ("-" empty, lower case: waiting), and how many wait
		local function slots(p, n)
			local info = remote.call(AC, "provider_info", p) or { slots = {} }
			local out = {}
			for slot = 1, n do
				local d = info.slots[slot]
				local k = "-"
				if d then
					for name, def in pairs(DEFS) do
						if d.outputs and d.outputs[1] and d.outputs[1].key == def.outputs[1].key then k = name end
					end
					if d.pending then k = k:lower() end
				end
				out[#out + 1] = k
			end
			return table.concat(out), info.pending or 0, info
		end
		local function store(c, def, count)
			local tmp = game.create_inventory(1)
			local ok = true
			for _ = 1, count or 1 do
				ok = ok and encode_into(tmp, def) and remote.call(NET, "insert_stack", c, tmp[1]) == 1
			end
			tmp.destroy()
			return ok
		end

		--- the settings paste
		local one = slots(dst, 4)
		expect(one == "-E--", "the destination before the paste: " .. one)
		expect(store(ctrl, DEFS.C) and store(ctrl, DEFS.D), "storing an encoded C and D")
		local inv = game.create_inventory(10)
		encode_into(inv, DEFS.C)
		inv.insert{ name = BLANK, count = 1 }
		remote.call(AC, "paste", src, dst, inv)
		local f, n, info = slots(dst, 4)
		local enc, blanks = net_patterns(ctrl)
		expect(f == "AECD" and n == 0 and inv.is_empty() and info.priority == 7 and (enc.C or 0) == 1 and enc.D == nil
			and blanks == 0, "the paste onto a provider holding E in slot 2: slots " .. f .. ", waiting " .. n .. ", inventory "
			.. serpent.line(inv.get_contents()) .. ", priority " .. tostring(info.priority) .. ", network " .. serpent.line(enc)
			.. ", blanks " .. blanks)
		remote.call(AC, "paste", src, dst2, inv)
		f, n = slots(dst2, 4)
		enc = net_patterns(ctrl)
		local cs = remote.call(AC, "custom_status", dst2)
		expect(f == "abCd" and n == 3 and enc.C == nil and cs and cs.label and cs.label[1] == "fork-me-pattern.status-waiting"
			and tonumber(cs.label[2]) == 3, "the paste with an empty inventory: slots " .. f .. ", waiting " .. n .. ", network "
			.. serpent.line(enc) .. ", status " .. serpent.line(cs))

		--- Clear patterns in inventory
		inv.clear()
		inv.insert{ name = "iron-plate", count = 30 }
		encode_into(inv, DEFS.A)
		inv.insert{ name = BLANK, count = 2 }
		encode_into(inv, BROKEN)
		encode_into(inv, DEFS.X)
		local count = remote.call(PT, "bulk_count", pterm, "inventory", inv)
		local cleared, left = remote.call(PT, "bulk_clear", pterm, "inventory", inv)
		expect(count == 3 and cleared == 3 and left == 0 and inv.get_item_count(ENCODED) == 0 and inv.get_item_count(BLANK) == 5
			and inv.get_item_count("iron-plate") == 30, "clearing the inventory: count " .. tostring(count) .. ", cleared "
			.. tostring(cleared) .. ", left " .. tostring(left) .. ", inventory " .. serpent.line(inv.get_contents()))

		--- Clear unused network patterns
		expect(store(ctrl, DEFS.X, 2) and store(ctrl, DEFS.Y) and store(ctrl, BROKEN) and store(ctrl, DEFS.A),
			"storing X twice, Y, a broken pattern and A")
		local _, blanks0 = net_patterns(ctrl)
		count = remote.call(PT, "bulk_count", pterm, "network")
		cleared, left = remote.call(PT, "bulk_clear", pterm, "network", nil, inv)
		enc, blanks = net_patterns(ctrl)
		expect(count == 4 and cleared == 4 and left == 0 and serpent.line(enc) == serpent.line({ A = 1 }) and blanks == blanks0 + 4,
			"clearing the network: count " .. tostring(count) .. ", cleared " .. tostring(cleared) .. ", left " .. tostring(left)
			.. ", encoded " .. serpent.line(enc) .. ", blanks " .. blanks0 .. " -> " .. blanks)
		expect(remote.call(PT, "bulk_count", pterm, "network") == 0, "unused patterns after the clear")

		--- the same through the window, for a stand-in player
		local pinv = game.create_inventory(20)
		encode_into(pinv, DEFS.X)
		encode_into(pinv, DEFS.Y)
		remote.call(GUI, "stand_in", "patternbulk", { main = pinv, index = 9585, gui = true })
		local ok, err = pcall(remote.call, GUI, "stand_in_open_entity", "patternbulk", pterm)
		expect(ok and err, "the pattern terminal's window: " .. tostring(err))
		if ok and err then
			local v = remote.call(GUI, "stand_in_act", "patternbulk", "pat_bulk", "inventory", "fork_me_pat_confirm")
			local q = v and v.labels[1]
			expect(q and q[1] == "fork-me-pattern-terminal.confirm-inventory" and q[2] == 2 and #v.buttons == 2
				and pinv.get_item_count(ENCODED) == 2, "the question of Clear patterns in inventory: " .. serpent.line(v))
			v = remote.call(GUI, "stand_in_act", "patternbulk", "pat_bulk_cancel", false, "fork_me_pat_confirm")
			expect(v and #v.labels == 0 and pinv.get_item_count(ENCODED) == 2, "Cancel: " .. serpent.line(v))
			remote.call(GUI, "stand_in_act", "patternbulk", "pat_bulk", "inventory")
			v = remote.call(GUI, "stand_in_act", "patternbulk", "pat_bulk_ok", false, "fork_me_pat_confirm")
			local texts = remote.call(GUI, "stand_in_texts", "patternbulk")
			local last = texts[#texts]
			expect(v and #v.labels == 0 and pinv.get_item_count(ENCODED) == 0 and pinv.get_item_count(BLANK) == 2
				and type(last) == "table" and last[1] == "fork-me-pattern-terminal.cleared-inventory" and last[2] == 2,
				"Confirm: " .. serpent.line(v) .. ", inventory " .. serpent.line(pinv.get_contents()) .. ", text " .. serpent.line(last))
			remote.call(GUI, "stand_in_act", "patternbulk", "pat_bulk", "network")
			texts = remote.call(GUI, "stand_in_texts", "patternbulk")
			last = texts[#texts]
			expect(type(last) == "table" and last[1] == "fork-me-pattern-terminal.none-network",
				"Clear unused network patterns with none: " .. serpent.line(last))
			remote.call(GUI, "stand_in_close_window", "patternbulk", true)
		end
		remote.call(GUI, "stand_in_forget", "patternbulk")
		pinv.destroy()

		--- Return all patterns
		local moved
		moved, left = remote.call(AC, "return_patterns", ret)
		f, n = slots(ret, 4)
		enc = net_patterns(ctrl)
		expect(moved == 2 and left == 0 and f == "----" and enc.P == 1 and enc.Q == 1, "Return all patterns: moved " .. tostring(moved)
			.. ", left " .. tostring(left) .. ", slots " .. f .. ", network " .. serpent.line(enc))

		--- the full network
		expect(store(ctrl2, DEFS.X, 2), "storing X twice in the full network")
		remote.call(NET, "insert", ctrl2, "iron-plate", 10000000)
		local plates = remote.call(NET, "contents", ctrl2)["iron-plate"] or 0
		expect(remote.call(NET, "can_insert", ctrl2, BLANK, 1) == 0, "the full network still has room for a blank")
		inv.clear()
		count = remote.call(AC, "unused_network_patterns", ctrl2)
		cleared, left = remote.call(AC, "clear_network_patterns", ctrl2, inv)
		enc, blanks = net_patterns(ctrl2)
		expect(count == 2 and cleared == 0 and left == 2 and serpent.line(enc) == serpent.line({ X = 2 }) and blanks == 0
			and inv.is_empty() and (remote.call(NET, "contents", ctrl2)["iron-plate"] or 0) == plates,
			"clearing in a full network: count " .. tostring(count) .. ", cleared " .. tostring(cleared) .. ", left "
			.. tostring(left) .. ", encoded " .. serpent.line(enc) .. ", blanks " .. blanks .. ", back " .. serpent.line(inv.get_contents()))
		moved, left = remote.call(AC, "return_patterns", ret2)
		f = slots(ret2, 1)
		expect(moved == 0 and left == 1 and f == "R", "Return all patterns into a full network: moved " .. tostring(moved)
			.. ", left " .. tostring(left) .. ", slots " .. f)
		inv.destroy()
		return finish()
	end

	function T.running(check) check(storage.patternbulk585 and storage.patternbulk585.done, "Pattern paste and bulk clearing") end
	return T
end
