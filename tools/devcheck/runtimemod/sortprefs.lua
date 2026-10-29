--- Runtime test of me-network issue #602, points 2 to 4: the ME Terminal's sort. A network holds iron plates (30), copper
--- plates (20), iron gears (10), ME Crafting Cards (5, an item of this mod), iron ore (3) and water,
--- with two ME Terminals. Through a stand-in player with a GUI (the windows' own code):
--- * the sort is the player's: "Sort" in terminal A turns it to name, terminal B opens with name and its grid in that order;
---   the direction button turns it to Z first in both, and back;
--- * the sorts by mod (base before me-network, turned: after) and by tier (by the tiers of scripts/fork-me-sortkeys.lua,
---   what has none last in both directions); in a game without Gregtorio the science packs have the tiers 0 (red), 1 (green),
---   2 (blue) and iron plates 0;
--- * a row whose amount reaches 0 stays in its place with 0, greyed; it is a row of its own again when the network has the
---   item back; after the window closed and opened again it is gone.
--- Loaded by control.lua like qualityterm.lua.

local NET, TERM, GUI = "gregtorio-me-network", "gregtorio-me-terminal", "gregtorio-me-gui"
local BX, BY = 30, 200                   -- (inside the cleared test area, TEST_RADIUS of control.lua; clear of the other tests)
local CHECK = 130
local WHO = "sortprefs602"

return function(H)
	local me_place, me_report, power = H.me_place, H.me_report, H.power
	local T = {}

	function T.setup(s)
		local fails = {}
		local what = "terminal sort preference"
		power(s, fails, what, BX, BY)
		local ctrl = me_place(s, fails, what, "me-network-controller", BX + 7, BY)
		local drive = H.me_drive(s, fails, what, BX + 8.5, BY - 0.5, {}, "16k")
		local fdrive = H.me_drive(s, fails, what, BX + 8.5, BY + 0.5, {}, "1k", true)
		local a = me_place(s, fails, what, "me-terminal", BX + 12.5, BY - 2.5)
		local b = me_place(s, fails, what, "me-terminal", BX + 12.5, BY + 2.5)
		H.me_connect(fails, what, { ctrl, drive, fdrive, a, b })
		storage.sortprefs602_scene = { ctrl = ctrl, a = a, b = b }
		return fails
	end

	function T.tick()
		if game.tick ~= CHECK then return end
		local st = { problems = {}, done = true }
		storage.sortprefs602 = st
		local problems = st.problems
		local sc = storage.sortprefs602_scene
		local ctrl, a, b = sc and sc.ctrl, sc and sc.a, sc and sc.b
		if not (ctrl and ctrl.valid and a and a.valid and b and b.valid) then
			return me_report("SORTPREFS", "ME Terminal sort preference", { "the test blocks were not built" })
		end
		local function expect(ok, msg) if not ok then problems[#problems + 1] = msg end end
		local function line(t) return serpent.line(t, { comment = false }) end
		remote.call(NET, "insert", ctrl, "iron-plate", 30)
		remote.call(NET, "insert", ctrl, "copper-plate", 20)
		remote.call(NET, "insert", ctrl, "iron-gear-wheel", 10)
		remote.call(NET, "insert", ctrl, "me-crafting-card", 5)
		remote.call(NET, "insert", ctrl, "iron-ore", 3)
		remote.call(NET, "insert_fluid", ctrl, "water", 1000)
		local inv = game.create_inventory(10)
		remote.call(GUI, "stand_in", WHO, { main = inv, index = 9602, gui = true })
		--- the grid of the stand-in's open window: the sprites in order (a row at 0: "<sprite>=0", greyed: "~" after it)
		local function grid()
			local out = {}
			for i, btn in ipairs(remote.call(GUI, "stand_in_numbers", WHO, "fork_me_grid")) do
				local name = (btn.sprite or ""):gsub("^item/", ""):gsub("^fluid/", "")
				if btn.number == 0 then name = name .. "=0" end
				if btn.enabled == false then name = name .. "~" end
				out[i] = name
			end
			return table.concat(out, " ")
		end
		local function captions()
			local r = remote.call(GUI, "stand_in_act", WHO, nil, nil, "fork_me_tab_storage")
			local out = {}
			for _, c in ipairs(r and r.buttons or {}) do out[#out + 1] = type(c) == "table" and c[1] or tostring(c) end
			return table.concat(out, " ")
		end
		local function open(t)
			local ok, err = pcall(remote.call, GUI, "stand_in_open_entity", WHO, t)
			expect(ok, "the terminal window did not open: " .. tostring(err))
			return ok
		end
		local function refresh() remote.call(GUI, "stand_in_select_tab", WHO, "fork_me_tabs", 1) end

		--- point 2: the sort is the player's
		if open(a) then
			local before = grid()
			expect(before == "iron-plate copper-plate iron-gear-wheel me-crafting-card iron-ore water",
				"terminal A sorts by amount at first: " .. before)
			remote.call(GUI, "stand_in_act", WHO, "term_sort")
			local by_name = "copper-plate iron-gear-wheel iron-ore iron-plate me-crafting-card water"
			expect(grid() == by_name, "terminal A after Sort: " .. grid())
			if open(b) then
				expect(captions():find("fork-me-net.sort-name", 1, true) ~= nil, "terminal B opens with the sort by name: " .. captions())
				expect(grid() == by_name, "terminal B's grid by name: " .. grid())
				remote.call(GUI, "stand_in_act", WHO, "term_sort_dir")
				local z_first = "me-crafting-card iron-plate iron-ore iron-gear-wheel copper-plate water"
				expect(grid() == z_first, "terminal B, name turned (Z first, fluids after the items): " .. grid())
				expect(captions():find("fork-me-net.sort-name", 1, true) ~= nil, "the direction keeps the sort: " .. captions())
				open(a)
				expect(grid() == z_first, "terminal A keeps the direction: " .. grid())
				remote.call(GUI, "stand_in_act", WHO, "term_sort_dir")
				expect(grid() == by_name, "A to Z again: " .. grid())
			end
			local p = remote.call(TERM, "prefs", 9602)
			expect(p.sort == "name" and p.desc == false and p.kind == "all", "the preference: " .. line(p))
		end

		--- point 3: mod and tier, through the window's list
		local function keys(sort, desc)
			local out = {}
			for i, e in ipairs(remote.call(TERM, "entries", a, "", sort, "items", true, nil, nil, nil, nil, desc)) do out[i] = e.key end
			return out
		end
		local function joined(sort, desc) return table.concat(keys(sort, desc), " ") end
		local prof = helpers.create_profiler()                  -- (the tiers are made in on_init: the first sort reads them)
		keys("tier", false)
		prof.stop()
		log({ "", "DEVCHECK-SORTPREFS first sort by tier: ", prof })
		prof.reset()
		remote.call(TERM, "rebuild_tiers")
		prof.stop()
		log({ "", "DEVCHECK-SORTPREFS the tiers of every item and fluid (on_init, on_configuration_changed): ", prof })
		local mods = {}
		for _, k in ipairs(keys("mod")) do mods[#mods + 1] = remote.call(TERM, "sort_keys", false, k).mod end
		expect(mods[#mods] == "me-network", "sort by mod: me-network last of base and me-network: " .. line(mods))
		local turned = keys("mod", true)
		expect(remote.call(TERM, "sort_keys", false, turned[1]).mod == "me-network", "sort by mod turned: me-network first: "
			.. joined("mod", true))
		--- an item without a tier (the first by name that the network takes: no recipe but hidden ones and recycling makes it)
		local bare
		local names = {}
		for name, p in pairs(prototypes.item) do if p.type == "item" and not p.parameter then names[#names + 1] = name end end
		table.sort(names)
		for _, name in ipairs(names) do
			if remote.call(TERM, "sort_keys", false, name).tier == nil and remote.call(NET, "insert", ctrl, name, 1) == 1 then
				bare = name
				break
			end
		end
		expect(bare ~= nil, "no storable item without a tier for the sort by tier")
		--- the tiers in order, those without one last, both ways
		local function tiers(desc)
			local out = {}
			for i, k in ipairs(keys("tier", desc)) do out[i] = remote.call(TERM, "sort_keys", false, k).tier or "none" end
			return out
		end
		for _, desc in ipairs({ false, true }) do
			local t = tiers(desc)
			local ok, none = t[#t] == "none" or not bare, false
			for i = 2, #t do
				if t[i] == "none" then none = true
				elseif none or t[i - 1] == "none" then ok = false
				elseif desc and t[i] > t[i - 1] or not desc and t[i] < t[i - 1] then ok = false end
			end
			expect(ok, "sort by tier" .. (desc and " turned" or "") .. ": " .. line(t) .. " (" .. joined("tier", desc) .. ")")
		end
		if bare then remote.call(NET, "extract", ctrl, bare, 1) end
		local packs = {}
		for _, name in ipairs({ "automation-science-pack", "logistic-science-pack", "chemical-science-pack", "iron-plate" }) do
			packs[#packs + 1] = name .. "=" .. tostring(remote.call(TERM, "sort_keys", false, name).tier)
		end
		if not script.active_mods["gregtorio-continued"] then
			expect(table.concat(packs, " ") == "automation-science-pack=0 logistic-science-pack=1 chemical-science-pack=2 "
				.. "iron-plate=0", "the vanilla tiers: " .. table.concat(packs, " "))
		end

		--- point 4: rows that reach 0
		if open(a) then
			local by_name = "copper-plate iron-gear-wheel iron-ore iron-plate me-crafting-card water"
			expect(grid() == by_name, "terminal A by name: " .. grid())
			remote.call(NET, "extract", ctrl, "iron-gear-wheel", 10)
			refresh()
			local kept = "copper-plate iron-gear-wheel=0~ iron-ore iron-plate me-crafting-card water"
			expect(grid() == kept, "the gears at 0 stay in their place, greyed: " .. grid())
			remote.call(NET, "extract", ctrl, "iron-ore", 3)
			refresh()
			expect(grid() == "copper-plate iron-gear-wheel=0~ iron-ore=0~ iron-plate me-crafting-card water", "two rows at 0: " .. grid())
			remote.call(NET, "insert", ctrl, "iron-gear-wheel", 4)
			refresh()
			expect(grid() == "copper-plate iron-gear-wheel iron-ore=0~ iron-plate me-crafting-card water", "the gears are back: " .. grid())
			remote.call(GUI, "stand_in_close_window", WHO, false)
			open(a)
			expect(grid() == "copper-plate iron-gear-wheel iron-plate me-crafting-card water", "after closing, no row at 0: " .. grid())
			remote.call(GUI, "stand_in_close_window", WHO, false)
		end
		remote.call(GUI, "stand_in_forget", WHO)
		inv.destroy()
		me_report("SORTPREFS", "ME Terminal sort preference", problems, "the sort and its direction are the player's in both "
			.. "terminals; sort by mod and by tier; rows at 0 kept in place until the window closes (issue #602; tiers: "
			.. table.concat(packs, " ") .. "; without a tier: " .. tostring(bare) .. ")")
	end

	function T.running(check) check(storage.sortprefs602 and storage.sortprefs602.done, "ME Terminal sort preference") end
	return T
end
