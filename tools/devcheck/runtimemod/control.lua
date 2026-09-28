--- Places every assembling machine that has an item, gives it a recipe and power, then lets
--- the benchmark run the map. Any runtime error in Gregtorio's scripts or the entities fails
--- the run. Results are logged as DEVCHECK-RUNTIME lines.
script.on_init(function()
	local s = game.surfaces[1]
	s.always_day = true
	s.request_to_generate_chunks({ 0, 0 }, 12)
	s.force_generate_chunk_requests()
	local recipe_for = {}
	for rn, r in pairs(prototypes.recipe) do recipe_for[r.category] = recipe_for[r.category] or rn end
	local x, y, placed, with_recipe, fails = -150, -150, 0, 0, {}
	for name, p in pairs(prototypes.get_entity_filtered{ { filter = "type", type = "assembling-machine" } }) do
		if p.items_to_place_this and #p.items_to_place_this > 0 then
			local ok, e = pcall(function()
				return s.create_entity{ name = name, position = { x, y }, force = "player", raise_built = true }
			end)
			if ok and e then
				placed = placed + 1
				for c, _ in pairs(p.crafting_categories) do
					if recipe_for[c] and pcall(function() e.set_recipe(recipe_for[c]) end) then
						with_recipe = with_recipe + 1
						break
					end
				end
				s.create_entity{ name = "electric-energy-interface", position = { x, y + 7 }, force = "player" }
				s.create_entity{ name = "substation", position = { x + 5, y + 7 }, force = "player" }
			else
				fails[#fails + 1] = name .. ": " .. tostring(e)
			end
			x = x + 14
			if x > 150 then x = -150; y = y + 14 end
		end
	end
	log("DEVCHECK-RUNTIME placed=" .. placed .. " with_recipe=" .. with_recipe .. " failed=" .. #fails)
	for _, f in pairs(fails) do log("DEVCHECK-RUNTIME-FAIL " .. f) end
end)
