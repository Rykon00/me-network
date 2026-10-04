--- Runtime test of the holder cursors of the storage engine (me-network issue #43, scripts/fork-me-network.lua
--- first_holder): an insert skips the full cells in front of the first one with room, and an extraction that frees
--- room in a skipped cell brings it back, so the order of AE2 (the first cell with room, by drive priority and slot)
--- is unchanged. Two small networks: one drive (the plain order) and two drives of different priority (the ranked
--- order). Each fills its cells, takes a little out of the first cell (or takes a second key out of it, which frees
--- a type), and expects the next insert to go there. Loaded by control.lua: require("holders")(H) returns
--- { setup, tick, running }.

local NET = "gregtorio-me-network"
local BX, BY = 370, -345
local CHECK = 400

return function(H)
	local me_place, me_report = H.me_place, H.me_report
	local T = {}

	local function build(s, fails, what, bx, by, drives)
		local eei = me_place(s, fails, what, "electric-energy-interface", bx + 12.5, by + 6.5)
		if eei then
			eei.power_production = 1e6
			eei.electric_buffer_size = 1e7
		end
		me_place(s, fails, what, "substation", bx + 13, by + 2)
		local ctrl = me_place(s, fails, what, "me-network-controller", bx + 6, by)
		local all = { ctrl }
		for i = 1, drives do
			all[#all + 1] = me_drive(s, fails, what, bx + 8.5 - 4 * (i - 1), by + 4.5, {}, "1k")
		end
		me_connect(fails, what, all)
		return ctrl, all
	end

	function T.setup(s)
		local fails = {}
		local c1, a1 = build(s, fails, "holders plain", BX, BY, 1)
		local c2, a2 = build(s, fails, "holders ranked", BX + 30, BY, 2)
		storage.holders43_scene = { plain = { ctrl = c1, drives = { a1[2] } }, ranked = { ctrl = c2, drives = { a2[2], a2[3] } } }
		return fails
	end

	local function holders(ctrl, key)
		return remote.call(NET, "holders", ctrl, key) or {}
	end

	function T.tick()
		local st = storage.holders43
		if not st then
			if game.tick < CHECK then return end
			st = { problems = {}, done = false }
			storage.holders43 = st
		end
		if st.done then return end
		local problems = st.problems
		local function expect(ok, what) if not ok then problems[#problems + 1] = what end end
		local sc = storage.holders43_scene
		if not (sc and sc.plain.ctrl and sc.plain.ctrl.valid and sc.ranked.ctrl and sc.ranked.ctrl.valid) then
			problems[#problems + 1] = "the test networks were not built"
		else
			local IRON, COPPER = "iron-plate", "copper-plate"
			--- the plain order (one priority, no partition)
			do
				local ctrl, d1 = sc.plain.ctrl, sc.plain.drives[1]
				local cid1 = d1.unit_number .. ":1"
				expect(remote.call(NET, "insert", ctrl, COPPER, 10) == 10, "plain: copper in")
				local stored = remote.call(NET, "insert", ctrl, IRON, 1e7)
				expect(stored > 10000, "plain: only " .. stored .. " iron plates fit")
				local before = holders(ctrl, IRON)
				expect(before[cid1] ~= nil and next(before, next(before)) ~= nil, "plain: iron is not in several cells " .. serpent.line(before))
				expect(remote.call(NET, "insert", ctrl, IRON, 100) == 0, "plain: a full network took iron")
				expect(remote.call(NET, "can_insert", ctrl, IRON, 100) == 0, "plain: a full network has room for iron")
				--- 500 iron out of the first cell: the next insert goes there
				expect(remote.call(NET, "extract", ctrl, IRON, 500) == 500, "plain: extract 500")
				local mid = holders(ctrl, IRON)
				local room = remote.call(NET, "can_insert", ctrl, IRON, 100000)
				expect(room >= 500 and room < 600, "plain: room after the 500 left is " .. room)
				expect(mid[cid1] == before[cid1] - 500, "plain: the first cell lost the 500: " .. serpent.line(mid))
				expect(remote.call(NET, "insert", ctrl, IRON, 300) == 300, "plain: insert 300")
				local after = holders(ctrl, IRON)
				expect(after[cid1] == mid[cid1] + 300, "plain: the 300 did not go to the first cell: " .. serpent.line(after))
				local room2 = remote.call(NET, "can_insert", ctrl, IRON, 100000)
				expect(room2 >= room - 300 and room2 < room - 200, "plain: room after the 300 came back is " .. room2 .. ", was " .. room)
				--- freed room again and again
				for i = 1, 5 do
					expect(remote.call(NET, "extract", ctrl, IRON, 40) == 40, "plain: extract 40, round " .. i)
					expect(remote.call(NET, "insert", ctrl, IRON, 40) == 40, "plain: insert 40, round " .. i)
				end
				local again = holders(ctrl, IRON)
				expect(again[cid1] == after[cid1], "plain: the rounds moved the first cell " .. serpent.line(again))
				--- a second key leaves the first cell: its bytes and its type are free for iron
				local copper = holders(ctrl, COPPER)
				expect(copper[cid1] == 10, "plain: copper is in the first cell " .. serpent.line(copper))
				expect(remote.call(NET, "extract", ctrl, COPPER, 10) == 10, "plain: copper out")
				local freed = remote.call(NET, "insert", ctrl, IRON, 5)
				expect(freed >= 1, "plain: no room after copper left")
				local last = holders(ctrl, IRON)
				expect(last[cid1] == again[cid1] + freed, "plain: the iron after copper left did not go to the first cell: "
					.. serpent.line(last))
			end
			--- the ranked order (two drives, the second of the higher priority)
			do
				local ctrl, d1, d2 = sc.ranked.ctrl, sc.ranked.drives[1], sc.ranked.drives[2]
				remote.call(NET, "set_priority", d2, 5)
				local lo, hi = d1.unit_number .. ":1", d2.unit_number .. ":1"
				local stored = remote.call(NET, "insert", ctrl, IRON, 1e7)
				expect(stored > 20000, "ranked: only " .. stored .. " iron plates fit")
				local full = holders(ctrl, IRON)
				expect(full[lo] and full[hi], "ranked: both drives hold iron " .. serpent.line(full))
				expect(remote.call(NET, "insert", ctrl, IRON, 100) == 0, "ranked: a full network took iron")
				--- extraction takes the low priority drive first: empty it, then 700 from the high one
				local low_total = 0
				for cid, n in pairs(full) do if cid:match("^" .. d1.unit_number .. ":") then low_total = low_total + n end end
				expect(remote.call(NET, "extract", ctrl, IRON, low_total + 700) == low_total + 700, "ranked: extract")
				local mid = holders(ctrl, IRON)
				expect(remote.call(NET, "can_insert", ctrl, IRON, 1e7) >= low_total + 700, "ranked: room after the extraction")
				--- the high priority drive is filled first: 600 go to its first cell with room, the rest to the low one
				expect(remote.call(NET, "insert", ctrl, IRON, 600) == 600, "ranked: insert 600")
				local after = holders(ctrl, IRON)
				local gained_hi = 0
				for cid, n in pairs(after) do
					if cid:match("^" .. d2.unit_number .. ":") then gained_hi = gained_hi + n - (mid[cid] or 0) end
				end
				expect(gained_hi == 600, "ranked: the 600 did not go to the high priority drive (" .. gained_hi .. ") " .. serpent.line(after))
				--- and the order is the same for a later round
				expect(remote.call(NET, "extract", ctrl, IRON, 30) == 30 and remote.call(NET, "insert", ctrl, IRON, 30) == 30, "ranked: round trip")
			end
		end
		st.done = true
		me_report("HOLDERS", "ME storage engine holder cursors", problems,
			"full cells at the front are skipped; an extraction that frees room (a second key out of the cell too) brings them back, in the plain and the ranked order")
	end

	function T.running(check) check(storage.holders43 and storage.holders43.done, "ME holder cursors") end
	return T
end
