--- Test fixture of the benchmark (never part of me-network): a container with as many slots as the warehouses of
--- storage mods, for the profile of a storage bus on a big chest.
local chest = table.deepcopy(data.raw.container["steel-chest"])
chest.name = "zz-bench-warehouse"
chest.inventory_size = 800
chest.minable = nil
chest.next_upgrade = nil
chest.fast_replaceable_group = nil
data:extend({ chest })

--- a tank of 1 000 000 units: the source and sink of the fluid capacity probes
local tank = table.deepcopy(data.raw["storage-tank"]["storage-tank"])
tank.name = "zz-bench-big-tank"
tank.fluid_box.volume = 1000000
tank.minable = nil
tank.next_upgrade = nil
tank.fast_replaceable_group = nil
data:extend({ tank })
