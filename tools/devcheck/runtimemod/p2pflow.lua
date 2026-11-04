--- Runtime test of me-network issue #633: ME P2P tunnels that carry on their own (no pattern provider).
--- One network with power: an item input tunnel fed by a fast inserter from a chest of PLATES iron plates, its two outputs
--- facing two chests; a fluid input tunnel whose front faces an infinity pipe of water, its two outputs facing two storage
--- tanks. Checks:
---   * the items end in the two chests (both get some: round robin), none is lost (chest, inserter, part and the two chests
---     hold PLATES);
---   * both tanks get water;
---   * the window's line says what the input holds and that it carries;
---   * the fluid input turned: its tank is made again in the new direction (its pipe connection is the front);
---   * the item input destroyed with items in its chest: the part goes, its items lie on the ground (none lost);
---   * an output's tile holds no part; an input of a provider (the P2P test) has one, and the provider never takes it as a
---     neighbour (checked there by its targets).
--- The scene runs through the save and load of the save-and-load run.
--- Loaded by control.lua: require("p2pflow")(H) returns { setup, tick, running }.

local NET, P2P, GUI = "gregtorio-me-network", "gregtorio-me-p2p", "gregtorio-me-gui"
local BX, BY = -880, -220
local START, LAST = 160, 1400
local PLATES = 30                                          -- (a fast inserter moves about 2.3 a second)
local FREQ_I, FREQ_F = 7100, 7101

