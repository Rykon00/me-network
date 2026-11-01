--- Runtime test of me-network issue #385: the ME Quantum Bridge (scripts/fork-me-qbridge.lua), across two surfaces.
--- * Nauvis: a network with a controller and a drive (500 iron plates) and bridge A; a second surface "me-qbridge-test":
---   bridge B and an ME Interface that keeps 50 iron plates, no controller. Both bridges on frequency 7: linked, one network;
---   the interface on the other surface fills from the drive on Nauvis.
--- * B's power is taken away: its buffer runs dry and the link goes (B's side has no network that works); power back: linked
---   again.
--- * A third bridge of frequency 7 (on Nauvis): the frequency is taken, nothing links; it is mined: A and B link again.
--- * Issue #511 (qbfield.lua): A's window keeps a typed frequency over the refreshes, shows one set elsewhere.
--- Loaded by control.lua like lab.lua.

local NET, IO, QB = "gregtorio-me-network", "gregtorio-me-io", "gregtorio-me-qbridge"
local qbfield = require("qbfield")       -- (issue #511)
local BX, BY = -40, 240                  -- (inside the cleared test area, TEST_RADIUS of control.lua; clear of the other tests)
local SURFACE = "me-qbridge-test"
local START, CUT, CUT_CHECK, BACK_CHECK, THIRD_CHECK, FINAL = 100, 400, 700, 950, 1080, 1300

local function surface_b()
	local s = game.surfaces[SURFACE]
	if s then return s end
	s = game.create_surface(SURFACE, { width = 96, height = 96, default_enable_all_autoplace_controls = false,
		autoplace_settings = { entity = { treat_missing_as_default = false, settings = {} },
			decorative = { treat_missing_as_default = false, settings = {} } } })
	s.request_to_generate_chunks({ 0, 0 }, 2)
	s.force_generate_chunk_requests()
	local tiles = {}
	for x = -30, 29 do for y = -30, 29 do tiles[#tiles + 1] = { name = "refined-concrete", position = { x, y } } end end
	s.set_tiles(tiles)
	return s
end

return function(H)
	local me_place, me_report, power = H.me_place, H.me_report, H.power
	local T = {}

	function T.setup(s)
		local fails = {}
		local what = "quantum bridge"
		power(s, fails, what, BX, BY)
		local ctrl = me_place(s, fails, what, "me-network-controller", BX + 7, BY)
		local drive = H.me_drive(s, fails, what, BX + 8.5, BY - 0.5, { ["iron-plate"] = 500 })
		local qa = me_place(s, fails, what, "me-quantum-bridge", BX + 12.5, BY + 2.5)
		H.me_connect(fails, what, { ctrl, drive, qa })
		local sb = surface_b()
		power(sb, fails, what, 0, 0)
		local qb = me_place(sb, fails, what, "me-quantum-bridge", 6.5, 0.5)
		local iface = me_place(sb, fails, what, "me-network-interface", 8.5, 0.5)       -- (next to the bridge's east side)
		if qb and iface then H.me_connect(fails, what, { qb, iface }) end
		return fails
	end

	function T.tick()
		local tick = game.tick
		if tick ~= START and tick ~= CUT and tick ~= CUT_CHECK and tick ~= BACK_CHECK and tick ~= THIRD_CHECK and tick ~= FINAL
			and tick ~= CUT_CHECK + 1 and tick ~= BACK_CHECK + 1 then return end
		local s, sb = game.surfaces[1], game.surfaces[SURFACE]
		local st = storage.qbridge385
		local qa = s.find_entity("me-quantum-bridge", { BX + 12.5, BY + 2.5 })
		local qb = sb and sb.find_entity("me-quantum-bridge", { 6.5, 0.5 })
		local iface = sb and sb.find_entity("me-network-interface", { 8.5, 0.5 })
		local ctrl = s.find_entity("me-network-controller", { BX + 7, BY })
		if tick == START then
			st = { problems = {}, done = false }
			storage.qbridge385 = st
			if not (qa and qb and iface and ctrl) then
				st.done = true
				return me_report("QBRIDGE", "ME Quantum Bridge", { "the test blocks were not built" })
			end
			remote.call(IO, "set_interface_config", iface, { [1] = { name = "iron-plate", quality = "normal", amount = 50 } }, {})
			remote.call(QB, "set_frequency", qa, 7)
			remote.call(QB, "set_frequency", qb, 7)
			st.linked0 = (remote.call(QB, "info", qa) or {}).status
			return
		end
		if not st or st.done then return end
		local problems = st.problems
		local function expect(ok, msg) if not ok then problems[#problems + 1] = msg end end
		local function same() return remote.call(NET, "same_network", qa, qb) == true end
		local function held() return iface.get_inventory(defines.inventory.chest).get_item_count("iron-plate") end
		local function status(e) return (remote.call(QB, "info", e) or {}).status end
		if tick == CUT then
			expect(st.linked0 == "linked", "both bridges on frequency 7 are not linked at once: " .. tostring(st.linked0))
			expect(same(), "the two bridges are not one network")
			expect(held() == 50 and remote.call(NET, "count", ctrl, "iron-plate") == 450,
				"the interface on the other surface holds " .. held() .. " plates, the drive " .. remote.call(NET, "count", ctrl, "iron-plate"))
			local info = remote.call(QB, "info", qb) or {}
			expect(info.partner and info.partner.surface == s.name, "B's partner " .. serpent.line(info.partner))
			--- B loses its power
			for _, e in pairs(sb.find_entities_filtered{ name = "electric-energy-interface", position = { 0, 0 }, radius = 1 }) do e.destroy() end
			return
		end
		if tick == CUT_CHECK then
			expect(not same(), "B without power is still linked")
			expect(status(qa) == "no-power-there" and status(qb) == "no-power", "statuses without B's power: " .. tostring(status(qa)) .. ", " .. tostring(status(qb)))
			expect(remote.call(NET, "count", iface, "iron-plate") == 0, "B's side still reaches the drive")
			--- power back
			local eei = sb.create_entity{ name = "electric-energy-interface", position = { 0, 0 }, force = "player" }
			eei.power_production, eei.electric_buffer_size = 1e7, 1e8
			return
		end
		if tick == BACK_CHECK then
			expect(same() and status(qb) == "linked", "the link did not come back with the power: " .. tostring(status(qb)))
			--- a third bridge of frequency 7
			local third = s.create_entity{ name = "me-quantum-bridge", position = { BX + 20.5, BY + 2.5 }, force = "player", raise_built = true }
			remote.call(QB, "set_frequency", third, 7)
			st.third = third
			return
		end
		if tick == THIRD_CHECK then
			expect(not same() and status(qa) == "taken" and status(qb) == "taken", "a third bridge on frequency 7: " .. tostring(status(qa)) .. ", " .. tostring(status(qb)))
			if st.third and st.third.valid then st.third.destroy{ raise_destroy = true } end
			return
		end
		if tick == FINAL then
			st.done = true
			expect(same() and status(qa) == "linked", "the pair did not link again after the third bridge went: " .. tostring(status(qa)))
			qbfield(problems, qa, 7, 8, "qbridge511")
			me_report("QBRIDGE", "ME Quantum Bridge", problems, "two bridges on frequency 7 join a network on Nauvis and one on another surface"
				.. " (an interface there fills from a drive here); no power on one side opens the link, power back closes it; a third"
				.. " bridge of the frequency links nothing, gone again: linked; the window's frequency field keeps what is typed")
		end
	end

	function T.running(check) check(storage.qbridge385 and storage.qbridge385.done, "ME Quantum Bridge") end
	return T
end
