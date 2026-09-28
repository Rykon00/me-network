--------------------------------------------------------------------------------
--- FORK AE2: FLUID STORAGE OF THE ME NETWORK (runtime, see prototypes/122-fork-ae2-fluids.lua)
--- The logistic network knows no fluids, so the fluid side of the ME network is kept by script:
---   * ME Fluid Drive: a 1x1 entity without fluid boxes. Its contents are virtual, a table
---     { fluid -> amount } in storage.fork_me_fluids.drives[unit_number], capped by the capacity
---     of the drive (mod-data "fork-me-fluids"). The network total of a fluid is the sum over the
---     drives that stand in that logistic network; the network is looked up when a total is asked
---     for, so merging or splitting networks needs no bookkeeping.
---   * Picking a drive up moves its contents onto the item (item-with-tags, tag "fork_me_fluids"),
---     placing that item brings them back. A drive that is destroyed (or removed by a script
---     without mining) loses its fluids, like a tank that burns down.
---   * ME Fluid Interface: a small storage tank. In import mode its content is moved into the
---     network, in export mode it is filled with a chosen fluid up to a chosen level. Pumps and
---     pipes connect to it like to any tank. Mode, fluid and level live in
---     storage.fork_me_fluids.interfaces and are set in a panel next to the tank GUI.
---   * Temperature: the network stores fluids by name only. Importing drops the temperature,
---     exporting (and the autocrafting hand-over) uses the fluid's default temperature.
--- Work per step: INTERFACES_PER_STEP interfaces every STEP_TICKS ticks (round robin) and the
--- open drive GUIs. Nothing runs per tick; a network total loops over the drives (a few hundred
--- at most), nothing loops over all tanks.
--- State: storage.fork_me_fluids only. GUI state lives in the GUI elements (tags).
--------------------------------------------------------------------------------

local M = {}

--- functions called with every mined assembling machine, furnace, drive or interface (autocrafting
--- rescues the fluid of a leased machine); registered at load time, so nothing is stored
M.mined_hooks = {}

local STEP_TICKS = 15               -- 20 (autocrafting), 30 (molds) and 60 (terminal) are taken
local INTERFACES_PER_STEP = 8
local EPS = 1e-6                    -- fluid amounts are fixed point (1/2^24); below this a box counts as empty
local TAG = "fork_me_fluids"        -- item tag that carries the contents of a picked up drive
local DRIVE_FRAME = "fork_me_fluid_drive"
local IFACE_FRAME = "fork_me_fluid_interface"

--------------------------------------------------------------------------------
--- prototype data and state
--------------------------------------------------------------------------------

local function mod_data()
	local md = prototypes.mod_data["fork-me-fluids"]
	return md and md.data or { drives = {}, interface = {} }
end

local function drive_capacity(name)
	return mod_data().drives[name]
end

local function interface_name()
	return mod_data().interface.name or "me-fluid-interface"
end

local function interface_volume()
	return mod_data().interface.volume or 5000
end

local function state()
	local s = storage.fork_me_fluids
	if not s then
		s = {
			drives = {},        -- unit_number -> { entity, name, capacity, contents = { fluid -> amount }, used }
			interfaces = {},    -- unit_number -> { entity, mode = "import"|"export", fluid, level, status }
			ilist = {},         -- unit numbers of interfaces (round robin)
			icursor = 1,
			gui = {},           -- player_index -> { entity, sig } while a drive GUI is open
		}
		storage.fork_me_fluids = s
	end
	return s
end

local function network_of(entity)
	return entity.surface.find_logistic_network_by_position(entity.position, entity.force)
end
M.network_of = network_of

--- "1234" or "12.3" for the GUI
function M.format(amount)
	if amount == math.floor(amount) then return string.format("%d", amount) end
	return string.format("%.1f", amount)
end
local format = M.format

--------------------------------------------------------------------------------
--- drives
--------------------------------------------------------------------------------

