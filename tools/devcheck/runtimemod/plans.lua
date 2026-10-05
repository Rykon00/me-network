--- Runtime test of me-network issue #50, lever 11 (docs/PERFORMANCE.md "Pull request 11"): kept plans. A plan is a pure function
--- of the network's patterns and stock; the planner keeps the last plans and gives one back while nothing it depends on
--- changed. Every result must equal a fresh plan of the same state (remote `plan` with `fresh_only`), and each way a kept
--- plan must be dropped must drop it: the stock below what the plan asked of it (above it, or a key the plan never read,
--- keeps it), a pattern added or removed, a provider built or removed, its machine (here: the chest of its processing
--- patterns) removed or built, the network split and joined again. A crafting CPU that becomes busy or free is not part of
--- a plan: the plan is kept and the crafting tab's preview says so. Loaded by control.lua: require("plans")(H).

local NET, AC, TERM = "gregtorio-me-network", "gregtorio-me-autocraft", "gregtorio-me-terminal"
local BX, BY = 250, -150
local START = 300
local KEY, AMOUNT = "engine-unit", 5                -- 5 gears (10 plates), 10 pipes (10 plates), 5 steel: 20 plates asked
local P_GEAR = { kind = "processing", inputs = { { key = "iron-plate", amount = 2 } }, outputs = { { key = "iron-gear-wheel", amount = 1 } } }
local P_PIPE = { kind = "processing", inputs = { { key = "iron-plate", amount = 1 } }, outputs = { { key = "pipe", amount = 1 } } }
local P_ENGINE = { kind = "processing", inputs = { { key = "iron-gear-wheel", amount = 1 }, { key = "pipe", amount = 2 },
	{ key = "steel-plate", amount = 1 } }, outputs = { { key = KEY, amount = 1 } } }
local P_GEAR2 = { kind = "processing", inputs = { { key = "copper-plate", amount = 3 } }, outputs = { { key = "iron-gear-wheel", amount = 1 } } }
local P_PIPE2 = { kind = "processing", inputs = { { key = "stone", amount = 2 } }, outputs = { { key = "pipe", amount = 1 } } }

