--- Runtime test of me-network issue #514: the ME Terminal's quality filter and sort by quality. A network holds iron plates
--- in normal (30), uncommon (10) and legendary (10) quality, copper plates (5) and water (a game without the quality mod
--- skips the test with a note). Through the remote `entries` (the window's list):
--- * the filter: "= rare" shows nothing, "= uncommon" the uncommon plates, "≥ uncommon" the uncommon and the legendary
---   ones, "≤ normal" the normal plates and the water (a fluid counts as normal quality);
--- * the sort "quality": higher quality first, then name, then amount; the sort "name" and "count": the qualities of one
---   name by their level (normal, uncommon, legendary), not by the key's text (that would be legendary before uncommon);
--- * the kept lists: a filter is a list of its own, switching back gives the kept one; any quality (nil, or "=" without a
---   quality) is the list from before the filter, and the call without the argument too;
--- * the row above the tabs (remote terminal_top_view) has the comparator and the quality drop-down, set from the state.
--- Loaded by control.lua like lab.lua.

local NET, TERM, GUI = "gregtorio-me-network", "gregtorio-me-terminal", "gregtorio-me-gui"
local BX, BY = 150, -20                  -- (inside the cleared test area, TEST_RADIUS of control.lua; clear of the other tests)
local CHECK = 120

return function(H)
	local me_place, me_report, power = H.me_place, H.me_report, H.power
	local T = {}

	function T.setup(s)
		local fails = {}
		local what = "terminal quality filter"
		power(s, fails, what, BX, BY)
		local ctrl = me_place(s, fails, what, "me-network-controller", BX + 7, BY)
		local drive = H.me_drive(s, fails, what, BX + 8.5, BY - 0.5, {}, "16k")
		local fdrive = H.me_drive(s, fails, what, BX + 8.5, BY + 0.5, {}, "1k", true)
		local term = me_place(s, fails, what, "me-terminal", BX + 12.5, BY - 2.5)
		H.me_connect(fails, what, { ctrl, drive, fdrive, term })
		storage.qualityterm514_scene = { ctrl = ctrl, term = term }
		return fails
	end

	function T.tick()
		if game.tick ~= CHECK then return end
		local st = { problems = {}, done = true }
		storage.qualityterm514 = st
		local q = prototypes.quality
		if not (q.uncommon and q.rare and q.legendary) then
			return me_report("QUALITYTERM", "ME Terminal quality filter", {}, "no quality mod: skipped")
		end
		local problems = st.problems
		local sc = storage.qualityterm514_scene
		local ctrl, term = sc and sc.ctrl, sc and sc.term
		if not (ctrl and ctrl.valid and term and term.valid) then
			return me_report("QUALITYTERM", "ME Terminal quality filter", { "the test blocks were not built" })
		end
		remote.call(NET, "insert", ctrl, "iron-plate", 30)
		remote.call(NET, "insert", ctrl, "iron-plate", 10, "uncommon")
		remote.call(NET, "insert", ctrl, "iron-plate", 10, "legendary")
		remote.call(NET, "insert", ctrl, "copper-plate", 5)
		remote.call(NET, "insert_fluid", ctrl, "water", 1000)
		local function keys(sort, quality, fresh)
			local out = {}
			for i, e in ipairs(remote.call(TERM, "entries", term, "", sort, "all", fresh, nil, nil, nil, quality)) do
				out[i] = e.fluid and "water" or e.key
			end
			return table.concat(out, " ")
		end
		local function expect(got, want, what)
			if got ~= want then problems[#problems + 1] = what .. ": " .. got .. " (expected " .. want .. ")" end
		end
		--- the filter
		expect(keys("count", { cmp = "=", name = "rare" }, true), "", "= rare")
		expect(keys("count", { cmp = "=", name = "uncommon" }, true), "iron-plate@uncommon", "= uncommon")
		expect(keys("count", { cmp = ">=", name = "uncommon" }, true), "iron-plate@uncommon iron-plate@legendary", "≥ uncommon")
		expect(keys("count", { cmp = "<=", name = "normal" }, true), "iron-plate copper-plate water", "≤ normal")
		--- the sorts
		expect(keys("quality", nil, true), "iron-plate@legendary iron-plate@uncommon copper-plate iron-plate water", "sort quality")
		expect(keys("name", nil, true), "copper-plate iron-plate iron-plate@uncommon iron-plate@legendary water", "sort name")
		expect(keys("count", nil, true), "iron-plate iron-plate@uncommon iron-plate@legendary copper-plate water", "sort count")
		--- the kept lists (the network does not change between the calls)
		local function kept() return remote.call(TERM, "entries_stats").kept end
		local up = { cmp = ">=", name = "uncommon" }
		local all = keys("name")
		local k = kept()
		expect(keys("name", nil), all, "any quality (nil), again")
		expect(keys("name", { cmp = "=" }), all, "any quality (= without a quality)")
		expect(keys("name", { cmp = "<=", name = "zz-no-such-quality" }), all, "a quality the game does not know")
		expect(tostring(kept() - k), "3", "lists kept for any quality (the id from before the filter)")
		local filtered = keys("name", up)
		expect(filtered, "iron-plate@uncommon iron-plate@legendary", "≥ uncommon, sort name")
		k = kept()
		expect(keys("name"), all, "back to any quality")
		expect(keys("name", up), filtered, "back to ≥ uncommon")
		expect(tostring(kept() - k), "2", "lists kept when switching back")
		--- the row above the tabs
		local row = remote.call(GUI, "terminal_top_view", { cmp = ">=", name = "uncommon" })
		local by = {}
		for _, c in ipairs(row) do if c.name then by[c.name] = c end end
		local cmp, dd = by.fork_me_qcmp, by.fork_me_quality
		if not (cmp and dd) then
			problems[#problems + 1] = "the row above the tabs has no quality filter: " .. serpent.line(row)
		else
			expect(tostring(cmp.selected_index) .. " of " .. #cmp.items, "2 of 3", "the comparator drop-down")
			local visible = remote.call(GUI, "workbench_qualities")
			local want = 1
			for i, name in ipairs(visible) do if name == "uncommon" then want = i + 1 end end
			expect(tostring(dd.selected_index) .. " of " .. #dd.items, want .. " of " .. (#visible + 1), "the quality drop-down")
		end
		local plain = remote.call(GUI, "terminal_top_view")
		for _, c in ipairs(plain) do
			if c.name == "fork_me_quality" and c.selected_index ~= 1 then
				problems[#problems + 1] = "without a filter the quality drop-down shows " .. c.selected_index
			end
		end
		me_report("QUALITYTERM", "ME Terminal quality filter", problems, "filter, sorts, kept lists and the row checked")
	end

	function T.running(check) check(storage.qualityterm514 and storage.qualityterm514.done, "ME Terminal quality filter") end
	return T
end
