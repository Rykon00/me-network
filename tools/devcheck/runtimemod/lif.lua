--- Runtime test of me-network issue #531: the ME Logistic Interface (scripts/fork-me-logistic-interface.lua), on a surface of
--- its own ("me-lif-test", concrete) with five logistic networks far apart (a roboport each, logistic and construction robots,
--- power), so the robots of one never serve another:
--- * A: an ME network (iron plates, stone walls) and interface L1 (its window built into a stand-in). Offer: a row of 100 iron plates serves a vanilla requester
---   (20), a row of stone walls a construction ghost. Request: "keep 50 copper plates" while the network has none fills from a
---   storage chest and an active provider and stops at 50. The loop guard: L1's own request row of iron plates and a second
---   interface L2 (another ME network, the same logistic network) asking for iron plates are not applied. Settings by paste,
---   blueprint tag and clone (a clone has exactly three hidden chests); the hidden chests' flags.
--- * B: accept: an active provider's stone lands in the interface's storage chest and goes into the network; "Accept trash" off:
---   coal stays out; a filter of coal (accept on): the coal comes. Mined: the chests' contents go into the network, the chests
---   go; destroyed: spilled where it stood.
--- * C, D, E: the engine facts the design relies on (Factorio 2.1.23, measured by the maintainer's research mod), without an
---   ME network: C hidden chests (two on one tile) are served by robots both ways; D robots carry an item between a hidden
---   requester and a hidden passive provider on the same tile (the reason for the loop guard); E a requester takes from an
---   active provider first, then a storage chest, then a passive provider (the nearest).
--- * F: with an ME Logistic Storage Bus on the same logistic network (priority 10, the network stores there first): what the
---   interface pulls in goes into the drive, never into the bus's storage chest; the bus does not count the interface's
---   provider; what the network stores goes into the vanilla storage chest, not the interface's.
--- * G, H, I (issue #532): an ME network with iron sticks and no iron plates, a CPU, a provider with a molecular assembler and
---   the gear pattern, a level maintainer that keeps 10 gears (its start lacks 10 iron plates), a vanilla storage chest with
---   30 iron plates. G: the interface asks for what the start lacks ("Request what crafting lacks", on by default), the
---   plates arrive and the maintainer's job makes the gears; a second interface there does not ask (only the first of a
---   logistic network). H: a second interface offers iron plates: they are left out, nothing arrives. I: the switch off:
---   nothing arrives (both interfaces).
--- The save at tick 500 and the schedule digest (control.lua) cover the interfaces' queue. Loaded by control.lua like lab.lua.

local NET, LIF, SB = "gregtorio-me-network", "gregtorio-me-logistic-interface", "gregtorio-me-storagebus"
local SURFACE = "me-lif-test"
local NAME = "me-logistic-interface"
local PROV, REQ, STOR = NAME .. "-provider", NAME .. "-requester", NAME .. "-storage"
local X = { A = 0, B = 200, C = 400, D = 600, E = 800, F = 1000, G = 1200, H = 1400, I = 1600 }
local GEAR, GEAR_RECIPE = "iron-gear-wheel", "iron-gear-crafting-table"   -- (1 iron plate and 2 sticks: the stand-in or Gregtorio's)
local T1, T2, T3, T4 = 60, 450, 800, 1150   -- (the checks; the save at 500 lies between T2 and T3)

local function surface()
	local s = game.surfaces[SURFACE]
	if s then return s end
	s = game.create_surface(SURFACE, { width = 3600, height = 160, default_enable_all_autoplace_controls = false,
		autoplace_settings = { entity = { treat_missing_as_default = false, settings = {} },
			decorative = { treat_missing_as_default = false, settings = {} } } })
	s.always_day = true
	local tiles = {}
	for _, x0 in pairs(X) do
		s.request_to_generate_chunks({ x0, 0 }, 3)
		for x = x0 - 32, x0 + 31 do for y = -32, 31 do tiles[#tiles + 1] = { name = "refined-concrete", position = { x, y } } end end
	end
	s.force_generate_chunk_requests()
	s.set_tiles(tiles)
	return s
end

local function set_request(e, i, name, count)
	local p = e.get_logistic_point(defines.logistic_member_index.logistic_container)
	local sec = p.get_section(1) or p.add_section()
	sec.set_slot(i, { value = { name = name, quality = "normal", comparator = "=" }, min = count })
end

return function(H)
	local me_place, me_report, power = H.me_place, H.me_report, H.power
	local T = {}

	--- a logistic network at x0: a roboport with robots, power; `robots` logistic and 10 construction robots
	local function cluster(s, fails, what, x0, robots)
		power(s, fails, what, x0 - 7, 0)
		local port = me_place(s, fails, what, "roboport", x0, 0)
		if port then
			port.insert{ name = "logistic-robot", count = robots or 30 }
			port.insert{ name = "construction-robot", count = 10 }
		end
		return port
	end

	--- an ME network at x0: controller, drive with `items`, and `members` connected to it
	local function me_net(s, fails, what, x0, items, members)
		local ctrl = me_place(s, fails, what, "me-network-controller", x0 + 5, -6)
		local drive = H.me_drive(s, fails, what, x0 + 6.5, -6.5, items)
		local list = { ctrl, drive }
		for _, m in ipairs(members) do list[#list + 1] = m end
		H.me_connect(fails, what, list)
		return drive
	end

	local function place(s, fails, what, name, x, y, items)
		local c = me_place(s, fails, what, name, x, y)
		for _, it in pairs(c and items or {}) do c.insert(it) end
		return c
	end

	--- issue #532: a crafting cluster at x0 (see the header); returns its interfaces L, L2
	local function crafting(s, fails, what, x0, second_offers)
		cluster(s, fails, what, x0)
		power(s, fails, what, x0 + 14, -12)
		place(s, fails, what, "storage-chest", x0 - 4.5, 4.5, { { name = "iron-plate", count = 30 } })
		local l = me_place(s, fails, what, NAME, x0 + 4.5, 3.5)
		local l2 = me_place(s, fails, what, NAME, x0 + 6.5, 3.5)
		local cpu = me_place(s, fails, what, "me-16k-crafting-storage", x0 + 8.5, -6.5)
		local p = me_place(s, fails, what, "me-pattern-provider", x0 + 10.5, -6.5)
		local m = me_place(s, fails, what, "me-molecular-assembler", x0 + 10.5, -7.5)
		if m then
			m.force.recipes[GEAR_RECIPE].enabled = true
			m.get_module_inventory().insert{ name = "me-acceleration-card", count = 5 }
		end
		local maint = me_place(s, fails, what, "me-level-maintainer", x0 + 12.5, -6.5)
		me_net(s, fails, what, x0, { ["iron-stick"] = 100 }, { l, l2, cpu, p, maint })
		if p then give_patterns(p, { { kind = "crafting", recipe = GEAR_RECIPE } }, fails) end
		if maint then remote.call("gregtorio-me-circuit", "set_maintainer", maint, GEAR, 10, false, 1, 0) end
		if second_offers and l2 then remote.call(LIF, "set_row", l2, "offer", 1, "iron-plate", 10) end
		for _, x in ipairs({ l, l2 }) do remote.call(LIF, "set_accept", x, false) end
		return l, l2
	end

	function T.setup()
		local fails = {}
		local what = "logistic interface"
		local s = surface()
		--- A
		local a = X.A
		cluster(s, fails, what, a)
		local qa = place(s, fails, what, "requester-chest", a - 4.5, 4.5)
		if qa then set_request(qa, 1, "iron-plate", 20) end
		place(s, fails, what, "storage-chest", a + 3.5, 5.5, { { name = "copper-plate", count = 30 } })
		place(s, fails, what, "active-provider-chest", a - 3.5, -4.5, { { name = "copper-plate", count = 30 } })
		local l1 = me_place(s, fails, what, NAME, a + 4.5, 3.5)
		local l2 = me_place(s, fails, what, NAME, a - 5.5, -2.5)
		local l3 = me_place(s, fails, what, NAME, a + 8.5, 3.5)        -- (the paste and blueprint target)
		me_net(s, fails, what, a, { ["iron-plate"] = 500, ["stone-wall"] = 20 }, { l1, l3 })
		local c2 = me_place(s, fails, what, "me-network-controller", a - 10, 6)             -- (L2's own ME network)
		if c2 and l2 then H.me_connect(fails, what, { c2, l2 }) end
		--- B
		local b = X.B
		cluster(s, fails, what, b)
		place(s, fails, what, "active-provider-chest", b - 3.5, 4.5, { { name = "stone", count = 10 } })
		local lb = me_place(s, fails, what, NAME, b + 4.5, 3.5)
		local lc = me_place(s, fails, what, NAME, b + 6.5, 3.5)
		me_net(s, fails, what, b, {}, { lb, lc })
		--- C: hidden chests served both ways, two on one tile
		local c = X.C
		cluster(s, fails, what, c)
		local hp = place(s, fails, what, PROV, c + 3.5, 3.5, { { name = "iron-plate", count = 20 } })
		local hr = place(s, fails, what, REQ, c + 3.5, 3.5)
		if hr then set_request(hr, 1, "copper-plate", 10) end
		local vr = place(s, fails, what, "requester-chest", c - 4.5, 4.5)
		if vr then set_request(vr, 1, "iron-plate", 20) end
		place(s, fails, what, "storage-chest", c - 3.5, -4.5, { { name = "copper-plate", count = 10 } })
		if not (hp and hr) then fails[#fails + 1] = what .. ": hidden chests on one tile not placed" end
		--- D: the same-tile shuttle
		local d = X.D
		cluster(s, fails, what, d)
		place(s, fails, what, PROV, d + 3.5, 3.5, { { name = "electronic-circuit", count = 32 } })
		local hr2 = place(s, fails, what, REQ, d + 3.5, 3.5)
		if hr2 then set_request(hr2, 1, "electronic-circuit", 32) end
		--- E: the source order (the passive provider nearest)
		local e = X.E
		cluster(s, fails, what, e)
		local vr3 = place(s, fails, what, "requester-chest", e + 4.5, 4.5)
		if vr3 then set_request(vr3, 1, "iron-plate", 10) end
		place(s, fails, what, "passive-provider-chest", e + 5.5, 4.5, { { name = "iron-plate", count = 10 } })
		place(s, fails, what, "storage-chest", e - 4.5, -4.5, { { name = "iron-plate", count = 10 } })
		place(s, fails, what, "active-provider-chest", e - 5.5, -4.5, { { name = "iron-plate", count = 10 } })
		--- F: with an ME Logistic Storage Bus
		local f = X.F
		cluster(s, fails, what, f)
		place(s, fails, what, "passive-provider-chest", f - 3.5, 4.5, { { name = "coal", count = 20 } })
		place(s, fails, what, "storage-chest", f - 4.5, -4.5)
		local lf = me_place(s, fails, what, NAME, f + 4.5, 3.5)
		local bus = me_place(s, fails, what, "me-logistic-storage-bus", f + 3.5, -2.5)
		me_net(s, fails, what, f, { ["iron-plate"] = 100 }, { lf, bus })
		if bus then remote.call(SB, "set_settings", bus, { priority = 10 }) end
		--- G, H, I: what failed crafting starts lack (issue #532)
		crafting(s, fails, what, X.G, false)
		crafting(s, fails, what, X.H, true)
		local li, li2 = crafting(s, fails, what, X.I, false)
		for _, x in ipairs({ li, li2 }) do remote.call(LIF, "set_auto", x, false) end
		--- the rows
		local function row(l, tab, i, key, amount)
			if not (l and remote.call(LIF, "set_row", l, tab, i, key, amount)) then
				fails[#fails + 1] = what .. ": row " .. tab .. " " .. i .. " " .. key .. " refused"
			end
		end
		row(l1, "offer", 1, "iron-plate", 100)
		row(l1, "offer", 2, "stone-wall", 10)
		row(l1, "request", 1, "copper-plate", 50)
		row(lf, "offer", 1, "iron-plate", 50)
		row(lf, "request", 1, "coal", 20)
		--- (an active provider's items go to storage chests, the hidden ones too: only B's LB and F's LF accept trash)
		for _, l in ipairs({ l1, l2, l3, lc }) do remote.call(LIF, "set_accept", l, false) end
		return fails
	end

	local function finish(st, problems)
		st.done = true
		me_report("LIF", "ME logistic interface (issue #531)", problems, "offer to a requester and a ghost, request to the target, "
			.. "accept, the switch and the filter, the loop guard, settings copies, mined and destroyed, the engine facts, "
			.. "the logistic storage bus, what failed crafting starts lack (issue #532)")
	end

	function T.tick()
		local tick = game.tick
		if tick ~= T1 and tick ~= T2 and tick ~= T3 and tick ~= T4 then return end
		local st = storage.lif531
		if not st then
			st = { problems = {} }
			storage.lif531 = st
		end
		if st.done then return end
		local problems = st.problems
		local function expect(ok, text) if not ok then problems[#problems + 1] = text end end
		local s = game.surfaces[SURFACE]
		if not s then
			expect(false, "no test surface")
			return finish(st, problems)
		end
		local function find(name, x, y) return s.find_entity(name, { x, y }) end
		local function n(e, name, index)
			if not (e and e.valid) then return -1 end
			local inv = e.get_inventory(index or defines.inventory.chest)
			return inv and inv.get_item_count(name) or -1
		end
		local function count(e, name) return remote.call(NET, "count", e, name) end
		local function info(l) return remote.call(LIF, "info", l) or {} end
		local function chests(l) return remote.call(LIF, "chests", l) or {} end
		local a, b, c, d, e, f = X.A, X.B, X.C, X.D, X.E, X.F
		local l1, l2, l3 = find(NAME, a + 4.5, 3.5), find(NAME, a - 5.5, -2.5), find(NAME, a + 8.5, 3.5)
		local lb, lc, lf = find(NAME, b + 4.5, 3.5), find(NAME, b + 6.5, 3.5), find(NAME, f + 4.5, 3.5)

		if tick == T1 then
			if not (l1 and l2 and l3 and lb and lc and lf) then
				expect(false, "interfaces missing")
				return finish(st, problems)
			end
			--- the hidden chests: on the block's tile, not selectable, indestructible; the same logistic network as the block
			local ch = chests(l1)
			for _, k in ipairs({ "provider", "requester", "store" }) do
				local x = ch[k]
				expect(x and x.valid and x.position.x == l1.position.x and x.position.y == l1.position.y and not x.destructible,
					"L1's " .. k .. " chest: " .. tostring(x and x.valid and x.name))
			end
			expect(ch.provider and ch.provider.prototype.selectable_in_game == false, "the provider is selectable")
			expect(#s.find_entities_filtered{ position = l1.position, name = { PROV, REQ, STOR } } == 3, "L1's tile holds "
				.. #s.find_entities_filtered{ position = l1.position, name = { PROV, REQ, STOR } } .. " hidden chests")
			--- refused rows: a fluid, a spoiling item (Space Age), an item with tags, a key twice in a tab
			expect(not remote.call(LIF, "set_row", l3, "offer", 1, "fluid/water", 10), "a fluid row was taken")
			if prototypes.item.yumako then expect(not remote.call(LIF, "set_row", l3, "offer", 1, "yumako", 10), "a spoiling item was taken") end
			expect(not remote.call(LIF, "set_row", l1, "offer", 3, "iron-plate", 5), "a second row of iron plates was taken")
			--- the loop guard: L1 offers iron plates; its own request row of them and L2's are not applied
			remote.call(LIF, "set_row", l1, "request", 2, "iron-plate", 10)
			remote.call(LIF, "set_row", l2, "request", 1, "iron-plate", 10)
			remote.call(LIF, "visit", l1)
			remote.call(LIF, "visit", l2)
			local i1, i2 = info(l1), info(l2)
			expect(i1.lid and i1.lid == i2.lid, "L1 and L2 in one logistic network: " .. tostring(i1.lid) .. " / " .. tostring(i2.lid))
			expect(i1.collide and i1.collide[2] and not i1.collide[1], "L1's own iron request not marked: " .. serpent.line(i1.collide))
			expect(i2.collide and i2.collide[1] and i2.request[1] and i2.request[1].asked == 0, "L2's iron request applied: "
				.. serpent.line(i2.request and i2.request[1]))
			expect(i1.request[1] and i1.request[1].asked == 50, "L1 asks for copper: " .. serpent.line(i1.request[1]))
			expect(i1.offer[1] and i1.offer[1].key == "iron-plate" and i1.ncollide == 1, "L1's offer and collisions: " .. serpent.line(i1.offer[1])
				.. " " .. tostring(i1.ncollide))
			--- the window (built into a stand-in: the harness has no player): nine request rows, the second red, "-" asked
			local v = remote.call("gregtorio-me-gui", "lif_view", l1)
			expect(v and v.ok and #v.rows == 9 and v.rows[2].red and not v.rows[1].red and v.asked[2] == "-" and v.accept == false,
				"L1's window: " .. serpent.line(v and { v.ok, #v.rows, v.rows[1], v.rows[2], v.asked[2], v.accept }))
			remote.call(LIF, "set_row", l1, "request", 2, nil)
			--- a construction ghost of a stone wall: the robots fetch it from L1's provider
			s.create_entity{ name = "entity-ghost", inner_name = "stone-wall", position = { a + 1.5, 6.5 }, force = "player" }
			--- settings by paste, blueprint tag and clone
			remote.call(LIF, "set_filter", l1, "coal")
			local g = remote.call(LIF, "get_settings", l1)
			remote.call(LIF, "paste", l1, l3)
			local g3 = remote.call(LIF, "get_settings", l3)
			expect(g3 and #g3.offer == 2 and #g3.request == 1 and g3.accept == false and g3.filter == "coal", "paste: " .. serpent.line(g3))
			expect(chests(l3).store.storage_filter and chests(l3).store.storage_filter.name.name == NAME .. "-nothing",
				"accept off: the storage chest's filter " .. serpent.line(chests(l3).store.storage_filter))
			remote.call(LIF, "paste", l2, l3)                                  -- (back to L2's settings: one request row)
			remote.call(LIF, "built", l3, { fork_me_logistic_interface = g })
			g3 = remote.call(LIF, "get_settings", l3)
			expect(g3 and #g3.offer == 2 and g3.offer[1].amount == 100 and g3.accept == false, "blueprint tag: " .. serpent.line(g3))
			remote.call(LIF, "paste", l2, l3)
			remote.call(LIF, "set_filter", l1, nil)
			expect(chests(lb).store.storage_filter == nil, "accept on: B's storage chest has a filter " .. serpent.line(chests(lb).store.storage_filter))
			local clone = l1.clone{ position = { a + 4.5, 23.5 }, surface = s, create_build_effect_smoke = false }
			local gc = clone and remote.call(LIF, "get_settings", clone)
			expect(gc and #gc.offer == 2 and #gc.request == 1, "clone's settings: " .. serpent.line(gc))
			expect(clone and #s.find_entities_filtered{ position = clone.position, name = { PROV, REQ, STOR } } == 3, "a clone's tile holds "
				.. (clone and #s.find_entities_filtered{ position = clone.position, name = { PROV, REQ, STOR } } or "nothing"))
			if clone then clone.destroy{ raise_destroy = true } end
			expect(#s.find_entities_filtered{ position = { a + 4.5, 23.5 }, name = { PROV, REQ, STOR } } == 0, "a destroyed clone left its chests")
			--- B: accept is on by default
			expect(info(lb).accept == true, "B: accept off by default")
			return
		end

		if tick == T2 then
			--- A: offer served a requester and a ghost; request filled to its target
			local qa = find("requester-chest", a - 4.5, 4.5)
			expect(n(qa, "iron-plate") == 20, "A: the requester got " .. n(qa, "iron-plate") .. " iron plates from L1")
			expect(find("stone-wall", a + 1.5, 6.5) ~= nil, "A: the wall ghost was not built from L1's provider")
			local ch = chests(l1)
			expect(n(ch.provider, "iron-plate") == 100 and count(l1, "iron-plate") == 380, "A: L1's provider "
				.. n(ch.provider, "iron-plate") .. ", the network " .. count(l1, "iron-plate") .. " iron plates")
			local src = n(find("storage-chest", a + 3.5, 5.5), "copper-plate") + n(find("active-provider-chest", a - 3.5, -4.5), "copper-plate")
			expect(count(l1, "copper-plate") == 50 and src == 10, "A: copper in the network " .. count(l1, "copper-plate")
				.. ", left in the sources " .. src)
			local i1 = info(l1)
			expect(i1.request[1] and i1.request[1].asked == 0, "A: L1 still asks " .. serpent.line(i1.request[1]))
			--- B: the stone arrived; accept off, then coal
			expect(count(lb, "stone") == 10, "B: stone in the network " .. count(lb, "stone"))
			remote.call(LIF, "set_accept", lb, false)
			find("active-provider-chest", b - 3.5, 4.5).insert{ name = "coal", count = 10 }
			--- C, D, E: the engine facts
			local hp, vr = find(PROV, c + 3.5, 3.5), find("requester-chest", c - 4.5, 4.5)
			local hr = find(REQ, c + 3.5, 3.5)
			expect(n(vr, "iron-plate") == 20 and n(hp, "iron-plate") == 0, "C: a requester served from a hidden provider: "
				.. n(vr, "iron-plate") .. " (engine)")
			expect(n(hr, "copper-plate") == 10, "C: a hidden requester on the same tile served: " .. n(hr, "copper-plate") .. " (engine)")
			local hr2 = find(REQ, d + 3.5, 3.5)
			expect(n(hr2, "electronic-circuit") > 0, "D: robots no longer carry between a hidden requester and provider on one "
				.. "tile (engine; the loop guard may be loosened): " .. n(hr2, "electronic-circuit"))
			local vr3 = find("requester-chest", e + 4.5, 4.5)
			local ap, sc, pp = find("active-provider-chest", e - 5.5, -4.5), find("storage-chest", e - 4.5, -4.5),
				find("passive-provider-chest", e + 5.5, 4.5)
			expect(n(vr3, "iron-plate") == 10 and n(ap, "iron-plate") == 0 and n(sc, "iron-plate") == 10 and n(pp, "iron-plate") == 10,
				"E: the first source is not the active provider: active " .. n(ap, "iron-plate") .. ", storage " .. n(sc, "iron-plate")
				.. ", passive " .. n(pp, "iron-plate") .. " (engine)")
			if vr3 then set_request(vr3, 1, "iron-plate", 20) end
			--- G: the first interface asks for what the maintainer's start lacked, the second does not
			local g, g2 = find(NAME, X.G + 4.5, 3.5), find(NAME, X.G + 6.5, 3.5)
			local ig, ig2 = info(g), info(g2)
			expect(ig.auto and ig.auto_asks and not ig2.auto_asks, "G: who asks: " .. tostring(ig.auto_asks) .. " / " .. tostring(ig2.auto_asks))
			--- F: pulled in into the drive, not into the bus's storage chest
			local sd = find("storage-chest", f - 4.5, -4.5)
			expect(count(lf, "coal") == 20 and n(sd, "coal") == 0, "F: coal in the network " .. count(lf, "coal") .. ", in the bus's "
				.. "storage chest " .. n(sd, "coal"))
			return
		end

		if tick == T3 then
			--- B: nothing came while accept was off; a filter of coal (accept on) lets it come
						expect(count(lb, "coal") == 0 and n(chests(lb).store, "coal") == 0, "B: coal came while accept was off: network "
				.. count(lb, "coal"))
			remote.call(LIF, "set_accept", lb, true)
			remote.call(LIF, "set_filter", lb, "coal")
			--- E: the second source is the storage chest
			local sc, pp = find("storage-chest", e - 4.5, -4.5), find("passive-provider-chest", e + 5.5, 4.5)
			expect(n(sc, "iron-plate") == 0 and n(pp, "iron-plate") == 10, "E: the second source is not the storage chest: storage "
				.. n(sc, "iron-plate") .. ", passive " .. n(pp, "iron-plate") .. " (engine)")
			--- F: the bus does not count L's provider; the network stores into the vanilla storage chest
			local bus = find("me-logistic-storage-bus", f + 3.5, -2.5)
			remote.call(SB, "set_settings", bus, { mode = "providers" })
			remote.call(SB, "visit", bus)
			expect(count(lf, "iron-plate") == 50 and n(chests(lf).provider, "iron-plate") == 50, "F: iron counted " .. count(lf, "iron-plate")
				.. " with 50 in L's provider")
			remote.call(NET, "insert", lf, "stone", 30)
			expect(n(find("storage-chest", f - 4.5, -4.5), "stone") == 30 and n(chests(lf).store, "stone") == 0,
				"F: stone stored into the interface's storage chest " .. n(chests(lf).store, "stone"))
			return
		end

		--- T4
		expect(count(lb, "coal") == 10, "B: the filter of coal let " .. count(lb, "coal") .. " coal in")
		--- mined: the contents into the network, the chests gone
		local ch = chests(lb)
		ch.provider.insert{ name = "iron-gear-wheel", count = 5 }
		ch.requester.insert{ name = "iron-gear-wheel", count = 6 }
		ch.store.insert{ name = "iron-gear-wheel", count = 7 }
		local buffer = game.create_inventory(10)
		local pos = lb.position
		remote.call(LIF, "removed", lb, buffer)
		lb.destroy()
		local lb2 = find(NAME, b + 6.5, 3.5)
		expect(count(lb2, "iron-gear-wheel") == 18 and buffer.get_item_count("iron-gear-wheel") == 0, "B: mined, gears in the network "
			.. count(lb2, "iron-gear-wheel") .. ", in the buffer " .. buffer.get_item_count("iron-gear-wheel"))
		expect(#s.find_entities_filtered{ position = pos, name = { PROV, REQ, STOR } } == 0, "B: a mined interface left its chests")
		buffer.destroy()
		--- destroyed: spilled
		chests(lc).store.insert{ name = "iron-stick", count = 9 }
		local cpos = lc.position
		lc.destroy{ raise_destroy = true }
		local spilled = 0
		for _, it in pairs(s.find_entities_filtered{ type = "item-entity", position = cpos, radius = 3 }) do
			if it.stack.name == "iron-stick" then spilled = spilled + it.stack.count end
		end
		expect(spilled == 9 and #s.find_entities_filtered{ position = cpos, name = { PROV, REQ, STOR } } == 0, "B: destroyed, spilled "
			.. spilled .. " sticks")
		--- E: the passive provider last
		local pp = find("passive-provider-chest", e + 5.5, 4.5)
		expect(n(pp, "iron-plate") == 10, "E: the passive provider was taken from while others had some: " .. n(pp, "iron-plate"))
		--- G, H, I (issue #532)
		local function plates(x0) return n(find("storage-chest", x0 - 4.5, 4.5), "iron-plate") end
		local g, h, h2, i3 = find(NAME, X.G + 4.5, 3.5), find(NAME, X.H + 4.5, 3.5), find(NAME, X.H + 6.5, 3.5), find(NAME, X.I + 4.5, 3.5)
		expect(count(g, GEAR) == 10 and plates(X.G) == 20, "G: gears " .. count(g, GEAR) .. ", plates left in the storage chest "
			.. plates(X.G) .. " (the maintainer's job got its plates from the robots)")
		local ih = info(h)
		expect(count(h, GEAR) == 0 and plates(X.H) == 30 and ih.auto_asks and ih.auto_skipped == 1 and #ih.auto_list == 0,
			"H: an offered key was asked for: gears " .. count(h, GEAR) .. ", plates " .. plates(X.H) .. ", skipped "
			.. tostring(ih.auto_skipped) .. ", asked " .. #(ih.auto_list or {}))
		expect(info(h2).offer[1] ~= nil, "H: the offer row is gone")
		local ii = info(i3)
		expect(count(i3, GEAR) == 0 and plates(X.I) == 30 and not ii.auto and #ii.auto_list == 0, "I: the switch off, yet gears "
			.. count(i3, GEAR) .. ", plates " .. plates(X.I))
		local vi = remote.call("gregtorio-me-gui", "lif_view", i3)
		expect(vi and vi.ok and vi.auto == false and vi.auto_list == 0, "I's window: " .. serpent.line(vi and { vi.ok, vi.auto, vi.auto_list }))
		local gs = remote.call(LIF, "get_settings", i3)
		expect(gs and gs.auto == false, "I's settings keep the switch: " .. serpent.line(gs and gs.auto))
		local sch = remote.call(LIF, "schedule", l1)
		expect(sch and sch.due and sch.interval, "L1's schedule: " .. serpent.line(sch))
		finish(st, problems)
	end

	function T.running(check) check(storage.lif531 and storage.lif531.done, "ME logistic interface (issue #531)") end

	return T
end