return function(H)
	local me_place, me_report = H.me_place, H.me_report
	local T = {}

	function T.setup(s)
		local fails = {}
		local what = "kept plans"
		local eei = me_place(s, fails, what, "electric-energy-interface", BX + 8, BY - 4)
		if eei then
			eei.power_production = 1e6
			eei.electric_buffer_size = 1e7
		end
		me_place(s, fails, what, "substation", BX + 11, BY - 4)
		for x = BX, BX + 24 do me_place(s, fails, what, "me-cable", x + 0.5, BY + 1.5) end
		local ctrl = me_place(s, fails, what, "me-network-controller", BX + 6, BY)
		local prov = me_place(s, fails, what, "me-pattern-provider", BX + 1.5, BY + 0.5)
		me_place(s, fails, what, "steel-chest", BX + 1.5, BY - 0.5)
		me_place(s, fails, what, "me-1k-crafting-storage", BX + 3.5, BY + 0.5)
		local term = me_place(s, fails, what, "me-terminal", BX + 9.5, BY + 0.5)
		local drive = me_drive(s, fails, what, BX + 22, BY + 3, { ["iron-plate"] = 100, ["steel-plate"] = 10, stone = 50, ["copper-plate"] = 30 })
		me_connect(fails, what, { ctrl, drive })
		if prov then give_patterns(prov, { P_GEAR, P_PIPE, P_ENGINE }, fails) end
		storage.plans50_scene = { ctrl = ctrl, prov = prov, term = term, drive = drive }
		return fails
	end

	local function digest(p)
		if not p then return "nil" end
		return serpent.line({ ok = p.ok, missing = p.missing, reserve = p.reserve, pids = p.pids, step_runs = p.step_runs, runs = p.runs,
			loops = p.loops, bytes = p.bytes, no_pattern = p.no_pattern, too_complex = p.too_complex }, { comment = false, sortkeys = true })
	end

	function T.tick()
		local tick = game.tick
		local sc = storage.plans50_scene
		local st = storage.plans50
		if not st then
			if tick < START or not sc then return end
			st = { problems = {}, done = false, step = 0, next = tick, cases = {} }
			storage.plans50 = st
		end
		if st.done or tick < st.next then return end
		local problems = st.problems
		local s = game.surfaces[1]
		local ctrl = sc.ctrl
		if not (ctrl and ctrl.valid and sc.prov and sc.prov.valid and sc.term and sc.term.valid) then
			problems[#problems + 1] = "the test network was not built"
			st.done = true
			me_report("PLANS", "ME kept plans", problems, "no network")
			return
		end
		--- one plan through the kept plans against a fresh one of the same state; `want`: "hit" (kept) or "miss" (made anew)
		local function case(name, want)
			local before = remote.call(AC, "kept_plan_stats")
			local kept = remote.call(AC, "plan", ctrl, KEY, AMOUNT)
			local after = remote.call(AC, "kept_plan_stats")
			local fresh = remote.call(AC, "plan", ctrl, KEY, AMOUNT, true)
			local got = (after.hits > before.hits) and "hit" or "miss"
			if digest(kept) ~= digest(fresh) then
				problems[#problems + 1] = name .. ": the kept plan differs from a fresh one: " .. digest(kept) .. " against " .. digest(fresh)
			end
			if want and got ~= want then problems[#problems + 1] = name .. ": a " .. got .. ", not a " .. want end
			st.cases[#st.cases + 1] = name .. " " .. got
			return kept
		end
		local function count(key) return remote.call(NET, "count", ctrl, key) end
		local function preview() return remote.call(TERM, "craft_preview", sc.term, KEY, AMOUNT) end
		st.step = st.step + 1
		local step = st.step
		st.next = tick + 10
		if step == 1 then
			--- everything in one tick: no provider rescan in between can change the patterns
			local p = case("first plan", "miss")
			if not (p and p.ok) then problems[#problems + 1] = "the first plan is not ok: " .. digest(p) end
			case("the same state again", "hit")
			remote.call(NET, "insert", ctrl, "stone", 10)
			case("a key the plan never read changed", "hit")
			remote.call(NET, "extract", ctrl, "iron-plate", 10)
			case("iron 100 -> 90, the plan asked 20", "hit")
			remote.call(NET, "extract", ctrl, "iron-plate", count("iron-plate") - 15)
			local short = case("iron 90 -> 15, below the 20 asked", "miss")
			if short and short.ok then problems[#problems + 1] = "with 15 iron plates the plan is still ok" end
			remote.call(NET, "insert", ctrl, "iron-plate", 85)
			case("iron 15 -> 100", "miss")
			st.free_before = preview().reason
			local id = remote.call(AC, "start", ctrl, KEY, 1)
			if not id then problems[#problems + 1] = "the job that keeps the CPU busy did not start" end
			st.job = id
			case("the CPU became busy (the job took 4 iron and 1 steel)", "hit")
			st.free_busy = preview().reason
		elseif step == 2 then
			if st.job then remote.call(AC, "cancel", st.job) end
			st.next = tick + 120
		elseif step == 3 then
			case("the CPU became free", nil)
			local r = preview().reason
			if st.free_before ~= nil or st.free_busy ~= "no-free-cpu" or r ~= nil then
				problems[#problems + 1] = "the preview's CPU: before " .. tostring(st.free_before) .. ", busy " .. tostring(st.free_busy)
					.. ", free again " .. tostring(r) .. " (nil, no-free-cpu, nil)"
			end
			give_patterns(sc.prov, { P_GEAR2 }, problems)
		elseif step == 4 then
			case("a pattern added", "miss")
			local inv = game.create_inventory(2)
			if not remote.call(AC, "take_pattern", sc.prov, 4, inv) then problems[#problems + 1] = "the added pattern was not taken out" end
			inv.destroy()
		elseif step == 5 then
			case("a pattern removed", "miss")
			local p2 = s.create_entity{ name = "me-pattern-provider", position = { BX + 13.5, BY + 0.5 }, force = "player", raise_built = true }
			s.create_entity{ name = "steel-chest", position = { BX + 13.5, BY - 0.5 }, force = "player", raise_built = true }
			sc.prov2 = p2
			if p2 then give_patterns(p2, { P_PIPE2 }, problems) else problems[#problems + 1] = "the second provider was not built" end
		elseif step == 6 then
			case("a provider built", "miss")
			if sc.prov2 and sc.prov2.valid then sc.prov2.destroy{ raise_destroy = true } end
			for _, e in pairs(s.find_entities_filtered{ type = "item-entity", area = { { BX + 10, BY - 3 }, { BX + 17, BY + 3 } } }) do e.destroy() end
		elseif step == 7 then
			case("a provider removed", "miss")
			local chest = s.find_entity("steel-chest", { BX + 1.5, BY - 0.5 })
			if chest then chest.destroy{ raise_destroy = true } end
		elseif step == 8 then
			local p = case("the machine of the patterns removed", "miss")
			if p and p.ok then problems[#problems + 1] = "without the chest of its patterns the plan is still ok" end
			s.create_entity{ name = "steel-chest", position = { BX + 1.5, BY - 0.5 }, force = "player", raise_built = true }
		elseif step == 9 then
			case("the machine of the patterns built", "miss")
			--- every cable next to the drive goes: the drive is a network of its own
			local b = sc.drive and sc.drive.valid and sc.drive.bounding_box
			st.cut = {}
			if b then
				for _, c in pairs(s.find_entities_filtered{ name = "me-cable", area = { { b.left_top.x - 1, b.left_top.y - 1 }, { b.right_bottom.x + 1, b.right_bottom.y + 1 } } }) do
					st.cut[#st.cut + 1] = { c.position.x, c.position.y }
					c.destroy{ raise_destroy = true }
				end
			end
			if #st.cut == 0 then problems[#problems + 1] = "no cable next to the drive to cut" end
		elseif step == 10 then
			local p = case("the network split (the drive left)", "miss")
			if p and p.ok then problems[#problems + 1] = "without its drive the plan is still ok" end
			for _, p in ipairs(st.cut or {}) do s.create_entity{ name = "me-cable", position = p, force = "player", raise_built = true } end
		elseif step == 11 then
			local p = case("the network joined again", "miss")
			if not (p and p.ok) then problems[#problems + 1] = "with its drive back the plan is not ok: " .. digest(p) end
			st.done = true
			me_report("PLANS", "ME kept plans", problems, #st.cases .. " cases: " .. table.concat(st.cases, "; "))
		end
	end

	function T.running(check) check(storage.plans50 and storage.plans50.done, "ME kept plans") end
	return T
end
