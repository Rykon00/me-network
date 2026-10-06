--------------------------------------------------------------------------------
--- ME NETWORK: THE IN-GAME DIAGNOSTIC (issue #38, part 3): the command /me-stats
---   * `/me-stats`: the network of the ME block the player has open, else the nearest ME block within 10 tiles:
---     its members by kind, how many interfaces and buses are busy, probing or parked (and why), the level
---     maintainers the same way, the crafting CPUs and jobs; then the scheduler's work of the whole map over the last
---     minute (visits per tick against the budget, probes, backlog, starved arrivals, missed wakes, wakes, and the
---     time between two visits of a block that had work). `/me-stats all`: one line per network.
---   * It costs nothing while it is not used: the counters are the scheduler's (fork-me-schedule.lua, copied once per
---     3600 ticks for the window); the walk over a network's members runs inside the command. Nothing here is saved
---     or decides anything: the counters differ between the peers of a game, each player sees their own.
---   * `gregtorio-me-stats` (remote): `report(entity)` the data of a network, `window()` the scheduler's window,
---     `run(entity, parameter)` the lines the command prints, `mark(tick)` (tests).
--------------------------------------------------------------------------------

local N = require("scripts.fork-me-network")
local Sched = require("scripts.fork-me-schedule")
local AC = require("scripts.fork-me-autocraft")

local M = {}

local RADIUS = 10                    -- tiles around the player for the nearest ME block
local MAX_NETWORKS = 25              -- lines of `/me-stats all`
local PER_LINE = 7                   -- kinds per line of the member list

--- the kinds of members in the order they are listed (a kind not named here comes last, by name)
local KIND_ORDER = { "controller", "cable", "underground", "drive", "terminal", "interface", "import-bus", "export-bus",
	"storage-bus", "fluid-interface", "fluid-import-bus", "fluid-export-bus", "fluid-storage-bus", "provider", "pattern-terminal", "maintainer",
	"circuit", "cpu", "crafting" }
local KNOWN = {}
for i, k in ipairs(KIND_ORDER) do KNOWN[k] = i end

--- the blocks whose visits the I/O scheduler runs
local IO_KINDS = { interface = true, ["import-bus"] = true, ["export-bus"] = true }

--- the queues of the scheduler as the counters name them: label, the settings of its budget (floor, ceiling) or the
--- rate per second, and the counters of its probe list
local QUEUES = {
	{ name = "io", floor = "io", ceiling = "io_max", probe = "io_probe" },
	{ name = "storage_bus", floor = "storage_bus", ceiling = "storage_bus_max", probe = "storage_bus_probe" },
	{ name = "fluid_storage_bus", floor = "storage_bus", ceiling = "storage_bus_max", probe = "fluid_storage_bus_probe" },
	{ name = "maintainer", floor = "maintainer", ceiling = "maintainer_max", probe = "maintainer_probe" },
	{ name = "circuit", rate = "circuit" },
	{ name = "jobs", floor = "jobs", ceiling = "jobs_max" },
}

