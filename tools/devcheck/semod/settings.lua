--- issue #706: `devcheck.py launch` turns this on: the steps of control.lua do not run by the tick, the harness drives a
--- real spaceship launch through RCON (the remote interface "me-se-launch")
data:extend({ { type = "bool-setting", name = "zz-me-se-real-launch", setting_type = "startup", default_value = false } })
