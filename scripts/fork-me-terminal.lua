--------------------------------------------------------------------------------
--- FORK AE2: ME TERMINAL (runtime; issue #68: the hub of the ME network, scripts/fork-me-network.lua)
---   * Status line: network state, bytes and types used of the item cells and of the fluid cells, drives and
---     cells, the controller's power draw. A search field above the tabs filters the Storage and Crafting tabs.
---   * Storage tab: sort (amount or name), kind (all, items, fluids), one grid with the items and then the
---     fluids. Left click on an item: a stack into the cursor (with something in the cursor: that is stored
---     instead); right click: one item into the cursor; shift click: a stack into the inventory. Fluids are
---     shown with their amounts; they cannot be taken by hand. Issue #28: the window shows the player's inventory on
---     its left (scripts/fork-me-gui.lua, the pane): shift + click there stores the stack in the network, control +
---     click every stack of that item (store_stack, store_inventory_item); it replaces the terminal's own grid of
---     the player's inventory.
---   * Crafting tab (scripts/fork-me-autocraft.lua): every item or fluid a pattern can make, in the storage
---     grid's style. A click picks it: amount field, the plan preview (what is taken from storage, what is
---     missing, as slot buttons) and the Craft button.
---   * Jobs tab: the crafting jobs of the network with progress and a cancel button.
---   * Cells tab: the drives of the network (higher priority first) with their cells; a click on a drive opens
---     the drive window, a click on a cell its cell window (scripts/fork-me-windows.lua; "Back" returns here).
---   * Every window is refreshed once per second while it is open (scripts/fork-me-gui.lua, refresh_all); the
---     same step runs the slow step of the network module (drive lights, sweep for vanished members).
---   * Every GUI event of the mod is registered here and routed by scripts/fork-me-gui.lua (dispatch): the
---     elements carry their action in their tags. The open key and on_gui_opened open the ME windows.
--- Every button calls a function of this module that the runtime test calls directly (take, store_cursor,
--- store_inventory_item, withdraw, store_stack, entries, craft_preview, start_craft, cancel_job, cells). The Patterns tab is
--- gone (issue #130): encoding patterns is the ME Pattern Terminal's job (scripts/fork-me-patternterm.lua).
--- State: storage.fork_me_terminal[player_index] = { entity, filter, sort, kind, pick, amount, shown... }
--------------------------------------------------------------------------------

local N = require("scripts.fork-me-network")
local G = require("scripts.fork-me-gui")
local autocraft = require("scripts.fork-me-autocraft")
local Sched = require("scripts.fork-me-schedule")

local M = {}

local MAX_BUTTONS = 400
local MAX_CRAFT_BUTTONS = 200
local COLUMNS = 10
local REFRESH_TICKS = 60
local WIDTH = 40 * COLUMNS + 12
local KINDS = { all = "items", items = "fluids", fluids = "all" }     -- the kind button cycles

local function state()
	storage.fork_me_terminal = storage.fork_me_terminal or {}
	return storage.fork_me_terminal
end

--- nil when the terminal can be used, otherwise the reason as a locale key of [fork-me-net] (status-...)
local function problem(entity)
	if not (entity and entity.valid) then return "no-network" end
	--- (issue #128: the terminal has no power of its own; it works when its network does)
	local net = N.network_of(entity)
	if not net then return "no-network" end
	local ok, why = N.usable(net)
	if not ok then return why end
	return nil
end

--- the working network of a terminal, or nil and the reason
local function network(entity)
	local why = problem(entity)
	if why then return nil, why end
	return N.network_of(entity)
end
M.network = network

local function status_line(net)
	local st = N.stats(net)
	local f = G.fmt
	return { "fork-me-net.terminal-status", f(st.bytes), f(st.bytes_total), st.types, st.types_total,
		st.drives, st.cells, f(st.power / 1000), f(st.fbytes), f(st.fbytes_total),
		st.ftypes, st.ftypes_total, st.fluid_cells }
end

--------------------------------------------------------------------------------
--- data of the tabs (also the remote interface: the runtime test calls the same code)
--------------------------------------------------------------------------------

--- Issue #50, lever 8: what an entry reads of its key alone, once per key (per load: prototypes do not change while the
--- game runs): a fluid's name, an item's name, quality and whether it has data (N.parse_key), and whether the prototype
--- exists (an entry of a removed prototype is not shown)
local key_info, key_info_n = {}, 0
local function info_of(key)
	local i = key_info[key]
	if not i then
		if key_info_n >= 50000 then key_info, key_info_n = {}, 0 end   -- (keys with data can be many)
		if N.is_fluid_key(key) then
			local name = N.fluid_name(key)                  -- (issue #159: one entry per temperature, "fluid/<name>@<degrees>")
			i = { fluid = true, name = name, ok = prototypes.fluid[name] ~= nil }
		else
			local name, quality, json = N.parse_key(key)
			i = { name = name, quality = quality, special = json ~= nil, ok = prototypes.item[name] ~= nil }
		end
		key_info[key] = i
		key_info_n = key_info_n + 1
	end
	return i
end

--- issue #50, lever 8: { kept, resorted, sorted } lists since the load (tests, the benchmark)
local list_stats = { kept = 0, resorted = 0, sorted = 0 }

--- `list` sorted by `order` (a strict total order: the result is the one table.sort gives). The list mostly comes in the
--- order of the last refresh, where an insertion sort moves only what changed; when that takes too long, table.sort.
local function sort_list(list, order)
	local n = #list
	local moves, limit = 0, 4 * n + 64
	for i = 2, n do
		local e = list[i]
		local j = i - 1
		while j >= 1 and order(e, list[j]) do
			list[j + 1] = list[j]
			j = j - 1
			moves = moves + 1
		end
		list[j + 1] = e
		if moves > limit then
			table.sort(list, order)
			list_stats.sorted = list_stats.sorted + 1
			return
		end
	end
end

--- the entries of `current` (key -> entry) in the order of `prev` (the last sorted entries) where they were there, the
--- others after them, then sorted (without `prev`: table.sort)
local function resorted(prev, current, order)
	local list, n = {}, 0
	if not prev then                                  -- (a first list: no order to start from)
		for _, e in pairs(current) do
			n = n + 1
			list[n] = e
		end
		table.sort(list, order)
		return list
	end
	for _, e in ipairs(prev) do
		local now = current[e.key]
		if now then
			n = n + 1
			list[n] = now
			current[e.key] = false
		end
	end
	for _, e in pairs(current) do
		if e then
			n = n + 1
			list[n] = e
		end
	end
	sort_list(list, order)
	return list
end

--- Issue #50, lever 8: the last entries per network (weak: a network that is gone takes them along), search, sort and
--- kind, with the network's contents version (net.cver: every change of an amount counts it up) and whether it was
--- usable. Derived from the state only, outside storage: a peer without them makes the same list.
local lists = setmetatable({}, { __mode = "k" })
local KEEP_LISTS = 16

--- The entries of the storage grid: the items, then the fluids (key "fluid/<name>", fluid = true), each filtered
--- by the search and sorted by amount or name. `kind`: "all" (default), "items" or "fluids". Issue #50, lever 8: the
--- same table as the last call while the network's contents did not change (do not change it). `fresh` (tests, the
--- benchmark): made from nothing, as at a first refresh, and not kept.
function M.entries(net, filter, sort, kind, fresh)
	filter = (filter or ""):lower():gsub("%s+", "-")
	local usable = N.usable(net) and true or false
	local per = lists[net]
	if not per then
		per = { n = 0, of = {} }
		lists[net] = per
	end
	local id = tostring(sort) .. "|" .. tostring(kind) .. "|" .. filter
	local last = not fresh and per.of[id] or nil
	if last and last.cver == net.cver and last.usable == usable then
		list_stats.kept = list_stats.kept + 1
		return last.list
	end
	if last then list_stats.resorted = list_stats.resorted + 1 end
	if not last and not fresh then
		if per.n >= KEEP_LISTS then per.n, per.of = 0, {} end
		per.n = per.n + 1
	end
	local items, liquids = {}, {}
	if usable then
		for key, count in pairs(net.items) do
			local i = info_of(key)
			if i.ok and (filter == "" or i.name:find(filter, 1, true)) then
				if i.fluid then
					if kind ~= "items" then liquids[key] = { key = key, name = i.name, count = count, fluid = true } end
				elseif kind ~= "fluids" then
					items[key] = { key = key, name = i.name, quality = i.quality, count = count, special = i.special }
				end
			end
		end
	end
	local function order(a, b)
		if sort == "name" then
			if a.name ~= b.name then return a.name < b.name end
		elseif a.count ~= b.count then
			return a.count > b.count
		end
		return a.key < b.key
	end
	items = resorted(last and last.items, items, order)
	liquids = resorted(last and last.liquids, liquids, order)
	local list = {}
	for i, e in ipairs(items) do list[i] = e end
	for _, f in ipairs(liquids) do list[#list + 1] = f end
	if not fresh then per.of[id] = { cver = net.cver, usable = usable, items = items, liquids = liquids, list = list } end
	return list
end

--- The crafting tab's preview for `amount` of `key`: { ok, reason, runs, steps, reserve = { key -> n },
--- missing = { key -> n }, loops, cpus, free, bytes, cpu_list }. reason: "no-network", "bad-amount", "no-cpu",
--- "missing", "no-pattern", "cpu-too-small" (no CPU is big enough), "no-free-cpu" (those that are, are busy) or nil
--- when it can start. Issue #6: `bytes` is the crafting storage the job needs, `cpu_list` the CPUs of the network in
--- the order a job takes them (autocraft.cpu_list: fits, free).
function M.craft_preview(terminal, key, amount)
	local net, why = network(terminal)
	if not net then return { ok = false, reason = "no-network", why = why } end
	local total, free = autocraft.cpu_summary(net)
	local out = { ok = false, cpus = total, free = free, reserve = {}, missing = {}, loops = {}, runs = 0, steps = 0 }
	amount = math.floor(tonumber(amount) or 0)
	local plan = amount >= 1 and autocraft.plan(net, key, amount) or nil
	if not plan then out.reason = "bad-amount" return out end
	out.reserve, out.missing, out.loops = plan.reserve or {}, plan.missing or {}, plan.loops or {}
	out.runs, out.steps = plan.runs or 0, #(plan.steps or {})
	out.bytes, out.cpu_list = plan.bytes, plan.bytes and autocraft.cpu_list(net, plan.bytes) or {}
	local fits, free, biggest = false, false, 0
	for _, c in ipairs(out.cpu_list) do
		if c.fits then fits = true end
		if c.fits and c.free then free = true end
		if c.bytes and c.bytes > biggest then biggest = c.bytes end
	end
	out.biggest = biggest
	if plan.no_pattern then out.reason = "no-pattern"
	elseif not plan.ok then out.reason = "missing"
	elseif total == 0 then out.reason = "no-cpu"
	elseif not fits then out.reason = "cpu-too-small"
	elseif not free then out.reason = "no-free-cpu"
	else out.ok = true end
	return out
end

--- the Craft button: returns the job id, or nil and a reason (a locale key suffix of [fork-me-craft] error-...)
function M.start_craft(terminal, key, amount)
	local id, why, plan = autocraft.start(terminal, key, amount)
	return id, why, plan
end

function M.cancel_job(id) return autocraft.cancel(id) end

function M.jobs(terminal)
	local net = network(terminal)
	return net and autocraft.jobs(net) or {}
end

--- the cells tab: the drives of the network with their cells (N.drives_of; issue #50, lever 8: light, without each cell's
--- items and cards, which the tab does not show)
function M.cells(terminal)
	local net = network(terminal)
	return net and N.drives_of(net, true) or {}
end

--------------------------------------------------------------------------------
--- the storage tab's functions
--------------------------------------------------------------------------------

--- Move up to `count` items `name` of `quality` from the network at `terminal` into `target` (anything with
--- insert: LuaPlayer, LuaEntity, LuaInventory). Plain items first, then items with tags of that name.
--- Returns the number moved.
function M.withdraw(terminal, target, name, quality, count)
	local net = network(terminal)
	if not net then return 0 end
	local moved = N.extract_to(net, target, N.key_of(name, quality), count)
	if moved < count then
		for _, c in pairs(N.contents(net)) do
			if moved >= count then break end
			if c.special and c.name == name and c.quality == (quality or "normal") then
				moved = moved + N.extract_to(net, target, c.key, count - moved)
			end
		end
	end
	return moved
end

--- Store a LuaItemStack in the network at `terminal`.
--- Returns the number of items stored, or nil and a locale key of [fork-me-net] (status-... or the reason).
function M.store_stack(terminal, stack)
	local net, why = network(terminal)
	if not net then return nil, why end
	if not (stack and stack.valid_for_read) then return 0 end
	return N.insert_stack(net, stack)
end

--- A click on an item of the grid, for a player's `cursor` (LuaItemStack) and main inventory `inv`. `mode`:
--- "stack" (a stack into the cursor), "one" (one item into the cursor), "inventory" (a stack into the
--- inventory). With something in the cursor, "stack" stores the cursor. Returns the number of items moved
--- (stored: negative), or nil and a reason.
function M.take_to(cursor, inv, terminal, key, mode)
	local net, why = network(terminal)
	if not net then return nil, why end
	if N.is_fluid_key(key) then return nil, "fluid-by-hand" end
	local name = N.parse_key(key)
	local proto = prototypes.item[name]
	if not proto then return nil, "cannot-store" end
	if mode == "stack" and cursor and cursor.valid_for_read then
		local n, w = M.store_stack(terminal, cursor)
		return n and -n or nil, w
	end
	if mode == "inventory" then
		if not inv then return nil, "inventory-full" end
		local n = N.extract_to(net, inv, key, proto.stack_size)
		if n == 0 then return nil, "inventory-full" end
		return n
	end
	if not cursor then return nil, "inventory-full" end
	if mode == "one" and cursor.valid_for_read then
		--- one more of the same plain item into the cursor
		local bad, ckey = N.storable(cursor)
		if bad or ckey ~= key or cursor.count >= proto.stack_size then return 0 end
		local got = N.extract_key(net, key, 1)
		if got > 0 then cursor.count = cursor.count + got end
		return got
	end
	if cursor.valid_for_read then return 0 end
	return N.extract_to(net, cursor, key, mode == "one" and 1 or proto.stack_size)
end

function M.take(player, terminal, key, mode)
	return M.take_to(player.cursor_stack, player.get_main_inventory(), terminal, key, mode)
end

--- Store what the player holds in the cursor. Returns the count, or nil and a reason.
function M.store_cursor(player, terminal)
	return M.store_stack(terminal, player.cursor_stack)
end

--- Store items `name` of `quality` from the inventory `inv`: all of them, or one stack (`all` false).
--- Stacks with own data (tags) are stored stack by stack. A stack the network refuses (a used one: issue #76) stays and
--- the others go on; the reason of the first refusal is the answer when nothing was stored. Returns the count stored, or
--- nil and a reason.
function M.store_inventory_item(inv, terminal, name, quality, all)
	local net, why = network(terminal)
	if not net then return nil, why end
	if not inv then return 0 end
	local total, reason = 0, nil
	for i = 1, #inv do
		local stack = inv[i]
		if stack.valid_for_read and stack.name == name and stack.quality.name == (quality or "normal") then
			local n, w = N.insert_stack(net, stack)
			if n then total = total + n
			else
				reason = reason or w
				if not N.refuses_stack(w) then break end                  -- (no room, no power: the next stack fares no better)
			end
			if not all then break end
		end
	end
	if total == 0 and reason then return nil, reason end
	return total
end

local function report(player, why)
	if why and why ~= "empty" then
		player.create_local_flying_text{ text = { "fork-me-net.error-" .. why }, create_at_cursor = true }
	end
end

--------------------------------------------------------------------------------
--- the window
--------------------------------------------------------------------------------

local TABS = { "storage", "crafting", "jobs", "cells" }

local function scroll_table(parent, name, columns, height)
	local scroll = parent.add{ type = "scroll-pane", horizontal_scroll_policy = "never" }
	scroll.style.maximal_height = height
	scroll.style.minimal_width = WIDTH
	return scroll.add{ type = "table", name = name, column_count = columns, style = "filter_slot_table" }
end

local function build_storage(tab)
	local row = G.row(tab)
	row.add{ type = "button", name = "fork_me_sort", caption = { "fork-me-net.sort-count" },
		tooltip = { "fork-me-net.sort-tooltip" }, tags = G.act("term_sort") }
	row.add{ type = "button", name = "fork_me_kind", caption = { "fork-me-gui.kind-all" },
		tooltip = { "fork-me-gui.kind-tooltip" }, tags = G.act("term_kind") }
	row.add{ type = "button", caption = { "fork-me-terminal.store-hand" }, tags = G.act("term_store") }
	G.label(tab, { "fork-me-net.terminal-help" }, WIDTH)
	G.label(tab, "", WIDTH, nil, "fork_me_status").visible = false
	scroll_table(tab, "fork_me_grid", COLUMNS, 9 * 40 + 8)
end

local function build_crafting(tab)
	G.label(tab, "", WIDTH, nil, "fork_me_craft_info")
	scroll_table(tab, "fork_me_craft_grid", COLUMNS, 4 * 40 + 8)
	tab.add{ type = "line" }
	local pick = G.row(tab, "fork_me_pick_row")
	pick.add{ type = "sprite-button", name = "fork_me_pick", style = "slot_button" }
	pick.add{ type = "label", name = "fork_me_pick_name", caption = { "fork-me-gui.craft-pick" } }
	pick.add{ type = "empty-widget" }.style.horizontally_stretchable = true
	pick.add{ type = "label", caption = { "fork-me-gui.amount" } }
	G.number_field(pick, 1, G.act("term_amount"), 80, false, "fork_me_amount")
	pick.add{ type = "button", name = "fork_me_craft", caption = { "fork-me-craft.craft" }, style = "confirm_button",
		tags = G.act("term_craft") }
	G.label(tab, "", WIDTH, nil, "fork_me_plan")
	G.label(tab, "", WIDTH, nil, "fork_me_plan_cpus").visible = false
	local plan = tab.add{ type = "table", name = "fork_me_plan_grid", column_count = COLUMNS, style = "filter_slot_table" }
	plan.visible = false
end

local function build_jobs(tab)
	G.label(tab, "", WIDTH, nil, "fork_me_jobs_info")
	local scroll = tab.add{ type = "scroll-pane", horizontal_scroll_policy = "never" }
	scroll.style.maximal_height = 9 * 40
	scroll.style.minimal_width = WIDTH
	scroll.add{ type = "table", name = "fork_me_jobs", column_count = 5 }
end

local function build_cells(tab)
	G.label(tab, { "fork-me-gui.cells-help" }, WIDTH)
	local scroll = tab.add{ type = "scroll-pane", horizontal_scroll_policy = "never" }
	scroll.style.maximal_height = 9 * 40
	scroll.style.minimal_width = WIDTH
	scroll.add{ type = "table", name = "fork_me_cells", column_count = 2 }
end

local function open(player, entity)
	if not (entity and entity.valid and entity.name == "me-terminal") then return end
	local _, content = G.open_window(player, "terminal", { "fork-me-terminal.title" }, { unit = entity.unit_number })
	local st = state()[player.index]
	if not (st and st.entity == entity) then
		st = { entity = entity, filter = "", sort = "count", kind = "all", amount = 1, tab = 1 }
		state()[player.index] = st
	end
	st.shown, st.craft_shown, st.jobs_shown, st.cells_shown, st.plan_shown = nil, nil, nil, nil, nil
	G.label(content, "", WIDTH, nil, "fork_me_net_line")
	local top = G.row(content)
	top.add{ type = "label", caption = { "fork-me-terminal.search" } }
	local search = top.add{ type = "textfield", name = "fork_me_search", text = st.filter or "", tags = G.act("term_search") }
	search.style.width = 200
	local tabs = content.add{ type = "tabbed-pane", name = "fork_me_tabs", tags = G.act("term_tab") }
	for _, name in ipairs(TABS) do
		local tab = tabs.add{ type = "tab", caption = { "fork-me-gui.tab-" .. name } }
		local flow = tabs.add{ type = "flow", name = "fork_me_tab_" .. name, direction = "vertical" }
		flow.style.vertical_spacing = 6
		tabs.add_tab(tab, flow)
	end
	build_storage(tabs.fork_me_tab_storage)
	build_crafting(tabs.fork_me_tab_crafting)
	build_jobs(tabs.fork_me_tab_jobs)
	build_cells(tabs.fork_me_tab_cells)
	tabs.selected_tab_index = st.tab or 1
	G.find(content, "fork_me_sort").caption = { "fork-me-net.sort-" .. (st.sort or "count") }
	G.find(content, "fork_me_kind").caption = { "fork-me-gui.kind-" .. (st.kind or "all") }
	G.find(content, "fork_me_amount").text = tostring(st.amount or 1)
	M.refresh(player)
end
M.open = open

local function refresh_storage(player, st, frame, net)
	local status, grid = G.find(frame, "fork_me_status"), G.find(frame, "fork_me_grid")
	local items = M.entries(net, st.filter, st.sort, st.kind)
	local n = math.min(#items, MAX_BUTTONS)
	local sort, kind = st.sort or "count", st.kind or "all"
	--- What the grid shows is kept in storage (every peer sets the same buttons) and compared entry by entry. Issue #50,
	--- lever 8: unchanged since the last refresh: nothing is set (open tooltips stay); a button whose entry has another
	--- amount gets the new number, one whose entry is another key is made again in its place. A new sort, kind or number
	--- of buttons (or a window of an older version, which kept a signature string) builds the grid anew.
	local shown = st.shown
	if type(shown) == "table" and shown.sort == sort and shown.kind == kind and shown.n == n
		and (shown.total > MAX_BUTTONS) == (#items > MAX_BUTTONS) then
		local keys, counts = shown.keys, shown.counts
		local first
		for i = 1, n do
			if keys[i] ~= items[i].key or counts[i] ~= items[i].count then first = i break end
		end
		local children = first and grid.children
		if not first or #children == n then              -- (else the grid is not what was kept: built anew below)
			for i = first or n + 1, n do
				local c = items[i]
				if keys[i] ~= c.key then
					children[i].destroy()
					G.slot(grid, c.key, c.count, G.act("term_take", { key = c.key }), c.special and "yellow_slot_button" or nil, nil, i)
					keys[i], counts[i] = c.key, c.count
				elseif counts[i] ~= c.count then
					G.slot_amount(children[i], c.key, c.count)
					counts[i] = c.count
				end
			end
			if #items > MAX_BUTTONS and shown.total ~= #items then
				status.caption = { "fork-me-terminal.too-many", MAX_BUTTONS, #items }
			end
			shown.total = #items
			return
		end
	end
	local keys, counts = {}, {}
	for i = 1, n do keys[i], counts[i] = items[i].key, items[i].count end
	st.shown = { sort = sort, kind = kind, n = n, keys = keys, counts = counts, total = #items }
	grid.clear()
	status.visible = false
	if #items == 0 then
		status.caption = { "fork-me-terminal.empty" }
		status.visible = true
	elseif #items > MAX_BUTTONS then
		status.caption = { "fork-me-terminal.too-many", MAX_BUTTONS, #items }
		status.visible = true
	end
	for i = 1, math.min(#items, MAX_BUTTONS) do
		local c = items[i]
		G.slot(grid, c.key, c.count, G.act("term_take", { key = c.key }), c.special and "yellow_slot_button" or nil)
	end
end

local function refresh_crafting(st, frame, net)
	local total, free, _, slots = autocraft.cpu_summary(net)
	local keys, ignored = autocraft.craftable(net)
	G.find(frame, "fork_me_craft_info").caption = { "fork-me-craft.info", total, free, #keys, ignored.total or 0,
		autocraft.ignored_list(ignored), slots }
	local filter = (st.filter or ""):lower():gsub("%s+", "-")
	local shown, sig = {}, {}
	for _, key in pairs(keys) do
		if (filter == "" or key:find(filter, 1, true)) and #shown < MAX_CRAFT_BUTTONS then
			local d = autocraft.describe(key)
			if d then
				local count = d.fluid and N.count_key(net, key) or N.count(net, key, "normal")
				shown[#shown + 1] = { key = key, craft = key, count = count }
				sig[#sig + 1] = key .. "=" .. count
			end
		end
	end
	sig = table.concat(sig, ",") .. "|" .. tostring(st.pick)
	if st.craft_shown ~= sig then
		st.craft_shown = sig
		local grid = G.find(frame, "fork_me_craft_grid")
		grid.clear()
		for _, c in ipairs(shown) do
			G.slot(grid, c.key, c.count, G.act("term_pick", { key = c.craft }),
				c.craft == st.pick and "yellow_slot_button" or nil)
		end
	end
	--- the picked resource: the plan preview
	local pick, name = G.find(frame, "fork_me_pick"), G.find(frame, "fork_me_pick_name")
	local plan_label, plan_grid, button = G.find(frame, "fork_me_plan"), G.find(frame, "fork_me_plan_grid"), G.find(frame, "fork_me_craft")
	local d = st.pick and autocraft.describe(st.pick)
	if not d then
		pick.sprite = ""
		name.caption = { "fork-me-gui.craft-pick" }
		plan_label.caption = ""
		plan_grid.visible = false
		G.find(frame, "fork_me_plan_cpus").visible = false
		button.enabled = false
		return
	end
	pick.sprite = d.sprite
	name.caption = d.localised_name
	local p = M.craft_preview(st.entity, st.pick, st.amount)
	button.enabled = p.ok
	local psig = { tostring(p.ok), tostring(p.reason), p.runs, p.steps, tostring(p.bytes) }
	for _, c in ipairs(p.cpu_list or {}) do psig[#psig + 1] = c.kind .. c.id .. tostring(c.free) .. tostring(c.fits) .. (c.bytes or "") end
	for k, n in pairs(p.reserve) do psig[#psig + 1] = "r" .. k .. "=" .. n end
	for k, n in pairs(p.missing) do psig[#psig + 1] = "m" .. k .. "=" .. n end
	psig = table.concat(psig, ",")
	if st.plan_shown == psig then return end
	st.plan_shown = psig
	if p.reason == "bad-amount" then plan_label.caption = { "fork-me-craft.bad-amount" }
	elseif p.reason == "no-cpu" then plan_label.caption = { "fork-me-craft.no-cpu" }
	elseif p.reason == "no-pattern" then plan_label.caption = { "fork-me-craft.error-no-pattern" }
	elseif p.reason == "cpu-too-small" or p.reason == "no-free-cpu" then
		plan_label.caption = { "fork-me-craft.error-" .. p.reason, G.fmt(p.bytes), G.fmt(p.biggest or 0) }
	elseif p.reason == "missing" then
		local text = { "", { "fork-me-gui.plan-missing" } }
		if next(p.loops) then text[#text + 1] = { "fork-me-craft.plan-loop", autocraft.item_list(p.loops, 4) } end
		plan_label.caption = text
	else plan_label.caption = { "fork-me-gui.plan-ok", p.runs, p.steps } end
	M.plan_cpus(G.find(frame, "fork_me_plan_cpus"), p)
	plan_grid.clear()
	local function add(list, style, tip)
		local keys = {}
		for k in pairs(list) do keys[#keys + 1] = k end
		table.sort(keys)
		for _, k in ipairs(keys) do
			G.slot(plan_grid, k, list[k], nil, style, tip)
		end
	end
	add(p.missing, "red_slot_button", { "fork-me-gui.missing-tooltip" })
	add(p.reserve, nil, { "fork-me-gui.uses-tooltip" })
	plan_grid.visible = #plan_grid.children > 0
end

--- the name of a CPU of autocraft.cpu_list: "Crafting CPU 3 (2x3, 5k, 2 co-processors)"
function M.cpu_name(c)
	return { "fork-me-craft.cpu-name", c.id, c.width, c.height, G.fmt(c.bytes), c.coprocessors }
end

--- Issue #6: the line under the plan: the bytes the job needs and the CPUs of the network (free ones that fit, busy
--- ones that fit, those that are too small)
function M.plan_cpus(label, p)
	if not (p.bytes and p.reason ~= "missing" and p.reason ~= "no-pattern" and p.reason ~= "bad-amount" and p.cpu_list and #p.cpu_list > 0) then
		label.visible = false
		return
	end
	local groups = { free = { "" }, busy = { "" }, small = { "" } }
	local n = { free = 0, busy = 0, small = 0 }
	for _, c in ipairs(p.cpu_list) do
		local which = not c.fits and "small" or c.free and "free" or "busy"
		n[which] = n[which] + 1
		if n[which] <= 4 then
			local list = groups[which]
			if n[which] > 1 then list[#list + 1] = ", " end
			list[#list + 1] = M.cpu_name(c)
		elseif n[which] == 5 then
			groups[which][#groups[which] + 1] = ", ..."
		end
	end
	local text = { "", { "fork-me-craft.plan-bytes", G.fmt(p.bytes) } }
	for _, which in ipairs({ "free", "busy", "small" }) do
		if n[which] > 0 then text[#text + 1] = { "fork-me-craft.plan-cpus-" .. which, groups[which] } end
	end
	label.caption = text
	label.visible = true
end

local function status_text(j)
	if j.status == "running" then
		return j.wait and { "fork-me-craft.wait-" .. j.wait } or { "fork-me-craft.status-running" }
	elseif j.status == "failed" then
		return { "fork-me-craft.status-failed", j.reason or "" }
	elseif j.status == "queued" and j.wait == "cpu-bytes" and j.bytes then
		return { "fork-me-craft.status-queued-bytes", G.fmt(j.bytes) }
	end
	return { "fork-me-craft.status-" .. j.status }
end
M.status_text = status_text

--- a job list (terminal jobs tab, CPU window): icon, amount and name, progress, status, cancel
function M.job_rows(t, jobs)
	t.clear()
	for _, j in ipairs(jobs) do
		local d = autocraft.describe(j.item)
		G.slot(t, j.item, j.amount)
		local name = t.add{ type = "label", caption = { "", G.fmt(j.amount), " ", d and d.localised_name or j.item } }
		name.style.minimal_width = 140
		local bar = t.add{ type = "progressbar", value = j.total > 0 and j.done / j.total or 0,
			tooltip = { "fork-me-gui.progress", j.done, j.total } }
		bar.style.width = 90
		local status = G.label(t, status_text(j), 160)
		status.style.minimal_width = 160
		if j.active then
			t.add{ type = "button", caption = { "fork-me-craft.cancel" }, style = "red_button", tags = G.act("job_cancel", { id = j.id }) }
		else
			t.add{ type = "empty-widget" }
		end
	end
end

local function refresh_jobs(st, frame, net)
	local jobs = autocraft.jobs(net)
	local total, free = autocraft.cpu_summary(net)
	G.find(frame, "fork_me_jobs_info").caption = #jobs == 0 and { "fork-me-gui.no-jobs", total, free }
		or { "fork-me-gui.jobs-info", #jobs, total, free }
	local sig = {}
	for i, j in ipairs(jobs) do sig[i] = j.id .. ":" .. j.status .. ":" .. tostring(j.wait) .. ":" .. j.done .. "/" .. j.total end
	sig = table.concat(sig, ",")
	if st.jobs_shown == sig then return end
	st.jobs_shown = sig
	M.job_rows(G.find(frame, "fork_me_jobs"), jobs)
end

--- a cell's slot button for a cell list (terminal cells tab, drive window): fill in percent as the number
function M.cell_tooltip(c)
	local tip = { "", { "fork-me-gui.cell-fill", G.fmt(c.bytes), G.fmt(c.bytes_total), c.types, c.types_total } }
	if #c.partition > 0 then tip[#tip + 1] = { "fork-me-gui.cell-partitioned", #c.partition } end
	return tip
end

local function refresh_cells(st, frame, net)
	local drives = N.drives_of(net, true)
	local sig = {}
	for _, d in ipairs(drives) do
		sig[#sig + 1] = d.unit .. "p" .. d.priority
		for slot = 1, 10 do
			local c = d.cells[slot]
			sig[#sig + 1] = c and (c.name .. c.bytes .. "/" .. c.types .. "/" .. #c.partition) or "-"
		end
	end
	sig = table.concat(sig, ",")
	if st.cells_shown == sig then return end
	st.cells_shown = sig
	local t = G.find(frame, "fork_me_cells")
	t.clear()
	if #drives == 0 then
		t.add{ type = "label", caption = { "fork-me-gui.cells-none" } }
		t.add{ type = "empty-widget" }
		return
	end
	for _, d in ipairs(drives) do
		local head = t.add{ type = "flow", direction = "vertical" }
		head.add{ type = "sprite-button", sprite = "item/me-drive", style = "slot_button",
			tooltip = { "fork-me-gui.open-drive" }, tags = G.act("term_drive", { drive = d.unit }) }
		head.add{ type = "label", caption = { "fork-me-gui.priority-short", d.priority } }
		local row = t.add{ type = "table", column_count = COLUMNS, style = "filter_slot_table" }
		for slot = 1, 10 do
			local c = d.cells[slot]
			if c then
				local pct = c.bytes_total > 0 and math.floor(100 * c.bytes / c.bytes_total) or 0
				row.add{ type = "sprite-button", sprite = "item/" .. c.name, number = pct,
					style = #c.partition > 0 and "yellow_slot_button" or "slot_button", tooltip = M.cell_tooltip(c),
					tags = G.act("term_cell", { drive = d.unit, slot = slot }) }
			else
				row.add{ type = "sprite-button", style = "slot_button", enabled = false }
			end
		end
	end
end

function M.refresh(player, frame)
	frame = frame or G.window_of(player)
	local st = state()[player.index]
	if not (frame and st) then return false end
	local entity = st.entity
	if not (entity and entity.valid and player.can_reach_entity(entity)) then return false end
	local net_line, tabs = G.find(frame, "fork_me_net_line"), G.find(frame, "fork_me_tabs")
	if not (net_line and tabs) then return false end                    -- built by an older version
	local net, why = network(entity)
	if not net then
		net_line.caption = { "fork-me-net.status-" .. why }
		G.find(frame, "fork_me_grid").clear()
		st.shown, st.craft_shown, st.jobs_shown, st.cells_shown, st.plan_shown = nil, nil, nil, nil, nil
		return true
	end
	net_line.caption = status_line(net)
	local tab = TABS[tabs.selected_tab_index or 1]
	st.tab = tabs.selected_tab_index
	if tab == "storage" then refresh_storage(player, st, frame, net)
	elseif tab == "crafting" then refresh_crafting(st, frame, net)
	elseif tab == "jobs" then refresh_jobs(st, frame, net)
	else refresh_cells(st, frame, net) end
	return true
end

--- issue #28: shift + click in the inventory pane stores the stack, control + click every stack of that item
G.window("terminal", { open = open, refresh = function(player, frame) return M.refresh(player, frame) end,
	entities = { "me-terminal" }, hint = { "fork-me-gui.store-help" },
	shift = function(entity, stack)
		local n, why = M.store_stack(entity, stack)
		if not n then return why end
		if n == 0 then return "no-storage" end
		return nil
	end,
	control = function(entity, stack, inv)
		local n, why = M.store_inventory_item(inv, entity, stack.name, stack.quality.name, true)
		if not n then return why end
		if n == 0 then return "no-storage" end
		return nil
	end,
	message = G.net_message })

--------------------------------------------------------------------------------
--- actions
--------------------------------------------------------------------------------

local function st_of(player) return state()[player.index] end

G.on("term_search", function(event, player, el)
	if event.name ~= defines.events.on_gui_text_changed then return end
	local st = st_of(player)
	if not st then return end
	st.filter = el.text
	M.refresh(player)
end)

G.on("term_tab", function(event, player)
	if event.name ~= defines.events.on_gui_selected_tab_changed then return end
	M.refresh(player)
end)

G.on("term_sort", function(event, player, el)
	local st = st_of(player)
	if not st then return end
	st.sort = st.sort == "name" and "count" or "name"
	el.caption = { "fork-me-net.sort-" .. st.sort }
	M.refresh(player)
end)

G.on("term_kind", function(event, player, el)
	local st = st_of(player)
	if not st then return end
	st.kind = KINDS[st.kind or "all"] or "all"
	el.caption = { "fork-me-gui.kind-" .. st.kind }
	M.refresh(player)
end)

G.on("term_store", function(event, player)
	local st = st_of(player)
	if not st then return end
	local _, why = M.store_cursor(player, st.entity)
	report(player, why)
	M.refresh(player)
end)

--- Issue #67: what the network takes out of a chest behind a storage bus may come back within a few ticks (the bus reads
--- the chest again REREAD ticks after the take, scripts/fork-me-storagebus.lua), but the window is refreshed every 60 ticks.
--- So a take schedules one more refresh of the taker's window FOLLOW_TICKS later; a second take in the meantime changes
--- nothing (at most one per player in that time). The table is state (saved): every peer refreshes the same tick.
local FOLLOW_TICKS = 10

local function follow_up(player)
	local f = storage.fork_me_follow
	if not f then
		f = {}
		storage.fork_me_follow = f
	end
	if not f[player.index] then f[player.index] = game.tick + FOLLOW_TICKS end
end

--- every tick (control.lua): the refreshes that are due; one comparison while none is pending
function M.on_tick(tick)
	local f = storage.fork_me_follow
	if not f or next(f) == nil then return end
	for index, due in pairs(f) do
		if due <= tick then
			f[index] = nil
			local player = game.get_player(index)
			if player and player.connected then G.refresh_one(player) end
		end
	end
end

G.on("term_take", function(event, player, el)
	local st = st_of(player)
	if not (st and event.name == defines.events.on_gui_click) then return end
	local mode = event.shift and "inventory" or event.button == defines.mouse_button_type.right and "one" or "stack"
	local _, why = M.take(player, st.entity, el.tags.key, mode)
	report(player, why)
	M.refresh(player)
	follow_up(player)
end)

G.on("term_pick", function(event, player, el)
	local st = st_of(player)
	if not st then return end
	st.pick = el.tags.key
	M.refresh(player)
end)

G.on("term_amount", function(event, player, el)
	local st = st_of(player)
	if not st then return end
	st.amount = math.max(0, math.floor(tonumber(el.text) or 0))
	M.refresh(player)
end)

G.on("term_craft", function(event, player)
	local st = st_of(player)
	if not (st and st.pick) then return end
	local d = autocraft.describe(st.pick)
	if not d then return end
	local id, why, plan = M.start_craft(st.entity, st.pick, st.amount)
	if id then
		player.print({ d.fluid and "fork-me-craft.started-fluid" or "fork-me-craft.started", st.amount, d.localised_name })
		st.jobs_shown = nil
	elseif why == "missing" then
		player.print({ "fork-me-craft.plan-missing", autocraft.item_list(plan.missing, 8) })
	elseif why == "cpu-too-small" or why == "no-free-cpu" then
		player.print({ "fork-me-craft.error-" .. why, G.fmt(plan.bytes), G.fmt(plan.biggest or 0) })
	else
		player.print({ "fork-me-craft.error-" .. why })
	end
	M.refresh(player)
end)

--- also the CPU window's cancel button
G.on("job_cancel", function(event, player, el)
	M.cancel_job(el.tags.id)
	local st = st_of(player)
	if st then st.jobs_shown = nil end
	G.refresh_one(player)
end)

G.on("term_drive", function(event, player, el)
	local st = st_of(player)
	local drive = G.entity_by_unit(el.tags.drive)
	if st and st.entity and st.entity.valid and drive and drive.valid then G.open("drive", player, drive, { via = st.entity.unit_number }) end
end)

G.on("term_cell", function(event, player, el)
	local st = st_of(player)
	local drive = G.entity_by_unit(el.tags.drive)
	if st and st.entity and st.entity.valid and drive and drive.valid then G.open("cell", player, drive, { slot = el.tags.slot, via = st.entity.unit_number }) end
end)

remote.add_interface("gregtorio-me-terminal", {
	--- the lookup of the ME windows (their entity by unit number)
	entity_by_unit = function(unit) return G.entity_by_unit(unit) end,
	withdraw = function(terminal, target, name, quality, count) return M.withdraw(terminal, target, name, quality or "normal", count) end,
	store_stack = function(terminal, stack) return M.store_stack(terminal, stack) end,
	--- what the grid buttons do, for a cursor stack and a main inventory: mode "stack", "one" or "inventory"
	take = function(cursor, inventory, terminal, key, mode) return M.take_to(cursor, inventory, terminal, key, mode) end,
	--- the "Store item in hand" button and a click on the grid with something in the cursor
	store_cursor = function(cursor, terminal) return M.store_stack(terminal, cursor) end,
	--- a click on an item of the inventory row
	store_inventory_item = function(inventory, terminal, name, quality, all)
		return M.store_inventory_item(inventory, terminal, name, quality, all)
	end,
	--- the grid's entries for a search text, a sort ("count" or "name") and a kind ("all", "items", "fluids")
	--- `fresh` (tests, the benchmark): made from nothing, as at a first refresh, and not kept
	entries = function(terminal, filter, sort, kind, fresh)
		local net = network(terminal)
		return net and M.entries(net, filter, sort, kind, fresh) or {}
	end,
	--- issue #50, lever 8: { kept, resorted, sorted } since the load: lists given back unchanged, made from the last one, sorted
	--- with table.sort after too many moves
	entries_stats = function() return { kept = list_stats.kept, resorted = list_stats.resorted, sorted = list_stats.sorted } end,
	--- nil when the terminal works, else the reason
	problem = function(terminal) return problem(terminal) end,
	--- the crafting tab: preview and the Craft button; the jobs tab; the cells tab
	craft_preview = function(terminal, key, amount) return M.craft_preview(terminal, key, amount) end,
	start_craft = function(terminal, key, amount) return M.start_craft(terminal, key, amount) end,
	cancel_job = function(id) return M.cancel_job(id) end,
	jobs = function(terminal) return M.jobs(terminal) end,
	cells = function(terminal)
		local out = {}
		for _, d in ipairs(M.cells(terminal)) do out[#out + 1] = { unit = d.unit, priority = d.priority, cells = d.cells } end
		return out
	end,
	--- whether a click on an ME block opens its window for a cursor stack and the cursor's other flags
	--- (fork-me-gui.lua cursor_flags: blueprint, record, ghost, wire, damaged); returns the answer and the reason
	click_opens = function(stack, flags) return G.click_opens(stack, flags) end,
	--- open the terminal window for a player (the GUI is built and refreshed: catches errors in the window code)
	open = function(player, terminal) open(player, terminal) return G.window_of(player) ~= nil end,
	--- the tabs of the terminal window, in order (issue #130: four, the Patterns tab is the ME Pattern Terminal now)
	tabs = function() return { table.unpack(TABS) } end,
	--- select a tab of the open terminal and refresh it; false when it has no such tab
	show_tab = function(player, index)
		local frame = G.window_of(player)
		local tabs = frame and G.find(frame, "fork_me_tabs")
		if not tabs or index < 1 or index > #TABS then return false end
		tabs.selected_tab_index = index
		return M.refresh(player)
	end,
	--- pick a craftable resource and an amount as the crafting tab does
	pick = function(player, key, amount)
		local st = st_of(player)
		if not st then return false end
		st.pick, st.amount = key, amount or st.amount
		return M.refresh(player)
	end,
})

--------------------------------------------------------------------------------
--- events (every GUI event of the mod goes through here)
--------------------------------------------------------------------------------

--- Every open ME window is closed: a window built by an older version may lack elements the current refresh
--- expects (the player simply opens it again).
function M.on_configuration_changed()
	state()
	for index in pairs(storage.fork_me_terminal) do
		if not game.get_player(index) then storage.fork_me_terminal[index] = nil end
	end
	for _, player in pairs(game.players) do
		--- the frames of the windows and panels before R3
		for _, old in pairs({ "fork_me_terminal", "fork_me_drive", "fork_me_bus", "fork_ae2_provider",
			"fork_me_maintainer", "fork_me_circuit", "fork_me_fluid_interface" }) do
			for _, root in pairs({ player.gui.screen, player.gui.relative }) do
				local frame = root[old]
				if frame then frame.destroy() end
			end
		end
	end
	G.close_all()
	storage.fork_me_gui_bypass = nil
end

--- on_init of the mod (control.lua, after the hand-over of an older Gregtorio Continued's state, if any)
function M.on_init()
	state()
	N.rebuild()
end

--- the "open GUI" key (linked to the game's own): a cell in the cursor goes into a drive, an encoded pattern into a
--- pattern provider, else the entity's ME window opens (blocks without a vanilla window: drive, buses, provider,
--- controller). Nothing happens with a tool in the cursor (blueprint, planner, copy-paste, wire, ghost, an item
--- being built): the game uses the tool, as it does on a chest (G.click_opens).
script.on_event("fork-me-terminal-open", function(event)
	local player = game.get_player(event.player_index)
	if not (player and player.selected) then return end
	local e = player.selected
	G.clear_bypass(player)
	if not G.click_opens(player.cursor_stack, G.cursor_flags(player, e)) then return end
	if N.quick_insert(player, e) then return end
	if autocraft.quick_insert(player, e) then return end
	G.open_entity(player, e)
end)

--- entities with a vanilla window (terminal, CPU and maintainer lamps, combinator, tank, container): the ME
--- window replaces it
script.on_event(defines.events.on_gui_opened, function(event)
	if event.gui_type == defines.gui_type.entity and event.entity and event.entity.valid then
		G.open_entity(game.get_player(event.player_index), event.entity)
	end
end)

script.on_event(defines.events.on_gui_closed, function(event)
	G.on_closed(event)
end)

--- issue #28: the inventory pane of an open ME window follows the player's main inventory and cursor
script.on_event({ defines.events.on_player_main_inventory_changed, defines.events.on_player_cursor_stack_changed }, function(event)
	G.on_inventory_changed(event)
end)

script.on_event(defines.events.on_player_left_game, function(event)
	G.on_left(game.get_player(event.player_index))
end)

script.on_event({ defines.events.on_gui_click, defines.events.on_gui_text_changed, defines.events.on_gui_elem_changed,
	defines.events.on_gui_confirmed, defines.events.on_gui_checked_state_changed,
	defines.events.on_gui_switch_state_changed, defines.events.on_gui_selection_state_changed,
	defines.events.on_gui_selected_tab_changed, defines.events.on_gui_value_changed }, function(event)
	G.dispatch(event)
end)

local function refresh()
	N.slow_step()
	G.refresh_all()
end
script.on_nth_tick(REFRESH_TICKS, function() Sched.metered(refresh) end)

script.on_event(defines.events.on_player_removed, function(event)
	state()[event.player_index] = nil
	if storage.fork_me_gui_pane then storage.fork_me_gui_pane[event.player_index] = nil end
	if storage.fork_me_pterm_ui then storage.fork_me_pterm_ui[event.player_index] = nil end      -- (the ME Pattern Terminal's editor)
end)

return M