return function(H)
	local me_place, me_report, power = H.me_place, H.me_report, H.power
	local T = {}

	function T.setup(s)
		local fails = {}
		local what = "p2p on their own"
		for x = BX - 6, BX + 40, 32 do
			for y = BY - 6, BY + 30, 32 do s.request_to_generate_chunks({ x, y }, 0) end
		end
		s.force_generate_chunk_requests()
		local tiles = {}
		for x = BX - 6, BX + 40 do
			for y = BY - 6, BY + 30 do tiles[#tiles + 1] = { name = "grass-1", position = { x, y } } end
		end
		s.set_tiles(tiles)
		power(s, fails, what, BX, BY)
		local ctrl = me_place(s, fails, what, "me-network-controller", BX + 7, BY)
		local N, S, E, W = defines.direction.north, defines.direction.south, defines.direction.east, defines.direction.west
		local sc = { ctrl = ctrl }
		--- items: chest -> fast inserter -> input tunnel (facing north, away from the inserter); outputs east of two chests
		sc.src = me_place(s, fails, what, "wooden-chest", BX + 2.5, BY + 8.5)
		sc.ins = me_place(s, fails, what, "fast-inserter", BX + 2.5, BY + 7.5, { direction = S })   -- (picks from the south)
		sc.in_item = me_place(s, fails, what, "me-item-p2p-tunnel", BX + 2.5, BY + 6.5, { direction = N })
		sc.c1 = me_place(s, fails, what, "wooden-chest", BX + 20.5, BY + 4.5)
		sc.c2 = me_place(s, fails, what, "wooden-chest", BX + 24.5, BY + 4.5)
		sc.o1 = me_place(s, fails, what, "me-item-p2p-tunnel", BX + 20.5, BY + 3.5, { direction = S })
		sc.o2 = me_place(s, fails, what, "me-item-p2p-tunnel", BX + 24.5, BY + 3.5, { direction = S })
		--- fluids: an infinity pipe in front of the input; outputs facing two storage tanks (3x3)
		sc.in_fluid = me_place(s, fails, what, "me-fluid-p2p-tunnel", BX + 4.5, BY + 12.5, { direction = W })
		sc.pipe = me_place(s, fails, what, "infinity-pipe", BX + 3.5, BY + 12.5)
		sc.t1 = me_place(s, fails, what, "storage-tank", BX + 21.5, BY + 13.5)
		sc.t2 = me_place(s, fails, what, "storage-tank", BX + 26.5, BY + 13.5)
		sc.f1 = me_place(s, fails, what, "me-fluid-p2p-tunnel", BX + 21.5, BY + 11.5, { direction = S })
		sc.f2 = me_place(s, fails, what, "me-fluid-p2p-tunnel", BX + 26.5, BY + 11.5, { direction = S })
		H.me_connect(fails, what, { ctrl, sc.in_item, sc.o1, sc.o2, sc.in_fluid, sc.f1, sc.f2 })
		if sc.src then sc.src.insert{ name = "iron-plate", count = PLATES } end
		if sc.pipe then sc.pipe.set_infinity_pipe_filter{ name = "water", percentage = 1 } end
		storage.p2pflow633_scene = sc
		return fails
	end

	local function info(e) return e and e.valid and remote.call(P2P, "info", e) or {} end
	local function items(e) return e and e.valid and e.get_item_count("iron-plate") or 0 end
	local function water(t)
		local f = t and t.valid and t.get_fluid(1)
		return f and f.amount or 0
	end

	function T.tick()
		local tick = game.tick
		local st = storage.p2pflow633
		if not st then
			if tick < START then return end
			st = { problems = {}, done = false, phase = 0 }
			storage.p2pflow633 = st
		end
		if st.done then return end
		local problems = st.problems
		local function expect(ok, text) if not ok then problems[#problems + 1] = text end end
		local function finish(note)
			st.done = true
			me_report("P2PFLOW", "ME P2P tunnels on their own (issue #633)", problems, note)
		end
		local sc = storage.p2pflow633_scene or {}
		local need = { "ctrl", "src", "ins", "c1", "c2", "o1", "o2", "in_fluid", "pipe", "t1", "t2", "f1", "f2" }
		if not st.removed then need[#need + 1] = "in_item" end
		for _, k in ipairs(need) do
			if not (sc[k] and sc[k].valid) then
				expect(false, "the scene is missing " .. k)
				return finish()
			end
		end
		local late = tick >= LAST

		if st.phase == 0 then
			expect(remote.call(P2P, "set", sc.in_item, FREQ_I, false), "the item input's frequency")
			expect(remote.call(P2P, "set", sc.o1, FREQ_I, true) and remote.call(P2P, "set", sc.o2, FREQ_I, true), "the item outputs")
			expect(remote.call(P2P, "set", sc.in_fluid, FREQ_F, false), "the fluid input's frequency")
			expect(remote.call(P2P, "set", sc.f1, FREQ_F, true) and remote.call(P2P, "set", sc.f2, FREQ_F, true), "the fluid outputs")
			local part = remote.call(P2P, "part", sc.in_item)
			expect(part and part.valid and part.name == "me-item-p2p-tunnel-buffer", "the item input's chest: " .. tostring(part and part.name))
			local tank = remote.call(P2P, "part", sc.in_fluid)
			expect(tank and tank.valid and tank.direction == sc.in_fluid.direction, "the fluid input's tank in its direction")
			expect(remote.call(P2P, "part", sc.o1) == nil, "an output has no part")
			st.phase, st.at = 1, tick
			return
		end

		if st.phase == 1 then
			--- until the chest is empty and the items are in the two chests, and the tanks have water
			local placed = items(sc.c1) + items(sc.c2)
			local ok = placed == PLATES and water(sc.t1) > 0 and water(sc.t2) > 0
			if not ok and not late and tick < st.at + 900 then return end
			local held = items(sc.src) + items(sc.ins) + items(remote.call(P2P, "part", sc.in_item)) + placed
			expect(placed == PLATES, "the chests got " .. items(sc.c1) .. " + " .. items(sc.c2) .. " of " .. PLATES)
			expect(items(sc.c1) > 0 and items(sc.c2) > 0, "round robin: " .. items(sc.c1) .. " + " .. items(sc.c2))
			expect(held == PLATES, "no plate lost: " .. held .. " of " .. PLATES)        -- (the inserter's count holds its hand)
			expect(water(sc.t1) > 0 and water(sc.t2) > 0, "the tanks: " .. water(sc.t1) .. ", " .. water(sc.t2))
			local v = remote.call(GUI, "p2p_view", sc.in_fluid)
			expect(type(v.carry) == "table" and v.carry[1] == "fork-me-gui.p2p-carry", "the fluid input's carry line: " .. serpent.line(v.carry))
			local d = info(sc.in_fluid)
			expect(d.carry == "working" or d.carry == "blocked", "the fluid input's state: " .. serpent.line(d))
			st.note = items(sc.c1) .. " + " .. items(sc.c2) .. " plates, water " .. string.format("%.0f", water(sc.t1)) .. " + "
				.. string.format("%.0f", water(sc.t2))
			--- the fluid input turned: its tank is made again in the new direction
			sc.in_fluid.direction = defines.direction.north
			remote.call(P2P, "rotated", sc.in_fluid)
			local tank = remote.call(P2P, "part", sc.in_fluid)
			expect(tank and tank.valid and tank.direction == defines.direction.north, "the turned input's tank: "
				.. tostring(tank and tank.valid and tank.direction))
			--- the item input destroyed with plates in its chest: they lie on the ground
			local part = remote.call(P2P, "part", sc.in_item)
			local inv = part and part.get_inventory(defines.inventory.chest)
			if inv then inv.insert{ name = "iron-plate", count = 7 } end
			local inside = items(part)
			local pos = sc.in_item.position
			st.removed = true
			sc.in_item.destroy{ raise_destroy = true }
			local ground = 0
			for _, g in pairs(game.surfaces[1].find_entities_filtered{ name = "item-on-ground", position = pos, radius = 3 }) do
				if g.stack.valid_for_read and g.stack.name == "iron-plate" then ground = ground + g.stack.count end
			end
			expect(ground == inside, "the destroyed input's plates on the ground: " .. ground .. " of " .. inside)
			expect(#game.surfaces[1].find_entities_filtered{ name = "me-item-p2p-tunnel-buffer", position = pos } == 0,
				"the destroyed input's chest is gone")
			return finish(st.note)
		end
	end

	function T.running(check)
		if storage.p2pflow633_scene and not (storage.p2pflow633 and storage.p2pflow633.done) then check("P2PFLOW") end
	end

	return T
end
