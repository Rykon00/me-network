--------------------------------------------------------------------------------
--- FORK AE2: ME TERMINAL (runtime; issue #68: the central GUI of the ME network, scripts/fork-me-network.lua)
---   * Status line: network state, bytes and types used of the item cells and of the fluid cells, drives and
---     cells, the controller's power draw.
---   * Storage tab: search (item or fluid name), sort (amount or name), one grid with the items and then the
---     fluids (issue #68 step R2). Left click on an item: a stack into the cursor (with something in the cursor:
---     that is stored instead); right click: one item into the cursor; shift click: a stack into the inventory.
---     Fluids are shown with their amounts; they cannot be taken by hand (an ME Fluid Interface or a fluid
---     export bus takes them out). Below: the player's inventory (click: store all of that item, right click:
---     one stack).
---   * Crafting tab (autocrafting, scripts/fork-me-autocraft.lua): every item or fluid a pattern can make,
---     an amount field and a "Craft" button with a plan preview (what is missing), and the job list with
---     progress and a cancel button. Its look is redone in step R3.
---   * The GUI is refreshed once per second while it is open (only for players that have it open); the same
---     step runs the slow step of the network module (drive lights, sweep for vanished members).
---   * GUI events of every ME window are registered here and routed (a Factorio event has one handler):
---     drives (fork-me-network.lua), buses (fork-me-io.lua), fluid interfaces (fork-me-fluids.lua), level maintainers and circuit interfaces (fork-me-circuit.lua), pattern
---     providers (fork-me-autocraft.lua).
--- Every button calls a function of this module that the runtime test calls directly (take, store_cursor,
--- store_inventory_item, withdraw, store_stack).
--- State: storage.fork_me_terminal[player_index] = { entity, filter, sort }
--------------------------------------------------------------------------------

local N = require("scripts.fork-me-network")
local autocraft = require("scripts.fork-me-autocraft")
local fluids = require("scripts.fork-me-fluids")
local circuit = require("scripts.fork-me-circuit")
local io = require("scripts.fork-me-io")

local M = {}

local FRAME = "fork_me_terminal"
local MAX_BUTTONS = 400
local COLUMNS = 10
local REFRESH_TICKS = 60

local function state()
	storage.fork_me_terminal = storage.fork_me_terminal or {}
	return storage.fork_me_terminal
end

