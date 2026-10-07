--------------------------------------------------------------------------------
--- The picker of the mod's windows (issue #94): a popup that chooses an item (with its quality) or a fluid, the way the
--- game's own picker does: the item groups as tabs, the items and fluids of the group below them, a row with the
--- qualities at the bottom and the green check at its right end (it is also what the game's confirm key does: "E" by
--- default). Factorio's picker for a mod's button (`choose-elem-button`) has no quality row, takes a choice at once and
--- cannot leave the virtual signals out (issues #69, #82), so this one is the mod's own.
---
--- A window opens it with `Picker.open(player, spec)` and gets the choice back through the callback named in the spec
--- (`Picker.on_confirm(name, fn)`; `fn(player, data, choice)`, `choice` = { kind = "item" or "fluid", name, quality,
--- temperature }). Issue #159: a fluid can be chosen with a temperature (a field in the bottom row, whole degrees; empty:
--- none, which a filter reads as every temperature and a level maintainer or a pattern output as the default one).
--- Everything it knows lives in the frame's tags and the player's GUI: nothing is in `storage`, so another player or a
--- loaded save has nothing to agree on.
---
--- Closing: the frame is not the player's opened GUI (the window below it is). The game's close keys therefore close
--- that window; the hook `G.on_window_closed` turns that into "the picker closes" (Escape) or "the picker confirms"
--- (the confirm key's own event comes in the same tick, in either order).
--------------------------------------------------------------------------------

local G = require("scripts.fork-me-gui")
local N = require("scripts.fork-me-network")

local M = {}

M.NAME = "fork_me_picker"
local COLUMNS = 10
local MAX_SHOWN = 1500
local confirms = {}

--- `fn(player, data, choice)` is called when a picker opened with `spec.callback == name` is confirmed
function M.on_confirm(name, fn) confirms[name] = fn end

--- The key of a choice (issue #70): an item (`with_quality`: "name@quality", normal quality as the plain name; else the
--- plain name, for the places that take no quality) or a fluid ("fluid/<name>", with a temperature
--- "fluid/<name>@<degrees>": issue #159); nil for anything else (another kind, an unknown name or quality), so a window
--- can set what it gets or refuse it.
function M.key_of(choice, with_quality)
	if type(choice) ~= "table" or type(choice.name) ~= "string" then return nil end
	if choice.kind == "fluid" then
		return prototypes.fluid[choice.name] and N.fluid_filter_key(choice.name, tonumber(choice.temperature)) or nil
	end
	if choice.kind ~= "item" or not prototypes.item[choice.name] then return nil end
	if not with_quality then return choice.name end
	local q = choice.quality or "normal"
	if not prototypes.quality[q] or (q ~= "normal" and not script.feature_flags.quality) then return nil end
	return q == "normal" and choice.name or (choice.name .. "@" .. q)
end

--- The preset of a key for `Picker.open` (an item with its quality, or a fluid; nil for no key)
function M.preset_of(key)
	if not key then return nil end
	if key:sub(1, 6) == "fluid/" then
		local name, deg = N.split_fluid_key(key)
		return { kind = "fluid", name = name, temperature = deg }
	end
	local name, q = key:match("^([^@#]+)@?([^#]*)")
	return { kind = "item", name = name, quality = (q and q ~= "") and q or "normal" }
end

--- the quality names an item can be chosen with, lowest first (empty without the quality mod: an item then has its
--- normal quality only)
function M.qualities()
	local out = {}
	if not script.feature_flags.quality then return out end
	for _, q in pairs(prototypes.quality) do
		if not q.hidden and not q.parameter then out[#out + 1] = q end
	end
	table.sort(out, function(a, b) return a.level < b.level end)
	for i, q in ipairs(out) do out[i] = q.name end
	return out
end

--------------------------------------------------------------------------------
--- the catalog: what the picker lists, derived from the prototypes only (kept outside storage, made again after a load)
--------------------------------------------------------------------------------

local catalog

--- { { name, order, subs = { { name, order, list = { { kind, name, order } } } } } }: the groups, their subgroups and the
--- items and fluids of each, in the game's order (not hidden, not parameters)
local function catalog_of()
	if catalog then return catalog end
	local groups, by = {}, {}
	local function add(kind, proto)
		if proto.hidden or proto.parameter then return end
		local g, sg = proto.group, proto.subgroup
		if not (g and sg) then return end
		local gr = by[g.name]
		if not gr then
			gr = { name = g.name, order = g.order, subs = {}, by = {} }
			by[g.name] = gr
			groups[#groups + 1] = gr
		end
		local s = gr.by[sg.name]
		if not s then
			s = { name = sg.name, order = sg.order, list = {} }
			gr.by[sg.name] = s
			gr.subs[#gr.subs + 1] = s
		end
		s.list[#s.list + 1] = { kind = kind, name = proto.name, order = proto.order }
	end
	for _, p in pairs(prototypes.item) do add("item", p) end
	for _, p in pairs(prototypes.fluid) do add("fluid", p) end
	local function by_order(a, b)
		if a.order ~= b.order then return a.order < b.order end
		return a.name < b.name
	end
	table.sort(groups, by_order)
	for _, gr in ipairs(groups) do
		table.sort(gr.subs, by_order)
		for _, s in ipairs(gr.subs) do table.sort(s.list, by_order) end
	end
	catalog = groups
	return groups
end

--- the search text as the terminal's search takes it: lower case, spaces as dashes, matched against the prototype name
local function normal(text)
	return ((text or ""):lower():gsub("%s+", "-"))
end

--- the groups that have an entry of an allowed kind (`kinds` = { item = bool, fluid = bool })
local function groups_for(kinds)
	local out = {}
	for _, g in ipairs(catalog_of()) do
		local has = false
		for _, s in ipairs(g.subs) do
			for _, e in ipairs(s.list) do
				if kinds[e.kind] then has = true break end
			end
			if has then break end
		end
		if has then out[#out + 1] = g end
	end
	return out
end

--- the entries the picker lists: { { kind, name, group } } of the allowed kinds, in the game's order, whose name
--- contains the search text. `group` (a name): only that group's. For tests and the window.
function M.entries(kinds, filter, group)
	filter = normal(filter)
	local out = {}
	for _, g in ipairs(catalog_of()) do
		if group == nil or g.name == group then
			for _, s in ipairs(g.subs) do
				for _, e in ipairs(s.list) do
					if kinds[e.kind] and (filter == "" or e.name:find(filter, 1, true)) then
						out[#out + 1] = { kind = e.kind, name = e.name, group = g.name }
					end
				end
			end
		end
	end
	return out
end

--- the names of the groups that list something of the allowed kinds
function M.group_names(kinds)
	local out = {}
	for i, g in ipairs(groups_for(kinds)) do out[i] = g.name end
	return out
end

--- the group an item or fluid is listed in
local function group_of(kind, name)
	local proto = (kind == "fluid" and prototypes.fluid or prototypes.item)[name]
	return proto and proto.group and proto.group.name or nil
end

--------------------------------------------------------------------------------
--- the frame
--------------------------------------------------------------------------------

local function button_name(kind, name) return kind:sub(1, 1) .. "/" .. name end

--- the tags of the picker frame, changed in place (a LuaGuiElement's tags are a copy)
local function set_tags(frame, fields)
	local t = frame.tags
	for k, v in pairs(fields) do t[k] = v end
	frame.tags = t
	return t
end

local function picker_of(player)
	local frame = player.gui.screen[M.NAME]
	if frame and frame.valid then return frame end
	return nil
end

--- the list of the chosen group, or of every group for a search text
local function fill(frame)
	local t = frame.tags
	local body = G.find(frame, "fork_me_pk_body")
	if not body then return end
	body.clear()
	local filter = normal(t.filter)
	local shown, more = 0, false
	for _, g in ipairs(groups_for(t.kinds)) do
		if filter ~= "" or g.name == t.group then
			for _, s in ipairs(g.subs) do
				local tbl
				for _, e in ipairs(s.list) do
					if t.kinds[e.kind] and (filter == "" or e.name:find(filter, 1, true)) then
						if shown >= MAX_SHOWN then more = true break end
						shown = shown + 1
						tbl = tbl or body.add{ type = "table", column_count = COLUMNS, style = "filter_slot_table" }
						local b = tbl.add{ type = "sprite-button", name = button_name(e.kind, e.name), style = "slot_button",
							sprite = e.kind .. "/" .. e.name, tags = G.act("pk_item", { kind = e.kind, name = e.name }) }
						b.elem_tooltip = { type = e.kind, name = e.name }
						b.toggled = t.kind == e.kind and t.name == e.name
					end
				end
				if more then break end
			end
		end
		if more then break end
	end
	if shown == 0 then
		body.add{ type = "label", caption = { "fork-me-picker.no-match" } }
	elseif more then
		body.add{ type = "label", caption = { "fork-me-picker.more", MAX_SHOWN } }
	end
end

--- the group tabs, the quality row and the green check follow the tags
local function sync(frame)
	local t = frame.tags
	local tabs = G.find(frame, "fork_me_pk_groups")
	if tabs then
		tabs.visible = normal(t.filter) == ""
		for _, b in pairs(tabs.children) do b.toggled = b.tags.group == t.group end
	end
	local q = G.find(frame, "fork_me_pk_q")
	if q then
		for _, b in pairs(q.children) do
			b.toggled = b.tags.quality == t.quality
			b.enabled = t.kind ~= "fluid"
		end
	end
	local temp = G.find(frame, "fork_me_pk_temp_row")
	if temp then temp.visible = t.kind == "fluid" end
	local ok = G.find(frame, "fork_me_pk_ok")
	if ok then ok.enabled = t.name ~= nil end
end

--- Open the picker for `player`. `spec`: { callback = a name given to on_confirm, data = what the callback gets back (plain
--- data), kinds = { item = bool, fluid = bool } (what can be chosen), preset = { kind, name, quality } (what is chosen
--- at first, optional), quality = false (the place takes no quality: no quality row, the choice has none), title = a
--- LocalisedString }. Returns false when no kind is allowed.
function M.open(player, spec)
	M.close(player)
	local kinds = { item = spec.kinds.item and true or false, fluid = spec.kinds.fluid and true or false }
	if not (kinds.item or kinds.fluid) then return false end
	local t = { callback = spec.callback, data = spec.data or {}, kinds = kinds, filter = "", quality = "normal",
		plain = spec.quality == false }
	local preset = spec.preset
	if preset and kinds[preset.kind] and (preset.kind == "fluid" and prototypes.fluid or prototypes.item)[preset.name] then
		t.kind, t.name, t.group = preset.kind, preset.name, group_of(preset.kind, preset.name)
		if preset.kind == "item" and preset.quality and prototypes.quality[preset.quality] then t.quality = preset.quality end
		if preset.kind == "fluid" and tonumber(preset.temperature) then t.temperature = math.floor(tonumber(preset.temperature) + 0.5) end
	end
	local groups = groups_for(kinds)
	if not t.group then t.group = groups[1] and groups[1].name end

	local frame = player.gui.screen.add{ type = "frame", name = M.NAME, direction = "vertical", tags = t }
	local bar = frame.add{ type = "flow", direction = "horizontal" }
	bar.drag_target = frame
	bar.style.horizontal_spacing = 8
	bar.add{ type = "label", caption = spec.title or { "fork-me-picker.title" }, style = "frame_title", ignored_by_interaction = true }
	local drag = bar.add{ type = "empty-widget", style = "draggable_space_header", ignored_by_interaction = true }
	drag.style.horizontally_stretchable = true
	drag.style.height = 24
	drag.style.right_margin = 4
	bar.add{ type = "sprite-button", style = "frame_action_button", sprite = "utility/close",
		tooltip = { "gui.close-instruction" }, tags = G.act("pk_cancel") }
	local inner = frame.add{ type = "frame", style = "inside_shallow_frame_with_padding", direction = "vertical" }
	local content = inner.add{ type = "flow", direction = "vertical" }
	content.style.vertical_spacing = 6

	local top = G.row(content)
	top.add{ type = "label", caption = { "fork-me-picker.search" } }
	local search = top.add{ type = "textfield", name = "fork_me_pk_search", tags = G.act("pk_search") }
	search.style.width = 200
	local tabs = content.add{ type = "table", name = "fork_me_pk_groups", column_count = 6 }
	tabs.style.horizontal_spacing = 0
	tabs.style.vertical_spacing = 0
	for _, g in ipairs(groups) do
		local b = tabs.add{ type = "sprite-button", style = "filter_group_button_tab_slightly_larger", sprite = "item-group/" .. g.name,
			tooltip = prototypes.item_group[g.name] and prototypes.item_group[g.name].localised_name or g.name,
			tags = G.act("pk_group", { group = g.name }) }
		b.toggled = g.name == t.group
	end
	local body = content.add{ type = "scroll-pane", name = "fork_me_pk_body", direction = "vertical" }
	body.style.minimal_width = COLUMNS * 40 + 24
	body.style.maximal_height = 380
	body.style.minimal_height = 200
	body.style.horizontally_stretchable = true

	local bottom = G.row(content)
	local qualities = M.qualities()
	if #qualities > 1 and not t.plain then
		bottom.add{ type = "label", caption = { "fork-me-picker.quality" } }
		local q = bottom.add{ type = "flow", name = "fork_me_pk_q", direction = "horizontal" }
		q.style.horizontal_spacing = 2
		for _, name in ipairs(qualities) do
			q.add{ type = "sprite-button", style = "tool_button", sprite = "quality/" .. name,
				tooltip = prototypes.quality[name].localised_name, tags = G.act("pk_quality", { quality = name }) }
		end
	end
	if spec.temperature ~= false and kinds.fluid then             -- issue #159: a fluid's temperature (optional)
		local row = bottom.add{ type = "flow", name = "fork_me_pk_temp_row", direction = "horizontal" }
		row.style.vertical_align = "center"
		row.add{ type = "label", caption = { "fork-me-picker.temperature" }, tooltip = { "fork-me-picker.temperature-tooltip" } }
		local f = row.add{ type = "textfield", name = "fork_me_pk_temp", text = t.temperature and tostring(t.temperature) or "",
			numeric = true, allow_decimal = false, allow_negative = true, lose_focus_on_confirm = true,
			tooltip = { "fork-me-picker.temperature-tooltip" }, tags = G.act("pk_temp") }
		f.style.width = 70
	end
	local gap = bottom.add{ type = "empty-widget" }
	gap.style.horizontally_stretchable = true
	bottom.add{ type = "sprite-button", name = "fork_me_pk_ok", sprite = "utility/check_mark", style = "item_and_count_select_confirm",
		tooltip = { "fork-me-picker.confirm" }, tags = G.act("pk_ok") }

	frame.auto_center = true
	fill(frame)
	sync(frame)
	return true
end

function M.close(player)
	local frame = player.gui.screen[M.NAME]
	if frame and frame.valid then frame.destroy() end
end

--- The green check: what is chosen goes to the callback and the picker closes. Nothing chosen: it only closes.
function M.confirm(player)
	local frame = picker_of(player)
	if not frame then return false end
	local t = frame.tags
	local cb, choice = confirms[t.callback], nil
	if t.name then
		choice = { kind = t.kind, name = t.name, quality = t.kind == "item" and not t.plain and t.quality or nil,
			temperature = t.kind == "fluid" and t.temperature or nil }
	end
	local data = t.data
	frame.destroy()
	if cb and choice then cb(player, data, choice) end
	return true
end

--------------------------------------------------------------------------------
--- actions of its elements
--------------------------------------------------------------------------------

G.on("pk_group", function(event, player, el)
	if event.name ~= defines.events.on_gui_click then return end
	local frame = picker_of(player)
	if not frame then return end
	set_tags(frame, { group = el.tags.group })
	fill(frame)
	sync(frame)
end)

G.on("pk_item", function(event, player, el)
	if event.name ~= defines.events.on_gui_click then return end
	local frame = picker_of(player)
	if not frame then return end
	local t = frame.tags
	if t.name then
		local old = G.find(frame, button_name(t.kind, t.name))
		if old and old.valid then old.toggled = false end
	end
	el.toggled = true
	set_tags(frame, { kind = el.tags.kind, name = el.tags.name })
	sync(frame)
end)

G.on("pk_quality", function(event, player, el)
	if event.name ~= defines.events.on_gui_click then return end
	local frame = picker_of(player)
	if not frame then return end
	set_tags(frame, { quality = el.tags.quality })
	sync(frame)
end)

--- the search text (by name, as the terminal's search); Enter takes the chosen element in
G.on("pk_search", function(event, player, el)
	local frame = picker_of(player)
	if not frame then return end
	if event.name == defines.events.on_gui_confirmed then
		if frame.tags.name then M.confirm(player) end
		return
	end
	if event.name ~= defines.events.on_gui_text_changed then return end
	set_tags(frame, { filter = el.text })
	fill(frame)
	sync(frame)
end)

--- issue #159: the temperature field (empty: none); Enter takes the chosen fluid in
G.on("pk_temp", function(event, player, el)
	local frame = picker_of(player)
	if not frame then return end
	if event.name ~= defines.events.on_gui_text_changed and event.name ~= defines.events.on_gui_confirmed then return end
	local n = tonumber(el.text)
	local t = frame.tags
	t.temperature = n and math.floor(n + 0.5) or nil
	frame.tags = t
	if event.name == defines.events.on_gui_confirmed and t.name then M.confirm(player) end
end)

G.on("pk_ok", function(event, player)
	if event.name ~= defines.events.on_gui_click then return end
	M.confirm(player)
end)

G.on("pk_cancel", function(event, player)
	if event.name ~= defines.events.on_gui_click then return end
	M.close(player)
end)

--------------------------------------------------------------------------------
--- the close keys and the confirm key
---
--- The picker is a screen frame next to the ME window, which is the player's opened GUI, so Escape and "E" both close
--- that window. A window that is closed while a picker is open stays open instead (the game's rule: the popup goes
--- first): the picker is hidden and marked with the tick. Escape ends there (a hidden picker of an earlier tick is
--- removed with the next close or the next refresh); the confirm key (a custom input linked to the game's "confirm-gui",
--- fired in the same tick, before or after the close) takes the hidden or the shown picker's choice in.
--------------------------------------------------------------------------------

--- G.on_window_closed hook: the ME window was closed. True when it was for the picker (the window stays).
G.on_window_closed(function(player, window)
	local frame = picker_of(player)
	if frame then
		if frame.visible or frame.tags.cancel_tick == game.tick then
			G.focus(player, window)                      -- (the window, or its hand-over buffer: issue #168)
			if frame.visible then
				frame.visible = false
				set_tags(frame, { cancel_tick = game.tick })
			end
			return true
		end
		frame.destroy()                                  -- a picker hidden by an earlier close: this close is the window's
	end
	if window.tags.keep_tick == game.tick then          -- the confirm key just took a picker in: the window stays
		G.focus(player, window)
		return true
	end
	return false
end)

script.on_event("fork-me-picker-confirm", function(event)
	local player = game.get_player(event.player_index)
	local frame = player and picker_of(player)
	if not frame then return end
	if not (frame.visible or frame.tags.cancel_tick == game.tick) then return end
	local window = G.window_of(player)
	if window and window.valid then
		local wt = window.tags
		wt.keep_tick = game.tick
		window.tags = wt
		G.focus(player, window)
	end
	M.confirm(player)
end)

return M
