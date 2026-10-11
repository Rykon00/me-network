--------------------------------------------------------------------------------
--- ME CELL WORKBENCH (me-network issue #17, part 3; prototypes/cards.lua, docs/ME-REWORK.md "The ME Cell Workbench",
--- guide: docs/AE2.md "ME Cell Workbench")
---   * AE2's Cell Workbench: one storage cell, its partition (items with quality, or fluids) and its card slots (4 for
---     an item cell, 3 for a fluid cell: AE2's numbers), "From contents", "Clear" and the copy mode ("keep the
---     partition when the cell is taken out": it stays in the workbench and goes onto the next cell whose partition
---     is empty). AE2's workbench needs neither the network nor power (its block entity has no grid node): this one is
---     no ME member and needs no cable.
---   * Issue #28 (docs/ME-REWORK.md "Windows with the player's inventory"): the workbench's script inventory of 5
---     slots (rec.inv), whose slots its window shows next to the player's inventory: slot 1 the cell, slots 2 to 5 its
---     cards. While a cell lies in the workbench its cards are those items and not in its tags (never both). A cell that
---     arrives gives its tag cards to the slots; a cell taken out by a click gets them into its tags before it moves.
---     cell_click, card_click and shift_in refuse a wrong item before it moves. sync() is the backstop (the migration,
---     the removal): what may not be there goes back, a cell that left is looked for by its item_number.
---   * The cell stays an item, and every change is written into its tags at once (N.cell_stack), with its contents
---     untouched.
---   * Issue #37: the workbench's partition (rec.config) is shown and set without a cell too. It holds item keys and
---     fluid keys (kept_list: the items, then the fluids); a cell that arrives without a partition takes the keys of its
---     kind, also without the copy mode (set by hand for it), and a cell in the workbench shows and changes the keys of
---     its kind only (remember), the other kind's stay. Without the copy mode all of it is forgotten when a cell leaves.
---   * Mined: the cards into the cell's tags, the cell into the buffer; destroyed or removed by a script: spilled; a
---     workbench removed without an event: the sweep (from the network's slow step) spills it at the position kept in
---     the record.
--- State: storage.fork_me_workbench = { recs = { [unit] = { entity, inv, keep, config (a list of keys), where, cell
--- (item_number of the cell in slot 1) } }, list, cursor }.
--------------------------------------------------------------------------------

local N = require("scripts.fork-me-network")
local G = require("scripts.fork-me-gui")

local M = {}

local NAME = "me-cell-workbench"
local SWEEP_PER_STEP = 20           -- workbenches checked for a vanished entity per slow step
local SLOTS = 5                     -- the cell and the most card slots of a cell (an item cell's 4)

local function state()
	local s = storage.fork_me_workbench
	if not s then
		s = { recs = {}, list = {}, cursor = 1 }
		storage.fork_me_workbench = s
	end
	return s
end

local function is_bench(entity) return entity and entity.valid and entity.name == NAME end

--- the card rules of a cell (item or fluid cell)
local function rules_of(spec)
	local r = N.card_rules()
	return spec.kind == "fluid" and r.fluid_cell or r.item_cell
end

local function is_cell(stack) return stack and stack.valid_for_read and N.cell_spec(stack.name) ~= nil end

--- issue #37: the most kinds an item cell and a fluid cell take (the slots of the workbench's partition without a
--- cell), as the two stand-in specs N.clean_partition checks a list against
local limits
local function kept_limits()
	if not limits then
		local items, fluids = 0, 0
		for _, spec in pairs(N.cell_specs()) do
			if spec.kind == "fluid" then fluids = math.max(fluids, spec.types or 0) else items = math.max(items, spec.types or 0) end
		end
		limits = { item = { types = items }, fluid = { kind = "fluid", types = fluids } }
	end
	return limits
end

--- the workbench's partition in the order its window shows it: the item keys, then the fluid keys, each sorted.
--- Returns the list and the number of item keys.
local function kept_list(config)
	local items, fluids = {}, {}
	for _, key in ipairs(config or {}) do
		if N.is_fluid_key(key) then fluids[#fluids + 1] = key else items[#items + 1] = key end
	end
	table.sort(items)
	table.sort(fluids)
	local n = #items
	for i = 1, #fluids do items[n + i] = fluids[i] end
	return items, n
end

--- a list of keys as the workbench keeps it: known items and fluids, each once, at most what a cell of the kind
--- takes; nil when nothing is left
local function clean_kept(list)
	local lim = kept_limits()
	local out = {}
	for _, spec in ipairs({ lim.item, lim.fluid }) do
		for key in pairs(N.clean_partition(spec, list) or {}) do out[#out + 1] = key end
	end
	out = kept_list(out)
	return #out > 0 and out or nil
end

--- the workbench's partition after the partition of the cell in it changed: the cell's keys, and the kept keys of
--- the other kind (an item cell does not touch the fluids kept for a fluid cell)
local function remember(rec, cell)
	local fluid = N.cell_spec(cell.name).kind == "fluid"
	local out = N.cell_keys(cell)
	for _, key in ipairs(rec.config or {}) do
		if N.is_fluid_key(key) ~= fluid then out[#out + 1] = key end
	end
	rec.config = clean_kept(out)
end

--- the cell's record written back into its stack (tags, description); the stack gets a new item_number
local function write(rec, stack, cell)
	stack.set_stack(N.cell_stack(cell))
	if rec then rec.cell = stack.item_number end
end

--- the card items in slots 2 to 5, as a list of names (slot order)
local function slot_cards(inv)
	local out = {}
	for slot = 2, #inv do
		local stack = inv[slot]
		if stack.valid_for_read and N.card_kind(stack.name) then out[#out + 1] = stack.name end
	end
	return out
end

--- The tag cards of the cell in slot 1 become the items of the card slots (an empty slot each; a card that finds none
--- goes to `back`), its tags lose them.
local function unpack_cards(rec, inv, back)
	local stack = inv[1]
	local cell = N.cell_from_stack(stack)
	if not (cell.cards and #cell.cards > 0) then
		rec.cell = stack.item_number
		return
	end
	for _, name in ipairs(cell.cards) do
		local free
		for slot = 2, #inv do
			if not inv[slot].valid_for_read then free = slot break end
		end
		if free then
			inv[free].set_stack{ name = name, count = 1 }
		else
			local tmp = game.create_inventory(1)
			tmp[1].set_stack{ name = name, count = 1 }
			G.give_back(back, tmp[1], rec.entity)
			tmp.destroy()
		end
	end
	cell.cards = nil
	N.apply_cell_cards(cell)
	write(rec, stack, cell)
end

--- The card items of the slots go into the tags of `stack` (the cell that leaves or left): the ones its kind takes,
--- within the limits and its slots; those slots are emptied. A card the cell cannot take stays.
local function pack_cards(inv, stack)
	local cell = N.cell_from_stack(stack)
	local r = rules_of(N.cell_spec(cell.name))
	local list, n = {}, {}
	for slot = 2, #inv do
		local s = inv[slot]
		local kind = s.valid_for_read and N.card_kind(s.name)
		local limit = kind and r.limits[kind]
		if limit and (n[kind] or 0) < limit and #list < r.slots then
			n[kind] = (n[kind] or 0) + 1
			list[#list + 1] = s.name
			if s.count > 1 then s.count = s.count - 1 else s.clear() end
		end
	end
	if #list == 0 then return end
	cell.cards = list
	N.apply_cell_cards(cell)
	stack.set_stack(N.cell_stack(cell))
end

--- the workbench's inventory; a workbench of 0.3.0 had one slot without a title (the cell, its cards in its tags): it is
--- replaced here, the cell moved over and its tag cards become the card slots' items
local function inv_of(rec)
	local inv = rec.inv
	if inv and inv.valid and #inv == SLOTS then return inv end
	local e = rec.entity
	local new = game.create_inventory(SLOTS, e and e.valid and e.localised_name or { "entity-name." .. NAME })
	if inv and inv.valid then
		for i = 1, math.min(#inv, SLOTS) do new[i].transfer_stack(inv[i]) end
		if inv.is_empty() then inv.destroy() end
	end
	rec.inv = new
	if is_cell(new[1]) then unpack_cards(rec, new, nil) end
	return new
end

local function register(entity)
	local s = state()
	local unit = entity.unit_number
	local rec = s.recs[unit]
	if not rec then
		rec = { entity = entity, keep = false,
			where = { surface = entity.surface.index, x = entity.position.x, y = entity.position.y } }
		s.recs[unit] = rec
		s.list[#s.list + 1] = unit
	end
	inv_of(rec)
	return rec
end

local function rec_of(entity)
	if not is_bench(entity) then return nil end
	return register(entity)
end

--- the cell in the workbench: its stack (valid for read) and its record (N.cell_from_tags), or nil
local function cell_of(rec)
	local inv = inv_of(rec)
	local stack = inv[1]
	if not is_cell(stack) then return nil end
	return stack, N.cell_from_stack(stack)
end

--- the cell left: without the copy mode the workbench forgets the partition (AE2's CLEAR_ON_REMOVE)
local function taken(rec)
	rec.cell = nil
	if not rec.keep then rec.config = nil end
end

--- a cell arrived in slot 1 (AE2: a cell with a partition shows it; one without gets the workbench's: the keys of its
--- kind, kept by the copy mode or set by hand without a cell, issue #37); its tag cards become the card slots' items
local function arrived(rec, inv, back)
	local stack = inv[1]
	local cell = N.cell_from_stack(stack)
	if #N.cell_keys(cell) > 0 then
		remember(rec, cell)
	elseif rec.config and N.clean_partition(N.cell_spec(cell.name), rec.config) then
		N.set_cell_keys(cell, rec.config)
		write(rec, stack, cell)
	end
	unpack_cards(rec, inv, back)
end

--- the cell leaves by script (taken by a click, mined, destroyed, vanished): the card slots' cards into its tags first
local function release(rec, inv)
	if is_cell(inv[1]) then pack_cards(inv, inv[1]) end
	taken(rec)
end

--- the stack with item_number `number` in `places` (LuaItemStacks and LuaInventories), or nil
local function find_stack(places, number)
	if not number then return nil end
	for _, place in ipairs(places or {}) do
		if place.valid then
			if place.object_name == "LuaItemStack" then
				if place.valid_for_read and place.item_number == number then return place end
			elseif place.object_name == "LuaInventory" then
				for i = 1, #place do
					local s = place[i]
					if s.valid_for_read and s.item_number == number then return s end
				end
			end
		end
	end
	return nil
end

local function signature(rec, inv)
	local out = { tostring(rec.cell) }
	for i = 1, #inv do
		local s = inv[i]
		out[#out + 1] = s.valid_for_read and (s.name .. "x" .. s.count) or "-"
	end
	return table.concat(out, ",")
end

--- Issue #28: the slots checked (after every click, the migration, the removal). `back`: where what may not be there
--- goes (G.give_back: the player, a LuaInventory, nil for the ground); `places`: where a cell that left is looked for
--- (the cursors and main inventories of the window's players). Exactly one cell, in slot 1 (the one that was there is
--- kept, another goes back); a cell that left gets the card slots' cards into its tags when it is found (else they stay);
--- a cell that arrived gives its tag cards to the slots and takes the kept partition; the card slots hold one card each
--- that the cell takes (kind, limit, its number of slots), the rest goes back; no cell: every card goes back.
--- Returns true when something changed.
function M.sync(rec, back, places)
	local inv = inv_of(rec)
	local before = rec.sig or signature(rec, inv)
	--- the cell: the one with the kept item_number, else the first one; it goes into slot 1
	local pick
	for i = 1, #inv do
		if is_cell(inv[i]) and (not pick or (inv[i].item_number == rec.cell and inv[pick].item_number ~= rec.cell)) then pick = i end
	end
	if pick and pick ~= 1 then inv[1].swap_stack(inv[pick]) end
	local number = pick and inv[1].item_number
	if rec.cell and number ~= rec.cell then
		local left = find_stack(places, rec.cell)
		if left and is_cell(left) then pack_cards(inv, left) end
		taken(rec)
	end
	for i = 2, #inv do
		if is_cell(inv[i]) then G.give_back(back, inv[i], rec.entity) end   -- a second cell
	end
	if not is_cell(inv[1]) and inv[1].valid_for_read then
		--- a card or another item in the cell slot: a card moves to a card slot below (when a cell is there)
		local free
		for i = 2, #inv do if not inv[i].valid_for_read then free = i break end end
		if free and N.card_kind(inv[1].name) then inv[free].transfer_stack(inv[1]) else G.give_back(back, inv[1], rec.entity) end
	end
	if is_cell(inv[1]) and inv[1].item_number ~= rec.cell then arrived(rec, inv, back) end
	--- the card slots
	local stack = inv[1]
	local spec = is_cell(stack) and N.cell_spec(stack.name)
	local r = spec and rules_of(spec)
	local counts, kept = {}, {}
	local function take(name)
		local kind = N.card_kind(name)
		local limit = r and kind and r.limits[kind]
		if not limit or (counts[kind] or 0) >= limit then return false end
		counts[kind] = (counts[kind] or 0) + 1
		return true
	end
	local last = r and (1 + r.slots) or 1
	for i = 2, last do
		if inv[i].valid_for_read and take(inv[i].name) then kept[i] = true end
	end
	for i = 2, #inv do
		local s = inv[i]
		if s.valid_for_read then
			local extra = kept[i] and s.count - 1 or s.count
			while extra > 0 do
				local free
				if N.card_kind(s.name) then
					for j = 2, last do if not inv[j].valid_for_read then free = j break end end
				end
				if free and take(s.name) then
					inv[free].transfer_stack(s, 1)
					kept[free] = true
					extra = extra - 1
				else
					G.give_back(back, s, rec.entity, extra)
					extra = 0
				end
			end
		end
	end
	rec.sig = signature(rec, inv)
	return rec.sig ~= before
end

--------------------------------------------------------------------------------
--- the window's functions (scripts/fork-me-windows.lua) and the runtime test (remote below)
--------------------------------------------------------------------------------

--- the workbench's inventory (its window shows it)
function M.inventory(entity)
	local rec = rec_of(entity)
	return rec and inv_of(rec) or nil
end

--- sync() of a workbench (`back`, `places` as there)
function M.sync_entity(entity, back, places)
	local rec = rec_of(entity)
	return rec ~= nil and M.sync(rec, back, places)
end

--- A click on the cell slot: a cell in the cursor goes in (a cell there is swapped into the cursor, with its cards;
--- anything else is refused before it moves); with an empty cursor the cell goes into the cursor (`shift`: into
--- `inventory`), with its cards. Returns the reason of a refusal.
function M.cell_click(entity, cursor, inventory, shift)
	local rec = rec_of(entity)
	if not rec then return "no-workbench" end
	local inv = inv_of(rec)
	local slot = inv[1]
	if cursor and cursor.valid_for_read then
		if not N.cell_spec(cursor.name) then return "not-a-cell" end
		if slot.valid_for_read then
			release(rec, inv)
			local held = game.create_inventory(1)
			held[1].transfer_stack(cursor)
			cursor.transfer_stack(slot)
			slot.transfer_stack(held[1])
			held.destroy()
		else
			slot.transfer_stack(cursor)
		end
		M.sync(rec, inventory, { cursor })
		return nil
	end
	if not slot.valid_for_read then return nil end
	if shift and not (inventory and inventory.valid) then return "no-inventory" end   -- (nothing moved: the cell stays)
	release(rec, inv)
	if shift then
		if inventory.insert(slot) < 1 then
			M.sync(rec, inventory, {})                     -- (back: the cards return to the slots)
			return "inventory-full"
		end
		slot.clear()
	elseif not (cursor and cursor.transfer_stack(slot)) then
		M.sync(rec, inventory, {})
		return "inventory-full"
	end
	M.sync(rec, inventory, {})
	return nil, shift and "out" or nil
end

--- the partition button `index`: `key` (nil: remove) replaces the key at that place of the list. Without a cell
--- (issue #37) the list is the workbench's own (kept_list: items, then fluids), for the next cell without a partition.
function M.set_partition_slot(entity, index, key)
	local rec = rec_of(entity)
	if not rec or type(index) ~= "number" or index < 1 then return false end
	local stack, cell = cell_of(rec)
	if not stack then
		local list = kept_list(rec.config)
		local out, seen = {}, {}
		for i = 1, math.max(#list, index) do
			local k
			if i == index then k = key else k = list[i] end
			if type(k) == "string" and not seen[k] then
				seen[k] = true
				out[#out + 1] = k
			end
		end
		rec.config = clean_kept(out)
		return true
	end
	local list = N.cell_keys(cell)
	local out, seen = {}, {}
	for i = 1, math.max(#list, index) do
		local k
		if i == index then k = key else k = list[i] end
		if k and not seen[k] then
			seen[k] = true
			out[#out + 1] = k
		end
	end
	N.set_cell_keys(cell, out)
	write(rec, stack, cell)
	remember(rec, cell)
	return true
end

--- AE2's "partition storage": the partition becomes what the cell holds (nothing without a cell)
function M.from_contents(entity)
	local rec = rec_of(entity)
	local stack, cell
	if rec then stack, cell = cell_of(rec) end
	if not stack then return false end
	local keys = {}
	for key in pairs(cell.items) do if not key:find("#", 1, true) then keys[#keys + 1] = key end end
	N.set_cell_keys(cell, keys)
	write(rec, stack, cell)
	remember(rec, cell)
	return true
end

--- the partition of the cell is emptied (the kept keys of the other kind stay); without a cell (issue #37) the
--- workbench's own partition, all of it
function M.clear(entity)
	local rec = rec_of(entity)
	if not rec then return false end
	local stack, cell = cell_of(rec)
	if not stack then
		rec.config = nil
		return true
	end
	N.set_cell_keys(cell, {})
	write(rec, stack, cell)
	remember(rec, cell)
	return true
end

--- the copy mode: keep the partition when the cell is taken out (AE2's KEEP_ON_REMOVE)
function M.set_keep(entity, keep)
	local rec = rec_of(entity)
	if not rec then return false end
	rec.keep = keep == true
	if not rec.keep and not cell_of(rec) then rec.config = nil end
	return true
end

--- A click on card slot `slot` of the cell (the inventory's slot `slot` + 1): a card in the cursor goes in (into that
--- slot, else the first empty one; a card the cell does not take, one beyond its kind's limit, one without a free slot
--- or without a cell is refused before anything moves), a click on a card takes it into the cursor (`shift`: into
--- `inventory`). Returns the reason of a refusal.
function M.card_click(entity, slot, cursor, inventory, shift)
	local rec = rec_of(entity)
	local stack, cell
	if rec then stack, cell = cell_of(rec) end
	if not stack then return "no-cell" end
	local inv = inv_of(rec)
	local r = rules_of(N.cell_spec(cell.name))
	local out
	if cursor and cursor.valid_for_read then
		local kind = N.card_kind(cursor.name)
		local limit = kind and r.limits[kind]
		if not limit then return "not-here" end
		local n = 0
		for _, name in ipairs(slot_cards(inv)) do if N.card_kind(name) == kind then n = n + 1 end end
		if n >= limit then return "limit" end
		local free = slot + 1 <= 1 + r.slots and not inv[slot + 1].valid_for_read and slot + 1 or nil
		for i = 2, 1 + r.slots do if not free and not inv[i].valid_for_read then free = i end end
		if not free then return "full" end
		inv[free].transfer_stack(cursor, 1)
	else
		local at = slot + 1
		if not (at >= 2 and at <= #inv and inv[at].valid_for_read) then return nil end
		if shift then
			if not (inventory and inventory.valid) then return "no-inventory" end
			if inventory.insert(inv[at]) < 1 then return "inventory-full" end
			inv[at].clear()
			out = "out"
		elseif not (cursor and cursor.transfer_stack(inv[at])) then
			return "inventory-full"
		end
	end
	M.sync(rec, inventory, {})
	return nil, out
end

--- Issue #28: shift + click on stack `stack` of the player's inventory in the workbench's window: a cell goes into the
--- empty cell slot, cards into the card slots (one each, as the cell takes them). Returns the reason when nothing goes
--- in (nothing moved then).
function M.shift_in(entity, stack, inventory)
	local rec = rec_of(entity)
	if not rec then return "no-workbench" end
	if not (stack and stack.valid_for_read) then return nil end
	if is_cell(stack) then
		if inv_of(rec)[1].valid_for_read then return "occupied" end
		return M.cell_click(entity, stack, inventory, false)
	end
	if not N.card_kind(stack.name) then return "not-here" end
	local why = M.card_click(entity, 1, stack, inventory, false)
	if why then return why end
	while stack.valid_for_read and not M.card_click(entity, 1, stack, inventory, false) do end
	return nil
end

--- the window's data: { cell = { name, fluid, items, bytes, bytes_total, types, types_total, partition = keys, cards =
--- { names: the card slots' cards }, slots, inverted, fuzzy, equal, void } or nil, keep, config (the workbench's
--- partition: its item keys, then its fluid keys), config_items (how many of them are items), limits = { items,
--- fluids } (the most kinds of each) }
function M.info(entity)
	local rec = rec_of(entity)
	if not rec then return nil end
	local config, n = kept_list(rec.config)
	local lim = kept_limits()
	local out = { keep = rec.keep, config = config, config_items = n, limits = { items = lim.item.types, fluids = lim.fluid.types } }
	local stack, cell = cell_of(rec)
	if stack then
		local spec = N.cell_spec(cell.name)
		local items = {}
		for k, v in pairs(cell.items) do items[k] = v end
		--- the cards are the card slots' items while the cell lies here: the fields as they will be in the tags
		cell.cards = N.clean_cards(spec, slot_cards(inv_of(rec)))
		N.apply_cell_cards(cell)
		local cards = { table.unpack(cell.cards or {}) }
		out.cell = { name = cell.name, fluid = spec.kind == "fluid", items = items, bytes = cell.bytes, bytes_total = spec.bytes,
			types = cell.types, types_total = spec.types, partition = N.cell_keys(cell), cards = cards,
			slots = rules_of(spec).slots, inverted = N.has_card(cell, "inverter"), fuzzy = N.has_card(cell, "fuzzy"),
			equal = cell.eq, void = cell.void == true, sticky = cell.sticky == true }
	end
	return out
end

--------------------------------------------------------------------------------
--- events
--------------------------------------------------------------------------------

function M.on_built(entity)
	if is_bench(entity) then register(entity) end
end

local function forget(s, unit)
	local rec = s.recs[unit]
	if rec and rec.inv and rec.inv.valid and rec.inv.is_empty() then rec.inv.destroy() end
	s.recs[unit] = nil
	for i = #s.list, 1, -1 do if s.list[i] == unit then table.remove(s.list, i) end end
end

--- everything in the slots (the cards in the cell's tags first) into `buffer`, the rest onto the ground at `surface`,
--- `position`
local function empty_out(rec, buffer, surface, position)
	local inv = inv_of(rec)
	M.sync(rec, buffer, {})
	release(rec, inv)
	for i = 1, #inv do
		local stack = inv[i]
		if stack.valid_for_read and buffer and buffer.valid then
			local n = buffer.insert(stack)
			if n >= stack.count then stack.clear() elseif n > 0 then stack.count = stack.count - n end
		end
		if stack.valid_for_read and surface then
			surface.spill_item_stack{ position = position, stack = stack, allow_belts = false }
			stack.clear()
		end
	end
end

--- mined (the cell into `buffer`), destroyed or removed by a script (`buffer` nil: spilled)
function M.on_removed(entity, buffer)
	local s = storage.fork_me_workbench
	local rec = s and is_bench(entity) and s.recs[entity.unit_number]
	if not rec then return end
	empty_out(rec, buffer, entity.surface, entity.position)
	forget(s, entity.unit_number)
end

--- from the network's slow step: a few workbenches per step; one whose entity vanished without an event spills its
--- cell at its position
function M.sweep()
	local s = storage.fork_me_workbench
	if not (s and #s.list > 0) then return end
	for _ = 1, math.min(SWEEP_PER_STEP, #s.list) do
		if s.cursor > #s.list then s.cursor = 1 end
		local unit = s.list[s.cursor]
		local rec = s.recs[unit]
		if rec and not rec.entity.valid then
			empty_out(rec, nil, game.get_surface(rec.where.surface), { rec.where.x, rec.where.y })
			forget(s, unit)
		else
			s.cursor = s.cursor + 1
		end
	end
end
N.slow_hooks[#N.slow_hooks + 1] = M.sweep

--- after a mod update: the records of workbenches that are gone are swept, every workbench has one (and the
--- inventory of issue #28)
function M.on_configuration_changed()
	state()
	for _, surface in pairs(game.surfaces) do
		for _, e in pairs(surface.find_entities_filtered{ name = NAME }) do register(e) end
	end
end

remote.add_interface("gregtorio-me-workbench", {
	info = function(entity) return M.info(entity) end,
	--- the window's clicks on the cell slot and a card slot: `cursor` a LuaItemStack, `inventory` a LuaInventory
	cell_click = function(entity, cursor, inventory, shift) return M.cell_click(entity, cursor, inventory, shift) end,
	card_click = function(entity, slot, cursor, inventory, shift) return M.card_click(entity, slot, cursor, inventory, shift) end,
	set_partition_slot = function(entity, index, key) return M.set_partition_slot(entity, index, key) end,
	from_contents = function(entity) return M.from_contents(entity) end,
	clear = function(entity) return M.clear(entity) end,
	set_keep = function(entity, keep) return M.set_keep(entity, keep) end,
	--- issue #28: the inventory the window shows, and what a change by a player does (`back`: a LuaInventory standing
	--- for the player's inventory; `places`: LuaItemStacks and LuaInventories where a cell that left is looked for)
	inventory = function(entity) return M.inventory(entity) end,
	sync = function(entity, back, places) return M.sync_entity(entity, back, places) end,
	--- shift + click on a stack of the player's inventory in the window: a cell into the cell slot, cards after it
	shift_in = function(entity, stack, inventory) return M.shift_in(entity, stack, inventory) end,
	--- what the removal events do (`buffer`: mined)
	removed = function(entity, buffer) M.on_removed(entity, buffer) end,
	sweep = function() M.sweep() end,
})

--- the workbench of a window by its unit number (it is no node of the ME graph, which the windows ask first)
function M.by_unit(unit)
	local s = storage.fork_me_workbench
	local rec = s and s.recs[unit]
	return rec and rec.entity and rec.entity.valid and rec.entity or nil
end

M.NAME = NAME
return M
