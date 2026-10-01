--------------------------------------------------------------------------------
--- FORK AE2: SHARED GUI OF THE ME WINDOWS (issue #68, step R3; docs/ME-REWORK.md, "GUIs (R3)")
---   * One window style: a screen frame with a title bar (caption, drag handle, close button) and a light
---     content frame, opened as the player's `opened` GUI (E and Escape close it like any window).
---   * Amounts are formatted with k/M/G everywhere (items and fluids): fmt().
---   * Routing: an element that acts carries the tag `fork_me_act` (an action name) and its data in its tags;
---     the modules register their actions with on(name, fn) at load time, and the terminal module sends every
---     GUI event of the mod to dispatch(). Windows are registered with window(name, def): def.open(player,
---     entity), def.refresh(player, frame) for the bounded refresh of open windows, def.entities (names whose
---     click opens it). open_entity() is called by the open key (simple entities have no vanilla GUI) and by
---     on_gui_opened (lamps, combinators, tanks, containers: the vanilla window is replaced at once).
--- Nothing here keeps state in storage: what a window shows lives in its elements' tags.
--------------------------------------------------------------------------------

local M = {}

local actions = {}          -- action name -> function(event, player, element)
local windows = {}          -- window name -> { refresh, open }
local openers = {}          -- entity name or ME kind (scripts/fork-me-network.lua kind_of) -> function(player, entity)
local REFRESH_MAX = 30      -- open windows refreshed per step (one per player at most: player.opened)

--------------------------------------------------------------------------------
--- formatting
--------------------------------------------------------------------------------

--- "999", "12.3", "1.2k", "12k", "123k", "1.2M", ..., "1.2G"
function M.fmt(n)
	n = tonumber(n) or 0
	local neg = n < 0
	if neg then n = -n end
	local out
	if n < 1000 then
		out = n == math.floor(n) and string.format("%d", n) or string.format("%.1f", n)
	else
		local units = { "k", "M", "G", "T" }
		local i = 0
		while n >= 1000 and i < #units do n = n / 1000 i = i + 1 end
		out = (n < 10 and string.format("%.1f", math.floor(n * 10) / 10) or string.format("%d", math.floor(n))) .. units[i]
	end
	return (neg and "-" or "") .. out
end

--------------------------------------------------------------------------------
--- building blocks
--------------------------------------------------------------------------------

--- breadth first search for a named element below `root`
function M.find(root, name)
	local queue, i = { root }, 1
	while queue[i] do
		for _, child in pairs(queue[i].children) do
			if child.name == name then return child end
			queue[#queue + 1] = child
		end
		i = i + 1
	end
end

--- tags for an acting element: { fork_me_act = act, ...data }
function M.act(act, data)
	local t = { fork_me_act = act }
	for k, v in pairs(data or {}) do t[k] = v end
	return t
end

--- A window: destroys the player's ME window, builds frame, title bar and content frame. Returns the frame and
--- the content flow. `tags` go onto the frame (fork_me_window = name is added).
function M.open_window(player, name, caption, tags)
	M.close_window(player)
	local t = { fork_me_window = name }
	for k, v in pairs(tags or {}) do t[k] = v end
	local frame = player.gui.screen.add{ type = "frame", name = "fork_me_window", direction = "vertical", tags = t }
	local bar = frame.add{ type = "flow", direction = "horizontal" }
	bar.drag_target = frame
	bar.style.horizontal_spacing = 8
	bar.add{ type = "label", caption = caption, style = "frame_title", ignored_by_interaction = true }
	local drag = bar.add{ type = "empty-widget", style = "draggable_space_header", ignored_by_interaction = true }
	drag.style.horizontally_stretchable = true
	drag.style.height = 24
	drag.style.right_margin = 4
	bar.add{ type = "sprite-button", style = "frame_action_button", sprite = "utility/close",
		tooltip = { "gui.close-instruction" }, tags = M.act("close") }
	local inner = frame.add{ type = "frame", style = "inside_shallow_frame_with_padding", direction = "vertical" }
	local content = inner.add{ type = "flow", name = "fork_me_content", direction = "vertical" }
	content.style.vertical_spacing = 6
	frame.auto_center = true
	player.opened = frame
	return frame, content
end

--- the player's open ME window (or nil), and its name
function M.window_of(player)
	local frame = player.gui.screen.fork_me_window
	if frame and frame.valid then return frame, frame.tags.fork_me_window end
	return nil
end

function M.close_window(player)
	local frame = player.gui.screen.fork_me_window
	if frame and frame.valid then frame.destroy() end
end

--- a label that wraps at `width` pixels
function M.label(parent, caption, width, style, name)
	local l = parent.add{ type = "label", name = name, caption = caption, style = style }
	if width then
		l.style.single_line = false
		l.style.maximal_width = width
	end
	return l
end

--- a heading line
function M.heading(parent, caption)
	return parent.add{ type = "label", caption = caption, style = "caption_label" }
end

--- a horizontal flow with centered children
function M.row(parent, name)
	local r = parent.add{ type = "flow", name = name, direction = "horizontal" }
	r.style.vertical_align = "center"
	r.style.horizontal_spacing = 6
	return r
end

--- A slot button for an item or fluid (`key`: item name, "name@quality" or "fluid/<name>"), with the amount
--- formatted in the tooltip and the button's number. `style` defaults to slot_button.
function M.slot(parent, key, amount, tags, style, extra_tooltip)
	local def = { type = "sprite-button", style = style or "slot_button", tags = tags }
	if key then
		if key:sub(1, 6) == "fluid/" then
			local name = key:sub(7)
			local proto = prototypes.fluid[name]
			if proto then def.sprite = "fluid/" .. name end
			def.tooltip = { "", proto and proto.localised_name or name, amount and (": " .. M.fmt(amount)) or "", extra_tooltip or "" }
		else
			local name, q = key:match("^([^@#]+)@?([^#]*)")
			q = (q and q ~= "") and q or "normal"
			if prototypes.item[name] and prototypes.quality[q] then
				def.sprite = "item/" .. name
				def.elem_tooltip = { type = "item-with-quality", name = name, quality = q }
				if extra_tooltip then def.tooltip = extra_tooltip end
			else
				def.tooltip = key                     -- the prototype is gone (a mod was removed)
			end
		end
	end
	if amount then def.number = math.floor(amount) end
	return parent.add(def)
end

--- a numeric text field (integers, optionally negative) that acts on change and on confirm
function M.number_field(parent, value, tags, width, negative, name)
	local f = parent.add{ type = "textfield", name = name, text = tostring(value or 0), numeric = true, allow_decimal = false,
		allow_negative = negative or false, lose_focus_on_confirm = true, tags = tags }
	f.style.width = width or 80
	return f
end

--- a slot table with `columns` columns
function M.grid(parent, columns, name)
	local scroll = parent.add{ type = "scroll-pane", horizontal_scroll_policy = "never" }
	scroll.style.maximal_height = 6 * 40 + 8
	local t = scroll.add{ type = "table", name = name, column_count = columns, style = "filter_slot_table" }
	return t, scroll
end

--------------------------------------------------------------------------------
--- registry and routing
--------------------------------------------------------------------------------

function M.on(act, fn) actions[act] = fn end

--- a window: { open = function(player, entity, opts), refresh = function(player, frame), entities = { entity names
--- or ME kinds } }; refresh returns false to close the window
function M.window(name, def)
	windows[name] = def
	for _, entity_name in pairs(def.entities or {}) do openers[entity_name] = def.open end
end

--- true when the entity opens an ME window (click or open key)
function M.has_window(entity)
	if not (entity and entity.valid) then return false end
	return (openers[entity.name] or (M.kind_of and openers[M.kind_of(entity.name) or ""])) ~= nil
end

--- open a registered window by name: def.open(player, entity, opts)
function M.open(name, player, entity, opts)
	local def = windows[name]
	if def then def.open(player, entity, opts) end
end

--- Show the vanilla window of an entity once (the ME Interface's "Open inventory"): the next on_gui_opened of
--- this player for it is let through. Kept in storage (multiplayer safe), cleared by the open key.
function M.open_vanilla(player, entity)
	storage.fork_me_gui_bypass = storage.fork_me_gui_bypass or {}
	storage.fork_me_gui_bypass[player.index] = entity.unit_number
	player.opened = entity
end

function M.clear_bypass(player)
	local b = storage.fork_me_gui_bypass
	if b then b[player.index] = nil end
end

--- The open key on an entity, or the vanilla window of an entity that has one: open the ME window instead.
--- Returns true when the entity has an ME window.
function M.open_entity(player, entity)
	if not (entity and entity.valid) then return false end
	local open = openers[entity.name] or (M.kind_of and openers[M.kind_of(entity.name) or ""])
	if not open then return false end
	local b = storage.fork_me_gui_bypass
	if b and b[player.index] == entity.unit_number then
		b[player.index] = nil
		return true                                   -- the vanilla window, asked for by the ME window
	end
	if not player.can_reach_entity(entity) then return true end
	local frame, name = M.window_of(player)
	if frame and frame.tags.unit == entity.unit_number and not frame.tags.via and windows[name] and open == windows[name].open then
		player.opened = frame                         -- already open (the open key and on_gui_opened both fire)
		return true
	end
	open(player, entity)
	return true
end

--- every GUI event of the mod (click, text, elem, checked, switch, selection, confirmed)
function M.dispatch(event)
	local el = event.element
	if not (el and el.valid) then return false end
	local act = el.tags and el.tags.fork_me_act
	if not act then return false end
	local player = game.get_player(event.player_index)
	if act == "close" then
		M.close_window(player)
		return true
	elseif act == "back" then                       -- back to the terminal a drive or cell window came from
		local via = el.tags.via and game.get_entity_by_unit_number(el.tags.via)
		if via and via.valid then M.open_entity(player, via) else M.close_window(player) end
		return true
	end
	local fn = actions[act]
	if not fn then return false end
	fn(event, player, el)
	return true
end

--- on_gui_closed: our window was closed (E, Escape, another GUI opened)
function M.on_closed(event)
	local el = event.element
	if el and el.valid and el.name == "fork_me_window" then
		el.destroy()
		return true
	end
	return false
end

--- every 60 ticks (terminal module): refresh the open windows (one per player), close those whose entity is
--- gone or out of reach
function M.refresh_all()
	local n = 0
	for _, player in pairs(game.connected_players) do
		local frame, name = M.window_of(player)
		if frame and n < REFRESH_MAX then
			n = n + 1
			local def = windows[name]
			if not def then
				frame.destroy()
			elseif player.opened ~= frame then
				frame.destroy()                            -- dying or another GUI closed it without an event
			else
				local ok = def.refresh and def.refresh(player, frame)
				if ok == false then frame.destroy() end
			end
		end
	end
end

--- refresh the player's window now (after a button changed something)
function M.refresh_one(player)
	local frame, name = M.window_of(player)
	local def = frame and windows[name]
	if def and def.refresh and def.refresh(player, frame) == false and frame.valid then frame.destroy() end
end

--- The window's entity (by the unit number in its tags), nil when gone or out of reach. A window opened from a
--- terminal (tag `via`: the terminal's unit number) needs the terminal in reach, not the entity.
function M.entity_of(player, frame)
	local e = frame.tags.unit and game.get_entity_by_unit_number(frame.tags.unit)
	if not (e and e.valid) then return nil end
	local via = frame.tags.via and game.get_entity_by_unit_number(frame.tags.via)
	if not player.can_reach_entity((via and via.valid) and via or e) then return nil end
	return e
end

--- a "Back" button to the terminal for a window opened from one
function M.back_button(parent, via)
	if not via then return nil end
	return parent.add{ type = "button", caption = { "fork-me-gui.back" }, tags = M.act("back", { via = via }) }
end

--- after a mod update every open ME window is closed (a window built by an older version may lack elements)
function M.close_all()
	for _, player in pairs(game.players) do M.close_window(player) end
end

return M
