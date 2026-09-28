--------------------------------------------------------------------------------
--- FORK AE2: ME TERMINAL AND ME INTERFACE (runtime)
--- The ME network is the logistic network (see prototypes/120-fork-ae2.lua), so the only
--- script parts are event driven:
---   * ME Terminal: opening it shows a GUI with the contents of the logistic network at
---     its position; clicking an item moves it from network storage into the player's
---     inventory, the item in hand can be stored in the network. While a terminal GUI is
---     open it is refreshed once per second (only for players that have it open).
---   * ME Interface: "trash unrequested" is switched on when a player places one by hand.
---   * Crafting tab (autocrafting, scripts/fork-me-autocraft.lua): every item a pattern can make,
---     an amount field and a "Craft" button with a plan preview (what is missing), and the job list
---     with progress and a cancel button. Selected item and amount live in the GUI elements (tags,
---     text field); jobs live in storage.fork_ae2.
--- State: storage.fork_me_terminal[player_index] = { entity = LuaEntity, filter = string }
--------------------------------------------------------------------------------

local autocraft = require("scripts.fork-me-autocraft")

local M = {}

local FRAME = "fork_me_terminal"
local MAX_BUTTONS = 400
local COLUMNS = 10
local REFRESH_TICKS = 60

local function state()
	storage.fork_me_terminal = storage.fork_me_terminal or {}
	return storage.fork_me_terminal
end

local function network_of(entity)
	return entity.surface.find_logistic_network_by_position(entity.position, entity.force)
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

--- nil when the terminal can be used, otherwise the reason as a locale key
local function problem(entity)
	if entity.status == defines.entity_status.no_power then return "no-power" end
	if not network_of(entity) then return "no-network" end
	return nil
end

