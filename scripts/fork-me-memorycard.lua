--------------------------------------------------------------------------------
--- ME NETWORK: THE ME MEMORY CARD (issue #561)
---   * AE2's Memory Card as a selection tool (prototypes/cards.lua). **Select** (the normal drag) over ME blocks: the ME block
---     nearest the area's centre is copied onto the card: its entity name and its blueprint tags, made exactly as a blueprint
---     of it makes them (a script blueprint of its tile and the blueprint handler of every module, fork-me-autocraft.lua
---     `tag_blueprint`), so the card carries what a blueprint carries (a provider's patterns, an interface's rows, a bus's
---     filters, a bridge's frequency ...). A select without an ME block empties the card.
---   * **Alt-select**: every block of the copied name in the area (the player's force) takes the tags through the same path as
---     a blueprint pasted over it (scripts/fork-me-pasteover.lua `apply`, issue #383), with the player: a pattern provider's
---     patterns go into its empty slots and are filled from the player's inventory first, then from the network (issue #558,
---     fill_pending: encoded from the inventory, encoded from the network, blank from the inventory, blank from the
---     network); what finds nothing waits and is shown as #558 shows it. A provider's filled slots keep their patterns.
---   * The content is per card: a selection tool has no tags, but a unique item number, so
---     `storage.fork_me_memcard.cards[item_number] = { name, tags, patterns }`; the card's label shows the block and the
---     number of patterns ([entity=...] rich text, no language).
--------------------------------------------------------------------------------

local N = require("scripts.fork-me-network")
local AC = require("scripts.fork-me-autocraft")
local PO = require("scripts.fork-me-pasteover")

local M = {}
M.CARD = "me-memory-card"
local PROVIDER_TAG = "fork_me_provider"

local function state()
	local s = storage.fork_me_memcard
	if not s then
		s = { cards = {} }
		storage.fork_me_memcard = s
	end
	return s
end

local function is_card(stack)
	return stack ~= nil and stack.valid_for_read and stack.name == M.CARD and stack.item_number ~= nil
end

--- the blueprint tags of `entity` (a table, empty when it has none)
function M.tags_of(entity)
	local inv = game.create_inventory(1)
	local bp = inv[1]
	bp.set_stack{ name = "blueprint" }
	local p = entity.position
	local mapping = bp.create_blueprint{ surface = entity.surface, force = entity.force,
		area = { { p.x - 0.1, p.y - 0.1 }, { p.x + 0.1, p.y + 0.1 } } }
	local tags = {}
	if bp.is_blueprint_setup() then
		AC.tag_blueprint(bp, mapping)
		for index, e in pairs(mapping or {}) do
			if e.valid and e.unit_number == entity.unit_number then tags = bp.get_blueprint_entity_tags(index) or {} end
		end
	end
	inv.destroy()
	return tags
end

local function patterns_of(tags)
	local t = tags[PROVIDER_TAG]
	return type(t) == "table" and type(t.patterns) == "table" and table_size(t.patterns) or 0
end

--- what the card holds (nil: empty)
function M.content(stack)
	if not is_card(stack) then return nil end
	return state().cards[stack.item_number]
end

local function tell(player, text)
	if player and player.valid then player.create_local_flying_text{ text = text, create_at_cursor = true } end
end

--- Select: copy the ME block nearest the area's centre onto the card, or empty it. Returns the copied entity (nil: emptied).
function M.copy(stack, entities, area, player)
	if not is_card(stack) then return nil end
	local s = state()
	local cx = area and (area.left_top.x + area.right_bottom.x) / 2 or 0
	local cy = area and (area.left_top.y + area.right_bottom.y) / 2 or 0
	local best, bd
	for _, e in pairs(entities or {}) do
		if e.valid and e.unit_number and N.kind_of(e.name) then
			local d = (e.position.x - cx) ^ 2 + (e.position.y - cy) ^ 2
			if not bd or d < bd or (d == bd and e.unit_number < best.unit_number) then best, bd = e, d end
		end
	end
	if not best then
		s.cards[stack.item_number] = nil
		stack.label = ""                                          -- (the engine refuses nil: "" is no label)
		tell(player, { "fork-me-memcard.cleared" })
		return nil
	end
	local tags = M.tags_of(best)
	local n = patterns_of(tags)
	s.cards[stack.item_number] = { name = best.name, tags = tags, patterns = n }
	stack.label = "[entity=" .. best.name .. "]" .. (n > 0 and (" [item=me-encoded-pattern]" .. n) or "")
	tell(player, n > 0 and { "fork-me-memcard.copied-patterns", best.localised_name, n }
		or next(tags) and { "fork-me-memcard.copied", best.localised_name }
		or { "fork-me-memcard.copied-nothing", best.localised_name })
	return best
end

--- Alt-select: paste the card onto every block of its name among `entities`; `inv` (a test: instead of the player's) the
--- inventory a provider's patterns come from first. Returns the number of blocks.
function M.paste(stack, entities, player, inv)
	local c = M.content(stack)
	if not c then
		tell(player, { "fork-me-memcard.empty" })
		return 0
	end
	local n = 0
	for _, e in pairs(entities or {}) do
		if e.valid and e.name == c.name and (not player or e.force == player.force) then
			if c.tags[PROVIDER_TAG] then
				AC.on_built(e, c.tags, nil, player, inv)
			elseif PO.apply then
				PO.apply(e, c.tags, player)
			end
			n = n + 1
		end
	end
	tell(player, { "fork-me-memcard.pasted", n, prototypes.entity[c.name] and prototypes.entity[c.name].localised_name or c.name })
	return n
end

function M.on_selected(event)
	if event.item ~= M.CARD then return end
	local player = game.get_player(event.player_index)
	if player then M.copy(player.cursor_stack, event.entities, event.area, player) end
end

function M.on_alt_selected(event)
	if event.item ~= M.CARD then return end
	local player = game.get_player(event.player_index)
	if player then M.paste(player.cursor_stack, event.entities, player, nil) end
end

remote.add_interface("gregtorio-me-memorycard", {
	--- (tests) the handlers with a card stack of a script inventory and no player
	copy = function(stack, entities, area) local e = M.copy(stack, entities, area, nil) return e and e.unit_number or nil end,
	paste = function(stack, entities, inv) return M.paste(stack, entities, nil, inv) end,
	content = function(stack) return M.content(stack) end,
	tags_of = function(entity) return M.tags_of(entity) end,
})

return M