--- how a scheduled block stands: busy (in the busy list), probing (blocked on its target's side: one cheap check
--- now and then, `rec.block` says why) or parked (blocked on the network's side, `rec.park` says why)
local function standing(rec)
	if rec.park then return "parked", rec.park end
	if rec.sq then return "probing", rec.block or "?" end
	return "busy"
end

local function tally(into, rec)
	local how, why = standing(rec)
	into[how] = (into[how] or 0) + 1
	if why then
		local by = into[how .. "_by"]
		if not by then
			by = {}
			into[how .. "_by"] = by
		end
		by[why] = (by[why] or 0) + 1
	end
end

--- the data of a network: { id, status, members, surface, kinds = { kind = n }, io = { busy, probing, parked,
--- probing_by = { why = n }, parked_by }, maintainers = {...}, cpus, cpus_busy, jobs_running, jobs_queued }
function M.report(net)
	local snet = storage.fork_me_net
	local io_s = storage.fork_me_io
	local ae = storage.fork_ae2
	local out = { id = net.id, members = net.n, kinds = {}, io = {}, maintainers = {} }
	local ok, why = N.usable(net)
	out.status = ok and "ok" or (why or "?")
	for unit in pairs(net.nodes) do
		local node = snet.nodes[unit]
		if node then
			out.surface = out.surface or node.surface
			local kind = node.kind or "?"
			out.kinds[kind] = (out.kinds[kind] or 0) + 1
			if IO_KINDS[kind] then
				local rec = io_s and io_s.recs[unit]
				if rec then tally(out.io, rec) end
			elseif kind == "maintainer" then
				local rec = ae and ae.maintainers and ae.maintainers[unit]
				if rec then tally(out.maintainers, rec) end
			end
		end
	end
	local cpu = AC.cpu_report(net)
	out.cpus, out.cpus_busy = cpu.cpus, cpu.busy
	out.jobs_running, out.jobs_queued = 0, 0
	for _, job in ipairs(AC.jobs(net)) do
		if job.active then
			if job.status == "running" then out.jobs_running = out.jobs_running + 1 else out.jobs_queued = out.jobs_queued + 1 end
		end
	end
	return out
end

function M.window() return Sched.window(game.tick) end

--------------------------------------------------------------------------------
--- the lines
--------------------------------------------------------------------------------

local function secs(ticks) return string.format("%.1f", ticks / 60) end

--- a time of the scheduler: in ticks under a second (where seconds would round to zero), else in seconds (issue #51)
local function span(ticks)
	ticks = ticks or 0
	if ticks < 60 then return { "me-stats.ticks", math.floor(ticks + 0.5) } end
	return { "me-stats.seconds", secs(ticks) }
end

--- the starved arrivals: how many, and (issue #51) how long the other side had been out by the rate the visit before saw,
--- and how many ran out sooner than that rate said
local function starved_text(c)
	local out = c.out or { n = 0 }
	if c.starved <= 0 or ((out.n or 0) == 0 and (c.sooner or 0) == 0) then return tostring(c.starved) end
	if (out.n or 0) == 0 then return { "me-stats.starved-sooner", c.starved, c.sooner or 0 } end
	return { "me-stats.starved", c.starved, span(out.median), span(out.max), c.sooner or 0 }
end

--- "no-key 3, net-full 2" (sorted by the number, then by name) or "-"
local function detail(by)
	if not by then return "-" end
	local list = {}
	for why, n in pairs(by) do list[#list + 1] = { why, n } end
	table.sort(list, function(a, b) if a[2] ~= b[2] then return a[2] > b[2] end return a[1] < b[1] end)
	local parts = {}
	for i, e in ipairs(list) do parts[i] = e[1] .. " " .. e[2] end
	return table.concat(parts, ", ")
end

local function status_text(status)
	if status == "ok" then return { "me-stats.working" } end
	return status
end

local function surface_name(index)
	local surface = index and game.get_surface(index)
	return surface and surface.name or "?"
end

--- the lines of one network
local function network_lines(r, w)
	local lines = {}
	lines[#lines + 1] = { "me-stats.header", r.id, status_text(r.status), r.members, surface_name(r.surface) }
	local kinds = {}
	for kind in pairs(r.kinds) do kinds[#kinds + 1] = kind end
	table.sort(kinds, function(a, b)
		local ka, kb = KNOWN[a] or 1000, KNOWN[b] or 1000
		if ka ~= kb then return ka < kb end
		return a < b
	end)
	local line
	for i, kind in ipairs(kinds) do
		if (i - 1) % PER_LINE == 0 then
			if line then lines[#lines + 1] = line end
			line = { "", { "me-stats.members" } }
		end
		line[#line + 1] = i % PER_LINE == 1 and " " or ", "
		line[#line + 1] = { "me-stats.count", KNOWN[kind] and { "me-stats.kind-" .. kind } or kind, r.kinds[kind] }
	end
	if line then lines[#lines + 1] = line end
	local io = r.io
	lines[#lines + 1] = { "me-stats.blocks", io.busy or 0, io.probing or 0, detail(io.probing_by), io.parked or 0, detail(io.parked_by) }
	local m = r.maintainers
	if (r.kinds.maintainer or 0) > 0 then
		lines[#lines + 1] = { "me-stats.maintainers", r.kinds.maintainer, m.busy or 0, m.probing or 0, m.parked or 0, detail(m.parked_by) }
	end
	if (r.cpus or 0) > 0 or r.jobs_running > 0 or r.jobs_queued > 0 then
		lines[#lines + 1] = { "me-stats.crafting", r.cpus or 0, r.cpus_busy or 0, r.jobs_running, r.jobs_queued }
	end
	return lines
end

--- "16 to 32", "10 per second"
local function budget_text(q)
	if q.rate then return { "me-stats.per-second", Sched.setting(q.rate) } end
	local floor, ceiling = Sched.setting(q.floor), Sched.setting(q.ceiling)
	if floor == ceiling then return tostring(floor) end
	return floor .. " to " .. ceiling
end

--- the lines of the scheduler's window
local function scheduler_lines(w)
	local lines = {}
	lines[#lines + 1] = { "me-stats.scheduler", secs(w.span) }
	for _, q in ipairs(QUEUES) do
		local c = w.q[q.name]
		if c then
			local p = q.probe and w.q[q.probe]
			local probes = p and p.ticks > 0 and string.format("%.2f", p.visits / p.ticks) or "-"
			local work = c.work and c.work.n > 0
				and { "me-stats.service", span(c.work.median), span(c.work.p99), span(c.work.max), c.work.n }
				or { "me-stats.service-none" }
			if c.ticks == 0 then              -- (the crafting jobs: stepped one at a time, no list of their own)
				lines[#lines + 1] = { "me-stats.queue-samples", { "me-stats.queue-" .. q.name }, work }
			else
				lines[#lines + 1] = { "me-stats.queue", { "me-stats.queue-" .. q.name }, string.format("%.2f", c.visits / c.ticks),
					budget_text(q), probes, string.format("%.0f", c.backlog_avg), starved_text(c), c.missed, c.missed_total, c.wakes, work }
			end
		end
	end
	return lines
end

--- the lines of `/me-stats all`
local function all_lines()
	local snet = storage.fork_me_net
	local ids = {}
	for id in pairs(snet and snet.nets or {}) do ids[#ids + 1] = id end
	table.sort(ids)
	local lines = { { "me-stats.all-header", #ids } }
	for i, id in ipairs(ids) do
		if i > MAX_NETWORKS then
			lines[#lines + 1] = { "me-stats.all-more", #ids - MAX_NETWORKS }
			break
		end
		local r = M.report(snet.nets[id])
		local io = r.io
		lines[#lines + 1] = { "me-stats.all-line", r.id, status_text(r.status), r.members,
			(r.kinds.interface or 0) + (r.kinds["import-bus"] or 0) + (r.kinds["export-bus"] or 0),
			io.busy or 0, io.probing or 0, io.parked or 0, r.cpus or 0, r.jobs_running + r.jobs_queued }
	end
	return lines
end

--- the network of the ME block a player has open, else the nearest ME block within RADIUS tiles
local function network_for(player, entity)
	if entity then return N.network_of(entity) end
	if not player then return nil end
	local opened = player.opened
	if type(opened) == "userdata" and opened.object_name == "LuaEntity" and opened.valid then
		local net = N.network_of(opened)
		if net then return net end
	end
	local _, net = N.member_near(player.surface, player.position, player.force, RADIUS, true)
	return net
end

--- the lines for `parameter` ("" or "all"); `player` may be nil (the console), `entity` names the block directly (tests)
function M.run(player, parameter, entity)
	local param = (parameter or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
	if param == "all" then
		local lines = all_lines()
		for _, l in ipairs(scheduler_lines(Sched.window(game.tick))) do lines[#lines + 1] = l end
		return lines
	end
	local net = network_for(player, entity)
	if not net then
		return { { player and "me-stats.no-network" or "me-stats.no-player" } }
	end
	local lines = network_lines(M.report(net))
	for _, l in ipairs(scheduler_lines(Sched.window(game.tick))) do lines[#lines + 1] = l end
	return lines
end

local function say(player, message)
	if player then player.print(message) else game.print(message) end
end

commands.add_command("me-stats", { "me-stats.help" }, function(command)
	local player = command.player_index and game.get_player(command.player_index) or nil
	for _, line in ipairs(M.run(player, command.parameter)) do say(player, line) end
end)

remote.add_interface("gregtorio-me-stats", {
	report = function(entity)
		local net = entity and N.network_of(entity)
		return net and M.report(net) or nil
	end,
	window = function(tick) return Sched.window(tick or game.tick) end,
	mark = function(tick) Sched.mark(tick) end,                           -- (tests: a copy of the counters at a chosen tick)
	run = function(entity, parameter) return M.run(nil, parameter, entity) end,
	--- (tests, issue #51: the text of the starved arrivals and of a time for given counters)
	starved_text = function(c) return starved_text(c) end,
	span = function(ticks) return span(ticks) end,
})

return M
