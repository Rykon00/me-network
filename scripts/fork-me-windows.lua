--------------------------------------------------------------------------------
--- FORK AE2: THE WINDOWS OF THE ME BLOCKS (issue #68, step R3; docs/AE2.md, docs/ME-REWORK.md "GUIs (R3)")
--- One window per block, in the style of scripts/fork-me-gui.lua, opened by a click on the block (the vanilla
--- window of lamps, combinators, tanks and containers is replaced; blocks without one open on the open key):
---   * ME Drive: the ten cell slots with fill bars, the drive's priority; click a slot to put a cell in or take
---     it out, right click a cell for its cell window.
---   * Storage cell (from the drive window or the terminal's cells tab): contents, bytes and types, the
---     partition (the items or fluids the cell is restricted to; a blacklist with an Inverter Card), "Clear" and "From
---     contents", the cell's upgrade cards (shown only: they go in and out in the ME Cell Workbench, issue #17).
---   * ME Cell Workbench (issue #17): the cell slot and its card slots, the cell's partition, "From contents", "Clear"
---     and the copy mode; issue #28: the player's inventory beside it (shift + click: a cell into the cell slot, a card
---     into a card slot).
---   * ME Controller: network state, members, drives, cells, bytes and types, power.
---   * ME Pattern Provider (issue #80): the 9 pattern slots (click with an encoded pattern in hand to put it in,
---     click a pattern to take it out), the status of each pattern (usable by how many machines, or why not), the
---     machines and chests next to it, the priority.
---   * ME Crafting CPU (issue #6: a multiblock of crafting blocks): its blocks, bytes, co-processors, its job.
---   * ME Level Maintainer: item or fluid, amount, amount from the circuit, the on/off circuit condition, status.
---   * ME Circuit Interface: 20 filters, output on/off, status.
---   * ME Interface: 9 config rows (an item or a fluid and its amount), the four fluid sides (import, off or a fluid
---     row; what each side's tank holds), the container's content, "Open inventory"; its priority (issue #17).
---   * ME Import/Export Bus: 9 filters (items and fluids), status, the entity it faces and what of it the bus uses.
---   * ME Storage Bus: mode (read and write, read only, write only), priority, 18 filters (items and fluids; 9 more per
---     Capacity Card), what it shows (items, or the fluid, amount and temperature of a tank's segment), status, the
---     entity it faces; issue #17: its 5 card slots (issue #28: the player's inventory beside them, shift + click puts a
---     card in), the cards it waits for, "filter on extract", "From contents" and "Clear", and a red warning with an Overflow Destruction Card.
--- (issue #3: the windows of the ME Fluid Interface and the ME Fluid Storage Bus are gone with those blocks)
--- Every window shows plain data from a `*_data` function and changes things through functions of the
--- block's module (or the small `set_*` helpers here); the runtime test calls the same functions
--- (remote interface "gregtorio-me-gui"). Nothing is kept in storage: what a window shows lives in its tags.
--------------------------------------------------------------------------------

local N = require("scripts.fork-me-network")
local G = require("scripts.fork-me-gui")
local autocraft = require("scripts.fork-me-autocraft")
local patterns = require("scripts.fork-me-patterns")
local circuit = require("scripts.fork-me-circuit")
local io = require("scripts.fork-me-io")
local sbus = require("scripts.fork-me-storagebus")
local bench = require("scripts.fork-me-workbench")
local picker = require("scripts.fork-me-picker")
local terminal = require("scripts.fork-me-terminal")

local M = {}

G.kind_of = N.kind_of

local WIDTH = 400

--- the entity of the player's open window, and the frame
local function window_entity(player)
	local frame = G.window_of(player)
	if not frame then return nil end
	return G.entity_of(player, frame), frame
end

--- rebuild the child `name` of `frame` when `sig` changed since the last build
local function rebuild(frame, name, sig, build)
	local box = G.find(frame, name)
	if not box then return end
	if box.tags.sig == sig then return end
	box.clear()
	box.tags = { sig = sig }
	build(box)
end

--- Issue #28: the slots `first` .. `last` of a block's inventory `inv` as slot buttons (block_slot: the window's
--- click), rebuilt when a stack changed; `tip(slot, stack)` gives a button's tooltip
local function block_slots(frame, name, inv, first, last, tip)
	local sig = { tostring(first), tostring(last) }
	for i = first, last do
		local st = inv[i]
		sig[#sig + 1] = st.valid_for_read and (st.name .. "#" .. st.count .. "@" .. st.quality.name .. G.stack_ident(st)) or "-"
	end
	rebuild(frame, name, table.concat(sig, ","), function(box)
		for i = first, last do G.stack_button(box, inv[i], G.act("block_slot", { slot = i }), tip and tip(i, inv[i]) or nil) end
	end)
end

local function caption_of(entity)
	return entity.localised_name
end

--- Issue #28, shift + click in the window of a block without slots of its own: the stack is stored in the block's
--- network (as the terminal stores it; the block needs a working network). Returns the reason when nothing was stored.
function M.store_shift(entity, stack)
	local net = N.network_of(entity)
	if not net then return "no-network" end
	local n, why = N.insert_stack(net, stack)
	if not n then return why end
	return nil
end

--- control + click there: every stack of that item and quality in the inventory is stored
function M.store_all(entity, stack, inv)
	local net = N.network_of(entity)
	if not net then return "no-network" end
	local name, q = stack.name, stack.quality.name
	local stored, why = 0, nil
	for i = 1, #inv do
		local s = inv[i]
		if s.valid_for_read and s.name == name and s.quality.name == q then
			local n, w = N.insert_stack(net, s)
			if n then stored = stored + n
			else
				why = why or w
				if not N.refuses_stack(w) then break end                -- (a used stack stays, the next one may go in)
			end
		end
	end
	if stored == 0 then return why or "no-storage" end
	return nil
end

--- the window definition's fields of a block whose shift + click stores into the network
local function storing(def)
	def.shift, def.control, def.message, def.hint = M.store_shift, M.store_all, G.net_message, { "fork-me-gui.store-help" }
	return def
end

--- a cell shift-clicked into a drive (the drive window, and a cell window of that drive): into its first free slot
local function cell_into_drive(drive, stack)
	local _, why = N.insert_cell(drive, stack)
	return why
end

local function flying(player, why)
	if why then player.create_local_flying_text{ text = { "fork-me-net.error-" .. why }, create_at_cursor = true } end
end

--- an item or fluid key from a choose-elem value (item-with-quality, fluid name or SignalID)
local function key_of_elem(elem_type, value)
	if value == nil then return nil end
	if elem_type == "fluid" then return prototypes.fluid[value] and ("fluid/" .. value) or nil end
	if elem_type == "item-with-quality" then
		return prototypes.item[value.name] and N.key_of(value.name, value.quality or "normal") or nil
	end
	return prototypes.item[value] and value or nil
end
M.key_of_elem = key_of_elem

--- Issue #70: the picker (scripts/fork-me-picker.lua) for a key slot button: `act` names the callback of the choice,
--- `data` (plain data: the block's unit number, the slot's index) comes back with it, `key` is what the slot holds (the
--- picker opens on it), `with_quality` false for a place that takes no quality (buses, the maintainer's target, the
--- circuit interface's filters, the pattern editor's rows)
local function key_picker(player, act, data, key, with_quality)
	picker.open(player, { callback = act, data = data, kinds = { item = true, fluid = true }, preset = picker.preset_of(key),
		quality = with_quality and true or false })
end

local function right_click(event) return event.button == defines.mouse_button_type.right end

--- a choice the picker made that the slot cannot take (another kind, an unknown name): the picker is closed already
local function refused_choice(player)
	player.create_local_flying_text{ text = { "fork-me-gui.choice-refused" }, create_at_cursor = true }
end

--------------------------------------------------------------------------------
--- ME Drive
--------------------------------------------------------------------------------

function M.drive_data(drive)
	if not (drive and drive.valid and N.kind_of(drive.name) == "drive") then return nil end
	local net = N.network_of(drive)
	return { priority = N.get_priority(drive), cells = N.drive_info(drive), slots = 10, online = net and N.usable(net) or false }
end

local function cell_line(c)
	return { "fork-me-net.drive-slot-short", G.fmt(c.bytes), G.fmt(c.bytes_total), c.types, c.types_total }
end

--- issue #147: the tooltip of a cell slot, what the cell's own tooltip says and what it holds, then the click hints
function M.drive_cell_tooltip(drive, slot)
	local tip = N.drive_cell_tooltip(drive, slot)
	return tip and { "", tip, "\n", { "fork-me-gui.drive-slot-tooltip" } } or { "fork-me-net.drive-slot-empty" }
end

local function build_drive_cells(box, drive)
	local data = M.drive_data(drive)
	local t = box.add{ type = "table", column_count = 2 }
	t.style.horizontal_spacing = 16
	for slot = 1, data.slots do
		local c = data.cells[slot]
		local row = G.row(t)
		if c then
			row.add{ type = "sprite-button", sprite = "item/" .. c.name, style = #c.partition > 0 and "yellow_slot_button" or "slot_button",
				tooltip = M.drive_cell_tooltip(drive, slot),
				tags = G.act("drive_slot", { slot = slot }) }
			local col = row.add{ type = "flow", direction = "vertical" }
			local bar = col.add{ type = "progressbar", value = c.bytes_total > 0 and c.bytes / c.bytes_total or 1 }
			bar.style.width = 120
			col.add{ type = "label", caption = cell_line(c) }
		else
			row.add{ type = "sprite-button", style = "slot_button", tooltip = { "fork-me-net.drive-slot-empty" },
				tags = G.act("drive_slot", { slot = slot }) }
			local col = row.add{ type = "flow", direction = "vertical" }
			col.add{ type = "label", caption = { "fork-me-net.drive-slot-empty" } }.style.width = 120
		end
	end
end

local function drive_sig(drive)
	local data = M.drive_data(drive)
	local sig = { tostring(data.online) }
	for slot = 1, data.slots do
		sig[#sig + 1] = data.cells[slot] and N.drive_cell_sig(drive, slot) or "-"   -- issue #147: what the tooltip shows
	end
	return table.concat(sig, ",")
end

local function open_drive(player, drive, opts)
	local via = opts and opts.via
	local _, content = G.open_window(player, "drive", caption_of(drive), { unit = drive.unit_number, via = via })
	G.label(content, { "fork-me-gui.drive-help" }, WIDTH)
	local row = G.row(content)
	row.add{ type = "label", caption = { "fork-me-gui.priority" }, tooltip = { "fork-me-gui.priority-tooltip" } }
	G.number_field(row, N.get_priority(drive), G.act("drive_priority"), 70, true).tooltip = { "fork-me-gui.priority-tooltip" }
	local status = content.add{ type = "label", name = "fork_me_drive_status" }
	content.add{ type = "flow", name = "fork_me_drive_cells", direction = "vertical" }
	G.back_button(content, via)
	M.refresh_drive(player, G.window_of(player))
end

function M.refresh_drive(player, frame)
	local drive = G.entity_of(player, frame)
	if not drive then return false end
	local data = M.drive_data(drive)
	G.find(frame, "fork_me_drive_status").caption = data.online and { "fork-me-net.drive-online" } or { "fork-me-net.status-no-network" }
	rebuild(frame, "fork_me_drive_cells", drive_sig(drive), function(box) build_drive_cells(box, drive) end)
	return true
end

G.window("drive", { open = open_drive, refresh = M.refresh_drive, entities = { "drive" }, shift = cell_into_drive,
	message = G.net_message })

G.on("drive_priority", function(event, player, el)
	if event.name ~= defines.events.on_gui_text_changed and event.name ~= defines.events.on_gui_confirmed then return end
	local drive = window_entity(player)
	if drive then N.set_priority(drive, tonumber(el.text) or 0) end
end)

G.on("drive_slot", function(event, player, el)
	if event.name ~= defines.events.on_gui_click then return end
	local drive, frame = window_entity(player)
	if not drive then return end
	local slot = el.tags.slot
	if event.button == defines.mouse_button_type.right then
		if N.drive_info(drive)[slot] then G.open("cell", player, drive, { slot = slot, via = frame.tags.via }) end
		return
	end
	local cursor, inv, remote = G.hand(player)      -- (remote view, issue #177: the cell goes straight into the character's inventory)
	local why, out = N.drive_click(cursor, inv, drive, slot, event.shift or remote)
	flying(player, why)
	if remote and out then G.moved_text(player) end
	G.refresh_one(player)
end)

--------------------------------------------------------------------------------
--- storage cell (in a drive slot)
--------------------------------------------------------------------------------

function M.cell_data(drive, slot)
	local info = drive and drive.valid and N.drive_info(drive)[slot]
	if not info then return nil end
	local contents = {}
	for key, n in pairs(info.items) do contents[#contents + 1] = { key = key, count = n } end
	table.sort(contents, function(a, b)
		if a.count ~= b.count then return a.count > b.count end
		return a.key < b.key
	end)
	info.contents = contents
	return info
end

--- the partition button `index` of the cell window: `key` (nil: remove it) replaces the key at that place
--- of the sorted partition list
function M.set_partition_slot(drive, slot, index, key)
	local list = N.get_partition(drive, slot)
	local out, seen = {}, {}
	local n = math.max(#list, index)
	for i = 1, n do
		local k
		if i == index then k = key else k = list[i] end
		if k and not seen[k] then
			seen[k] = true
			out[#out + 1] = k
		end
	end
	return N.set_partition(drive, slot, out)
end

--- issue #161: key buttons with the mod's picker (an item with its quality, or a fluid with an optional temperature), as
--- in the ME Cell Workbench; before, the game's own chooser, which has no temperature
local function build_partition(box, drive, slot)
	local c = M.cell_data(drive, slot)
	local t = box.add{ type = "table", column_count = 10, style = "filter_slot_table" }
	local count = math.min(c.types_total, #c.partition + 1)
	for i = 1, count do
		G.key_button(t, c.partition[i], G.act("cell_part", { index = i }), { "fork-me-gui.key-slot-tooltip" })
	end
end

local function open_cell(player, drive, opts)
	local slot = opts.slot
	local c = M.cell_data(drive, slot)
	if not c then return end
	local proto = prototypes.item[c.name]
	local _, content = G.open_window(player, "cell", proto and proto.localised_name or c.name,
		{ unit = drive.unit_number, slot = slot, via = opts.via })
	local head = G.row(content)
	head.add{ type = "sprite", sprite = "item/" .. c.name }
	local col = head.add{ type = "flow", direction = "vertical" }
	local bar = col.add{ type = "progressbar", name = "fork_me_cell_bar" }
	bar.style.width = 300
	col.add{ type = "label", name = "fork_me_cell_fill" }
	G.heading(content, { "fork-me-gui.cell-contents" })
	local grid = G.grid(content, 10, "fork_me_cell_items")
	grid.parent.style.minimal_width = 40 * 10 + 12
	content.add{ type = "line" }
	G.heading(content, { "fork-me-gui.partition" })
	G.label(content, { c.fluid and "fork-me-gui.partition-help-fluid" or "fork-me-gui.partition-help" }, WIDTH)
	G.label(content, "", WIDTH, nil, "fork_me_cell_mode")
	content.add{ type = "flow", name = "fork_me_cell_part", direction = "vertical" }
	local cards = G.row(content)                       -- issue #17: the cell's cards, shown only
	cards.add{ type = "label", caption = { "fork-me-gui.cards" }, tooltip = { "fork-me-gui.cell-cards-tooltip" } }
	cards.add{ type = "flow", name = "fork_me_cell_cards", direction = "horizontal" }
	local buttons = G.row(content)
	buttons.add{ type = "button", caption = { "fork-me-gui.partition-clear" }, tags = G.act("cell_part_clear") }
	buttons.add{ type = "button", caption = { "fork-me-gui.partition-contents" }, tooltip = { "fork-me-gui.partition-contents-tooltip" },
		tags = G.act("cell_part_contents") }
	G.back_button(buttons, opts.via)
	M.refresh_cell(player, G.window_of(player))
end

function M.refresh_cell(player, frame)
	local drive = G.entity_of(player, frame)
	local slot = frame.tags.slot
	local c = drive and M.cell_data(drive, slot)
	if not c then return false end
	G.find(frame, "fork_me_cell_bar").value = c.bytes_total > 0 and c.bytes / c.bytes_total or 1
	G.find(frame, "fork_me_cell_fill").caption = { "fork-me-gui.cell-fill", G.fmt(c.bytes), G.fmt(c.bytes_total), c.types, c.types_total }
	local sig = {}
	for _, e in ipairs(c.contents) do sig[#sig + 1] = e.key .. "=" .. e.count end
	rebuild(frame, "fork_me_cell_items", table.concat(sig, ","), function(grid)
		for _, e in ipairs(c.contents) do G.slot(grid, e.key, e.count) end
	end)
	rebuild(frame, "fork_me_cell_part", c.name .. ":" .. table.concat(c.partition, ","), function(box)
		build_partition(box, drive, slot)
	end)
	G.find(frame, "fork_me_cell_mode").caption = M.cell_mode_caption(c)
	rebuild(frame, "fork_me_cell_cards", table.concat(c.cards or {}, ","), function(box)
		if #(c.cards or {}) == 0 then box.add{ type = "label", caption = { "fork-me-gui.cards-none" } } end
		for _, name in ipairs(c.cards or {}) do
			box.add{ type = "sprite", sprite = "item/" .. name, elem_tooltip = { type = "item", name = name } }
		end
	end)
	return true
end

--- what the cards make of a cell's partition (a blacklist, every quality, equal shares, destroys): one line. The
--- sentences are N.cell_mode_text's, which the item tooltip of the cell (issue #64) puts on lines of their own.
function M.cell_mode_caption(c)
	local parts = { "" }
	for _, kind in ipairs({ "inverted", "fuzzy", "equal", "void" }) do
		local text = N.cell_mode_text(kind, c)
		if text then
			if #parts > 1 then parts[#parts + 1] = " " end
			parts[#parts + 1] = text
		end
	end
	return #parts > 1 and parts or ""
end

G.window("cell", { open = open_cell, refresh = M.refresh_cell, shift = cell_into_drive, message = G.net_message })

G.on("cell_part", function(event, player, el)
	if event.name ~= defines.events.on_gui_click then return end
	local drive, frame = window_entity(player)
	if not drive then return end
	local slot, index = frame.tags.slot, el.tags.index
	local c = M.cell_data(drive, slot)
	if not c then return end
	local key = c.partition[index]
	if right_click(event) then
		if key then M.set_partition_slot(drive, slot, index, nil) G.refresh_one(player) end
		return
	end
	picker.open(player, { callback = "cell_part", data = { unit = drive.unit_number, slot = slot, index = index },
		kinds = { item = not c.fluid, fluid = c.fluid == true }, preset = picker.preset_of(key),
		title = { "fork-me-picker.title-" .. (c.fluid and "fluid" or "item") } })
end)

--- the picker's choice goes into the partition button it was opened for (the window and the cell are checked again)
picker.on_confirm("cell_part", function(player, data, choice)
	local drive, frame = window_entity(player)
	if not (drive and drive.unit_number == data.unit and frame.tags.slot == data.slot) then return end
	local c = M.cell_data(drive, data.slot)
	local key = c and choice.kind == (c.fluid and "fluid" or "item") and picker.key_of(choice, true)
	if key then M.set_partition_slot(drive, data.slot, data.index, key) else refused_choice(player) end
	G.refresh_one(player)
end)

G.on("cell_part_clear", function(event, player)
	local drive, frame = window_entity(player)
	if drive then N.set_partition(drive, frame.tags.slot, {}) G.refresh_one(player) end
end)

G.on("cell_part_contents", function(event, player)
	local drive, frame = window_entity(player)
	if drive then N.partition_from_contents(drive, frame.tags.slot) G.refresh_one(player) end
end)

--------------------------------------------------------------------------------
--- ME Cell Workbench (issue #17, part 3)
--------------------------------------------------------------------------------

function M.workbench_data(entity) return bench.info(entity) end

--- the workbench is no node of the ME graph: its window finds it through the workbench's own records
G.entity_lookup(bench.by_unit)

--- issue #28: the window has the player's inventory on its left; the cell slot and the card slots are the slots of the
--- workbench's inventory (slot 1 the cell, 2 to 5 its cards)
local function open_workbench(player, entity)
	if not bench.inventory(entity) then return end    -- (a workbench without a record yet gets one: the lookup needs it)
	local _, content = G.open_window(player, "workbench", caption_of(entity), { unit = entity.unit_number }, true)
	G.label(content, { "fork-me-gui.workbench-help" }, WIDTH)
	local row = G.row(content)
	row.add{ type = "flow", name = "fork_me_wb_cell", direction = "horizontal" }
	local col = row.add{ type = "flow", direction = "vertical" }
	G.label(col, "", 300, nil, "fork_me_wb_fill")
	G.label(col, "", 300, nil, "fork_me_wb_mode")
	G.heading(content, { "fork-me-gui.partition" })
	content.add{ type = "flow", name = "fork_me_wb_part", direction = "vertical" }
	local buttons = G.row(content)
	buttons.add{ type = "button", caption = { "fork-me-gui.partition-clear" }, tags = G.act("wb_clear") }
	buttons.add{ type = "button", name = "fork_me_wb_contents", caption = { "fork-me-gui.partition-contents" },
		tooltip = { "fork-me-gui.partition-contents-tooltip" }, tags = G.act("wb_contents") }
	row = G.row(content)
	row.add{ type = "label", caption = { "fork-me-gui.cards" }, tooltip = { "fork-me-gui.workbench-cards-tooltip" } }
	row.add{ type = "flow", name = "fork_me_wb_cards", direction = "horizontal" }
	content.add{ type = "checkbox", name = "fork_me_wb_keep", state = false, caption = { "fork-me-gui.workbench-keep" },
		tooltip = { "fork-me-gui.workbench-keep-tooltip" }, tags = G.act("wb_keep") }
	M.refresh_workbench(player, G.window_of(player))
end

--- issues #69, #82, #94: the buttons of the workbench's partition, from `workbench_data`: its filled slots (without a
--- cell the items, then the fluids; with a cell its partition) and the free one at the end. A button opens the mod's picker
--- (scripts/fork-me-picker.lua), which chooses an item with its quality or a fluid and nothing else.
--- Returns { { index, key (nil: free), kind ("item" or "fluid"; nil: free), free } }
function M.workbench_slots(d)
	local list = d.cell and d.cell.partition or d.config
	local out = {}
	for i, key in ipairs(list) do out[i] = { index = i, key = key, kind = N.is_fluid_key(key) and "fluid" or "item" } end
	out[#out + 1] = { index = #list + 1, free = true }
	return out
end

--- what the picker of slot `index` (a position in the list; the list's length + 1 is the free slot) offers: { item =
--- bool, fluid = bool }. The kind a slot has can always be chosen again; a kind that is new to the slot needs room (63
--- items, 18 fluids without a cell; with a cell its own kind and its types).
function M.workbench_kinds(d, index)
	local c = d.cell
	local list = c and c.partition or d.config
	local key = list[index]
	if c then
		local out = { item = false, fluid = false }
		out[c.fluid and "fluid" or "item"] = key ~= nil or #list < c.types_total
		return out
	end
	local fluid_key = key ~= nil and N.is_fluid_key(key)
	return {
		item = (key ~= nil and not fluid_key) or d.config_items < d.limits.items,
		fluid = fluid_key or #d.config - d.config_items < d.limits.fluids,
	}
end

--- the picker's choice goes into slot `index`: `kind` "item" (name, quality: normal when nil) or "fluid" (name, and
--- `temperature`: issue #159, nil for every temperature). Refused
--- (false, nothing changes) for another kind, an unknown name or quality, a quality without the quality mod, a kind the
--- slot may not take (workbench_kinds), a slot beyond the free one. Returns true when the list was set.
function M.workbench_set(entity, index, kind, name, quality, temperature)
	local d = M.workbench_data(entity)
	if not d or type(index) ~= "number" or index < 1 or type(name) ~= "string" then return false end
	local list = d.cell and d.cell.partition or d.config
	if index > #list + 1 then return false end
	local kinds = M.workbench_kinds(d, index)
	if kind ~= "item" and kind ~= "fluid" or not kinds[kind] then return false end
	local key
	if kind == "fluid" then
		if not prototypes.fluid[name] then return false end
		key = N.fluid_filter_key(name, tonumber(temperature))
	else
		if not prototypes.item[name] then return false end
		quality = quality or "normal"
		if not prototypes.quality[quality] or (quality ~= "normal" and not script.feature_flags.quality) then return false end
		key = N.key_of(name, quality)
	end
	return bench.set_partition_slot(entity, index, key)
end

--- slot `index` is emptied (right click). Returns true when it was filled.
function M.workbench_clear_slot(entity, index)
	local d = M.workbench_data(entity)
	local list = d and (d.cell and d.cell.partition or d.config)
	if not (list and type(index) == "number" and list[index]) then return false end
	return bench.set_partition_slot(entity, index, nil)
end

function M.refresh_workbench(player, frame)
	local entity = G.entity_of(player, frame)
	local d = entity and M.workbench_data(entity)
	if not d then return false end
	local c = d.cell
	G.find(frame, "fork_me_wb_fill").caption = c and { "fork-me-gui.cell-fill", G.fmt(c.bytes), G.fmt(c.bytes_total), c.types,
		c.types_total } or { "fork-me-gui.workbench-no-cell" }
	G.find(frame, "fork_me_wb_mode").caption = c and M.cell_mode_caption(c) or ""
	local part = c and c.partition or d.config
	rebuild(frame, "fork_me_wb_part", (c and c.name or "-") .. ":" .. table.concat(part, ","), function(box)
		local t = box.add{ type = "table", column_count = 10, style = "filter_slot_table" }
		for _, slot in ipairs(M.workbench_slots(d)) do
			local tags = G.act("wb_slot", { index = slot.index })
			if slot.free then
				local kinds = M.workbench_kinds(d, slot.index)
				local room = kinds.item or kinds.fluid
				G.key_button(t, nil, tags, { room and "fork-me-gui.workbench-slot-free" or "fork-me-gui.workbench-slot-full" }).enabled = room
			else
				G.key_button(t, slot.key, tags, { "fork-me-gui.workbench-slot-tooltip" })
			end
		end
		--- issue #37: no cell: the workbench's own partition, for the next cell without one
		if not c then G.label(box, { "fork-me-gui.workbench-kept" }, WIDTH) end
	end)
	local contents = G.find(frame, "fork_me_wb_contents")
	if contents then contents.enabled = c ~= nil end
	local inv = bench.inventory(entity)
	block_slots(frame, "fork_me_wb_cell", inv, 1, 1, function(_, st)
		return { st.valid_for_read and "fork-me-gui.workbench-cell-tooltip" or "fork-me-gui.workbench-cell-empty" }
	end)
	block_slots(frame, "fork_me_wb_cards", inv, 2, 1 + (c and c.slots or 4), function(_, st)
		return { st.valid_for_read and "fork-me-gui.card-slot-tooltip" or (c and "fork-me-gui.card-slot-empty" or "fork-me-gui.workbench-card-no-cell") }
	end)
	G.find(frame, "fork_me_wb_keep").state = d.keep
	return true
end

--- issue #28: shift + click in the inventory pane, and a click on the cell slot (slot 1) or a card slot (2 to 5)
G.window("workbench", { open = open_workbench, refresh = M.refresh_workbench, entities = { bench.NAME },
	shift = function(entity, stack, inv) return bench.shift_in(entity, stack, inv) end,
	click = function(entity, slot, cursor, inv, shift)
		if slot == 1 then return bench.cell_click(entity, cursor, inv, shift) end
		return bench.card_click(entity, slot - 1, cursor, inv, shift)
	end })

--- issue #94: a click on a partition slot opens the picker (a filled slot's element and quality are chosen in it), a right
--- click empties a filled slot
G.on("wb_slot", function(event, player, el)
	if event.name ~= defines.events.on_gui_click then return end
	local entity, frame = window_entity(player)
	if not entity then return end
	local d = M.workbench_data(entity)
	if not d then return end
	local index = el.tags.index
	local list = d.cell and d.cell.partition or d.config
	local key = list[index]
	if event.button == defines.mouse_button_type.right then
		if key and M.workbench_clear_slot(entity, index) then
			local box = G.find(frame, "fork_me_wb_part")
			if box then box.tags = {} end
			G.refresh_one(player)
		end
		return
	end
	local kinds = M.workbench_kinds(d, index)
	if not (kinds.item or kinds.fluid) then return end
	local preset = picker.preset_of(key)
	picker.open(player, { callback = "wb_slot", data = { unit = entity.unit_number, index = index }, kinds = kinds,
		preset = preset, title = { "fork-me-picker.title-" .. (kinds.item and kinds.fluid and "both" or kinds.item and "item" or "fluid") } })
end)

--- issue #94: the picker's green check: the choice goes into the slot it was opened for (the window and its workbench
--- are checked again: a cell may have come or gone meanwhile). The list is drawn anew whatever happened, so a key that
--- is in the list already or that no cell takes leaves no stale button.
picker.on_confirm("wb_slot", function(player, data, choice)
	local entity, frame = window_entity(player)
	if not (entity and entity.unit_number == data.unit) then return end
	if not M.workbench_set(entity, data.index, choice.kind, choice.name, choice.quality, choice.temperature) then
		player.create_local_flying_text{ text = { "fork-me-gui.workbench-set-refused" }, create_at_cursor = true }
	end
	local box = frame and G.find(frame, "fork_me_wb_part")
	if box then box.tags = {} end
	G.refresh_one(player)
end)

G.on("wb_clear", function(event, player)
	if event.name ~= defines.events.on_gui_click then return end
	local entity = window_entity(player)
	if entity then bench.clear(entity) G.refresh_one(player) end
end)

G.on("wb_contents", function(event, player)
	if event.name ~= defines.events.on_gui_click then return end
	local entity = window_entity(player)
	if entity then bench.from_contents(entity) G.refresh_one(player) end
end)

G.on("wb_keep", function(event, player, el)
	if event.name ~= defines.events.on_gui_checked_state_changed then return end
	local entity = window_entity(player)
	if entity then bench.set_keep(entity, el.state) G.refresh_one(player) end
end)

--------------------------------------------------------------------------------
--- ME Controller
--------------------------------------------------------------------------------

function M.controller_data(entity)
	if not (entity and entity.valid) then return nil end
	local net = N.network_of(entity)
	if not net then return { status = "no-network" } end
	local st = N.stats(net)
	st.energy = entity.energy
	local cap = entity.prototype.electric_energy_source_prototype
	cap = cap and cap.buffer_capacity
	st.supply = cap and cap > 0 and math.min(1, st.energy / cap) or nil    -- (issue #149: the buffer stays full while the network delivers)
	return st
end

local function open_controller(player, entity)
	local _, content = G.open_window(player, "controller", caption_of(entity), { unit = entity.unit_number })
	G.label(content, "", WIDTH, nil, "fork_me_ctrl_status")
	G.label(content, "", WIDTH, nil, "fork_me_ctrl_stats")
	G.label(content, "", WIDTH, nil, "fork_me_ctrl_power")
	M.refresh_controller(player, G.window_of(player))
end

--- Issue #149: the power breakdown under the total: one line per kind (blocks, power in all, power of one), biggest first,
--- and a line when the controller's buffer is not full (its network delivers less than it asks for). A LocalisedString
--- takes 20 parts at most, so the lines go in groups.
function M.power_text(d)
	if not d.power_rows then return "" end
	local parts, group = { "" }, { "" }
	for _, row in ipairs(d.power_rows) do
		local name = row.entity and { "entity-name." .. row.key } or { "fork-me-gui.power-kind-" .. row.key }
		group[#group + 1] = { "fork-me-gui.power-row", name, row.n, G.fmt_power(row.w), G.fmt_power(row.per) }
		if #group == 19 then parts[#parts + 1] = group group = { "" } end
	end
	parts[#parts + 1] = group
	if d.supply and d.supply < 0.99 then
		parts[#parts + 1] = { "fork-me-gui.power-supply", math.floor(d.supply * 100) }
	end
	return { "", { "fork-me-gui.power-heading" }, parts }
end

function M.refresh_controller(player, frame)
	local entity = G.entity_of(player, frame)
	if not entity then return false end
	local d = M.controller_data(entity)
	G.find(frame, "fork_me_ctrl_status").caption = { "fork-me-net.status-" .. d.status }
	local stats = G.find(frame, "fork_me_ctrl_stats")
	if d.members then
		local f = G.fmt
		stats.caption = { "fork-me-gui.controller-stats", d.members, d.drives, d.cells, d.fluid_cells, f(d.bytes), f(d.bytes_total),
			d.types, d.types_total, f(d.fbytes), f(d.fbytes_total), d.ftypes, d.ftypes_total, G.fmt_power(d.power) }
	else
		stats.caption = ""
	end
	G.find(frame, "fork_me_ctrl_power").caption = M.power_text(d)
	return true
end

G.window("controller", storing({ open = open_controller, refresh = M.refresh_controller, entities = { "controller" } }))

--------------------------------------------------------------------------------
--- ME Pattern Provider (issue #80: 9 slots for encoded patterns)
--------------------------------------------------------------------------------

function M.provider_data(entity) return autocraft.provider_info(entity) end

--- the sprite of a pattern slot: the recipe of a crafting pattern, else the first output
local function pattern_sprite(d)
	if d.kind == "crafting" and d.recipe and prototypes.recipe[d.recipe] then return "recipe/" .. d.recipe end
	local first = type(d.outputs) == "table" and d.outputs[1]
	local key = type(first) == "table" and first.key
	if type(key) == "string" then
		if key:sub(1, 6) == "fluid/" then
			local name = N.fluid_name(key)
			if prototypes.fluid[name] then return "fluid/" .. name end
		elseif prototypes.item[key] then
			return "item/" .. key
		end
	end
	return "item/" .. patterns.ENCODED
end
M.pattern_sprite = pattern_sprite

--- the status line of a slot (LocalisedString)
local function slot_status(d)
	if d.pending then return { "fork-me-pattern.status-pending" } end
	if d.ok then return { "fork-me-pattern.status-ok", d.machines } end
	return { "fork-me-pattern.status-" .. (d.reason or "invalid") }
end
M.slot_status = slot_status

--- the tooltip of a slot: the pattern's inputs and outputs, then what a click does
local function slot_tooltip(d)
	local def = patterns.normalize(d)
	local text = def and patterns.description(def) or { "fork-me-pattern.status-invalid" }
	return { "", text, "\n\n", { d.pending and "fork-me-gui.provider-pending-tooltip" or "fork-me-gui.provider-slot-tooltip" } }
end

local function build_provider_slots(box, entity)
	local info = M.provider_data(entity)
	local t = box.add{ type = "table", column_count = 3 }
	t.style.horizontal_spacing = 8
	t.style.vertical_spacing = 2
	for slot = 1, info.slot_count do
		local d = info.slots[slot]
		local tags = G.act("prov_slot", { slot = slot })
		if d then
			t.add{ type = "sprite-button", sprite = pattern_sprite(d), tooltip = slot_tooltip(d), tags = tags,
				style = d.pending and "yellow_slot_button" or d.ok and "slot_button" or "red_slot_button" }
		else
			t.add{ type = "sprite-button", style = "slot_button", tooltip = { "fork-me-gui.provider-empty-tooltip" }, tags = tags }
		end
		local name
		if not d then name = { "fork-me-gui.provider-slot-empty" }
		elseif d.kind == "crafting" and d.recipe and prototypes.recipe[d.recipe] then
			name = { "fork-me-pattern.name-crafting", prototypes.recipe[d.recipe].localised_name }
		else
			local first = type(d.outputs) == "table" and d.outputs[1]
			local desc = first and type(first.key) == "string" and autocraft.describe(first.key)
			name = { "fork-me-pattern.name-processing", desc and desc.localised_name or "?" }
		end
		local l = t.add{ type = "label", caption = name }
		l.style.width = 170
		G.label(t, d and slot_status(d) or "", 200)
	end
end

local function build_provider_machines(box, entity)
	local info = M.provider_data(entity)
	if #info.machines == 0 then
		G.label(box, { "fork-me-gui.provider-no-machine" }, WIDTH)
		return
	end
	for _, m in ipairs(info.machines) do
		local row = G.row(box)
		row.add{ type = "sprite", sprite = "entity/" .. m.name }
		local proto = prototypes.entity[m.name]
		local parts = { "", proto and proto.localised_name or m.name }
		if m.recipe and prototypes.recipe[m.recipe] then
			parts[#parts + 1] = { "fork-me-gui.provider-machine-recipe", "[recipe=" .. m.recipe .. "]", prototypes.recipe[m.recipe].localised_name }
		end
		if m.busy then parts[#parts + 1] = { "fork-me-gui.provider-machine-busy", m.busy } end
		G.label(row, parts, WIDTH - 40)
	end
end

local function provider_sig(entity)
	local info = M.provider_data(entity)
	local sig = { tostring(info.network) }
	for slot = 1, info.slot_count do
		local d = info.slots[slot]
		sig[#sig + 1] = d and (tostring(d.id or d.recipe) .. ":" .. tostring(d.ok) .. ":" .. tostring(d.reason) .. ":"
			.. tostring(d.machines) .. ":" .. tostring(d.pending)) or "-"
	end
	local machines = {}
	for _, m in ipairs(info.machines) do machines[#machines + 1] = m.unit .. ":" .. tostring(m.recipe) .. ":" .. tostring(m.busy) end
	return table.concat(sig, ","), table.concat(machines, ",")
end

local function open_provider(player, entity)
	local _, content = G.open_window(player, "provider", caption_of(entity), { unit = entity.unit_number })
	G.label(content, { "fork-me-gui.provider-help" }, WIDTH)
	local row = G.row(content)
	row.add{ type = "label", caption = { "fork-me-gui.priority" }, tooltip = { "fork-me-gui.provider-priority-tooltip" } }
	G.number_field(row, autocraft.get_priority(entity), G.act("prov_priority"), 70, true).tooltip = { "fork-me-gui.provider-priority-tooltip" }
	--- issue #156: the card slots (only the Pattern Capacity Card fits), then the patterns: "n of m", a list that scrolls
	row = G.row(content)
	row.add{ type = "label", caption = { "fork-me-gui.cards" }, tooltip = { "fork-me-gui.provider-cards-tooltip" } }
	row.add{ type = "flow", name = "fork_me_prov_cards", direction = "horizontal" }
	G.label(content, "", WIDTH, nil, "fork_me_prov_want")
	G.label(content, "", WIDTH, "caption_label", "fork_me_provider_count")
	local scroll = content.add{ type = "scroll-pane", name = "fork_me_provider_scroll", horizontal_scroll_policy = "never" }
	scroll.style.maximal_height = 380
	scroll.add{ type = "flow", name = "fork_me_provider_slots", direction = "vertical" }
	content.add{ type = "line" }
	G.heading(content, { "fork-me-gui.provider-machines" })
	content.add{ type = "flow", name = "fork_me_provider_machines", direction = "vertical" }
	G.label(content, "", WIDTH, nil, "fork_me_provider_status")
	M.refresh_provider(player, G.window_of(player))
end

function M.refresh_provider(player, frame)
	local entity = G.entity_of(player, frame)
	if not entity then return false end
	local slots_sig, machines_sig = provider_sig(entity)
	local pinfo = M.provider_data(entity)
	block_slots(frame, "fork_me_prov_cards", autocraft.provider_inventory(entity), 1, pinfo.card_slots, function(_, st)
		return { st.valid_for_read and "fork-me-gui.card-slot-tooltip" or "fork-me-gui.card-slot-empty" }
	end)
	local want = {}
	for _, name in ipairs(pinfo.want or {}) do want[#want + 1] = "[item=" .. name .. "]" end
	G.find(frame, "fork_me_prov_want").caption = #want > 0 and { "fork-me-gui.cards-wanted", table.concat(want, " ") } or ""
	G.find(frame, "fork_me_provider_count").caption = { "fork-me-gui.provider-count", pinfo.filled, pinfo.slot_count }
	rebuild(frame, "fork_me_provider_slots", slots_sig, function(box) build_provider_slots(box, entity) end)
	rebuild(frame, "fork_me_provider_machines", machines_sig, function(box) build_provider_machines(box, entity) end)
	local info = M.provider_data(entity)
	G.find(frame, "fork_me_provider_status").caption = info.network and "" or { "fork-me-net.status-no-network" }
	return true
end

--- the reasons of a refused card are the windows' own (fork-me-gui.refused-*), the others the network module's
local PROVIDER_CARD_REASONS = { ["not-here"] = true, limit = true, full = true, ["patterns-above"] = true }
G.window("provider", { open = open_provider, refresh = M.refresh_provider, entities = { "provider" },
	shift = function(entity, stack)                    -- an encoded pattern into the first free slot, a card into a card slot (issue #156)
		if stack.valid_for_read and N.card_kind(stack.name) then return autocraft.provider_shift_in(entity, stack) end
		local _, why = autocraft.insert_pattern(entity, stack)
		return why
	end,
	click = function(entity, slot, cursor, inv, shift) return autocraft.provider_card_click(entity, slot, cursor, inv, shift) end,
	message = function(why)
		if PROVIDER_CARD_REASONS[why] then return { "fork-me-gui.refused-" .. why } end
		return G.net_message(why)
	end })

G.on("prov_slot", function(event, player, el)
	if event.name ~= defines.events.on_gui_click then return end
	local entity = window_entity(player)
	if not entity then return end
	local cursor, inv, remote = G.hand(player)
	local why, out = autocraft.provider_click(cursor, inv, entity, el.tags.slot, event.shift or remote)
	flying(player, why)
	if remote and out then G.moved_text(player) end
	G.refresh_one(player)
end)

G.on("prov_priority", function(event, player, el)
	if event.name ~= defines.events.on_gui_text_changed and event.name ~= defines.events.on_gui_confirmed then return end
	local entity = window_entity(player)
	if entity then autocraft.set_priority(entity, tonumber(el.text) or 0) end
end)

--------------------------------------------------------------------------------
--- a crafting block (issue #6): the window of its Crafting CPU (any block of it)
--------------------------------------------------------------------------------

function M.crafting_cpu_data(entity) return autocraft.group_info(entity) end

--- the window's title (issue #151): the Crafting CPU's name, the same whichever block of it was clicked; a group that is no
--- CPU is "Crafting blocks"
function M.crafting_cpu_title(d)
	if d and d.status == "ok" then return { "fork-me-gui.ccpu-title", d.id } end
	return { "fork-me-gui.ccpu-title-none" }
end

--- the value labels of the facts table, by name
local CCPU_FACTS = { "size", "storage", "coprocessors", "monitors" }

local function open_crafting_cpu(player, entity)
	local d = M.crafting_cpu_data(entity)
	local _, content = G.open_window(player, "crafting-cpu", M.crafting_cpu_title(d), { unit = entity.unit_number })
	G.label(content, "", WIDTH, nil, "fork_me_ccpu_status").tooltip = { "fork-me-gui.ccpu-help" }
	local why = G.label(content, "", WIDTH, nil, "fork_me_ccpu_why")
	why.visible = false
	local facts = content.add{ type = "table", name = "fork_me_ccpu_facts", column_count = 2 }
	facts.style.horizontally_stretchable = true
	facts.style.column_alignments[2] = "right"
	for _, key in ipairs(CCPU_FACTS) do
		facts.add{ type = "label", caption = { "fork-me-gui.ccpu-" .. key } }
		local v = facts.add{ type = "label", name = "fork_me_ccpu_" .. key }
		v.style.horizontally_stretchable = true
		v.style.horizontal_align = "right"
	end
	local bar = content.add{ type = "progressbar", name = "fork_me_ccpu_bar", value = 0 }
	bar.style.horizontally_stretchable = true
	content.add{ type = "flow", name = "fork_me_ccpu_parts", direction = "horizontal" }
	G.heading(content, { "fork-me-gui.ccpu-job" })
	content.add{ type = "table", name = "fork_me_ccpu_job", column_count = 5 }
	M.refresh_crafting_cpu(player, G.window_of(player))
end

function M.refresh_crafting_cpu(player, frame)
	local entity = G.entity_of(player, frame)
	if not entity then return false end
	local d = M.crafting_cpu_data(entity)
	if not d then return false end
	--- the title follows the group (a block added or removed can change its number or make it a CPU)
	local title = frame.children[1] and frame.children[1].children[1]
	if title and title.type == "label" then title.caption = M.crafting_cpu_title(d) end
	local status, why
	if d.status == "not-rectangle" then
		status, why = "not-cpu", { "fork-me-gui.ccpu-not-rectangle", d.blocks, d.width, d.height }
	elseif d.status == "no-storage" then
		status, why = "not-cpu", { "fork-me-gui.ccpu-no-storage" }
	elseif not d.network then
		status, why = "no-network", { "fork-me-net.status-no-network" }
	elseif not d.working then
		status, why = "no-network", { "fork-me-gui.ccpu-not-working" }
	else
		status = d.job and "working" or "idle"
	end
	G.find(frame, "fork_me_ccpu_status").caption = { "fork-me-gui.ccpu-status-" .. status }
	local wl = G.find(frame, "fork_me_ccpu_why")
	wl.visible = why ~= nil
	wl.caption = why or ""
	G.find(frame, "fork_me_ccpu_size").caption = { "fork-me-gui.ccpu-size-value", d.width, d.height, d.blocks }
	G.find(frame, "fork_me_ccpu_storage").caption = { "fork-me-gui.ccpu-storage-value", G.fmt(d.used), G.fmt(d.bytes) }
	G.find(frame, "fork_me_ccpu_coprocessors").caption = { "fork-me-gui.ccpu-coprocessors-value", d.coprocessors, d.speed }
	G.find(frame, "fork_me_ccpu_monitors").caption = tostring(d.monitors)
	--- the blocks of the CPU by type as icons with their counts (rebuilt only when the counts change)
	local pf = G.find(frame, "fork_me_ccpu_parts")
	local psig = {}
	for _, part in ipairs(d.parts or {}) do psig[#psig + 1] = part.name .. "=" .. part.count end
	psig = table.concat(psig, ",")
	if pf.tags.sig ~= psig then
		pf.tags = { sig = psig }
		pf.clear()
		for _, part in ipairs(d.parts or {}) do
			local b = pf.add{ type = "sprite-button", style = "slot_button", sprite = "item/" .. part.name, number = part.count,
				tooltip = { "entity-name." .. part.name }, ignored_by_interaction = true }
			b.tags = {}
		end
	end
	G.find(frame, "fork_me_ccpu_bar").value = d.bytes > 0 and math.min(1, d.used / d.bytes) or 0
	local jobs = {}
	local j = d.job
	if j then
		jobs[1] = { id = j.id, item = j.item, amount = j.amount, status = j.closing and (j.closing == "done" and "delivering" or "cancelling") or j.status,
			wait = j.wait, done = j.done, total = j.total, bytes = j.bytes,
			active = not j.closing and (j.status == "queued" or j.status == "running") }
	end
	local t = G.find(frame, "fork_me_ccpu_job")
	local sig = j and (j.id .. ":" .. tostring(jobs[1].status) .. ":" .. tostring(j.wait) .. ":" .. j.done) or "none"
	if t.tags.sig ~= sig then
		t.tags = { sig = sig }
		terminal.job_rows(t, jobs)
		if not j then t.add{ type = "label", caption = { "fork-me-gui.ccpu-idle" } } end
	end
	return true
end

G.window("crafting-cpu", storing({ open = open_crafting_cpu, refresh = M.refresh_crafting_cpu, entities = { "crafting" } }))

--------------------------------------------------------------------------------
--- ME Level Maintainer
--------------------------------------------------------------------------------

function M.maintainer_data(entity)
	if not (entity and entity.valid and N.kind_of(entity.name) == "maintainer") then return nil end
	if not circuit.get_maintainer(entity) then circuit.set_maintainer(entity) end
	local d = circuit.get_maintainer(entity)
	d.condition = circuit.get_condition(entity)
	return d
end

--- the target button: a key (an item or a fluid), nil clears it
function M.set_maintainer_target(entity, key)
	return circuit.set_maintainer(entity, key or false)
end

local function open_maintainer(player, entity)
	local d = M.maintainer_data(entity)
	local _, content = G.open_window(player, "maintainer", caption_of(entity), { unit = entity.unit_number })
	G.label(content, { "fork-me-circuit.maintainer-help" }, WIDTH)
	local row = G.row(content)
	row.add{ type = "label", caption = { "fork-me-circuit.maintainer-keep" } }
	row.add{ type = "flow", name = "fork_me_maint_target" }
	G.number_field(row, d.amount, G.act("maint_amount"), 100)
	content.add{ type = "checkbox", state = d.circuit or false, caption = { "fork-me-circuit.maintainer-circuit" },
		tooltip = { "fork-me-circuit.maintainer-circuit-tooltip" }, tags = G.act("maint_circuit") }
	content.add{ type = "line" }
	local c = d.condition
	content.add{ type = "checkbox", state = c.enabled or false, caption = { "fork-me-gui.condition-enabled" },
		tooltip = { "fork-me-gui.condition-tooltip" }, tags = G.act("maint_cond_on") }
	local cond = G.row(content)
	local sig = cond.add{ type = "choose-elem-button", elem_type = "signal", signal = c.signal, style = "slot_button",
		tags = G.act("maint_cond_signal") }
	sig.style.size = 40
	local index = 1
	for i, v in ipairs(circuit.COMPARATORS) do if v == c.comparator then index = i end end
	cond.add{ type = "drop-down", items = circuit.COMPARATORS, selected_index = index, tags = G.act("maint_cond_cmp") }.style.width = 60
	G.number_field(cond, c.constant, G.act("maint_cond_const"), 100, true)
	content.add{ type = "line" }
	G.label(content, "", WIDTH, nil, "fork_me_maint_stock")
	G.label(content, "", WIDTH, nil, "fork_me_maint_status")
	M.refresh_maintainer(player, G.window_of(player))
end

function M.refresh_maintainer(player, frame)
	local entity = G.entity_of(player, frame)
	if not entity then return false end
	local d = M.maintainer_data(entity)
	rebuild(frame, "fork_me_maint_target", d.key or "-", function(box)
		G.key_button(box, d.key, G.act("maint_target"), { "fork-me-circuit.maintainer-target-tooltip" }).style.size = 40
	end)
	local stock = G.find(frame, "fork_me_maint_stock")
	local desc = d.key and autocraft.describe(d.key)
	stock.caption = desc and { "fork-me-circuit.maintainer-stock", G.fmt(d.stock or 0), G.fmt(d.target or d.amount or 0), desc.localised_name } or ""
	G.find(frame, "fork_me_maint_status").caption = circuit.maintainer_status(entity)
	return true
end

G.window("maintainer", storing({ open = open_maintainer, refresh = M.refresh_maintainer, entities = { "maintainer" } }))

G.on("maint_target", function(event, player, el)
	if event.name ~= defines.events.on_gui_click then return end
	local entity = window_entity(player)
	if not entity then return end
	if right_click(event) then
		M.set_maintainer_target(entity, nil)
		G.refresh_one(player)
		return
	end
	key_picker(player, "maint_target", { unit = entity.unit_number }, M.maintainer_data(entity).key, false)
end)

--- issue #70: the target is an item or a fluid, without a quality
picker.on_confirm("maint_target", function(player, data, choice)
	local entity = window_entity(player)
	if not (entity and entity.unit_number == data.unit) then return end
	local key = picker.key_of(choice, false)
	if key then M.set_maintainer_target(entity, key) else refused_choice(player) end
	G.refresh_one(player)
end)

G.on("maint_amount", function(event, player, el)
	if event.name ~= defines.events.on_gui_text_changed and event.name ~= defines.events.on_gui_confirmed then return end
	local entity = window_entity(player)
	if entity then circuit.set_maintainer(entity, nil, tonumber(el.text) or 0) end
end)

G.on("maint_circuit", function(event, player, el)
	if event.name ~= defines.events.on_gui_checked_state_changed then return end
	local entity = window_entity(player)
	if entity then circuit.set_maintainer(entity, nil, nil, el.state) G.refresh_one(player) end
end)

G.on("maint_cond_on", function(event, player, el)
	if event.name ~= defines.events.on_gui_checked_state_changed then return end
	local entity = window_entity(player)
	if entity then circuit.set_condition(entity, el.state) G.refresh_one(player) end
end)

G.on("maint_cond_signal", function(event, player, el)
	if event.name ~= defines.events.on_gui_elem_changed then return end
	local entity = window_entity(player)
	if entity then circuit.set_condition(entity, nil, el.elem_value or false) end
end)

G.on("maint_cond_cmp", function(event, player, el)
	if event.name ~= defines.events.on_gui_selection_state_changed then return end
	local entity = window_entity(player)
	if entity then circuit.set_condition(entity, nil, nil, circuit.COMPARATORS[el.selected_index]) end
end)

G.on("maint_cond_const", function(event, player, el)
	if event.name ~= defines.events.on_gui_text_changed and event.name ~= defines.events.on_gui_confirmed then return end
	local entity = window_entity(player)
	if entity then circuit.set_condition(entity, nil, nil, nil, tonumber(el.text) or 0) end
end)

--------------------------------------------------------------------------------
--- ME Circuit Interface
--------------------------------------------------------------------------------

local CIRCUIT_FILTERS = 20

function M.circuit_data(entity)
	if not (entity and entity.valid and N.kind_of(entity.name) == "circuit") then return nil end
	if not circuit.get_circuit(entity) then circuit.set_circuit_filters(entity, {}) end
	local d = circuit.get_circuit(entity)
	d.enabled = circuit.get_circuit_enabled(entity)
	return d
end

--- the filter button `index`: `key` (nil: remove) replaces that filter; the list stays packed
function M.set_circuit_filter(entity, index, key)
	local d = M.circuit_data(entity)
	if not d then return false end
	local out = {}
	for i = 1, math.max(#d.filters, index) do
		local k
		if i == index then k = key else k = d.filters[i] end
		if k then out[#out + 1] = k end
	end
	return circuit.set_circuit_filters(entity, out)
end

local function open_circuit(player, entity)
	local d = M.circuit_data(entity)
	local _, content = G.open_window(player, "circuit", caption_of(entity), { unit = entity.unit_number })
	G.label(content, { "fork-me-circuit.circuit-help" }, WIDTH)
	content.add{ type = "switch", switch_state = d.enabled and "right" or "left", left_label_caption = { "fork-me-gui.off" },
		right_label_caption = { "fork-me-gui.on" }, tags = G.act("circ_on") }
	content.add{ type = "flow", name = "fork_me_circ_filters", direction = "vertical" }
	G.label(content, "", WIDTH, nil, "fork_me_circ_status")
	M.refresh_circuit(player, G.window_of(player))
end

function M.refresh_circuit(player, frame)
	local entity = G.entity_of(player, frame)
	if not entity then return false end
	local d = M.circuit_data(entity)
	rebuild(frame, "fork_me_circ_filters", table.concat(d.filters, ","), function(box)
		local t = box.add{ type = "table", column_count = 10, style = "filter_slot_table" }
		for i = 1, math.min(CIRCUIT_FILTERS, #d.filters + 1) do
			G.key_button(t, d.filters[i], G.act("circ_filter", { index = i }), { "fork-me-gui.key-slot-tooltip" })
		end
	end)
	local status = G.find(frame, "fork_me_circ_status")
	if not d.network then status.caption = { "fork-me-circuit.circuit-no-network" }
	elseif #d.filters == 0 then status.caption = { "fork-me-circuit.circuit-all", d.signals }
	else status.caption = { "fork-me-circuit.circuit-filtered", d.signals } end
	return true
end

G.window("circuit", storing({ open = open_circuit, refresh = M.refresh_circuit, entities = { "circuit" } }))

G.on("circ_filter", function(event, player, el)
	if event.name ~= defines.events.on_gui_click then return end
	local entity = window_entity(player)
	if not entity then return end
	local index = el.tags.index
	local key = M.circuit_data(entity).filters[index]
	if right_click(event) then
		if key then M.set_circuit_filter(entity, index, nil) G.refresh_one(player) end
		return
	end
	key_picker(player, "circ_filter", { unit = entity.unit_number, index = index }, key, false)
end)

picker.on_confirm("circ_filter", function(player, data, choice)
	local entity = window_entity(player)
	if not (entity and entity.unit_number == data.unit) then return end
	local key = picker.key_of(choice, false)
	if key then M.set_circuit_filter(entity, data.index, key) else refused_choice(player) end
	G.refresh_one(player)
end)

G.on("circ_on", function(event, player, el)
	if event.name ~= defines.events.on_gui_switch_state_changed then return end
	local entity = window_entity(player)
	if entity then circuit.set_circuit_enabled(entity, el.switch_state == "right") end
end)

--------------------------------------------------------------------------------
--- ME Interface (issue #3: config rows with items or fluids, the four fluid sides)
--------------------------------------------------------------------------------

local SIDE_NAMES = { "north", "east", "south", "west" }

function M.interface_data(entity) return io.get_interface(entity) end

--- a config row: the item button (`elem`: { name, quality } or nil) and its amount (nil: keep it / one stack)
function M.set_interface_item(entity, i, elem, amount)
	if elem then return io.set_interface_slot(entity, i, elem.name, elem.quality or "normal", amount) end
	return io.set_interface_slot(entity, i, nil)
end

--- a config row from the picker's choice (issue #70: { kind = "item" or "fluid", name, quality }; anything else is
--- refused, nothing changes). Returns what io.set_interface_key returns, or false.
function M.set_interface_choice(entity, i, choice, amount)
	local key = picker.key_of(choice, true)
	if not key then return false end
	return io.set_interface_key(entity, i, key, amount)
end

--- issue #161: a status line with the hint that the block imports a fluid the network holds at many temperatures
--- (`fmix` = { fluid, number }, nil: the status alone)
function M.mix_status(status, fmix)
	if not fmix then return status end
	return { "", status, "\n", { "fork-me-gui.fluid-mixed", "[fluid=" .. fmix[1] .. "]", tostring(fmix[2]) } }
end

local function open_interface(player, entity)
	local _, content = G.open_window(player, "interface", caption_of(entity), { unit = entity.unit_number })
	G.label(content, { "fork-me-gui.interface-help" }, WIDTH)
	local row = G.row(content)                        -- issue #17: the interface's priority
	row.add{ type = "label", caption = { "fork-me-gui.priority" }, tooltip = { "fork-me-gui.interface-priority-tooltip" } }
	G.number_field(row, io.get_interface_priority(entity), G.act("if_priority"), 70, true).tooltip = { "fork-me-gui.interface-priority-tooltip" }
	--- issue #196: the card slots (only the Interface Capacity Card fits), the rows in a list that scrolls when cards add rows
	row = G.row(content)
	row.add{ type = "label", caption = { "fork-me-gui.cards" }, tooltip = { "fork-me-gui.interface-cards-tooltip" } }
	row.add{ type = "flow", name = "fork_me_if_cards", direction = "horizontal" }
	G.label(content, "", WIDTH, nil, "fork_me_if_want")
	G.label(content, "", WIDTH, nil, "fork_me_if_kept")
	local scroll = content.add{ type = "scroll-pane", name = "fork_me_if_scroll", horizontal_scroll_policy = "never" }
	scroll.style.maximal_height = 300
	scroll.add{ type = "flow", name = "fork_me_if_config", direction = "vertical" }
	G.heading(content, { "fork-me-gui.interface-sides" })
	content.add{ type = "flow", name = "fork_me_if_sides", direction = "vertical" }
	G.heading(content, { "fork-me-gui.interface-contents" })
	local grid = G.grid(content, 9, "fork_me_if_items")
	grid.parent.style.minimal_width = 40 * 9 + 12
	G.label(content, "", WIDTH, nil, "fork_me_if_status")
	content.add{ type = "button", caption = { "fork-me-gui.interface-inventory" }, tags = G.act("if_inventory") }
	M.refresh_interface(player, G.window_of(player))
end

local function config_sig(config, slots)
	local out = {}
	for i = 1, slots do
		local c = config[i]
		out[i] = c and io.row_key(c) or "-"            -- not the amounts: their fields keep the focus
	end
	return table.concat(out, ",")
end

--- the values of a side's drop-down: "import", "off", then the fluid rows; and the selected index
local function side_choices(d, side)
	local values, items = { "import", "off" }, { { "fork-me-gui.interface-side-import" }, { "fork-me-gui.interface-side-off" } }
	local selected = d.sides[side] == "off" and 2 or 1
	for i = 1, d.slots do
		local c = d.config[i]
		if c and c.type == "fluid" then
			values[#values + 1] = i
			items[#items + 1] = { "fork-me-gui.interface-side-row", i, "[fluid=" .. c.name .. "]", (G.fluid_label(io.row_key(c))) }
			if d.sides[side] == i then selected = #values end
		end
	end
	return values, items, selected
end

function M.refresh_interface(player, frame)
	local entity = G.entity_of(player, frame)
	if not entity then return false end
	local d = M.interface_data(entity)
	local have = {}
	for _, c in ipairs(d.contents) do have[c.key] = c.count end
	block_slots(frame, "fork_me_if_cards", io.interface_inventory(entity), 1, d.card_slots, function(_, st)
		return { st.valid_for_read and "fork-me-gui.card-slot-tooltip" or "fork-me-gui.card-slot-empty" }
	end)
	local want = {}
	for _, name in ipairs(d.want or {}) do want[#want + 1] = "[item=" .. name .. "]" end
	G.find(frame, "fork_me_if_want").caption = #want > 0 and { "fork-me-gui.cards-wanted", table.concat(want, " ") } or ""
	G.find(frame, "fork_me_if_kept").caption = d.kept and { "fork-me-gui.interface-rows-kept" } or ""
	rebuild(frame, "fork_me_if_config", config_sig(d.config, d.slots), function(box)
		local t = box.add{ type = "table", column_count = 6 }
		for i = 1, d.slots do
			local c = d.config[i]
			G.key_button(t, c and io.row_key(c) or nil, G.act("if_item", { index = i }), { "fork-me-gui.key-slot-tooltip" })
			local f = G.number_field(t, c and c.amount or 0, G.act("if_amount", { index = i }), 70)
			f.enabled = c ~= nil
			f.tooltip = c and c.type == "fluid" and { "fork-me-gui.interface-fluid-amount", G.fmt(d.volume) } or nil
		end
	end)
	local side_sig = { config_sig(d.config, d.slots) }
	for s = 1, io.SIDES do side_sig[#side_sig + 1] = tostring(d.sides[s] or "import") end
	rebuild(frame, "fork_me_if_sides", table.concat(side_sig, ","), function(box)
		local t = box.add{ type = "table", column_count = 3 }
		for s = 1, io.SIDES do
			t.add{ type = "label", caption = { "fork-me-gui.interface-side-" .. SIDE_NAMES[s] } }
			local values, items, selected = side_choices(d, s)
			t.add{ type = "drop-down", items = items, selected_index = selected,
				tags = G.act("if_side", { side = s, values = values }) }.style.width = 200
			t.add{ type = "label", name = "fork_me_if_side_" .. s, caption = "" }
		end
	end)
	for s = 1, io.SIDES do
		local f = d.fluids[s]
		local label = G.find(frame, "fork_me_if_side_" .. s)
		if label then
			local proto = f.name and prototypes.fluid[f.name]
			--- (issue #159: with its temperature when it is not the default one)
			local holds = proto and { "fork-me-gui.tank-holds", G.fmt(f.amount), G.fmt(d.volume), (G.fluid_label(N.fluid_key(f.name, f.temperature))) }
				or { "fork-me-gui.tank-empty", G.fmt(d.volume) }
			label.caption = { "", holds, f.connected and "" or { "fork-me-gui.interface-side-unconnected" } }
			label.tooltip = f.status and { "fork-me-gui.interface-side-status-" .. f.status } or nil
		end
	end
	local sig = {}
	for _, c in ipairs(d.contents) do sig[#sig + 1] = c.key .. "=" .. c.count end
	rebuild(frame, "fork_me_if_items", table.concat(sig, ","), function(grid)
		for _, c in ipairs(d.contents) do G.slot(grid, c.key, c.count) end
	end)
	G.find(frame, "fork_me_if_status").caption = M.mix_status({ "fork-me-net.bus-" .. (d.status or "ok") }, d.fmix)
	return true
end

local interface_window = storing({ open = open_interface, refresh = M.refresh_interface, entities = { "interface" } })
local store_into_network = interface_window.shift
--- shift + click: a card into the card slots (issue #196), anything else is stored in the network as before
interface_window.shift = function(entity, stack, inv)
	if stack.valid_for_read and N.card_kind(stack.name) then return io.interface_shift_in(entity, stack) end
	return store_into_network(entity, stack, inv)
end
interface_window.click = function(entity, slot, cursor, inv, shift) return io.interface_card_click(entity, slot, cursor, inv, shift) end
--- the reasons of a refused card are the windows' own (fork-me-gui.refused-*; the network module has no text for them)
local store_message = interface_window.message
interface_window.message = function(why)
	if why == "not-here" or why == "limit" or why == "full" then return { "fork-me-gui.refused-" .. why } end
	return store_message(why)
end
G.window("interface", interface_window)

G.on("if_item", function(event, player, el)
	if event.name ~= defines.events.on_gui_click then return end
	local entity = window_entity(player)
	if not entity then return end
	local index = el.tags.index
	local c = io.get_interface_config(entity)[index]
	local key = c and io.row_key(c)
	if right_click(event) then
		if key then io.set_interface_key(entity, index, nil) G.refresh_one(player) end
		return
	end
	key_picker(player, "if_item", { unit = entity.unit_number, index = index }, key, true)
end)

picker.on_confirm("if_item", function(player, data, choice)
	local entity = window_entity(player)
	if not (entity and entity.unit_number == data.unit) then return end
	if not M.set_interface_choice(entity, data.index, choice) then refused_choice(player) end
	G.refresh_one(player)
end)

G.on("if_amount", function(event, player, el)
	if event.name ~= defines.events.on_gui_text_changed and event.name ~= defines.events.on_gui_confirmed then return end
	local entity = window_entity(player)
	if not entity then return end
	local c = io.get_interface_config(entity)[el.tags.index]
	if c then io.set_interface_key(entity, el.tags.index, io.row_key(c), tonumber(el.text) or 0) end
end)

G.on("if_priority", function(event, player, el)
	if event.name ~= defines.events.on_gui_text_changed and event.name ~= defines.events.on_gui_confirmed then return end
	local entity = window_entity(player)
	if entity then io.set_interface_priority(entity, tonumber(el.text) or 0) end
end)

G.on("if_side", function(event, player, el)
	if event.name ~= defines.events.on_gui_selection_state_changed then return end
	local entity = window_entity(player)
	if not entity then return end
	io.set_interface_side(entity, el.tags.side, el.tags.values[el.selected_index])
	G.refresh_one(player)
end)

G.on("if_inventory", function(event, player)
	local entity = window_entity(player)
	if entity then G.open_vanilla(player, entity) end
end)

--------------------------------------------------------------------------------
--- buses (issue #3: items and fluids mixed in the filters)
--------------------------------------------------------------------------------

function M.bus_data(entity) return io.bus_info(entity) end

local function open_bus(player, entity)
	local d = M.bus_data(entity)
	local _, content = G.open_window(player, "bus", caption_of(entity), { unit = entity.unit_number })
	G.label(content, { "fork-me-net." .. d.kind .. "-help" }, WIDTH)
	content.add{ type = "flow", name = "fork_me_bus_filters", direction = "vertical" }
	local row = G.row(content)                       -- issue #110: the Acceleration Card slots
	row.add{ type = "label", caption = { "fork-me-gui.cards" }, tooltip = { "fork-me-gui.bus-cards-tooltip" } }
	row.add{ type = "flow", name = "fork_me_bus_cards", direction = "horizontal" }
	G.label(content, "", WIDTH, nil, "fork_me_bus_want")
	G.label(content, "", WIDTH, nil, "fork_me_bus_speed")
	G.label(content, "", WIDTH, nil, "fork_me_bus_target")
	G.label(content, "", WIDTH, nil, "fork_me_bus_status")
	M.refresh_bus(player, G.window_of(player))
end

function M.refresh_bus(player, frame)
	local entity = G.entity_of(player, frame)
	if not entity then return false end
	local d = M.bus_data(entity)
	rebuild(frame, "fork_me_bus_filters", table.concat(d.filters, ","), function(box)
		local t = box.add{ type = "table", column_count = d.max, style = "filter_slot_table" }
		for i = 1, d.max do G.key_button(t, d.filters[i], G.act("bus_filter", { index = i }), { "fork-me-gui.key-slot-tooltip" }) end
	end)
	block_slots(frame, "fork_me_bus_cards", io.bus_inventory(entity), 1, d.slots, function(_, st)
		return { st.valid_for_read and "fork-me-gui.card-slot-tooltip" or "fork-me-gui.card-slot-empty" }
	end)
	local want = {}
	for _, name in ipairs(d.want or {}) do want[#want + 1] = "[item=" .. name .. "]" end
	G.find(frame, "fork_me_bus_want").caption = #want > 0 and { "fork-me-gui.cards-wanted", table.concat(want, " ") } or ""
	G.find(frame, "fork_me_bus_speed").caption = d.items and { "fork-me-gui.bus-speed", d.accel, G.fmt(d.rate) } or ""
	local target = d.target and prototypes.entity[d.target]
	local what = d.items and d.fluids and "both" or d.fluids and "fluids" or "items"
	G.find(frame, "fork_me_bus_target").caption = target
		and { "fork-me-gui.bus-target-" .. what, target.localised_name } or ""
	local status = { "fork-me-net.bus-" .. (d.status or "ok") }
	if d.tstat then                                       -- issue #159: the temperatures the network has and the target takes
		status = { "fork-me-net.bus-temperature-detail", "[fluid=" .. d.tstat[1] .. "]", d.tstat[2], d.tstat[3] }
	end
	G.find(frame, "fork_me_bus_status").caption = M.mix_status(status, d.fmix)
	return true
end

local bus_window = storing({ open = open_bus, refresh = M.refresh_bus, entities = { "import-bus", "export-bus" } })
--- issue #110: a bus's window also has its card slots: shift + click of a card in the pane puts it in (anything else is stored in
--- the network as before), a click on a slot moves a card, a reason of the card slots is shown as such
local store_shift, store_all = bus_window.shift, bus_window.control
bus_window.shift = function(entity, stack, inv)
	if N.card_kind(stack.name) then return io.bus_shift_in(entity, stack) end
	return store_shift(entity, stack, inv)
end
bus_window.control = function(entity, stack, inv)
	if N.card_kind(stack.name) then return io.bus_shift_in(entity, stack) end
	return store_all(entity, stack, inv)
end
bus_window.click = function(entity, slot, cursor, inv, shift) return io.bus_card_click(entity, slot, cursor, inv, shift) end
bus_window.hint = { "fork-me-gui.bus-pane-hint" }
local net_message = bus_window.message
bus_window.message = function(why)
	if why == "not-here" or why == "limit" or why == "full" or why == "no-bus" or why == "inventory-full" then
		return { "fork-me-gui.refused-" .. why }
	end
	return net_message(why)
end
G.window("bus", bus_window)

G.on("bus_filter", function(event, player, el)
	if event.name ~= defines.events.on_gui_click then return end
	local entity = window_entity(player)
	if not entity then return end
	local index = el.tags.index
	local key = M.bus_data(entity).filters[index]
	if right_click(event) then
		if key then io.set_bus_filter(entity, index, nil) G.refresh_one(player) end
		return
	end
	key_picker(player, "bus_filter", { unit = entity.unit_number, index = index }, key, false)
end)

--- issue #70: a bus filter is an item or a fluid, without a quality
picker.on_confirm("bus_filter", function(player, data, choice)
	local entity = window_entity(player)
	if not (entity and entity.unit_number == data.unit) then return end
	local key = picker.key_of(choice, false)
	if key then io.set_bus_filter(entity, data.index, key) else refused_choice(player) end
	G.refresh_one(player)
end)

--------------------------------------------------------------------------------
--- ME Storage Bus (issue #3: a chest's items or a tank's fluid segment; filters of both)
--------------------------------------------------------------------------------

local SBUS_MODES = { "readwrite", "read", "write" }

function M.storage_bus_data(entity) return sbus.info(entity) end

local function open_storage_bus(player, entity)
	local d = M.storage_bus_data(entity)
	if not d then return end
	--- issue #28: the player's inventory on the left, the card slots in the window
	local _, content = G.open_window(player, "storage-bus", caption_of(entity), { unit = entity.unit_number }, true)
	G.label(content, { "fork-me-net.storage-bus-help" }, WIDTH)
	local row = G.row(content)
	row.add{ type = "label", caption = { "fork-me-gui.storage-bus-mode" } }
	local items, index = {}, 1
	for i, mode in ipairs(SBUS_MODES) do
		items[i] = { "fork-me-gui.storage-bus-mode-" .. mode }
		if mode == d.mode then index = i end
	end
	row.add{ type = "drop-down", items = items, selected_index = index, tags = G.act("sbus_mode") }
	--- issue #155: the filter mode (an Inverter Card makes the blacklist and fixes the drop-down), and what the Fuzzy Card does
	row = G.row(content)
	row.add{ type = "label", caption = { "fork-me-gui.storage-bus-filtermode" }, tooltip = { "fork-me-gui.storage-bus-filtermode-tooltip" } }
	row.add{ type = "drop-down", name = "fork_me_sbus_filtermode", items = {}, tags = G.act("sbus_filtermode"),
		tooltip = { "fork-me-gui.storage-bus-filtermode-tooltip" } }
	G.label(content, "", WIDTH, nil, "fork_me_sbus_fuzzy")
	row = G.row(content)
	row.add{ type = "label", caption = { "fork-me-gui.priority" }, tooltip = { "fork-me-gui.storage-bus-priority-tooltip" } }
	G.number_field(row, d.priority, G.act("sbus_priority"), 70, true).tooltip = { "fork-me-gui.storage-bus-priority-tooltip" }
	--- issue #17: the cards, the extract setting, the void warning
	row = G.row(content)
	row.add{ type = "label", caption = { "fork-me-gui.cards" }, tooltip = { "fork-me-gui.storage-bus-cards-tooltip" } }
	row.add{ type = "flow", name = "fork_me_sbus_cards", direction = "horizontal" }
	G.label(content, "", WIDTH, nil, "fork_me_sbus_want")
	local void = G.label(content, "", WIDTH, nil, "fork_me_sbus_void")
	void.style.font_color = { 1, 0.25, 0.2 }
	void.style.font = "default-bold"
	content.add{ type = "checkbox", name = "fork_me_sbus_extract", state = d.extract, caption = { "fork-me-gui.storage-bus-extract" },
		tooltip = { "fork-me-gui.storage-bus-extract-tooltip" }, tags = G.act("sbus_extract") }
	content.add{ type = "label", name = "fork_me_sbus_filters_caption", caption = { "fork-me-gui.storage-bus-filters" },
		tooltip = { "fork-me-gui.storage-bus-filters-tooltip" } }
	content.add{ type = "flow", name = "fork_me_sbus_filters", direction = "vertical" }
	local buttons = G.row(content)
	buttons.add{ type = "button", caption = { "fork-me-gui.partition-contents" }, tooltip = { "fork-me-gui.storage-bus-contents-tooltip" },
		tags = G.act("sbus_contents") }
	buttons.add{ type = "button", caption = { "fork-me-gui.partition-clear" }, tags = G.act("sbus_clear") }
	G.label(content, "", WIDTH, nil, "fork_me_sbus_holds")
	G.label(content, "", WIDTH, nil, "fork_me_sbus_target")
	G.label(content, "", WIDTH, nil, "fork_me_sbus_status")
	M.refresh_storage_bus(player, G.window_of(player))
end

function M.refresh_storage_bus(player, frame)
	local entity = G.entity_of(player, frame)
	local d = entity and M.storage_bus_data(entity)
	if not d then return false end
	rebuild(frame, "fork_me_sbus_filters", d.max .. ":" .. table.concat(d.filters, ","), function(box)
		local t = box.add{ type = "table", column_count = 9, style = "filter_slot_table" }
		for i = 1, d.max do G.key_button(t, d.filters[i], G.act("sbus_filter", { index = i }), { "fork-me-gui.key-slot-tooltip" }) end
	end)
	block_slots(frame, "fork_me_sbus_cards", sbus.inventory(entity), 1, d.slots, function(_, st)
		return { st.valid_for_read and "fork-me-gui.card-slot-tooltip" or "fork-me-gui.card-slot-empty" }
	end)
	local want = {}
	for _, name in ipairs(d.want or {}) do want[#want + 1] = "[item=" .. name .. "]" end
	G.find(frame, "fork_me_sbus_want").caption = #want > 0 and { "fork-me-gui.cards-wanted", table.concat(want, " ") } or ""
	G.find(frame, "fork_me_sbus_void").caption = d.void and { "fork-me-gui.storage-bus-void", G.fmt(d.voided) } or ""
	G.find(frame, "fork_me_sbus_extract").state = d.extract
	--- the filter mode drop-down: whitelist / blacklist; with an Inverter Card the second entry says so and it cannot be changed
	local fm = G.find(frame, "fork_me_sbus_filtermode")
	local carded = d.inverted and true or false
	if fm.tags.carded ~= carded then
		fm.items = { { "fork-me-gui.storage-bus-filtermode-whitelist" },
			{ "fork-me-gui.storage-bus-filtermode-blacklist" .. (carded and "-card" or "") } }
		fm.tags = { fork_me_act = "sbus_filtermode", carded = carded }
	end
	fm.selected_index = (carded or d.blacklist) and 2 or 1
	fm.enabled = not carded
	G.find(frame, "fork_me_sbus_fuzzy").caption = d.side == "fluid" and ""
		or { d.fuzzy and "fork-me-gui.storage-bus-fuzzy-on" or "fork-me-gui.storage-bus-fuzzy-off" }
	G.find(frame, "fork_me_sbus_filters_caption").caption = { "fork-me-gui.storage-bus-filters" .. (d.inverted and "-blacklist" or ""),
		d.max, d.fuzzy and { "fork-me-gui.storage-bus-fuzzy" } or "" }
	local holds
	if d.side == "fluid" then
		local fluid = d.fluid and prototypes.fluid[d.fluid]
		holds = fluid and { "fork-me-gui.fluid-storage-bus-holds", G.fmt(d.amount), fluid.localised_name,
			string.format("%.0f", d.temperature or fluid.default_temperature) } or { "fork-me-gui.fluid-storage-bus-empty" }
	else
		holds = { "fork-me-gui.storage-bus-holds", G.fmt(d.items), d.types }
	end
	G.find(frame, "fork_me_sbus_holds").caption = holds
	local target = d.target and prototypes.entity[d.target]
	G.find(frame, "fork_me_sbus_target").caption = target and { "fork-me-gui.bus-target", target.localised_name } or ""
	G.find(frame, "fork_me_sbus_status").caption = { "fork-me-net." .. (d.side == "fluid" and "fluid-" or "")
		.. "storage-bus-" .. (d.status or "ok") }
	return true
end

--- issue #28: shift + click in the inventory pane puts cards in, a click on a card slot puts in or takes out
G.window("storage-bus", { open = open_storage_bus, refresh = M.refresh_storage_bus, entities = { "storage-bus" },
	shift = function(entity, stack) return sbus.shift_in(entity, stack) end,
	click = function(entity, slot, cursor, inv, shift) return sbus.card_click(entity, slot, cursor, inv, shift) end })

G.on("sbus_mode", function(event, player, el)
	if event.name ~= defines.events.on_gui_selection_state_changed then return end
	local entity = window_entity(player)
	if entity then sbus.set_mode(entity, SBUS_MODES[el.selected_index] or "readwrite") G.refresh_one(player) end
end)

G.on("sbus_filtermode", function(event, player, el)
	if event.name ~= defines.events.on_gui_selection_state_changed then return end
	local entity = window_entity(player)
	if entity then sbus.set_settings(entity, { blacklist = el.selected_index == 2 }) G.refresh_one(player) end
end)

G.on("sbus_priority", function(event, player, el)
	if event.name ~= defines.events.on_gui_text_changed and event.name ~= defines.events.on_gui_confirmed then return end
	local entity = window_entity(player)
	if entity then sbus.set_priority(entity, tonumber(el.text) or 0) end
end)

G.on("sbus_filter", function(event, player, el)
	if event.name ~= defines.events.on_gui_click then return end
	local entity = window_entity(player)
	if not entity then return end
	local index = el.tags.index
	local key = M.storage_bus_data(entity).filters[index]
	if right_click(event) then
		if key then sbus.set_filter(entity, index, nil) G.refresh_one(player) end
		return
	end
	key_picker(player, "sbus_filter", { unit = entity.unit_number, index = index }, key, true)
end)

picker.on_confirm("sbus_filter", function(player, data, choice)
	local entity = window_entity(player)
	if not (entity and entity.unit_number == data.unit) then return end
	local key = picker.key_of(choice, true)
	if key then sbus.set_filter(entity, data.index, key) else refused_choice(player) end
	G.refresh_one(player)
end)

G.on("sbus_extract", function(event, player, el)
	if event.name ~= defines.events.on_gui_checked_state_changed then return end
	local entity = window_entity(player)
	if entity then sbus.set_settings(entity, { extract = el.state }) G.refresh_one(player) end
end)

G.on("sbus_contents", function(event, player)
	if event.name ~= defines.events.on_gui_click then return end
	local entity = window_entity(player)
	if entity then sbus.filters_from_contents(entity) G.refresh_one(player) end
end)

G.on("sbus_clear", function(event, player)
	if event.name ~= defines.events.on_gui_click then return end
	local entity = window_entity(player)
	if entity then sbus.clear_filters(entity) G.refresh_one(player) end
end)

--------------------------------------------------------------------------------
--- remote interface (the runtime test: the data and set functions of every window)
--------------------------------------------------------------------------------

local stand_ins = {}            -- name -> a table standing for a LuaPlayer (the tests, stand_in below)
remote.add_interface("gregtorio-me-gui", {
	fmt = function(n) return G.fmt(n) end,
	--- issue #150 (tests): the hand-over buffer of a relative window: its stacks into the block of window `name` (what it
	--- refuses stays), and what is left back to `to` (a player or an inventory)
	buffer_absorb = function(inv, name, entity, seen) return G.buffer_absorb(inv, G.def_named(name), entity, seen) end,
	buffer_return = function(inv, to, entity) G.buffer_return(inv, to, entity) end,
	buffer_slots = function() return G.BUFFER_SLOTS end,
	--- true when the entity opens an ME window (click or open key)
	has_window = function(entity) return G.has_window(entity) end,
	drive_data = function(drive) return M.drive_data(drive) end,
	--- issue #147 (tests): the tooltip of a cell slot of the drive window and the window's rebuild signature
	drive_cell_tooltip = function(drive, slot) return M.drive_cell_tooltip(drive, slot) end,
	drive_sig = function(drive) return drive_sig(drive) end,
	cell_data = function(drive, slot) return M.cell_data(drive, slot) end,
	--- issue #75: what a slot of a window gives a stack (the tooltip next to the item's own, the signature piece)
	stack_tooltip = function(stack, base) return G.stack_tooltip(stack, base) end,
	stack_ident = function(stack) return G.stack_ident(stack) end,
	--- issue #79: the description in the key of an item with tags kept in the network
	key_description = function(key) return G.key_description(key) end,
	cell_mode_caption = function(c) return M.cell_mode_caption(c) end,
	set_partition_slot = function(drive, slot, index, key) return M.set_partition_slot(drive, slot, index, key) end,
	controller_data = function(entity) return M.controller_data(entity) end,
	controller_power_text = function(entity) return M.power_text(M.controller_data(entity)) end,    -- (issue #149)
	provider_data = function(entity) return M.provider_data(entity) end,
	crafting_cpu_data = function(entity) return M.crafting_cpu_data(entity) end,
	crafting_cpu_title = function(entity) return M.crafting_cpu_title(M.crafting_cpu_data(entity)) end,    -- (issue #151)
	maintainer_data = function(entity) return M.maintainer_data(entity) end,
	set_maintainer_target = function(entity, signal) return M.set_maintainer_target(entity, signal) end,
	circuit_data = function(entity) return M.circuit_data(entity) end,
	set_circuit_filter = function(entity, index, key) return M.set_circuit_filter(entity, index, key) end,
	interface_data = function(entity) return M.interface_data(entity) end,
	set_interface_item = function(entity, i, elem, amount) return M.set_interface_item(entity, i, elem, amount) end,
	bus_data = function(entity) return M.bus_data(entity) end,
	storage_bus_data = function(entity) return M.storage_bus_data(entity) end,
	workbench_data = function(entity) return M.workbench_data(entity) end,
	--- issues #69, #82, #94: the workbench's partition buttons, what the picker of a slot offers, what a choice does, the
	--- right click, and the picker's lists (the groups, the entries of the allowed kinds by a search text, the qualities)
	workbench_slots = function(entity) local d = M.workbench_data(entity) return d and M.workbench_slots(d) end,
	workbench_kinds = function(entity, index) local d = M.workbench_data(entity) return d and M.workbench_kinds(d, index) end,
	workbench_set = function(entity, index, kind, name, quality) return M.workbench_set(entity, index, kind, name, quality) end,
	workbench_clear_slot = function(entity, index) return M.workbench_clear_slot(entity, index) end,
	picker_groups = function(kinds) return picker.group_names(kinds) end,
	picker_entries = function(kinds, filter, group) return picker.entries(kinds, filter, group) end,
	workbench_qualities = function() return picker.qualities() end,
	key_of_elem = function(elem_type, value) return key_of_elem(elem_type, value) end,
	--- issue #70: the key of the picker's choice (`with_quality`: an item keeps its quality), a row from a choice
	key_of_choice = function(choice, with_quality) return picker.key_of(choice, with_quality) end,
	set_interface_choice = function(entity, i, choice, amount) return M.set_interface_choice(entity, i, choice, amount) end,
	--- issue #28: a click on slot `slot` of the inventory pane of `entity`'s window (`mode` "left", "right", "shift"), for
	--- a cursor stack and an inventory standing for the player's; returns the reason of a refusal and "picked"
	inventory_click = function(cursor, inventory, slot, mode, entity, window)
		return G.inventory_click(cursor, inventory, slot, mode, window and G.def_named(window) or G.def_of(entity), entity)
	end,
	--- Issues #176 and #177: the harness has no player and a remote call cannot carry functions, so a table standing for a
	--- LuaPlayer is made here from plain data: `spec` = { remote = in remote view, main = the main inventory (not in remote
	--- view), character = the character's main inventory (nil: no character), index = a number }; kept under `name`.
	stand_in = function(name, spec)
		local texts = {}
		local sp = { object_name = "LuaPlayer", valid = true, index = spec.index or 9001, texts = texts,
			controller_type = spec.remote and defines.controllers.remote or defines.controllers.character,
			get_main_inventory = function() return not spec.remote and spec.main or nil end,
			create_local_flying_text = function(a) texts[#texts + 1] = a.text end }
		if spec.character then
			sp.character = { valid = true, surface = game.surfaces[1], position = { x = 0, y = 0 },
				get_inventory = function() return spec.character end }
		end
		stand_ins[name] = sp
		return true
	end,
	stand_in_inventory = function(name) return G.player_inventory(stand_ins[name]) end,
	stand_in_hand = function(name) return G.hand(stand_ins[name]) end,
	stand_in_uses_buffer = function(name) return G.uses_buffer(stand_ins[name]) end,
	stand_in_give_back = function(name, stack, entity) G.give_back(stand_ins[name], stack, entity) end,
	stand_in_parked = function(name) return G.parked_count(stand_ins[name]) end,
	stand_in_return_parked = function(name) return G.return_parked(stand_ins[name]) end,
	stand_in_texts = function(name) return stand_ins[name].texts end,
	stand_in_forget = function(name) stand_ins[name] = nil end,
	forget_player = function(index) G.forget_player(index) end,      -- (issue #179: what on_player_removed does)
	--- every registered window: { [name] = { pane = true, shift = has a shift + click target, control, message } }
	windows = function() return G.window_list() end,
	--- a click on slot `slot` of the block in `entity`'s window (its cards, its cell); returns the reason of a refusal
	block_click = function(entity, slot, cursor, inventory, shift)
		return G.block_click(G.def_of(entity), entity, slot, cursor, inventory, shift)
	end,
})

return M
