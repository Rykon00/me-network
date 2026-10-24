--- Issue #503: test items that a "dependent mod" (this helper) removes and renames between the save and the load (settings.lua)
local stage = settings.startup["zz-me-network-devcheck-migrate-items"].value
local function item(name)
	data:extend({ { type = "item", name = name, icon = "__base__/graphics/icons/iron-gear-wheel.png", icon_size = 64,
		stack_size = 100, subgroup = "intermediate-product", order = "zz[devcheck]-" .. name } })
end
if stage ~= "none" then
	item("devcheck-new-item")
	if stage == "old" then
		item("devcheck-renamed-item")
		item("devcheck-removed-item")
	elseif ME_NETWORK.replace_item then
		ME_NETWORK.replace_item("devcheck-renamed-item", "devcheck-new-item")
	end
end
