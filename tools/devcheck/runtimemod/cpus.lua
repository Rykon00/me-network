--- Runtime test of me-network issue #6 (docs/ME-REWORK.md "Crafting CPUs as multiblocks"): crafting CPUs built from
--- 1x1 crafting blocks. One network with two gear machines: the smallest CPU (one 1k crafting storage, A), a 3x2
--- rectangle with every block kind (4k and 1k storage, a unit, two co-processors, a monitor: B), a group that is no
--- rectangle (C) and one without storage (D). Checked: their status, bytes, speed and pictures, the bytes of a plan
--- (5 per gear + 24), a job too big for every CPU (refused, a level maintainer waits), two jobs at once on A and B, a
--- third one refused, a block removed during a job (it pauses, goes on on the rest of its CPU, cancelled: nothing
--- lost), a clone and a blueprint of a CPU (issue #145: the legacy CPU's case is gone with it). Loaded by control.lua: require("cpus")(H)
--- returns { setup, tick, running } like cards.lua.

local NET, AC, C = "gregtorio-me-network", "gregtorio-me-autocraft", "gregtorio-me-circuit"
local TERM, GUI = "gregtorio-me-terminal", "gregtorio-me-gui"
local X, Y = 300, -300
local GEAR, GEAR_RECIPE = "iron-gear-wheel", "iron-gear-crafting-table"
local PLATES, STICKS = 2000, 4000
local BIG = 1100                       -- gears: 5 * 1100 + 24 = 5524 bytes, more than B's 5120
--- B: 3x2 at tiles X+16..18, Y..Y+1 (top row: 4k storage, 1k storage, unit; bottom: two co-processors, monitor)
local B = {
	{ "me-4k-crafting-storage", 16, 0 }, { "me-1k-crafting-storage", 17, 0 }, { "me-crafting-unit", 18, 0 },
	{ "me-crafting-co-processing-unit", 16, 1 }, { "me-crafting-co-processing-unit", 17, 1 }, { "me-crafting-monitor", 18, 1 },
}

return function(H)
	local me_place, cable_row, power, me_report = H.me_place, H.cable_row, H.power, H.me_report
	local T = {}
	local function line(t) return serpent.line(t) end
	local function at(dx, dy) return { X + dx + 0.5, Y + dy + 0.5 } end      -- the centre of tile (X+dx, Y+dy)

	function T.setup(s)
		local fails = {}
		local what = "crafting CPUs"
		power(s, fails, what, X, Y)
		power(s, fails, what, X + 30, Y - 8)                                   -- the machines and the maintainer
		me_place(s, fails, what, "me-network-controller", X + 7, Y)          -- tiles X+6..7, Y-1..Y
		H.me_drive(s, fails, what, X + 8.5, Y - 0.5, { ["iron-plate"] = PLATES, ["iron-stick"] = STICKS })
		me_place(s, fails, what, "me-terminal", X + 9.5, Y - 0.5)
		cable_row(s, fails, X + 10, X + 60, Y - 1)
		for _, mx in pairs({ 30, 36 }) do
			me_place(s, fails, what, "me-pattern-provider", X + mx + 0.5, Y - 1.5)
			local m = me_place(s, fails, what, "me-molecular-assembler", X + mx + 0.5, Y - 2.5)
			if m then
				m.force.recipes[GEAR_RECIPE].enabled = true
				m.set_recipe(GEAR_RECIPE)
			end
		end
		me_place(s, fails, what, "me-level-maintainer", X + 40.5, Y - 1.5)
		--- A: one 1k crafting storage under the cable row
		me_place(s, fails, what, "me-1k-crafting-storage", X + 12.5, Y + 0.5)
		for _, b in ipairs(B) do me_place(s, fails, what, b[1], X + b[2] + 0.5, Y + b[3] + 0.5) end
		--- C: an L of three blocks (with storage); D: two units (no storage)
		me_place(s, fails, what, "me-1k-crafting-storage", X + 22.5, Y + 0.5)
		me_place(s, fails, what, "me-crafting-unit", X + 23.5, Y + 0.5)
		me_place(s, fails, what, "me-crafting-unit", X + 22.5, Y + 1.5)
		me_place(s, fails, what, "me-crafting-unit", X + 26.5, Y + 0.5)
		me_place(s, fails, what, "me-crafting-unit", X + 27.5, Y + 0.5)
		for _, mx in pairs({ 30, 36 }) do
			local p = s.find_entity("me-pattern-provider", { X + mx + 0.5, Y - 1.5 })
			if p then give_patterns(p, { { kind = "crafting", recipe = GEAR_RECIPE } }, fails) end
		end
		return fails
	end

	local function cpu_test()
		local st = storage.cpus6
		if (st and st.done) or game.tick < 90 then return end
		local s = game.surfaces[1]
		local function find(name, dx, dy) return s.find_entity(name, at(dx, dy)) end
		local t = find("me-terminal", 9, -1)
		if not st then
			st = { problems = {}, phase = "start" }
			storage.cpus6 = st
		end
		local problems = st.problems
		local function expect(ok, msg) if not ok then problems[#problems + 1] = msg end end
		local function finish()
			st.done = true
			me_report("CPUS6", "crafting CPU multiblocks", problems, "smallest CPU, every block kind, not a rectangle, "
				.. "no storage, plan bytes, too big (terminal and maintainer), two jobs, block removed during a job, clone, "
				.. "blueprint")
		end
		local function count(name) return remote.call(NET, "count", t, name) end
		local function info(e) return e and e.valid and remote.call(AC, "group_info", e) or {} end
		local function job(id) return remote.call(AC, "job", id) or {} end
		--- issue #152: every crafting block of the scene shows the picture of its neighbours and its group: variation
		--- 1 + mask (N 1, E 2, S 4, W 8: a crafting block on that side) + 16 * state (0 no CPU, 1 CPU, 2 CPU with a job)
		local block_names = { "me-crafting-unit", "me-1k-crafting-storage", "me-4k-crafting-storage", "me-16k-crafting-storage",
			"me-64k-crafting-storage", "me-256k-crafting-storage", "me-crafting-co-processing-unit", "me-crafting-monitor" }
		local function check_pictures(tag)
			local n = 0
			for _, e in pairs(s.find_entities_filtered{ area = { { X - 1, Y - 3 }, { X + 60, Y + 6 } }, name = block_names }) do
				local mask = 0
				for bit, d in ipairs({ { 0, -1 }, { 1, 0 }, { 0, 1 }, { -1, 0 } }) do
					local o = s.find_entities_filtered{ position = { e.position.x + d[1], e.position.y + d[2] }, radius = 0.3, name = block_names }
					if #o > 0 then mask = mask + 2 ^ (bit - 1) end
				end
				local gi = info(e)
				local state = gi.status ~= "ok" and 0 or gi.job and 2 or 1
				local want = 1 + mask + 16 * state
				n = n + 1
				expect(e.graphics_variation == want, tag .. ": " .. e.name .. " at " .. e.position.x .. "," .. e.position.y .. " shows "
					.. e.graphics_variation .. ", expected " .. want .. " (mask " .. mask .. ", state " .. state .. ")")
			end
			expect(n >= 1, tag .. ": no crafting block found")
		end
		local function conserved(what)
			local gears = count(GEAR)
			expect(count("iron-plate") + gears == PLATES and count("iron-stick") + 2 * gears == STICKS,
				what .. ": plates " .. count("iron-plate") .. ", sticks " .. count("iron-stick") .. ", gears " .. gears)
		end
		local a, b1 = find("me-1k-crafting-storage", 12, 0), find("me-4k-crafting-storage", 16, 0)

		if st.phase == "start" then
			if not (t and a and b1) then problems[#problems + 1] = "entities missing" return finish() end
			local ia, ib = info(a), info(b1)
			expect(ia.status == "ok" and ia.bytes == 1024 and ia.blocks == 1 and ia.speed == 1 and ia.network and ia.working,
				"the smallest CPU: " .. line(ia))
			check_pictures("start")
			expect(a.graphics_variation == 17, "a lone CPU block shows the lit picture with all four frames: " .. a.graphics_variation)
			expect(ib.status == "ok" and ib.bytes == 5120 and ib.blocks == 6 and ib.width == 3 and ib.height == 2
				and ib.coprocessors == 2 and ib.speed == 3 and ib.monitors == 1, "the rectangle of every block kind: " .. line(ib))
			local ic, id = info(find("me-crafting-unit", 22, 1)), info(find("me-crafting-unit", 26, 0))
			expect(ic.status == "not-rectangle" and ic.blocks == 3 and ic.bytes == 1024, "the L: " .. line(ic))
			expect(id.status == "no-storage" and id.blocks == 2, "the units: " .. line(id))
			expect(find("me-crafting-unit", 22, 1).graphics_variation <= 16, "a block of no CPU shows a dark picture")
			local n, free, powered, slots = remote.call(AC, "cpus", t)
			expect(n == 2 and free == 2 and powered == 2 and slots == 2, "CPUs of the network (only A and B): " .. n .. " " .. free .. " " .. powered .. " " .. slots)
			local plan = remote.call(AC, "plan", t, GEAR, 150)
			expect(plan and plan.ok and plan.bytes == 5 * 150 + 24, "the plan of 150 gears: " .. line(plan and plan.bytes))
			--- part 2: the plan preview names the bytes and the CPUs (A and B fit 774 bytes, B alone 1524, none 5524)
			local pv = remote.call(TERM, "craft_preview", t, GEAR, 150)
			expect(pv.ok and pv.bytes == 774 and #pv.cpu_list == 2 and pv.cpu_list[1].fits and pv.cpu_list[1].free
				and pv.cpu_list[1].bytes == 1024 and pv.cpu_list[2].bytes == 5120, "preview of 150 gears: " .. line(pv.cpu_list))
			pv = remote.call(TERM, "craft_preview", t, GEAR, 300)
			expect(pv.ok and not pv.cpu_list[1].fits and pv.cpu_list[2].fits, "preview of 300 gears: " .. line(pv.cpu_list))
			pv = remote.call(TERM, "craft_preview", t, GEAR, BIG)
			expect(not pv.ok and pv.reason == "cpu-too-small" and pv.biggest == 5120, "preview of a job too big: " .. line({ pv.reason, pv.biggest }))
			expect(remote.call(GUI, "has_window", a), "a crafting block opens no window")
			--- issue #28: shift + click in a crafting block's window stores the stack in the network
			local pinv = game.create_inventory(2)
			pinv[1].set_stack{ name = "stone", count = 3 }
			local s0 = count("stone")
			local w = remote.call(GUI, "inventory_click", pinv[2], pinv, 1, "shift", a)
			expect(w == nil and count("stone") == s0 + 3 and not pinv[1].valid_for_read, "shift + click in a crafting block's window: " .. tostring(w))
			pinv.destroy()
			--- issue #151: the window's title is the CPU's, whichever of its blocks was clicked (storage, unit, monitor); a group
			--- that is no CPU is "Crafting blocks"
			local function title(name, x, y) return remote.call(GUI, "crafting_cpu_title", find(name, x, y)) end
			local t1, t2, t3 = title("me-4k-crafting-storage", 16, 0), title("me-crafting-unit", 18, 0), title("me-crafting-monitor", 18, 1)
			expect(t1[1] == "fork-me-gui.ccpu-title" and t1[2] == ib.id and line(t1) == line(t2) and line(t2) == line(t3),
				"the title of one CPU from three blocks: " .. line({ t1, t2, t3 }) .. " id " .. tostring(ib.id))
			local parts = remote.call(GUI, "crafting_cpu_data", find("me-4k-crafting-storage", 16, 0)).parts
			local total = 0
			for _, part in ipairs(parts or {}) do total = total + part.count end
			expect(parts and #parts >= 3 and total == ib.blocks, "the blocks of the CPU by type (issue #151): " .. line(parts))
			local tl = title("me-crafting-unit", 22, 1)
			expect(tl[1] == "fork-me-gui.ccpu-title-none", "the title of an L: " .. line(tl))
			local wd = remote.call(GUI, "crafting_cpu_data", find("me-crafting-unit", 22, 1))
			expect(wd and wd.status == "not-rectangle" and wd.width == 2 and wd.height == 2, "the window data of the L: " .. line(wd))
			--- too big for every CPU: refused, nothing taken; a level maintainer waits
			local id1, why, _, bytes, biggest = remote.call(AC, "start", t, GEAR, BIG)
			expect(id1 == nil and why == "cpu-too-small" and bytes == 5 * BIG + 24 and biggest == 5120,
				"a job too big for every CPU: " .. line({ id1, why, bytes, biggest }))
			conserved("after the refused job")
			st.maint = find("me-level-maintainer", 40, -2)
			expect(remote.call(C, "set_maintainer", st.maint, GEAR, BIG, false), "set_maintainer")
			st.phase, st.tick = "maintainer", game.tick
			return
		end

		if st.phase == "maintainer" then
			local m = remote.call(C, "get_maintainer", st.maint) or {}
			if m.status ~= "cpu-too-small" and game.tick < st.tick + 120 then return end
			expect(m.status == "cpu-too-small" and not m.job, "the maintainer with a job too big: " .. line(m))
			remote.call(C, "set_maintainer", st.maint, false)
			conserved("after the maintainer")
			--- two jobs at once: the small one takes A (the smallest CPU that fits), the next one B; a third is refused
			local ja, why_a = remote.call(AC, "start", t, GEAR, 10)
			local jb, why_b = remote.call(AC, "start", t, GEAR, 20)
			local jc, why_c = remote.call(AC, "start", t, GEAR, 5)
			expect(ja and jb, "two jobs did not start: " .. tostring(why_a) .. " " .. tostring(why_b))
			expect(jc == nil and why_c == "no-free-cpu", "a third job: " .. line({ jc, why_c }))
			if not (ja and jb) then return finish() end
			local xa, xb = job(ja), job(jb)
			expect(xa.group == info(a).id and xa.ops == 6 and xa.bytes == 74, "job A: " .. line({ xa.group, xa.ops, xa.bytes }))
			expect(xb.group == info(b1).id and xb.ops == 18, "job B on the co-processor CPU: " .. line({ xb.group, xb.ops }))
			expect(info(b1).used == 124 and info(b1).job and info(b1).job.id == jb, "B's window data: " .. line(info(b1)))
			local mon = remote.call(AC, "monitor", find("me-crafting-monitor", 18, 1))
			expect(mon and mon.sprite == "item/" .. GEAR and mon.text == "20" and mon.job == jb, "the monitor: " .. line(mon))
			local pv = remote.call(TERM, "craft_preview", t, GEAR, 5)
			expect(not pv.ok and pv.reason == "no-free-cpu", "preview while both CPUs run: " .. line({ pv.reason }))
			check_pictures("two jobs running")
			st.ja, st.jb, st.phase, st.tick = ja, jb, "two", game.tick
			return
		end

		if st.phase == "two" then
			local xa, xb = job(st.ja), job(st.jb)
			if xa.leases and xb.leases and xa.leases > 0 and xb.leases > 0 then st.overlap = true end
			--- issue #140: the monitor shows what job B still has to make (20 gears, one per craft): the amount less the finished
			--- crafts, whenever it is looked at (a job whose machines make everything in one batch jumps from 20 to nothing)
			local mon = remote.call(AC, "monitor", find("me-crafting-monitor", 18, 1))
			if mon and tonumber(mon.text) then
				expect(tonumber(mon.text) == 20 - xb.done, "the monitor shows " .. mon.text .. " with " .. xb.done .. " of 20 crafts done")
				if xb.done > 0 and xb.done < 20 then st.mon_counted = (st.mon_counted or 0) + 1 end
			end
			local function over(j) return j.status == "done" or j.status == "failed" or j.status == "cancelled" end
			if not (over(xa) and over(xb)) then
				if game.tick > st.tick + 900 then problems[#problems + 1] = "the two jobs did not end: " .. line({ xa.status, xb.status }) return finish() end
				return
			end
			expect(xa.status == "done" and xb.status == "done", "the two jobs ended as " .. xa.status .. ", " .. xb.status)
			expect(st.overlap, "the two jobs never had a machine crafting at the same time")
			expect(remote.call(AC, "monitor", find("me-crafting-monitor", 18, 1)) == nil, "the monitor still shows the ended job")
			--- (vanilla: the job is part done for a while; with Gregtorio its fast machines make all 20 in one batch)
			expect(script.active_mods["gregtorio-continued"] or (st.mon_counted or 0) >= 1, "the monitor was never looked at while the job was part done")
			expect(count(GEAR) == 30, "gears after the two jobs: " .. count(GEAR))
			conserved("after the two jobs")
			check_pictures("after the two jobs")
			--- a job that only B can take (300 gears: 1524 bytes)
			local jf, why = remote.call(AC, "start", t, GEAR, 300)
			expect(jf and job(jf).group == info(b1).id, "the big job is not on B: " .. tostring(why))
			if not jf then return finish() end
			st.jf, st.phase, st.tick = jf, "running", game.tick
			return
		end

		if st.phase == "running" then
			local xf = job(st.jf)
			if not ((xf.leases or 0) > 0 or (xf.done or 0) > 0) then
				if game.tick > st.tick + 200 then problems[#problems + 1] = "the big job does not run" return finish() end
				return
			end
			--- a block of its CPU removed: the group is no rectangle, the job pauses with everything it holds
			find("me-crafting-unit", 18, 0).destroy{ raise_destroy = true }
			local ib = info(b1)
			expect(ib.status == "not-rectangle" and ib.blocks == 5, "B without a corner: " .. line(ib))
			xf = job(st.jf)
			expect(xf.status == "queued" and not xf.group, "the job did not pause: " .. line({ xf.status, xf.group }))
			check_pictures("B without a corner")
			--- the column completed away: the rest is a 2x2 CPU with 5120 bytes, the job goes on there
			find("me-crafting-monitor", 18, 1).destroy{ raise_destroy = true }
			ib = info(b1)
			expect(ib.status == "ok" and ib.blocks == 4 and ib.bytes == 5120 and ib.monitors == 0, "the rest of B: " .. line(ib))
			check_pictures("the rest of B")
			st.phase, st.tick = "paused", game.tick
			return
		end

		if st.phase == "paused" then
			local xf = job(st.jf)
			if not (xf.status == "running" and xf.group) then
				if game.tick > st.tick + 100 then problems[#problems + 1] = "the paused job did not go on: " .. line({ xf.status, xf.wait }) return finish() end
				return
			end
			expect(xf.group == info(b1).id, "the job went on on another CPU: " .. tostring(xf.group))
			remote.call(AC, "cancel", st.jf)
			st.phase, st.tick = "cancel", game.tick
			return
		end

		if st.phase == "cancel" then
			local xf = job(st.jf)
			if xf.status ~= "cancelled" then
				if game.tick > st.tick + 600 then problems[#problems + 1] = "the cancelled job did not end: " .. tostring(xf.status) return finish() end
				return
			end
			conserved("after the cancelled job")
			--- B rebuilt; then a clone of B and a blueprint of B form CPUs of their own
			me_place(s, problems, "rebuild", "me-crafting-unit", X + 18.5, Y + 0.5)
			me_place(s, problems, "rebuild", "me-crafting-monitor", X + 18.5, Y + 1.5)
			local ib = info(b1)
			expect(ib.status == "ok" and ib.blocks == 6 and ib.bytes == 5120 and ib.monitors == 1, "B rebuilt: " .. line(ib))
			check_pictures("B rebuilt")
			local originals = {}
			for _, b in ipairs(B) do originals[#originals + 1] = find(b[1], b[2], b[3]) end
			s.clone_entities{ entities = originals, destination_offset = { 30, 0 } }
			local ik = info(find("me-4k-crafting-storage", 46, 0))
			expect(ik.status == "ok" and ik.blocks == 6 and ik.bytes == 5120 and ik.coprocessors == 2 and ik.id ~= ib.id,
				"the clone of B: " .. line(ik))
			local inv = game.create_inventory(1)
			inv.insert{ name = "blueprint" }
			local bp = inv[1]
			bp.create_blueprint{ surface = s, force = "player", area = { { X + 16.1, Y + 0.1 }, { X + 18.9, Y + 1.9 } } }
			local ghosts = bp.build_blueprint{ surface = s, force = "player", position = { X + 53.5, Y + 1 } }
			for _, g in pairs(ghosts) do if g.valid then g.revive{ raise_revive = true } end end
			inv.destroy()
			local blocks = s.find_entities_filtered{ area = { { X + 51, Y }, { X + 57, Y + 2 } }, name = "me-crafting-co-processing-unit" }
			local ip = info(blocks[1])
			expect(#ghosts == 6 and ip.status == "ok" and ip.blocks == 6 and ip.bytes == 5120 and ip.coprocessors == 2,
				"the blueprint of B: " .. #ghosts .. " ghosts, " .. line(ip))
			conserved("at the end")
			return finish()
		end
	end

	function T.tick() cpu_test() end
	function T.running(check) check(storage.cpus6 and storage.cpus6.done, "crafting CPU multiblocks") end
	return T
end
