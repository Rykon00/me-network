--- Runtime test of me-network issue #442: the Creative Energy Cell. A network whose ME Controller has no pole, a drive with iron
--- plates and a level emitter in energy mode:
---   * without the cell the network does not work (it counts nothing, the emitter is off);
---   * a Creative Energy Cell built next to the controller: it works (100 plates, the emitter reports the controller's buffer as
---     full and is on);
---   * the cell removed: it does not work again.
--- Loaded by control.lua: require("creativeenergy")(H) returns { setup, tick, running }.

local NET, EM = "gregtorio-me-network", "gregtorio-me-emitter"
local BX, BY = -20, 330               -- (inside the cleared test area, TEST_RADIUS of control.lua; clear of the other tests)
local START = 185
local CELL = "me-creative-energy-cell"

return function(H)
	local me_place, me_report = H.me_place, H.me_report
	local T = {}

	function T.setup(s)
		local fails = {}
		local what = "creative energy cell"
		local ctrl = me_place(s, fails, what, "me-network-controller", BX + 7, BY)           -- (no pole: no power)
		local drive = H.me_drive(s, fails, what, BX + 8.5, BY - 0.5, { ["iron-plate"] = 100 }, "16k")
		local em = me_place(s, fails, what, "me-level-emitter", BX + 8.5, BY + 0.5)
		H.me_connect(fails, what, { ctrl, drive, em })
		return fails
	end

	function T.tick()
		local st = storage.creativeenergy442
		if game.tick < START or (st and st.done) then return end
		st = { problems = {} }
		storage.creativeenergy442 = st
		local s = game.surfaces[1]
		local function find(name, x, y) return s.find_entity(name, { BX + x, BY + y }) end
		local function expect(ok, msg) if not ok then st.problems[#st.problems + 1] = msg end end
		local function report()
			st.done = true
			me_report("CREATIVEENERGY", "Creative Energy Cell", st.problems, "no power without it; works with it, the emitter "
				.. "reports full; no power again without it")
		end
		local ctrl, em = find("me-network-controller", 7, 0), find("me-level-emitter", 8.5, 0.5)
		if not (ctrl and em) then expect(false, "entities missing") return report() end
		local function count() return remote.call(NET, "count", ctrl, "iron-plate") end
		remote.call(EM, "set", em, { energy = true, amount = 1 })
		expect(count() == 0 and not remote.call(EM, "get", em).on, "without the cell the network does not work: " .. count())
		local cell = s.create_entity{ name = CELL, position = { BX + 6.5, BY + 1.5 }, force = "player", raise_built = true }
		expect(cell ~= nil, "the cell is built")
		remote.call(EM, "visit", em)
		local d = remote.call(EM, "get", em)
		expect(count() == 100, "with the cell the network works: " .. count())
		expect(d.on and (d.level or 0) >= ctrl.electric_buffer_size and ctrl.electric_buffer_size > 0,
			"the emitter reports the controller's buffer as full: " .. serpent.line({ d.level, ctrl.electric_buffer_size }))
		if cell then cell.destroy{ raise_destroy = true } end
		remote.call(EM, "visit", em)
		expect(count() == 0 and not remote.call(EM, "get", em).on, "without it again: " .. count())
		return report()
	end

	function T.running(check) check(storage.creativeenergy442 and storage.creativeenergy442.done, "Creative Energy Cell") end

	return T
end
