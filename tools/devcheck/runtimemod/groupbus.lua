--- Runtime test of me-network issue #363: the Group Filter Card on the ME Import Bus and ME Export Bus. A network with iron and
--- copper plates, gears and stone; an export bus on chest A and an import bus on chest B, each with the card:
---   * the export bus with the text "*-plate" puts plates into A and no gears or stone, a key that comes into the network later
---     ("steel-plate") too; with no text it exports nothing;
---   * the import bus with the text "stone|iron-ore" takes the stone and the iron ore from B and leaves the wood; with no text
---     it takes everything;
---   * the text goes with a blueprint tag and a settings paste.
--- Loaded by control.lua: require("groupbus")(H) returns { setup, tick, running }.

local NET, IO = "gregtorio-me-network", "gregtorio-me-io"
local BX, BY = -150, -70              -- (inside the cleared test area, TEST_RADIUS of control.lua; clear of the other tests)
local START = 140
local CARD = "me-group-filter-card"

return function(H)
	local me_place, me_report, power = H.me_place, H.me_report, H.power
	local T = {}
	local SOUTH = { direction = defines.direction.south }

	function T.setup(s)
		local fails = {}
		local what = "group filter buses"
		power(s, fails, what, BX, BY)
		local ctrl = me_place(s, fails, what, "me-network-controller", BX + 7, BY)
		local drive = H.me_drive(s, fails, what, BX + 8.5, BY - 0.5, { ["iron-plate"] = 200, ["copper-plate"] = 200,
			["iron-gear-wheel"] = 50, stone = 50, [CARD] = 4 })
		local members = { ctrl, drive }
		for _, x in pairs({ 10.5, 12.5, 14.5 }) do
			local name = x == 12.5 and "me-import-bus" or "me-export-bus"
			members[#members + 1] = me_place(s, fails, what, name, BX + x, BY + 0.5, SOUTH)
			me_place(s, fails, what, "iron-chest", BX + x, BY + 1.5)
		end
		for x = 9.5, 14.5 do me_place(s, fails, what, "me-cable", BX + x, BY - 0.5) end
		H.me_connect(fails, what, members)
		return fails
	end

	function T.tick()
		local st = storage.groupbus363
		if (st and st.done) or game.tick < START then return end
		st = { problems = {}, done = true }
		storage.groupbus363 = st
		local problems = st.problems
		local function expect(ok, msg) if not ok then problems[#problems + 1] = msg end end
		local s = game.surfaces[1]
		local function find(name, x, y) return s.find_entity(name, { BX + x, BY + y }) end
		local function report()
			me_report("GROUPBUS", "Group Filter Card on the import and export bus", problems, "export by a text, a new key too, no "
				.. "text exports nothing; import by a text, no text imports everything; blueprint tag and paste")
		end
		local ctrl, E, I, E2 = find("me-network-controller", 7, 0), find("me-export-bus", 10.5, 0.5), find("me-import-bus", 12.5, 0.5),
			find("me-export-bus", 14.5, 0.5)
		local A, B = find("iron-chest", 10.5, 1.5), find("iron-chest", 12.5, 1.5)
		if not (ctrl and E and I and E2 and A and B) then expect(false, "entities missing") return report() end
		local inv = game.create_inventory(2)
		local function put(bus)
			inv[1].set_stack{ name = CARD, count = 1 }
			local why = remote.call(IO, "bus_card_click", bus, 1, inv[1], inv, false)
			return why == nil and not inv[1].valid_for_read
		end
		local a, b = A.get_inventory(defines.inventory.chest), B.get_inventory(defines.inventory.chest)
		local function step(bus, n) for _ = 1, n or 1 do remote.call(IO, "step", bus) end end
		--- the export bus
		expect(put(E), "the card goes into the export bus")
		remote.call(IO, "set_bus_gtext", E, "*-plate")
		step(E, 4)
		expect(a.get_item_count("iron-plate") > 0 and a.get_item_count("copper-plate") > 0, "the export bus put plates into A: "
			.. a.get_item_count("iron-plate") .. ", " .. a.get_item_count("copper-plate"))
		expect(a.get_item_count("iron-gear-wheel") == 0 and a.get_item_count("stone") == 0, "the export bus put gears or stone into A")
		remote.call(NET, "insert", ctrl, "steel-plate", 20)
		step(E, 6)
		expect(a.get_item_count("steel-plate") > 0, "a plate new in the network is exported too: " .. a.get_item_count("steel-plate"))
		a.clear()
		remote.call(IO, "set_bus_gtext", E, "")
		step(E, 2)
		expect(a.is_empty(), "with no text the export bus exports nothing")
		--- the import bus
		b.insert{ name = "stone", count = 30 }
		b.insert{ name = "iron-ore", count = 30 }
		b.insert{ name = "wood", count = 30 }
		expect(put(I), "the card goes into the import bus")
		remote.call(IO, "set_bus_gtext", I, "stone|iron-ore")
		step(I, 4)
		expect(b.get_item_count("stone") == 0 and b.get_item_count("iron-ore") == 0 and b.get_item_count("wood") == 30,
			"the import bus took " .. 30 - b.get_item_count("stone") .. " stone, " .. 30 - b.get_item_count("iron-ore")
			.. " iron ore, " .. 30 - b.get_item_count("wood") .. " wood (the text stone|iron-ore)")
		remote.call(IO, "set_bus_gtext", I, "")
		step(I, 4)
		expect(b.get_item_count("wood") == 0, "with no text the import bus takes everything: wood left " .. b.get_item_count("wood"))
		--- copying
		remote.call(IO, "set_bus_gtext", E, "*-plate")
		remote.call(IO, "paste", E, E2)
		expect((remote.call(IO, "get_bus", E2) or {}).gtext == "*-plate", "a settings paste carries the text: "
			.. serpent.line((remote.call(IO, "get_bus", E2) or {}).gtext))
		remote.call(IO, "built", E2, { fork_me_bus = { filters = {}, gtext = "copper-*" } })
		expect((remote.call(IO, "get_bus", E2) or {}).gtext == "copper-*", "a blueprint tag carries the text")
		inv.destroy()
		return report()
	end

	function T.running(check) check(storage.groupbus363 and storage.groupbus363.done, "Group Filter Card on the import and export bus") end

	return T
end
