--------------------------------------------------------------------------------
--- ME NETWORK: THE WIRELESS REFILL (issue #603; the maintainer's decisions of 2026-10-29 on the issue)
---   A player who wears the ME Wireless Module (scripts/fork-me-wireless.lua) and stands inside the range of an access point
---   of the network the module is linked to gets the game's personal logistics from the ME network, without a window:
---   * the list is the game's own: the requests of the character's logistic sections (their minimums, the compiled filters of
---     its requester point) and its trash slots. A character whose force has no personal logistics yet (not researched) or
---     whose player switched personal logistics off gets nothing;
---   * a request below its minimum gets what it lacks from the network, at most one stack per request and visit; every stack
---     in the trash slots goes into the network;
---   * every item moved costs energy from the network's controllers (NUMBERS.refill_energy J, mod data "fork-me-network",
---     wireless; AE2's 1 AE per item of Platform.poweredExtraction): what the controllers hold beyond one tick of their draw
---     pays for it, and what it cannot pay for does not move;
---   * the network serves first: robots only bring what is still missing after a visit (no setting).
---   The visits are a queue of the scheduler (scripts/fork-me-schedule.lua, tag "wireless_refill"): one record per player
---   (unit = the player index) whose character has the module, made when the module is put into the armour, when the player
---   joins or respawns and on a configuration change, forgotten when the module, the player or the character is gone. Its
---   budget: the map settings "wireless refill visits per tick" (at least / at most). A visit that moved something comes back
---   after ACTIVE_TICKS, one that found nothing to do after IDLE_TICKS, one outside every range or without logistics after
---   AWAY_TICKS. Counts, never measured time.
--- State: storage.fork_me_wireless.refill = { q = the queue, recs = { [unit] = { unit, character?, link? } } } (a record with
--- `character` stands for a character without a player: the tests and the benchmark).
--------------------------------------------------------------------------------

local N = require("scripts.fork-me-network")
local Sched = require("scripts.fork-me-schedule")
local W = require("scripts.fork-me-wireless")

local M = {}

local TAG = "wireless_refill"
local ACTIVE_TICKS = 30                 -- a visit that moved something: the next one about half a second later
local IDLE_TICKS = 120                  -- one that found nothing to do
local AWAY_TICKS = 300                  -- outside every access point's range, no link, no logistics, no network
local SPREAD = 8                        -- ticks a visit may come sooner or later (Sched.slot)
M.ACTIVE_TICKS, M.IDLE_TICKS, M.AWAY_TICKS = ACTIVE_TICKS, IDLE_TICKS, AWAY_TICKS

local energy_cache
local function energy_per_item()
	if not energy_cache then energy_cache = prototypes.mod_data["fork-me-network"].data.wireless.refill_energy end
	return energy_cache
end

local function state()
	local w = W.state()
	local s = w.refill
	if not s then
		s = { q = Sched.new(TAG), recs = {} }
		w.refill = s
	end
	return s
end

local function rec_of(unit)
	local s = storage.fork_me_wireless and storage.fork_me_wireless.refill
	return s and s.recs[unit]
end

--- the character a record stands for, and the controller unit its module is linked to
local function character_of(rec)
	if rec.character then return rec.character.valid and rec.character or nil, rec.link end
	local player = game.get_player(rec.unit)
	local c = player and player.connected and player.character
	return c and c.valid and c or nil, player and W.module_link(player)
end

local function has_module(character)
	local grid = character.grid
	return grid ~= nil and grid.count(W.MODULE) > 0
end

--- `unit` (a record of `s`) comes back in about `iv` ticks
local function again(s, rec, iv)
	Sched.at(s.q, rec, rec.unit, Sched.slot(s.q, false, rec.unit, game.tick, iv, SPREAD, SPREAD))
end

--- what the controllers of `net` can pay for: items at `per` J each, at most `want`
local function affordable(net, per, want)
	if per <= 0 or net.creative then return want end
	return math.min(want, math.floor(N.spare_energy(net) / per))
end

--- `joules` paid by the controllers of `net` (counted in `s.paid`: the tests)
local function pay(s, net, joules)
	s.paid = (s.paid or 0) + N.pay_energy(net, joules)
end

--- One visit of a character: requests filled, trash emptied. Returns the scheduler's class (0: nothing to do, 1: it moved
--- something and something is still missing or left, 2: it moved all it was asked for), the interval until the next visit
--- and the number of items moved.
function M.serve(character, link)
	local s = state()
	if not (character.force.character_logistic_requests and has_module(character)) then return 0, AWAY_TICKS end
	local point = character.get_requester_point()
	if not (point and point.enabled) then return 0, AWAY_TICKS end
	local ctrl = link and W.controller_of(link)
	local net = ctrl and N.network_of(ctrl)
	if not (net and N.usable(net)) then return 0, AWAY_TICKS end
	if not W.anchor_for(net, character.surface, character.position) then return 0, AWAY_TICKS end
	local per = energy_per_item()
	local main = character.get_inventory(defines.inventory.character_main)
	local moved, short = 0, false
	--- the requests (the compiled filters: one entry per item and quality with the sections' minimums added up)
	for _, f in pairs(point.filters or {}) do
		if f.name and (f.type == nil or f.type == "item") and (f.count or 0) > 0 and prototypes.item[f.name] then
			local q = f.quality or "normal"
			local lack = f.count - main.get_item_count{ name = f.name, quality = q }
			local cursor = character.cursor_stack
			if cursor and cursor.valid_for_read and cursor.name == f.name and cursor.quality.name == q then lack = lack - cursor.count end
			if lack > 0 then
				local want = math.min(lack, prototypes.item[f.name].stack_size)
				local can = affordable(net, per, want)
				local got = can > 0 and N.extract(net, f.name, q, can) or 0
				if got > 0 then
					local n = main.insert{ name = f.name, quality = q, count = got }
					if n < got then N.insert(net, f.name, q, got - n) end      -- (no room: back into the network)
					if n > 0 then
						pay(s, net, n * per)
						moved = moved + n
					end
					if n < want then short = true end
				else
					short = true
				end
			end
		end
	end
	--- the trash slots
	local trash = character.get_inventory(defines.inventory.character_trash)
	for i = 1, trash and #trash or 0 do
		local stack = trash[i]
		if stack.valid_for_read then
			local max = affordable(net, per, stack.count)
			local n = max > 0 and N.insert_partial(net, stack, max) or nil
			if n and n > 0 then
				pay(s, net, n * per)
				moved = moved + n
			end
			if stack.valid_for_read then short = true end
		end
	end
	if moved == 0 then return 0, IDLE_TICKS, 0 end
	return short and 1 or 2, ACTIVE_TICKS, moved
end

--- the scheduler's visit of `unit`
local function visit(rec, unit)
	local s = state()
	local character, link = character_of(rec)
	if not (character and has_module(character)) then
		Sched.forget(s.q, rec)
		s.recs[unit] = nil
		return 0
	end
	local class, iv = M.serve(character, link)
	again(s, rec, iv)
	return class
end

--- `unit` (a player index, or a character's record) is scheduled at once: the module went in, the player came back
function M.add(unit, character, link)
	local s = state()
	local rec = s.recs[unit]
	if not rec then
		rec = { unit = unit }
		s.recs[unit] = rec
	end
	rec.character, rec.link = character, link
	Sched.wake(s.q, rec, unit)
end

--- the player's record when their character has the module (events: placed or removed equipment, joined, respawned)
function M.update_player(player)
	if not (player and player.valid) then return end
	local c = player.character
	if c and c.valid and has_module(c) then M.add(player.index) end
end

function M.on_tick(tick)
	local s = storage.fork_me_wireless and storage.fork_me_wireless.refill
	if s and next(s.recs) then
		Sched.run(s.q, tick, Sched.setting("wireless_refill"), Sched.setting("wireless_refill_max"), rec_of, visit, nil, TAG)
	end
end

--- every player with the module gets a record (on_init, on_configuration_changed: a save from before the refill)
function M.on_configuration_changed()
	if not storage.fork_me_wireless then return end
	for _, player in pairs(game.players) do M.update_player(player) end
end

--- the tests and the benchmark (remote gregtorio-me-wireless): a character without a player as a record of the queue, linked to
--- the network of `ctrl`; one visit now (the items moved); the energy paid so far; the energy per item
function M.add_character(character, ctrl)
	M.add(-character.unit_number, character, ctrl.unit_number)
	return -character.unit_number
end
function M.visit_now(unit)
	local rec = rec_of(unit)
	if not rec then return nil end
	local character, link = character_of(rec)
	if not character then return nil end
	local _, _, moved = M.serve(character, link)
	return moved or 0
end
function M.paid() return state().paid or 0 end
M.energy_per_item = energy_per_item

return M