local function drive_record(s, entity)
	local unit = entity.unit_number
	local rec = s.drives[unit]
	if not rec then
		rec = { entity = entity, name = entity.name, capacity = drive_capacity(entity.name) or 0, contents = {}, used = 0 }
		s.drives[unit] = rec
	end
	return rec
end

local function rec_add(rec, name, amount)
	local now = (rec.contents[name] or 0) + amount
	if now < EPS then now = 0 end
	rec.contents[name] = now > 0 and now or nil
	local used = 0
	for _, a in pairs(rec.contents) do used = used + a end
	rec.used = used
end

--- drives standing in `net`, oldest first; records of removed entities are dropped on the way
local function drives_in(s, net)
	local list = {}
	if not net then return list end
	local id = net.network_id
	for unit, rec in pairs(s.drives) do
		local e = rec.entity
		if not e.valid then
			s.drives[unit] = nil
		else
			local n = network_of(e)
			if n and n.network_id == id then list[#list + 1] = rec end
		end
	end
	table.sort(list, function(a, b) return a.entity.unit_number < b.entity.unit_number end)
	return list
end

local function list_totals(list)
	local out = {}
	for _, rec in pairs(list) do
		for name, amount in pairs(rec.contents) do out[name] = (out[name] or 0) + amount end
	end
	return out
end

local function list_capacity(list)
	local total, used = 0, 0
	for _, rec in pairs(list) do
		total = total + rec.capacity
		used = used + rec.used
	end
	return total, used
end

local function list_count(list, name)
	local n = 0
	for _, rec in pairs(list) do n = n + (rec.contents[name] or 0) end
	return n
end

--- store up to `amount` of `name`: drives that already hold the fluid first, then the rest
local function list_insert(list, name, amount)
	if not (amount and amount > 0) then return 0 end
	local left = amount
	for pass = 1, 2 do
		for _, rec in pairs(list) do
			if left <= EPS then break end
			if pass == 2 or rec.contents[name] then
				local room = rec.capacity - rec.used
				if room > 0 then
					local put = math.min(room, left)
					rec_add(rec, name, put)
					left = left - put
				end
			end
		end
	end
	if left < EPS then left = 0 end
	return amount - left
end

local function list_remove(list, name, amount)
	if not (amount and amount > 0) then return 0 end
	local left = amount
	for _, rec in pairs(list) do
		if left <= EPS then break end
		local have = rec.contents[name] or 0
		if have > 0 then
			local take = math.min(have, left)
			rec_add(rec, name, -take)
			left = left - take
		end
	end
	if left < EPS then left = 0 end
	return amount - left
end

--- { fluid -> amount } stored in the network
function M.totals(net) return list_totals(drives_in(state(), net)) end

--- total capacity and used units of the network's fluid drives
function M.capacity(net) return list_capacity(drives_in(state(), net)) end

function M.count(net, name) return list_count(drives_in(state(), net), name) end

--- Store `amount` of `name` in the network. Returns the amount stored (less when the drives are full).
function M.insert(net, name, amount) return list_insert(drives_in(state(), net), name, amount) end

--- Take `amount` of `name` out of the network. Returns the amount taken.
function M.remove(net, name, amount) return list_remove(drives_in(state(), net), name, amount) end

--- drives of the network as plain data (for GUIs and tests)
function M.drives(net)
	local out = {}
	for _, rec in pairs(drives_in(state(), net)) do
		out[#out + 1] = { unit = rec.entity.unit_number, name = rec.name, capacity = rec.capacity, used = rec.used }
	end
	return out
end

--- LocalisedString "1234 Water, 12.3 Steam" for a { fluid -> amount } table
function M.fluid_list(contents, limit)
	local names = {}
	for name in pairs(contents) do names[#names + 1] = name end
	table.sort(names)
	local out = { "" }
	for i, name in ipairs(names) do
		if i > (limit or 8) then out[#out + 1] = ", ..." break end
		local proto = prototypes.fluid[name]
		out[#out + 1] = { "", (i > 1 and ", " or "") .. format(contents[name]) .. " ", proto and proto.localised_name or name }
	end
	return out
end

--- Put the contents of a drive onto its item (the stack the mined drive turned into)
local function pack_drive(s, entity, stack)
	local rec = s.drives[entity.unit_number]
	if not (rec and next(rec.contents)) then return false end
	if not (stack and stack.valid_for_read and stack.name == entity.name and stack.is_item_with_tags) then return false end
	local contents = {}
	for name, amount in pairs(rec.contents) do contents[name] = amount end
	local tags = stack.tags or {}
	tags[TAG] = contents
	stack.tags = tags
	stack.custom_description = { "fork-me-fluids.drive-item-holds", M.fluid_list(contents, 6) }
	rec.contents, rec.used = {}, 0          -- moved, not copied
	return true
end

--- A placed drive: an item that carried fluids gives them to the new entity (capped by its capacity)
local function unpack_drive(s, entity, tags)
	local rec = drive_record(s, entity)
	local stored = tags and tags[TAG]
	if type(stored) == "table" then
		local names = {}
		for name in pairs(stored) do names[#names + 1] = name end
		table.sort(names)
		for _, name in pairs(names) do
			local amount = stored[name]
			if type(name) == "string" and type(amount) == "number" and amount > 0 and prototypes.fluid[name] then
				local room = rec.capacity - rec.used
				if room > 0 then rec_add(rec, name, math.min(room, amount)) end
			end
		end
	end
	return rec
end

--------------------------------------------------------------------------------
--- interfaces
--------------------------------------------------------------------------------

local function register_interface(s, entity)
	local unit = entity.unit_number
	if not s.interfaces[unit] then
		s.interfaces[unit] = { entity = entity, mode = "import", fluid = nil, level = interface_volume(), status = "ok" }
		s.ilist[#s.ilist + 1] = unit
	end
	return s.interfaces[unit]
end

local function drop_interface(s, unit)
	s.interfaces[unit] = nil
	for i = #s.ilist, 1, -1 do
		if s.ilist[i] == unit then table.remove(s.ilist, i) end
	end
end

--- Move what the tank holds into the network (as much as fits); returns the amount moved.
--- Pipes and tanks connected without a pump share one fluid segment with the interface, and the
--- whole segment is taken (the interface's own box would only hold its share of it).
local function tank_to_network(e, held, list)
	local total, used = list_capacity(list)
	if total <= 0 then return 0, "no-drive" end
	local room = total - used
	if room <= EPS then return 0, "full" end
	local fb = e.fluidbox
	local segment = fb.get_fluid_segment_contents(1)
	local available = math.max(held.amount, (segment and segment[held.name] or 0) + 1)   -- segment counts are rounded
	local removed = e.remove_fluid{ name = held.name, amount = math.min(available, room) }
	if removed <= 0 then return 0, "ok" end
	local stored = list_insert(list, held.name, removed)
	if stored < removed then               -- cannot happen (room was checked), but never lose fluid
		e.insert_fluid{ name = held.name, amount = removed - stored, temperature = held.temperature }
	end
	return stored, "ok"
end

--- one import or export pass of an interface; `drives_of(net)` gives the drive list of a network
local function interface_step(rec, drives_of)
	local e = rec.entity
	local net = network_of(e)
	if not net then rec.status = "no-network" return end
	local list = drives_of(net)
	local held = e.fluidbox[1]
	if held and held.amount <= EPS then held = nil end
	if rec.mode == "import" then
		if not held then rec.status = "empty" return end
		local _, status = tank_to_network(e, held, list)
		rec.status = status
		return
	end
	--- export
	local fluid = rec.fluid
	if not fluid then rec.status = "no-fluid" return end
	if held and held.name ~= fluid then      -- another fluid in the tank: into the network first
		tank_to_network(e, held, list)
		held = e.fluidbox[1]
		if held and held.amount <= EPS then held = nil end
		if held and held.name ~= fluid then rec.status = "blocked" return end
	end
	local want = rec.level - (held and held.amount or 0)
	if want <= EPS then rec.status = "ok" return end
	local avail = list_count(list, fluid)
	if avail <= EPS then
		rec.status = list_capacity(list) > 0 and "empty-network" or "no-drive"
		return
	end
	local inserted = e.insert_fluid{ name = fluid, amount = math.min(want, avail) }
	if inserted > 0 then list_remove(list, fluid, inserted) end
	rec.status = "ok"
end

--------------------------------------------------------------------------------
--- GUIs
--------------------------------------------------------------------------------

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

--- drive GUI (screen frame, opened with the "open GUI" key on a drive)
local function drive_gui_refresh(player, g)
	local frame = player.gui.screen[DRIVE_FRAME]
	local entity = g.entity
	if not (frame and entity.valid) then return false end
	local s = state()
	local rec = s.drives[entity.unit_number] or drive_record(s, entity)
	local net = network_of(entity)
	local names, sig = {}, {}
	for name, amount in pairs(rec.contents) do names[#names + 1] = name end
	table.sort(names)
	for i, name in ipairs(names) do sig[i] = name .. "=" .. rec.contents[name] end
	sig = table.concat(sig, ",") .. "|" .. (net and net.network_id or "-")
	if g.sig == sig then return true end
	g.sig = sig
	find(frame, "fork_mefd_used").caption = { "fork-me-fluids.drive-used", format(rec.used), format(rec.capacity) }
	local status = find(frame, "fork_mefd_status")
	status.caption = net and "" or { "fork-me-fluids.status-no-network" }
	status.visible = net == nil
	local grid = find(frame, "fork_mefd_grid")
	grid.clear()
	for _, name in ipairs(names) do
		local proto = prototypes.fluid[name]
		if proto then
			grid.add{ type = "sprite", sprite = "fluid/" .. name }
			local label = grid.add{ type = "label", caption = proto.localised_name }
			label.style.minimal_width = 160
			grid.add{ type = "label", caption = format(rec.contents[name]) }
		end
	end
	if #names == 0 then
		grid.add{ type = "label", caption = { "fork-me-fluids.drive-empty" } }
	end
	return true
end

local function close_drive_gui(player)
	local frame = player.gui.screen[DRIVE_FRAME]
	if frame then frame.destroy() end
	state().gui[player.index] = nil
end

local function open_drive(player, entity)
	local s = state()
	local g = s.gui[player.index]
	local frame = player.gui.screen[DRIVE_FRAME]
	if g and frame and g.entity == entity then
		player.opened = frame
		return
	end
	close_drive_gui(player)
	frame = player.gui.screen.add{ type = "frame", name = DRIVE_FRAME, direction = "vertical", caption = entity.localised_name }
	frame.auto_center = true
	frame.add{ type = "label", name = "fork_mefd_used" }
	local status = frame.add{ type = "label", name = "fork_mefd_status" }
	status.style.single_line = false
	status.style.maximal_width = 320
	local scroll = frame.add{ type = "scroll-pane", horizontal_scroll_policy = "never" }
	scroll.style.maximal_height = 300
	scroll.style.minimal_width = 320
	scroll.add{ type = "table", name = "fork_mefd_grid", column_count = 3 }
	s.gui[player.index] = { entity = entity }
	player.opened = frame
	drive_gui_refresh(player, s.gui[player.index])
end

--- interface panel (relative to the storage tank GUI, only for the fluid interface)
local function interface_gui_refresh(frame, rec)
	local e = rec.entity
	if not (frame and frame.valid and e.valid) then return end
	local net = network_of(e)
	local status = find(frame, "fork_mef_status")
	status.caption = { "fork-me-fluids.status-" .. (rec.status or "ok") }
	local line = find(frame, "fork_mef_network")
	if net then
		local list = drives_in(state(), net)
		local total, used = list_capacity(list)
		local held = rec.fluid and list_count(list, rec.fluid) or nil
		if held then
			line.caption = { "fork-me-fluids.network-line-fluid", format(used), format(total), format(held), prototypes.fluid[rec.fluid].localised_name }
		else
			line.caption = { "fork-me-fluids.network-line", format(used), format(total) }
		end
	else
		line.caption = { "fork-me-fluids.status-no-network" }
	end
	local fluid_row = find(frame, "fork_mef_fluid_row")
	fluid_row.visible = rec.mode == "export"
	find(frame, "fork_mef_level_row").visible = rec.mode == "export"
	--- another player (or a script) may have changed the settings: mirror the record
	local switch = find(frame, "fork_mef_mode")
	local want = rec.mode == "export" and "right" or "left"
	if switch.switch_state ~= want then switch.switch_state = want end
	local button = find(frame, "fork_mef_fluid")
	if button.elem_value ~= rec.fluid then button.elem_value = rec.fluid end
	local level = find(frame, "fork_mef_level")
	if tonumber(level.text) ~= rec.level then level.text = format(rec.level) end
end

local function open_interface_gui(player, entity)
	local s = state()
	local rec = s.interfaces[entity.unit_number] or register_interface(s, entity)
	local rel = player.gui.relative
	if rel[IFACE_FRAME] then rel[IFACE_FRAME].destroy() end
	local frame = rel.add{
		type = "frame", name = IFACE_FRAME, direction = "vertical", caption = { "fork-me-fluids.interface-title" },
		anchor = { gui = defines.relative_gui_type.storage_tank_gui, position = defines.relative_gui_position.right, names = { entity.name } },
		tags = { unit = entity.unit_number },
	}
	local help = frame.add{ type = "label", caption = { "fork-me-fluids.interface-help" } }
	help.style.single_line = false
	help.style.maximal_width = 300
	frame.add{
		type = "switch", name = "fork_mef_mode",
		left_label_caption = { "fork-me-fluids.mode-import" }, left_label_tooltip = { "fork-me-fluids.mode-import-tooltip" },
		right_label_caption = { "fork-me-fluids.mode-export" }, right_label_tooltip = { "fork-me-fluids.mode-export-tooltip" },
		switch_state = rec.mode == "export" and "right" or "left",
	}
	local fluid_row = frame.add{ type = "flow", name = "fork_mef_fluid_row", direction = "horizontal" }
	fluid_row.style.vertical_align = "center"
	fluid_row.add{ type = "label", caption = { "fork-me-fluids.fluid" } }
	fluid_row.add{ type = "choose-elem-button", name = "fork_mef_fluid", elem_type = "fluid", fluid = rec.fluid }
	local level_row = frame.add{ type = "flow", name = "fork_mef_level_row", direction = "horizontal" }
	level_row.style.vertical_align = "center"
	level_row.add{ type = "label", caption = { "fork-me-fluids.level", format(interface_volume()) } }
	local level = level_row.add{ type = "textfield", name = "fork_mef_level", text = format(rec.level), numeric = true,
		allow_decimal = false, allow_negative = false, lose_focus_on_confirm = true }
	level.style.width = 80
	local status = frame.add{ type = "label", name = "fork_mef_status" }
	status.style.single_line = false
	status.style.maximal_width = 300
	local line = frame.add{ type = "label", name = "fork_mef_network" }
	line.style.single_line = false
	line.style.maximal_width = 300
	interface_gui_refresh(frame, rec)
end

local function close_interface_gui(player)
	local frame = player.gui.relative[IFACE_FRAME]
	if frame then frame.destroy() end
end

--- the interface record and frame an element of the panel belongs to
local function interface_of_element(el)
	local frame = el
	while frame and frame.valid and frame.name ~= IFACE_FRAME do frame = frame.parent end
	if not (frame and frame.valid) then return nil end
	local unit = frame.tags and frame.tags.unit
	local rec = unit and state().interfaces[unit]
	if not (rec and rec.entity.valid) then return nil end
	return rec, frame
end

local function set_level(rec, text)
	local n = tonumber(text)
	if not n then return end
	rec.level = math.max(0, math.min(interface_volume(), math.floor(n)))
end

--- Set an interface from a script: mode "import"/"export", fluid name (export), level (export)
function M.set_interface(entity, mode, fluid, level)
	if not (entity and entity.valid and entity.name == interface_name()) then return false end
	local rec = register_interface(state(), entity)
	if mode == "import" or mode == "export" then rec.mode = mode end
	if fluid ~= nil then rec.fluid = prototypes.fluid[fluid] and fluid or nil end
	if level ~= nil then set_level(rec, level) end
	return true
end

function M.get_interface(entity)
	local rec = entity and entity.valid and state().interfaces[entity.unit_number]
	if not rec then return nil end
	return { mode = rec.mode, fluid = rec.fluid, level = rec.level, status = rec.status }
end

--------------------------------------------------------------------------------
--- step
--------------------------------------------------------------------------------

local function on_step()
	local s = storage.fork_me_fluids
	if not s then return end
	local n = #s.ilist
	if n > 0 then
		local cache = {}                                    -- network id -> drive list, once per step
		local function drives_of(net)
			local list = cache[net.network_id]
			if not list then
				list = drives_in(s, net)
				cache[net.network_id] = list
			end
			return list
		end
		for _ = 1, math.min(INTERFACES_PER_STEP, n) do
			if s.icursor > #s.ilist then s.icursor = 1 end
			local unit = s.ilist[s.icursor]
			local rec = s.interfaces[unit]
			if rec and rec.entity.valid then
				interface_step(rec, drives_of)
				s.icursor = s.icursor + 1
			else
				drop_interface(s, unit)
			end
			if #s.ilist == 0 then break end
		end
	end
	if next(s.gui) then
		for index, g in pairs(s.gui) do
			local player = game.get_player(index)
			if not (player and player.valid) then
				s.gui[index] = nil
			else
				local frame = player.gui.screen[DRIVE_FRAME]
				--- dying or disconnecting closes the GUI without an event: the frame must not linger
				if not (frame and g.entity.valid and player.opened == frame and player.can_reach_entity(g.entity)) then
					close_drive_gui(player)
				else
					drive_gui_refresh(player, g)
				end
			end
		end
	end
	for _, player in pairs(game.connected_players) do
		local frame = player.gui.relative[IFACE_FRAME]
		if frame then
			local rec = interface_of_element(frame)
			if rec then interface_gui_refresh(frame, rec) else frame.destroy() end
		end
	end
end

script.on_nth_tick(STEP_TICKS, on_step)

--------------------------------------------------------------------------------
--- events (build/mine from control.lua, GUI from the terminal module and here)
--------------------------------------------------------------------------------

--- The tags of the drive item a build event consumed: `event.tags` (ghost tags, script_raised_revive),
--- the robot's `event.stack`, or the player's `event.consumed_items`.
function M.tags_from_event(event)
	if type(event.tags) == "table" and event.tags[TAG] then return event.tags end
	local stack = event.stack
	if stack and stack.valid and stack.valid_for_read and stack.is_item_with_tags then
		local tags = stack.tags
		if tags and tags[TAG] then return tags end
	end
	local consumed = event.consumed_items
	if consumed and consumed.valid then
		for i = 1, #consumed do
			local st = consumed[i]
			if st.valid_for_read and st.is_item_with_tags then
				local tags = st.tags
				if tags and tags[TAG] then return tags end
			end
		end
	end
	return nil
end

--- `tags`: the item tags of the placed drive item (see tags_from_event)
function M.on_built(entity, tags)
	if not (entity and entity.valid) then return end
	local s = state()
	if drive_capacity(entity.name) then
		unpack_drive(s, entity, tags)
	elseif entity.name == interface_name() then
		register_interface(s, entity)
	end
end

--- mined by a player, a robot or a space platform: a drive's fluids go onto the item in `buffer`,
--- an interface's content goes back into the network (as far as the drives have room)
function M.on_mined(entity, buffer)
	if not (entity and entity.valid) then return end
	local s = state()
	local unit = entity.unit_number
	if s.drives[unit] then
		if buffer and buffer.valid then
			for i = 1, #buffer do
				local stack = buffer[i]
				if stack.valid_for_read and stack.name == entity.name then
					pack_drive(s, entity, stack)
					break
				end
			end
		end
		s.drives[unit] = nil
	elseif s.interfaces[unit] then
		local held = entity.fluidbox[1]
		local net = held and held.amount > EPS and network_of(entity)
		if net then tank_to_network(entity, held, drives_in(s, net)) end
		drop_interface(s, unit)
	else
		for _, hook in pairs(M.mined_hooks) do hook(entity) end
	end
end

--- destroyed or removed without mining: the fluids are lost
function M.on_removed(entity)
	if not (entity and entity.valid) then return end
	local s = state()
	local unit = entity.unit_number
	if s.drives[unit] then
		s.drives[unit] = nil
	elseif s.interfaces[unit] then
		drop_interface(s, unit)
	end
end

--- the "open GUI" key on a selected entity (routed from the terminal's custom input handler)
function M.on_open_input(player, entity)
	if not (entity and entity.valid and drive_capacity(entity.name)) then return false end
	if not player.can_reach_entity(entity) then return true end
	open_drive(player, entity)
	return true
end

function M.on_gui_opened(event)
	if event.gui_type == defines.gui_type.entity and event.entity and event.entity.valid
		and event.entity.name == interface_name() then
		open_interface_gui(game.get_player(event.player_index), event.entity)
		return true
	end
	return false
end

function M.on_gui_closed(event)
	local player = game.get_player(event.player_index)
	if not player then return false end
	if event.element and event.element.valid and event.element.name == DRIVE_FRAME then
		close_drive_gui(player)
		return true
	end
	if event.gui_type == defines.gui_type.entity and event.entity and event.entity.valid
		and event.entity.name == interface_name() then
		close_interface_gui(player)
		return true
	end
	return false
end

function M.on_gui_text_changed(event)
	local el = event.element
	if not (el and el.valid and el.name == "fork_mef_level") then return false end
	local rec, frame = interface_of_element(el)
	if rec then
		set_level(rec, el.text)
		interface_gui_refresh(frame, rec)
	end
	return true
end

function M.on_player_removed(index)
	state().gui[index] = nil
end

script.on_event(defines.events.on_gui_switch_state_changed, function(event)
	local el = event.element
	if not (el and el.valid and el.name == "fork_mef_mode") then return end
	local rec, frame = interface_of_element(el)
	if not rec then return end
	rec.mode = el.switch_state == "right" and "export" or "import"
	rec.status = "ok"
	interface_gui_refresh(frame, rec)
end)

script.on_event(defines.events.on_gui_elem_changed, function(event)
	local el = event.element
	if not (el and el.valid and el.name == "fork_mef_fluid") then return end
	local rec, frame = interface_of_element(el)
	if not rec then return end
	local value = el.elem_value
	rec.fluid = type(value) == "string" and prototypes.fluid[value] and value or nil
	rec.status = "ok"
	interface_gui_refresh(frame, rec)
end)

script.on_event(defines.events.on_gui_confirmed, function(event)
	local el = event.element
	if not (el and el.valid and el.name == "fork_mef_level") then return end
	local rec, frame = interface_of_element(el)
	if not rec then return end
	set_level(rec, el.text)
	el.text = format(rec.level)
	interface_gui_refresh(frame, rec)
end)

--- (a filter can only be given when one event is registered at a time)
local ENTITY_FILTER = { { filter = "type", type = "simple-entity-with-force" }, { filter = "type", type = "storage-tank" } }
local MINED_FILTER = { { filter = "type", type = "simple-entity-with-force" }, { filter = "type", type = "storage-tank" },
	{ filter = "type", type = "assembling-machine" }, { filter = "type", type = "furnace" } }
for _, name in pairs({ "on_player_mined_entity", "on_robot_mined_entity", "on_space_platform_mined_entity" }) do
	script.on_event(defines.events[name], function(event) M.on_mined(event.entity, event.buffer) end, MINED_FILTER)
end
for _, name in pairs({ "on_entity_died", "script_raised_destroy" }) do
	script.on_event(defines.events[name], function(event) M.on_removed(event.entity) end, ENTITY_FILTER)
end

--- Rebuild the registries from the world. Drive contents are kept (matched by unit number),
--- interface settings too; open GUIs are closed.
function M.on_configuration_changed()
	local s = state()
	local names = {}
	for name in pairs(mod_data().drives) do names[#names + 1] = name end
	names[#names + 1] = interface_name()
	local drives, interfaces = {}, {}
	for _, surface in pairs(game.surfaces) do
		for _, e in pairs(surface.find_entities_filtered{ name = names }) do
			local unit = e.unit_number
			if drive_capacity(e.name) then
				local old = s.drives[unit]
				local rec = { entity = e, name = e.name, capacity = drive_capacity(e.name), contents = {}, used = 0 }
				if old and old.contents then
					local list = {}
					for n in pairs(old.contents) do list[#list + 1] = n end
					table.sort(list)
					for _, n in pairs(list) do
						local a = old.contents[n]
						if prototypes.fluid[n] and type(a) == "number" and a > 0 then
							rec_add(rec, n, math.min(a, rec.capacity - rec.used))
						end
					end
				end
				drives[unit] = rec
			else
				local old = s.interfaces[unit]
				interfaces[unit] = {
					entity = e,
					mode = old and old.mode == "export" and "export" or "import",
					fluid = old and old.fluid and prototypes.fluid[old.fluid] and old.fluid or nil,
					level = old and old.level or interface_volume(),
					status = "ok",
				}
				if old then
					local keep = interfaces[unit]
					keep.level = math.max(0, math.min(interface_volume(), keep.level))
				end
			end
		end
	end
	s.drives, s.interfaces, s.ilist, s.icursor = drives, interfaces, {}, 1
	for unit in pairs(interfaces) do s.ilist[#s.ilist + 1] = unit end
	table.sort(s.ilist)
	for index in pairs(s.gui) do
		local player = game.get_player(index)
		if player then close_drive_gui(player) else s.gui[index] = nil end
	end
	for _, player in pairs(game.players) do
		close_interface_gui(player)
		local opened = player.opened
		if opened and player.opened_gui_type == defines.gui_type.entity and opened.valid and opened.name == interface_name() then
			player.opened = nil
		end
	end
end

--- Other mods and the devcheck runtime test use the same code paths
remote.add_interface("gregtorio-me-fluids", {
	count = function(entity, fluid)
		local net = network_of(entity)
		return net and M.count(net, fluid) or 0
	end,
	totals = function(entity)
		local net = network_of(entity)
		return net and M.totals(net) or {}
	end,
	capacity = function(entity)
		local net = network_of(entity)
		if not net then return 0, 0 end
		return M.capacity(net)
	end,
	insert = function(entity, fluid, amount)
		local net = network_of(entity)
		return net and M.insert(net, fluid, amount) or 0
	end,
	remove = function(entity, fluid, amount)
		local net = network_of(entity)
		return net and M.remove(net, fluid, amount) or 0
	end,
	drives = function(entity)
		local net = network_of(entity)
		return net and M.drives(net) or {}
	end,
	drive = function(entity)
		local rec = entity and entity.valid and state().drives[entity.unit_number]
		if not rec then return nil end
		local contents = {}
		for n, a in pairs(rec.contents) do contents[n] = a end
		return { name = rec.name, capacity = rec.capacity, used = rec.used, contents = contents }
	end,
	set_interface = function(entity, mode, fluid, level) return M.set_interface(entity, mode, fluid, level) end,
	get_interface = function(entity) return M.get_interface(entity) end,
	--- what mining a drive does: the contents go onto `stack` (an item stack of the same drive item)
	pack_drive = function(entity, stack) return pack_drive(state(), entity, stack) end,
	--- what placing a drive item does: `tags` are the item's tags
	unpack_drive = function(entity, tags) M.on_built(entity, tags) end,
})

return M
