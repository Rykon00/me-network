--- Runtime test of me-network issue #506: the ME Logistic Storage Bus (a logistic network as an external cell). Three
--- roboports in a row (R1 - R2 - R3: R1 and R3 meet only through R2), storage chests, a passive and an active provider, a
--- buffer and a requester chest in R1's area, a storage chest in R3's area; an ME network with a drive and three logistic
--- buses: L1 and L2 in R1's area (one logistic network: L2 is refused), L3 outside every area. Checked: what the terminal
--- counts (storage chests only, every quality, nothing that spoils, no ammo, never the requester), extraction and insertion
--- through the network (the drives first at the default priority -100, the logistic network first at priority 10), the
--- modes "providers" (active, passive and buffer chests too) and "read", a whitelist and a blacklist, the settings by paste,
--- clone and blueprint tag, the network split by a removed roboport (a stale count corrected at the next extraction, the
--- other half gone at the next visit), the second bus taking over when the first is removed, a bus outside every area that
--- gets a network when a roboport is built and loses it at its next scheduled visit when the roboport is removed, and a
--- change by hand seen at a scheduled visit. The save at tick 500 and its schedule digest cover the bus's queue (control.lua).
--- Loaded by control.lua: require("lsbus")(H) returns { setup, tick, running }.

local NET, SB, IO = "gregtorio-me-network", "gregtorio-me-storagebus", "gregtorio-me-io"
local BX, BY = -330, 330          -- (inside the cleared test area, TEST_RADIUS of control.lua; the roboports' areas clear of the other tests)
local PHASE1, PHASE2 = 150, 410   -- (the second phase after the storage bus idle limit of 120 ticks, before the save at 500)
local NAME = "me-logistic-storage-bus"
local R4_AT = { BX + 14, BY - 55 }   -- (a roboport built by the test: its area holds L3, apart from R1's)

return function(H)
	local me_place, me_report, power = H.me_place, H.me_report, H.power
	local T = {}

	function T.setup(s)
		local fails = {}
		local what = "logistic storage bus"
		power(s, fails, what, BX - 6, BY - 6)
		local ctrl = me_place(s, fails, what, "me-network-controller", BX + 1, BY - 6)
		local drive = H.me_drive(s, fails, what, BX + 2.5, BY - 6.5, {}, "16k")
		local term = me_place(s, fails, what, "me-terminal", BX + 3.5, BY - 6.5)
		H.cable_row(s, fails, BX + 4, BX + 14, BY - 7)
		for y = BY - 39, BY - 8 do me_place(s, fails, what, "me-cable", BX + 14.5, y + 0.5) end
		local l1 = me_place(s, fails, what, NAME, BX + 12.5, BY - 5.5)
		local l2 = me_place(s, fails, what, NAME, BX + 13.5, BY - 5.5)
		local l3 = me_place(s, fails, what, NAME, BX + 14.5, BY - 39.5)
		H.me_connect(fails, what, { ctrl, drive, term, l1, l2, l3 })
		for i = 0, 2 do me_place(s, fails, what, "roboport", BX + 45 * i, BY) end
		local function chest(name, x, y, items)
			local c = me_place(s, fails, what, name, BX + x, BY + y)
			for _, it in pairs(c and items or {}) do c.insert(it) end
			return c
		end
		local s1 = {}
		s1[#s1 + 1] = { name = "iron-plate", count = 100 }
		if prototypes.quality.rare then s1[#s1 + 1] = { name = "iron-plate", count = 10, quality = "rare" } end
		if prototypes.item.yumako then s1[#s1 + 1] = { name = "yumako", count = 10 } end   -- (Space Age: it spoils)
		s1[#s1 + 1] = { name = "firearm-magazine", count = 10 }
		chest("storage-chest", 3.5, 3.5, s1)
		chest("storage-chest", 4.5, 3.5)
		chest("passive-provider-chest", 5.5, 3.5, { { name = "copper-plate", count = 50 }, { name = "iron-plate", count = 15 } })
		chest("active-provider-chest", 6.5, 3.5, { { name = "stone", count = 20 } })
		chest("buffer-chest", 7.5, 3.5, { { name = "coal", count = 30 } })
		chest("requester-chest", 8.5, 3.5, { { name = "sulfur", count = 40 } })
		chest("storage-chest", 95.5, 0.5, { { name = "wood", count = 40 } })                 -- (R3's area only)
		chest("storage-chest", 16.5, -41.5, { { name = "plastic-bar", count = 12 } })        -- (R4's area, once it is built)
		return fails
	end

	local function finish(st, problems)
		st.done = true
		me_report("LSBUS", "ME logistic storage bus (issue #506)", problems, "counts, quality, extraction, insertion, modes, "
			.. "filters, settings copies, a second bus, a split network, a bus outside every area, scheduled visits")
	end

	function T.tick()
		local st = storage.lsbus506
		if game.tick < PHASE1 or (st and st.done) then return end
		local s = game.surfaces[1]
		local function find(name, x, y) return s.find_entity(name, { BX + x, BY + y }) end
		local t = find("me-terminal", 3.5, -6.5)
		local l1, l2, l3 = find(NAME, 12.5, -5.5), find(NAME, 13.5, -5.5), find(NAME, 14.5, -39.5)
		local s1, s2 = find("storage-chest", 3.5, 3.5), find("storage-chest", 4.5, 3.5)
		local p1, a1, b1 = find("passive-provider-chest", 5.5, 3.5), find("active-provider-chest", 6.5, 3.5), find("buffer-chest", 7.5, 3.5)
		local function info(e) return remote.call(SB, "info", e) or {} end
		local function set(e, settings) return remote.call(SB, "set_settings", e, settings) end
		local function count(name, q) return remote.call(NET, "count", t, name, q) end
		local function ins(name, n, q) return remote.call(NET, "insert", t, name, n, q) end
		local function ext(name, n, q) return remote.call(NET, "extract", t, name, n, q) end
		local function lnet(e) return s.find_logistic_network_by_position(e.position, "player") end
		local function stored(name, q)                                   -- (what the storage chests of R1's network hold)
			local n = lnet(s1)
			return n and n.get_item_count({ name = name, quality = q or "normal" }, "storage") or -1
		end

		if not st then                                                   -- phase 1
			st = { problems = {} }
			storage.lsbus506 = st
			local problems = st.problems
			local function expect(ok, text) if not ok then problems[#problems + 1] = text end end
			if not (t and l1 and l2 and l3 and s1 and s2 and p1 and a1 and b1) then
				expect(false, "entities missing")
				return finish(st, problems)
			end
			local rare = prototypes.quality.rare ~= nil

			--- the buses: L1 has R1's network, L2 is refused, L3 stands in none
			local i1, i2, i3 = info(l1), info(l2), info(l3)
			expect(i1.status == "ok" and i1.logistic and i1.side == "logistic" and i1.network ~= nil, "L1: " .. serpent.line(i1.status) .. " " .. tostring(i1.network))
			expect(i1.priority == -100 and i1.mode == "readwrite", "L1 defaults: priority " .. tostring(i1.priority) .. ", mode " .. tostring(i1.mode))
			expect(i2.status == "shared-target" and i2.items == 0, "L2: " .. tostring(i2.status) .. ", " .. tostring(i2.items) .. " items")
			expect(i3.status == "no-target" and lnet(l3) == nil, "L3: " .. tostring(i3.status))
			expect(lnet(s1) ~= nil and lnet(s1).network_id == i1.network, "R1's network is L1's")

			--- counts: the storage chests only, every quality, nothing that spoils, no ammo, no requester
			expect(count("iron-plate") == 100, "iron counted " .. count("iron-plate"))
			if rare then expect(count("iron-plate", "rare") == 10, "rare iron counted " .. count("iron-plate", "rare")) end
			expect(count("wood") == 40, "wood of R3's area (through R2) counted " .. count("wood"))
			for _, name in ipairs({ "copper-plate", "stone", "coal", "sulfur", "firearm-magazine" }) do
				expect(count(name) == 0, name .. " counted " .. count(name) .. " in the mode storage")
			end
			if prototypes.item.yumako then expect(count("yumako") == 0, "a spoiling item counted " .. count("yumako")) end

			--- extraction through the network: out of the storage chests
			expect(ext("iron-plate", 30) == 30 and s1.get_item_count("iron-plate") == 70 and count("iron-plate") == 70,
				"extract 30 iron: chest " .. s1.get_item_count("iron-plate") .. ", count " .. count("iron-plate"))
			if rare then
				expect(ext("iron-plate", 4, "rare") == 4 and s1.get_item_count{ name = "iron-plate", quality = "rare" } == 6,
					"extract 4 rare iron: chest " .. s1.get_item_count{ name = "iron-plate", quality = "rare" })
			end

			--- insertion: the drive first at the default priority -100, the logistic network first at priority 10
			expect(ins("stone-brick", 10) == 10 and stored("stone-brick") == 0 and count("stone-brick") == 10,
				"priority -100: stone bricks in the storage chests " .. stored("stone-brick"))
			set(l1, { priority = 10 })
			expect(ins("iron-gear-wheel", 25) == 25 and stored("iron-gear-wheel") == 25 and count("iron-gear-wheel") == 25,
				"priority 10: gears in the storage chests " .. stored("iron-gear-wheel"))
			if rare then
				expect(ins("iron-gear-wheel", 5, "rare") == 5 and stored("iron-gear-wheel", "rare") == 5, "priority 10: rare gears "
					.. stored("iron-gear-wheel", "rare"))
			end

			--- the mode "providers": active, passive and buffer chests too, taken after the storage chests
			set(l1, { mode = "providers" })
			expect(count("copper-plate") == 50 and count("stone") == 20 and count("coal") == 30 and count("iron-plate") == 85
				and count("sulfur") == 0, "providers: copper " .. count("copper-plate") .. ", stone " .. count("stone") .. ", coal "
				.. count("coal") .. ", iron " .. count("iron-plate") .. ", sulfur " .. count("sulfur"))
			expect(ext("iron-plate", 80) == 80 and s1.get_item_count("iron-plate") == 0 and p1.get_item_count("iron-plate") == 5,
				"providers: 80 iron taken, storage chest " .. s1.get_item_count("iron-plate") .. ", passive " .. p1.get_item_count("iron-plate"))
			expect(ext("stone", 5) == 5 and a1.get_item_count("stone") == 15, "providers: stone from the active provider " .. a1.get_item_count("stone"))
			expect(ext("coal", 5) == 5 and b1.get_item_count("coal") == 25, "providers: coal from the buffer chest " .. b1.get_item_count("coal"))
			expect(ins("iron-gear-wheel", 3) == 3 and stored("iron-gear-wheel") == 28, "providers: inserts go to the storage chests "
				.. stored("iron-gear-wheel"))

			--- read only: shown and taken from, never stored into
			set(l1, { mode = "read" })
			expect(count("copper-plate") == 0 and count("iron-gear-wheel") == 28, "read: copper " .. count("copper-plate") .. ", gears " .. count("iron-gear-wheel"))
			expect(ins("iron-gear-wheel", 10) == 10 and stored("iron-gear-wheel") == 28 and count("iron-gear-wheel") == 38,
				"read: gears in the storage chests " .. stored("iron-gear-wheel"))
			expect(ext("iron-gear-wheel", 2) == 2, "read: taking works")       -- (out of the drive: priority 0 is taken before 10)
			set(l1, { mode = "readwrite" })
			local gears = count("iron-gear-wheel")

			--- a whitelist and a blacklist
			set(l1, { filters = { "iron-gear-wheel" } })
			expect(count("wood") == 0 and count("iron-gear-wheel") == gears, "whitelist: wood " .. count("wood") .. ", gears " .. count("iron-gear-wheel"))
			set(l1, { blacklist = true })
			expect(count("wood") == 40 and count("iron-gear-wheel") == gears - stored("iron-gear-wheel"), "blacklist: wood "
				.. count("wood") .. ", gears " .. count("iron-gear-wheel"))
			set(l1, { filters = {}, blacklist = false })

			--- the settings by paste, a clone and a blueprint tag; the mode "providers" belongs to the logistic bus
			set(l1, { mode = "providers", priority = 7, filters = { "coal" } })
			local g1 = remote.call(SB, "get_settings", l1)
			expect(g1.mode == "providers" and g1.priority == 7 and #g1.filters == 1, "L1's settings: " .. serpent.line(g1))
			remote.call(SB, "paste", l1, l2)
			local p2 = info(l2)
			expect(p2.mode == "providers" and p2.priority == 7 and #p2.filters == 1, "paste: " .. serpent.line({ p2.mode, p2.priority }))
			set(l2, { mode = "readwrite", priority = -100, filters = {} })
			remote.call(SB, "built", l2, nil, l1)
			expect(info(l2).mode == "providers" and info(l2).priority == 7, "clone: " .. tostring(info(l2).mode))
			set(l2, { mode = "read", priority = 0 })
			remote.call(SB, "built", l2, { fork_me_storage_bus = g1 })
			expect(info(l2).mode == "providers" and info(l2).priority == 7, "blueprint tag: " .. tostring(info(l2).mode))
			set(l2, { mode = "write" })
			expect(info(l2).mode == "providers", "write only is no mode of the logistic bus: " .. tostring(info(l2).mode))
			for _, l in ipairs({ l1, l2 }) do set(l, { mode = "readwrite", priority = -100, filters = {} }) end
			expect(info(l2).status == "shared-target" and info(l2).items == 0, "L2 still refused: " .. tostring(info(l2).status))
			expect(count("wood") == 40, "wood counted once: " .. count("wood"))

			--- a split: R2 removed (no event); the stale count is corrected at the next extraction, the visit drops R3's half
			local r2 = find("roboport", 45, 0)
			local id = info(l1).network
			if r2 then r2.destroy() end
			expect(ext("wood", 5) == 0 and count("wood") == 0, "after the split: wood taken, counted " .. count("wood"))
			remote.call(SB, "visit", l1)
			local after = info(l1)
			expect(after.status == "ok" and after.network == lnet(l1).network_id, "after the split: " .. tostring(after.status) .. ", network "
				.. tostring(after.network) .. " (was " .. tostring(id) .. ")")
			expect(count("wood") == 0 and count("iron-gear-wheel") == gears, "after the visit: wood " .. count("wood") .. ", gears " .. count("iron-gear-wheel"))

			--- the second bus takes over when the first is removed
			l1.destroy{ raise_destroy = true }
			remote.call(SB, "visit", l2)
			expect(info(l2).status == "ok" and info(l2).items > 0 and count("iron-gear-wheel") == gears, "L2 took over: "
				.. tostring(info(l2).status) .. ", gears " .. count("iron-gear-wheel"))

			--- a bus outside every area gets a network when a roboport is built there, and keeps no claim of another
			expect(count("plastic-bar") == 0, "plastic outside every area counted " .. count("plastic-bar"))
			local r4 = s.create_entity{ name = "roboport", position = R4_AT, force = "player" }
			remote.call(SB, "visit", l3)
			expect(info(l3).status == "ok" and count("plastic-bar") == 12 and info(l3).network ~= info(l2).network,
				"L3 in R4's network: " .. tostring(info(l3).status) .. ", plastic " .. count("plastic-bar"))
			if r4 then r4.destroy() end                                   -- (the last roboport of its area: seen at its next visit)

			--- a change by hand: seen at a scheduled visit
			s2.insert{ name = "iron-stick", count = 7 }
			local bl = remote.call(IO, "backlogs")
			expect(bl.logistic_storage_bus_units == 2, "logistic buses in the queue: " .. tostring(bl.logistic_storage_bus_units))
			local ok, why = remote.call(SB, "lists_ok")
			expect(ok, "visit lists: " .. tostring(why))
			return
		end

		if game.tick < PHASE2 then return end                            -- phase 2: the scheduled visits
		local problems = st.problems
		local function expect(ok, text) if not ok then problems[#problems + 1] = text end end
		expect(l2 and l3, "L2 or L3 missing")
		if l2 and l3 then
			expect(count("iron-stick") == 7, "a change by hand seen at a scheduled visit: " .. count("iron-stick"))
			expect(info(l3).status == "no-target" and count("plastic-bar") == 0, "R4 removed: L3 " .. tostring(info(l3).status)
				.. ", plastic " .. count("plastic-bar"))
			local sch = remote.call(SB, "schedule", l2)
			expect(sch and sch.due and sch.interval and sch.side == "logistic", "L2's schedule: " .. serpent.line(sch))
		end
		finish(st, problems)
	end

	function T.running(check) check(storage.lsbus506 and storage.lsbus506.done, "ME logistic storage bus (issue #506)") end

	return T
end
