--- Runtime test of me-network issue #537: the ME Logistic Interface's automatic mode (scripts/fork-me-logistic-interface.lua),
--- on a surface of its own ("me-lifauto-test", concrete) with four logistic networks far apart:
--- * J (logistic robots): three requesters want 10 gears each, a storage chest of the base holds 12, the ME network 100. The
---   automatic stock covers what the base lacks (18): the base's storage chest is emptied first, the requesters get 30, the
---   network keeps 82. A fourth requester wants copper cable, which ME lacks: not offered. A new block is in Automatic mode.
--- * L (no robots, so the stock stays): two automatic blocks of one ME network far apart; a requester beside the eastern one
---   wants 10 pipes. The first block (by unit number) leads, the stock lands at the eastern one (nearer to the demand). The
---   request is then cleared: the stock stays for a pass without demand (kept, z = 1), then goes back into the network.
--- * M: the network's needs first: a level maintainer keeps 10 gears, its start lacks iron plates (the network has 5 of the
---   10); a requester of the base wants 20 iron plates. They are not offered (counted as left to waiting ME blocks).
--- * N (logistic robots): an export bus waits for copper cable that only a storage chest of the base holds (30): the block
---   asks for it (one stack, at most what the base has), it arrives and the bus exports it.
--- * P (no robots): an ME Logistic Storage Bus on the same logistic network shows the base's storage chests (3 copper plates,
---   5 gears) to the ME network, whose drive has 10 copper plates and no gears; requesters want 20 of each. The stock comes
---   from the drive only (10 copper plates; no gears): what the bus shows is the base's own.
--- The save at tick 500 lies between the checks; the scan's state and the stock are in `storage`. Loaded by control.lua.