local function refresh(player)
	local st = state()[player.index]
	local frame = player.gui.screen[FRAME]
	if not (st and frame) then return end
	local entity = st.entity
	local status, grid = frame.fork_me_status, find(frame, "fork_me_grid")
	local why = problem(entity)
	if why then
		grid.clear()
		st.shown = nil
		status.caption = { "fork-me-terminal." .. why }
		status.visible = true
		return
	end
	M.refresh_crafting(player, frame, entity)
	local filter = (st.filter or ""):lower():gsub("%s+", "-")
	local items = {}
	for _, c in pairs(network_of(entity).get_contents()) do
		if filter == "" or c.name:find(filter, 1, true) then items[#items + 1] = c end
	end
	table.sort(items, function(a, b)
		if a.count ~= b.count then return a.count > b.count end
		return a.name < b.name
	end)
	--- unchanged since the last refresh: keep the buttons (and their open tooltips)
	local sig = {}
	for i = 1, math.min(#items, MAX_BUTTONS) do sig[i] = items[i].name .. "/" .. (items[i].quality or "normal") .. "=" .. items[i].count end
	sig = table.concat(sig, ",")
	if st.shown == sig then return end
	st.shown = sig
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
		if prototypes.item[c.name] then
			grid.add{
				type = "sprite-button",
				sprite = "item/" .. c.name,
				number = c.count,
				style = "slot_button",
				elem_tooltip = { type = "item-with-quality", name = c.name, quality = c.quality },
				tags = { fork_me_item = c.name, fork_me_quality = c.quality },
			}
		end
	end
end

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
	top.add{ type = "button", name = "fork_me_store", caption = { "fork-me-terminal.store-hand" } }
	local status = frame.add{ type = "label", name = "fork_me_status" }
	status.style.single_line = false
	status.style.maximal_width = 40 * COLUMNS
	local tabs = frame.add{ type = "tabbed-pane", name = "fork_me_tabs" }
	local storage_tab = tabs.add{ type = "tab", caption = { "fork-me-terminal.tab-storage" } }
	local craft_tab = tabs.add{ type = "tab", caption = { "fork-me-craft.tab" } }
	local storage_flow = tabs.add{ type = "flow", direction = "vertical" }
	local scroll = storage_flow.add{ type = "scroll-pane", name = "fork_me_scroll", horizontal_scroll_policy = "never" }
	scroll.style.maximal_height = 400
	scroll.style.minimal_width = 40 * COLUMNS + 12
	scroll.add{ type = "table", name = "fork_me_grid", column_count = COLUMNS }
	tabs.add_tab(storage_tab, storage_flow)
	tabs.add_tab(craft_tab, M.build_crafting(tabs))
	state()[player.index] = { entity = entity, filter = "" }
	player.opened = frame
	refresh(player)
end


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

--- plan preview for the selected item and amount; enables or disables the Craft button
local function update_plan(frame, net)
	local panel = find(frame, "fork_ae2_panel")
	local label, button = find(frame, "fork_ae2_plan"), find(frame, "fork_ae2_craft")
	local item = panel.tags and panel.tags.item
	if not item then
		panel.visible = false
		label.caption = ""
		return
	end
	panel.visible = true
	local amount = tonumber(find(frame, "fork_ae2_amount").text) or 0
	local total = autocraft.cpu_summary(net)
	local plan = amount >= 1 and autocraft.plan(net, item, amount) or nil
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
		grid.add{ type = "sprite", sprite = "item/" .. j.item }
		local name = grid.add{ type = "label", caption = { "", j.amount .. "x ", prototypes.item[j.item].localised_name } }
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
	local net = network_of(entity)
	local info = find(frame, "fork_ae2_info")
	local total, free = autocraft.cpu_summary(net)
	local names, ignored = autocraft.craftable(net)
	info.caption = { "fork-me-craft.info", total, free, #names, ignored }

	local filter = (st.filter or ""):lower():gsub("%s+", "-")
	local shown, sig = {}, {}
	for _, name in pairs(names) do
		if filter == "" or name:find(filter, 1, true) then
			if #shown < MAX_CRAFT_BUTTONS then
				local count = net.get_item_count{ name = name, quality = "normal" }
				shown[#shown + 1] = { name = name, count = count }
				sig[#sig + 1] = name .. "=" .. count
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
				type = "sprite-button", sprite = "item/" .. c.name, number = c.count, style = "slot_button",
				elem_tooltip = { type = "item", name = c.name }, tags = { fork_ae2_pick = c.name },
			}
		end
	end
	update_plan(frame, net)
	refresh_jobs(st, frame, net)
end

local function pick_craftable(player, name)
	local frame = player.gui.screen[FRAME]
	local st = state()[player.index]
	if not (frame and st) then return end
	local panel = find(frame, "fork_ae2_panel")
	panel.tags = { item = name }
	find(frame, "fork_ae2_icon").sprite = "item/" .. name
	find(frame, "fork_ae2_name").caption = prototypes.item[name].localised_name
	update_plan(frame, network_of(st.entity))
end

local function start_craft(player)
	local frame = player.gui.screen[FRAME]
	local st = state()[player.index]
	if not (frame and st) then return end
	local item = find(frame, "fork_ae2_panel").tags.item
	if not item then return end
	local amount = tonumber(find(frame, "fork_ae2_amount").text) or 0
	local id, why, plan = autocraft.start(st.entity, item, amount)
	if id then
		player.print({ "fork-me-craft.started", amount, prototypes.item[item].localised_name })
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

--- Move up to `count` items from the network at `terminal` into `target` (anything with
--- insert/remove_item: LuaPlayer, LuaEntity, LuaInventory). Returns the number moved.
function M.withdraw(terminal, target, name, quality, count)
	if not (terminal and terminal.valid) or problem(terminal) then return 0 end
	local network = network_of(terminal)
	count = math.min(count, network.get_item_count({ name = name, quality = quality }))
	if count <= 0 then return 0 end
	local inserted = target.insert{ name = name, quality = quality, count = count }
	if inserted <= 0 then return 0 end
	local removed = network.remove_item{ name = name, quality = quality, count = inserted }
	if removed < inserted then
		target.remove_item{ name = name, quality = quality, count = inserted - removed }
	end
	return removed
end

--- Store a LuaItemStack in the network at `terminal`.
--- Returns the number of items stored, or nil and a locale key.
function M.store_stack(terminal, stack)
	if not (terminal and terminal.valid) then return nil, "no-network" end
	local why = problem(terminal)
	if why then return nil, why end
	if not (stack and stack.valid_for_read) then return 0 end
	if stack.item then return nil, "cannot-store" end   -- items with own data (blueprints, armor, ...)
	local inserted = network_of(terminal).insert(stack)
	if inserted <= 0 then return nil, "no-storage" end
	if inserted >= stack.count then stack.clear() else stack.count = stack.count - inserted end
	return inserted
end

local function take(player, name, quality, button, shift)
	local st = state()[player.index]
	if not st then return end
	local stack = prototypes.item[name].stack_size
	local want = stack
	if shift then want = stack * 10 elseif button == defines.mouse_button_type.right then want = math.ceil(stack / 2) end
	M.withdraw(st.entity, player, name, quality, want)
end

local function store_hand(player)
	local st = state()[player.index]
	if not st then return end
	local _, why = M.store_stack(st.entity, player.cursor_stack)
	if why and why ~= "no-power" and why ~= "no-network" then player.print({ "fork-me-terminal." .. why }) end
end

--- Other mods and the devcheck runtime test can use the same code paths
remote.add_interface("gregtorio-me-terminal", {
	withdraw = function(terminal, target, name, quality, count) return M.withdraw(terminal, target, name, quality or "normal", count) end,
	store_stack = function(terminal, stack) return M.store_stack(terminal, stack) end,
})

--------------------------------------------------------------------------------
--- events
--------------------------------------------------------------------------------

function M.on_built(entity)
	if entity and entity.valid and entity.name == "me-interface" then
		local point = entity.get_requester_point()
		if point then point.trash_not_requested = true end
	end
end

function M.on_configuration_changed()
	state()
	for index, st in pairs(storage.fork_me_terminal) do
		local player = game.get_player(index)
		if not (player and st.entity and st.entity.valid) then
			if player then close(player) else storage.fork_me_terminal[index] = nil end
		end
	end
end

script.on_init(function() state() end)

script.on_event("fork-me-terminal-open", function(event)
	local player = game.get_player(event.player_index)
	if player and player.selected and player.selected.name == "me-terminal" then
		open(player, player.selected)
	end
end)

script.on_event(defines.events.on_gui_opened, function(event)
	if event.gui_type == defines.gui_type.entity and event.entity and event.entity.valid
		and event.entity.name == "me-terminal" then
		open(game.get_player(event.player_index), event.entity)
	end
end)

script.on_event(defines.events.on_gui_closed, function(event)
	if event.element and event.element.valid and event.element.name == FRAME then
		close(game.get_player(event.player_index))
	end
end)

script.on_event(defines.events.on_gui_click, function(event)
	local el = event.element
	if not (el and el.valid) then return end
	local player = game.get_player(event.player_index)
	if el.tags and el.tags.fork_me_item then
		take(player, el.tags.fork_me_item, el.tags.fork_me_quality, event.button, event.shift)
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
		store_hand(player)
		refresh(player)
	end
end)

script.on_event(defines.events.on_gui_text_changed, function(event)
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

script.on_event(defines.events.on_gui_selected_tab_changed, function(event)
	if event.element and event.element.valid and event.element.name == "fork_me_tabs" then
		refresh(game.get_player(event.player_index))
	end
end)

script.on_nth_tick(REFRESH_TICKS, function()
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
