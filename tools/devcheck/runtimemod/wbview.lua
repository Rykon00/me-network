--- Issue #579: the ME Cell Workbench's two inventories (remote `inventories`: the cell's of one slot, the cards' of the cell's card
--- slots) as the tests read the one inventory of before: [1] the cell, [2] and up the cards, # both, and get_item_count,
--- get_contents and is_empty over both; `.cell` and `.cards` are the two inventories themselves.
local WB = "gregtorio-me-workbench"

return function(w)
	local t = w and remote.call(WB, "inventories", w)
	if not t then return nil end
	local cell, cards = t.cell, t.cards
	return setmetatable({
		cell = cell, cards = cards,
		get_item_count = function(name) return cell.get_item_count(name) + cards.get_item_count(name) end,
		is_empty = function() return cell.is_empty() and cards.is_empty() end,
		get_contents = function()
			local out = cell.get_contents()
			for _, c in pairs(cards.get_contents()) do out[#out + 1] = c end
			return out
		end,
	}, {
		__index = function(_, i) if i == 1 then return cell[1] end return cards[i - 1] end,
		__len = function() return 1 + #cards end,
	})
end
