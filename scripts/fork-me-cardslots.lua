--------------------------------------------------------------------------------
--- ME NETWORK: CARD SLOTS OF A BLOCK (issue #17, #28; made generic for issue #110)
---   The card slots of the ME Storage Bus (scripts/fork-me-storagebus.lua) and, since issue #110, of the ME Import Bus and
---   Export Bus (scripts/fork-me-io.lua): a script inventory per block (`rec.inv`) whose slots the block's window shows
---   next to the player's inventory (issue #28), the cards by slot in `rec.cards` ({ [slot] = name }, what the block's code
---   reads), and what a blueprint, a settings paste or a clone asks for in `rec.want` (it is filled from the player's
---   inventory, then the network). The clicks refuse a wrong card before anything moves; the cards are given back when the
---   block is mined, spilled when it is destroyed or vanishes.
---   `CS.new(def)` makes the functions of one kind of block; `def`:
---     rules()        the block's card rules: { slots, limits = { kind -> how many } } (N.card_rules().<block>)
---     title(rec)     the localised name of the block's inventory (shown in the game's inventory lists)
---     rec_of(entity) the block's record, or nil
---     on_cards(rec)  the cards changed: the fields the block's code reads are made from them (and the block is visited)
---   The record keeps: inv, cards, want, where (its position, for a block that vanishes without an event).
--------------------------------------------------------------------------------

local N = require("scripts.fork-me-network")
local G = require("scripts.fork-me-gui")

local M = {}

