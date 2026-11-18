--- Runtime test of me-network issue #750: the most one crafting order may ask for. It was 100 000 items (10 000 000 fluid
--- units), refused with "That amount is too large" only when Craft was pressed; it is 2 147 483 647 now and the plan line
--- names it. A network with four ME Singularity Storage Cells (3 000 000 000 iron plates, 5 000 000 000 iron sticks), a
--- Crafting CPU with ME Singularity Crafting Storage and an ME Molecular Assembler with the gear pattern (1 plate + 2
--- sticks):
--- * an order of the limit + 1 is refused ("too-many"), by the start and by the tab's preview (before a click);
--- * an order of 100 001 (refused before) is planned by the preview;
--- * an order of the limit starts: the job's amount and runs are the number exactly, its pool holds exactly that many
---   plates and twice as many sticks, the network has exactly that much less, the bytes are what the rule gives;
--- * it runs: after RUN ticks gears were made;
--- * cancelled, everything comes back: plates + gears and sticks + 2 * gears are the numbers of the start, to the item.
--- Loaded by control.lua: require("orderlimit")(H) returns { setup, tick, running }.

local AC, PT, TERM, NET = "gregtorio-me-autocraft", "gregtorio-me-pattern-terminal", "gregtorio-me-terminal", "gregtorio-me-network"
local BX, BY = 700, -100
local START, RUN, SETTLE, TIMEOUT = 110, 400, 200, 1500
local GEAR = "iron-gear-crafting-table"
local LIMIT = 2147483647
local PLATES, STICKS = 3000000000, 5000000000

