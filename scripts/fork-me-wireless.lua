--------------------------------------------------------------------------------
--- ME NETWORK: WIRELESS (issues #153, #205 to #210; design: docs/ME-WIRELESS.md, numbers: prototypes/wireless.lua)
---   * ME Wireless Access Point (#205): a member of the network with 4 card slots for Wireless Boosters (scripts/
---     fork-me-cardslots.lua); its range and its power draw follow the boosters (`range_of`, `power_of`; the power through
---     N.power_hooks, recomputed when the cards change). `anchor_for` finds the nearest access point of a network that has a
---     position in range (a loop over the access points, few; at a key press and at the window's refresh, never per tick).
---   * The wireless window (#206): the ME Terminal's (or the ME Pattern Terminal's, #210) window with the access point as its
---     entity. G.reachable lets it through when the player's terminal is linked to the access point's network, the access point
---     has the player in range and the terminal has energy (G.remote_reach); the refresh pays the energy (G.refresh_hooks) and
---     closes the window when one of them is gone. The block windows opened from it (drive, cell) go through the same check.
---   * The Wireless ME Terminal (#207): an item with tags { link = the controller's unit number, energy = J }; the hotkey
---     `fork-me-wireless` opens it (the last mode: terminal or pattern terminal); the open key with the item in the cursor on
---     an access point or a controller links it to that network.
---   * The ME Charger (#208): a member with one slot for a Wireless ME Terminal; once a second (the network's slow step) it adds
---     the charge rate times the time to the item's energy while its network works; its power draw is the charge rate while the
---     item is not full, else its idle draw (N.power_changed when that changes).
---   * The equipment module (#209): a battery piece of the armour's grid; it is used before an item, its energy is the
---     equipment's own (the grid charges it, the window pays from it), its link is the player's (storage, equipment has no tags).
--- State: storage.fork_me_wireless = { aps = { [unit] = { entity, unit, inv, cards, want, where } }, chargers = { [unit] =
--- { entity, unit, inv, where, charging, last } }, players = { [index] = { mode, link, last } } }.
--------------------------------------------------------------------------------

local N = require("scripts.fork-me-network")
local G = require("scripts.fork-me-gui")
local CS = require("scripts.fork-me-cardslots")

local M = {}

local AP, CHARGER, ITEM, MODULE = "me-wireless-access-point", "me-charger", "me-wireless-terminal", "me-wireless-module"
local TAG, BP_TAG = "fork_me_wireless", "fork_me_access_point"
local WIDTH = 400
local MAX_DT = 120                       -- ticks of energy a refresh pays at most (a window that was not refreshed for a while)
M.AP, M.CHARGER, M.ITEM, M.MODULE = AP, CHARGER, ITEM, MODULE

local numbers_cache
local function numbers()
	if not numbers_cache then numbers_cache = prototypes.mod_data["fork-me-network"].data.wireless end
	return numbers_cache
end

local function state()
	local s = storage.fork_me_wireless
	if not s then
		s = { aps = {}, chargers = {}, players = {} }
		storage.fork_me_wireless = s
	end
	return s
end

local function player_state(player)
	local s = state()
	local ps = s.players[player.index]
	if not ps then
		ps = { mode = "terminal" }
		s.players[player.index] = ps
	end
	return ps
end

local function flying(player, key, ...)
	if player.create_local_flying_text then
		player.create_local_flying_text{ text = { "fork-me-wireless." .. key, ... }, create_at_cursor = true }
	end
end

--------------------------------------------------------------------------------
--- the access point (#205)
--------------------------------------------------------------------------------

local function ap_rec(entity)
	if not (entity and entity.valid and entity.name == AP) then return nil end
	local s = state()
	local rec = s.aps[entity.unit_number]
	if not rec then
		rec = { entity = entity, unit = entity.unit_number }
		s.aps[entity.unit_number] = rec
	end
	rec.entity = entity
	return rec
end
M.ap_rec = ap_rec

local cards
cards = CS.new{
	rules = function() return N.card_rules().access_point end,
	title = function(rec) return rec.entity and rec.entity.valid and rec.entity.localised_name or { "entity-name." .. AP } end,
	rec_of = ap_rec,
	on_cards = function(rec) N.power_changed(rec.entity) end,
}
M.cards = cards

local function boosters(rec) return rec and (cards.counts(rec).booster or 0) or 0 end

--- the range (tiles) and the power draw (W) of an access point with `b` boosters
function M.range_of(b)
	local n = numbers()
	return n.base_range + n.range_per_booster * b ^ n.range_exponent
end
function M.power_of(b)
	local n = numbers()
	return n.base_power + n.power_per_booster * b ^ (1 + b / n.power_exponent_divisor)
end

N.power_hooks["access-point"] = function(entity) return M.power_of(boosters(ap_rec(entity))) end

--- the range of an access point entity
function M.ap_range(entity) return M.range_of(boosters(ap_rec(entity))) end

--- The nearest access point of network `net` on `surface` that has `pos` in range, and the distance; nil when there is none
--- or the network does not work.
function M.anchor_for(net, surface, pos)
	if not (net and N.usable(net)) then return nil end
	local s = state()
	local best, best_d, best_r
	for unit, rec in pairs(s.aps) do
		local e = rec.entity
		if e and e.valid then
			if e.surface == surface and N.network_of(e) == net then
				local dx, dy = e.position.x - pos.x, e.position.y - pos.y
				local d = math.sqrt(dx * dx + dy * dy)
				local r = M.range_of(boosters(rec))
				if d <= r and (not best_d or d < best_d) then best, best_d, best_r = e, d, r end
			end
		else
			s.aps[unit] = nil
		end
	end
	return best, best_d, best_r
end

--- the controller (its unit number) of the network of `entity`, nil without exactly one
local function controller_unit(entity)
	local net = entity and entity.valid and N.network_of(entity)
	if not (net and net.status == "ok") then return nil end
	return next(net.controllers)
end

local function controller_of(unit)
	local e = unit and G.entity_by_unit(unit)
	return e and e.valid and N.kind_of(e.name) == "controller" and e or nil
end

--------------------------------------------------------------------------------
--- the terminal item and the module (#207, #209)
--------------------------------------------------------------------------------

--- the data in a Wireless ME Terminal stack: { link, energy } (a copy; a new item: energy 0, no link)
function M.item_data(stack)
	if not (stack and stack.valid_for_read and stack.name == ITEM) then return nil end
	local t = stack.tags
	local d = type(t) == "table" and t[TAG] or nil
	return { link = d and d.link or nil, energy = d and tonumber(d.energy) or 0 }
end

--- write the data back, with the item's description (its network and its charge)
function M.set_item_data(stack, d)
	local t = stack.tags or {}
	t[TAG] = { link = d.link, energy = math.max(0, math.min(numbers().item_buffer, d.energy or 0)) }
	stack.tags = t
	local ctrl = controller_of(d.link)
	stack.custom_description = { "", ctrl and { "fork-me-wireless.item-linked", string.format("[gps=%d,%d,%s]",
		math.floor(ctrl.position.x), math.floor(ctrl.position.y), ctrl.surface.name) } or { "fork-me-wireless.item-unlinked" },
		"\n", { "fork-me-wireless.item-charge", math.floor(100 * t[TAG].energy / numbers().item_buffer) } }
end

--- the player's module (a LuaEquipment in the armour's grid), or nil
local function module_of(player)
	local c = player.character
	local grid = c and c.valid and c.grid
	if not grid then return nil end
	for _, eq in pairs(grid.equipment) do
		if eq.name == MODULE then return eq end
	end
	return nil
end

--- the player's first Wireless ME Terminal stack in their inventory (a linked one first), or nil
local function item_of(player)
	local inv = G.player_inventory(player)
	if not inv then return nil end
	local first
	for i = 1, #inv do
		local st = inv[i]
		if st.valid_for_read and st.name == ITEM then
			local d = M.item_data(st)
			if d.link then return st end
			first = first or st
		end
	end
	return first
end

--- What the player opens the wireless window with: { kind = "module", eq, link, energy } or { kind = "item", stack, link,
--- energy }; the module comes first. nil when the player has neither.
function M.source_of(player)
	local eq = module_of(player)
	if eq then return { kind = "module", eq = eq, link = player_state(player).link, energy = eq.energy } end
	local st = item_of(player)
	if st then
		local d = M.item_data(st)
		return { kind = "item", stack = st, link = d.link, energy = d.energy }
	end
	return nil
end

--- `joules` out of the source (never below 0); returns the energy left
function M.drain(src, joules)
	if src.kind == "module" then
		src.eq.energy = math.max(0, src.eq.energy - joules)
		src.energy = src.eq.energy
	else
		local d = M.item_data(src.stack)
		d.energy = math.max(0, d.energy - joules)
		M.set_item_data(src.stack, d)
		src.energy = d.energy
	end
	return src.energy
end

--- where the player is for the range: the character (also in remote view), else the player's position
local function where(player)
	local c = player.character
	if c and c.valid then return c.surface, c.position end
	return player.surface, player.position
end

--- Link the item in `stack` (or, `stack` nil, the player's module) to the network of `entity` (an access point or a
--- controller). Returns true, or nil and a reason.
function M.link(player, entity, stack)
	local unit = controller_unit(entity)
	if not unit then return nil, "no-network" end
	if stack then
		local d = M.item_data(stack)
		if not d then return nil, "no-terminal" end
		d.link = unit
		M.set_item_data(stack, d)
	else
		player_state(player).link = unit
	end
	return true
end

--- Can `player` use the window of access point `ap` wirelessly now? true and the source, the distance and the range, or nil
--- and a reason ("no-terminal", "not-linked", "other-network", "empty", "out-of-range", "no-network").
function M.check(player, ap)
	local src = M.source_of(player)
	if not src then return nil, "no-terminal" end
	if not src.link then return nil, "not-linked" end
	local ctrl = controller_of(src.link)
	if not ctrl then return nil, "link-lost" end
	local net = N.network_of(ctrl)
	if not (net and N.usable(net)) then return nil, "no-network" end
	if ap and N.network_of(ap) ~= net then return nil, "other-network" end
	if src.energy <= 0 then return nil, "empty" end
	local surface, pos = where(player)
	if ap then
		if ap.surface ~= surface then return nil, "out-of-range" end
		local dx, dy = ap.position.x - pos.x, ap.position.y - pos.y
		local d, r = math.sqrt(dx * dx + dy * dy), M.ap_range(ap)
		if d > r then return nil, "out-of-range" end
		return true, src, d, r
	end
	local found, d, r = M.anchor_for(net, surface, pos)
	if not found then return nil, "out-of-range" end
	return found, src, d, r
end

--- the wireless window's reach (G.remote_reach)
G.remote_reach[#G.remote_reach + 1] = function(player, anchor)
	if not (anchor and anchor.valid and anchor.name == AP) then return false end
	return M.check(player, anchor) == true
end

--- what an open window uses (W): the source's use times 1 + distance / range
function M.use_rate(src, d, r)
	local n = numbers()
	return (src.kind == "module" and n.module_use or n.item_use) * (1 + (d or 0) / math.max(1, r or 1))
end

--- the refresh of a wireless window (G.refresh_hooks): pay the energy since the last refresh; out of range, empty or no longer
--- linked: the window closes with the reason
G.refresh_hooks[#G.refresh_hooks + 1] = function(player, frame)
	local anchor = G.entity_by_unit(frame.tags.via) or G.entity_by_unit(frame.tags.unit)
	if not (anchor and anchor.valid and anchor.name == AP) or player.can_reach_entity(anchor) then return true end
	local ok, src, d, r = M.check(player, anchor)
	if not ok then
		flying(player, "closed-" .. src)
		return false
	end
	local ps = player_state(player)
	local dt = math.min(MAX_DT, game.tick - (ps.last or game.tick))
	ps.last = game.tick
	if dt > 0 and M.drain(src, M.use_rate(src, d, r) * dt / 60) <= 0 then
		flying(player, "closed-empty")
		return false
	end
	return true
end

--- The hotkey: the wireless window of the player's module or item, in its last mode; again while it is open: it closes. With
--- the module and an access point or a controller under the cursor the module is linked first.
function M.open_for(player)
	local frame = G.window_of(player)
	local anchor = frame and (G.entity_by_unit(frame.tags.via) or G.entity_by_unit(frame.tags.unit))
	if anchor and anchor.valid and anchor.name == AP then
		G.close_window(player)
		return true
	end
	local src = M.source_of(player)
	local sel = player.selected
	if src and src.kind == "module" and sel and sel.valid and (sel.name == AP or N.kind_of(sel.name) == "controller") then
		local ok, why = M.link(player, sel, nil)
		flying(player, ok and "linked" or ("refused-" .. why))
	end
	local ap, why = M.check(player, nil)
	if not ap then
		flying(player, "refused-" .. why)
		return false
	end
	local ps = player_state(player)
	ps.last = game.tick
	G.open(ps.mode == "pattern" and "pattern-terminal" or "terminal", player, ap)
	return true
end

script.on_event("fork-me-wireless", function(event)
	local player = game.get_player(event.player_index)
	if player then M.open_for(player) end
end)

--- the open key with a Wireless ME Terminal in the cursor on an access point or a controller: it is linked to that network
G.open_key_hooks[#G.open_key_hooks + 1] = function(player, entity)
	local cursor = player.cursor_stack
	if not (cursor and cursor.valid_for_read and cursor.name == ITEM) then return false end
	if not (entity.name == AP or N.kind_of(entity.name) == "controller") then return false end
	local ok, why = M.link(player, entity, cursor)
	flying(player, ok and "linked" or ("refused-" .. why))
	return true
end

--- the mode switch of the wireless window: the other window on the same access point
G.on("wl_mode", function(event, player, el)
	if event.name ~= defines.events.on_gui_click then return end
	local frame = G.window_of(player)
	local ap = frame and G.entity_of(player, frame)
	if not (ap and ap.name == AP) then return end
	local ps = player_state(player)
	ps.mode = el.tags.mode == "pattern" and "pattern" or "terminal"
	G.open(ps.mode == "pattern" and "pattern-terminal" or "terminal", player, ap)
end)

--- the mode button of a wireless window (the terminal and the pattern terminal add it when their entity is an access point)
function M.mode_button(parent, entity, to)
	if not (entity and entity.valid and entity.name == AP) then return end
	parent.add{ type = "button", caption = { "fork-me-wireless.mode-" .. to }, tooltip = { "fork-me-wireless.mode-tooltip" },
		tags = G.act("wl_mode", { mode = to }) }
end
G.wireless_mode_button = M.mode_button

--------------------------------------------------------------------------------
--- the charger (#208)
--------------------------------------------------------------------------------

local function charger_rec(entity)
	if not (entity and entity.valid and entity.name == CHARGER) then return nil end
	local s = state()
	local rec = s.chargers[entity.unit_number]
	if not rec then
		rec = { entity = entity, unit = entity.unit_number }
		s.chargers[entity.unit_number] = rec
	end
	rec.entity = entity
	if not (rec.inv and rec.inv.valid) then rec.inv = game.create_inventory(1, { "entity-name." .. CHARGER }) end
	rec.where = { surface = entity.surface.index, x = entity.position.x, y = entity.position.y }
	return rec
end
M.charger_rec = charger_rec

--- does the charger charge (an item that is not full)? Its power draw follows (N.power_changed when it changes)
local function settle_charger(rec)
	local d = M.item_data(rec.inv[1])
	local charging = d ~= nil and d.energy < numbers().item_buffer
	if charging ~= (rec.charging == true) then
		rec.charging = charging or nil
		N.power_changed(rec.entity)
	end
	rec.last = rec.last or game.tick
end

N.power_hooks["charger"] = function(entity)
	local rec = state().chargers[entity.unit_number]
	return (rec and rec.charging) and numbers().charge_rate or numbers().charger_idle
end

--- one charging step of every charger (the network's slow step, once a second; few chargers): the charge rate times the time
--- since the last step goes into the item while the network works
function M.charge_step()
	local s = storage.fork_me_wireless
	if not s then return end
	for unit, rec in pairs(s.chargers) do
		local e = rec.entity
		if not (e and e.valid) then
			s.chargers[unit] = nil
		elseif rec.charging then
			local dt = math.min(MAX_DT, game.tick - (rec.last or game.tick))
			rec.last = game.tick
			local net = N.network_of(e)
			local st = rec.inv[1]
			local d = M.item_data(st)
			if d and dt > 0 and net and N.usable(net) then
				d.energy = d.energy + numbers().charge_rate * dt / 60
				M.set_item_data(st, d)
			end
			settle_charger(rec)
		else
			rec.last = game.tick
		end
	end
end
N.slow_hooks[#N.slow_hooks + 1] = M.charge_step

--- A click on the charger's slot: a Wireless ME Terminal in the cursor goes in, a click with an empty cursor takes it (shift:
--- into `inventory`). Returns the reason of a refusal.
function M.charger_click(entity, cursor, inventory, shift)
	local rec = charger_rec(entity)
	if not rec then return "no-target" end
	local slot = rec.inv[1]
	if cursor and cursor.valid_for_read then
		if cursor.name ~= ITEM then return "not-a-terminal" end
		if slot.valid_for_read then return "charger-full" end
		slot.transfer_stack(cursor)
	elseif slot.valid_for_read then
		if shift then
			if not (inventory and inventory.valid) then return "no-inventory" end
			if inventory.insert(slot) < 1 then return "inventory-full" end
			slot.clear()
		elseif not (cursor and cursor.transfer_stack(slot)) then
			return "inventory-full"
		end
	end
	rec.last = game.tick
	settle_charger(rec)
	return nil
end

--- shift + click on a Wireless ME Terminal in the player's inventory in the charger's window: into the slot
function M.charger_shift_in(entity, stack)
	local rec = charger_rec(entity)
	if not rec then return "no-target" end
	if not (stack and stack.valid_for_read and stack.name == ITEM) then return "not-a-terminal" end
	if rec.inv[1].valid_for_read then return "charger-full" end
	rec.inv[1].transfer_stack(stack)
	rec.last = game.tick
	settle_charger(rec)
	return nil
end

--- the charge of the item in a charger (0..1), nil when it is empty
function M.charger_info(entity)
	local rec = charger_rec(entity)
	local d = rec and M.item_data(rec.inv[1])
	local net = entity and entity.valid and N.network_of(entity)
	return { charge = d and d.energy / numbers().item_buffer or nil, charging = rec and rec.charging == true or false,
		network = net ~= nil and (N.usable(net)) or false, linked = d and d.link ~= nil or false }
end

--------------------------------------------------------------------------------
--- events: built, removed, settings paste, blueprints (control.lua calls them)
--------------------------------------------------------------------------------

local function spill_inv(inv, rec, buffer)
	local e = rec.entity
	local surface, pos
	if e and e.valid then surface, pos = e.surface, e.position
	elseif rec.where then surface, pos = game.get_surface(rec.where.surface), { rec.where.x, rec.where.y } end
	for i = 1, #inv do
		local st = inv[i]
		if st.valid_for_read then
			local got = buffer and buffer.valid and buffer.insert(st) or 0
			if got >= st.count then st.clear() elseif got > 0 then st.count = st.count - got end
			if st.valid_for_read and surface then
				surface.spill_item_stack{ position = pos, stack = st, allow_belts = false }
				st.clear()
			end
		end
	end
end

--- built, revived or cloned (`tags`: blueprint tags, `source`: the original of a clone): an access point wants the source's
--- boosters (from the network, never from nothing); a charger starts empty
function M.on_built(entity, tags, source)
	if not (entity and entity.valid) then return end
	if entity.name == CHARGER then charger_rec(entity) return end
	if entity.name ~= AP then return end
	ap_rec(entity)
	local list
	local t = type(tags) == "table" and tags[BP_TAG]
	if type(t) == "table" and type(t.cards) == "table" then list = t.cards
	elseif source and source.valid and source.name == AP then
		local from = ap_rec(source)
		list = from.want and { table.unpack(from.want) } or cards.card_list(from)
	end
	if list and #list > 0 then cards.want_cards(entity, list, nil) end
	N.power_changed(entity)
end

--- mined (`buffer`: the boosters and the charger's item go there) or destroyed (nil: spilled where it stood)
function M.on_removed(entity, buffer)
	if not (entity and entity.valid and entity.unit_number) then return end
	local s = storage.fork_me_wireless
	if not s then return end
	local unit = entity.unit_number
	if entity.name == AP and s.aps[unit] then
		local rec = s.aps[unit]
		if buffer and buffer.valid then cards.give_cards(rec, buffer) else cards.spill_cards(rec) end
		cards.detach(rec)
		s.aps[unit] = nil
	elseif entity.name == CHARGER and s.chargers[unit] then
		local rec = s.chargers[unit]
		if rec.inv and rec.inv.valid then
			spill_inv(rec.inv, rec, buffer)
			rec.inv.destroy()
		end
		s.chargers[unit] = nil
	end
end

--- a member that vanished without an event (the network's sweep): what it held is spilled where it stood
N.vanish_hooks[#N.vanish_hooks + 1] = function(unit)
	local s = storage.fork_me_wireless
	if not s then return end
	local ap = s.aps[unit]
	if ap then
		cards.detach(ap)
		s.aps[unit] = nil
	end
	local ch = s.chargers[unit]
	if ch then
		if ch.inv and ch.inv.valid then
			spill_inv(ch.inv, ch, nil)
			ch.inv.destroy()
		end
		s.chargers[unit] = nil
	end
end

--- settings paste between access points: the source's boosters are wanted (from the player, then the network)
function M.on_entity_settings_pasted(event)
	local src, dst = event.source, event.destination
	if not (src and src.valid and dst and dst.valid and src.name == AP and dst.name == AP) then return end
	local from = ap_rec(src)
	local player = event.player_index and game.get_player(event.player_index) or nil
	cards.want_cards(dst, from.want and { table.unpack(from.want) } or cards.card_list(from) or {}, player)
end

--- blueprints: an access point carries its boosters
function M.tag_blueprint(bp, mapping)
	for index, entity in pairs(mapping) do
		if entity.valid and entity.name == AP then
			local rec = ap_rec(entity)
			local list = rec.want and { table.unpack(rec.want) } or cards.card_list(rec)
			if list then bp.set_blueprint_entity_tag(index, BP_TAG, { cards = list }) end
		end
	end
end

--- after a mod update: the records of entities that are gone are dropped
function M.on_configuration_changed()
	numbers_cache = nil
	local s = state()
	for unit, rec in pairs(s.aps) do if not (rec.entity and rec.entity.valid) then s.aps[unit] = nil end end
	for unit, rec in pairs(s.chargers) do if not (rec.entity and rec.entity.valid) then s.chargers[unit] = nil end end
end

--------------------------------------------------------------------------------
--- the windows of the access point and the charger
--------------------------------------------------------------------------------

local function window_entity(player)
	local frame = G.window_of(player)
	return frame and G.entity_of(player, frame)
end

local function open_ap(player, entity)
	local _, content = G.open_window(player, "access-point", entity.localised_name, { unit = entity.unit_number })
	G.label(content, { "fork-me-wireless.ap-help" }, WIDTH)
	local row = G.row(content)
	row.add{ type = "label", caption = { "fork-me-gui.cards" }, tooltip = { "fork-me-wireless.ap-cards-tooltip" } }
	row.add{ type = "flow", name = "fork_me_ap_cards", direction = "horizontal" }
	G.label(content, "", WIDTH, nil, "fork_me_ap_want")
	G.label(content, "", WIDTH, nil, "fork_me_ap_info")
	G.label(content, "", WIDTH, nil, "fork_me_ap_status")
	M.refresh_ap(player, G.window_of(player))
end

function M.refresh_ap(player, frame)
	local entity = G.entity_of(player, frame)
	local rec = ap_rec(entity)
	if not rec then return false end
	local inv = cards.inv_of(rec)
	local box = G.find(frame, "fork_me_ap_cards")
	local sig = {}
	for i = 1, #inv do sig[i] = inv[i].valid_for_read and inv[i].name or "-" end
	sig = table.concat(sig, ",")
	if box.tags.sig ~= sig then
		box.clear()
		box.tags = { sig = sig }
		for i = 1, #inv do
			G.stack_button(box, inv[i], G.act("block_slot", { slot = i }),
				{ inv[i].valid_for_read and "fork-me-gui.card-slot-tooltip" or "fork-me-gui.card-slot-empty" })
		end
	end
	local want = {}
	for _, name in ipairs(rec.want and cards.missing_cards(rec, rec.want) or {}) do want[#want + 1] = "[item=" .. name .. "]" end
	G.find(frame, "fork_me_ap_want").caption = #want > 0 and { "fork-me-gui.cards-wanted", table.concat(want, " ") } or ""
	local b = boosters(rec)
	G.find(frame, "fork_me_ap_info").caption = { "fork-me-wireless.ap-info", b, string.format("%.0f", M.range_of(b)),
		G.fmt_power(M.power_of(b)) }
	local net = N.network_of(entity)
	local ok, why = N.usable(net)
	G.find(frame, "fork_me_ap_status").caption = { "fork-me-net.status-" .. (ok and "ok" or (why or "no-network")) }
	return true
end

G.window("access-point", { open = open_ap, refresh = function(player, frame) return M.refresh_ap(player, frame) end,
	entities = { "access-point" }, hint = { "fork-me-wireless.ap-pane-hint" },
	shift = function(entity, stack) return cards.shift_in(entity, stack) end,
	click = function(entity, slot, cursor, inv, shift) return cards.card_click(entity, slot, cursor, inv, shift) end,
	message = function(why) return { "fork-me-gui.refused-" .. why } end })

local function open_charger(player, entity)
	charger_rec(entity)
	local _, content = G.open_window(player, "charger", entity.localised_name, { unit = entity.unit_number })
	G.label(content, { "fork-me-wireless.charger-help" }, WIDTH)
	local row = G.row(content)
	row.add{ type = "sprite-button", name = "fork_me_charger_slot", style = "slot_button", tags = G.act("block_slot", { slot = 1 }) }
	G.label(row, "", WIDTH - 50, nil, "fork_me_charger_info")
	M.refresh_charger(player, G.window_of(player))
end

function M.refresh_charger(player, frame)
	local entity = G.entity_of(player, frame)
	local rec = charger_rec(entity)
	if not rec then return false end
	G.render_slot(G.find(frame, "fork_me_charger_slot"), rec.inv[1], nil, { "fork-me-wireless.charger-slot-tooltip" })
	local i = M.charger_info(entity)
	G.find(frame, "fork_me_charger_info").caption = i.charge and { "fork-me-wireless.charger-charge", math.floor(100 * i.charge),
		{ i.charging and (i.network and "fork-me-wireless.charger-charging" or "fork-me-wireless.charger-no-power")
			or "fork-me-wireless.charger-full" } } or { "fork-me-wireless.charger-empty" }
	return true
end

G.window("charger", { open = open_charger, refresh = function(player, frame) return M.refresh_charger(player, frame) end,
	entities = { "charger" }, hint = { "fork-me-wireless.charger-pane-hint" },
	shift = function(entity, stack) return M.charger_shift_in(entity, stack) end,
	click = function(entity, _, cursor, inv, shift) return M.charger_click(entity, cursor, inv, shift) end,
	message = function(why) return { "fork-me-wireless.refused-" .. why } end })

--------------------------------------------------------------------------------
--- the remote interface (the runtime test: the functions the hotkey, the clicks and the steps call)
--------------------------------------------------------------------------------

remote.add_interface("gregtorio-me-wireless", {
	range_of = function(b) return M.range_of(b) end,
	power_of = function(b) return M.power_of(b) end,
	ap_range = function(entity) return M.ap_range(entity) end,
	anchor_for = function(entity, surface, pos) return M.anchor_for(N.network_of(entity), surface, pos) end,
	ap_inventory = function(entity) local r = ap_rec(entity) return r and cards.inv_of(r) or nil end,
	ap_card_click = function(entity, slot, cursor, inventory, shift) return cards.card_click(entity, slot, cursor, inventory, shift) end,
	--- a Wireless ME Terminal stack: its data, linking it (`entity`: an access point or a controller), draining it
	item_data = function(stack) return M.item_data(stack) end,
	set_item_energy = function(stack, joules)
		local d = M.item_data(stack)
		if not d then return false end
		d.energy = joules
		M.set_item_data(stack, d)
		return true
	end,
	link_item = function(stack, entity) return M.link(nil, entity, stack) end,
	drain_item = function(stack, joules) return M.drain({ kind = "item", stack = stack }, joules) end,
	controller_unit = function(entity) return controller_unit(entity) end,
	--- the charger
	charger_click = function(entity, cursor, inventory, shift) return M.charger_click(entity, cursor, inventory, shift) end,
	charger_inventory = function(entity) local r = charger_rec(entity) return r and r.inv or nil end,
	charger_info = function(entity) return M.charger_info(entity) end,
	charge_step = function() M.charge_step() end,
	--- the module: what the window pays from a LuaEquipment (issue #209's check: the engine keeps what the script sets)
	drain_equipment = function(eq, joules) return M.drain({ kind = "module", eq = eq, energy = eq.energy }, joules) end,
	use_rate = function(kind, d, r) return M.use_rate({ kind = kind }, d, r) end,
	numbers = function() return numbers() end,
	on_removed = function(entity, buffer) M.on_removed(entity, buffer) end,
	built = function(entity, tags, source) M.on_built(entity, tags, source) end,
	paste = function(source, destination) M.on_entity_settings_pasted{ source = source, destination = destination } end,
})

return M
