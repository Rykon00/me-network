--- Issue #710 (the test CHANCE of control.lua): a quick recipe of Space Exploration's core fragment processing whose second
--- product comes at 50 %: 2 stone into an iron stick and, by chance, an iron gear wheel. (A real fragment recipe takes 20 s.)
data:extend({ {
	type = "recipe", name = "zz-me-se-chance", categories = { "core-fragment-processing" }, energy_required = 0.5, enabled = true,
	ingredients = { { type = "item", name = "stone", amount = 2 } },
	results = { { type = "item", name = "iron-stick", amount = 1 },
		{ type = "item", name = "iron-gear-wheel", amount = 1, independent_probability = 0.5 } },
	main_product = "iron-stick", icon = "__base__/graphics/icons/signal/signal-info.png", subgroup = "intermediate-product",
} })
