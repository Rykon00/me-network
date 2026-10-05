--- Runtime test of me-network issue #84 (docs/ME-REWORK.md "Damaged items on the by-count paths"): an item that is damaged
--- (a mined wall, a chest: the stack's `health` below 1) is refused by `N.storable`, but the paths that move items by count
--- never looked at the stack: a count and a removal by count take a damaged stack for a whole one, so a damaged item came
--- out of the network as a new one.
--- * The storage bus: a chest with a damaged stack of 5 wooden chests and a whole stack of 3. Taking 8 out of the network
---   hands out the 3 whole ones; the damaged stack stays in the chest, and once the network found that, the bus shows 0 (not
---   the 5 it cannot hand out).
--- * The interface row surplus: an interface whose row wants 2 iron chests holds a damaged stack of 5: nothing of it goes into
---   the network, the stack stays.
--- Loaded by control.lua: require("damaged")(H) returns { setup, tick, running } like margin.lua.

local NET, IO = "gregtorio-me-network", "gregtorio-me-io"
local BX, BY = 500, -200
local START, CHECK1, CHECK2, CHECK3 = 100, 300, 700, 1100
local WOOD, IRON = "wooden-chest", "iron-chest"

return function(H)
	local me_place, me_report = H.me_place, H.me_report
	local T = {}
	local SOUTH = { direction = defines.direction.south }

	function T.setup(s)
		local fails = {}
		local what = "damaged"
		local eei = me_place(s, fails, what, "electric-energy-interface", BX + 12.5, BY + 6.5)
		if eei then
			eei.power_production = 1e6
			eei.electric_buffer_size = 1e7
		end
		me_place(s, fails, what, "substation", BX + 13, BY + 2)
		local ctrl = me_place(s, fails, what, "me-network-controller", BX + 6, BY)
		local drive = me_drive(s, fails, what, BX + 8.5, BY - 2.5, {}, "256k")
		local sbus = me_place(s, fails, what, "me-storage-bus", BX + 7.5, BY + 0.5, SOUTH)
		local schest = me_place(s, fails, what, "steel-chest", BX + 7.5, BY + 1.5)
		local iface = me_place(s, fails, what, "me-network-interface", BX + 4.5, BY - 2.5)
		me_connect(fails, what, { ctrl, drive, sbus, iface })
		storage.damaged84_scene = { ctrl = ctrl, sbus = sbus, schest = schest, iface = iface }
		return fails
	end

	--- the stacks of `name` in an inventory: { count, health } each
	local function stacks(inv, name)
		local out = {}
		for i = 1, #inv do
			local st = inv[i]
			if st.valid_for_read and st.name == name then out[#out + 1] = { count = st.count, health = st.health } end
		end
		return out
	end
	local function damaged_count(inv, name)
		local n = 0
		for _, st in ipairs(stacks(inv, name)) do if st.health < 1 then n = n + st.count end end
		return n
	end
	local function whole_count(inv, name)
		local n = 0
		for _, st in ipairs(stacks(inv, name)) do if st.health >= 1 then n = n + st.count end end
		return n
	end

	function T.tick()
		local tick = game.tick
		local sc = storage.damaged84_scene
		local st = storage.damaged84
		if not st then
			if tick < START or not sc then return end
			st = { problems = {}, done = false }
			storage.damaged84 = st
			local chest = sc.schest.get_inventory(defines.inventory.chest)
			chest[1].set_stack{ name = WOOD, count = 5, health = 0.5 }
			chest[2].set_stack{ name = WOOD, count = 3 }
			local ichest = sc.iface.get_inventory(defines.inventory.chest)
			ichest[1].set_stack{ name = IRON, count = 5, health = 0.5 }
			ichest[2].set_stack{ name = IRON, count = 3 }
			remote.call(IO, "set_interface_slot", sc.iface, 1, IRON, "normal", 2)
		end
		if st.done or tick < CHECK1 then return end
		local problems = st.problems
		local function expect(ok, text) if not ok then problems[#problems + 1] = text end end
		for _, e in pairs(sc) do
			if not e.valid then
				problems[#problems + 1] = "the test network was not built"
				st.done = true
				return me_report("DAMAGED", "damaged items on the by-count paths", problems, "no network")
			end
		end
		local function count(name) return remote.call(NET, "count", sc.ctrl, name) end
		local chest = sc.schest.get_inventory(defines.inventory.chest)
		local ichest = sc.iface.get_inventory(defines.inventory.chest)
		if not st.taken then
			st.taken = true
			--- the interface row's surplus: the damaged stack is no surplus the network can take
			expect(count(IRON) == 3, "the network has " .. count(IRON) .. " iron chests, not the 3 whole ones of the interface's surplus (a damaged stack went in as whole ones)")
			expect(damaged_count(ichest, IRON) == 5, "the interface's damaged stack of iron chests is " .. damaged_count(ichest, IRON) .. ", not 5 (it was taken as a whole one)")
			expect(whole_count(ichest, IRON) == 0, "the interface still holds " .. whole_count(ichest, IRON) .. " whole iron chests: the surplus was not taken")
			--- the storage bus: what the network can hand out of the chest
			local out = game.create_inventory(20)
			local moved = remote.call(NET, "extract_to", sc.ctrl, out, WOOD, count(WOOD))
			local got_whole, got_damaged = whole_count(out, WOOD), damaged_count(out, WOOD)
			expect(got_damaged == 0, got_damaged .. " damaged wooden chests came out of the network")
			expect(moved == 3 and got_whole == 3, "the network handed out " .. moved .. " wooden chests (" .. got_whole .. " whole, " .. out.get_item_count(WOOD)
				.. " in all), not the 3 whole ones")
			expect(damaged_count(chest, WOOD) == 5, "the damaged stack in the chest behind the storage bus is " .. damaged_count(chest, WOOD) .. ", not 5 (it came out as whole ones)")
			out.destroy()
			return
		end
		if tick < CHECK2 then return end
		if not st.looked then
			--- the bus has looked again: it shows what it can hand out
			st.looked = true
			expect(count(WOOD) == 0, "the storage bus shows " .. count(WOOD) .. " wooden chests, the 5 damaged ones it cannot hand out")
			expect(count(IRON) == 3, "the network has " .. count(IRON) .. " iron chests after the interface's later visits, not 3")
			--- the damaged stack is taken out of the chest and whole ones put in: the bus shows them again, and hands them out
			chest.clear()
			chest[1].set_stack{ name = WOOD, count = 4 }
			return
		end
		if tick < CHECK3 then return end
		expect(count(WOOD) == 4, "the storage bus shows " .. count(WOOD) .. " wooden chests after the damaged stack was replaced by 4 whole ones")
		local out = game.create_inventory(8)
		local moved = remote.call(NET, "extract_to", sc.ctrl, out, WOOD, 4)
		expect(moved == 4 and whole_count(out, WOOD) == 4, "the 4 whole wooden chests came out as " .. moved .. " (" .. whole_count(out, WOOD) .. " whole)")
		out.destroy()
		st.done = true
		me_report("DAMAGED", "damaged items on the by-count paths", problems, "a damaged stack stays in the chest behind a storage bus and is not shown once found, "
			.. "a damaged stack in an interface is no surplus (its whole ones are), the bus shows whole stacks again once the damaged one is gone")
	end

	function T.running(check) check(storage.damaged84 and storage.damaged84.done, "damaged items on the by-count paths") end
	return T
end
