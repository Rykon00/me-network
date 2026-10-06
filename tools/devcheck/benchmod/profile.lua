--- devcheck.py bench --profile: put at the top of control.lua of an instrumented COPY of me-network (in
--- .devcheck/bench-profile; the mod itself never contains it). devcheck.py wraps selected functions of the copy's
--- modules with __BENCH_WRAP (a line `name = __BENCH_WRAP("module.name", name)` before each module's final
--- `return M`; local functions are wrapped through their upvalue) and every script.on_nth_tick handler with
--- __BENCH_NTH. While the benchmark mod has the profiler on (remote zz-me-bench-profile), each wrapped call is timed
--- with a LuaProfiler: inclusive time (callees included) and the number of calls; a recursive call counts, its time is
--- in the outer one. `--exclusive` (issue #122, __BENCH.exclusive): each function's own time instead, a wrapped callee stops
--- its caller's timer (a stack); with --alloc its own allocation too. The wrapper's own cost then falls on the caller (the
--- report's overhead per call).
__BENCH = { sections = {}, on = false }
local XSTACK = {}

--- exclusive mode: `sec` leaves the stack, its caller's timer (and memory count) goes on
local function xfinish(sec, ...)
	sec.stop()
	if __BENCH.alloc then sec.kb = sec.kb + (collectgarbage("count") - sec.m0) end
	XSTACK[#XSTACK] = nil
	local top = XSTACK[#XSTACK]
	if top then
		if __BENCH.alloc then top.m0 = collectgarbage("count") end
		top.restart()
	end
	return ...
end

local function finish(sec, p, m0, ...)
	sec.tstop()
	sec.add(p)
	sec.depth = 0
	if m0 then sec.kb = sec.kb + (collectgarbage("count") - m0) end     -- (alloc mode: the collector is stopped)
	return ...
end

function __BENCH_WRAP(name, f)
	if type(f) ~= "function" then return f end
	local sec = { name = name, n = 0, depth = 0 }
	__BENCH.sections[#__BENCH.sections + 1] = sec
	return function(...)
		if not __BENCH.on then return f(...) end
		sec.n = sec.n + 1
		if __BENCH.exclusive then
			local top = XSTACK[#XSTACK]
			if top then
				top.stop()
				if __BENCH.alloc then top.kb = top.kb + (collectgarbage("count") - top.m0) end
			end
			XSTACK[#XSTACK + 1] = sec
			if __BENCH.alloc then sec.m0 = collectgarbage("count") end
			sec.restart()
			return xfinish(sec, f(...))
		end
		if sec.depth > 0 then return f(...) end
		sec.depth = 1
		local p = sec.tmp
		sec.treset()
		local m0 = __BENCH.alloc and collectgarbage("count") or nil
		return finish(sec, p, m0, f(...))
	end
end

function __BENCH_NTH(n, f)
	return script.on_nth_tick(n, f and __BENCH_WRAP("on_nth_tick(" .. tostring(n) .. ")", f) or f)
end
