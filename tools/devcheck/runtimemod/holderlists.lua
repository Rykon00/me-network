--- Runtime test of me-network issue #59 (docs/PERFORMANCE.md "Round five"): the sorted holder lists of the storage engine
--- (by cell id, by rank, the extraction order) follow a cell that starts or stops holding a key in a copy instead of being
--- dropped and sorted anew. Every 10 ticks of the whole run (both halves of the save and load; the other tests' networks
--- insert and extract all the time, with priorities, partitions and storage buses), every kept list of every network must be
--- the list sorted anew from the index, and every holder cursor on a kept list must stand behind entries it may skip
--- (remote `check_holder_lists`). And one case on its own network (one drive of four 1k cells, one priority): two cells
--- full of iron plates put the cursor behind them, the first cell is emptied and the third filled, then a cell before the
--- cursor starts holding the key: the cursor must move back to it, so the next plate goes into that cell and not into the
--- fourth. Loaded by control.lua: require("holderlists")(H).

local NET = "gregtorio-me-network"
local FROM, TO, EVERY = 30, 1400, 10
local BX, BY = 100, -100
local KEY = "iron-plate"

return function(H)
	local me_place, me_report = H.me_place, H.me_report
	local T = {}

	function T.setup(s)
		local fails = {}
		local what = "holder lists"
		local eei = me_place(s, fails, what, "electric-energy-interface", BX, BY)
		if eei then
			eei.power_production = 1e6
			eei.electric_buffer_size = 1e7
		end
		me_place(s, fails, what, "substation", BX + 3, BY)
		local ctrl = me_place(s, fails, what, "me-network-controller", BX + 7, BY)
		local drive = me_drive(s, fails, what, BX + 10, BY + 3, {}, "1k")
		me_connect(fails, what, { ctrl, drive })
		storage.holderlists59_scene = { ctrl = ctrl, drive = drive }
		return fails
	end

	--- the cursor case, in one tick (no visit in between); problems into `problems`
	local function cursor_case(problems)
		local sc = storage.holderlists59_scene
		if not (sc and sc.ctrl and sc.ctrl.valid and sc.drive and sc.drive.valid) then problems[#problems + 1] = "the cursor case's network was not built" return end
		local ctrl, drive = sc.ctrl, sc.drive
		local function cell(slot) return remote.call(NET, "drive", drive)[slot] end
		local function held(slot) local c = cell(slot) return c and c.items and c.items[KEY] or 0 end
		local function fill(slot)                              -- plates in until the cell is full
			for _ = 1, 1000 do
				local c = cell(slot)
				if not c or c.state == "full" then return end
				if remote.call(NET, "insert", ctrl, KEY, 100) == 0 then return end
			end
		end
		fill(1)
		fill(2)
		remote.call(NET, "insert", ctrl, KEY, 1)                -- the cursor passes the two full cells
		remote.call(NET, "extract", ctrl, KEY, held(1))          -- the first cell is emptied: it no longer holds the key
		if held(1) ~= 0 then problems[#problems + 1] = "the first cell still holds " .. held(1) .. " plates" return end
		fill(3)                                                   -- (what the third cell cannot take goes into the first)
		if held(1) == 0 then remote.call(NET, "insert", ctrl, KEY, 1) end   -- holders full: the first open cell starts holding it
		local h1 = held(1)
		if h1 == 0 then problems[#problems + 1] = "the first cell did not start holding the plates" return end
		local lists, bad, first = remote.call(NET, "check_holder_lists")
		if bad > 0 then problems[#problems + 1] = "cursor case: " .. tostring(first) end
		remote.call(NET, "insert", ctrl, KEY, 1)                -- a holder with room: the first cell, not the fourth
		if held(1) ~= h1 + 1 or held(4) ~= 0 then
			problems[#problems + 1] = "the next plate went elsewhere: first cell " .. held(1) .. ", fourth " .. held(4)
		end
	end

	function T.tick()
		local tick = game.tick
		local st = storage.holderlists59
		if not st then
			if tick < FROM then return end
			st = { problems = {}, done = false, rounds = 0, lists = 0 }
			storage.holderlists59 = st
		end
		if st.done or tick % EVERY ~= 0 then return end
		if not st.case then
			st.case = true
			cursor_case(st.problems)
		end
		local lists, bad, first = remote.call(NET, "check_holder_lists")
		st.rounds = st.rounds + 1
		st.lists = st.lists + lists
		if bad > 0 and #st.problems < 5 then
			st.problems[#st.problems + 1] = "tick " .. tick .. ": " .. bad .. " of " .. lists .. " lists or cursors differ: " .. tostring(first)
		end
		if tick >= TO then
			if st.lists == 0 then st.problems[#st.problems + 1] = "no kept list to check" end
			st.done = true
			me_report("HOLDERLISTS", "ME holder lists", st.problems, st.rounds .. " rounds, " .. st.lists .. " lists checked, the cursor case")
		end
	end

	function T.running(check) check(storage.holderlists59 and storage.holderlists59.done, "ME holder lists") end
	return T
end
