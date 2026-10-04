--- Runtime test of the in-game diagnostic of me-network issue #38, part 3 (scripts/fork-me-stats.lua, the command
--- /me-stats): a small network with an export bus whose key the network does not hold (parked), an import bus on an empty
--- chest and an interface with no rows (probing); the report must count the members by kind and the blocks by state,
--- agree with the scheduler's own counters, and the window (the counters since a copy of them) must be their difference.
--- The lines are checked for their keys and their first parameters (the locale is not rendered headless; `check` lists the
--- keys of the locale that are missing). Loaded by control.lua: require("stats")(H) returns { setup, tick, running }.

local NET, IO, STATS = "gregtorio-me-network", "gregtorio-me-io", "gregtorio-me-stats"
local BX, BY = 330, -345
local CHECK1, MARK_B, CHECK2 = 600, 700, 760
local FAKE = 3600 * 1000                                      -- ticks of the marks: a multiple of the window

return function(H)
	local me_place, power, me_report = H.me_place, H.power, H.me_report
	local T = {}
	local NORTH = { direction = defines.direction.north }

	function T.setup(s)
		local fails = {}
		local what = "stats"
		local eei = me_place(s, fails, what, "electric-energy-interface", BX + 12.5, BY + 6.5)
		if eei then
			eei.power_production = 1e6
			eei.electric_buffer_size = 1e7
		end
		me_place(s, fails, what, "substation", BX + 13, BY + 2)
		local ctrl = me_place(s, fails, what, "me-network-controller", BX + 6, BY)
		local drive = me_drive(s, fails, what, BX + 8.5, BY + 4.5, { ["iron-plate"] = 100 })
		local export = me_place(s, fails, what, "me-export-bus", BX + 2.5, BY + 0.5, NORTH)
		me_place(s, fails, what, "iron-chest", BX + 2.5, BY - 0.5)
		local import = me_place(s, fails, what, "me-import-bus", BX + 4.5, BY + 0.5, NORTH)
		me_place(s, fails, what, "iron-chest", BX + 4.5, BY - 0.5)
		local iface = me_place(s, fails, what, "me-network-interface", BX + 11.5, BY + 0.5)
		me_connect(fails, what, { ctrl, drive, export, import, iface })
		if export then remote.call(IO, "set_bus_filters", export, { "copper-plate" }) end     -- a key the network does not hold
		if import then remote.call(IO, "set_bus_filters", import, { "iron-plate" }) end
		storage.stats38_scene = { ctrl = ctrl }
		return fails
	end

	local function keys_of(lines)
		local out = {}
		for _, l in ipairs(lines) do out[#out + 1] = type(l) == "table" and l[1] or tostring(l) end
		return out
	end

	function T.tick()
		local tick = game.tick
		local st = storage.stats38
		if not st then
			if tick < CHECK1 then return end
			st = { problems = {}, done = false }
			storage.stats38 = st
		end
		if st.done then return end
		local problems = st.problems
		local function expect(ok, what) if not ok then problems[#problems + 1] = what end end
		local ctrl = storage.stats38_scene and storage.stats38_scene.ctrl
		if not (ctrl and ctrl.valid) then
			problems[#problems + 1] = "the test network was not built"
			st.done = true
			me_report("STATS", "ME stats command", problems, "no network")
			return
		end
		if not st.step1 then
			st.step1 = true
			expect(commands.commands["me-stats"] ~= nil, "the command /me-stats is not registered")
			local r = remote.call(STATS, "report", ctrl)
			expect(r ~= nil, "no report for the network")
			if r then
				local k = r.kinds
				expect(k.controller == 1 and k.drive == 1 and k.interface == 1 and k["import-bus"] == 1 and k["export-bus"] == 1,
					"members by kind: " .. serpent.line(k, { comment = false }))
				local total = 0
				for _, n in pairs(k) do total = total + n end
				expect(total == r.members, "members " .. r.members .. " against the sum of the kinds " .. total)
				local io = r.io
				local seen = (io.busy or 0) + (io.probing or 0) + (io.parked or 0)
				expect(seen == 3, "blocks by state add up to " .. seen .. ", not 3: " .. serpent.line(io, { comment = false }))
				expect((io.parked_by or {})["no-key"] == 1, "the export bus waiting for copper is not parked for no-key: "
					.. serpent.line(io, { comment = false }))
				expect(r.status == "ok", "network status " .. tostring(r.status))
			end
			--- the counters of the report are the scheduler's
			local w = remote.call(STATS, "window")
			local snap = remote.call(IO, "sched_stats", false)
			local q, c = w.q.io, snap.io
			expect(q and c and q.visits == c.visits and q.ticks == c.ticks and q.starved == c.starved and q.wakes == c.wakes
				and q.missed_total == c.missed, "the window since the load is not the scheduler's counters: "
				.. serpent.line(q, { comment = false }) .. " against " .. serpent.line({ c.visits, c.ticks, c.starved, c.wakes, c.missed }))
			expect(q and q.visits > 0 and w.span > 0, "no visits in the window")
			--- the lines
			local lines = remote.call(STATS, "run", ctrl, "")
			local keys = keys_of(lines)
			expect(keys[1] == "me-stats.header" and lines[1][2] == r.id and lines[1][4] == r.members, "first line " .. serpent.line(lines[1], { comment = false }))
			local has = {}
			for _, key in ipairs(keys) do has[key] = true end
			expect(has[""] and has["me-stats.blocks"] and has["me-stats.scheduler"] and has["me-stats.queue"],
				"lines: " .. table.concat(keys, ", "))
			expect(lines[#lines][1] == "me-stats.queue" or lines[#lines][1] == "me-stats.queue-samples", "the last line is not a queue line: " .. serpent.line(lines[#lines], { comment = false }))
			for _, l in ipairs(lines) do log({ "", "DEVCHECK-STATS-LINE ", l }) end     -- (rendered by the engine: devcheck.py checks them)
			local all = remote.call(STATS, "run", nil, "all")
			for _, l in ipairs(all) do log({ "", "DEVCHECK-STATS-LINE ", l }) end
			expect(all[1][1] == "me-stats.all-header" and all[2] and all[2][1] == "me-stats.all-line", "/me-stats all: "
				.. table.concat(keys_of(all), ", "))
			local none = remote.call(STATS, "run", nil, "")
			expect(none[1][1] == "me-stats.no-player", "/me-stats from the console: " .. serpent.line(none[1], { comment = false }))
			--- two copies of the counters FAKE ticks on: the window is the difference to the first
			st.v0, st.t0 = c.visits, c.ticks
			remote.call(STATS, "mark", FAKE)
		end
		if tick >= MARK_B and not st.step2 then
			st.step2 = true
			remote.call(STATS, "mark", FAKE + 3600)
		end
		if tick >= CHECK2 and not st.step3 then
			st.step3 = true
			local w = remote.call(STATS, "window", FAKE + 3600 + 60)
			local snap = remote.call(IO, "sched_stats", false)
			local q = w.q.io
			expect(w.span == 3660, "span " .. tostring(w.span))
			expect(q and q.visits == snap.io.visits - st.v0 and q.visits > 0, "window visits " .. tostring(q and q.visits)
				.. " against " .. (snap.io.visits - st.v0))
			expect(q and q.ticks == snap.io.ticks - st.t0, "window ticks " .. tostring(q and q.ticks) .. " against " .. (snap.io.ticks - st.t0))
			st.done = true
			me_report("STATS", "ME stats command", problems, "the report counts members and blocks, the window is the counters' difference, "
				.. "the lines carry their keys, the command is registered")
		end
	end

	function T.running(check) check(storage.stats38 and storage.stats38.done, "ME stats command") end
	return T
end
