--- Runtime test of me-network issue #559: all ME Wireless Links of a frequency on a surface form one wireless network. On a
--- surface of its own ("me-wgroup-test", concrete, a power source at each place), frequency 5:
---   * A (x 0: controller, drive with copper plates), B (x 400, an ME Interface keeping 10 copper plates), C (x 800, another such
---     interface) and D (x 1500): A and C are 798 tiles apart (the range is 512), B is in reach of both: the chain A - B - C is
---     one network, both interfaces fill; edges A 1, B 2, C 1 (a spanning tree, not one edge per pair); D, 700 tiles from C,
---     is out of range and alone; B's window data counts 4 links of the frequency; A's drain is the base and 13 started chunks;
---   * C's power cut: C drops out (A and C apart, B one edge); the power back: C joins again;
---   * B on frequency 6: A and C apart at once; B back on 5: one network at once;
---   * B destroyed: A and C apart at once; a new link B2 there on frequency 5 joins them when it has power.
--- Then a timing probe (logged as DEVCHECK-RUNTIME-WGROUP-PERF, no check but the group's size): 200 links of frequency 7 in
--- reach of each other: building them and setting their frequencies; once they have power: a slow step with nothing changed, one
--- with a link without power (the group decided again), one link to another frequency and back.
--- Loaded by control.lua: require("wgroup")(H) returns { setup, tick, running }.

local NET, IO, QB = "gregtorio-me-network", "gregtorio-me-io", "gregtorio-me-qbridge"
local SURFACE = "me-wgroup-test"
local SITES = { 0, 400, 800, 1500, -300 }     -- (A, B, C, D, the timing probe's grid)
local START, TIMEOUT = 100, 400
local LINK = "me-wireless-link"
local PROBE = 200

local function surface()
	local s = game.surfaces[SURFACE]
	if s then return s end
	s = game.create_surface(SURFACE, { default_enable_all_autoplace_controls = false,
		autoplace_settings = { entity = { treat_missing_as_default = false, settings = {} },
			decorative = { treat_missing_as_default = false, settings = {} } } })
	s.always_day = true
	for _, x in pairs(SITES) do s.request_to_generate_chunks({ x, 0 }, 1) end
	s.force_generate_chunk_requests()
	local tiles = {}
	for _, x0 in pairs(SITES) do
		for x = x0 - 16, x0 + 16 do for y = -16, 16 do tiles[#tiles + 1] = { name = "refined-concrete", position = { x, y } } end end
	end
	s.set_tiles(tiles)
	return s
end

return function(H)
	local me_place, me_report = H.me_place, H.me_report
	local T = {}

	function T.setup()
		local fails = {}
		local what = "wireless link group"
		local s = surface()
		for _, x in pairs(SITES) do H.power(s, fails, what, x, 0) end
		local ctrl = me_place(s, fails, what, "me-network-controller", 6, 0)
		local drive = H.me_drive(s, fails, what, 7.5, -0.5, { ["copper-plate"] = 300 })
		local a = me_place(s, fails, what, LINK, 8.5, -0.5)
		H.me_connect(fails, what, { ctrl, drive, a })
		for _, x in pairs({ 400, 800 }) do
			local l = me_place(s, fails, what, LINK, x + 6.5, -0.5)
			local i = me_place(s, fails, what, "me-network-interface", x + 7.5, -0.5)
			H.me_connect(fails, what, { l, i })
		end
		me_place(s, fails, what, LINK, 1506.5, -0.5)
		return fails
	end

	function T.tick()
		local st = storage.wgroup559
		local tick = game.tick
		if tick < START or (st and st.done) then return end
		local s = game.surfaces[SURFACE]
		if not st then
			st = { problems = {}, phase = "start" }
			storage.wgroup559 = st
		end
		local problems = st.problems
		local function expect(ok, msg) if not ok then problems[#problems + 1] = msg end end
		local function finish()
			st.done = true
			me_report("WGROUP", "ME Wireless Link groups (issue #559)", problems, "a chain of three links is one network (a spanning "
				.. "tree), one out of range alone; a link without power drops out and comes back; a frequency change and a "
				.. "removal split the group at once, a new link joins it")
		end
		local function link(x) return s.find_entity(LINK, { x + 6.5, -0.5 }) end
		local a, b, c, d = s.find_entity(LINK, { 8.5, -0.5 }), link(400), link(800), link(1500)
		local ib, ic = s.find_entity("me-network-interface", { 407.5, -0.5 }), s.find_entity("me-network-interface", { 807.5, -0.5 })
		local eei_c = s.find_entity("electric-energy-interface", { 800, 0 })
		if not (a and c and d and ib and ic and eei_c) then expect(false, "entities missing in phase " .. st.phase) return finish() end
		local function same(x, y) return x and y and remote.call(NET, "same_network", x, y) end
		local function info(e) return remote.call(QB, "info", e) or {} end
		local function copper(i) return i.get_inventory(defines.inventory.chest).get_item_count("copper-plate") end
		local function waited(what)
			if tick > st.at + TIMEOUT then
				expect(false, what .. " within " .. TIMEOUT .. " ticks")
				return true
			end
			return false
		end

		if st.phase == "start" then
			for _, i in pairs({ ib, ic }) do
				remote.call(IO, "set_interface_config", i, { [1] = { name = "copper-plate", quality = "normal", amount = 10 } }, {})
			end
			for _, l in pairs({ a, b, c, d }) do remote.call(QB, "set_frequency", l, 5) end
			st.phase, st.at = "join", tick
		elseif st.phase == "join" then
			if not (same(a, b) and same(a, c) and copper(ib) == 10 and copper(ic) == 10) then
				if waited("the chain A - B - C did not become one network with full interfaces: " .. serpent.line({ same(a, b),
					same(a, c), copper(ib), copper(ic), info(a).status, info(b).status, info(c).status })) then return finish() end
				return
			end
			local ia, ibi, ici, idi = info(a), info(b), info(c), info(d)
			expect(ia.edges == 1 and ibi.edges == 2 and ici.edges == 1, "the edges of A, B, C: " .. serpent.line({ ia.edges,
				ibi.edges, ici.edges }))
			expect(idi.status == "out-of-range" and (idi.edges or 0) == 0 and not same(a, d), "D 700 tiles from C: " .. serpent.line(idi))
			expect(ibi.group == 4 and ibi.status == "linked", "B's window data: " .. serpent.line({ ibi.group, ibi.status }))
			local want = remote.call(QB, "drain", LINK, 398)
			expect(math.abs(ia.watts - want) < 1 and math.abs(ibi.watts - remote.call(QB, "drain", LINK, 400)) < 1,
				"the drains of A and B: " .. serpent.line({ ia.watts, ibi.watts, want }))
			eei_c.power_production, eei_c.energy, c.energy = 0, 0, 0
			st.phase, st.at = "cut", tick
		elseif st.phase == "cut" then
			if same(a, c) then
				if waited("C without power stayed in the network") then return finish() end
				return
			end
			expect(info(b).edges == 1 and info(c).status == "no-power", "after C lost its power: " .. serpent.line({ info(b).edges,
				info(c).status }))
			eei_c.power_production = 1e6
			st.phase, st.at = "back", tick
		elseif st.phase == "back" then
			if not same(a, c) then
				if waited("C did not join again with its power back") then return finish() end
				return
			end
			remote.call(QB, "set_frequency", b, 6)
			expect(not same(a, c) and info(a).status == "out-of-range", "B on frequency 6: " .. serpent.line({ same(a, c), info(a).status }))
			remote.call(QB, "set_frequency", b, 5)
			expect(same(a, c) and same(a, b), "B back on frequency 5: " .. serpent.line({ same(a, b), same(a, c) }))
			b.destroy{ raise_destroy = true }
			expect(not same(a, c), "B destroyed, A and C still one network")
			local b2 = s.create_entity{ name = LINK, position = { 406.5, -0.5 }, force = "player", raise_built = true }
			if b2 then remote.call(QB, "set_frequency", b2, 5) end
			st.phase, st.at = "rebuild", tick
		elseif st.phase == "rebuild" then
			local b2 = link(400)
			if not (same(a, c) and same(a, b2)) then
				if waited("a new link B2 did not join A and C") then return finish() end
				return
			end
			st.phase, st.at = "probe", tick
		elseif st.phase == "probe" then
			--- the timing probe: 200 links in a grid around the fifth place's substation
			local p = helpers.create_profiler()
			local links = {}
			for i = 0, PROBE - 1 do
				local row = math.floor(i / 15)                          -- (7 rows above the power source, 7 below)
				local e = s.create_entity{ name = LINK, position = { -305.5 + i % 15, row < 7 and -8.5 + row or 1.5 + row - 7 },
					force = "player", raise_built = true }
				if e then links[#links + 1] = e end
			end
			p.stop()
			local p2 = helpers.create_profiler()
			for _, e in ipairs(links) do remote.call(QB, "set_frequency", e, 7) end
			p2.stop()
			log({ "", "DEVCHECK-RUNTIME-WGROUP-PERF built ", #links, " links: ", p, "; their frequency set: ", p2 })
			st.phase, st.at = "probe2", tick
		elseif st.phase == "probe2" then
			if tick < st.at + 150 then return end                      -- (the slow steps since decided the group)
			local first, second = s.find_entity(LINK, { -305.5, -8.5 }), s.find_entity(LINK, { -304.5, -8.5 })
			local n = first and info(first) or {}
			local p = helpers.create_profiler()
			remote.call(QB, "step")                                     -- (nothing changed)
			p.stop()
			if first then first.energy = 0 end
			local p2 = helpers.create_profiler()
			remote.call(QB, "step")                                     -- (one link without power: the group decided again)
			p2.stop()
			local p3 = helpers.create_profiler()
			if second then remote.call(QB, "set_frequency", second, 9) end   -- (out of the group and back: two decisions each)
			if second then remote.call(QB, "set_frequency", second, 7) end
			p3.stop()
			log({ "", "DEVCHECK-RUNTIME-WGROUP-PERF ", PROBE, " links with power (group ", tostring(n.group), ", edges of the first ",
				tostring(n.edges), "), the slow step: nothing changed ", p, "; one link without power ", p2,
				"; one link to another frequency and back ", p3 })
			expect(n.group == PROBE and (n.edges or 0) > 0, "the probe's group: " .. serpent.line({ n.group, n.edges, n.status }))
			return finish()
		end
	end

	function T.running(check) check(storage.wgroup559 and storage.wgroup559.done, "ME Wireless Link groups") end
	return T
end
