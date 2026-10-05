--- Runtime test of me-network issue #50, lever 6 (docs/PERFORMANCE.md "Pull request 12"): the scan of the pattern providers.
--- The scan keeps what it reads of a pattern alone (per slot content and per pattern), reads each machine once per scan and
--- compares what it found with the last scan instead of a signature string. This test checks, for a provider next to each
--- kind of machine, the reason of every slot (ok, "category", "not-researched", "no-recipe", "furnace", "stack", "fluid-box",
--- "fluid-pipes", "no-machine") and that each change only a scan can see makes the network's patterns anew: a machine's
--- recipe cleared and set, a pipe built at a fluid box and removed, a recipe's research taken and given back, a machine
--- removed and built again and a second machine built (all without an event), a provider's priority. After every change the
--- network's patterns (the reasons it ignores, the machines of each pattern) must be what a scan of every provider says, and
--- a scan that found nothing new must keep them (a kept plan stays kept). The same test passes on the code before the
--- change. Loaded by control.lua: require("scan")(H).

local NET, AC = "gregtorio-me-network", "gregtorio-me-autocraft"
local BX, BY = 200, -100
local START = 320
local RESEARCH = "zz-devcheck-scan"               -- a test recipe of the macerator's category (data-final-fixes.lua)

local function pat(inputs, outputs)
	local p = { kind = "processing", inputs = {}, outputs = {} }
	for k, n in pairs(inputs) do p.inputs[#p.inputs + 1] = { key = k, amount = n } end
	for k, n in pairs(outputs) do p.outputs[#p.outputs + 1] = { key = k, amount = n } end
	table.sort(p.inputs, function(a, b) return a.key < b.key end)
	return p
end
local function craft(recipe) return { kind = "crafting", recipe = recipe } end

--- the providers: the machine (above the provider), its recipe, the patterns and their reasons with nothing changed
local CASES = {
	{ machine = "ev-macerator", recipe = "crushed-iron",
		patterns = { craft("crushed-iron"), pat({ ["raw-iron"] = 1 }, { ["crushed-iron"] = 2 }), craft(RESEARCH), craft("hydrochloric-acid") },
		want = { "ok", "ok", "ok", "category" } },
	{ machine = "hv-chemical-reactor", recipe = "hydrochloric-acid",
		patterns = { craft("hydrochloric-acid"),
			pat({ ["fluid/chlorine"] = 100, ["fluid/hydrogen"] = 100 }, { ["fluid/hydrochloric-acid"] = 100 }) },
		want = { "ok", "ok" } },
	{ machine = "iron-furnace",
		patterns = { craft("iron-dust-smelter"), pat({ ["iron-dust"] = 1 }, { ["iron-ingot"] = 1 }),
			pat({ ["iron-dust"] = 1, ["raw-iron"] = 1 }, { ["iron-ingot"] = 1 }), pat({ ["fluid/chlorine"] = 10 }, { ["iron-ingot"] = 1 }) },
		want = { "furnace", "ok", "stack", "fluid-box" } },
	{ machine = "steel-chest",
		patterns = { craft("crushed-iron"), pat({ ["iron-plate"] = 1 }, { ["iron-gear-wheel"] = 1 }), pat({ ["fluid/chlorine"] = 10 }, { ["iron-plate"] = 1 }) },
		want = { "no-machine", "ok", "fluid-box" } },
	{ machine = "me-molecular-assembler", recipe = "iron-gear-crafting-table",
		patterns = { craft("iron-gear-crafting-table"), pat({ ["iron-plate"] = 1000 }, { ["iron-gear-wheel"] = 1 }) },
		want = { "ok", "stack" } },
	{ machine = "steel-chest", patterns = { pat({ ["iron-plate"] = 1 }, { ["iron-stick"] = 2 }) }, want = { "ok" } },
	{ machine = "steel-chest", patterns = { pat({ ["copper-plate"] = 1 }, { ["iron-stick"] = 2 }) }, want = { "ok" } },
}

--- where a provider and its machine stand (3x3 machines centred above the provider, the 2x2 furnace beside it)
local function provider_pos(i) return { BX + 4 * i + 1.5, BY + 0.5 } end
local function machine_pos(i, name)
	local x = BX + 4 * i + 1.5
	if name == "steel-chest" then return { x, BY - 0.5 } end
	if name == "iron-furnace" then return { x + 0.5, BY - 1 } end
	return { x, BY - 1.5 }
end

return function(H)
	local me_place, me_report = H.me_place, H.me_report
	local T = {}

	local function place_machine(s, fails, i, raise)
		local c = CASES[i]
		local pos = machine_pos(i, c.machine)
		local m = s.create_entity{ name = c.machine, position = pos, force = "player", raise_built = raise }
		if not m then
			fails[#fails + 1] = "scan: machine " .. c.machine .. " not built"
			return nil
		end
		if c.recipe then
			m.force.recipes[c.recipe].enabled = true
			m.set_recipe(c.recipe)
		end
		if c.machine == "iron-furnace" then m.get_inventory(defines.inventory.fuel).insert{ name = "coal", count = 5 } end
		return m
	end

	function T.setup(s)
		local fails = {}
		local what = "provider scan"
		local eei = me_place(s, fails, what, "electric-energy-interface", BX - 6, BY + 7)
		if eei then
			eei.power_production = 1e6
			eei.electric_buffer_size = 1e7
		end
		for _, x in pairs({ -3, 12, 28 }) do me_place(s, fails, what, "substation", BX + x, BY + 7) end
		for x = BX - 6, BX + 4 * #CASES + 4 do me_place(s, fails, what, "me-cable", x + 0.5, BY + 1.5) end
		local ctrl = me_place(s, fails, what, "me-network-controller", BX - 2, BY + 3)
		local drive = me_drive(s, fails, what, BX + 4 * #CASES + 2, BY + 3,
			{ ["iron-plate"] = 100, ["copper-plate"] = 100, ["raw-iron"] = 50 })
		me_connect(fails, what, { ctrl, drive })
		for _, r in pairs({ "crushed-iron", "hydrochloric-acid", "iron-gear-crafting-table", "iron-dust-smelter", RESEARCH }) do
			local rec = game.forces.player.recipes[r]
			if rec then rec.enabled = true else fails[#fails + 1] = "scan: no recipe " .. r end
		end
		local provs, machines = {}, {}
		for i, c in ipairs(CASES) do
			machines[i] = place_machine(s, fails, i, true)
			local p = me_place(s, fails, what, "me-pattern-provider", provider_pos(i)[1], provider_pos(i)[2])
			provs[i] = p
			if p then give_patterns(p, c.patterns, fails) end
		end
		storage.scan50_scene = { ctrl = ctrl, provs = provs, machines = machines }
		return fails
	end

	function T.tick()
		local tick = game.tick
		local sc = storage.scan50_scene
		local st = storage.scan50
		if not st then
			if tick < START or not sc then return end
			st = { problems = {}, done = false, step = 0, next = tick, cases = 0 }
			storage.scan50 = st
		end
		if st.done or tick < st.next then return end
		local problems = st.problems
		local s = game.surfaces[1]
		local ctrl = sc.ctrl
		if not (ctrl and ctrl.valid) then
			problems[#problems + 1] = "the test network was not built"
			st.done = true
			me_report("SCAN", "ME provider scan", problems, "no network")
			return
		end
		local line = function(v) return serpent.line(v, { comment = false, sortkeys = true }) end
		--- the providers rescanned (the remote plan rescans them first), then the network's patterns against what a scan of each
		--- provider says; `want`: [case] = { [slot] = reason or "ok" } for the slots this step expects
		local function check(name, want)
			st.cases = st.cases + 1
			remote.call(AC, "plan", ctrl, "iron-stick", 1)
			local ignored = remote.call(AC, "ignored", ctrl)
			local has_targets = remote.interfaces[AC].pattern_targets ~= nil
			local targets = has_targets and remote.call(AC, "pattern_targets", ctrl) or nil
			local expect_ignored, machines = { total = 0 }, {}
			for i, p in ipairs(sc.provs) do
				local info = p and p.valid and remote.call(AC, "provider_info", p)
				for slot, d in pairs(info and info.slots or {}) do
					local got = d.ok and "ok" or tostring(d.reason)
					if not d.ok then
						expect_ignored.total = expect_ignored.total + 1
						expect_ignored[d.reason] = (expect_ignored[d.reason] or 0) + 1
					elseif d.id then
						machines[d.id] = (machines[d.id] or 0) + d.machines
					end
					local w = want[i] and want[i][slot]
					if w and w ~= got then
						problems[#problems + 1] = name .. ": provider " .. i .. " slot " .. slot .. " is " .. got .. ", not " .. w
					end
				end
			end
			if line(ignored) ~= line(expect_ignored) then
				problems[#problems + 1] = name .. ": the network ignores " .. line(ignored) .. ", the scans say " .. line(expect_ignored)
			end
			if targets then
				local counts = {}
				for id, units in pairs(targets) do counts[id] = #units end
				if line(counts) ~= line(machines) then
					problems[#problems + 1] = name .. ": the network's machines " .. line(counts) .. ", the scans say " .. line(machines)
				end
			end
		end
		local function want_all()
			local w = {}
			for i, c in ipairs(CASES) do w[i] = {} for slot, r in ipairs(c.want) do w[i][slot] = r end end
			return w
		end
		local function first_pid(key)
			local p = remote.call(AC, "plan", ctrl, key, 1)
			return p and p.pids and p.pids[1]
		end
		st.step = st.step + 1
		local step = st.step
		st.next = tick + 5
		local m = sc.machines
		if step == 1 then
			check("nothing changed", want_all())
			--- a scan that finds nothing new keeps the network's patterns: the second plan is a kept one
			remote.call(AC, "plan", ctrl, "iron-stick", 3)
			local before = remote.call(AC, "kept_plan_stats")
			remote.call(AC, "plan", ctrl, "iron-stick", 3)
			if remote.call(AC, "kept_plan_stats").hits ~= before.hits + 1 then
				problems[#problems + 1] = "a rescan that found nothing new made the network's patterns anew (no kept plan)"
			end
			st.pid_before = first_pid("iron-stick")
			if m[1] and m[1].valid then m[1].set_recipe(nil) end
		elseif step == 2 then
			local w = want_all()
			w[1][2] = "no-recipe"
			check("the macerator's recipe cleared", w)
			if m[1] and m[1].valid then m[1].set_recipe(CASES[1].recipe) end
			--- a pipe at the reactor's first input box
			local r = m[2]
			st.pipe = nil
			if r and r.valid then
				for i = 1, #r.fluidbox do
					local proto = r.fluidbox.get_prototype(i)
					if proto and proto.object_name ~= "LuaFluidBoxPrototype" then proto = proto[1] end   -- merged prototypes
					if proto and proto.production_type == "input" then
						local conn = r.fluidbox.get_pipe_connections(i)[1]
						if conn then
							local pipe = s.create_entity{ name = "pipe", position = conn.target_position, force = "player" }
							if pipe then st.pipe = pipe end
						end
						break
					end
				end
			end
			if not st.pipe then problems[#problems + 1] = "no pipe built at the reactor's input" end
		elseif step == 3 then
			local w = want_all()
			w[2] = { "fluid-pipes", "fluid-pipes" }
			check("a pipe at the reactor's input", w)
			if st.pipe and st.pipe.valid then st.pipe.destroy() end
			game.forces.player.recipes[RESEARCH].enabled = false
		elseif step == 4 then
			local w = want_all()
			w[1][3] = "not-researched"
			check("the pipe removed, a recipe's research taken", w)
			game.forces.player.recipes[RESEARCH].enabled = true
			if m[5] and m[5].valid then m[5].destroy() end
		elseif step == 5 then
			local w = want_all()
			w[5] = { "no-machine", "no-machine" }
			check("the research back, the assembler removed without an event", w)
			m[5] = place_machine(s, problems, 5, false)
			--- a second chest beside the chest provider (west of it), without an event
			local pos = provider_pos(4)
			st.chest2 = s.create_entity{ name = "steel-chest", position = { pos[1] - 1, pos[2] }, force = "player" }
			if not st.chest2 then problems[#problems + 1] = "the second chest was not built" end
		elseif step == 6 then
			check("the assembler built again, a second chest", want_all())
			local info = sc.provs[4] and sc.provs[4].valid and remote.call(AC, "provider_info", sc.provs[4])
			local n = info and info.slots[2] and info.slots[2].machines
			if n ~= 2 then problems[#problems + 1] = "the chest provider's pattern has " .. tostring(n) .. " machines, not 2" end
			remote.call(AC, "set_priority", sc.provs[7], 5)
		elseif step == 7 then
			check("a provider's priority", want_all())
			local pid = first_pid("iron-stick")
			if not (st.pid_before and pid and pid ~= st.pid_before and pid:find("copper", 1, true)) then
				problems[#problems + 1] = "the priority did not change the pattern: " .. tostring(st.pid_before) .. " then " .. tostring(pid)
			end
			if st.chest2 and st.chest2.valid then st.chest2.destroy() end
			remote.call(AC, "set_priority", sc.provs[7], 0)
		elseif step == 8 then
			check("the second chest removed, the priority back", want_all())
			st.done = true
			me_report("SCAN", "ME provider scan", problems, st.cases .. " states")
		end
	end

	function T.running(check) check(storage.scan50 and storage.scan50.done, "ME provider scan") end
	return T
end
