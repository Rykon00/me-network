--- The main menu simulations as the game shows them after every mod: copied into a mod-data prototype,
--- which control.lua reads, and listed in the log for devcheck.py (save file and length of each).
local list = data.raw["utility-constants"]["default"].main_menu_simulations or {}
local copy = {}
local names = {}
for name, sim in pairs(list) do
  copy[name] = { save = sim.save, length = sim.length, init = sim.init, update = sim.update }
  names[#names + 1] = name
end
table.sort(names)
local lines = { "DEVCHECK-MENUSIMS-BEGIN" }
for _, name in ipairs(names) do
  lines[#lines + 1] = table.concat({ name, list[name].save or "", tostring(list[name].length or 0) }, "\t")
end
lines[#lines + 1] = "DEVCHECK-MENUSIMS-END"
log("\n" .. table.concat(lines, "\n"))
data:extend({ { type = "mod-data", name = "zz-gregtorio-devcheck-menusim", data = copy } })
