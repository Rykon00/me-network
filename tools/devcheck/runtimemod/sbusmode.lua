--- Runtime test of me-network issue #155: the filter mode of the ME Storage Bus (whitelist or blacklist, a setting of the
--- bus; an Inverter Card makes the blacklist and cannot be switched back). On a chest: an allowed and a refused item
--- go in and stay out as the mode says, with and without the card; settings paste, a clone and a blueprint's tag keep the
--- mode; a bus that never saw the setting is a whitelist (an old save).
--- Loaded by control.lua: require("sbusmode")(H) returns { setup, tick, running }.

local NET, SB = "gregtorio-me-network", "gregtorio-me-storagebus"
local BX, BY = 10, -380
local START = 140
local SOUTH = { direction = defines.direction.south }
local BUSES = { 11.5, 13.5, 15.5, 17.5 }          -- B1 switched, B2 with the Inverter Card, B3 paste target, B4 whitelist source

return function(H)
	local me_place, me_report, power = H.me_place, H.me_report, H.power
	local T = {}

	function T.setup(s)
		local fails = {}
		local what = "storage bus filter mode"
		power(s, fails, what, BX, BY)
		local ctrl = me_place(s, fails, what, "me-network-controller", BX + 7, BY)
		local drive = H.me_drive(s, fails, what, BX + 8.5, BY - 0.5, {}, "16k")
		local term = me_place(s, fails, what, "me-terminal", BX + 10.5, BY - 0.5)
		H.cable_row(s, fails, BX + 11, BX + 20, BY - 1)
		for _, x in ipairs(BUSES) do
			me_place(s, fails, what, "me-storage-bus", BX + x, BY + 0.5, SOUTH)
			me_place(s, fails, what, "iron-chest", BX + x, BY + 1.5)
		end
		H.me_connect(fails, what, { ctrl, drive, term })
		return fails
	end

	function T.tick()
		local st = storage.sbusmode155
		if st or game.tick < START then return end
		st = { problems = {}, done = true }
		storage.sbusmode155 = st
		local problems = st.problems
		local function expect(ok, text) if not ok then problems[#problems + 1] = text end end
		local s = game.surfaces[1]
		local function find(name, x, y) return s.find_entity(name, { BX + x, BY + y }) end
		local t = find("me-terminal", 10.5, -0.5)
		local b, c = {}, {}
		for i, x in ipairs(BUSES) do b[i], c[i] = find("me-storage-bus", x, 0.5), find("iron-chest", x, 1.5) end
		if not (t and b[1] and b[2] and b[3] and b[4] and c[1] and c[2] and c[3] and c[4]) then
			return me_report("SBUSMODE", "ME storage bus filter mode", { "entities missing" })
		end
		local function info(e) return remote.call(SB, "info", e) or {} end
		local function set(e, settings) remote.call(SB, "set_settings", e, settings) end
		local function ins(name, n) return remote.call(NET, "insert", t, name, n) end

		--- an old bus (never switched) is a whitelist
		local g0 = remote.call(SB, "get_settings", b[1])
		expect(g0 and g0.blacklist == nil and info(b[1]).blacklist == false, "a fresh bus is a whitelist: " .. serpent.line(g0))

		--- whitelist: iron plates go into the chest, copper stays out
		set(b[1], { filters = { "iron-plate" }, priority = 10 })
		ins("iron-plate", 10)
		ins("copper-plate", 10)
		expect(c[1].get_item_count("iron-plate") == 10 and c[1].get_item_count("copper-plate") == 0,
			"whitelist: chest has " .. c[1].get_item_count("iron-plate") .. " iron, " .. c[1].get_item_count("copper-plate") .. " copper")

		--- blacklist (the switch): iron stays out, copper goes in
		set(b[1], { blacklist = true })
		local i1, g1 = info(b[1]), remote.call(SB, "get_settings", b[1])
		expect(i1.blacklist == true and not i1.inverted and g1.blacklist == true, "the switch is set: " .. serpent.line(i1.blacklist))
		ins("iron-plate", 10)
		ins("copper-plate", 10)
		expect(c[1].get_item_count("iron-plate") == 10 and c[1].get_item_count("copper-plate") == 10,
			"blacklist: chest has " .. c[1].get_item_count("iron-plate") .. " iron, " .. c[1].get_item_count("copper-plate") .. " copper")

		--- back to a whitelist
		set(b[1], { blacklist = false })
		expect(info(b[1]).blacklist == false and remote.call(SB, "get_settings", b[1]).blacklist == nil, "switched back")
		ins("copper-plate", 10)
		expect(c[1].get_item_count("copper-plate") == 10, "whitelist again: copper stays out")

		--- the Inverter Card makes the blacklist whatever the switch says
		local inv = game.create_inventory(2)
		inv[1].set_stack{ name = "me-inverter-card", count = 1 }
		set(b[2], { filters = { "iron-plate" }, priority = 10, blacklist = false })
		expect(remote.call(SB, "card_click", b[2], 1, inv[1], inv[2], false) == nil and info(b[2]).inverted, "the card went in")
		ins("iron-plate", 10)
		ins("stone", 10)
		expect(c[2].get_item_count("iron-plate") == 0 and c[2].get_item_count("stone") == 10,
			"Inverter Card with the switch off: chest has " .. c[2].get_item_count("iron-plate") .. " iron, " .. c[2].get_item_count("stone") .. " stone")
		inv.destroy()

		--- settings paste, a clone (built from its source) and the blueprint's tag keep the mode; a paste from a whitelist resets
		set(b[1], { blacklist = true, filters = { "iron-plate" } })
		remote.call(SB, "paste", b[1], b[3])
		expect(info(b[3]).blacklist == true and #info(b[3]).filters == 1, "paste: " .. serpent.line(info(b[3]).blacklist))
		set(b[4], { filters = { "stone" } })
		remote.call(SB, "paste", b[4], b[3])
		expect(info(b[3]).blacklist == false, "paste from a whitelist: " .. serpent.line(info(b[3]).blacklist))
		remote.call(SB, "built", b[3], nil, b[1])
		expect(info(b[3]).blacklist == true, "a clone: " .. serpent.line(info(b[3]).blacklist))
		set(b[3], { blacklist = false })
		remote.call(SB, "built", b[3], { fork_me_storage_bus = remote.call(SB, "get_settings", b[1]) })
		expect(info(b[3]).blacklist == true, "a blueprint tag: " .. serpent.line(info(b[3]).blacklist))
		local tagged = remote.call(SB, "get_settings", b[1])
		expect(tagged.blacklist == true, "the tag holds the mode")

		me_report("SBUSMODE", "ME storage bus filter mode", problems, "whitelist and blacklist on a chest, the switch, the Inverter Card, paste, clone and tag, a fresh bus a whitelist")
	end

	function T.running(check) check(storage.sbusmode155 and storage.sbusmode155.done, "ME storage bus filter mode") end

	return T
end