function M.new(def)
	local C = {}

	--- the cards of a block by kind: { capacity = n, ... }
	function C.counts(rec)
		local out = {}
		for _, name in pairs(rec.cards or {}) do
			local kind = N.card_kind(name)
			if kind then out[kind] = (out[kind] or 0) + 1 end
		end
		return out
	end

	--- where a block's cards go when nobody takes them: its position (kept, a block can vanish without an event)
	local function remember_place(rec)
		local e = rec.entity
		if e and e.valid then rec.where = { surface = e.surface.index, x = e.position.x, y = e.position.y } end
	end

	--- Issue #28: the card slots are a script inventory (rec.inv) whose slots the block's window shows. Its stacks are the
	--- cards; rec.cards is what the block's code, the window and the settings read, made from the slots by sync() and by
	--- every function here that moves a card. A block of a save before issue #28 kept only the names: its inventory is made
	--- here, with a card item for each name (the version number may not change, so no on_configuration_changed has to run
	--- first).
	function C.inv_of(rec)
		local inv = rec.inv
		if inv and inv.valid then return inv end
		inv = game.create_inventory(def.rules().slots, def.title(rec))
		for slot, name in pairs(rec.cards or {}) do
			if type(slot) == "number" and slot <= #inv and type(name) == "string" and prototypes.item[name] then
				inv[slot].set_stack{ name = name, count = 1 }
			end
		end
		rec.inv = inv
		return inv
	end
	local inv_of = C.inv_of

	--- every stack in the card slots onto the ground (destroyed, vanished); the slots are empty afterwards
	function C.spill_cards(rec)
		local inv = inv_of(rec)
		local e = rec.entity
		local surface, pos
		if e and e.valid then surface, pos = e.surface, e.position
		elseif rec.where then surface, pos = game.get_surface(rec.where.surface), { rec.where.x, rec.where.y } end
		for slot = 1, #inv do
			local stack = inv[slot]
			if stack.valid_for_read and surface then
				surface.spill_item_stack{ position = pos, stack = stack, allow_belts = false }
				stack.clear()
			end
		end
		rec.cards = {}
	end

	--- into `target` (LuaInventory or mined buffer), what does not fit onto the ground: everything in the slots, also an
	--- item a sync has not seen yet
	function C.give_cards(rec, target)
		local inv = inv_of(rec)
		for slot = 1, #inv do
			local stack = inv[slot]
			if stack.valid_for_read and target and target.valid then
				local got = target.insert(stack)
				if got >= stack.count then stack.clear() elseif got > 0 then stack.count = stack.count - got end
			end
		end
		C.spill_cards(rec)
	end

	--- the record and its inventory leave: what is still in the slots is spilled
	function C.detach(rec)
		C.spill_cards(rec)
		if rec.inv and rec.inv.valid and rec.inv.is_empty() then rec.inv.destroy() end
	end

	--- can the block take one more card `name`? (a card of a kind it takes, below that kind's limit, an empty slot)
	function C.card_fits(rec, name)
		local kind = N.card_kind(name)
		local rules = def.rules()
		local limit = kind and rules.limits[kind]
		if not limit then return false, "not-here" end
		if (C.counts(rec)[kind] or 0) >= limit then return false, "limit" end
		local inv = inv_of(rec)
		for slot = 1, rules.slots do
			if not inv[slot].valid_for_read then return slot end
		end
		return false, "full"
	end
	local card_fits = C.card_fits

	--- one card into the empty slot `slot`: from `from` (a LuaItemStack: one of it is moved, quality and all) or a new
	--- stack of `name` (taken from the network by the caller)
	function C.install(rec, slot, name, from)
		local inv = inv_of(rec)
		if from then inv[slot].transfer_stack(from, 1) else inv[slot].set_stack{ name = name, count = 1 } end
		rec.cards = rec.cards or {}
		rec.cards[slot] = inv[slot].valid_for_read and inv[slot].name or nil
		remember_place(rec)
	end
	local install = C.install

	--- the cards of a block as a list of names (slot order); nil when it has none
	function C.card_list(rec)
		local out
		for slot = 1, def.rules().slots do
			local name = rec.cards and rec.cards[slot]
			if name then
				out = out or {}
				out[#out + 1] = name
			end
		end
		return out
	end

	--- Issue #28: the card slots checked (the migration's backstop and the tests; the window's clicks refuse before they
	--- move anything, so this finds nothing to do after them). One card per slot, of a kind the block takes, within its
	--- kind's limit: the cards that were in their slot already are kept first, then the new ones in slot order; a second
	--- card of one stack goes into an empty slot when it may, else back to `back` (G.give_back: the player, a LuaInventory,
	--- nil for the ground at the block) with every other item. rec.cards follows the slots; a change takes the block out of
	--- waiting for blueprint cards (the player decides now). Returns true when the slots or the cards changed.
	function C.sync(rec, back)
		local inv = inv_of(rec)
		local r = def.rules()
		local old = rec.cards or {}
		local counts, kept, moved = {}, {}, false
		local function take(name)
			local kind = N.card_kind(name)
			local limit = kind and r.limits[kind]
			if not limit or (counts[kind] or 0) >= limit then return false end
			counts[kind] = (counts[kind] or 0) + 1
			return true
		end
		for pass = 1, 2 do
			for slot = 1, math.min(#inv, r.slots) do
				local stack = inv[slot]
				if stack.valid_for_read and not kept[slot] and (old[slot] == stack.name) == (pass == 1) and take(stack.name) then
					kept[slot] = true
				end
			end
		end
		for slot = 1, #inv do
			local stack = inv[slot]
			if stack.valid_for_read then
				local extra = kept[slot] and stack.count - 1 or stack.count
				while extra > 0 do
					local free
					if N.card_kind(stack.name) then
						for i = 1, math.min(#inv, r.slots) do
							if not inv[i].valid_for_read then free = i break end
						end
					end
					if free and take(stack.name) then
						inv[free].transfer_stack(stack, 1)
						kept[free] = true
						extra = extra - 1
					else
						G.give_back(back, stack, rec.entity, extra)
						extra = 0
					end
					moved = true
				end
			end
		end
		local cards, changed = {}, moved
		for slot = 1, r.slots do
			local stack = inv[slot]
			cards[slot] = kept[slot] and stack.valid_for_read and stack.name or nil
			if cards[slot] ~= old[slot] then changed = true end
		end
		if not changed then return false end
		rec.cards = cards
		rec.want = nil
		remember_place(rec)
		def.on_cards(rec)
		return true
	end

	--- A click on card slot `slot` of the window. With a card in the cursor one card of it goes in (into `slot`, else the
	--- first empty slot); a card the block does not take, one beyond its kind's limit or one without an empty slot is
	--- refused before anything moves (the reason is returned, the cursor keeps it). With an empty cursor the card in the
	--- slot goes into the cursor (`shift`: into `inventory`). Takes the block out of waiting for blueprint cards.
	function C.card_click(entity, slot, cursor, inventory, shift)
		local rec = def.rec_of(entity)
		if not rec then return "no-bus" end
		local inv = inv_of(rec)
		local out
		if cursor and cursor.valid_for_read then
			local free, why = card_fits(rec, cursor.name)
			if not free then return why end
			if slot >= 1 and slot <= def.rules().slots and not inv[slot].valid_for_read then free = slot end
			install(rec, free, nil, cursor)
		else
			local stack = slot >= 1 and slot <= #inv and inv[slot]
			if not (stack and stack.valid_for_read) then return nil end
			if shift then
				if not (inventory and inventory.valid) then return "no-inventory" end
				if inventory.insert(stack) < 1 then return "inventory-full" end
				stack.clear()
				out = "out"
			elseif not (cursor and cursor.transfer_stack(stack)) then
				return "inventory-full"
			end
			if rec.cards then rec.cards[slot] = nil end
		end
		rec.want = nil
		def.on_cards(rec)
		return nil, out
	end

	--- Issue #28: shift + click on stack `stack` of the player's inventory in the block's window: its cards go into the
	--- empty slots, one each, as far as the kind's limit allows; the rest stays in the stack. Returns the reason when none
	--- goes in (nothing moved then).
	function C.shift_in(entity, stack)
		local rec = def.rec_of(entity)
		if not rec then return "no-bus" end
		if not (stack and stack.valid_for_read) then return nil end
		local moved, why = 0, nil
		while stack.valid_for_read do
			local free
			free, why = card_fits(rec, stack.name)
			if not free then break end
			install(rec, free, nil, stack)
			moved = moved + 1
		end
		if moved == 0 then return why end
		rec.want = nil
		def.on_cards(rec)
		return nil
	end

	--- the missing ones of `want` (a list of names) for the cards a block has, as a list
	function C.missing_cards(rec, want)
		local have = {}
		for _, name in pairs(rec.cards or {}) do have[name] = (have[name] or 0) + 1 end
		local out = {}
		for _, name in ipairs(want) do
			if (have[name] or 0) > 0 then have[name] = have[name] - 1 else out[#out + 1] = name end
		end
		return out, have
	end
	local missing_cards = C.missing_cards

	--- the wanted cards the block still lacks, taken from the network (one each); rec.want is dropped once nothing is
	--- missing or nothing missing can ever go in
	function C.fill_cards(rec)
		local want = rec.want
		if not want then return end
		local missing = missing_cards(rec, want)
		local net = N.active_of(rec.entity)
		local changed = false
		for _, name in ipairs(missing) do
			local slot = card_fits(rec, name)
			if slot and net and N.count(net, name, "normal") >= 1 and N.extract(net, name, "normal", 1) == 1 then
				install(rec, slot, name)
				changed = true
			end
		end
		local left = missing_cards(rec, want)
		local possible = false
		for _, name in ipairs(left) do if card_fits(rec, name) then possible = true end end
		if not possible then rec.want = nil end
		if changed then def.on_cards(rec, true) end
	end

	--- The block is to have the cards `want` (names; a blueprint, a settings paste, a clone). Cards it has beyond them go
	--- to `player` (inventory, else the network, else the ground at the player); missing ones come from the player's
	--- inventory, then from the network, else the block waits for them (rec.want). `player` nil: only the network.
	function C.want_cards(entity, want, player)
		local rec = def.rec_of(entity)
		if not rec then return false end
		local inv = inv_of(rec)
		local rules = def.rules()
		local list = {}
		for _, name in ipairs(type(want) == "table" and want or {}) do
			if type(name) == "string" and N.card_kind(name) and #list < rules.slots then list[#list + 1] = name end
		end
		--- what is too many goes first (so the limits leave room for the wanted ones)
		local _, extra = missing_cards(rec, list)
		local net = N.active_of(entity)
		local pinv = player and player.valid and G.player_inventory(player)
		for slot = 1, rules.slots do
			local name = rec.cards and rec.cards[slot]
			local stack = inv[slot]
			if name and (extra[name] or 0) > 0 and stack.valid_for_read then
				extra[name] = extra[name] - 1
				rec.cards[slot] = nil
				local got = pinv and pinv.insert(stack) or 0
				if got >= stack.count then stack.clear() end
				if stack.valid_for_read and net and N.insert(net, stack.name, stack.quality.name, stack.count) >= stack.count then stack.clear() end
				if stack.valid_for_read then
					if player and player.valid and G.in_remote_view(player) then
						rec.cards[slot] = name                  -- (issue #177: never spilled from remote view: it stays in its slot)
					else
						local where = player and player.valid and player.character and player.character.valid and player.character or entity
						where.surface.spill_item_stack{ position = where.position, stack = stack, allow_belts = false }
						stack.clear()
					end
				end
			end
		end
		for _, name in ipairs(missing_cards(rec, list)) do
			local slot = card_fits(rec, name)
			local from = slot and pinv and pinv.find_item_stack(name)
			if from then install(rec, slot, nil, from) end
		end
		rec.want = #missing_cards(rec, list) > 0 and list or nil
		def.on_cards(rec, true)
		if rec.want then C.fill_cards(rec) end
		def.on_cards(rec)
		return true
	end

	return C
end

return M
