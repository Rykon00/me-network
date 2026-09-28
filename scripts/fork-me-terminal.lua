--------------------------------------------------------------------------------
--- FORK AE2: ME TERMINAL AND ME INTERFACE (runtime)
--- The ME network is the logistic network (see prototypes/120-fork-ae2.lua), so the only
--- script parts are event driven:
---   * ME Terminal: opening it shows a GUI with the contents of the logistic network at
---     its position; clicking an item moves it from network storage into the player's
---     inventory, the item in hand can be stored in the network. While a terminal GUI is
---     open it is refreshed once per second (only for players that have it open).
---   * ME Interface: "trash unrequested" is switched on when a player places one by hand.
--- State: storage.fork_me_terminal[player_index] = { entity = LuaEntity, filter = string }
--------------------------------------------------------------------------------

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
	local status, grid = frame.fork_me_status, frame.fork_me_scroll.fork_me_grid
	local why = problem(entity)
	if why then
		grid.clear()
		st.shown = nil
		status.caption = { "fork-me-terminal." .. why }
		status.visible = true
		return
	end
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
	local scroll = frame.add{ type = "scroll-pane", name = "fork_me_scroll", horizontal_scroll_policy = "never" }
	scroll.style.maximal_height = 400
	scroll.style.minimal_width = 40 * COLUMNS + 12
	scroll.add{ type = "table", name = "fork_me_grid", column_count = COLUMNS }
	state()[player.index] = { entity = entity, filter = "" }
	player.opened = frame
	refresh(player)
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
	elseif el.name == "fork_me_store" then
		store_hand(player)
		refresh(player)
	end
end)

script.on_event(defines.events.on_gui_text_changed, function(event)
	if event.element.name ~= "fork_me_search" then return end
	local st = state()[event.player_index]
	if st then
		st.filter = event.element.text
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
