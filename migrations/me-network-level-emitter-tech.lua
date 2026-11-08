--- Issue #679: the ME Level Emitter and the ME Circuit Interface moved from ME Automation to the new technology ME Level
--- Emitter (its prerequisite). A force that researched ME Automation gets the new technology researched as well, so nothing it
--- had is locked behind a technology it skipped (on_configuration_changed resets the technology effects afterwards).
for _, force in pairs(game.forces) do
	local auto, emitter = force.technologies["me-automation"], force.technologies["me-level-emitter"]
	if auto and emitter and auto.researched and not emitter.researched then emitter.researched = true end
end
