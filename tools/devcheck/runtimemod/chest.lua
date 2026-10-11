--- Runtime test of me-network issue #229: the ME Chest (AE2's). A chest on its own (no ME Controller) on power from the grid:
--- without a cell its terminal says so; with a cell its terminal stores and takes on that cell only; what is put into its
--- container goes into the cell, what the cell refuses waits there and comes back through the window; a fluid cell is filled
--- from its pipe connection (a pipe next to it connects); without power nothing goes in. A chest in a working network: its cell is
--- network storage at the chest's priority, the network pays its power (its own buffer draws nothing), its terminal still sees
--- its cell only. Mined: the cell comes with it, its hidden parts go.
--- Loaded by control.lua: require("chest")(H) returns { setup, tick, running }.

local NET, TERM = "gregtorio-me-network", "gregtorio-me-terminal"
local BX, BY = 160, -420
local START = 170

return function(H)
	local me_place, me_report, power = H.me_place, H.me_report, H.power
	local T = {}

	function T.setup(s)
		local fails = {}
		local what = "ME chest"
		power(s, fails, what, BX, BY)                                                  -- (substation at BX + 3)
		me_place(s, fails, what, "me-chest", BX + 6.5, BY + 0.5)                       -- A: on its own, an item cell
		me_place(s, fails, what, "me-chest", BX + 8.5, BY + 0.5)                       -- C: on its own, a fluid cell
		me_place(s, fails, what, "pipe", BX + 8.5, BY + 1.5)
		power(s, fails, what, BX, BY + 12)
		local ctrl = me_place(s, fails, what, "me-network-controller", BX + 7, BY + 12)
		local drive = H.me_drive(s, fails, what, BX + 8.5, BY + 11.5, {}, "16k")
		me_place(s, fails, what, "me-chest", BX + 9.5, BY + 11.5)                      -- B: in the network
		H.me_connect(fails, what, { ctrl, drive })
		return fails
	end

	local function cell_stack(inv, i, name, items)
		inv[i].set_stack{ name = name, count = 1, tags = items and { fork_me_cell = { items = items, data = {} } } or nil }
		return inv[i]
	end

	function T.tick()
		local st = storage.chest229
		if st and st.done then return end
		if game.tick < START then return end
		local s = game.surfaces[1]
		local function find(name, x, y) return s.find_entity(name, { BX + x, BY + y }) end
		local a, c, b = find("me-chest", 6.5, 0.5), find("me-chest", 8.5, 0.5), find("me-chest", 9.5, 11.5)
		local drive, ctrl = find("me-drive", 8.5, 11.5), find("me-network-controller", 7, 12)
		if not st then
			st = { problems = {}, step = 1, at = game.tick }
			storage.chest229 = st
		end
		local problems = st.problems
		local function expect(ok, text) if not ok then problems[#problems + 1] = text end end
		if not (a and c and b and drive and ctrl) then
			st.done = true
			return me_report("CHEST", "ME Chest", { "entities missing" })
		end
		local inv = game.create_inventory(4)
		if st.step == 1 then
			--- on its own, without a cell
			local info = remote.call(NET, "chest", a)
			expect(info and info.powered and info.own and not info.network, "chest A powered on its own: " .. serpent.line(info))
			expect(remote.call(TERM, "problem", a) == "chest-no-cell", "no cell: " .. tostring(remote.call(TERM, "problem", a)))
			--- a cell in, a second one refused
			expect(remote.call(NET, "insert_cell", a, cell_stack(inv, 1, "me-1k-storage-cell"), 1) == 1, "a cell into chest A")
			local _, why = remote.call(NET, "insert_cell", a, cell_stack(inv, 2, "me-1k-storage-cell"))
			expect(why == "drive-full", "a second cell refused: " .. tostring(why))
			inv[2].clear()
			expect(remote.call(TERM, "problem", a) == nil, "with a cell it works: " .. tostring(remote.call(TERM, "problem", a)))
			--- its terminal stores and takes on its cell
			inv[1].set_stack{ name = "iron-plate", count = 10 }
			expect(remote.call(TERM, "store_stack", a, inv[1]) == 10, "10 iron stored through its terminal")
			expect(remote.call(TERM, "withdraw", a, inv, "iron-plate", "normal", 4) == 4, "4 iron taken")
			expect(remote.call(NET, "chest_count", a, "iron-plate") == 6, "6 iron in its cell: " .. remote.call(NET, "chest_count", a, "iron-plate"))
			local entries = remote.call(TERM, "entries", a, "", "count", "all", true)
			expect(#entries == 1 and entries[1].key == "iron-plate" and entries[1].count == 6, "its grid: " .. serpent.line(entries))
			--- what goes into its container goes into the cell; a blueprint waits
			a.insert{ name = "copper-plate", count = 20 }
			c.insert{ name = "stone", count = 3 }                                 -- (C has no cell yet: it waits)
			--- the fluid chest: a fluid cell, water into its pipe connection; the pipe next to it connects
			expect(remote.call(NET, "insert_cell", c, cell_stack(inv, 3, "me-1k-fluid-storage-cell"), 1) == 1, "a fluid cell into chest C")
			local tank = s.find_entity("me-chest-fluid", c.position)
			expect(tank ~= nil, "chest C has its fluid part")
			if tank then tank.fluidbox[1] = { name = "water", amount = 100, temperature = 15 } end
			local pipe = find("pipe", 8.5, 1.5)
			local linked = false
			for _, fb in pairs(pipe and pipe.fluidbox.get_connections(1) or {}) do
				if fb.owner and fb.owner.name == "me-chest-fluid" then linked = true end
			end
			expect(linked, "a pipe next to the chest connects to it")
			st.step, st.at = 2, game.tick
		elseif st.step == 2 and game.tick >= st.at + 3 then
			expect(remote.call(NET, "chest_count", a, "copper-plate") == 20 and a.get_item_count("copper-plate") == 0,
				"copper from the container into the cell: " .. remote.call(NET, "chest_count", a, "copper-plate"))
			--- (the pipe next to it took its share of the 100 before the first tick: a fluid box flows both ways; the tank is
			--- emptied into the cell every tick, so what a pipe brings goes in)
			local water = remote.call(NET, "fluid_key", "water", 15)
			local in_cell = remote.call(NET, "chest_count", c, water)
			local pipe = find("pipe", 8.5, 1.5)
			local in_pipe = pipe and pipe.fluidbox[1] and pipe.fluidbox[1].amount or 0
			local tank = s.find_entity("me-chest-fluid", c.position)
			local in_tank = tank and tank.fluidbox[1] and tank.fluidbox[1].amount or 0
			expect(in_cell > 80 and math.abs(in_cell + in_pipe + in_tank - 100) < 0.01,
				"water from the pipe connection into the fluid cell, none lost: " .. in_cell .. " in the cell, " .. in_pipe
				.. " in the pipe, " .. in_tank .. " in the tank")
			local ci = remote.call(NET, "chest", c)
			expect(ci.input and ci.input.name == "stone", "stone waits in the fluid chest's input: " .. serpent.line(ci.input))
			expect(remote.call(NET, "chest_take_input", c, inv), "the waiting stone back through the window")
			expect(inv.get_item_count("stone") == 3 and c.get_item_count("stone") == 0, "the stone is out")
			--- without power: nothing goes in, its terminal says why
			local sub = find("substation", 3, 0)
			if sub then sub.destroy() end
			local p = s.find_entity("me-chest-power", a.position)
			if p then p.energy = 0 end
			expect(remote.call(TERM, "problem", a) == "chest-no-power", "no power: " .. tostring(remote.call(TERM, "problem", a)))
			a.insert{ name = "iron-plate", count = 5 }
			st.step, st.at = 3, game.tick
		elseif st.step == 3 and game.tick >= st.at + 3 then
			expect(a.get_item_count("iron-plate") == 5 and remote.call(NET, "chest_count", a, "iron-plate") == 6,
				"without power the iron waits: " .. a.get_item_count("iron-plate"))
			--- in a network: the cell is storage at the chest's priority
			expect(remote.call(NET, "insert_cell", b, cell_stack(inv, 1, "me-1k-storage-cell"), 1) == 1, "a cell into chest B")
			expect(remote.call(NET, "same_network", b, ctrl), "chest B is in the controller's network")
			remote.call(NET, "set_priority", b, 5)
			expect(remote.call(NET, "insert", ctrl, "stone", 7) == 7 and remote.call(NET, "chest_count", b, "stone") == 7,
				"priority 5: the network's stone into chest B: " .. remote.call(NET, "chest_count", b, "stone"))
			remote.call(NET, "set_priority", drive, 10)
			remote.call(NET, "insert", ctrl, "coal", 9)
			expect(remote.call(NET, "chest_count", b, "coal") == 0, "the drive of priority 10 first")
			expect(remote.call(NET, "count", ctrl, "stone") == 7, "the network counts the chest's stone")
			--- its terminal sees its cell only and stores there
			local keys = {}
			for _, e in pairs(remote.call(TERM, "entries", b, "", "name", "all", true)) do keys[#keys + 1] = e.key end
			expect(#keys == 1 and keys[1] == "stone", "chest B's grid: its cell only: " .. table.concat(keys, ","))
			inv[2].set_stack{ name = "wood", count = 4 }
			expect(remote.call(TERM, "store_stack", b, inv[2]) == 4 and remote.call(NET, "chest_count", b, "wood") == 4,
				"stored through chest B's terminal into its cell")
			expect(remote.call(NET, "count", ctrl, "wood") == 4, "the network sees it")
			expect(remote.call(NET, "check_holder_lists"), "the holder lists are right after the chest's own stores and takes")
			remote.call(NET, "slow_step")
			local info = remote.call(NET, "chest", b)
			local pb = s.find_entity("me-chest-power", b.position)
			expect(info.network and info.powered and pb and pb.power_usage == 0, "in a working network the network pays: "
				.. serpent.line(info) .. " " .. tostring(pb and pb.power_usage))
			--- mined: the cell comes along, the hidden parts go
			local buffer = game.create_inventory(8)
			local pos = b.position
			remote.call(NET, "removed", b, buffer)
			b.destroy()
			expect(buffer.get_item_count("me-1k-storage-cell") == 1, "the cell into the buffer")
			expect(s.find_entity("me-chest-power", pos) == nil and s.find_entity("me-chest-fluid", pos) == nil, "the hidden parts are gone")
			expect(remote.call(NET, "count", ctrl, "stone") == 0, "its stone left the network with the cell")
			buffer.destroy()
			st.done = true
			me_report("CHEST", "ME Chest (issue #229)", problems,
				"on its own, its cell only, container and pipe input, refused input back, no power, priority in a network, the network pays, mined")
		end
		inv.destroy()
	end

	function T.running(check) check(storage.chest229 and storage.chest229.done, "ME Chest") end

	return T
end
