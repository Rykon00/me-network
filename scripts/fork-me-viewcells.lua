--------------------------------------------------------------------------------
--- ME NETWORK: VIEW CELLS (issue #440; prototypes/cards.lua)
--- AE2's View Cell (AE2-Unofficial: items/storage/ItemViewCell.java): an item with a partition (and an Inverter or Fuzzy Card),
--- partitioned in the ME Cell Workbench like a storage cell (its spec is mod-data `view_cells`, never `cells`: it is no storage
--- cell, no drive or chest takes it). Up to SLOTS of them lie in an ME Terminal's view cell slots, or, for the Wireless ME
--- Terminal (whose window is the terminal's with the access point as its block), in the player's own slots; the terminal's
--- storage list then shows only what the cells allow (`M.allows`).
--- State: storage.fork_me_view = { terms = { [unit] = { entity, inv, where } }, players = { [index] = { inv } } }; the filter
--- of an inventory is derived (a cache outside storage, by the item numbers of its stacks).
--------------------------------------------------------------------------------

local N = require("scripts.fork-me-network")
local G = require("scripts.fork-me-gui")

local M = {}

local NAME = "me-view-cell"
M.NAME = NAME
local SLOTS = 5                                     -- (AE2: the terminal's five view cell slots)

local function state()
	local s = storage.fork_me_view
	if not s then
		s = { terms = {}, players = {} }
		storage.fork_me_view = s
	end
	return s
end

local function is_terminal(entity) return entity.name == "me-terminal" end
local function is_access_point(entity) return N.kind_of(entity.name) == "access-point" end

--- the view cell inventory of a terminal window: the terminal's own, or for a wireless window (the access point) the
--- player's; made when first asked for; nil for any other block (the ME Chest's window)
function M.inventory(entity, player)
	if not (entity and entity.valid) then return nil end
	local s = state()
	local rec
	if is_terminal(entity) then
		rec = s.terms[entity.unit_number]
		if not rec then
			rec = { entity = entity }
			s.terms[entity.unit_number] = rec
		end
		rec.entity = entity
		rec.where = { surface = entity.surface.index, x = entity.position.x, y = entity.position.y }
	elseif is_access_point(entity) and player then
		rec = s.players[player.index]
		if not rec then
			rec = {}
			s.players[player.index] = rec
		end
	else
		return nil
	end
	if not (rec.inv and rec.inv.valid) then rec.inv = game.create_inventory(SLOTS, { "item-name." .. NAME }) end
	return rec.inv
end

--- the signature of an inventory's view cells (a written cell gets a new item number)
function M.sig(inv)
	if not inv then return "" end
	local out = {}
	for i = 1, #inv do
		local st = inv[i]
		out[i] = st.valid_for_read and tostring(st.item_number or st.name) or "-"
	end
	return table.concat(out, ",")
end

local cache = setmetatable({}, { __mode = "k" })    -- inventory -> { sig, filter }

--- the filter of the view cells in `inv`: { pos = { cells }, neg = { cells } } or nil (no view cell with a list: everything is
--- shown). A cell with an Inverter Card is a blacklist (neg), else a whitelist (pos); a cell with an empty list does nothing.
--- (AE2-Unofficial: ItemViewCell.createFilter, a MergedPriorityList of the cells' lists)
function M.filter(inv)
	if not inv then return nil, "" end
	local sig = M.sig(inv)
	local c = cache[inv]
	if c and c.sig == sig then return c.filter, sig end
	local pos, neg, any = {}, {}, false
	for i = 1, #inv do
		local st = inv[i]
		if st.valid_for_read and st.name == NAME then
			local cell = N.cell_from_stack(st)
			if cell.deny then
				neg[#neg + 1] = cell
				any = true
			elseif cell.partition then
				pos[#pos + 1] = cell
				any = true
			end
		end
	end
	local filter = any and { pos = pos, neg = neg } or nil
	cache[inv] = { sig = sig, filter = filter }
	return filter, sig
end

--- may the terminal list `key` under `filter`? A key a blacklist cell names is never shown; with whitelist cells a key one of
--- them names is shown (OR), without any every other key is.
--- ported from Applied Energistics 2, src/main/java/appeng/util/prioitylist/MergedPriorityList.java (isListed, of
--- GTNewHorizons' Applied-Energistics-2-Unofficial), LGPL-3.0, (c) AlgorithmX2 et al.
function M.allows(filter, key)
	for _, cell in ipairs(filter.neg) do
		if not N.accepts(cell, key) then return false end
	end
	if #filter.pos == 0 then return true end
	for _, cell in ipairs(filter.pos) do
		if N.accepts(cell, key) then return true end
	end
	return false
end

--- A click on view cell slot `slot` of the terminal window of `entity` (`cursor`, `inv`: the player's hand and inventory):
--- a view cell in hand goes in (or is swapped), anything else is refused; an empty hand takes the cell (shift: into the
--- inventory). Returns the reason of a refusal.
function M.click(entity, slot, cursor, inv, shift)
	local player = inv and inv.valid and inv.player_owner or nil
	local vinv = M.inventory(entity, player)
	if not vinv then return "no-target" end
	local stack = slot and slot >= 1 and slot <= #vinv and vinv[slot]
	if not stack then return "no-target" end
	if cursor and cursor.valid_for_read then
		if cursor.name ~= NAME then return "not-here" end
		if not stack.valid_for_read then stack.transfer_stack(cursor, 1)
		elseif cursor.count == 1 then stack.swap_stack(cursor)
		else return "full" end
		return nil
	end
	if not stack.valid_for_read then return nil end
	if shift and inv and inv.valid then
		local got = inv.insert(stack)
		if got >= stack.count then stack.clear() else return "inventory-full" end
		return nil
	end
	if cursor then cursor.transfer_stack(stack) end
	return nil
end

--- shift + click of a view cell in the inventory pane: into the first free view cell slot. Returns the reason of a refusal
function M.shift_in(entity, stack, inv)
	local player = inv and inv.valid and inv.player_owner or nil
	local vinv = M.inventory(entity, player)
	if not vinv then return "no-target" end
	for i = 1, #vinv do
		if not vinv[i].valid_for_read then
			vinv[i].transfer_stack(stack, 1)
			return nil
		end
	end
	return "full"
end

local function give_all(rec, target)
	local surface, pos
	local e = rec.entity
	if e and e.valid then surface, pos = e.surface, e.position
	elseif rec.where then surface, pos = game.get_surface(rec.where.surface), { rec.where.x, rec.where.y } end
	for i = 1, #rec.inv do
		local st = rec.inv[i]
		if st.valid_for_read then
			local got = target and target.valid and target.insert(st) or 0
			if got >= st.count then st.clear()
			elseif surface then
				surface.spill_item_stack{ position = pos, stack = st, allow_belts = false }
				st.clear()
			end
		end
	end
end

--- a terminal is mined (`buffer`: the event's buffer) or destroyed (nil: the cells are spilled where it stood)
function M.on_removed(entity, buffer)
	if not (entity and entity.valid and is_terminal(entity)) then return end
	local s = storage.fork_me_view
	local rec = s and s.terms[entity.unit_number]
	if not rec then return end
	if rec.inv and rec.inv.valid then
		give_all(rec, buffer)
		rec.inv.destroy()
	end
	s.terms[entity.unit_number] = nil
end

--- a terminal that vanished without an event (the network's sweep): its cells are spilled where it stood
N.vanish_hooks[#N.vanish_hooks + 1] = function(unit)
	local s = storage.fork_me_view
	local rec = s and s.terms[unit]
	if not rec then return end
	if rec.inv and rec.inv.valid then
		give_all(rec, nil)
		rec.inv.destroy()
	end
	s.terms[unit] = nil
end

--- a player is removed from the game: nothing is left to give their wireless view cells to, so they are spilled at the origin
--- of the first surface (never lost)
function M.forget_player(index)
	local s = storage.fork_me_view
	local rec = s and s.players[index]
	if not rec then return end
	if rec.inv and rec.inv.valid then
		local surface = game.surfaces[1]
		for i = 1, #rec.inv do
			local st = rec.inv[i]
			if st.valid_for_read and surface then surface.spill_item_stack{ position = { 0, 0 }, stack = st, allow_belts = false } end
		end
		rec.inv.destroy()
	end
	s.players[index] = nil
end

--- the window's view cell slots (in the flow `box`), rebuilt when the cells changed
function M.draw(box, entity, player)
	local inv = M.inventory(entity, player)
	if not inv then
		box.visible = false
		return
	end
	box.visible = true
	local sig = M.sig(inv)
	if box.tags.sig == sig then return end
	box.clear()
	box.tags = { sig = sig }
	box.add{ type = "label", caption = { "fork-me-terminal.view-cells" }, tooltip = { "fork-me-terminal.view-cells-tooltip" } }
	for i = 1, #inv do
		G.stack_button(box, inv[i], G.act("block_slot", { slot = i }),
			{ inv[i].valid_for_read and "fork-me-terminal.view-slot-tooltip" or "fork-me-terminal.view-slot-empty" })
	end
end

remote.add_interface("gregtorio-me-viewcells", {
	--- (tests) the view cell inventory of a terminal (or, with `player`, of the wireless window of an access point)
	inventory = function(entity, player) return M.inventory(entity, player) end,
	--- (tests) the filter's keys the terminal would show: does it allow `key`?
	allows = function(entity, key, player)
		local f = M.filter(M.inventory(entity, player))
		return f == nil or M.allows(f, key)
	end,
	click = function(entity, slot, cursor, inv, shift) return M.click(entity, slot, cursor, inv, shift) end,
})

return M
