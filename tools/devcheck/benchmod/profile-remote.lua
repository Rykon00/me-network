
--- devcheck.py bench --profile (appended to the instrumented copy's control.lua): the benchmark mod turns the
--- timers on at the first probe and has them reported at the second
local BENCH_N = require("scripts.fork-me-network")
remote.add_interface("zz-me-bench-profile", {
	enable = function(alloc, exclusive)
		for _, sec in pairs(__BENCH.sections) do
			sec.total, sec.tmp, sec.n, sec.depth, sec.kb = game.create_profiler(true), game.create_profiler(true), 0, 0, 0
			--- (the profilers' methods bound once: reading a method makes a new object, 88 bytes, issue #122)
			sec.stop, sec.restart, sec.add = sec.total.stop, sec.total.restart, sec.total.add
			sec.tstop, sec.treset = sec.tmp.stop, sec.tmp.reset
		end
		__BENCH.alloc = alloc and true or false
		__BENCH.exclusive = exclusive and true or false
		if alloc then collectgarbage("stop") end
		__BENCH.on = true
	end,
	report = function()
		__BENCH.on = false
		if __BENCH.alloc then collectgarbage("restart") end
		for _, sec in pairs(__BENCH.sections) do
			if sec.n > 0 then log({ "", "DEVCHECK-BENCH-PROF ", sec.name, " ", sec.n, " ", sec.total }) end
			if __BENCH.alloc and sec.n > 0 then log("DEVCHECK-BENCH-ALLOC " .. sec.name .. " " .. sec.n .. " " .. string.format("%.1f", sec.kb)) end
		end
		__BENCH.alloc = false
		--- what one wrapper adds to the time of its caller (an empty function, wrapped and not)
		local plain = function() end
		local wrapped = __BENCH_WRAP("calibration", plain)
		local sec = __BENCH.sections[#__BENCH.sections]
		sec.total, sec.tmp = game.create_profiler(true), game.create_profiler(true)
		sec.stop, sec.restart, sec.add = sec.total.stop, sec.total.restart, sec.total.add
		sec.tstop, sec.treset = sec.tmp.stop, sec.tmp.reset
		sec.n, sec.depth, sec.kb = 0, 0, 0
		__BENCH.on = true
		local a = game.create_profiler()
		for _ = 1, 20000 do wrapped() end
		a.stop()
		local b = game.create_profiler()
		for _ = 1, 20000 do plain() end
		b.stop()
		__BENCH.on = false
		a.divide(20000)
		b.divide(20000)
		log({ "", "DEVCHECK-BENCH-PROF-OVERHEAD wrapped ", a, " plain ", b })
	end,
	--- the storage API of the network of `entity`, called directly (µs per call in the log); `chest` for extract_to
	storage = function(entity, chest, item, fluid)
		local N = BENCH_N
		local net = N.network_of(entity)
		if not net then return end
		local inv = chest.get_inventory(defines.inventory.chest)
		local function time(name, n, f)
			local p = game.create_profiler()
			for i = 1, n do f(i) end
			p.stop()
			p.divide(n)
			log({ "", "DEVCHECK-BENCH-ENGINE storage API: ", name, " ", n, " ", p })
		end
		time("count", 2000, function() return N.count(net, item, "normal") end)
		time("insert 10 + extract 10 (" .. item .. ")", 1000, function()
			local k = N.insert(net, item, "normal", 10)
			N.extract(net, item, "normal", k)
		end)
		time("can_insert 1000 (" .. item .. ")", 1000, function() return N.can_insert(net, item, "normal", 1000) end)
		time("can_insert 1000 (a new item type)", 1000, function() return N.can_insert(net, "zz-bench-warehouse", "normal", 1000) end)
		time("extract_to a chest 10 + insert back", 1000, function()
			local k = N.extract_to(net, inv, item, 10)
			if k > 0 then
				inv.remove{ name = item, count = k }
				N.insert(net, item, "normal", k)
			end
		end)
		time("can_insert_fluid 1000 (" .. fluid .. ")", 1000, function() return N.can_insert_fluid(net, fluid, 1000) end)
		time("insert_fluid 100 + extract_fluid 100 (" .. fluid .. ")", 1000, function()
			local k = N.insert_fluid(net, fluid, 100)
			N.extract_fluid(net, fluid, k)
		end)
	end,
})
