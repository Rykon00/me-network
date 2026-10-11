--- ME Network: an ME storage network with autocrafting and fluids, inspired by Applied Energistics 2.

--- Gregtorio Continued before 0.5.0 contains this network itself (same prototypes, same scripts). It does not depend
--- on this mod, so it loads first and has made the mod-data "fork-me-network" by now: refuse to run both.
if data.raw["mod-data"] and data.raw["mod-data"]["fork-me-network"] then
	error("\n\nME Network: this version of Gregtorio Continued (before 0.5.0) contains its own ME network.\n"
		.. "Update Gregtorio Continued to 0.5.0 or later (it hands its ME network over to ME Network), or disable ME Network.\n")
end

require("prototypes.api")
require("prototypes.network")
require("prototypes.autocrafting")
require("prototypes.fluids")
require("prototypes.cards")
require("prototypes.wireless")
