--- Runtime test of me-network issue #411: the Crafting Card on the ME Export Bus and the ME Interface. A network with iron plates
--- and sticks (no gears), a 16k CPU and a pattern provider with an ME Molecular Assembler and a crafting pattern of the gear recipe;
--- an export bus on chest A with the filter "iron-gear-wheel" and an ME Interface:
---   * without the card the export bus starts no job; with it a visit starts one (its window data says so), a second visit no
---     second one, and the gears end in chest A;
---   * the import bus refuses the card;
---   * the interface with the card and a row of 10 gears starts a job for what the row lacks, and holds 10 gears after it.
--- Issue #426 (a crafting pattern of molten tin at an extractor next to a second provider, a drive of fluid cells, tin ingots, a
--- second CPU):
---   * craft only: the export bus takes none of the 5 gears the network has, starts a job, and the job's gears go straight into
---     chest A (the network still has its 5); a clone of the bus keeps the setting;
---   * fluids: an export bus with the card on a pipe and the filter "fluid/molten-tin", which the network lacks, starts a job and
---     the molten tin goes straight into the pipe; the interface's fluid row of 50 molten tin starts one and its side's tank holds
---     50 after it.
--- Loaded by control.lua: require("craftcard")(H) returns { setup, tick, running }.

local NET, IO, AC = "gregtorio-me-network", "gregtorio-me-io", "gregtorio-me-autocraft"
local BX, BY = -150, 10               -- (inside the cleared test area, TEST_RADIUS of control.lua; clear of the other tests)
local START, TIMEOUT = 160, 1100
local CARD, GEAR, GEAR_RECIPE = "me-crafting-card", "iron-gear-wheel", "iron-gear-crafting-table"
local TIN, TIN_KEY = "molten-tin", "fluid/molten-tin"   -- (issue #426: 1 tin ingot -> 14.4 molten tin, Gregtorio's or the stand-in)

return function(H)
	local me_place, cable_row, power, me_report = H.me_place, H.cable_row, H.power, H.me_report
	local T = {}
	local SOUTH = { direction = defines.direction.south }
	local NORTH = { direction = defines.direction.north }
	local function at(dx, dy) return { BX + dx + 0.5, BY + dy + 0.5 } end
	local function line(t) return serpent.line(t) end

	function T.setup(s)
		local fails = {}
		local what = "crafting card"
		power(s, fails, what, BX, BY)
		power(s, fails, what, BX + 22, BY - 8)
		me_place(s, fails, what, "me-network-controller", BX + 7, BY)             -- tiles 6..7, -1..0
		H.me_drive(s, fails, what, BX + 8.5, BY - 0.5, { ["iron-plate"] = 300, ["iron-stick"] = 600, [CARD] = 2 })
		cable_row(s, fails, BX + 9, BX + 20, BY - 1)
		me_place(s, fails, what, "me-16k-crafting-storage", BX + 12.5, BY + 0.5)   -- (room for a stack of gears)
		me_place(s, fails, what, "me-pattern-provider", BX + 16.5, BY - 1.5)
		local m = me_place(s, fails, what, "me-molecular-assembler", BX + 16.5, BY - 2.5)
		if m then
			m.force.recipes[GEAR_RECIPE].enabled = true
			--- (five Acceleration Cards: the export bus's job of a stack of gears ends within the test's ticks)
			m.get_module_inventory().insert{ name = "me-acceleration-card", count = 5 }
		end
		local p = s.find_entity("me-pattern-provider", at(16, -2))
		if p then give_patterns(p, { { kind = "crafting", recipe = GEAR_RECIPE } }, fails) end
		me_place(s, fails, what, "me-export-bus", BX + 10.5, BY - 1.5, NORTH)
		me_place(s, fails, what, "iron-chest", BX + 10.5, BY - 2.5)
		me_place(s, fails, what, "me-import-bus", BX + 14.5, BY + 0.5, SOUTH)
		me_place(s, fails, what, "iron-chest", BX + 14.5, BY + 1.5)
		me_place(s, fails, what, "me-network-interface", BX + 18.5, BY + 0.5)
		--- issue #426: fluid cells, tin ingots, a second CPU, an export bus on a pipe, a provider with the extractor of molten tin
		H.me_drive(s, fails, what, BX + 8.5, BY + 0.5, {}, "1k", true)
		H.me_drive(s, fails, what, BX + 9.5, BY + 0.5, { ["tin-ingot"] = 40 })
		me_place(s, fails, what, "me-16k-crafting-storage", BX + 16.5, BY + 0.5)
		me_place(s, fails, what, "me-export-bus", BX + 12.5, BY - 1.5, NORTH)
		me_place(s, fails, what, "pipe", BX + 12.5, BY - 2.5)
		me_place(s, fails, what, "me-pattern-provider", BX + 20.5, BY - 1.5)
		local x = me_place(s, fails, what, prototypes.entity["ev-fluid-extractor"] and "ev-fluid-extractor" or "ev-extractor",
			BX + 22.5, BY - 2.5)
		if x then
			x.force.recipes[TIN].enabled = true
			local ok, err = pcall(function() x.set_recipe(TIN) end)
			if not ok then fails[#fails + 1] = what .. ": recipe " .. TIN .. ": " .. tostring(err) end
		end
		local p2 = s.find_entity("me-pattern-provider", at(20, -2))
		if p2 then give_patterns(p2, { { kind = "crafting", recipe = TIN } }, fails) end
		return fails
	end

	function T.tick()
		local st = storage.craftcard411
		if (st and st.done) or game.tick < START then return end
		local s = game.surfaces[1]
		local function find(name, dx, dy) return s.find_entity(name, at(dx, dy)) end
		if not st then
			st = { problems = {}, phase = "start" }
			storage.craftcard411 = st
		end
		local problems = st.problems
		local function expect(ok, msg) if not ok then problems[#problems + 1] = msg end end
		local function finish()
			st.done = true
			me_report("CRAFTCARD", "Crafting Card on the export bus and the interface", problems, "no job without the card, one "
				.. "job with it and the gears exported; refused by the import bus; the interface crafts what its row lacks; craft "
				.. "only leaves the network's gears and hands the job's to the chest; molten tin crafted into the bus's pipe and the "
				.. "interface's fluid side (issue #426)")
		end
		local E, I, IF, A = find("me-export-bus", 10, -2), find("me-import-bus", 14, 0), find("me-network-interface", 18, 0),
			find("iron-chest", 10, -3)
		local F, PIPE = find("me-export-bus", 12, -2), find("pipe", 12, -3)
		if not (E and I and IF and A and F and PIPE) then expect(false, "entities missing") return finish() end
		local a = A.get_inventory(defines.inventory.chest)
		local function jobs() return remote.call(AC, "jobs", E) or {} end
		local function active()
			local n = 0
			for _, j in pairs(jobs()) do if j.active then n = n + 1 end end
			return n
		end
		local inv = game.create_inventory(1)
		local function put(click, block)
			inv[1].set_stack{ name = CARD, count = 1 }
			local why = remote.call(IO, click, block, 1, inv[1], inv, false)
			local ok = why == nil and not inv[1].valid_for_read
			inv[1].clear()
			return ok, why
		end
		local function waited(msg)
			if game.tick > st.tick + TIMEOUT then
				expect(false, msg)
				finish()
			end
		end

		if st.phase == "start" then
			remote.call(IO, "set_bus_filters", E, { GEAR })
			remote.call(IO, "step", E)
			expect(active() == 0, "without the card the export bus started a job: " .. line(jobs()))
			local ok, why = put("bus_card_click", I)
			expect(not ok and why == "not-here", "the import bus refuses the Crafting Card: " .. tostring(why))
			expect(put("bus_card_click", E), "the Crafting Card goes into the export bus")
			remote.call(IO, "step", E)
			local d = remote.call(IO, "bus_info", E) or {}
			expect(active() == 1 and d.craft == "crafting", "with the card a visit starts one job: " .. line({ jobs(), d.craft }))
			remote.call(IO, "step", E)
			expect(active() == 1, "a second visit starts no second job: " .. active())
			inv.destroy()
			st.phase, st.tick = "export", game.tick
			return
		end

		if st.phase == "export" then
			inv.destroy()
			if a.get_item_count(GEAR) == 0 then return waited("no gears in chest A: " .. line(jobs())) end
			--- the bus would go on crafting while the chest has room: no filter, then the interface
			remote.call(IO, "set_bus_filters", E, {})
			local inv2 = game.create_inventory(1)
			inv2[1].set_stack{ name = CARD, count = 1 }
			local why = remote.call(IO, "interface_card_click", IF, 4, inv2[1], inv2, false)
			expect(why == nil and not inv2[1].valid_for_read, "the Crafting Card goes into the interface's fourth slot: " .. tostring(why))
			inv2.destroy()
			st.phase, st.tick = "wait", game.tick
			return
		end

		if st.phase == "wait" then
			inv.destroy()
			if active() > 0 then return waited("the export bus's job does not end: " .. line(jobs())) end
			remote.call(IO, "set_interface_key", IF, 1, GEAR, 10)
			remote.call(IO, "step", IF)
			local d = remote.call(IO, "get_interface", IF) or {}
			expect(active() == 1 and d.craft == "crafting", "the interface starts a job for its row: " .. line({ jobs(), d.craft }))
			st.phase, st.tick = "interface", game.tick
			return
		end

		if st.phase == "interface" then
			inv.destroy()
			local have = IF.get_inventory(defines.inventory.chest).get_item_count(GEAR)
			if have < 10 then return waited("the interface holds " .. have .. " gears, not 10: " .. line(jobs())) end
			--- issue #426: craft only. The network gets 5 gears; the bus takes none of them, it crafts and the job's gears go
			--- straight into chest A
			a.clear()
			remote.call(NET, "insert", E, GEAR, 5)
			st.gears = remote.call(NET, "count", E, GEAR)
			expect(remote.call(IO, "set_bus_craft_only", E, true), "craft only set on the export bus")
			remote.call(IO, "set_bus_filters", E, { GEAR })
			remote.call(IO, "step", E)
			local d = remote.call(IO, "bus_info", E) or {}
			expect(a.get_item_count(GEAR) == 0 and remote.call(NET, "count", E, GEAR) == st.gears and d.conly == true,
				"craft only took gears from storage: chest " .. a.get_item_count(GEAR) .. ", network "
				.. remote.call(NET, "count", E, GEAR) .. " of " .. st.gears .. ", " .. tostring(d.conly))
			expect(active() == 1 and d.craft == "crafting", "craft only starts a job: " .. line({ jobs(), d.craft }))
			local c = E.clone{ position = at(30, 6), surface = s, force = E.force }
			expect(c and (remote.call(IO, "get_bus", c) or {}).conly == true, "a clone keeps craft only")
			if c then c.destroy{ raise_destroy = true } end
			st.phase, st.tick = "conly", game.tick
			return
		end

		if st.phase == "conly" then
			inv.destroy()
			if a.get_item_count(GEAR) == 0 then return waited("craft only: no gears in chest A: " .. line(jobs())) end
			expect(remote.call(NET, "count", E, GEAR) == st.gears, "craft only: the network's gears changed: "
				.. remote.call(NET, "count", E, GEAR) .. " of " .. st.gears)
			remote.call(IO, "set_bus_filters", E, {})
			remote.call(IO, "set_bus_craft_only", E, false)
			--- fluids: the export bus F on a pipe with the card and molten tin, which the network lacks
			local inv3 = game.create_inventory(1)
			inv3[1].set_stack{ name = CARD, count = 1 }
			local why = remote.call(IO, "bus_card_click", F, 1, inv3[1], inv3, false)
			expect(why == nil and not inv3[1].valid_for_read, "the Crafting Card goes into the fluid export bus: " .. tostring(why))
			inv3.destroy()
			remote.call(IO, "set_bus_filters", F, { TIN_KEY })
			remote.call(IO, "step", F)
			local d = remote.call(IO, "bus_info", F) or {}
			expect(d.craft == "crafting", "a missing fluid filter starts a job: " .. line({ jobs(), d.craft }))
			st.phase, st.tick = "fluid", game.tick
			return
		end

		if st.phase == "fluid" then
			inv.destroy()
			local n = PIPE.get_fluid_count(TIN)
			if n < 99.9 then return waited("molten tin in the export bus's pipe: " .. n .. ": " .. line(jobs())) end
			--- (what the job made over the pipe's 100 is in the network: taken away, so the interface's row finds none)
			local rest = remote.call(NET, "fluid_count", F, TIN) or 0
			expect(rest < 1, "the job's molten tin went into the network, not the pipe: " .. rest)
			if rest > 0 then remote.call(NET, "extract_fluid", F, TIN, rest) end
			remote.call(IO, "set_bus_filters", F, {})
			remote.call(IO, "set_interface_key", IF, 2, TIN_KEY, 50)
			remote.call(IO, "step", IF)
			local d = remote.call(IO, "get_interface", IF) or {}
			expect(d.craft == "crafting", "the interface's fluid row starts a job: " .. line({ jobs(), d.craft }))
			st.phase, st.tick = "ifluid", game.tick
			return
		end

		if st.phase == "ifluid" then
			inv.destroy()
			local sides, tanks = remote.call(IO, "get_interface_sides", IF) or {}, remote.call(IO, "interface_tanks", IF) or {}
			local n = 0
			for d, v in pairs(sides) do if v == 2 and tanks[d] then n = tanks[d].get_fluid_count(TIN) end end
			if n < 49.9 then return waited("molten tin in the interface's side: " .. n .. ": " .. line(jobs())) end
			return finish()
		end
		inv.destroy()
	end

	function T.running(check) check(storage.craftcard411 and storage.craftcard411.done, "Crafting Card on the export bus and the interface") end

	return T
end
