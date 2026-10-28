--- Runtime test of me-network issue #556: a network that draws more than the ME Controller's prototype buffer per tick. Until
--- 0.5.10 the buffer was a fixed 100 kJ, so a draw above 6 MW (100 kJ x 60) emptied it every tick and the network reported
--- "no-power" on any grid. One network: a controller, a drive and eight 4096x crafting accelerators (2 MW each, 16.124 MW in all),
--- on a source of 60 MW:
---   * it works, for 60 ticks in a row, and the controller's buffer holds N.BUFFER_TICKS ticks of its draw;
---   * the source cut to 8 MW (its own buffer emptied): the network reports "no-power" (the grid really lacks the power);
---   * the source back to 60 MW: it works again;
---   * two accelerators mined: the buffer follows the lower draw.
--- Loaded by control.lua: require("bigpower")(H) returns { setup, tick, running }.

local NET = "gregtorio-me-network"
local BX, BY = 250, 60                -- (inside the cleared test area, TEST_RADIUS of control.lua; clear of the other tests)
local START, TIMEOUT = 150, 300
local ACCEL, N_ACCEL = "me-crafting-accelerator-4096x", 8
local POWER = 120000 + 4000 + N_ACCEL * 2000000         -- (controller, drive, accelerators)
local BUFFER_TICKS = 30                                 -- (N.BUFFER_TICKS)

return function(H)
	local me_place, me_report = H.me_place, H.me_report
	local T = {}

	function T.setup(s)
		local fails = {}
		local what = "big network power"
		H.power(s, fails, what, BX, BY)
		local ctrl = me_place(s, fails, what, "me-network-controller", BX + 6, BY)
		local members = { ctrl, H.me_drive(s, fails, what, BX + 7.5, BY - 0.5, { ["iron-plate"] = 10 }) }
		for i = 1, N_ACCEL do members[#members + 1] = me_place(s, fails, what, ACCEL, BX + 7 + i + 0.5, BY - 0.5) end
		H.me_connect(fails, what, members)
		return fails
	end

	function T.tick()
		local st = storage.bigpower556
		if game.tick < START or (st and st.done) then return end
		if not st then
			st = { problems = {}, phase = "hold", at = game.tick }
			storage.bigpower556 = st
		end
		local s = game.surfaces[1]
		local problems = st.problems
		local function expect(ok, msg) if not ok then problems[#problems + 1] = msg end end
		local function finish()
			st.done = true
			me_report("BIGPOWER", "ME Controller buffer above 6 MW", problems, "a 16 MW network on a 60 MW source works for 60 ticks, "
				.. "its buffer " .. BUFFER_TICKS .. " ticks of the draw; no power on 8 MW, works again on 60 MW; the buffer follows a "
				.. "lower draw")
		end
		local ctrl = s.find_entity("me-network-controller", { BX + 6, BY })
		local eei = s.find_entity("electric-energy-interface", { BX, BY })
		if not (ctrl and eei) then expect(false, "entities missing") return finish() end
		local function info() return remote.call(NET, "network", ctrl) or {} end
		local function near(a, b) return math.abs(a - b) < 1 end
		local tick = game.tick

		if st.phase == "hold" then
			local n = info()
			if not n.ok then
				expect(false, "the 16 MW network on a 60 MW source does not work at tick " .. tick .. ": " .. serpent.line({ n.status,
					n.power, ctrl.energy, ctrl.electric_buffer_size }))
				return finish()
			end
			if tick < st.at + 60 then return end
			expect(n.power == POWER, "the network's power: " .. tostring(n.power) .. " W, " .. POWER .. " expected")
			expect(near(ctrl.power_usage * 60, POWER) and near(ctrl.electric_buffer_size, POWER / 60 * BUFFER_TICKS),
				"the controller's draw and buffer: " .. serpent.line({ ctrl.power_usage * 60, ctrl.electric_buffer_size }))
			eei.power_production, eei.energy = 8000000 / 60, 0
			st.phase, st.at = "weak", tick
		elseif st.phase == "weak" then
			local n = info()
			if n.status == "no-power" then
				eei.power_production = 1e6
				st.phase, st.at = "back", tick
			elseif tick > st.at + TIMEOUT then
				expect(false, "the network kept working on 8 MW for " .. TIMEOUT .. " ticks: " .. serpent.line({ n.status, ctrl.energy }))
				eei.power_production = 1e6
				return finish()
			end
		elseif st.phase == "back" then
			local n = info()
			if n.ok then
				for i = N_ACCEL - 1, N_ACCEL do                      -- (the far end: the rest stays one network)
					local a = s.find_entity(ACCEL, { BX + 7 + i + 0.5, BY - 0.5 })
					if a then a.destroy{ raise_destroy = true } end
				end
				local want = POWER - 2 * 2000000
				n = info()
				expect(n.power == want and near(ctrl.electric_buffer_size, want / 60 * BUFFER_TICKS),
					"two accelerators mined: " .. serpent.line({ n.power, ctrl.electric_buffer_size }) .. ", " .. want .. " W expected")
				return finish()
			elseif tick > st.at + TIMEOUT then
				expect(false, "the network did not work again " .. TIMEOUT .. " ticks after 60 MW came back: " .. serpent.line(n.status))
				return finish()
			end
		end
	end

	function T.running(check) check(storage.bigpower556 and storage.bigpower556.done, "ME Controller buffer above 6 MW") end
	return T
end
