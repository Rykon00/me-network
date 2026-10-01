--------------------------------------------------------------------------------
--- FORK AE2: THE WINDOWS OF THE ME BLOCKS (issue #68, step R3; docs/AE2.md, docs/ME-REWORK.md "GUIs (R3)")
--- One window per block, in the style of scripts/fork-me-gui.lua, opened by a click on the block (the vanilla
--- window of lamps, combinators, tanks and containers is replaced; blocks without one open on the open key):
---   * ME Drive: the ten cell slots with fill bars, the drive's priority; click a slot to put a cell in or take
---     it out, right click a cell for its cell window.
---   * Storage cell (from the drive window or the terminal's cells tab): contents, bytes and types, the
---     partition (the items or fluids the cell is restricted to), "Clear" and "From contents".
---   * ME Controller: network state, members, drives, cells, bytes and types, power.
---   * ME Pattern Provider: the machines next to it with their recipe (or why they are no pattern), the recipe
---     choice for furnaces.
---   * ME Crafting CPU: tier, power, the jobs it runs (progress, cancel) and the jobs waiting for a CPU.
---   * ME Level Maintainer: item or fluid, amount, amount from the circuit, the on/off circuit condition, status.
---   * ME Circuit Interface: 20 filters, output on/off, status.
---   * ME Fluid Interface: mode, fluid, fill level, tank content, status.
---   * ME Interface: 9 config slots (item and amount), the container's content, "Open inventory".
---   * ME Import/Export Bus, ME Fluid Import/Export Bus: 5 filters, status, the entity it faces.
---   * ME Storage Bus: mode (read and write, read only, write only), priority, 18 filters, what it shows,
---     status, the entity it faces.
---   * ME Fluid Storage Bus: the same with 5 fluid filters; what it shows (fluid, amount, temperature).
--- Every window shows plain data from a `*_data` function and changes things through functions of the
--- block's module (or the small `set_*` helpers here); the runtime test calls the same functions
--- (remote interface "gregtorio-me-gui"). Nothing is kept in storage: what a window shows lives in its tags.
--------------------------------------------------------------------------------

local N = require("scripts.fork-me-network")
local G = require("scripts.fork-me-gui")
local autocraft = require("scripts.fork-me-autocraft")
local fluids = require("scripts.fork-me-fluids")
local circuit = require("scripts.fork-me-circuit")
local io = require("scripts.fork-me-io")
local sbus = require("scripts.fork-me-storagebus")
local fsbus = require("scripts.fork-me-fluid-storagebus")
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

local function caption_of(entity)
	return entity.localised_name
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
	if elem_type == "signal" then return circuit.key_of_signal(value) end
	return prototypes.item[value] and value or nil
end
M.key_of_elem = key_of_elem

--- a choose-elem button for an item or fluid key
local function chooser(parent, elem_type, key, tags)
	local def = { type = "choose-elem-button", elem_type = elem_type, tags = tags, style = "slot_button" }
	if key then
		if elem_type == "fluid" then def.fluid = N.is_fluid_key(key) and key:sub(7) or nil
		elseif elem_type == "signal" then def.signal = circuit.signal_of(key)
		elseif elem_type == "item-with-quality" then
			local name, q = N.parse_key(key)
			def["item-with-quality"] = { name = name, quality = q }
		else def.item = key end
	end
	return parent.add(def)
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

local function build_drive_cells(box, drive)
	local data = M.drive_data(drive)
	local t = box.add{ type = "table", column_count = 2 }
	t.style.horizontal_spacing = 16
	for slot = 1, data.slots do
		local c = data.cells[slot]
		local row = G.row(t)
		if c then
			row.add{ type = "sprite-button", sprite = "item/" .. c.name, style = #c.partition > 0 and "yellow_slot_button" or "slot_button",
				tooltip = { "", terminal.cell_tooltip(c), "\n", { "fork-me-gui.drive-slot-tooltip" } },
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
		local c = data.cells[slot]
		sig[#sig + 1] = c and (c.name .. ":" .. c.bytes .. ":" .. c.types .. ":" .. #c.partition) or "-"
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

G.window("drive", { open = open_drive, refresh = M.refresh_drive, entities = { "drive" } })

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
	flying(player, N.drive_click(player.cursor_stack, player.get_main_inventory(), drive, slot, event.shift))
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

local function build_partition(box, drive, slot)
	local c = M.cell_data(drive, slot)
	local t = box.add{ type = "table", column_count = 10, style = "filter_slot_table" }
	local elem_type = c.fluid and "fluid" or "item-with-quality"
	local count = math.min(c.types_total, #c.partition + 1)
	for i = 1, count do
		chooser(t, elem_type, c.partition[i], G.act("cell_part", { index = i }))
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
	content.add{ type = "flow", name = "fork_me_cell_part", direction = "vertical" }
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
	return true
end

G.window("cell", { open = open_cell, refresh = M.refresh_cell })

G.on("cell_part", function(event, player, el)
	if event.name ~= defines.events.on_gui_elem_changed then return end
	local drive, frame = window_entity(player)
	if not drive then return end
	M.set_partition_slot(drive, frame.tags.slot, el.tags.index, key_of_elem(el.elem_type, el.elem_value))
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
--- ME Controller
--------------------------------------------------------------------------------

function M.controller_data(entity)
	if not (entity and entity.valid) then return nil end
	local net = N.network_of(entity)
	if not net then return { status = "no-network" } end
	local st = N.stats(net)
	st.energy = entity.energy
	return st
end

local function open_controller(player, entity)
	local _, content = G.open_window(player, "controller", caption_of(entity), { unit = entity.unit_number })
	G.label(content, "", WIDTH, nil, "fork_me_ctrl_status")
	G.label(content, "", WIDTH, nil, "fork_me_ctrl_stats")
	M.refresh_controller(player, G.window_of(player))
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
			d.types, d.types_total, f(d.fbytes), f(d.fbytes_total), d.ftypes, d.ftypes_total, f(d.power / 1000) }
	else
		stats.caption = ""
	end
	return true
end

G.window("controller", { open = open_controller, refresh = M.refresh_controller, entities = { "controller" } })

--------------------------------------------------------------------------------
--- ME Pattern Provider
--------------------------------------------------------------------------------

function M.provider_data(entity) return autocraft.provider_info(entity) end

local function build_provider(box, entity)
	local info = M.provider_data(entity)
	G.heading(box, { "fork-me-gui.provider-machines" })
	if #info.machines == 0 then
		G.label(box, { "fork-me-gui.provider-no-machine" }, WIDTH)
	end
	for _, m in ipairs(info.machines) do
		local row = G.row(box)
		row.add{ type = "sprite", sprite = "entity/" .. m.name }
		if m.recipe and prototypes.recipe[m.recipe] then
			row.add{ type = "sprite", sprite = "recipe/" .. m.recipe }
			row.add{ type = "label", caption = { "", prototypes.recipe[m.recipe].localised_name, m.chosen and { "fork-me-gui.provider-chosen" } or "" } }
		else
			row.add{ type = "label", caption = { "fork-me-gui.provider-no-recipe" } }
		end
	end
	local ignored = { total = 0 }
	for reason, n in pairs(info.ignored) do ignored[reason] = n ignored.total = ignored.total + n end
	if ignored.total > 0 then G.label(box, { "", { "fork-me-gui.provider-ignored", ignored.total }, " ", autocraft.ignored_list(ignored) }, WIDTH) end
	box.add{ type = "line" }
	G.heading(box, { "fork-me-gui.provider-furnaces" })
	if info.furnaces == 0 then
		G.label(box, { "fork-me-provider.no-furnace" }, WIDTH)
		return
	end
	if #info.options == 0 then
		G.label(box, { "fork-me-provider.no-recipes" }, WIDTH)
		return
	end
	G.label(box, { "fork-me-provider.info", info.furnaces }, WIDTH)
	local t = G.grid(box, 10)
	for _, name in ipairs(info.options) do
		local proto = prototypes.recipe[name]
		t.add{ type = "sprite-button", sprite = "recipe/" .. name, style = name == info.choice and "yellow_slot_button" or "slot_button",
			elem_tooltip = { type = "recipe", name = name },
			tooltip = info.shared[name] and { "fork-me-provider.shared-input" } or nil,
			tags = G.act("prov_recipe", { recipe = name }) }
		if not proto then t.children[#t.children].enabled = false end
	end
	local choice = info.choice and prototypes.recipe[info.choice]
	G.label(box, choice and { "fork-me-provider.current", choice.localised_name } or { "fork-me-provider.current-none" }, WIDTH)
	box.add{ type = "button", caption = { "fork-me-provider.clear" }, tooltip = { "fork-me-provider.clear-tooltip" }, tags = G.act("prov_clear") }
end

local function provider_sig(entity)
	local info = M.provider_data(entity)
	local sig = { tostring(info.choice), info.furnaces, table.concat(info.options, "/") }
	for _, m in ipairs(info.machines) do sig[#sig + 1] = m.name .. ":" .. tostring(m.recipe) .. ":" .. tostring(m.chosen) end
	for reason, n in pairs(info.ignored) do sig[#sig + 1] = reason .. n end
	return table.concat(sig, ",")
end

local function open_provider(player, entity)
	local _, content = G.open_window(player, "provider", caption_of(entity), { unit = entity.unit_number })
	content.add{ type = "flow", name = "fork_me_provider", direction = "vertical" }
	M.refresh_provider(player, G.window_of(player))
end

function M.refresh_provider(player, frame)
	local entity = G.entity_of(player, frame)
	if not entity then return false end
	rebuild(frame, "fork_me_provider", provider_sig(entity), function(box) build_provider(box, entity) end)
	return true
end

G.window("provider", { open = open_provider, refresh = M.refresh_provider, entities = { "provider" } })

G.on("prov_recipe", function(event, player, el)
	local entity = window_entity(player)
	if entity then autocraft.toggle_recipe(entity, el.tags.recipe) G.refresh_one(player) end
end)

G.on("prov_clear", function(event, player)
	local entity = window_entity(player)
	if entity then autocraft.set_recipe(entity, nil) G.refresh_one(player) end
end)

--------------------------------------------------------------------------------
--- ME Crafting CPU
--------------------------------------------------------------------------------

function M.cpu_data(entity) return autocraft.cpu_info(entity) end

local function open_cpu(player, entity)
	local _, content = G.open_window(player, "cpu", caption_of(entity), { unit = entity.unit_number })
	G.label(content, "", WIDTH, nil, "fork_me_cpu_info")
	G.heading(content, { "fork-me-gui.cpu-jobs" })
	content.add{ type = "table", name = "fork_me_cpu_jobs", column_count = 5 }
	G.heading(content, { "fork-me-gui.cpu-waiting" })
	content.add{ type = "table", name = "fork_me_cpu_waiting", column_count = 5 }
	M.refresh_cpu(player, G.window_of(player))
end

function M.refresh_cpu(player, frame)
	local entity = G.entity_of(player, frame)
	if not entity then return false end
	local d = M.cpu_data(entity)
	if not d then return false end
	G.find(frame, "fork_me_cpu_info").caption = { "fork-me-gui.cpu-info", d.slots, d.speed, #d.jobs,
		{ d.powered and "fork-me-gui.powered" or "fork-me-gui.unpowered" },
		{ d.network and "fork-me-net.drive-online" or "fork-me-net.status-no-network" } }
	local function sig(list)
		local out = {}
		for _, j in ipairs(list) do out[#out + 1] = j.id .. ":" .. tostring(j.status) .. ":" .. tostring(j.wait) .. ":" .. j.done end
		return table.concat(out, ",")
	end
	local jobs = {}
	for _, j in ipairs(d.jobs) do
		jobs[#jobs + 1] = { id = j.id, item = j.item, amount = j.amount, status = j.closing and (j.closing == "done" and "delivering" or "cancelling") or j.status,
			wait = j.wait, done = j.done, total = j.total, active = not j.closing and (j.status == "queued" or j.status == "running") }
	end
	local t, w = G.find(frame, "fork_me_cpu_jobs"), G.find(frame, "fork_me_cpu_waiting")
	if t.tags.sig ~= sig(jobs) then t.tags = { sig = sig(jobs) } terminal.job_rows(t, jobs) end
	if w.tags.sig ~= sig(d.waiting) then w.tags = { sig = sig(d.waiting) } terminal.job_rows(w, d.waiting) end
	return true
end

G.window("cpu", { open = open_cpu, refresh = M.refresh_cpu, entities = { "cpu" } })

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

--- the target button: a SignalID (item or fluid), nil clears it
function M.set_maintainer_target(entity, signal)
	local key = signal and circuit.key_of_signal(signal)
	return circuit.set_maintainer(entity, key or false)
end

local function open_maintainer(player, entity)
	local d = M.maintainer_data(entity)
	local _, content = G.open_window(player, "maintainer", caption_of(entity), { unit = entity.unit_number })
	G.label(content, { "fork-me-circuit.maintainer-help" }, WIDTH)
	local row = G.row(content)
	row.add{ type = "label", caption = { "fork-me-circuit.maintainer-keep" } }
	chooser(row, "signal", d.key, G.act("maint_target"))
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
	local stock = G.find(frame, "fork_me_maint_stock")
	local desc = d.key and autocraft.describe(d.key)
	stock.caption = desc and { "fork-me-circuit.maintainer-stock", G.fmt(d.stock or 0), G.fmt(d.target or d.amount or 0), desc.localised_name } or ""
	G.find(frame, "fork_me_maint_status").caption = circuit.maintainer_status(entity)
	return true
end

G.window("maintainer", { open = open_maintainer, refresh = M.refresh_maintainer, entities = { "maintainer" } })

G.on("maint_target", function(event, player, el)
	if event.name ~= defines.events.on_gui_elem_changed then return end
	local entity = window_entity(player)
	if not entity then return end
	if el.elem_value and not circuit.key_of_signal(el.elem_value) then
		el.elem_value = nil                         -- virtual signals cannot be crafted
		flying(player, "not-craftable")
	end
	M.set_maintainer_target(entity, el.elem_value)
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
			chooser(t, "signal", d.filters[i], G.act("circ_filter", { index = i }))
		end
	end)
	local status = G.find(frame, "fork_me_circ_status")
	if not d.network then status.caption = { "fork-me-circuit.circuit-no-network" }
	elseif #d.filters == 0 then status.caption = { "fork-me-circuit.circuit-all", d.signals }
	else status.caption = { "fork-me-circuit.circuit-filtered", d.signals } end
	return true
end

G.window("circuit", { open = open_circuit, refresh = M.refresh_circuit, entities = { "circuit" } })

G.on("circ_filter", function(event, player, el)
	if event.name ~= defines.events.on_gui_elem_changed then return end
	local entity = window_entity(player)
	if not entity then return end
	M.set_circuit_filter(entity, el.tags.index, el.elem_value and circuit.key_of_signal(el.elem_value) or nil)
	G.refresh_one(player)
end)

G.on("circ_on", function(event, player, el)
	if event.name ~= defines.events.on_gui_switch_state_changed then return end
	local entity = window_entity(player)
	if entity then circuit.set_circuit_enabled(entity, el.switch_state == "right") end
end)

--------------------------------------------------------------------------------
--- ME Fluid Interface
--------------------------------------------------------------------------------

function M.fluid_interface_data(entity)
	if not (entity and entity.valid and N.kind_of(entity.name) == "fluid-interface") then return nil end
	if not fluids.get_interface(entity) then fluids.set_interface(entity) end
	return fluids.get_interface(entity)
end

local function open_fluid_interface(player, entity)
	local d = M.fluid_interface_data(entity)
	local _, content = G.open_window(player, "fluid-interface", caption_of(entity), { unit = entity.unit_number })
	G.label(content, { "fork-me-fluids.interface-help" }, WIDTH)
	content.add{ type = "switch", switch_state = d.mode == "export" and "right" or "left",
		left_label_caption = { "fork-me-fluids.mode-import" }, left_label_tooltip = { "fork-me-fluids.mode-import-tooltip" },
		right_label_caption = { "fork-me-fluids.mode-export" }, right_label_tooltip = { "fork-me-fluids.mode-export-tooltip" },
		tags = G.act("fi_mode") }
	local row = G.row(content)
	row.add{ type = "label", caption = { "fork-me-fluids.fluid" } }
	row.add{ type = "choose-elem-button", elem_type = "fluid", fluid = d.fluid, style = "slot_button", tags = G.act("fi_fluid") }
	row.add{ type = "label", caption = { "fork-me-fluids.level", G.fmt(d.volume) } }
	G.number_field(row, d.level, G.act("fi_level"), 90)
	G.label(content, "", WIDTH, nil, "fork_me_fi_held")
	G.label(content, "", WIDTH, nil, "fork_me_fi_status")
	M.refresh_fluid_interface(player, G.window_of(player))
end

function M.refresh_fluid_interface(player, frame)
	local entity = G.entity_of(player, frame)
	if not entity then return false end
	local d = M.fluid_interface_data(entity)
	local held = d.held and prototypes.fluid[d.held.name]
	G.find(frame, "fork_me_fi_held").caption = held and { "fork-me-gui.tank-holds", G.fmt(d.held.amount), G.fmt(d.volume), held.localised_name }
		or { "fork-me-gui.tank-empty", G.fmt(d.volume) }
	G.find(frame, "fork_me_fi_status").caption = { "fork-me-fluids.status-" .. (d.status or "ok") }
	return true
end

G.window("fluid-interface", { open = open_fluid_interface, refresh = M.refresh_fluid_interface, entities = { "fluid-interface" } })

G.on("fi_mode", function(event, player, el)
	if event.name ~= defines.events.on_gui_switch_state_changed then return end
	local entity = window_entity(player)
	if entity then fluids.set_interface(entity, el.switch_state == "right" and "export" or "import") G.refresh_one(player) end
end)

G.on("fi_fluid", function(event, player, el)
	if event.name ~= defines.events.on_gui_elem_changed then return end
	local entity = window_entity(player)
	if entity then fluids.set_interface(entity, nil, el.elem_value or false) G.refresh_one(player) end
end)

G.on("fi_level", function(event, player, el)
	if event.name ~= defines.events.on_gui_text_changed and event.name ~= defines.events.on_gui_confirmed then return end
	local entity = window_entity(player)
	if entity then fluids.set_interface(entity, nil, nil, tonumber(el.text) or 0) end
end)

--------------------------------------------------------------------------------
--- ME Interface
--------------------------------------------------------------------------------

function M.interface_data(entity) return io.get_interface(entity) end

--- a config row: the item button (`elem`: { name, quality } or nil) and its amount (nil: keep it / one stack)
function M.set_interface_item(entity, i, elem, amount)
	if elem then return io.set_interface_slot(entity, i, elem.name, elem.quality or "normal", amount) end
	return io.set_interface_slot(entity, i, nil)
end

local function open_interface(player, entity)
	local d = M.interface_data(entity)
	local _, content = G.open_window(player, "interface", caption_of(entity), { unit = entity.unit_number })
	G.label(content, { "fork-me-gui.interface-help" }, WIDTH)
	content.add{ type = "flow", name = "fork_me_if_config", direction = "vertical" }
	G.heading(content, { "fork-me-gui.interface-contents" })
	local grid = G.grid(content, 9, "fork_me_if_items")
	grid.parent.style.minimal_width = 40 * 9 + 12
	G.label(content, "", WIDTH, nil, "fork_me_if_status")
	content.add{ type = "button", caption = { "fork-me-gui.interface-inventory" }, tags = G.act("if_inventory") }
	M.refresh_interface(player, G.window_of(player))
end

local function config_sig(config)
	local out = {}
	for i = 1, io.CONFIG_SLOTS do
		local c = config[i]
		out[i] = c and (c.name .. "@" .. c.quality) or "-"            -- not the amounts: their fields keep the focus
	end
	return table.concat(out, ",")
end

function M.refresh_interface(player, frame)
	local entity = G.entity_of(player, frame)
	if not entity then return false end
	local d = M.interface_data(entity)
	local have = {}
	for _, c in ipairs(d.contents) do have[c.key] = c.count end
	rebuild(frame, "fork_me_if_config", config_sig(d.config), function(box)
		local t = box.add{ type = "table", column_count = 6 }
		for i = 1, d.slots do
			local c = d.config[i]
			chooser(t, "item-with-quality", c and N.key_of(c.name, c.quality) or nil, G.act("if_item", { index = i }))
			local f = G.number_field(t, c and c.amount or 0, G.act("if_amount", { index = i }), 70)
			f.enabled = c ~= nil
		end
	end)
	local sig = {}
	for _, c in ipairs(d.contents) do sig[#sig + 1] = c.key .. "=" .. c.count end
	rebuild(frame, "fork_me_if_items", table.concat(sig, ","), function(grid)
		for _, c in ipairs(d.contents) do G.slot(grid, c.key, c.count) end
	end)
	G.find(frame, "fork_me_if_status").caption = { "fork-me-net.bus-" .. (d.status or "ok") }
	return true
end

G.window("interface", { open = open_interface, refresh = M.refresh_interface, entities = { "interface" } })

G.on("if_item", function(event, player, el)
	if event.name ~= defines.events.on_gui_elem_changed then return end
	local entity = window_entity(player)
	if entity then M.set_interface_item(entity, el.tags.index, el.elem_value) G.refresh_one(player) end
end)

G.on("if_amount", function(event, player, el)
	if event.name ~= defines.events.on_gui_text_changed and event.name ~= defines.events.on_gui_confirmed then return end
	local entity = window_entity(player)
	if not entity then return end
	local c = io.get_interface_config(entity)[el.tags.index]
	if c then io.set_interface_slot(entity, el.tags.index, c.name, c.quality, tonumber(el.text) or 0) end
end)

G.on("if_inventory", function(event, player)
	local entity = window_entity(player)
	if entity then G.open_vanilla(player, entity) end
end)

--------------------------------------------------------------------------------
--- buses
--------------------------------------------------------------------------------

function M.bus_data(entity) return io.bus_info(entity) end

local function open_bus(player, entity)
	local d = M.bus_data(entity)
	local _, content = G.open_window(player, "bus", caption_of(entity), { unit = entity.unit_number })
	G.label(content, { "fork-me-net." .. d.kind .. "-help" }, WIDTH)
	content.add{ type = "flow", name = "fork_me_bus_filters", direction = "vertical" }
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
		for i = 1, d.max do
			local key = d.filters[i] and (d.fluid and ("fluid/" .. d.filters[i]) or d.filters[i]) or nil
			chooser(t, d.fluid and "fluid" or "item", key, G.act("bus_filter", { index = i }))
		end
	end)
	local target = d.target and prototypes.entity[d.target]
	G.find(frame, "fork_me_bus_target").caption = target and { "fork-me-gui.bus-target", target.localised_name } or ""
	G.find(frame, "fork_me_bus_status").caption = { "fork-me-net.bus-" .. (d.status or "ok") }
	return true
end

G.window("bus", { open = open_bus, refresh = M.refresh_bus,
	entities = { "import-bus", "export-bus", "fluid-import-bus", "fluid-export-bus" } })

G.on("bus_filter", function(event, player, el)
	if event.name ~= defines.events.on_gui_elem_changed then return end
	local entity = window_entity(player)
	if entity then io.set_bus_filter(entity, el.tags.index, el.elem_value) G.refresh_one(player) end
end)

--------------------------------------------------------------------------------
--- ME Storage Bus
--------------------------------------------------------------------------------

local SBUS_MODES = { "readwrite", "read", "write" }

function M.storage_bus_data(entity) return sbus.info(entity) end

local function open_storage_bus(player, entity)
	local d = M.storage_bus_data(entity)
	if not d then return end
	local _, content = G.open_window(player, "storage-bus", caption_of(entity), { unit = entity.unit_number })
	G.label(content, { "fork-me-net.storage-bus-help" }, WIDTH)
	local row = G.row(content)
	row.add{ type = "label", caption = { "fork-me-gui.storage-bus-mode" } }
	local items, index = {}, 1
	for i, mode in ipairs(SBUS_MODES) do
		items[i] = { "fork-me-gui.storage-bus-mode-" .. mode }
		if mode == d.mode then index = i end
	end
	row.add{ type = "drop-down", items = items, selected_index = index, tags = G.act("sbus_mode") }
	row = G.row(content)
	row.add{ type = "label", caption = { "fork-me-gui.priority" }, tooltip = { "fork-me-gui.storage-bus-priority-tooltip" } }
	G.number_field(row, d.priority, G.act("sbus_priority"), 70, true).tooltip = { "fork-me-gui.storage-bus-priority-tooltip" }
	content.add{ type = "label", caption = { "fork-me-gui.storage-bus-filters" }, tooltip = { "fork-me-gui.storage-bus-filters-tooltip" } }
	content.add{ type = "flow", name = "fork_me_sbus_filters", direction = "vertical" }
	G.label(content, "", WIDTH, nil, "fork_me_sbus_holds")
	G.label(content, "", WIDTH, nil, "fork_me_sbus_target")
	G.label(content, "", WIDTH, nil, "fork_me_sbus_status")
	M.refresh_storage_bus(player, G.window_of(player))
end

function M.refresh_storage_bus(player, frame)
	local entity = G.entity_of(player, frame)
	local d = entity and M.storage_bus_data(entity)
	if not d then return false end
	rebuild(frame, "fork_me_sbus_filters", table.concat(d.filters, ","), function(box)
		local t = box.add{ type = "table", column_count = 9, style = "filter_slot_table" }
		for i = 1, d.max do chooser(t, "item-with-quality", d.filters[i], G.act("sbus_filter", { index = i })) end
	end)
	G.find(frame, "fork_me_sbus_holds").caption = { "fork-me-gui.storage-bus-holds", G.fmt(d.items), d.types }
	local target = d.target and prototypes.entity[d.target]
	G.find(frame, "fork_me_sbus_target").caption = target and { "fork-me-gui.bus-target", target.localised_name } or ""
	G.find(frame, "fork_me_sbus_status").caption = { "fork-me-net.storage-bus-" .. (d.status or "ok") }
	return true
end

G.window("storage-bus", { open = open_storage_bus, refresh = M.refresh_storage_bus, entities = { "storage-bus" } })

G.on("sbus_mode", function(event, player, el)
	if event.name ~= defines.events.on_gui_selection_state_changed then return end
	local entity = window_entity(player)
	if entity then sbus.set_mode(entity, SBUS_MODES[el.selected_index] or "readwrite") G.refresh_one(player) end
end)

G.on("sbus_priority", function(event, player, el)
	if event.name ~= defines.events.on_gui_text_changed and event.name ~= defines.events.on_gui_confirmed then return end
	local entity = window_entity(player)
	if entity then sbus.set_priority(entity, tonumber(el.text) or 0) end
end)

G.on("sbus_filter", function(event, player, el)
	if event.name ~= defines.events.on_gui_elem_changed then return end
	local entity = window_entity(player)
	if entity then
		sbus.set_filter(entity, el.tags.index, key_of_elem("item-with-quality", el.elem_value))
		G.refresh_one(player)
	end
end)

--------------------------------------------------------------------------------
--- ME Fluid Storage Bus
--------------------------------------------------------------------------------

function M.fluid_storage_bus_data(entity) return fsbus.info(entity) end

local function open_fluid_storage_bus(player, entity)
	local d = M.fluid_storage_bus_data(entity)
	if not d then return end
	local _, content = G.open_window(player, "fluid-storage-bus", caption_of(entity), { unit = entity.unit_number })
	G.label(content, { "fork-me-net.fluid-storage-bus-help" }, WIDTH)
	local row = G.row(content)
	row.add{ type = "label", caption = { "fork-me-gui.storage-bus-mode" } }
	local items, index = {}, 1
	for i, mode in ipairs(SBUS_MODES) do
		items[i] = { "fork-me-gui.storage-bus-mode-" .. mode }
		if mode == d.mode then index = i end
	end
	row.add{ type = "drop-down", items = items, selected_index = index, tags = G.act("fsbus_mode") }
	row = G.row(content)
	row.add{ type = "label", caption = { "fork-me-gui.priority" }, tooltip = { "fork-me-gui.fluid-storage-bus-priority-tooltip" } }
	G.number_field(row, d.priority, G.act("fsbus_priority"), 70, true).tooltip = { "fork-me-gui.fluid-storage-bus-priority-tooltip" }
	content.add{ type = "label", caption = { "fork-me-gui.fluid-storage-bus-filters" },
		tooltip = { "fork-me-gui.fluid-storage-bus-filters-tooltip" } }
	content.add{ type = "flow", name = "fork_me_fsbus_filters", direction = "vertical" }
	G.label(content, "", WIDTH, nil, "fork_me_fsbus_holds")
	G.label(content, "", WIDTH, nil, "fork_me_fsbus_target")
	G.label(content, "", WIDTH, nil, "fork_me_fsbus_status")
	M.refresh_fluid_storage_bus(player, G.window_of(player))
end

function M.refresh_fluid_storage_bus(player, frame)
	local entity = G.entity_of(player, frame)
	local d = entity and M.fluid_storage_bus_data(entity)
	if not d then return false end
	rebuild(frame, "fork_me_fsbus_filters", table.concat(d.filters, ","), function(box)
		local t = box.add{ type = "table", column_count = d.max, style = "filter_slot_table" }
		for i = 1, d.max do
			chooser(t, "fluid", d.filters[i] and ("fluid/" .. d.filters[i]) or nil, G.act("fsbus_filter", { index = i }))
		end
	end)
	local fluid = d.fluid and prototypes.fluid[d.fluid]
	G.find(frame, "fork_me_fsbus_holds").caption = fluid
		and { "fork-me-gui.fluid-storage-bus-holds", G.fmt(d.amount), fluid.localised_name,
			string.format("%.0f", d.temperature or fluid.default_temperature) }
		or { "fork-me-gui.fluid-storage-bus-empty" }
	local target = d.target and prototypes.entity[d.target]
	G.find(frame, "fork_me_fsbus_target").caption = target and { "fork-me-gui.bus-target", target.localised_name } or ""
	G.find(frame, "fork_me_fsbus_status").caption = { "fork-me-net.fluid-storage-bus-" .. (d.status or "ok") }
	return true
end

G.window("fluid-storage-bus", { open = open_fluid_storage_bus, refresh = M.refresh_fluid_storage_bus,
	entities = { "fluid-storage-bus" } })

G.on("fsbus_mode", function(event, player, el)
	if event.name ~= defines.events.on_gui_selection_state_changed then return end
	local entity = window_entity(player)
	if entity then fsbus.set_mode(entity, SBUS_MODES[el.selected_index] or "readwrite") G.refresh_one(player) end
end)

G.on("fsbus_priority", function(event, player, el)
	if event.name ~= defines.events.on_gui_text_changed and event.name ~= defines.events.on_gui_confirmed then return end
	local entity = window_entity(player)
	if entity then fsbus.set_priority(entity, tonumber(el.text) or 0) end
end)

G.on("fsbus_filter", function(event, player, el)
	if event.name ~= defines.events.on_gui_elem_changed then return end
	local entity = window_entity(player)
	if entity then
		fsbus.set_filter(entity, el.tags.index, el.elem_value)
		G.refresh_one(player)
	end
end)

--------------------------------------------------------------------------------
--- remote interface (the runtime test: the data and set functions of every window)
--------------------------------------------------------------------------------

remote.add_interface("gregtorio-me-gui", {
	fmt = function(n) return G.fmt(n) end,
	--- true when the entity opens an ME window (click or open key)
	has_window = function(entity) return G.has_window(entity) end,
	drive_data = function(drive) return M.drive_data(drive) end,
	cell_data = function(drive, slot) return M.cell_data(drive, slot) end,
	set_partition_slot = function(drive, slot, index, key) return M.set_partition_slot(drive, slot, index, key) end,
	controller_data = function(entity) return M.controller_data(entity) end,
	provider_data = function(entity) return M.provider_data(entity) end,
	cpu_data = function(entity) return M.cpu_data(entity) end,
	maintainer_data = function(entity) return M.maintainer_data(entity) end,
	set_maintainer_target = function(entity, signal) return M.set_maintainer_target(entity, signal) end,
	circuit_data = function(entity) return M.circuit_data(entity) end,
	set_circuit_filter = function(entity, index, key) return M.set_circuit_filter(entity, index, key) end,
	fluid_interface_data = function(entity) return M.fluid_interface_data(entity) end,
	interface_data = function(entity) return M.interface_data(entity) end,
	set_interface_item = function(entity, i, elem, amount) return M.set_interface_item(entity, i, elem, amount) end,
	bus_data = function(entity) return M.bus_data(entity) end,
	storage_bus_data = function(entity) return M.storage_bus_data(entity) end,
	fluid_storage_bus_data = function(entity) return M.fluid_storage_bus_data(entity) end,
	key_of_elem = function(elem_type, value) return key_of_elem(elem_type, value) end,
})

return M
