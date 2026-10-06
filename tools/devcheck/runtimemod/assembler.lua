--- Runtime test of me-network issue #131 (docs/AE2.md "Autocrafting"): the ME Molecular Assembler is one tile.
--- * the prototype: one tile (tile size, collision and selection box of the other 1x1 ME blocks), five module slots that take
---   only the Acceleration Card, no fluid boxes, and nothing laid out for a bigger machine left in it (the alt-mode icon
---   specification, the icons of the cards, the alert icon, the circuit connector's points: all within one tile)
--- * AE2's layout: one pattern provider with an ME Molecular Assembler on its sides: the provider reports three machines for its
---   crafting pattern (north, east and south; its west side is the cable that joins it to the network: a provider with a machine
---   on all four sides could not be connected, the cable router finds no path to it), and one job of 36 gears is crafted by all
---   three of them (each makes some, together exactly the 36)
--- * one tile away is no neighbour: a fourth assembler two tiles from the provider (where a 3x3 machine's edge would touch it)
---   is no machine of its pattern ("machines" stays three)
--- Loaded by control.lua: require("assembler")(H) returns { setup, tick, running } like crafter.lua.

local AC, NET_ = "gregtorio-me-autocraft", "gregtorio-me-network"
local BX, BY = -250, 20
local START, TIMEOUT = 100, 900
local GEAR = "iron-gear-crafting-table"
local SIDES = { { 0, -1 }, { 1, 0 }, { 0, 1 } }                      -- north, east, south (the provider's order; west is the cable)

return function(H)
	local me_place, me_report, power = H.me_place, H.me_report, H.power
	local T = {}

	function T.setup(s)
		local fails = {}
		local what = "three assemblers"
		local tiles = {}                                         -- (land under the scene: the map may have water there)
		for x = BX - 4, BX + 26 do
			for y = BY - 4, BY + 12 do tiles[#tiles + 1] = { name = "grass-1", position = { x, y } } end
		end
		s.set_tiles(tiles)
		power(s, fails, what, BX, BY)
		me_place(s, fails, what, "substation", BX + 20, BY + 5)
		local ctrl = me_place(s, fails, what, "me-network-controller", BX + 7, BY)
		local drive = me_drive(s, fails, what, BX + 8.5, BY - 0.5, { ["iron-plate"] = 400, ["iron-stick"] = 400 })
		local cpu = me_place(s, fails, what, "me-crafting-cpu", BX + 11, BY)
		local px, py = BX + 14.5, BY + 5.5
		local prov = me_place(s, fails, what, "me-pattern-provider", px, py)
		local ms = {}
		for i, d in ipairs(SIDES) do ms[i] = me_place(s, fails, what, "me-molecular-assembler", px + d[1], py + d[2]) end
		me_connect(fails, what, { ctrl, drive, cpu, prov })
		storage.assembler131_scene = { ctrl = ctrl, prov = prov, ms = ms }
		return fails
	end

	function T.tick()
		local tick = game.tick
		local st = storage.assembler131
		if not st then
			if tick < START then return end
			st = { problems = {}, done = false, phase = "start" }
			storage.assembler131 = st
		end
		if st.done then return end
		local problems = st.problems
		local function expect(ok, text) if not ok then problems[#problems + 1] = text end end
		local function finish(note)
			st.done = true
			me_report("ASSEMBLER", "ME Molecular Assembler 1x1", problems, note)
		end
		local sc = storage.assembler131_scene
		local ok = sc and sc.ctrl and sc.ctrl.valid and sc.prov and sc.prov.valid
		for i = 1, 3 do ok = ok and sc.ms[i] and sc.ms[i].valid end
		if not ok then
			expect(false, "the entities were not built")
			return finish()
		end
		if st.phase == "start" then
			--- the prototype
			local p = prototypes.entity["me-molecular-assembler"]
			expect(p.tile_width == 1 and p.tile_height == 1, "the assembler is " .. p.tile_width .. "x" .. p.tile_height)
			local cb, sb = p.collision_box, p.selection_box
			local function near(a, b) return math.abs(a - b) < 0.01 end
			expect(near(cb.left_top.x, -0.35) and near(cb.right_bottom.x, 0.35) and near(cb.left_top.y, -0.35) and near(cb.right_bottom.y, 0.35),
				"collision box " .. serpent.line(cb))
			expect(near(sb.left_top.x, -0.5) and near(sb.right_bottom.x, 0.5) and near(sb.left_top.y, -0.5) and near(sb.right_bottom.y, 0.5),
				"selection box " .. serpent.line(sb))
			expect(p.module_inventory_size == 5, "module slots " .. tostring(p.module_inventory_size))
			expect(#p.fluidbox_prototypes == 0, "the assembler has fluid boxes")
			for i = 1, 3 do
				local m = sc.ms[i]
				local inv = m.get_module_inventory()
				expect(inv and #inv == 5, "module inventory of machine " .. i)
				expect(inv and inv.can_insert{ name = "me-acceleration-card" } and not inv.can_insert{ name = "speed-module" },
					"machine " .. i .. " takes the wrong modules")
			end
			--- the provider: four machines for the pattern
			local fails = {}
			give_patterns(sc.prov, { { kind = "crafting", recipe = GEAR } }, fails)
			for _, f in pairs(fails) do expect(false, f) end
			local info = remote.call(AC, "provider_info", sc.prov)
			expect(info.slots[1] and info.slots[1].ok and info.slots[1].machines == 3, "the provider's slot: " .. serpent.line(info.slots[1]))
			--- a fifth assembler two tiles from the provider (a 3x3 machine's edge would have touched it) is no machine of it
			local far = me_place(game.surfaces[1], {}, "far", "me-molecular-assembler", sc.prov.position.x + 2, sc.prov.position.y)
			st.far = far
			info = remote.call(AC, "provider_info", sc.prov)
			expect(info.slots[1] and info.slots[1].machines == 3, "a machine two tiles from the provider counts: " .. serpent.line(info.slots[1]))
			if far and far.valid then far.destroy() end
			if #problems > 0 then return finish() end
			st.finished = {}
			for i = 1, 3 do st.finished[i] = sc.ms[i].products_finished end
			local why
			st.job, why = remote.call(AC, "start", sc.ctrl, "iron-gear-wheel", 36)
			st.since, st.phase = tick, "job"
			expect(st.job ~= nil, "the job did not start: " .. tostring(why))
			if not st.job then finish() end
			return
		end
		local j = remote.call(AC, "job", st.job)
		if not (j and (j.status == "done" or j.status == "failed" or j.status == "cancelled")) then
			if tick > st.since + TIMEOUT then
				expect(false, "the job timed out: " .. serpent.line(j))
				finish()
			end
			return
		end
		expect(j.status == "done", "the job ended as " .. j.status .. " " .. serpent.line(j.reason))
		local made, total = {}, 0
		for i = 1, 3 do
			made[i] = sc.ms[i].products_finished - st.finished[i]
			total = total + made[i]
			expect(made[i] > 0, "machine " .. i .. " (" .. ({ "north", "east", "south" })[i] .. ") crafted nothing: " .. serpent.line(made))
		end
		expect(total == 36, "the three machines crafted " .. total .. " gears, not 36: " .. serpent.line(made))
		expect(remote.call(NET_, "count", sc.ctrl, "iron-gear-wheel") == 36, "the network holds " .. tostring(remote.call(NET_, "count", sc.ctrl, "iron-gear-wheel")) .. " gears")
		finish("one provider, three assemblers around it: each crafted some of the 36 gears (" .. table.concat(made, ", ") .. "), a machine two tiles away is none")
	end

	function T.running(check) check(storage.assembler131 and storage.assembler131.done, "ME Molecular Assembler 1x1") end
	return T
end
