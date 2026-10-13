--- Runtime test of me-network issue #354, part 1: the Void ME Storage Cell and the Void ME Fluid Storage Cell. A drive with a
--- 16k cell (slot 1), a void cell partitioned for stone (slot 2) and a fluid void cell partitioned for water (slot 3):
---   * 50 stone go in (all taken) and are gone: the network holds none, the 16k cell got none (the partitioned void cell comes
---     first, as AE2's partitioned cells do);
---   * 30 iron plates go into the 16k cell;
---   * 1000 water go in and are gone;
---   * a second network with only an unpartitioned void cell destroys whatever reaches it (20 copper plates), and its drive
---     shows the void cell as a cell with room;
---   * issue #376: the drive slot tooltips of both void cells (no cards) carry the void cell warning, and so does the item
---     tooltip of the partitioned one once it is taken out of the drive.
--- Part 2, the Group Filter Card:
---   * a 16k cell with the card, the text "iron-*|copper-plate" and a partition for stone (which the card replaces): iron
---     plates, iron ore and copper plates go in, stone and copper ore do not; the drive shows the card, the text and the kept
---     partition;
---   * a storage bus with the card on a chest: the text "<iron ore's subgroup>&!stone" takes iron ore, not stone (a negated
---     term) and an item of another subgroup only by the blacklist mode, which in turn refuses the iron ore; the item's group
---     as the text takes a wooden chest; an empty text takes everything; the settings carry the text.
--- Loaded by control.lua: require("voidcell")(H) returns { setup, tick, running }.

local NET = "gregtorio-me-network"
local SB = "gregtorio-me-storagebus"
local GUI = "gregtorio-me-gui"
local VOIDCELL = "fork-me-gui.cell-mode-voidcell"

--- issue #376: whether a localised string holds `key` anywhere
local function has_key(ls, key)
	if type(ls) ~= "table" then return ls == key end
	for _, v in ipairs(ls) do if has_key(v, key) then return true end end
	return false
end
local BX, BY = 40, -380                 -- (inside the cleared test area, TEST_RADIUS of control.lua)
local START = 190

return function(H)
	local me_place, me_report, power = H.me_place, H.me_report, H.power
	local T = {}

	local function cell(drive, name, slot)
		local inv = game.create_inventory(1)
		inv[1].set_stack{ name = name, count = 1 }
		local ok = remote.call(NET, "insert_cell", drive, inv[1], slot)
		inv.destroy()
		return ok
	end

	function T.setup(s)
		local fails = {}
		local what = "void cells"
		power(s, fails, what, BX, BY)
		local ctrl = me_place(s, fails, what, "me-network-controller", BX + 7, BY)
		local drive = me_place(s, fails, what, "me-drive", BX + 8.5, BY - 0.5)
		H.me_connect(fails, what, { ctrl, drive })
		power(s, fails, what, BX, BY + 12)
		local ctrl2 = me_place(s, fails, what, "me-network-controller", BX + 7, BY + 12)
		local drive2 = me_place(s, fails, what, "me-drive", BX + 8.5, BY + 11.5)
		H.me_connect(fails, what, { ctrl2, drive2 })
		power(s, fails, what, BX, BY - 14)
		local ctrl3 = me_place(s, fails, what, "me-network-controller", BX + 7, BY - 14)
		local drive3 = me_place(s, fails, what, "me-drive", BX + 8.5, BY - 14.5)
		H.me_connect(fails, what, { ctrl3, drive3 })
		power(s, fails, what, BX, BY - 26)
		local ctrl4 = me_place(s, fails, what, "me-network-controller", BX + 7, BY - 26)
		local bus = me_place(s, fails, what, "me-storage-bus", BX + 12.5, BY - 25.5, { direction = defines.direction.south })
		me_place(s, fails, what, "iron-chest", BX + 12.5, BY - 24.5)
		H.me_connect(fails, what, { ctrl4, bus })
		return fails
	end

	local function report()
		local s = storage.voidcell354
		s.done = true
		me_report("VOIDCELL", "Void ME Storage Cells", s.problems,
			"partitioned void cell first, items and fluid destroyed, the other cell untouched, an unpartitioned one voids all;"
		.. " group filter on a cell and a storage bus: names, subgroup, group, negation, blacklist, empty text")
	end

	--- part 2: the Group Filter Card on a cell and on a storage bus
	local function group_filter(find, expect)
		local ctrl3, drive3 = find("me-network-controller", 7, -14), find("me-drive", 8.5, -14.5)
		local ctrl4, bus = find("me-network-controller", 7, -26), find("me-storage-bus", 12.5, -25.5)
		if not (ctrl3 and drive3 and ctrl4 and bus) then return expect(false, "group filter entities missing") end
		local inv = game.create_inventory(2)
		inv[1].set_stack{ name = "me-16k-storage-cell", count = 1, tags = { fork_me_cell = { items = {},
			partition = { stone = true }, cards = { "me-group-filter-card" }, gtext = "iron-*|copper-plate" } } }
		expect(remote.call(NET, "insert_cell", drive3, inv[1], 1), "the carded cell goes into the drive")
		local function ins(ctrl, name) return remote.call(NET, "insert", ctrl, name, 5) end
		expect(ins(ctrl3, "stone") == 0 and ins(ctrl3, "copper-ore") == 0, "the cell refuses stone and copper ore")
		expect(ins(ctrl3, "iron-plate") == 5 and ins(ctrl3, "iron-ore") == 5 and ins(ctrl3, "copper-plate") == 5,
			"the cell takes iron plates, iron ore and copper plates")
		local c = (remote.call(NET, "drive", drive3) or {})[1] or {}
		expect(c.gfilter == true and c.gtext == "iron-*|copper-plate" and c.partition and c.partition[1] == "stone",
			"the drive shows the card, the text and the kept partition: " .. serpent.line({ c.gfilter, c.gtext, c.partition }))
		--- the storage bus
		inv[1].set_stack{ name = "me-group-filter-card", count = 1 }
		expect(remote.call(SB, "card_click", bus, 1, inv[1], inv, false) == nil and not inv[1].valid_for_read, "the card goes into the bus")
		local sub = prototypes.item["iron-ore"].subgroup.name
		remote.call(SB, "set_settings", bus, { gtext = sub .. "&!stone" })
		remote.call(SB, "visit", bus)
		local other = prototypes.item["iron-gear-wheel"].subgroup.name ~= sub and "iron-gear-wheel" or "wooden-chest"
		expect(ins(ctrl4, "iron-ore") == 5 and ins(ctrl4, "stone") == 0 and ins(ctrl4, other) == 0,
			"the bus takes iron ore, not stone nor " .. other .. " (" .. sub .. ")")
		remote.call(SB, "set_settings", bus, { blacklist = true })
		expect(ins(ctrl4, other) == 5 and ins(ctrl4, "iron-ore") == 0, "the blacklist takes " .. other .. ", not iron ore")
		remote.call(SB, "set_settings", bus, { blacklist = false, gtext = prototypes.item["wooden-chest"].group.name })
		expect(ins(ctrl4, "wooden-chest") == 5 and ins(ctrl4, "iron-ore") == 0, "the group as the text takes a wooden chest only")
		local st = remote.call(SB, "get_settings", bus) or {}
		expect(st.gtext == prototypes.item["wooden-chest"].group.name, "the settings carry the text: " .. serpent.line(st.gtext))
		remote.call(SB, "set_settings", bus, { gtext = "" })
		expect(ins(ctrl4, "stone") == 5, "an empty text takes everything")
		inv.destroy()
	end

	function T.tick()
		local s = storage.voidcell354
		if game.tick < START or (s and s.done) then return end
		s = { problems = {} }
		storage.voidcell354 = s
		local surface = game.surfaces[1]
		local function find(name, x, y) return surface.find_entity(name, { BX + x, BY + y }) end
		local function expect(ok, text) if not ok then s.problems[#s.problems + 1] = text end end
		local ctrl, drive = find("me-network-controller", 7, 0), find("me-drive", 8.5, -0.5)
		local ctrl2, drive2 = find("me-network-controller", 7, 12), find("me-drive", 8.5, 11.5)
		if not (ctrl and drive and ctrl2 and drive2) then expect(false, "entities missing") return report() end
		expect(cell(drive, "me-16k-storage-cell", 1) and cell(drive, "me-void-storage-cell", 2)
			and cell(drive, "me-void-fluid-storage-cell", 3), "the cells go into the drive")
		remote.call(NET, "set_partition", drive, 2, { "stone" })
		remote.call(NET, "set_partition", drive, 3, { "fluid/water" })
		local n = remote.call(NET, "insert", ctrl, "stone", 50)
		expect(n == 50, "50 stone taken: " .. tostring(n))
		expect(remote.call(NET, "count", ctrl, "stone") == 0, "the stone is gone: " .. tostring(remote.call(NET, "count", ctrl, "stone")))
		n = remote.call(NET, "insert", ctrl, "iron-plate", 30)
		expect(n == 30 and remote.call(NET, "count", ctrl, "iron-plate") == 30, "30 iron plates stored: " .. tostring(n))
		n = remote.call(NET, "insert_fluid", ctrl, "water", 1000)
		expect(n and n >= 999 and remote.call(NET, "fluid_count", ctrl, "water") < 1, "the water is gone: "
			.. serpent.line({ n, remote.call(NET, "fluid_count", ctrl, "water") }))
		local info = remote.call(NET, "drive", drive)
		expect(info and info[1] and (info[1].types or 0) == 1, "the 16k cell holds one type: "
			.. serpent.line(info and info[1]))
		--- an unpartitioned void cell alone
		expect(cell(drive2, "me-void-storage-cell", 1), "the void cell goes into the second drive")
		n = remote.call(NET, "insert", ctrl2, "copper-plate", 20)
		expect(n == 20 and remote.call(NET, "count", ctrl2, "copper-plate") == 0, "an unpartitioned void cell voids all: " .. tostring(n))
		local info2 = remote.call(NET, "drive", drive2)
		expect(info2 and info2[1] and info2[1].state == "room", "the void cell has room: "
			.. serpent.line(info2 and info2[1]))
		--- issue #376: the void cell warning without a card, in the drive slot tooltip and in the item tooltip
		local tip1, tip2 = remote.call(GUI, "drive_cell_tooltip", drive, 2), remote.call(GUI, "drive_cell_tooltip", drive2, 1)
		expect(has_key(tip1, VOIDCELL) and has_key(tip2, VOIDCELL), "the drive tooltips of the void cells warn: "
			.. serpent.line({ tip1, tip2 }))
		local out = game.create_inventory(1)
		local took = remote.call(NET, "take_cell", drive, 2, out[1])
		local desc = took and out[1].valid_for_read and out[1].custom_description
		expect(has_key(desc, VOIDCELL), "the item tooltip of the partitioned void cell warns: " .. serpent.line(desc))
		out.destroy()
		group_filter(find, expect)
		return report()
	end

	function T.running(check) check(storage.voidcell354 and storage.voidcell354.done, "Void ME Storage Cells") end

	return T
end