--- breadth first search for a named element below `root`
local function find(root, name)
	local queue, i = { root }, 1
	while queue[i] do
		for _, child in pairs(queue[i].children) do
			if child.name == name then return child end
			queue[#queue + 1] = child
		end
		i = i + 1
	end
end

local function close(player)
	local frame = player.gui.screen[FRAME]
	if frame then frame.destroy() end
	state()[player.index] = nil
end

--- nil when the terminal can be used, otherwise the reason as a locale key of [fork-me-net] (status-...)
local function problem(entity)
	if not (entity and entity.valid) then return "no-network" end
	if entity.status == defines.entity_status.no_power then return "no-power-terminal" end
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

local function format_bytes(n)
	if n >= 1048576 then return string.format("%.1fM", n / 1048576) end
	if n >= 1024 then return string.format("%.1fk", n / 1024) end
	return tostring(n)
end

local function status_line(net)
	local st = N.stats(net)
	return { "fork-me-net.terminal-status", format_bytes(st.bytes), format_bytes(st.bytes_total), st.types, st.types_total,
		st.drives, st.cells, string.format("%.0f", st.power / 1000), format_bytes(st.fbytes), format_bytes(st.fbytes_total),
		st.ftypes, st.ftypes_total, st.fluid_cells }
end

--- the entries of the storage grid: the items, then the fluids (key "fluid/<name>", fluid = true), each filtered
--- by the search and sorted by amount or name
function M.entries(net, filter, sort)
	filter = (filter or ""):lower():gsub("%s+", "-")
	local items, liquids = {}, {}
	for _, c in pairs(N.contents(net)) do
		if prototypes.item[c.name] and (filter == "" or c.name:find(filter, 1, true)) then items[#items + 1] = c end
	end
	for name, amount in pairs(N.fluid_contents(net)) do
		if prototypes.fluid[name] and (filter == "" or name:find(filter, 1, true)) then
			liquids[#liquids + 1] = { key = "fluid/" .. name, name = name, count = amount, fluid = true }
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
	table.sort(items, order)
	table.sort(liquids, order)
	for _, f in ipairs(liquids) do items[#items + 1] = f end
	return items
end

local function refresh(player)
	local st = state()[player.index]
	local frame = player.gui.screen[FRAME]
	if not (st and frame) then return end
	local entity = st.entity
	local status, grid = find(frame, "fork_me_status"), find(frame, "fork_me_grid")
	local inv_grid, net_line = find(frame, "fork_me_inv_grid"), find(frame, "fork_me_net_line")
	if not (status and grid and inv_grid and net_line) then   -- a frame built by an older version
		close(player)
		return
	end
	local net, why = network(entity)
	if not net then
		grid.clear()
		st.shown = nil
		net_line.caption = ""
		status.caption = { "fork-me-net.status-" .. why }
		status.visible = true
		return
	end
	net_line.caption = status_line(net)
	M.refresh_crafting(player, frame, entity)
	local items = M.entries(net, st.filter, st.sort)
	local main = player.get_main_inventory()
	local own = main and main.get_contents() or {}
	table.sort(own, function(a, b)
		if a.name ~= b.name then return a.name < b.name end
		return (a.quality or "normal") < (b.quality or "normal")
	end)
	--- unchanged since the last refresh: keep the buttons (and their open tooltips)
	local sig = { st.sort or "count" }
	for i = 1, math.min(#items, MAX_BUTTONS) do sig[#sig + 1] = items[i].key .. "=" .. items[i].count end
	for _, c in ipairs(own) do sig[#sig + 1] = "inv/" .. c.name .. "/" .. (c.quality or "normal") .. "=" .. c.count end
	sig = table.concat(sig, ",")
	if st.shown == sig then return end
	st.shown = sig
	grid.clear()
	inv_grid.clear()
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
		if c.fluid then
			grid.add{
				type = "sprite-button",
				sprite = "fluid/" .. c.name,
				number = math.floor(c.count),
				style = "slot_button",
				tooltip = { "fork-me-terminal.fluid-tooltip", prototypes.fluid[c.name].localised_name, fluids.format(c.count) },
				tags = { fork_me_key = c.key },
			}
		else
			grid.add{
				type = "sprite-button",
				sprite = "item/" .. c.name,
				number = c.count,
				style = c.special and "yellow_slot_button" or "slot_button",
				elem_tooltip = { type = "item-with-quality", name = c.name, quality = c.quality },
				tags = { fork_me_key = c.key },
			}
		end
	end
	for _, c in ipairs(own) do
		if prototypes.item[c.name] then
			inv_grid.add{
				type = "sprite-button", sprite = "item/" .. c.name, number = c.count, style = "slot_button",
				elem_tooltip = { type = "item-with-quality", name = c.name, quality = c.quality or "normal" },
				tags = { fork_me_inv = c.name, fork_me_quality = c.quality or "normal" },
			}
		end
	end
end
M.refresh = refresh

local function open(player, entity)
	if not (entity and entity.valid and entity.name == "me-terminal") then return end
	if not player.can_reach_entity(entity) then return end
	local st = state()[player.index]
	local frame = player.gui.screen[FRAME]
	if st and frame and st.entity == entity then
		player.opened = frame
		return
	end
	close(player)
	frame = player.gui.screen.add{ type = "frame", name = FRAME, direction = "vertical", caption = { "fork-me-terminal.title" } }
	frame.auto_center = true
	local top = frame.add{ type = "flow", direction = "horizontal" }
	top.style.vertical_align = "center"
	top.add{ type = "label", caption = { "fork-me-terminal.search" } }
	top.add{ type = "textfield", name = "fork_me_search" }
	top.add{ type = "button", name = "fork_me_sort", caption = { "fork-me-net.sort-count" }, tooltip = { "fork-me-net.sort-tooltip" } }
	top.add{ type = "button", name = "fork_me_store", caption = { "fork-me-terminal.store-hand" } }
	local net_line = frame.add{ type = "label", name = "fork_me_net_line" }
	net_line.style.single_line = false
	net_line.style.maximal_width = 40 * COLUMNS
	local status = frame.add{ type = "label", name = "fork_me_status" }
	status.style.single_line = false
	status.style.maximal_width = 40 * COLUMNS
	local tabs = frame.add{ type = "tabbed-pane", name = "fork_me_tabs" }
	local storage_tab = tabs.add{ type = "tab", caption = { "fork-me-terminal.tab-storage" } }
	local craft_tab = tabs.add{ type = "tab", caption = { "fork-me-craft.tab" } }
	local storage_flow = tabs.add{ type = "flow", direction = "vertical" }
	local help = storage_flow.add{ type = "label", caption = { "fork-me-net.terminal-help" } }
	help.style.single_line = false
	help.style.maximal_width = 40 * COLUMNS
	local scroll = storage_flow.add{ type = "scroll-pane", name = "fork_me_scroll", horizontal_scroll_policy = "never" }
	scroll.style.maximal_height = 360
	scroll.style.minimal_width = 40 * COLUMNS + 12
	scroll.add{ type = "table", name = "fork_me_grid", column_count = COLUMNS }
	storage_flow.add{ type = "line" }
	storage_flow.add{ type = "label", caption = { "fork-me-net.inventory" }, style = "caption_label" }
	local inv = storage_flow.add{ type = "scroll-pane", horizontal_scroll_policy = "never" }
	inv.style.maximal_height = 130
	inv.style.minimal_width = 40 * COLUMNS + 12
	inv.add{ type = "table", name = "fork_me_inv_grid", column_count = COLUMNS }
	tabs.add_tab(storage_tab, storage_flow)
	tabs.add_tab(craft_tab, M.build_crafting(tabs))
	state()[player.index] = { entity = entity, filter = "", sort = "count" }
	player.opened = frame
	refresh(player)
end
M.open = open


--------------------------------------------------------------------------------
--- crafting tab
--------------------------------------------------------------------------------

local MAX_CRAFT_BUTTONS = 200

function M.build_crafting(parent)
	local flow = parent.add{ type = "flow", name = "fork_ae2_flow", direction = "vertical" }
	local info = flow.add{ type = "label", name = "fork_ae2_info" }
	info.style.single_line = false
	info.style.maximal_width = 40 * COLUMNS
	local scroll = flow.add{ type = "scroll-pane", name = "fork_ae2_scroll", horizontal_scroll_policy = "never" }
	scroll.style.maximal_height = 180
	scroll.style.minimal_width = 40 * COLUMNS + 12
	scroll.add{ type = "table", name = "fork_ae2_grid", column_count = COLUMNS }
	local panel = flow.add{ type = "flow", name = "fork_ae2_panel", direction = "horizontal" }
	panel.style.vertical_align = "center"
	panel.visible = false
	panel.add{ type = "sprite", name = "fork_ae2_icon" }
	panel.add{ type = "label", name = "fork_ae2_name" }
	local amount = panel.add{ type = "textfield", name = "fork_ae2_amount", text = "1", numeric = true,
		allow_decimal = false, allow_negative = false }
	amount.style.width = 80
	panel.add{ type = "button", name = "fork_ae2_craft", caption = { "fork-me-craft.craft" } }
	local plan = flow.add{ type = "label", name = "fork_ae2_plan" }
	plan.style.single_line = false
	plan.style.maximal_width = 40 * COLUMNS
	flow.add{ type = "line" }
	flow.add{ type = "label", caption = { "fork-me-craft.jobs" }, style = "caption_label" }
	local jobs = flow.add{ type = "scroll-pane", name = "fork_ae2_jobs_scroll", horizontal_scroll_policy = "never" }
	jobs.style.maximal_height = 160
	jobs.style.minimal_width = 40 * COLUMNS + 12
	jobs.add{ type = "table", name = "fork_ae2_jobs", column_count = 5 }
	return flow
end

local function status_text(j)
	if j.status == "running" then
		return j.wait and { "fork-me-craft.wait-" .. j.wait } or { "fork-me-craft.status-running" }
	elseif j.status == "failed" then
		return { "fork-me-craft.status-failed", j.reason or "" }
	end
	return { "fork-me-craft.status-" .. j.status }
end

--- plan preview for the selected resource and amount; enables or disables the Craft button
local function update_plan(frame, net)
	local panel = find(frame, "fork_ae2_panel")
	local label, button = find(frame, "fork_ae2_plan"), find(frame, "fork_ae2_craft")
	local key = panel.tags and panel.tags.item
	if not key then
		panel.visible = false
		label.caption = ""
		return
	end
	panel.visible = true
	local amount = tonumber(find(frame, "fork_ae2_amount").text) or 0
	local total = autocraft.cpu_summary(net)
	local plan = amount >= 1 and autocraft.plan(net, key, amount) or nil
	button.enabled = plan ~= nil and plan.ok and total > 0
	if not plan then
		label.caption = { "fork-me-craft.bad-amount" }
	elseif total == 0 then
		label.caption = { "fork-me-craft.no-cpu" }
	elseif plan.ok then
		label.caption = { "fork-me-craft.plan-ok", plan.runs, #plan.steps, autocraft.item_list(plan.reserve, 6) }
	else
		local text = { "", { "fork-me-craft.plan-missing", autocraft.item_list(plan.missing, 8) } }
		if next(plan.loops) then text[#text + 1] = { "fork-me-craft.plan-loop", autocraft.item_list(plan.loops, 4) } end
		label.caption = text
	end
end

local function refresh_jobs(st, frame, net)
	local jobs = autocraft.jobs(net)
	local sig = {}
	for i, j in ipairs(jobs) do sig[i] = j.id .. ":" .. j.status .. ":" .. tostring(j.wait) .. ":" .. j.done .. "/" .. j.total end
	sig = table.concat(sig, ",")
	if st.jobs_shown == sig then return end
	st.jobs_shown = sig
	local grid = find(frame, "fork_ae2_jobs")
	grid.clear()
	for _, j in ipairs(jobs) do
		local d = autocraft.describe(j.item)
		grid.add{ type = "sprite", sprite = d and d.sprite or nil }
		local prefix = (d and d.fluid) and (j.amount .. " ") or (j.amount .. "x ")
		local name = grid.add{ type = "label", caption = { "", prefix, d and d.localised_name or j.item } }
		name.style.minimal_width = 160
		local bar = grid.add{ type = "progressbar", value = j.total > 0 and j.done / j.total or 0 }
		bar.style.width = 100
		local status = grid.add{ type = "label", caption = status_text(j) }
		status.style.minimal_width = 160
		if j.active then
			grid.add{ type = "button", caption = { "fork-me-craft.cancel" }, tags = { fork_ae2_cancel = j.id } }
		else
			grid.add{ type = "empty-widget" }
		end
	end
end

function M.refresh_crafting(player, frame, entity)
	local st = state()[player.index]
	local tabs = frame.fork_me_tabs
	if not (st and tabs and tabs.selected_tab_index == 2) then return end
	local net = network(entity)
	if not net then return end
	local info = find(frame, "fork_ae2_info")
	local total, free, _, slots = autocraft.cpu_summary(net)
	local keys, ignored = autocraft.craftable(net)
	info.caption = { "fork-me-craft.info", total, free, #keys, ignored.total or 0, autocraft.ignored_list(ignored), slots }
	local fluid_totals = fluids.totals(net)

	local filter = (st.filter or ""):lower():gsub("%s+", "-")
	local shown, sig = {}, {}
	for _, key in pairs(keys) do
		if filter == "" or key:find(filter, 1, true) then
			if #shown < MAX_CRAFT_BUTTONS then
				local d = autocraft.describe(key)
				if d then
					local count = d.fluid and (fluid_totals[d.name] or 0) or N.count(net, key, "normal")
					shown[#shown + 1] = { key = key, d = d, count = count }
					sig[#sig + 1] = key .. "=" .. count
				end
			end
		end
	end
	sig = table.concat(sig, ",")
	if st.craft_shown ~= sig then
		st.craft_shown = sig
		local grid = find(frame, "fork_ae2_grid")
		grid.clear()
		for _, c in pairs(shown) do
			grid.add{
				type = "sprite-button", sprite = c.d.sprite, number = c.count, style = "slot_button",
				elem_tooltip = { type = c.d.fluid and "fluid" or "item", name = c.d.name }, tags = { fork_ae2_pick = c.key },
			}
		end
	end
	update_plan(frame, net)
	refresh_jobs(st, frame, net)
end

local function pick_craftable(player, key)
	local frame = player.gui.screen[FRAME]
	local st = state()[player.index]
	if not (frame and st) then return end
	local d = autocraft.describe(key)
	if not d then return end
	local panel = find(frame, "fork_ae2_panel")
	panel.tags = { item = key }
	find(frame, "fork_ae2_icon").sprite = d.sprite
	find(frame, "fork_ae2_name").caption = d.localised_name
	local net = network(st.entity)
	if net then update_plan(frame, net) end
end

local function start_craft(player)
	local frame = player.gui.screen[FRAME]
	local st = state()[player.index]
	if not (frame and st) then return end
	local key = find(frame, "fork_ae2_panel").tags.item
	if not key then return end
	local d = autocraft.describe(key)
	if not d then return end
	local amount = tonumber(find(frame, "fork_ae2_amount").text) or 0
	local id, why, plan = autocraft.start(st.entity, key, amount)
	if id then
		player.print({ d.fluid and "fork-me-craft.started-fluid" or "fork-me-craft.started", amount, d.localised_name })
		st.jobs_shown = nil
	elseif why == "missing" then
		player.print({ "fork-me-craft.plan-missing", autocraft.item_list(plan.missing, 8) })
	else
		player.print({ "fork-me-craft.error-" .. why })
	end
end

local function cancel_craft(player, id)
	autocraft.cancel(id)
	local st = state()[player.index]
	if st then st.jobs_shown = nil end
end

--------------------------------------------------------------------------------
--- the storage tab's functions (also the remote interface: the runtime test calls the same code)
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
		local problem, ckey = N.storable(cursor)
		if problem or ckey ~= key or cursor.count >= proto.stack_size then return 0 end
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
--- Stacks with own data (tags) are stored stack by stack. Returns the count stored, or nil and a reason.
function M.store_inventory_item(inv, terminal, name, quality, all)
	local net, why = network(terminal)
	if not net then return nil, why end
	if not inv then return 0 end
	local total, reason = 0, nil
	for i = 1, #inv do
		local stack = inv[i]
		if stack.valid_for_read and stack.name == name and stack.quality.name == (quality or "normal") then
			local n, w = N.insert_stack(net, stack)
			if n then total = total + n else reason = w end
			if not all or reason then break end
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

remote.add_interface("gregtorio-me-terminal", {
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
	--- the grid's entries for a search text and a sort ("count" or "name"): { { key, name, quality, count } }
	entries = function(terminal, filter, sort)
		local net = network(terminal)
		return net and M.entries(net, filter, sort) or {}
	end,
	--- nil when the terminal works, else the reason
	problem = function(terminal) return problem(terminal) end,
})

--------------------------------------------------------------------------------
--- events
--------------------------------------------------------------------------------

--- Every open terminal is closed: a frame built by an older version may lack elements the
--- current refresh expects (the player simply opens it again).
function M.on_configuration_changed()
	state()
	for index in pairs(storage.fork_me_terminal) do
		local player = game.get_player(index)
		if player then close(player) else storage.fork_me_terminal[index] = nil end
	end
	for _, player in pairs(game.players) do
		local frame = player.gui.screen[FRAME]
		if frame then frame.destroy() end
	end
end

script.on_init(function()
	state()
	N.rebuild()
end)

--- the "open GUI" key: the terminal here, drives (network module), buses (I/O module), the pattern provider
--- (autocrafting module)
script.on_event("fork-me-terminal-open", function(event)
	local player = game.get_player(event.player_index)
	if not (player and player.selected) then return end
	local e = player.selected
	if e.name == "me-terminal" then
		open(player, e)
	elseif not N.on_open_input(player, e) and not io.on_open_input(player, e) then
		autocraft.on_open_input(player, e)
	end
end)

script.on_event(defines.events.on_gui_opened, function(event)
	if fluids.on_gui_opened(event) then return end
	if circuit.on_gui_opened(event) then return end
	if event.gui_type == defines.gui_type.entity and event.entity and event.entity.valid
		and event.entity.name == "me-terminal" then
		open(game.get_player(event.player_index), event.entity)
	end
end)

script.on_event(defines.events.on_gui_closed, function(event)
	if fluids.on_gui_closed(event) then return end
	if circuit.on_gui_closed(event) then return end
	if autocraft.on_gui_closed(event) then return end
	if N.on_gui_closed(event) then return end
	if io.on_gui_closed(event) then return end
	if event.element and event.element.valid and event.element.name == FRAME then
		close(game.get_player(event.player_index))
	end
end)

script.on_event(defines.events.on_gui_click, function(event)
	local el = event.element
	if not (el and el.valid) then return end
	if autocraft.on_gui_click(event) then return end
	if N.on_gui_click(event) then return end
	local player = game.get_player(event.player_index)
	local st = state()[player.index]
	if el.tags and el.tags.fork_me_key then
		if not st then return end
		local mode = event.shift and "inventory" or event.button == defines.mouse_button_type.right and "one" or "stack"
		local _, why = M.take(player, st.entity, el.tags.fork_me_key, mode)
		report(player, why)
		refresh(player)
	elseif el.tags and el.tags.fork_me_inv then
		if not st then return end
		local _, why = M.store_inventory_item(player.get_main_inventory(), st.entity, el.tags.fork_me_inv, el.tags.fork_me_quality,
			event.button ~= defines.mouse_button_type.right)
		report(player, why)
		refresh(player)
	elseif el.tags and el.tags.fork_ae2_pick then
		pick_craftable(player, el.tags.fork_ae2_pick)
	elseif el.tags and el.tags.fork_ae2_cancel then
		cancel_craft(player, el.tags.fork_ae2_cancel)
		refresh(player)
	elseif el.name == "fork_ae2_craft" then
		start_craft(player)
		refresh(player)
	elseif el.name == "fork_me_store" then
		if not st then return end
		local _, why = M.store_cursor(player, st.entity)
		report(player, why)
		refresh(player)
	elseif el.name == "fork_me_sort" then
		if not st then return end
		st.sort = st.sort == "name" and "count" or "name"
		el.caption = { "fork-me-net.sort-" .. st.sort }
		refresh(player)
	end
end)

script.on_event(defines.events.on_gui_text_changed, function(event)
	if fluids.on_gui_text_changed(event) then return end
	if circuit.on_gui_text_changed(event) then return end
	local name = event.element.name
	local st = state()[event.player_index]
	if not st then return end
	if name == "fork_me_search" then
		st.filter = event.element.text
		refresh(game.get_player(event.player_index))
	elseif name == "fork_ae2_amount" then
		refresh(game.get_player(event.player_index))
	end
end)

script.on_event(defines.events.on_gui_switch_state_changed, function(event)
	fluids.on_gui_switch_state_changed(event)
end)

script.on_event(defines.events.on_gui_elem_changed, function(event)
	if fluids.on_gui_elem_changed(event) then return end
	if io.on_gui_elem_changed(event) then return end
	circuit.on_gui_elem_changed(event)
end)

script.on_event(defines.events.on_gui_confirmed, function(event)
	if fluids.on_gui_confirmed(event) then return end
	circuit.on_gui_confirmed(event)
end)

script.on_event(defines.events.on_gui_checked_state_changed, function(event)
	circuit.on_gui_checked_state_changed(event)
end)

script.on_event(defines.events.on_gui_selected_tab_changed, function(event)
	if event.element and event.element.valid and event.element.name == "fork_me_tabs" then
		refresh(game.get_player(event.player_index))
	end
end)

script.on_nth_tick(REFRESH_TICKS, function()
	N.slow_step()
	local terminals = storage.fork_me_terminal
	if not terminals or next(terminals) == nil then return end
	for index, st in pairs(terminals) do
		local player = game.get_player(index)
		if not (player and player.valid) then
			terminals[index] = nil
		elseif not (st.entity.valid and player.can_reach_entity(st.entity)) then
			close(player)
		else
			refresh(player)
		end
	end
end)

script.on_event(defines.events.on_player_removed, function(event)
	state()[event.player_index] = nil
end)

return M
