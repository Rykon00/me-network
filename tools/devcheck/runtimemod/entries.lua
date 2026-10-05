--- Runtime test of me-network issue #50, lever 8 (docs/PERFORMANCE.md "Pull request 13"): the terminal's entries. The entries
--- of a network are kept per search, sort and kind with the network's contents version (net.cver) and given back while it
--- did not change; a changed network sorts the last list again (an insertion sort that moves only what changed). Every 20
--- ticks of the whole run, for every terminal of the map (the other tests' networks move items and fluids all the time) and
--- every sort (count, name), kind (all, items, fluids) and search ("", "iron"), the entries through the kept lists must be
--- the entries made from nothing (remote `entries` with `fresh`). The test's own network changes an amount before every
--- round (four items, two of them at the same amount: ties are sorted by key), so lists are given back unchanged and sorted
--- again from the last one in both halves of the run (else the test proved nothing). Loaded by control.lua:
--- require("entries")(H).

local NET, TERM = "gregtorio-me-network", "gregtorio-me-terminal"
local BX, BY = 150, -60
local KEYS = { "iron-plate", "copper-plate", "stone", "coal" }
local FROM, TO, EVERY = 60, 1400, 20
local COMBOS = {}
for _, sort in ipairs({ "count", "name" }) do
	for _, kind in ipairs({ "all", "items", "fluids" }) do
		for _, filter in ipairs({ "", "iron" }) do COMBOS[#COMBOS + 1] = { sort, kind, filter } end
	end
end

return function(H)
	local me_place, me_report = H.me_place, H.me_report
	local T = {}

	function T.setup(s)
		local fails = {}
		local what = "terminal entries"
		local eei = me_place(s, fails, what, "electric-energy-interface", BX, BY)
		if eei then
			eei.power_production = 1e6
			eei.electric_buffer_size = 1e7
		end
		me_place(s, fails, what, "substation", BX + 3, BY)
		local ctrl = me_place(s, fails, what, "me-network-controller", BX + 7, BY)
		local drive = me_drive(s, fails, what, BX + 10, BY + 3, { ["iron-plate"] = 50, ["copper-plate"] = 50, stone = 40, coal = 30 })
		local term = me_place(s, fails, what, "me-terminal", BX + 12.5, BY - 2.5)
		me_connect(fails, what, { ctrl, drive, term })
		storage.entries50_scene = { ctrl = ctrl }
		return fails
	end

	function T.tick()
		local tick = game.tick
		local st = storage.entries50
		if not st then
			if tick < FROM then return end
			st = { problems = {}, done = false, rounds = 0, compared = 0 }
			storage.entries50 = st
		end
		if st.done or tick % EVERY ~= 0 then return end
		local problems = st.problems
		--- the own network: one amount up or down before the round (some rounds make two amounts equal)
		local sc = storage.entries50_scene
		local ctrl = sc and sc.ctrl
		if ctrl and ctrl.valid then
			local key = KEYS[st.rounds % #KEYS + 1]
			if st.rounds % 2 == 0 then remote.call(NET, "insert", ctrl, key, 10) else remote.call(NET, "extract", ctrl, key, 10) end
		end
		local line = function(v) return serpent.line(v, { comment = false, numformat = "%.17g" }) end
		local terms = game.surfaces[1].find_entities_filtered{ name = "me-terminal" }
		table.sort(terms, function(a, b) return a.unit_number < b.unit_number end)
		for _, term in ipairs(terms) do
			for _, c in ipairs(COMBOS) do
				local kept = remote.call(TERM, "entries", term, c[3], c[1], c[2])
				local again = remote.call(TERM, "entries", term, c[3], c[1], c[2])
				local fresh = remote.call(TERM, "entries", term, c[3], c[1], c[2], true)
				st.compared = st.compared + 1
				local a, b, f = line(kept), line(again), line(fresh)
				if (a ~= f or b ~= f) and #problems < 10 then
					problems[#problems + 1] = "tick " .. tick .. ", terminal " .. term.unit_number .. " (" .. table.concat(c, ", ") .. "): "
						.. #kept .. " entries kept, " .. #fresh .. " fresh: " .. a:sub(1, 300) .. " against " .. f:sub(1, 300)
				end
			end
		end
		st.rounds = st.rounds + 1
		if tick >= TO then
			local stats = remote.call(TERM, "entries_stats")
			if st.compared == 0 then problems[#problems + 1] = "no terminal to compare" end
			if stats.kept == 0 or stats.resorted == 0 then
				problems[#problems + 1] = "the kept lists were not used: " .. serpent.line(stats)
			end
			st.done = true
			me_report("ENTRIES", "ME terminal entries", problems, st.rounds .. " rounds, " .. st.compared .. " lists compared, "
				.. stats.kept .. " kept, " .. stats.resorted .. " sorted again, " .. stats.sorted .. " with table.sort")
		end
	end

	function T.running(check) check(storage.entries50 and storage.entries50.done, "ME terminal entries") end
	return T
end
