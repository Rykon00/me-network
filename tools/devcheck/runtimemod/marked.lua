--- Runtime test: a member marked for deconstruction carries no network from that moment (N.set_marked). A controller, drive A
--- (iron plates), a terminal, five cables, drive B (copper), an underground cable pair and drive C (stone) in a row:
---   * a marked cable splits B and C off at once, its cancelled mark joins them again;
---   * a marked drive takes its cells out of the network's storage (and splits C off), the cells stay in it and come back;
---   * a marked underground end splits C off and lets go of its partner; cancelled, the pair is paired again;
---   * a marked cable stays out through a full rebuild and a kept graph (the marks are read from the map);
---   * a marked drive that is mined gives its four cells into the buffer (nothing is lost while it was out of the graph).
--- Loaded by control.lua: require("marked")(H) returns { setup, tick, running }.

local NET = "gregtorio-me-network"
local UG = "me-underground-cable"
local BX, BY = -250, -140             -- (inside the cleared test area, TEST_RADIUS of control.lua; clear of the other tests)
local CHECK = 150
local PLATES, COPPER, STONE = 100, 50, 30

return function(H)
	local me_place, cable_row, power, me_report = H.me_place, H.cable_row, H.power, H.me_report
	local T = {}
	local function at(dx, dy) return { BX + dx + 0.5, BY + dy + 0.5 } end      -- the centre of tile (BX+dx, BY+dy)

	function T.setup(s)
		local fails = {}
		local what = "deconstruction marks"
		power(s, fails, what, BX, BY)
		me_place(s, fails, what, "me-network-controller", BX + 7, BY)             -- tiles 6..7, -1..0
		H.me_drive(s, fails, what, BX + 8.5, BY - 0.5, { ["iron-plate"] = PLATES })
		me_place(s, fails, what, "me-terminal", BX + 9.5, BY - 0.5)
		cable_row(s, fails, BX + 10, BX + 14, BY - 1)
		H.me_drive(s, fails, what, BX + 15.5, BY - 0.5, { ["copper-plate"] = COPPER })
		me_place(s, fails, what, UG, BX + 16.5, BY - 0.5, { direction = defines.direction.west })
		me_place(s, fails, what, UG, BX + 24.5, BY - 0.5, { direction = defines.direction.east })
		H.me_drive(s, fails, what, BX + 25.5, BY - 0.5, { ["stone"] = STONE })
		return fails
	end

	function T.tick()
		local st = storage.marked_decon
		if (st and st.done) or game.tick < CHECK then return end
		st = { done = true }
		storage.marked_decon = st
		local s = game.surfaces[1]
		local problems = {}
		local function expect(ok, msg) if not ok then problems[#problems + 1] = msg end end
		local function find(name, dx, dy) return s.find_entity(name, at(dx, dy)) end
		local t, cable = find("me-terminal", 9, -1), find("me-cable", 12, -1)
		local db, dc = find("me-drive", 15, -1), find("me-drive", 25, -1)
		local u1, u2 = find(UG, 16, -1), find(UG, 24, -1)
		local finish = function()
			me_report("DECON", "ME deconstruction marks", problems, "a marked cable, drive and underground end carry no network at "
				.. "once and join again when the mark is cancelled, through a rebuild and a kept graph, a mined marked drive's cells")
		end
		if not (t and cable and db and dc and u1 and u2) then expect(false, "entities missing") return finish() end
		local function count(name) return remote.call(NET, "count", t, name) end
		local function same(a, b) return remote.call(NET, "same_network", a, b) end
		local function state(what, copper, stone)
			expect(count("copper-plate") == copper and count("stone") == stone and count("iron-plate") == PLATES,
				what .. ": the terminal sees " .. count("iron-plate") .. " iron, " .. count("copper-plate") .. " copper, "
				.. count("stone") .. " stone (want " .. PLATES .. ", " .. copper .. ", " .. stone .. ")")
		end
		state("before any mark", COPPER, STONE)
		expect(same(t, db) and same(t, dc), "before any mark: drives B and C are not in the terminal's network")
		expect(remote.call(NET, "underground_partner", u1) == u2.unit_number, "before any mark: the underground pair is not paired")

		--- a marked cable
		cable.order_deconstruction("player")
		expect(cable.to_be_deconstructed(), "the cable is not marked")
		state("cable marked", 0, 0)
		expect(not same(t, db) and same(db, dc), "cable marked: B is still in the terminal's network, or B and C split")
		expect(remote.call(NET, "network", cable) == nil, "cable marked: the cable still belongs to a network")
		cable.cancel_deconstruction("player")
		state("cable's mark cancelled", COPPER, STONE)
		expect(same(t, db) and same(t, cable), "cable's mark cancelled: B or the cable is not in the terminal's network")

		--- a marked drive: its cells leave the storage, C splits off; back with the cancel
		db.order_deconstruction("player")
		state("drive B marked", 0, 0)
		local cells, held = 0, 0
		for _, c in pairs(remote.call(NET, "drive", db) or {}) do
			cells = cells + 1
			held = held + ((c.items or {})["copper-plate"] or 0)
		end
		expect(cells == 4 and held == COPPER, "drive B marked: it holds " .. cells .. " cells with " .. held .. " copper, not 4 with " .. COPPER)
		db.cancel_deconstruction("player")
		state("drive B's mark cancelled", COPPER, STONE)

		--- a marked underground end
		u1.order_deconstruction("player")
		state("underground end marked", COPPER, 0)
		expect(remote.call(NET, "underground_partner", u2) == nil, "underground end marked: its partner is still paired with it")
		u1.cancel_deconstruction("player")
		state("underground end's mark cancelled", COPPER, STONE)
		expect(remote.call(NET, "underground_partner", u1) == u2.unit_number, "underground end's mark cancelled: the pair is not paired")

		--- the mark through a rebuild of the graph (full) and a kept graph
		cable.order_deconstruction("player")
		remote.call(NET, "rebuild", true)
		state("cable marked, full rebuild", 0, 0)
		remote.call(NET, "rebuild", false)
		state("cable marked, kept graph", 0, 0)
		cable.cancel_deconstruction("player")
		state("cable's mark cancelled after the rebuilds", COPPER, STONE)

		--- a marked drive that is mined: its cells into the buffer
		db.order_deconstruction("player")
		local buffer = game.create_inventory(8)
		remote.call(NET, "removed", db, buffer)
		local got = 0
		for i = 1, #buffer do
			local stack = buffer[i]
			if stack.valid_for_read and stack.name:find("storage%-cell") then got = got + stack.count end
		end
		buffer.destroy()
		expect(got == 4, "marked drive B mined: " .. got .. " cells in the buffer, not 4")
		db.destroy()
		state("marked drive B mined", 0, 0)
		finish()
	end

	function T.running(check) check(storage.marked_decon and storage.marked_decon.done, "ME deconstruction marks") end
	return T
end
