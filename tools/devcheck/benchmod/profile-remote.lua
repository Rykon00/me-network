
--- devcheck.py bench --profile (appended to the instrumented copy's control.lua): the benchmark mod turns the
--- timers on at the first probe and has them reported at the second
remote.add_interface("zz-me-bench-profile", {
	enable = function()
		for _, sec in pairs(__BENCH.sections) do
			sec.total, sec.tmp, sec.n, sec.depth = game.create_profiler(true), game.create_profiler(true), 0, 0
		end
		__BENCH.on = true
	end,
	report = function()
		__BENCH.on = false
		for _, sec in pairs(__BENCH.sections) do
			if sec.n > 0 then log({ "", "DEVCHECK-BENCH-PROF ", sec.name, " ", sec.n, " ", sec.total }) end
		end
		--- what one wrapper adds to the time of its caller (an empty function, wrapped and not)
		local plain = function() end
		local wrapped = __BENCH_WRAP("calibration", plain)
		local sec = __BENCH.sections[#__BENCH.sections]
		sec.total, sec.tmp = game.create_profiler(true), game.create_profiler(true)
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
})
