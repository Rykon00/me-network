--- Runtime test of me-network issue #159: fluids keep their temperature in the network. One network with fluid cells, a
--- terminal, a crafting CPU and a circuit interface:
---   * the keys: the default temperature keeps "fluid/<name>", another temperature is "fluid/<name>@<degrees>" (whole
---     degrees after the engine's clamp), 249.6 and 250.2 are one key;
---   * an ME Interface imports steam at 250 °C from a pipe and exports it at 250 °C: a row of 250 °C and a row of every
---     temperature (the network holds only hot steam: never a fallback to 15 °C); refilled after the default steam came
---     in, the side keeps its 250 °C (nothing mixed);
---   * two temperatures of one fluid stay apart (two keys, two types in the cells), the remote calls of before count
---     the default temperature;
---   * an export bus with a filter of 250 °C fills a tank at 250 °C;
---   * a storage bus on a tank of steam at 400 °C: storage under "fluid/steam@400", steam at 400 goes in, the default
---     steam does not, both come out at their own temperature;
---   * an export bus without a temperature into a machine whose recipe takes steam between 200 and 600 °C fills it at
---     a temperature in that range; an export bus of water into a recipe of 50 to 100 °C moves nothing and says why
---     (status "temperature": the network has 15 °C, the target takes 50-100);
---   * autocrafting: a pattern of steam between 200 and 600 °C plans with the hot steam the network has, a pattern that
---     makes steam at 300 °C is craftable as "fluid/steam@300"; the job hands steam to the machine at a temperature in
---     the range and gives it back at the same key when it is cancelled;
---   * the circuit interface: one signal per fluid, the sum of its temperatures, a filter of one temperature only that one.
--- The runtime's save at tick 500 and the schedule comparison after the load cover its blocks like every other test's.
--- Loaded by control.lua: require("temperature")(H) returns { setup, tick, running }.

local NET, IO, FSB, AC, C38 = "gregtorio-me-network", "gregtorio-me-io", "gregtorio-me-fluid-storagebus", "gregtorio-me-autocraft",
	"gregtorio-me-circuit"
local BX, BY = -200, -330
local START, TIMEOUT = 120, 900
local SOUTH = { direction = defines.direction.south }

return function(H)
	local me_place, me_report, power = H.me_place, H.me_report, H.power
	local T = {}

	function T.setup(s)
		local fails = {}
		local what = "fluid temperature"
		local tiles = {}                                         -- (land under the scene: the map may have water there)
		for x = BX - 4, BX + 44 do
			for y = BY - 6, BY + 12 do tiles[#tiles + 1] = { name = "grass-1", position = { x, y } } end
		end
		s.set_tiles(tiles)
		power(s, fails, what, BX, BY)
		local ctrl = me_place(s, fails, what, "me-network-controller", BX + 7, BY)
		local drive = H.me_drive(s, fails, what, BX + 8.5, BY - 0.5, {}, "16k", true)
		local cpu = me_place(s, fails, what, "me-crafting-cpu", BX + 11, BY)
		local term = me_place(s, fails, what, "me-terminal", BX + 12.5, BY - 2.5)
		local ci = me_place(s, fails, what, "me-circuit-interface", BX + 14.5, BY - 2.5)
		local iface = me_place(s, fails, what, "me-network-interface", BX + 16.5, BY + 0.5)
		local pipe = me_place(s, fails, what, "pipe", BX + 16.5, BY + 1.5)                  -- the import side (south)
		local eb = me_place(s, fails, what, "me-export-bus", BX + 20.5, BY + 0.5, SOUTH)
		local tb = me_place(s, fails, what, "storage-tank", BX + 20.5, BY + 2.5)
		local sb = me_place(s, fails, what, "me-storage-bus", BX + 26.5, BY + 0.5, SOUTH)
		local tc = me_place(s, fails, what, "storage-tank", BX + 26.5, BY + 2.5)
		local eb2 = me_place(s, fails, what, "me-export-bus", BX + 33.5, BY + 0.5, SOUTH)
		local hm = me_place(s, fails, what, "zz-devcheck-hot-machine", BX + 33.5, BY + 2.5)
		local eb3 = me_place(s, fails, what, "me-export-bus", BX + 38.5, BY + 0.5, SOUTH)
		local wm = me_place(s, fails, what, "zz-devcheck-hot-machine", BX + 38.5, BY + 2.5)
		local prov = me_place(s, fails, what, "me-pattern-provider", BX + 31.5, BY + 7.5)
		local hm2 = me_place(s, fails, what, "zz-devcheck-hot-machine", BX + 33.5, BY + 7.5)
		if hm and wm and hm2 then
			hm.set_recipe("zz-devcheck-hot-steam")
			wm.set_recipe("zz-devcheck-warm-water")
			hm2.set_recipe("zz-devcheck-hot-steam")
		end
		if tc then tc.insert_fluid{ name = "steam", amount = 500, temperature = 400 } end
		if pipe then pipe.fluidbox[1] = { name = "steam", amount = 100, temperature = 250 } end
		H.me_connect(fails, what, { ctrl, drive, cpu, term, ci, iface, eb, sb, eb2, eb3, prov })
		storage.temperature159_scene = { ctrl = ctrl, drive = drive, term = term, ci = ci, iface = iface, pipe = pipe, eb = eb, tb = tb,
			sb = sb, tc = tc, eb2 = eb2, hm = hm, eb3 = eb3, wm = wm, prov = prov, hm2 = hm2 }
		return fails
	end

	function T.tick()
		local tick = game.tick
		local st = storage.temperature159
		if not st then
			if tick < START then return end
			st = { problems = {}, done = false, phase = 0 }
			storage.temperature159 = st
		end
		if st.done then return end
		local problems = st.problems
		local function expect(ok, text) if not ok then problems[#problems + 1] = text end end
		local function finish(note)
			st.done = true
			me_report("TEMPERATURE", "ME fluid temperature", problems, note)
		end
		local sc = storage.temperature159_scene
		for k, e in pairs(sc or {}) do
			if not e.valid then
				expect(false, "the entities were not built (" .. k .. ")")
				return finish()
			end
		end
		if not sc then
			expect(false, "the entities were not built")
			return finish()
		end
		local t = sc.term
		local function near(a, b, eps) return math.abs((a or 0) - (b or 0)) < (eps or 0.01) end
		local function key(name, temp) return remote.call(NET, "fluid_key", name, temp) end
		local function count(name, temp) return remote.call(NET, "fluid_count", t, name, temp) end
		local function keys() return remote.call(NET, "fluid_key_contents", t) end
		local function step(e, n) for _ = 1, n or 1 do remote.call(IO, "step", e) end end
		local function held(e, i) return e.fluidbox[i or 1] end
		local function side(d) return (remote.call(IO, "interface_tanks", sc.iface) or {})[d] end
		--- the input box of a machine with the hot recipe (the one whose filter is the fluid)
		local function input_box(m, name)
			local fb = m.fluidbox
			for i = 1, #fb do
				local f = fb.get_filter(i)
				if f and f.name == name and fb.get_prototype(i).production_type == "input" then return fb[i], f end
			end
			return nil
		end

		if st.phase == 0 then
			st.phase = 1
			--- the keys
			expect(key("steam") == "fluid/steam" and key("steam", 15) == "fluid/steam" and key("steam", 15.3) == "fluid/steam",
				"the default key: " .. tostring(key("steam", 15.3)))
			expect(key("steam", 249.6) == "fluid/steam@250" and key("steam", 250.2) == "fluid/steam@250", "rounded: " .. tostring(key("steam", 249.6)))
			expect(key("water", 3) == "fluid/water" and key("steam", 1e7) == "fluid/steam@5000", "clamped: " .. tostring(key("water", 3))
				.. ", " .. tostring(key("steam", 1e7)))

			--- the interface: south imports (the pipe of steam at 250), east keeps a row of 250 °C, west a row of every temperature
			remote.call(IO, "set_interface_config", sc.iface, {
				[1] = { type = "fluid", name = "steam", amount = 30, temperature = 250 },
				[2] = { type = "fluid", name = "steam", amount = 30 } }, { [1] = "off", [2] = 1, [4] = 2 })
			local cfg = remote.call(IO, "get_interface_config", sc.iface)
			expect(cfg[1] and cfg[1].temperature == 250 and cfg[2] and cfg[2].temperature == nil, "rows: " .. serpent.line(cfg))
			step(sc.iface, 3)
			local east, west = held(side(2)), held(side(4))
			expect(east and east.name == "steam" and near(east.amount, 30) and near(east.temperature, 250), "east (250 °C row): " .. serpent.line(east))
			expect(west and west.name == "steam" and near(west.amount, 30) and near(west.temperature, 250),
				"west (row of every temperature, only hot steam stored): " .. serpent.line(west))
			expect(near(count("steam", 250), 40) and count("steam") == 0, "the network: " .. serpent.line(keys()))
			local info = remote.call(IO, "get_interface", sc.iface)
			expect(info.fluids[2].temperature and near(info.fluids[2].temperature, 250), "the window's side: " .. serpent.line(info.fluids[2]))

			--- two temperatures of one fluid stay apart; the calls without a temperature count the default one
			expect(near(remote.call(NET, "insert_fluid", t, "steam", 200), 200) and near(remote.call(NET, "insert_fluid", t, "steam", 100, 500), 100),
				"steam at 15 and 500 °C stored")
			local k = keys()
			local all = 0                                    -- (the hot tank of the storage bus may be counted already)
			for kk, v in pairs(k) do if kk:find("^fluid/steam") then all = all + v end end
			expect(near(k["fluid/steam"], 200) and near(k["fluid/steam@250"], 40) and near(k["fluid/steam@500"], 100) and near(count("steam"), 200)
				and near(remote.call("gregtorio-me-fluids", "count", t, "steam", "any"), all) and all >= 340, "keys: " .. serpent.line(k))
			expect(near(remote.call("gregtorio-me-fluids", "totals", t).steam, all), "totals: " .. serpent.line(remote.call("gregtorio-me-fluids", "totals", t)))
			local types = 0
			for _, c in pairs(remote.call(NET, "drive", sc.drive)) do
				for kk in pairs(c.items) do if kk:find("^fluid/steam") then types = types + 1 end end
			end
			expect(types >= 3, "the cells hold " .. types .. " steam types")

			--- the west side drained: refilled at 250 °C, though the default steam comes first now (nothing mixed)
			side(4).remove_fluid{ name = "steam", amount = 20 }
			step(sc.iface)
			west = held(side(4))
			expect(west and near(west.amount, 30) and near(west.temperature, 250), "west refilled: " .. serpent.line(west))

			--- the export bus of 250 °C into a tank
			remote.call(IO, "set_bus_filters", sc.eb, { "fluid/steam@250" })
			step(sc.eb)
			local tb = held(sc.tb)
			expect(tb and near(tb.amount, 20) and near(tb.temperature, 250) and near(count("steam", 250), 0), "export bus of 250 °C: " .. serpent.line(tb)
				.. ", network " .. serpent.line(keys()))

			--- the storage bus on the tank at 400 °C
			remote.call(FSB, "visit", sc.sb)
			local hot = key("steam", 400)
			expect(near(keys()[hot], 500), "the hot tank in the network: " .. serpent.line(keys()))
			remote.call(FSB, "set_settings", sc.sb, { mode = "readwrite", priority = 10 })
			expect(near(remote.call(NET, "insert_fluid", t, "steam", 100, 400), 100) and near(held(sc.tc).amount, 600) and near(held(sc.tc).temperature, 400),
				"steam at 400 °C into the hot tank: " .. serpent.line(held(sc.tc)))
			expect(near(remote.call(NET, "insert_fluid", t, "steam", 50), 50) and near(held(sc.tc).amount, 600), "default steam kept out: " .. serpent.line(held(sc.tc)))
			expect(near(remote.call(NET, "extract_fluid", t, "steam", 100, 400), 100) and near(held(sc.tc).amount, 500) and near(held(sc.tc).temperature, 400),
				"steam at 400 °C taken: " .. serpent.line(held(sc.tc)))

			--- an export bus without a temperature into a machine of 200-600 °C; one of water into a machine of 50-100 °C
			remote.call(IO, "set_bus_filters", sc.eb2, { "fluid/steam" })
			step(sc.eb2)
			local box = input_box(sc.hm, "steam")
			expect(box and box.amount > 0 and box.temperature >= 200 and box.temperature <= 600 and near(box.temperature, 400),
				"steam into the 200-600 °C machine: " .. serpent.line(box))
			remote.call(NET, "insert_fluid", t, "water", 100)
			remote.call(IO, "set_bus_filters", sc.eb3, { "fluid/water" })
			step(sc.eb3)
			local bi = remote.call(IO, "bus_info", sc.eb3)
			expect(input_box(sc.wm, "water") == nil and bi.status == "temperature" and bi.tstat and bi.tstat[1] == "water" and bi.tstat[2] == "15"
				and bi.tstat[3] == "50-100", "water into the 50-100 °C machine: " .. serpent.line(input_box(sc.wm, "water")) .. ", " .. serpent.line(bi.tstat)
				.. " " .. tostring(bi.status))

			--- the circuit interface: one signal per fluid (its temperatures added up), a filter of one temperature
			local function signals()
				remote.call(C38, "update_circuit", sc.ci)
				local out = {}
				local sec = sc.ci.get_or_create_control_behavior().get_section(1)
				for _, f in pairs(sec and sec.filters or {}) do
					if f.value and f.value.type == "fluid" then out[f.value.name] = (out[f.value.name] or 0) + f.min end
				end
				return out
			end
			local want = math.floor(remote.call("gregtorio-me-fluids", "count", t, "steam", "any"))
			expect(signals().steam == want, "steam on the wire: " .. tostring(signals().steam) .. ", network " .. want)
			remote.call(C38, "set_circuit_filters", sc.ci, { "fluid/steam@500" })
			expect(signals().steam == 100, "steam at 500 °C on the wire: " .. tostring(signals().steam))
			remote.call(C38, "set_circuit_filters", sc.ci, { "fluid/steam" })
			expect(signals().steam == want, "steam of every temperature on the wire: " .. tostring(signals().steam))

			--- autocrafting
			local n = give_patterns(sc.prov, { { kind = "crafting", recipe = "zz-devcheck-hot-steam" }, { kind = "crafting", recipe = "zz-devcheck-heat-steam" } }, problems)
			expect(n == 2, "patterns given: " .. n)
			st.phase_tick = tick
			return
		end

		if st.phase == 1 then
			if tick < st.phase_tick + 5 then return end
			local craftable = {}
			for _, k in pairs(remote.call(AC, "craftable", t) or {}) do craftable[k] = true end
			expect(craftable["zz-devcheck-hot-token"] and craftable["fluid/steam@300"], "craftable: " .. serpent.line(craftable))
			local before = keys()
			local p = remote.call(AC, "plan", t, "zz-devcheck-hot-token", 2)
			local r = p and p.reserve or {}
			local taken = 0
			for k, v in pairs(r) do
				if k:find("^fluid/steam") then
					local deg = tonumber(k:match("@(%d+)$")) or 15
					expect(deg >= 200 and deg <= 600, "the plan takes steam at " .. deg .. " °C: " .. serpent.line(r))
					taken = taken + v
				end
			end
			expect(p and p.ok and near(taken, 20), "plan of two tokens: " .. serpent.line(p))
			local id, why = remote.call(AC, "start", t, "zz-devcheck-hot-token", 2)
			expect(id ~= nil, "job: " .. tostring(why))
			st.job, st.before, st.phase, st.phase_tick = id, before, 2, tick
			if not id then return finish() end
			return
		end

		if st.phase == 2 then
			--- the job hands steam to the (unpowered) machine: at a temperature in the recipe's range
			local box = input_box(sc.hm2, "steam")
			if box and box.amount > 0 then
				expect(box.temperature >= 200 and box.temperature <= 600, "the job's steam in the machine: " .. serpent.line(box))
				remote.call(AC, "cancel", st.job)
				st.phase, st.phase_tick = 3, tick
			elseif tick > st.phase_tick + TIMEOUT / 2 then
				expect(false, "the job never handed steam to the machine: " .. serpent.line(remote.call(AC, "job", st.job)))
				remote.call(AC, "cancel", st.job)
				st.phase, st.phase_tick = 3, tick
			end
			return
		end

		if st.phase == 3 then
			local job = remote.call(AC, "job", st.job)
			if job and job.status ~= "cancelled" and job.status ~= "failed" and job.status ~= "done" and tick < st.phase_tick + TIMEOUT / 2 then return end
			--- cancelled: the steam came back at the keys it left
			local now = keys()
			local diff = {}
			for k, v in pairs(st.before) do if k:find("^fluid/steam") and not near(now[k], v, 0.05) then diff[#diff + 1] = k .. " " .. tostring(now[k]) .. "/" .. v end end
			for k, v in pairs(now) do if k:find("^fluid/steam") and not st.before[k] then diff[#diff + 1] = k .. " " .. v .. "/0" end end
			table.sort(diff)
			expect(#diff == 0, "after the cancelled job: " .. table.concat(diff, ", ") .. " (job " .. serpent.line(job and job.status) .. ")")
			return finish("keys, interface rows, two temperatures, export bus, storage bus, recipe ranges, circuit signal, plan and job")
		end
	end

	function T.running(check) check(storage.temperature159 and storage.temperature159.done, "ME fluid temperature") end

	return T
end
