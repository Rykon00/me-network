--- devcheck.py bench --profile: put at the top of control.lua of an instrumented COPY of me-network (in
--- .devcheck/bench-profile; the mod itself never contains it). devcheck.py wraps selected functions of the copy's
--- modules with __BENCH_WRAP (a line `name = __BENCH_WRAP("module.name", name)` before each module's final
--- `return M`; local functions are wrapped through their upvalue) and every script.on_nth_tick handler with
--- __BENCH_NTH. While the benchmark mod has the profiler on (remote zz-me-bench-profile), each wrapped call is timed
--- with a LuaProfiler: inclusive time (callees included) and the number of calls; a recursive call counts, its time is
--- in the outer one.
__BENCH = { sections = {}, on = false }

local function finish(sec, p, ...)
	p.stop()
	sec.total.add(p)
	sec.depth = 0
	return ...
end

function __BENCH_WRAP(name, f)
	if type(f) ~= "function" then return f end
	local sec = { name = name, n = 0, depth = 0 }
	__BENCH.sections[#__BENCH.sections + 1] = sec
	return function(...)
		if not __BENCH.on then return f(...) end
		sec.n = sec.n + 1
		if sec.depth > 0 then return f(...) end
		sec.depth = 1
		local p = sec.tmp
		p.reset()
		return finish(sec, p, f(...))
	end
end

function __BENCH_NTH(n, f)
	return script.on_nth_tick(n, f and __BENCH_WRAP("on_nth_tick(" .. tostring(n) .. ")", f) or f)
end