return function(H)
	local me_place, me_report, power = H.me_place, H.me_report, H.power
	local T = {}

	function T.setup(s)
		local fails = {}
		local what = "order limit"
		local tiles = {}
		for x = BX - 4, BX + 24 do
			for y = BY - 4, BY + 12 do tiles[#tiles + 1] = { name = "grass-1", position = { x, y } } end
		end
		s.set_tiles(tiles)
		power(s, fails, what, BX, BY)
		me_place(s, fails, what, "substation", BX + 20, BY + 5)
		local ctrl = me_place(s, fails, what, "me-network-controller", BX + 7, BY)
		local drive = me_drive(s, fails, what, BX + 8.5, BY - 0.5, {}, "singularity")
		local cpu
		for i, d in ipairs({ { -0.5, -0.5 }, { 0.5, -0.5 }, { -0.5, 0.5 }, { 0.5, 0.5 } }) do
			local e = me_place(s, fails, what, i == 1 and "me-singularity-crafting-storage" or "me-crafting-unit", BX + 11 + d[1], BY + d[2])
			if i == 1 then cpu = e end
		end
		local prov = me_place(s, fails, what, "me-pattern-provider", BX + 14.5, BY + 5.5)
		local asm = me_place(s, fails, what, "me-molecular-assembler", BX + 15.5, BY + 5.5)
		if asm then asm.force.recipes[GEAR].enabled = true end
		me_connect(fails, what, { ctrl, drive, cpu, prov })
		storage.orderlimit750_scene = { ctrl = ctrl, prov = prov, asm = asm }
		return fails
	end

	function T.tick()
		local tick = game.tick
		local st = storage.orderlimit750
		if not st then
			if tick < START then return end
			st = { problems = {}, done = false, phase = "start" }
			storage.orderlimit750 = st
		end
		if st.done then return end
		local problems = st.problems
		local function expect(ok, text) if not ok then problems[#problems + 1] = text end end
		local function finish(note)
			st.done = true
			me_report("ORDERLIMIT", "the limit of a crafting order (issue #750)", problems, note)
		end
		local sc = storage.orderlimit750_scene
		if not (sc and sc.ctrl and sc.ctrl.valid and sc.prov and sc.prov.valid and sc.asm and sc.asm.valid) then
			expect(false, "the entities were not built")
			return finish()
		end
		local function count(name) return remote.call(NET, "count", sc.ctrl, name) end
		local function n(v) return string.format("%.0f", v or -1) end

		if st.phase == "start" then
			local inv = game.create_inventory(2)
			inv.insert{ name = "me-blank-pattern", count = 1 }
			local where, why = remote.call(PT, "encode_def", inv, nil, { kind = "crafting", recipe = GEAR })
			local stack = inv.find_item_stack("me-encoded-pattern")
			expect(where and stack and remote.call(AC, "insert_pattern", sc.prov, stack), "no gear pattern: " .. tostring(why))
			inv.destroy()
			--- (one insert per item: the harness's store_in_drive goes stack by stack, 30 million calls for this stock)
			local got_p = remote.call(NET, "insert", sc.ctrl, "iron-plate", PLATES)
			local got_s = remote.call(NET, "insert", sc.ctrl, "iron-stick", STICKS)
			expect(got_p == PLATES and got_s == STICKS, "the network took " .. n(got_p) .. " plates and " .. n(got_s) .. " sticks")
			st.phase, st.at = "order", tick + 60
			return
		end
		if st.phase == "order" then
			if tick < st.at then return end
			expect(count("iron-plate") == PLATES and count("iron-stick") == STICKS, "the stock: " .. n(count("iron-plate")) .. " plates, "
				.. n(count("iron-stick")) .. " sticks")
			local id, why = remote.call(AC, "start", sc.ctrl, "iron-gear-wheel", LIMIT + 1)
			expect(id == nil and why == "too-many", "an order of the limit + 1: " .. tostring(id) .. " " .. tostring(why))
			local p = remote.call(TERM, "craft_preview", sc.ctrl, "iron-gear-wheel", LIMIT + 1)
			expect(p and p.ok == false and p.reason == "too-many", "the preview of the limit + 1: " .. tostring(p and p.reason))
			p = remote.call(TERM, "craft_preview", sc.ctrl, "iron-gear-wheel", 100001)
			expect(p and p.ok == true and p.runs == 100001, "the preview of 100 001: " .. tostring(p and p.reason) .. ", runs " .. tostring(p and p.runs))
			p = remote.call(TERM, "craft_preview", sc.ctrl, "iron-gear-wheel", LIMIT)
			expect(p and p.ok == true and p.runs == LIMIT, "the preview of the limit: " .. tostring(p and p.reason) .. ", runs " .. n(p and p.runs))
			local bytes
			id, why, _, bytes = remote.call(AC, "start", sc.ctrl, "iron-gear-wheel", LIMIT)
			expect(id ~= nil, "an order of the limit did not start: " .. tostring(why))
			if not id then return finish() end
			st.job = id
			local job = remote.call(AC, "job", id)
			expect(job and job.amount == LIMIT and job.total == LIMIT, "the job's amount and runs: " .. n(job and job.amount) .. ", "
				.. n(job and job.total))
			--- the bytes rule: the amount, 8 per step and per resource taken, per step its runs and the ingredients of all its runs
			local want = LIMIT + 8 * (1 + 2) + LIMIT + 3 * LIMIT
			expect(bytes == want and job and job.bytes == want, "the job's bytes: " .. n(bytes) .. ", expected " .. n(want))
			expect(count("iron-plate") == PLATES - LIMIT and count("iron-stick") == STICKS - 2 * LIMIT, "taken from the network: "
				.. n(count("iron-plate")) .. " plates and " .. n(count("iron-stick")) .. " sticks are left")
			st.phase, st.at = "run", tick + RUN
			return
		end
		if st.phase == "run" then
			if tick < st.at then return end
			local job = remote.call(AC, "job", st.job)
			st.made = count("iron-gear-wheel")
			expect(job and job.status == "running" and (job.done or 0) > 0 and st.made > 0, "after " .. RUN .. " ticks: status "
				.. tostring(job and job.status) .. ", runs done " .. n(job and job.done) .. ", gears " .. n(st.made))
			expect(remote.call(AC, "cancel", st.job), "the job could not be cancelled")
			st.phase, st.at, st.deadline = "settle", tick + SETTLE, tick + TIMEOUT
			return
		end
		if st.phase == "settle" then
			if tick < st.at then return end
			local gears, plates, sticks = count("iron-gear-wheel"), count("iron-plate"), count("iron-stick")
			local back = plates + gears == PLATES and sticks + 2 * gears == STICKS
			if not back and tick < st.deadline then st.at = tick + 60 return end
			expect(back, "after the cancel: " .. n(plates) .. " plates, " .. n(sticks) .. " sticks, " .. n(gears) .. " gears (plates + gears "
				.. n(plates + gears) .. ", sticks + 2 gears " .. n(sticks + 2 * gears) .. ")")
			return finish("limit " .. n(LIMIT) .. ": refused above it, started at it, " .. n(st.made) .. " gears after " .. RUN
				.. " ticks, " .. n(gears) .. " at the end, everything back after the cancel")
		end
	end

	function T.running(check) check(storage.orderlimit750 and storage.orderlimit750.done, "the limit of a crafting order") end

	return T
end
