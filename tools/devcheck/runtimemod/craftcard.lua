--- Runtime test of me-network issue #411: the Crafting Card on the ME Export Bus and the ME Interface. A network with iron plates
--- and sticks (no gears), a 16k CPU and a pattern provider with an ME Molecular Assembler and a crafting pattern of the gear recipe;
--- an export bus on chest A with the filter "iron-gear-wheel" and an ME Interface:
---   * without the card the export bus starts no job; with it a visit starts one (its window data says so), a second visit no
---     second one, and the gears end in chest A;
---   * the import bus refuses the card;
---   * the interface with the card and a row of 10 gears starts a job for what the row lacks, and holds 10 gears after it.
--- Loaded by control.lua: require("craftcard")(H) returns { setup, tick, running }.

local NET, IO, AC = "gregtorio-me-network", "gregtorio-me-io", "gregtorio-me-autocraft"
local BX, BY = -150, 10               -- (inside the cleared test area, TEST_RADIUS of control.lua; clear of the other tests)
local START, TIMEOUT = 160, 1100
local CARD, GEAR, GEAR_RECIPE = "me-crafting-card", "iron-gear-wheel", "iron-gear-crafting-table"

return function(H)
	local me_place, cable_row, power, me_report = H.me_place, H.cable_row, H.power, H.me_report
	local T = {}
	local SOUTH = { direction = defines.direction.south }
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
		me_place(s, fails, what, "me-export-bus", BX + 10.5, BY - 1.5, { direction = defines.direction.north })
		me_place(s, fails, what, "iron-chest", BX + 10.5, BY - 2.5)
		me_place(s, fails, what, "me-import-bus", BX + 14.5, BY + 0.5, SOUTH)
		me_place(s, fails, what, "iron-chest", BX + 14.5, BY + 1.5)
		me_place(s, fails, what, "me-network-interface", BX + 18.5, BY + 0.5)
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
				.. "job with it and the gears exported; refused by the import bus; the interface crafts what its row lacks")
		end
		local E, I, IF, A = find("me-export-bus", 10, -2), find("me-import-bus", 14, 0), find("me-network-interface", 18, 0),
			find("iron-chest", 10, -3)
		if not (E and I and IF and A) then expect(false, "entities missing") return finish() end
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
		inv.destroy()

		if st.phase == "export" then
			if a.get_item_count(GEAR) == 0 then
				if game.tick > st.tick + TIMEOUT then
					expect(false, "no gears in chest A: " .. line(jobs()))
					return finish()
				end
				return
			end
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
			if active() > 0 then
				if game.tick > st.tick + TIMEOUT then
					expect(false, "the export bus's job does not end: " .. line(jobs()))
					return finish()
				end
				return
			end
			remote.call(IO, "set_interface_key", IF, 1, GEAR, 10)
			remote.call(IO, "step", IF)
			local d = remote.call(IO, "get_interface", IF) or {}
			expect(active() == 1 and d.craft == "crafting", "the interface starts a job for its row: " .. line({ jobs(), d.craft }))
			st.phase, st.tick = "interface", game.tick
			return
		end

		if st.phase == "interface" then
			local have = IF.get_inventory(defines.inventory.chest).get_item_count(GEAR)
			if have < 10 then
				if game.tick > st.tick + TIMEOUT then
					expect(false, "the interface holds " .. have .. " gears, not 10: " .. line(jobs()))
					return finish()
				end
				return
			end
			return finish()
		end
	end

	function T.running(check) check(storage.craftcard411 and storage.craftcard411.done, "Crafting Card on the export bus and the interface") end

	return T
end
