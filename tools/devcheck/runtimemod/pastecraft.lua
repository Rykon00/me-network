--- Runtime measurement of me-network issue #157: does a machine fed by an ME Interface that keeps one craft of its recipe
--- (what a recipe paste writes since #157) keep crafting? Three machines, each fed by an inserter from an interface:
--- the Molecular Assembler (the gear recipe), an iron furnace (iron dust) and a chemical reactor (a circuit board with
--- phenol: the board through an inserter, the phenol through a pipe from an interface side). Each with the interface
--- keeping one craft, two crafts and a stack (a fluid: one craft, two crafts, a side's volume). The products are taken
--- out by an inserter into a chest. Logged per case (DEVCHECK-RUNTIME-PASTECRAFT-CENSUS): the crafts in the window and
--- the most the machine could make in it. Checked: every machine crafted.
--- Loaded by control.lua: require("pastecraft")(H) returns { setup, tick, running }.

local IO = "gregtorio-me-io"
local BX, BY = 60, -330
local T0, T1 = 400, 1300                -- the window (ticks)
local MACHINES = {
	{ id = "assembler", name = "me-molecular-assembler", recipe = "iron-gear-crafting-table" },
	{ id = "furnace", name = "iron-furnace", recipe = "iron-dust-smelter" },
	{ id = "reactor", name = "hv-chemical-reactor", recipe = "phenolic-circuit-board" },
}
local VARIANTS = { 1, 2, "stack" }

return function(H)
	local me_place, me_report, power = H.me_place, H.me_report, H.power
	local T = {}

	local function inserter_name()
		if prototypes.entity["fast-inserter"] then return "fast-inserter" end
		return "inserter"
	end

	--- an inserter at (x, y) that takes from `from` and puts into `to` (tile centres)
	local function inserter(s, fails, what, x, y, from, to)
		local e = me_place(s, fails, what, inserter_name(), x, y)
		if e then
			e.pickup_position = from
			e.drop_position = to
		end
		return e
	end

	--- the rows of one interface for `variant` crafts of `recipe`: items (`fluid` false) or its fluids (true)
	local function rows(recipe, variant, fluid, volume)
		local out = {}
		for _, g in ipairs(prototypes.recipe[recipe].ingredients) do
			if (g.type == "fluid") == fluid then
				local amount
				if variant == "stack" then
					amount = fluid and volume or prototypes.item[g.name].stack_size
				else
					amount = math.ceil(g.amount * variant - 1e-6)
				end
				if fluid then out[#out + 1] = { type = "fluid", name = g.name, amount = amount }
				else out[#out + 1] = { name = g.name, quality = "normal", amount = amount } end
			end
		end
		return out
	end

	function T.setup(s)
		local fails = {}
		local what = "paste one craft"
		local tiles = {}
		for x = BX - 6, BX + 7 * 9 + 6 do
			for y = BY - 6, BY + 14 do tiles[#tiles + 1] = { name = "grass-1", position = { x, y } } end
		end
		s.set_tiles(tiles)
		power(s, fails, what, BX - 4, BY - 4)
		local ctrl = me_place(s, fails, what, "me-network-controller", BX + 3, BY - 4)
		local drive = H.me_drive(s, fails, what, BX + 4.5, BY - 4.5,
			{ ["iron-plate"] = 2000, ["iron-stick"] = 4000, ["iron-dust"] = 1000, ["resin-circuit-board"] = 1000 }, "64k")
		local fdrive = H.me_drive(s, fails, what, BX + 7.5, BY - 4.5, {}, "64k", true)
		local members = { ctrl, drive, fdrive }
		local cases = {}
		local col = 0
		for _, mdef in ipairs(MACHINES) do
			for _, v in ipairs(VARIANTS) do
				col = col + 1
				local X, Y = BX + 7 * (col - 1), BY
				local c = { id = mdef.id, variant = v, recipe = mdef.recipe }
				if not (prototypes.entity[mdef.name] and prototypes.recipe[mdef.recipe]) then
					fails[#fails + 1] = what .. ": " .. mdef.name .. " or " .. mdef.recipe .. " is missing"
				elseif mdef.id == "reactor" then
					--- the board through an inserter from the item interface (east of the fluid one), the phenol through a pipe
					c.iface = me_place(s, fails, what, "me-network-interface", X + 0.5, Y + 0.5)
					c.iitems = me_place(s, fails, what, "me-network-interface", X + 1.5, Y + 0.5)
					me_place(s, fails, what, "pipe", X + 0.5, Y + 1.5)
					c.machine = me_place(s, fails, what, mdef.name, X + 1.5, Y + 3.5)
					inserter(s, fails, what, X + 1.5, Y + 1.5, { X + 1.5, Y + 0.5 }, { X + 1.5, Y + 2.5 })
					inserter(s, fails, what, X + 1.5, Y + 5.5, { X + 1.5, Y + 4.5 }, { X + 1.5, Y + 6.5 })
					me_place(s, fails, what, "iron-chest", X + 1.5, Y + 6.5)
					members[#members + 1] = c.iface
					members[#members + 1] = c.iitems
				else
					c.iface = me_place(s, fails, what, "me-network-interface", X + 0.5, Y + 0.5)
					if mdef.id == "furnace" then
						c.machine = me_place(s, fails, what, mdef.name, X + 1, Y + 3)
						inserter(s, fails, what, X + 0.5, Y + 1.5, { X + 0.5, Y + 0.5 }, { X + 0.5, Y + 2.5 })
						inserter(s, fails, what, X + 0.5, Y + 4.5, { X + 0.5, Y + 3.5 }, { X + 0.5, Y + 5.5 })
						me_place(s, fails, what, "iron-chest", X + 0.5, Y + 5.5)
						if c.machine then c.machine.get_inventory(defines.inventory.fuel).insert{ name = "coal", count = 50 } end
					else
						c.machine = me_place(s, fails, what, mdef.name, X + 0.5, Y + 2.5)
						inserter(s, fails, what, X + 0.5, Y + 1.5, { X + 0.5, Y + 0.5 }, { X + 0.5, Y + 2.5 })
						inserter(s, fails, what, X + 0.5, Y + 3.5, { X + 0.5, Y + 2.5 }, { X + 0.5, Y + 4.5 })
						me_place(s, fails, what, "iron-chest", X + 0.5, Y + 4.5)
					end
					members[#members + 1] = c.iface
				end
				if c.machine and mdef.id ~= "furnace" then
					c.machine.force.recipes[mdef.recipe].enabled = true
					c.machine.set_recipe(mdef.recipe)
				end
				if mdef.id == "furnace" then game.forces.player.recipes[mdef.recipe].enabled = true end
				local eei = me_place(s, fails, what, "electric-energy-interface", X + 4.5, Y + 9.5)
				if eei then
					eei.power_production = 1e9
					eei.electric_buffer_size = 1e10
				end
				me_place(s, fails, what, "substation", X + 4, Y + 7)
				cases[#cases + 1] = c
			end
		end
		H.me_connect(fails, what, members)
		storage.pastecraft157_scene = { ctrl = ctrl, cases = cases }
		return fails
	end

	function T.tick()
		local tick = game.tick
		local st = storage.pastecraft157
		local sc = storage.pastecraft157_scene
		if not st then
			if tick < 100 or not sc then return end
			st = { problems = {}, done = false, phase = 0 }
			storage.pastecraft157 = st
		end
		if st.done then return end
		local problems = st.problems
		local function expect(ok, text) if not ok then problems[#problems + 1] = text end end
		local function finish(note)
			st.done = true
			me_report("PASTECRAFT", "ME interface keeping one craft", problems, note)
		end
		if st.phase == 0 then
			st.phase = 1
			remote.call("gregtorio-me-fluids", "insert", sc.ctrl, "phenol", 50000)
			for _, c in ipairs(sc.cases) do
				if c.iface and c.iface.valid then
					local volume = remote.call(IO, "get_interface", c.iface).volume
					if c.iitems then
						--- the fluid interface: one fluid row on its south side (the pipe), every other side off; the item one: no sides
						remote.call(IO, "set_interface_config", c.iface, rows(c.recipe, c.variant, true, volume), { [1] = "off", [2] = "off", [3] = 1, [4] = "off" })
						remote.call(IO, "set_interface_config", c.iitems, rows(c.recipe, c.variant, false, volume), { "off", "off", "off", "off" })
					else
						remote.call(IO, "set_interface_config", c.iface, rows(c.recipe, c.variant, false, volume), { "off", "off", "off", "off" })
					end
				end
			end
			return
		end
		if st.phase == 1 then
			if tick < T0 then return end
			for _, c in ipairs(sc.cases) do c.f0 = c.machine and c.machine.valid and c.machine.products_finished or 0 end
			st.phase = 2
			return
		end
		if st.phase == 2 then
			if tick < T1 then return end
			local notes = {}
			for _, c in ipairs(sc.cases) do
				local m = c.machine
				if m and m.valid then
					local made = m.products_finished - c.f0
					local per = prototypes.recipe[c.recipe].energy / m.crafting_speed * 60        -- ticks per craft
					local most = (T1 - T0) / per
					local share = most > 0 and made / most or 0
					log("DEVCHECK-RUNTIME-PASTECRAFT-CENSUS " .. c.id .. " | " .. tostring(c.variant) .. " | crafts " .. made
						.. " | most " .. string.format("%.1f", most) .. " | " .. string.format("%.0f %%", 100 * share))
					notes[#notes + 1] = c.id .. " x" .. tostring(c.variant) .. " " .. string.format("%.0f%%", 100 * share)
					expect(made > 0, c.id .. " with " .. tostring(c.variant) .. " crafts: nothing crafted (status " .. tostring(m.status) .. ")")
				else
					expect(false, c.id .. " " .. tostring(c.variant) .. ": the machine is missing")
				end
			end
			return finish(table.concat(notes, ", "))
		end
	end

	function T.running(check) check(storage.pastecraft157 and storage.pastecraft157.done, "ME interface keeping one craft") end

	return T
end