local NET, LIF, IO = "gregtorio-me-network", "gregtorio-me-logistic-interface", "gregtorio-me-io"
local SURFACE = "me-lifauto-test"
local NAME = "me-logistic-interface"
local X = { J = 0, L = 200, M = 400, N = 600, P = 800 }
local GEAR, GEAR_RECIPE = "iron-gear-wheel", "iron-gear-crafting-table"   -- (as lif.lua: the stand-in or Gregtorio's)
local T1, T2 = 420, 1150    -- (the checks; the save at 500 lies between them)

local function surface()
	local s = game.surfaces[SURFACE]
	if s then return s end
	s = game.create_surface(SURFACE, { width = 1800, height = 160, default_enable_all_autoplace_controls = false,
		autoplace_settings = { entity = { treat_missing_as_default = false, settings = {} },
			decorative = { treat_missing_as_default = false, settings = {} } } })
	s.always_day = true
	local tiles = {}
	for _, x0 in pairs(X) do
		s.request_to_generate_chunks({ x0, 0 }, 3)
		for x = x0 - 40, x0 + 39 do for y = -32, 31 do tiles[#tiles + 1] = { name = "refined-concrete", position = { x, y } } end end
	end
	s.force_generate_chunk_requests()
	s.set_tiles(tiles)
	return s
end

local function set_request(e, name, count)
	local p = e.get_logistic_point(defines.logistic_member_index.logistic_container)
	local sec = p.get_section(1) or p.add_section()
	if count > 0 then
		sec.set_slot(1, { value = { name = name, quality = "normal", comparator = "=" }, min = count })
	else
		sec.clear_slot(1)
	end
end

return function(H)
	local me_place, me_report, power = H.me_place, H.me_report, H.power
	local T = {}

	--- a logistic network at x0: a roboport, power; `robots` logistic robots (0: none, the stock stays where it is)
	local function cluster(s, fails, what, x0, robots)
		power(s, fails, what, x0 - 7, 0)
		local port = me_place(s, fails, what, "roboport", x0, 0)
		if port and robots > 0 then port.insert{ name = "logistic-robot", count = robots } end
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

	function T.setup()
		local fails = {}
		local what = "logistic interface automatic mode"
		local s = surface()
		--- J
		local j = X.J
		cluster(s, fails, what, j, 30)
		for k = 0, 2 do
			local r = place(s, fails, what, "requester-chest", j - 6.5 + 3 * k, 8.5)
			if r then set_request(r, GEAR, 10) end
		end
		local r4 = place(s, fails, what, "requester-chest", j + 3.5, 8.5)
		if r4 then set_request(r4, "copper-cable", 5) end
		place(s, fails, what, "storage-chest", j - 4.5, -4.5, { { name = GEAR, count = 12 } })
		local lj = me_place(s, fails, what, NAME, j + 4.5, 3.5)
		me_net(s, fails, what, j, { [GEAR] = 100 }, { lj })
		--- L: two blocks 30 tiles apart, the requester beside the eastern one
		local l = X.L
		cluster(s, fails, what, l, 0)
		local lw = me_place(s, fails, what, NAME, l - 14.5, 3.5)
		local le = me_place(s, fails, what, NAME, l + 15.5, 3.5)
		local rl = place(s, fails, what, "requester-chest", l + 15.5, 6.5)
		if rl then set_request(rl, "pipe", 10) end
		me_net(s, fails, what, l, { pipe = 50 }, { lw, le })
		--- M: a level maintainer whose start lacks iron plates (the crafting cluster of lif.lua)
		local m = X.M
		cluster(s, fails, what, m, 0)
		power(s, fails, what, m + 14, -12)
		local rm = place(s, fails, what, "requester-chest", m - 4.5, 6.5)
		if rm then set_request(rm, "iron-plate", 20) end
		local lm = me_place(s, fails, what, NAME, m + 4.5, 3.5)
		local cpu = me_place(s, fails, what, "me-16k-crafting-storage", m + 8.5, -6.5)
		local p = me_place(s, fails, what, "me-pattern-provider", m + 10.5, -6.5)
		local asm = me_place(s, fails, what, "me-molecular-assembler", m + 10.5, -7.5)
		if asm then
			asm.force.recipes[GEAR_RECIPE].enabled = true
			asm.get_module_inventory().insert{ name = "me-acceleration-card", count = 5 }
		end
		local maint = me_place(s, fails, what, "me-level-maintainer", m + 12.5, -6.5)
		me_net(s, fails, what, m, { ["iron-stick"] = 100, ["iron-plate"] = 5 }, { lm, cpu, p, maint })
		if p then give_patterns(p, { { kind = "crafting", recipe = GEAR_RECIPE } }, fails) end
		if maint then remote.call("gregtorio-me-circuit", "set_maintainer", maint, GEAR, 10, false, 1, 0) end
		--- N: an export bus that waits for copper cable, which a storage chest of the base holds
		local n = X.N
		cluster(s, fails, what, n, 30)
		place(s, fails, what, "storage-chest", n - 4.5, 6.5, { { name = "copper-cable", count = 30 } })
		local ln = me_place(s, fails, what, NAME, n + 4.5, 3.5)
		local xb = me_place(s, fails, what, "me-export-bus", n + 8.5, 3.5, { direction = defines.direction.south })
		place(s, fails, what, "iron-chest", n + 8.5, 4.5)
		me_net(s, fails, what, n, { ["iron-plate"] = 10 }, { ln, xb })
		if xb then remote.call(IO, "set_bus_filters", xb, { "copper-cable" }) end
		--- P: the base's chests through an ME Logistic Storage Bus
		local pp = X.P
		cluster(s, fails, what, pp, 0)
		place(s, fails, what, "storage-chest", pp - 4.5, 6.5, { { name = "copper-plate", count = 3 }, { name = GEAR, count = 5 } })
		for k, name in ipairs({ "copper-plate", GEAR }) do
			local r = place(s, fails, what, "requester-chest", pp - 8.5 + 2 * k, 9.5)
			if r then set_request(r, name, 20) end
		end
		local lp = me_place(s, fails, what, NAME, pp + 4.5, 3.5)
		local bus = me_place(s, fails, what, "me-logistic-storage-bus", pp + 6.5, 3.5)
		me_net(s, fails, what, pp, { ["copper-plate"] = 10 }, { lp, bus })
		for _, x in ipairs({ lj, lw, le, lm, ln, lp }) do remote.call(LIF, "set_accept", x, false) end
		storage.lifauto537 = { problems = {} }
		return fails
	end

	local function finish(st, problems)
		st.done = true
		me_report("LIFAUTO", "ME logistic interface automatic mode (issue #537)", problems, "offers what the base lacks after its "
			.. "own storage, nothing ME lacks, the leader and the nearest block, kept for a pass and then taken back, the waiting "
			.. "ME blocks first, asks for what an export bus waits for, never the base's chests an ME Logistic Storage Bus shows")
	end

	function T.tick()
		local st = storage.lifauto537
		if not st or st.done then return end
		local tick = game.tick
		local problems = st.problems
		local function expect(ok, text) if not ok then problems[#problems + 1] = text end end
		local s = game.surfaces[SURFACE]
		local function find(name, x, y) return s.find_entity(name, { x, y }) end
		local function n(e, name)
			if not (e and e.valid) then return -1 end
			return e.get_inventory(defines.inventory.chest).get_item_count(name)
		end
		local function count(e, name) return remote.call(NET, "count", e, name) end
		local function info(l) return remote.call(LIF, "info", l) or {} end
		local function chests(l) return remote.call(LIF, "chests", l) or {} end
		local le = find(NAME, X.L + 15.5, 3.5)
		--- L, after the request was cleared: was the stock kept for a pass without demand?
		if st.cleared and not st.held then
			local d = remote.call(LIF, "demand")
			local lid = info(le).lid
			local o = d and lid and d.auto and d.auto[lid] and d.auto[lid].keys.pipe
			if o and o.z == 1 and o.n == 0 and n(chests(le).provider, "pipe") == 10 then st.held = tick end
		end
		if tick ~= T1 and tick ~= T2 then return end
		local lj, lw = find(NAME, X.J + 4.5, 3.5), find(NAME, X.L - 14.5, 3.5)
		local lm, ln = find(NAME, X.M + 4.5, 3.5), find(NAME, X.N + 4.5, 3.5)
		if not (lj and lw and le and lm and ln) then
			expect(false, "blocks missing")
			return finish(st, problems)
		end

		if tick == T1 then
			local ij = info(lj)
			expect(ij.mode == "auto" and remote.call(LIF, "get_settings", lj).mode == "auto", "J: a new block is not automatic: "
				.. tostring(ij.mode))
			--- L: the leader and the nearest block
			local iw, ie = info(lw), info(le)
			expect(iw.auto_leads and not ie.auto_leads, "L: the first block does not lead: " .. tostring(iw.auto_leads) .. " / "
				.. tostring(ie.auto_leads))
			expect(n(chests(le).provider, "pipe") == 10 and n(chests(lw).provider, "pipe") == 0 and count(le, "pipe") == 40,
				"L: pipes at the eastern block " .. n(chests(le).provider, "pipe") .. ", the western " .. n(chests(lw).provider, "pipe")
				.. ", the network " .. count(le, "pipe"))
			expect(#ie.auto_offer == 1 and ie.auto_offer[1].key == "pipe" and ie.auto_offer[1].amount == 10 and #iw.auto_offer == 0,
				"L: the automatic offer " .. serpent.line(ie.auto_offer) .. " / " .. serpent.line(iw.auto_offer))
			local v = remote.call("gregtorio-me-gui", "lif_view", le)
			expect(v and v.ok and v.mode == true and v.auto_offer == 1 and v.auto_enabled == false, "L's window: "
				.. serpent.line(v and { v.ok, v.mode, v.auto_offer, v.auto_enabled, v.mode_line }))
			set_request(find("requester-chest", X.L + 15.5, 6.5), "pipe", 0)
			st.cleared = tick
			--- P: from the drive only, never the base's chests the bus shows
			local lp = find(NAME, X.P + 4.5, 3.5)
			local pc = find("storage-chest", X.P - 4.5, 6.5)
			local pv = chests(lp).provider
			expect(n(pv, "copper-plate") == 10 and n(pv, GEAR) == 0 and n(pc, "copper-plate") == 3 and n(pc, GEAR) == 5
				and count(lp, GEAR) == 5, "P: provider " .. n(pv, "copper-plate") .. " copper, " .. n(pv, GEAR) .. " gears; the base's "
				.. "chest " .. n(pc, "copper-plate") .. " copper, " .. n(pc, GEAR) .. " gears; the network shows " .. count(lp, GEAR) .. " gears")
			--- M: the network's needs first
			local im = info(lm)
			expect(count(lm, "iron-plate") == 5 and n(chests(lm).provider, "iron-plate") == 0 and im.auto_waits >= 1,
				"M: iron plates offered while the maintainer waits: provider " .. n(chests(lm).provider, "iron-plate") .. ", network "
				.. count(lm, "iron-plate") .. ", left to waiting blocks " .. tostring(im.auto_waits))
			return
		end

		--- T2
		--- J: the base's storage first, then the stock; copper cable (ME has none) not offered
		local got = 0
		for k = 0, 2 do got = got + n(find("requester-chest", X.J - 6.5 + 3 * k, 8.5), GEAR) end
		local sc = find("storage-chest", X.J - 4.5, -4.5)
		expect(got == 30 and n(sc, GEAR) == 0 and count(lj, GEAR) == 82, "J: requesters " .. got .. ", the base's storage chest "
			.. n(sc, GEAR) .. ", the network " .. count(lj, GEAR) .. " gears (want 30, 0, 82)")
		local ij = info(lj)
		for _, o in ipairs(ij.auto_offer) do expect(o.key ~= "copper-cable", "J: copper cable offered without ME stock") end
		--- L: kept for a pass, then back
		expect(st.held ~= nil, "L: the stock was not kept for a pass without demand")
		expect(n(chests(le).provider, "pipe") == 0 and count(le, "pipe") == 50, "L: the stock was not taken back: provider "
			.. n(chests(le).provider, "pipe") .. ", the network " .. count(le, "pipe"))
		--- N: the export bus got what it waited for
		local ch = find("iron-chest", X.N + 8.5, 4.5)
		expect(n(ch, "copper-cable") == 30 and n(find("storage-chest", X.N - 4.5, 6.5), "copper-cable") == 0, "N: the export bus's "
			.. "chest " .. n(ch, "copper-cable") .. ", the base's storage chest " .. n(find("storage-chest", X.N - 4.5, 6.5), "copper-cable")
			.. " copper cable")
		finish(st, problems)
	end

	function T.running(check) check(storage.lifauto537 and storage.lifauto537.done, "ME logistic interface automatic mode (issue #537)") end

	return T
end
