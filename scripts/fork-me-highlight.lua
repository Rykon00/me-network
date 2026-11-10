--------------------------------------------------------------------------------
--- ME NETWORK: THE NETWORK HIGHLIGHTED WHILE A PLAYER HOVERS A MEMBER (issue #699)
---   * The game draws its grey pipe visualization over a whole pipe system while a player hovers a part of it. The ME
---     Underground Cable is a pipe-to-ground in a connection category of its own, so the game draws that for an underground
---     pair; the ME Cable is no pipe (issue #697: as a pipe every removal costs time in the size of the network), so the game
---     draws nothing for it. This module draws the like itself: while a player hovers a built member of a network, the ME
---     Cables of that network around it are drawn as grey lines through the middle of their tiles (to the edge of a block
---     they connect to), every underground cable gets the pipe-to-ground visualization of its direction (`__base__/graphics/
---     entity/pipe-to-ground/visualization.png`) and a pair a dashed line between its ends.
---   * What it costs (2.1.24, docs/PERFORMANCE.md, issue #699): a render object about 10 us to make, so a straight run of
---     cables is one line, not a picture per cable (pictures cost 47 ms for the 4 000 cables of a comb around the cursor,
---     140 ms for a dense grid). Finding the cables costs about 4 us per member, a search of the surface as much as a walk
---     through the graph (Lua takes about 0.5 us per table access here). So the walk goes from the hovered member outward
---     through the graph, at most PER_TICK steps a tick (a step: one member visited, or one cable followed along a run),
---     and draws what it reached at once: the highlight spreads from the cursor over a few ticks and no tick pays more than
---     PER_TICK steps, whatever the size of the network.
---   * Only that player sees it. It goes when the selection changes to something else, when the player leaves or is removed.
---     Hovering another member of the same network near the first keeps it while that network keeps its members (moving the
---     cursor along a cable selects every cable on the way); a change of its members while it spreads starts it again.
---   * Drawn are the cables within HALF_W x HALF_H tiles of the hovered entity (about a zoomed-out screen); the walk may
---     leave that area by WALK tiles (a cable that comes back into it).
--- State: storage.fork_me_highlight (lazy): { h = key (a player index; a test's key) -> highlight, busy = highlights still
--- spreading or nil }. A highlight: { unit (the hovered member), net, count (its members then), surface, x, y, players, objs, n, box, walk, and
--- while it spreads queue, seen, head, tail }.
--------------------------------------------------------------------------------

local N = require("scripts.fork-me-network")

local M = {}
N.highlight = M                      -- (the hover handler of scripts/fork-me-windows.lua and the player handlers of the terminal)

local HALF_W, HALF_H = 64, 40        -- tiles drawn around the hovered entity
local WALK = 8                       -- tiles the walk through the graph may leave the area
local REUSE = 16                     -- tiles the hovered entity may move within the same network before it is drawn again
local PER_TICK = 200                 -- steps of every spreading highlight together per tick (and when it starts)
local MAX_OBJECTS = 3000             -- objects at most per highlight
--- the grey of the game's visualization of an empty pipe system (taken from a screenshot of a hovered underground pair)
local COLOR = { r = 73 / 255, g = 76 / 255, b = 89 / 255, a = 1 }
local WIDTH = 4                      -- pixels at zoom 1 (32 per tile): the bar of the pipe's visualization
local OVER = WIDTH / 64              -- tiles a line goes past a middle, so two lines meet without a notch
local LAYER = "higher-object-above"
M.HALF_W, M.HALF_H, M.PER_TICK, M.MAX_OBJECTS = HALF_W, HALF_H, PER_TICK, MAX_OBJECTS

local SINGLE = "fork-me-cable-visualization-single"        -- (prototypes/network.lua)
local D = defines.direction
local UG_SPRITE = { [D.north] = "fork-me-underground-visualization-north", [D.east] = "fork-me-underground-visualization-east",
	[D.south] = "fork-me-underground-visualization-south", [D.west] = "fork-me-underground-visualization-west" }

local function state()
	local st = storage.fork_me_highlight
	if not st then
		st = { h = {} }
		storage.fork_me_highlight = st
	end
	return st
end

--- the highlight of `key` goes
function M.clear(key)
	local st = storage.fork_me_highlight
	local h = st and st.h[key]
	if not h then return end
	for _, o in pairs(h.objs) do
		if o.valid then o.destroy() end
	end
	if h.queue then st.busy = (st.busy or 1) > 1 and st.busy - 1 or nil end
	st.h[key] = nil
end

--- the neighbours of the cable node `b` on its four sides: the mask (1 N, 2 E, 4 S, 8 W) and the neighbour east and south that is
--- a cable in the area `box` (the run goes on there)
local function sides(nodes, box, b)
	local x1, y1, x2, y2 = box[1], box[2], box[3], box[4]
	local mask, ce, cs = 0, nil, nil
	for unit in pairs(b.adj) do
		local o = nodes[unit]
		if o then
			if o[4] == b[2] and o[1] < b[3] and o[3] > b[1] then mask = mask + 1
			elseif o[1] == b[3] and o[2] < b[4] and o[4] > b[2] then
				mask = mask + 2
				if o.kind == "cable" and o[3] > x1 and o[1] < x2 and o[4] > y1 and o[2] < y2 then ce = o end
			elseif o[2] == b[4] and o[1] < b[3] and o[3] > b[1] then
				mask = mask + 4
				if o.kind == "cable" and o[3] > x1 and o[1] < x2 and o[4] > y1 and o[2] < y2 then cs = o end
			elseif o[3] == b[1] and o[2] < b[4] and o[4] > b[2] then mask = mask + 8 end
		end
	end
	return mask, ce, cs
end

local function add(h, obj)
	h.n = h.n + 1
	h.objs[h.n] = obj
end

local function add_line(h, x1, y1, x2, y2, dashed)
	if h.n >= MAX_OBJECTS then return end
	add(h, rendering.draw_line{ color = COLOR, width = WIDTH, from = { x1, y1 }, to = { x2, y2 }, surface = h.surface,
		players = h.players, render_layer = LAYER, dash_length = dashed and 0.25 or nil, gap_length = dashed and 0.25 or nil })
end

--- the cable node `b` (in the area; `mask` its sides, `cn` / `cw` its neighbour north / west is a cable in the area, `ce` /
--- `cs` the one east / south) is drawn: the runs that start at it, east and south (a run starts at a cable whose neighbour to
--- the west, or north, is no cable in the area). Returns the steps it took.
local function draw_cable(h, nodes, b, mask, cn, ce, cs, cw)
	local steps = 1
	local x, y = b[1], b[2]
	if mask == 0 then
		if h.n < MAX_OBJECTS then
			add(h, rendering.draw_sprite{ sprite = SINGLE, target = { x + 0.5, y + 0.5 }, surface = h.surface, players = h.players,
				render_layer = LAYER, tint = COLOR })
		end
		return steps
	end
	local box = h.box
	local E, W, S, Nn = mask % 4 >= 2, mask >= 8, mask % 8 >= 4, mask % 2 == 1
	if (E or W) and not cw then
		local x2, east, has_e = x, ce, E
		while east do
			x2 = east[1]
			local m, e2 = sides(nodes, box, east)
			east, has_e = e2, m % 4 >= 2
			steps = steps + 1
		end
		add_line(h, W and x or x + 0.5 - OVER, y + 0.5, has_e and x2 + 1 or x2 + 0.5 + OVER, y + 0.5)
	end
	if (S or Nn) and not cn then
		local y2, south, has_s = y, cs, S
		while south do
			y2 = south[2]
			local m, _, s2 = sides(nodes, box, south)
			south, has_s = s2, m % 8 >= 4
			steps = steps + 1
		end
		add_line(h, x + 0.5, Nn and y or y + 0.5 - OVER, x + 0.5, has_s and y2 + 1 or y2 + 0.5 + OVER)
	end
	return steps
end

local function draw_underground(h, nodes, b)
	local px, py = b[1] + 0.5, b[2] + 0.5
	local name = UG_SPRITE[b.dir]
	if name and h.n < MAX_OBJECTS then
		add(h, rendering.draw_sprite{ sprite = name, target = { px, py }, surface = h.surface, players = h.players,
			render_layer = LAYER, tint = COLOR })
	end
	--- the dashes to its partner, drawn by the end west or north of it (each pair once)
	local q = b.partner and nodes[b.partner]
	if q then
		local qx, qy = q[1] + 0.5, q[2] + 0.5
		if qx > px and qy == py then add_line(h, px + 0.5, py, qx - 0.5, qy, true)
		elseif qy > py and qx == px then add_line(h, px, py + 0.5, qx, qy - 0.5, true) end
	end
end

--- `h` spreads by at most `budget` steps; returns the steps left
local function spread(st, h, budget)
	local nodes = storage.fork_me_net.nodes
	local queue, seen = h.queue, h.seen
	local head, tail = h.head, h.tail
	local box, wb, net = h.box, h.walk, h.net
	local x1, y1, x2, y2 = box[1], box[2], box[3], box[4]
	local w1, v1, w2, v2 = wb[1], wb[2], wb[3], wb[4]
	while head <= tail and budget > 0 do
		local b = nodes[queue[head]]
		queue[head] = nil
		head = head + 1
		budget = budget - 1
		if b and b.net == net then
			local bin = b[3] > x1 and b[1] < x2 and b[4] > y1 and b[2] < y2
			local cab = bin and b.kind == "cable"
			local mask, cn, ce, cs, cw = 0, false, nil, nil, false
			for unit in pairs(b.adj) do
				local o = nodes[unit]
				if o then
					if cab then           -- (its sides, read in the same pass as the walk)
						local oc = o.kind == "cable" and o[3] > x1 and o[1] < x2 and o[4] > y1 and o[2] < y2
						if o[4] == b[2] and o[1] < b[3] and o[3] > b[1] then
							mask = mask + 1
							if oc then cn = true end
						elseif o[1] == b[3] and o[2] < b[4] and o[4] > b[2] then
							mask = mask + 2
							if oc then ce = o end
						elseif o[2] == b[4] and o[1] < b[3] and o[3] > b[1] then
							mask = mask + 4
							if oc then cs = o end
						elseif o[3] == b[1] and o[2] < b[4] and o[4] > b[2] then
							mask = mask + 8
							if oc then cw = true end
						end
					end
					if not seen[unit] then
						seen[unit] = true
						if o[3] > w1 and o[1] < w2 and o[4] > v1 and o[2] < v2 then
							tail = tail + 1
							queue[tail] = unit
						end
					end
				end
			end
			if cab then
				if not (cw and cn) then budget = budget - draw_cable(h, nodes, b, mask, cn, ce, cs, cw) + 1 end
			elseif bin and b.kind == "underground" then
				draw_underground(h, nodes, b)
			end
		end
	end
	h.head, h.tail = head, tail
	if head > tail then                               -- (spread to its end)
		h.queue, h.seen, h.head, h.tail = nil, nil, nil, nil
		st.busy = (st.busy or 1) > 1 and st.busy - 1 or nil
	end
	return budget
end

--- Start the highlight of the network of the member `entity` around it for `key` (players: { key }, or nil for every player:
--- the tests). Returns false when it keeps what is there or `entity` is no member.
function M.show(key, entity, players)
	local node = entity and entity.valid and N.node_of(entity)
	if not node then
		M.clear(key)
		return false
	end
	local s = N.state()
	local st = state()
	local pos = entity.position
	local old = st.h[key]
	local count = s.nets[node.net] and s.nets[node.net].n or 0
	if old and old.net == node.net and old.count == count and old.surface == node.surface
		and math.abs(pos.x - old.x) <= REUSE and math.abs(pos.y - old.y) <= REUSE then
		return false
	end
	M.clear(key)
	local unit = entity.unit_number
	local box = { pos.x - HALF_W, pos.y - HALF_H, pos.x + HALF_W, pos.y + HALF_H }
	local h = { unit = unit, net = node.net, count = count, surface = node.surface, x = pos.x, y = pos.y, players = players,
		objs = {}, n = 0, box = box, walk = { box[1] - WALK, box[2] - WALK, box[3] + WALK, box[4] + WALK },
		queue = { unit }, seen = { [unit] = true }, head = 1, tail = 1 }
	st.h[key] = h
	st.busy = (st.busy or 0) + 1
	spread(st, h, PER_TICK)
	return true
end

--- on_tick (control.lua): the highlights still spreading go on, PER_TICK steps of all of them together; one whose network
--- changed (gone, or another number of members: the global graph version changes with every build anywhere, and a base
--- whose robots build all the time would start it again on every tick) starts again (nothing while none spreads)
function M.on_tick()
	local st = storage.fork_me_highlight
	if not (st and st.busy) then return end
	local budget = PER_TICK
	local nets = storage.fork_me_net.nets
	for key, h in pairs(st.h) do
		if h.queue then
			local net = nets[h.net]
			if not (net and net.n == h.count) then
				local node = storage.fork_me_net.nodes[h.unit]
				local entity = node and node.entity
				local players = h.players
				M.clear(key)
				if entity and entity.valid then M.show(key, entity, players) end
				budget = 0
			else
				budget = spread(st, h, budget)
			end
			if budget <= 0 then return end
		end
	end
end

--- on_selected_entity_changed (scripts/fork-me-windows.lua): the player's selection is a member, or not
function M.on_selected(player)
	local e = player.selected
	if e and e.valid and N.node_of(e) then
		M.show(player.index, e, { player.index })
	elseif storage.fork_me_highlight and storage.fork_me_highlight.h[player.index] then
		M.clear(player.index)
	end
end

remote.add_interface("gregtorio-me-highlight", {
	--- tests: start the highlight of the network of `entity` for `key` (visible to every player); false: kept, or no member
	show = function(key, entity) return M.show(key, entity, nil) end,
	clear = function(key) M.clear(key) end,
	--- tests: what is drawn for `key`: { done = spread to its end, list = { { "line", x1, y1, x2, y2, dashed } or
	--- { sprite, x, y } } }, nil when nothing
	objects = function(key)
		local h = storage.fork_me_highlight and storage.fork_me_highlight.h[key]
		if not h then return nil end
		local list = {}
		for _, o in pairs(h.objs) do
			if not o.valid then
				list[#list + 1] = { "invalid" }
			elseif o.type == "line" then
				local a, b = o.from.position, o.to.position
				list[#list + 1] = { "line", a.x, a.y, b.x, b.y, (o.dash_length or 0) > 0 }
			else
				local t = o.target.position
				list[#list + 1] = { o.sprite, t.x, t.y }
			end
		end
		return { done = h.queue == nil, list = list }
	end,
	--- tests: the highlights there are and those still spreading
	counts = function()
		local st = storage.fork_me_highlight
		local n = 0
		for _ in pairs(st and st.h or {}) do n = n + 1 end
		return { highlights = n, busy = st and st.busy or 0 }
	end,
	--- tests and the probe: the highlight of `key` spreads by `steps` (to its end when nil); returns the steps it had left
	spread = function(key, steps)
		local st = storage.fork_me_highlight
		local h = st and st.h[key]
		if not (h and h.queue) then return nil end
		return spread(st, h, steps or 1e9)
	end,
})

return M
