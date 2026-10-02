--------------------------------------------------------------------------------
--- ME CELL WORKBENCH (me-network issue #17, part 3; prototypes/cards.lua, docs/ME-REWORK.md "The ME Cell Workbench",
--- guide: docs/AE2.md "ME Cell Workbench")
---   * AE2's Cell Workbench: one storage cell, its partition (items with quality, or fluids) and its card slots (4 for
---     an item cell, 3 for a fluid cell: AE2's numbers), "From contents", "Clear" and the copy mode ("keep the
---     partition when the cell is taken out": it stays in the workbench and goes onto the next cell whose partition
---     is empty). AE2's workbench needs neither the network nor power (its block entity has no grid node): this one is
---     no ME member and needs no cable.
---   * The cell stays an item: it lies in a script inventory of one slot (rec.inv), and every change is written into
---     its tags at once (N.cell_stack), with its contents untouched. The cards are part of the cell's tags.
---   * Mined: the cell goes into the buffer; destroyed or removed by a script: it is spilled; a workbench removed
---     without an event: the sweep (from the network's slow step) spills it at the position kept in the record.
--- State: storage.fork_me_workbench = { recs = { [unit] = { entity, inv, keep, config, where } }, list, cursor }.
--------------------------------------------------------------------------------

local N = require("scripts.fork-me-network")

local M = {}

local NAME = "me-cell-workbench"
local SWEEP_PER_STEP = 20           -- workbenches checked for a vanished entity per slow step

local function state()
	local s = storage.fork_me_workbench
	if not s then
		s = { recs = {}, list = {}, cursor = 1 }
		storage.fork_me_workbench = s
	end
	return s
end

local function is_bench(entity) return entity and entity.valid and entity.name == NAME end

local function register(entity)
	local s = state()
	local unit = entity.unit_number
	local rec = s.recs[unit]
	if not rec then
		rec = { entity = entity, inv = game.create_inventory(1), keep = false,
			where = { surface = entity.surface.index, x = entity.position.x, y = entity.position.y } }
		s.recs[unit] = rec
		s.list[#s.list + 1] = unit
	end
	return rec
end

local function rec_of(entity)
	if not is_bench(entity) then return nil end
	return register(entity)
end

--- the cell in the workbench: its stack (valid for read) and its record (N.cell_from_tags), or nil
local function cell_of(rec)
	local stack = rec.inv.valid and rec.inv[1]
	if not (stack and stack.valid_for_read and N.cell_spec(stack.name)) then return nil end
	return stack, N.cell_from_stack(stack)
end

--- the cell's record written back into its stack (tags, description)
local function write(stack, cell)
	stack.set_stack(N.cell_stack(cell))
end

--- the card rules of a cell (item or fluid cell)
local function rules_of(spec)
	local r = N.card_rules()
	return spec.kind == "fluid" and r.fluid_cell or r.item_cell
end

--------------------------------------------------------------------------------
--- the window's functions (scripts/fork-me-windows.lua) and the runtime test (remote below)
--------------------------------------------------------------------------------

--- a click on the cell slot: a cell in the cursor goes in (a cell there is swapped into the cursor); with an empty
--- cursor the cell goes into the cursor (`shift`: into `inventory`). Returns a reason on failure.
function M.cell_click(entity, cursor, inventory, shift)
	local rec = rec_of(entity)
	if not rec then return "no-workbench" end
	local slot = rec.inv[1]
	if cursor and cursor.valid_for_read then
		if not N.cell_spec(cursor.name) then return "not-a-cell" end
		if slot.valid_for_read then
			local held = game.create_inventory(1)
			held[1].transfer_stack(cursor)
			M.take(rec, cursor)
			M.put(rec, held[1])
			if held[1].valid_for_read then cursor.transfer_stack(held[1]) end
			held.destroy()
			return nil
		end
		M.put(rec, cursor)
		return nil
	end
	if not slot.valid_for_read then return nil end
	if shift then
		if not (inventory and inventory.valid and inventory.insert(slot) >= 1) then return "inventory-full" end
		slot.clear()
		M.taken(rec)
	elseif cursor then
		if not cursor.transfer_stack(slot) then return "inventory-full" end
		M.taken(rec)
	end
	return nil
end

--- one cell from `stack` into the workbench (AE2: a cell with a partition shows it; one without gets the kept one)
function M.put(rec, stack)
	if not (stack and stack.valid_for_read and N.cell_spec(stack.name)) or rec.inv[1].valid_for_read then return false end
	rec.inv[1].transfer_stack(stack)                       -- (a cell stacks to 1)
	local cell_stack, cell = cell_of(rec)
	if not cell_stack then return false end
	if #N.cell_keys(cell) > 0 then
		rec.config = N.cell_keys(cell)
	elseif rec.keep and rec.config and #rec.config > 0 then
		N.set_cell_keys(cell, rec.config)
		write(cell_stack, cell)
	end
	return true
end

--- the cell into `target` (an empty LuaItemStack); then what was taken out decides the kept partition
function M.take(rec, target)
	local slot = rec.inv[1]
	if not slot.valid_for_read then return false end
	if not target.transfer_stack(slot) then return false end
	M.taken(rec)
	return true
end

--- the cell left: without the copy mode the workbench forgets the partition (AE2's CLEAR_ON_REMOVE)
function M.taken(rec)
	if not rec.keep then rec.config = nil end
end

--- the partition button `index`: `key` (nil: remove) replaces the key at that place of the list
function M.set_partition_slot(entity, index, key)
	local rec = rec_of(entity)
	local stack, cell
	if rec then stack, cell = cell_of(rec) end
	if not stack then return false end
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
	write(stack, cell)
	rec.config = N.cell_keys(cell)
	return true
end

--- AE2's "partition storage": the partition becomes what the cell holds
function M.from_contents(entity)
	local rec = rec_of(entity)
	local stack, cell
	if rec then stack, cell = cell_of(rec) end
	if not stack then return false end
	local keys = {}
	for key in pairs(cell.items) do if not key:find("#", 1, true) then keys[#keys + 1] = key end end
	N.set_cell_keys(cell, keys)
	write(stack, cell)
	rec.config = N.cell_keys(cell)
	return true
end

function M.clear(entity)
	local rec = rec_of(entity)
	local stack, cell
	if rec then stack, cell = cell_of(rec) end
	if not stack then return false end
	N.set_cell_keys(cell, {})
	write(stack, cell)
	rec.config = nil
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

--- A click on card slot `slot` of the cell: a card in the cursor goes in (into `slot`, else the first free one), a
--- click on a card takes it into the cursor (`shift`: into `inventory`). Returns a reason on failure.
function M.card_click(entity, slot, cursor, inventory, shift)
	local rec = rec_of(entity)
	local stack, cell
	if rec then stack, cell = cell_of(rec) end
	if not stack then return "no-cell" end
	local r = rules_of(N.cell_spec(cell.name))
	cell.cards = cell.cards or {}                  -- a list (tags keep no gaps): a card goes to the end, one taken closes up
	if cursor and cursor.valid_for_read then
		local kind = N.card_kind(cursor.name)
		local limit = kind and r.limits[kind]
		if not limit then return "not-here" end
		local n = 0
		for _, name in ipairs(cell.cards) do if N.card_kind(name) == kind then n = n + 1 end end
		if n >= limit then return "limit" end
		if #cell.cards >= r.slots then return "full" end
		cell.cards[#cell.cards + 1] = cursor.name
		if cursor.count > 1 then cursor.count = cursor.count - 1 else cursor.clear() end
	else
		local name = cell.cards[slot]
		if not name then return nil end
		if shift then
			if not (inventory and inventory.valid and inventory.insert{ name = name, count = 1 } >= 1) then return "inventory-full" end
		elseif not (cursor and cursor.set_stack{ name = name, count = 1 }) then
			return "inventory-full"
		end
		table.remove(cell.cards, slot)
	end
	N.apply_cell_cards(cell)
	write(stack, cell)
	return nil
end

--- the window's data: { cell = { name, fluid, items, bytes, bytes_total, types, types_total, partition = keys, cards =
--- { [slot] = name }, slots, inverted, fuzzy, equal, void } or nil, keep, config }
function M.info(entity)
	local rec = rec_of(entity)
	if not rec then return nil end
	local out = { keep = rec.keep, config = rec.config and { table.unpack(rec.config) } or {} }
	local stack, cell = cell_of(rec)
	if stack then
		local spec = N.cell_spec(cell.name)
		local items = {}
		for k, v in pairs(cell.items) do items[k] = v end
		local cards = { table.unpack(cell.cards or {}) }
		out.cell = { name = cell.name, fluid = spec.kind == "fluid", items = items, bytes = cell.bytes, bytes_total = spec.bytes,
			types = cell.types, types_total = spec.types, partition = N.cell_keys(cell), cards = cards,
			slots = rules_of(spec).slots, inverted = N.has_card(cell, "inverter"), fuzzy = N.has_card(cell, "fuzzy"),
			equal = cell.eq, void = cell.void == true }
	end
	return out
end

--------------------------------------------------------------------------------
--- events
--------------------------------------------------------------------------------

function M.on_built(entity)
	if is_bench(entity) then register(entity) end
end

local function spill_at(surface, position, stack)
	if surface and stack.valid_for_read then
		surface.spill_item_stack{ position = position, stack = stack, allow_belts = false }
		stack.clear()
	end
end

local function forget(s, unit)
	local rec = s.recs[unit]
	if rec and rec.inv and rec.inv.valid then rec.inv.destroy() end
	s.recs[unit] = nil
	for i = #s.list, 1, -1 do if s.list[i] == unit then table.remove(s.list, i) end end
end

--- mined (the cell into `buffer`), destroyed or removed by a script (`buffer` nil: spilled)
function M.on_removed(entity, buffer)
	local s = storage.fork_me_workbench
	local rec = s and is_bench(entity) and s.recs[entity.unit_number]
	if not rec then return end
	local stack = rec.inv.valid and rec.inv[1]
	if stack and stack.valid_for_read then
		if buffer and buffer.valid and buffer.insert(stack) >= 1 then stack.clear() end
		spill_at(entity.surface, entity.position, stack)
	end
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
			local stack = rec.inv.valid and rec.inv[1]
			if stack and stack.valid_for_read then
				spill_at(game.get_surface(rec.where.surface), { rec.where.x, rec.where.y }, stack)
			end
			forget(s, unit)
		else
			s.cursor = s.cursor + 1
		end
	end
end
N.slow_hooks[#N.slow_hooks + 1] = M.sweep

--- after a mod update: the records of workbenches that are gone are swept, every workbench has one
function M.on_configuration_changed()
	state()
	for _, surface in pairs(game.surfaces) do
		for _, e in pairs(surface.find_entities_filtered{ name = NAME }) do register(e) end
	end
end

remote.add_interface("gregtorio-me-workbench", {
	info = function(entity) return M.info(entity) end,
	--- the window's clicks: `cursor` a LuaItemStack, `inventory` a LuaInventory
	cell_click = function(entity, cursor, inventory, shift) return M.cell_click(entity, cursor, inventory, shift) end,
	card_click = function(entity, slot, cursor, inventory, shift) return M.card_click(entity, slot, cursor, inventory, shift) end,
	set_partition_slot = function(entity, index, key) return M.set_partition_slot(entity, index, key) end,
	from_contents = function(entity) return M.from_contents(entity) end,
	clear = function(entity) return M.clear(entity) end,
	set_keep = function(entity, keep) return M.set_keep(entity, keep) end,
	--- what the removal events do (`buffer`: mined)
	removed = function(entity, buffer) M.on_removed(entity, buffer) end,
	sweep = function() M.sweep() end,
})

M.NAME = NAME
return M
