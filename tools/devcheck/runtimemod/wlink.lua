--- Runtime test of me-network issue #384: the ME Wireless Link (scripts/fork-me-qbridge.lua, the bridge's pairing).
--- * Nauvis: a network with a controller and a drive (300 copper plates) and link L1; 100 tiles east link L2 with an ME
---   Interface that keeps 40 copper plates, no controller, power of its own. Frequency 9 on both: one network, the interface
---   fills; each link draws 10 kW + 50 kW per started 32 tiles: 210 kW.
--- * A quantum bridge on frequency 9 too: the kinds never pair, the links stay linked.
--- * Frequency 21: L3 on Nauvis, L4 on another surface: "other-surface", nothing linked, the base drain.
--- * Frequency 33 on that other surface, 600 tiles apart (the range is 512): "out-of-range", nothing linked.
--- Loaded by control.lua like lab.lua.

local NET, IO, QB = "gregtorio-me-network", "gregtorio-me-io", "gregtorio-me-qbridge"
local BX, BY = 160, 280                  -- (inside the cleared test area, TEST_RADIUS of control.lua; clear of the other tests)
local SURFACE = "me-wlink-test"
local START, CHECK = 100, 600

--- the test's second surface, with concrete around the two places the far pair stands
local function surface_b()
	local s = game.surfaces[SURFACE]
	if s then return s end
	s = game.create_surface(SURFACE, { default_enable_all_autoplace_controls = false,
		autoplace_settings = { entity = { treat_missing_as_default = false, settings = {} },
			decorative = { treat_missing_as_default = false, settings = {} } } })
	for _, x in pairs({ 0, 600 }) do s.request_to_generate_chunks({ x, 0 }, 1) end
	s.force_generate_chunk_requests()
	local tiles = {}
	for _, x0 in pairs({ 0, 600 }) do
		for x = x0 - 12, x0 + 12 do for y = -12, 12 do tiles[#tiles + 1] = { name = "refined-concrete", position = { x, y } } end end
	end
	s.set_tiles(tiles)
	return s
end

return function(H)
	local me_place, me_report, power = H.me_place, H.me_report, H.power
	local T = {}

	function T.setup(s)
		local fails = {}
		local what = "wireless link"
		power(s, fails, what, BX, BY)
		local ctrl = me_place(s, fails, what, "me-network-controller", BX + 7, BY)
		local drive = H.me_drive(s, fails, what, BX + 8.5, BY - 0.5, { ["copper-plate"] = 300 })
		local l1 = me_place(s, fails, what, "me-wireless-link", BX + 10.5, BY - 0.5)
		H.me_connect(fails, what, { ctrl, drive, l1 })
		power(s, fails, what, BX + 100, BY)
		local l2 = me_place(s, fails, what, "me-wireless-link", BX + 110.5, BY - 0.5)
		local iface = me_place(s, fails, what, "me-network-interface", BX + 111.5, BY - 0.5)
		if l2 and iface then H.me_connect(fails, what, { l2, iface }) end
		me_place(s, fails, what, "me-quantum-bridge", BX + 20.5, BY + 4.5)
		me_place(s, fails, what, "me-wireless-link", BX + 14.5, BY + 4.5)                    -- L3
		local sb = surface_b()
		for _, x in pairs({ 0, 600 }) do power(sb, fails, what, x, 0) end
		me_place(sb, fails, what, "me-wireless-link", 6.5, 0.5)                              -- L4 (with L3)
		me_place(sb, fails, what, "me-wireless-link", 7.5, 0.5)                              -- L5
		me_place(sb, fails, what, "me-wireless-link", 606.5, 0.5)                            -- L6 (with L5)
		return fails
	end

	function T.tick()
		local tick = game.tick
		if tick ~= START and tick ~= CHECK then return end
		local s, sb = game.surfaces[1], game.surfaces[SURFACE]
		local function at(surface, x, y, name) return surface and surface.find_entity(name or "me-wireless-link", { x, y }) end
		local l1, l2 = at(s, BX + 10.5, BY - 0.5), at(s, BX + 110.5, BY - 0.5)
		local iface = at(s, BX + 111.5, BY - 0.5, "me-network-interface")
		local qb = at(s, BX + 20.5, BY + 4.5, "me-quantum-bridge")
		local l3, l4, l5, l6 = at(s, BX + 14.5, BY + 4.5), at(sb, 6.5, 0.5), at(sb, 7.5, 0.5), at(sb, 606.5, 0.5)
		local ctrl = at(s, BX + 7, BY, "me-network-controller")
		local st = storage.wlink384
		if tick == START then
			st = { problems = {}, done = false }
			storage.wlink384 = st
			if not (l1 and l2 and iface and qb and l3 and l4 and l5 and l6 and ctrl) then
				st.done = true
				return me_report("WLINK", "ME Wireless Link", { "the test blocks were not built" })
			end
			remote.call(IO, "set_interface_config", iface, { [1] = { name = "copper-plate", quality = "normal", amount = 40 } }, {})
			for _, p in pairs({ { l1, 9 }, { l2, 9 }, { qb, 9 }, { l3, 21 }, { l4, 21 }, { l5, 33 }, { l6, 33 } }) do
				remote.call(QB, "set_frequency", p[1], p[2])
			end
			return
		end
		if not st or st.done then return end
		st.done = true
		local problems = st.problems
		local function expect(ok, msg) if not ok then problems[#problems + 1] = msg end end
		local function info(e) return remote.call(QB, "info", e) or {} end
		local i1 = info(l1)
		local want = remote.call(QB, "drain", "me-wireless-link", 100)
		expect(want == 210000, "the drain over 100 tiles: " .. tostring(want) .. " W, not 210 kW")
		expect(i1.status == "linked" and remote.call(NET, "same_network", l1, l2), "L1 and L2 on frequency 9: " .. tostring(i1.status))
		expect(math.abs((i1.watts or 0) - 210000) < 1 and math.abs(l2.power_usage * 60 - 210000) < 1,
			"the linked pair's drain: " .. tostring(i1.watts) .. " / " .. tostring(l2.power_usage * 60) .. " W")
		expect(math.abs((i1.distance or 0) - 100) < 0.01 and i1.range == 512, "distance and range " .. serpent.line({ i1.distance, i1.range }))
		expect(iface.get_inventory(defines.inventory.chest).get_item_count("copper-plate") == 40
			and remote.call(NET, "count", ctrl, "copper-plate") == 260, "the interface 100 tiles away holds "
			.. iface.get_inventory(defines.inventory.chest).get_item_count("copper-plate") .. " plates")
		expect(info(qb).status == "waiting", "a quantum bridge on the links' frequency: " .. tostring(info(qb).status))
		local i3 = info(l3)
		expect(i3.status == "other-surface" and not remote.call(NET, "same_network", l3, l4)
			and math.abs((i3.watts or 0) - 10000) < 1, "a pair on two surfaces: " .. serpent.line({ i3.status, i3.watts }))
		local i5 = info(l5)
		expect(i5.status == "out-of-range" and not remote.call(NET, "same_network", l5, l6) and math.abs((i5.distance or 0) - 599) < 0.01,
			"a pair 599 tiles apart: " .. serpent.line({ i5.status, i5.distance }))
		me_report("WLINK", "ME Wireless Link", problems, "two links 100 tiles apart are one network at 210 kW each (an interface there fills);"
			.. " a quantum bridge on the same frequency stays apart; a pair on two surfaces and one 599 tiles apart do not link")
	end

	function T.running(check) check(storage.wlink384 and storage.wlink384.done, "ME Wireless Link") end
	return T
end
