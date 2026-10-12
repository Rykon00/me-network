--------------------------------------------------------------------------------
--- ME NETWORK: ME INTERFACE TERMINAL (issue #336; AE2's Interface Terminal, in AE2-Unofficial
--- src/main/java/appeng/parts/reporting/PartInterfaceTerminal.java and client/gui/implementations/GuiInterfaceTerminal.java,
--- read for what it offers; nothing of its code is ported)
---   A 1x1 block, a member of the network like the ME Pattern Terminal (power through the controller, walkable, its screen lit
---   while the network works). It has no slots and no settings: its window lists every **ME Pattern Provider** and **ME
---   Interface** of its network, a page at a time:
---   * each provider with its name (given here: `autocraft.set_label`, kept by blueprints and clones) or "ME Pattern Provider",
---     its position, the machines and chests next to it and its pattern slots (a click works as in the provider's window:
---     take a pattern into the hand, shift: into the inventory, put the one in the hand in or swap it; the tooltip shows the
---     pattern); each interface with its config rows (shown only);
---   * a search over the products of the patterns, the config rows of the interfaces and the providers' names (by the prototype
---     name and the translated name, as the ME Terminal's search: scripts/fork-me-names.lua), a filter by the machine or chest
---     next to a provider (or the interfaces alone) and "only with free slots";
---   * per block: **Locate** (a highlight box around it for the player and a map marker in their chat), **Open** (the block's
---     own window, opened through this terminal: its reach counts and Back returns here, the `via` of scripts/fork-me-gui.lua),
---     and for a provider **Rename**;
---   * shift + click an encoded pattern in the inventory pane: into the first free slot of the first provider of the list as
---     it is filtered.
--- Cost: nothing runs for it unless a window is open; then the refresh of open windows (once a second, scripts/fork-me-gui.lua)
--- reads the records of the network's providers and interfaces (table reads, no engine call but `valid`; the interfaces'
--- config rows only while a search is typed), and builds GUI elements only for the visible page and only when what it shows
--- changed (a signature in the page's tags, as the windows of scripts/fork-me-windows.lua do; issue #50, lever 8).
--- State: storage.fork_me_iterm_ui[player_index] = { search, filter, free, page, edit } (the window's settings of a player,
--- kept while it is closed). Every function the window uses is called by the runtime test through the remote interface
--- `gregtorio-me-interface-terminal`.
--------------------------------------------------------------------------------

local N = require("scripts.fork-me-network")
local G = require("scripts.fork-me-gui")
local autocraft = require("scripts.fork-me-autocraft")
local io = require("scripts.fork-me-io")
local Names = require("scripts.fork-me-names")
local W = require("scripts.fork-me-windows")

local M = {}

local NAME = "me-interface-terminal"
local PROVIDER = "me-pattern-provider"
local PAGE = 6                  -- blocks per page
local COLUMNS = 12              -- slot buttons per row of a block
local WIDTH = 40 * COLUMNS + 40
local INTERFACES = "@interfaces"   -- the filter value of "ME Interfaces only"
local LOCATE_TICKS = 600        -- how long the highlight box of Locate stays

local function ui()
	storage.fork_me_iterm_ui = storage.fork_me_iterm_ui or {}
	return storage.fork_me_iterm_ui
end

--- the window settings of a player (made when first asked for)
local function ui_of(index)
	local list = ui()
	local u = list[index]
	if not u then
		u = { search = "", filter = "", free = false, page = 1 }
		list[index] = u
	end
	return u
end
M.ui_of = ui_of

--- the working network of a block, or nil and the reason ("no-network", "no-controller", "conflict", "no-power")
local function network(entity)
	local net = N.network_of(entity)
	if not net then return nil, "no-network" end
	local ok, why = N.usable(net)
	if not ok then return nil, why end
	return net
end
M.network = network

--------------------------------------------------------------------------------
--- the list
--------------------------------------------------------------------------------

--- the name of an item or fluid key for the search: (kind, name)
local function key_parts(key)
	if key:sub(1, 6) == "fluid/" then return "fluid", N.fluid_name(key) end
	return "item", (N.parse_key(key))
end

--- does a key match the search (`dashed`, `lower`: Names.search, `names`: the player's translated names)?
local function key_matches(key, dashed, lower, names)
	if key:find(dashed, 1, true) then return true end
	local kind, name = key_parts(key)
	return name ~= nil and Names.matches(names, kind, name, dashed, lower)
end

--- The blocks of the window for network `net` and the settings `opts` = { search, filter, free } (a player's ui) and the
--- player's translated names `names` (nil: the prototype names only). Returns { entries = { { kind = "provider" | "interface",
--- unit, entity, label, near, size, filled, record } } in the order shown, machines = the entity names next to the network's
--- providers (sorted: the filter's choices), providers, interfaces = how many of each are in the network }.
function M.list(net, opts, names)
	opts = opts or {}
	local dashed, lower = Names.search(opts.search)
	local searching = dashed ~= ""
	local filter, free = opts.filter or "", opts.free == true
	local entries, seen, machines = {}, {}, {}
	local nprov, nif = 0, 0
	local function match_key(key) return key_matches(key, dashed, lower, names) end
	for _, p in ipairs(autocraft.provider_records(net)) do
		nprov = nprov + 1
		local near = p.near or {}
		for _, name in ipairs(near) do
			if not seen[name] then seen[name] = true machines[#machines + 1] = name end
		end
		local ok = filter == ""
		if not ok and filter ~= INTERFACES then
			for _, name in ipairs(near) do if name == filter then ok = true break end end
		end
		local size, filled = autocraft.record_size(p)
		if ok and free and filled >= size then ok = false end
		if ok and searching then
			ok = (p.label ~= nil and p.label:lower():find(lower, 1, true) ~= nil) or autocraft.any_output(p, match_key)
		end
		if ok then
			entries[#entries + 1] = { kind = "provider", unit = p.unit, entity = p.entity, label = p.label, near = near,
				size = size, filled = filled, record = p }
		end
	end
	local nodes = storage.fork_me_net and storage.fork_me_net.nodes or {}
	local ifs = {}
	for unit in pairs(net.nodes) do
		local node = nodes[unit]
		if node and node.kind == "interface" and node.entity.valid then ifs[#ifs + 1] = unit end
	end
	table.sort(ifs)                                        -- (net.nodes is a set: the order of the units, the same everywhere)
	for _, unit in ipairs(ifs) do
		nif = nif + 1
		local entity = nodes[unit].entity
		local ok = (filter == "" or filter == INTERFACES) and not free
		if ok and searching then
			ok = false
			for _, c in pairs(io.get_interface_config(entity) or {}) do
				if match_key(io.row_key(c)) then ok = true break end
			end
		end
		if ok then entries[#entries + 1] = { kind = "interface", unit = unit, entity = entity } end
	end
	--- providers first, grouped by the first machine next to them (as AE2's sections by machine), named ones first by name,
	--- then in the order they were built; then the interfaces
	local order = {}
	for i, e in ipairs(entries) do order[e] = i end
	table.sort(entries, function(a, b)
		if a.kind ~= b.kind then return a.kind == "provider" end
		if a.kind == "provider" then
			local ma, mb = a.near[1] or "", b.near[1] or ""
			if ma ~= mb then return ma < mb end
			if (a.label ~= nil) ~= (b.label ~= nil) then return a.label ~= nil end
			if a.label and a.label ~= b.label then return a.label < b.label end
		end
		return order[a] < order[b]
	end)
	table.sort(machines)
	return { entries = entries, machines = machines, providers = nprov, interfaces = nif }
end

--- the page `page` of a list: the first and last index of its entries, the page (kept in 1 .. pages) and the number of pages
function M.page_of(list, page)
	local n = #list.entries
	local pages = math.max(1, math.ceil(n / PAGE))
	page = math.max(1, math.min(pages, math.floor(tonumber(page) or 1)))
	local first = (page - 1) * PAGE + 1
	return first, math.min(n, first + PAGE - 1), page, pages
end

--- the data of one entry as its part of the window shows it: { kind, unit, title (a LocalisedString), label, position,
--- near, slots = { [slot] = record_slot or false } (a provider: size slots) or rows = { { key, amount } } (an interface) }
function M.entry_view(e)
	local pos = e.entity.position
	local v = { kind = e.kind, unit = e.unit, label = e.label, near = e.near or {},
		position = { x = math.floor(pos.x), y = math.floor(pos.y) } }
	if e.kind == "provider" then
		v.title = e.label or { "entity-name." .. PROVIDER }
		v.slots = {}
		for slot = 1, e.size do v.slots[slot] = autocraft.record_slot(e.record, slot) or false end
	else
		v.title = e.entity.localised_name
		v.rows = {}
		local config = io.get_interface_config(e.entity) or {}
		local idx = {}
		for i in pairs(config) do idx[#idx + 1] = i end
		table.sort(idx)
		for _, i in ipairs(idx) do v.rows[#v.rows + 1] = { key = io.row_key(config[i]), amount = config[i].amount } end
	end
	return v
end

--- the signature of what an entry's part shows (rebuilt only when it changed)
local function entry_sig(v, editing)
	local sig = { v.kind, v.unit, tostring(v.label), v.position.x, v.position.y, table.concat(v.near, "+"), tostring(editing) }
	if v.slots then
		for slot, d in ipairs(v.slots) do
			sig[#sig + 1] = d and (tostring(d.id or d.recipe) .. ":" .. tostring(d.ok) .. ":" .. tostring(d.reason) .. ":"
				.. tostring(d.pending)) or ("-" .. slot)
		end
	else
		for _, r in ipairs(v.rows) do sig[#sig + 1] = r.key .. "=" .. tostring(r.amount) end
	end
	return table.concat(sig, ",")
end

--- the provider of `unit` when it is still a member of the terminal's network, else nil and the reason
local function provider_in(terminal, unit)
	local e = G.entity_by_unit(unit)
	if not (e and e.valid and e.name == PROVIDER) then return nil, "no-provider" end
	if N.network_of(e) ~= N.network_of(terminal) then return nil, "not-in-network" end
	return e
end

--- any member of the terminal's network by unit (a provider or an interface), or nil
local function member_in(terminal, unit)
	local e = G.entity_by_unit(unit)
	if not (e and e.valid) then return nil end
	if N.network_of(e) ~= N.network_of(terminal) then return nil end
	return e
end

--- Shift + click of an encoded pattern in the inventory pane: into the first free slot of the first provider of the list (as
--- `opts` filters it). Returns the reason when it went nowhere.
function M.shift_in(entity, stack, opts, names)
	local net = network(entity)
	if not net then return "no-network" end
	if not (stack and stack.valid_for_read and stack.name == "me-encoded-pattern") then return "not-a-pattern" end
	for _, e in ipairs(M.list(net, opts, names).entries) do
		if e.kind == "provider" and e.filled < e.size then
			local _, why = autocraft.insert_pattern(e.entity, stack)
			if not why then return nil end
		end
	end
	return "no-free-slot"
end

--- Locate: a highlight box around the block for `player` and its map marker in their chat
function M.locate(player, e)
	e.surface.create_entity{ name = "highlight-box", position = e.position, source = e, box_type = "copy",
		render_player_index = player.index, blink_interval = 20, time_to_live = LOCATE_TICKS }
	player.print({ "fork-me-iface-terminal.located", e.localised_name,
		string.format("[gps=%d,%d,%s]", math.floor(e.position.x), math.floor(e.position.y), e.surface.name) })
end

--------------------------------------------------------------------------------
--- the window
--------------------------------------------------------------------------------

local function flying(player, why)
	if why then player.create_local_flying_text{ text = M.message(why), create_at_cursor = true } end
end

function M.message(why)
	if why == "no-free-slot" or why == "not-in-network" then return { "fork-me-iface-terminal." .. why } end
	return G.net_message(why)
end

local function tool_button(parent, sprite, tooltip, tags)
	local b = parent.add{ type = "sprite-button", sprite = sprite, style = "tool_button", tooltip = tooltip, tags = tags }
	b.style.size = 24
	b.style.padding = 0
	return b
end

--- one entry's part of the page (into `box`, a vertical flow)
function M.build_entry(box, v, editing)
	local head = G.row(box)
	head.add{ type = "sprite", sprite = "entity/" .. (v.kind == "provider" and PROVIDER or "me-network-interface") }
	if editing then
		local f = head.add{ type = "textfield", name = "fork_me_it_label", text = v.label or "",
			tags = G.act("it_label", { unit = v.unit }), lose_focus_on_confirm = true }
		f.style.width = 200
	else
		local l = head.add{ type = "label", caption = v.title, style = "caption_label" }
		l.style.maximal_width = 220
	end
	head.add{ type = "label", caption = { "fork-me-iface-terminal.position", v.position.x, v.position.y } }
	for _, name in ipairs(v.near) do
		if prototypes.entity[name] then
			head.add{ type = "sprite", sprite = "entity/" .. name, tooltip = prototypes.entity[name].localised_name }
		end
	end
	if v.kind == "provider" and #v.near == 0 then head.add{ type = "label", caption = { "fork-me-iface-terminal.no-machine" } } end
	head.add{ type = "empty-widget" }.style.horizontally_stretchable = true
	if v.kind == "provider" then
		tool_button(head, "utility/rename_icon", { "fork-me-iface-terminal.rename-tooltip" }, G.act("it_rename", { unit = v.unit }))
	end
	tool_button(head, "utility/center", { "fork-me-iface-terminal.locate-tooltip" }, G.act("it_locate", { unit = v.unit }))
	tool_button(head, "utility/go_to_arrow", { "fork-me-iface-terminal.open-tooltip" }, G.act("it_open", { unit = v.unit }))
	if v.rows and #v.rows == 0 then
		box.add{ type = "label", caption = { "fork-me-iface-terminal.no-config" } }
		return
	end
	local t = box.add{ type = "table", column_count = COLUMNS, style = "filter_slot_table" }
	if v.slots then
		for slot, d in ipairs(v.slots) do
			local tags = G.act("it_slot", { unit = v.unit, slot = slot })
			if d then
				t.add{ type = "sprite-button", sprite = W.pattern_sprite(d), tooltip = W.slot_tooltip(d), tags = tags,
					style = d.pending and "yellow_slot_button" or d.ok and "slot_button" or "red_slot_button" }
			else
				t.add{ type = "sprite-button", style = "slot_button", tooltip = { "fork-me-gui.provider-empty-tooltip" }, tags = tags }
			end
		end
	else
		for _, r in ipairs(v.rows) do G.slot(t, r.key, r.amount) end
	end
end

--- the page of a list into `box` (cleared first): the parts of entries `first` .. `last`
function M.build_page(box, list, first, last, editing)
	box.clear()
	if #list.entries == 0 then
		G.label(box, { "fork-me-iface-terminal.none" }, WIDTH)
		return
	end
	for i = first, last do
		if i > first then box.add{ type = "line" } end
		local v = M.entry_view(list.entries[i])
		M.build_entry(box, v, editing == v.unit)
	end
end

--- the filter's choices: the values and the drop-down's items, and the selected index
local function filter_choices(machines, filter)
	local values = { "", INTERFACES }
	local items = { { "fork-me-iface-terminal.filter-all" }, { "fork-me-iface-terminal.filter-interfaces" } }
	local selected = filter == INTERFACES and 2 or 1
	for _, name in ipairs(machines) do
		local proto = prototypes.entity[name]
		if proto then
			values[#values + 1] = name
			items[#items + 1] = { "", "[entity=" .. name .. "] ", proto.localised_name }
			if filter == name then selected = #values end
		end
	end
	return values, items, selected
end

local function open(player, entity)
	if not (entity and entity.valid and entity.name == NAME) then return end
	local u = ui_of(player.index)
	u.edit = nil
	Names.ensure(player)                                   -- (issue #295: the names for the search)
	local _, content = G.open_window(player, "interface-terminal", { "fork-me-iface-terminal.title" }, { unit = entity.unit_number })
	G.label(content, "", WIDTH, nil, "fork_me_it_net")
	G.label(content, { "fork-me-iface-terminal.help" }, WIDTH)
	local row = G.row(content)
	row.add{ type = "label", caption = { "fork-me-iface-terminal.search" }, tooltip = { "fork-me-iface-terminal.search-tooltip" } }
	local search = row.add{ type = "textfield", name = "fork_me_it_search", text = u.search or "", tags = G.act("it_search"),
		tooltip = { "fork-me-iface-terminal.search-tooltip" } }
	search.style.width = 160
	row.add{ type = "drop-down", name = "fork_me_it_filter", tags = G.act("it_filter", { values = { "" } }),
		tooltip = { "fork-me-iface-terminal.filter-tooltip" } }
	row.add{ type = "checkbox", state = u.free == true, caption = { "fork-me-iface-terminal.free" },
		tooltip = { "fork-me-iface-terminal.free-tooltip" }, tags = G.act("it_free") }
	local nav = G.row(content)
	nav.add{ type = "sprite-button", sprite = "utility/backward_arrow", style = "frame_action_button",
		tooltip = { "fork-me-iface-terminal.previous" }, tags = G.act("it_page", { step = -1 }) }
	nav.add{ type = "label", name = "fork_me_it_count", caption = "" }
	nav.add{ type = "sprite-button", sprite = "utility/forward_arrow", style = "frame_action_button",
		tooltip = { "fork-me-iface-terminal.next" }, tags = G.act("it_page", { step = 1 }) }
	local scroll = content.add{ type = "scroll-pane", horizontal_scroll_policy = "never" }
	scroll.style.maximal_height = 540
	scroll.style.minimal_width = WIDTH
	scroll.add{ type = "flow", name = "fork_me_it_page", direction = "vertical" }
	M.refresh(player)
end
M.open = open

function M.refresh(player, frame)
	frame = frame or G.window_of(player)
	if not frame then return false end
	local entity = G.entity_of(player, frame)
	if not (entity and entity.valid and entity.name == NAME) then return false end
	local net_line, box = G.find(frame, "fork_me_it_net"), G.find(frame, "fork_me_it_page")
	if not (net_line and box) then return false end                            -- built by another version
	local u = ui_of(player.index)
	local net, why = network(entity)
	net_line.caption = net and { "fork-me-net.status-ok" } or { "fork-me-net.status-" .. why }
	local list = net and M.list(net, u, u.search ~= "" and Names.names_of(player.index) or nil)
		or { entries = {}, machines = {}, providers = 0, interfaces = 0 }
	local first, last, page, pages = M.page_of(list, u.page)
	u.page = page
	local dd = G.find(frame, "fork_me_it_filter")
	if dd then
		local values, items, selected = filter_choices(list.machines, u.filter)
		local sig = table.concat(values, ",")
		if dd.tags.sig ~= sig then
			dd.items = items
			dd.tags = G.act("it_filter", { values = values, sig = sig })
		end
		if dd.selected_index ~= selected then dd.selected_index = selected end
	end
	local shown_p, shown_i = 0, 0
	for _, e in ipairs(list.entries) do
		if e.kind == "provider" then shown_p = shown_p + 1 else shown_i = shown_i + 1 end
	end
	G.find(frame, "fork_me_it_count").caption = { "fork-me-iface-terminal.count", shown_p, list.providers, shown_i, list.interfaces,
		page, pages }
	local sig = { tostring(first), tostring(last), tostring(#list.entries) }
	for i = first, last do sig[#sig + 1] = entry_sig(M.entry_view(list.entries[i]), u.edit) end
	sig = table.concat(sig, "|")
	if box.tags.sig ~= sig then
		M.build_page(box, list, first, last, u.edit)
		box.tags = { sig = sig }
	end
	return true
end

--- shift + click of a stack in the inventory pane (its owner's filter and search decide the provider)
local function pane_shift(entity, stack, inventory)
	local player = inventory and inventory.valid and inventory.player_owner or nil
	local u = player and ui_of(player.index) or nil
	return M.shift_in(entity, stack, u, u and u.search ~= "" and Names.names_of(player.index) or nil)
end

G.window("interface-terminal", { open = open, refresh = function(player, frame) return M.refresh(player, frame) end,
	entities = { NAME }, hint = { "fork-me-iface-terminal.store-help" }, shift = pane_shift, message = M.message })

--------------------------------------------------------------------------------
--- actions (the elements' tags carry them: scripts/fork-me-gui.lua dispatch)
--------------------------------------------------------------------------------

local function window_entity(player)
	local frame = G.window_of(player)
	local e = frame and G.entity_of(player, frame)
	if e and e.name == NAME then return e end
	return nil
end

--- issue #295: a player's names arrived: an open window searches by them
Names.on_done[#Names.on_done + 1] = function(player)
	if window_entity(player) then M.refresh(player) end
end

G.on("it_search", function(event, player, el)
	if event.name ~= defines.events.on_gui_text_changed then return end
	local u = ui_of(player.index)
	u.search, u.page = el.text, 1
	M.refresh(player)
end)

G.on("it_filter", function(event, player, el)
	if event.name ~= defines.events.on_gui_selection_state_changed then return end
	local u = ui_of(player.index)
	local values = el.tags.values or {}
	u.filter, u.page = values[el.selected_index] or "", 1
	M.refresh(player)
end)

G.on("it_free", function(event, player, el)
	if event.name ~= defines.events.on_gui_checked_state_changed then return end
	local u = ui_of(player.index)
	u.free, u.page = el.state, 1
	M.refresh(player)
end)

G.on("it_page", function(event, player, el)
	if event.name ~= defines.events.on_gui_click then return end
	local u = ui_of(player.index)
	u.page = (u.page or 1) + (el.tags.step or 0)
	M.refresh(player)
end)

G.on("it_slot", function(event, player, el)
	if event.name ~= defines.events.on_gui_click then return end
	local terminal = window_entity(player)
	if not terminal then return end
	local provider, why = provider_in(terminal, el.tags.unit)
	if not provider then flying(player, why) M.refresh(player) return end
	local cursor, inv, remote = G.hand(player)
	local out
	why, out = autocraft.provider_click(cursor, inv, provider, el.tags.slot, event.shift or remote)
	flying(player, why)
	if remote and out then G.moved_text(player) end
	G.update_pane(player)
	M.refresh(player)
end)

G.on("it_rename", function(event, player, el)
	if event.name ~= defines.events.on_gui_click then return end
	local terminal = window_entity(player)
	if not terminal then return end
	local u = ui_of(player.index)
	if u.edit == el.tags.unit then                      -- the second click saves what the field holds
		local provider = provider_in(terminal, el.tags.unit)
		local field = G.find(G.window_of(player), "fork_me_it_label")
		if provider and field then autocraft.set_label(provider, field.text) end
		u.edit = nil
	else
		u.edit = el.tags.unit
	end
	M.refresh(player)
end)

G.on("it_label", function(event, player, el)
	if event.name ~= defines.events.on_gui_confirmed then return end
	local terminal = window_entity(player)
	if not terminal then return end
	local provider, why = provider_in(terminal, el.tags.unit)
	if provider then autocraft.set_label(provider, el.text) else flying(player, why) end
	ui_of(player.index).edit = nil
	M.refresh(player)
end)

G.on("it_locate", function(event, player, el)
	if event.name ~= defines.events.on_gui_click then return end
	local terminal = window_entity(player)
	local e = terminal and member_in(terminal, el.tags.unit)
	if e then M.locate(player, e) else flying(player, "not-in-network") end
end)

G.on("it_open", function(event, player, el)
	if event.name ~= defines.events.on_gui_click then return end
	local terminal = window_entity(player)
	local e = terminal and member_in(terminal, el.tags.unit)
	if not e then flying(player, "not-in-network") M.refresh(player) return end
	G.open(e.name == PROVIDER and "provider" or "interface", player, e, { via = terminal.unit_number })
end)

--------------------------------------------------------------------------------
--- the remote interface (the runtime test; every function is what the window does)
--------------------------------------------------------------------------------

--- a list as plain data: { entries = { { kind, unit, label, near, size, filled } }, machines, providers, interfaces }
local function plain(list)
	local out = { machines = list.machines, providers = list.providers, interfaces = list.interfaces, entries = {} }
	for i, e in ipairs(list.entries) do
		out.entries[i] = { kind = e.kind, unit = e.unit, label = e.label, near = e.near, size = e.size, filled = e.filled }
	end
	return out
end

remote.add_interface("gregtorio-me-interface-terminal", {
	--- the list of the terminal's network for `opts` = { search, filter ("" all, "@interfaces", an entity name), free } and
	--- translated names `names` (as Names.names_of gives them)
	list = function(entity, opts, names)
		local net = network(entity)
		return net and plain(M.list(net, opts, names)) or nil
	end,
	page_of = function(entity, opts, page)
		local net = network(entity)
		if not net then return nil end
		return M.page_of(M.list(net, opts), page)
	end,
	--- the data of entry `index` of the list, as its part of the window shows it
	entry_view = function(entity, opts, index)
		local net = network(entity)
		local e = net and M.list(net, opts).entries[index]
		if not e then return nil end
		local v = M.entry_view(e)
		v.entity = nil
		return v
	end,
	--- page `page` of the list built into a stand-in of the window's page box (the harness has no player): per entry the
	--- caption (or the label field's text), the sprites of its slot buttons and their styles
	build_page = function(entity, opts, page, editing)
		local net = network(entity)
		if not net then return nil end
		local list = M.list(net, opts)
		local first, last = M.page_of(list, page)
		local box = W.stand_in_element{ type = "flow" }
		M.build_page(box, list, first, last, editing)
		local out = {}
		for _, c in ipairs(box.children) do
			if c.type == "flow" then
				local name = c.children[2]                  -- (the head row: the block's sprite, then its name or the name field)
				out[#out + 1] = { caption = name and (name.caption or name.type) }
			elseif c.type == "table" then
				local e = out[#out] or {}
				e.slots = {}
				for _, b in ipairs(c.children) do e.slots[#e.slots + 1] = { sprite = b.sprite, style = b.style_name, number = b.number } end
			elseif c.type == "label" and #out > 0 then
				out[#out].note = c.caption                   -- (an interface without config rows)
			elseif c.type == "label" then
				out[#out + 1] = { label = c.caption }        -- (nothing matches)
			end
		end
		return out
	end,
	shift_in = function(entity, stack, opts) return M.shift_in(entity, stack, opts) end,
	--- a click on slot `slot` of provider `unit` in the window: what the provider window's click does (`cursor`, `inventory`)
	click = function(entity, unit, slot, cursor, inventory, shift)
		local provider, why = provider_in(entity, unit)
		if not provider then return why end
		return autocraft.provider_click(cursor, inventory, provider, slot, shift)
	end,
	rename = function(entity, unit, text)
		local provider, why = provider_in(entity, unit)
		if not provider then return false, why end
		return autocraft.set_label(provider, text)
	end,
	problem = function(entity) local _, why = network(entity) return why end,
	ui_of = function(index) return ui_of(index) end,
})

return M
