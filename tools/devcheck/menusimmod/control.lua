--- Runs one main menu simulation the way the main menu does: devcheck.py loads the simulation's save
--- with --benchmark for the simulation's length, this mod runs its init chunk once (first tick) and its
--- update chunk every tick. `game.simulation` (the menu camera) only exists in the menu; the chunks get a
--- stand-in for it. An error in a chunk or in a handler it registers stops the benchmark like it stops
--- the menu. Results are logged as DEVCHECK-MENUSIM lines: the force bonuses and the armor of every
--- character at the start, every second the characters (health, shields, equipment energy, enemies
--- around, damage taken by type and source) and every character death with its cause.
local config = require("config")
local sim = prototypes.mod_data["zz-gregtorio-devcheck-menusim"].data[config.name]

local function out(s) log("DEVCHECK-MENUSIM " .. s) end

local function camera_stub()
  local values = { camera_position = { x = 0, y = 0 }, camera_zoom = 1, camera_surface_index = 1 }
  return setmetatable({}, {
    __index = values,
    __newindex = function(_, k, v)
      if k == "camera_position" then v = { x = v.x or v[1], y = v.y or v[2] } end
      values[k] = v
    end,
  })
end

local function compile(code, name)
  if not code or code == "" then return nil end
  local f, err = load(code:gsub("game%.simulation", "__menusim_camera"), "=" .. name)
  if not f then error(name .. " does not compile: " .. err) end
  return f
end

local function characters()
  local list = {}
  for _, surface in pairs(game.surfaces) do
    for _, c in pairs(surface.find_entities_filtered({ type = "character" })) do list[#list + 1] = c end
  end
  return list
end

local function grid_of(c)
  local inv = c.get_inventory(defines.inventory.character_armor)
  local stack = inv and inv[1]
  return stack and stack.valid_for_read and stack.grid or nil
end

local function describe_armor(c)
  local grid = grid_of(c)
  if not grid then return "no armor grid" end
  local counts, names = {}, {}
  for _, e in pairs(grid.equipment) do
    if not counts[e.name] then names[#names + 1] = e.name end
    counts[e.name] = (counts[e.name] or 0) + 1
  end
  table.sort(names)
  local parts = {}
  for _, n in ipairs(names) do parts[#parts + 1] = n .. "=" .. counts[n] end
  return string.format("grid %dx%d, %s; max shield %.0f, max energy %.0f kJ", grid.width, grid.height,
    table.concat(parts, " "), grid.max_shield, (grid.battery_capacity) / 1000)
end

local damage = {}   -- [unit_number] = { ["type/source"] = amount } since the last report

local function report_state()
  for _, c in pairs(characters()) do
    local grid = grid_of(c)
    local enemies = c.surface.count_entities_filtered({ position = c.position, radius = 20, force = "enemy", type = { "unit", "turret", "unit-spawner" } })
    local taken = {}
    for key, amount in pairs(damage[c.unit_number] or {}) do taken[#taken + 1] = string.format("%s %.0f", key, amount) end
    table.sort(taken)
    damage[c.unit_number] = nil
    out(string.format("tick=%d character=%d force=%s pos=%.1f,%.1f health=%.0f/%.0f shield=%.0f/%.0f energy=%.0f/%.0f kJ enemies(20)=%d damage=[%s]",
      game.tick, c.unit_number, c.force.name, c.position.x, c.position.y, c.health, c.max_health,
      grid and grid.shield or 0, grid and grid.max_shield or 0,
      grid and grid.available_in_batteries / 1000 or 0, grid and grid.battery_capacity / 1000 or 0,
      enemies, table.concat(taken, ", ")))
  end
end

local function report_start()
  local force = game.forces.player
  local researched = 0
  for _, t in pairs(force.technologies) do if t.researched then researched = researched + 1 end end
  local bonuses = {}
  for name in pairs(prototypes.ammo_category) do
    local d, s = force.get_ammo_damage_modifier(name), force.get_gun_speed_modifier(name)
    if d ~= 0 or s ~= 0 then bonuses[#bonuses + 1] = string.format("%s damage +%.0f%% speed +%.0f%%", name, d * 100, s * 100) end
  end
  table.sort(bonuses)
  out(string.format("start: %d of %d technologies researched, character health bonus %d, enemy evolution %.2f, peaceful %s",
    researched, #force.technologies, force.character_health_bonus, game.forces.enemy.get_evolution_factor(1),
    tostring(game.surfaces[1].peaceful_mode)))
  out("bonuses: " .. (#bonuses > 0 and table.concat(bonuses, "; ") or "none"))
  for _, c in pairs(characters()) do
    out(string.format("character=%d force=%s max health %.0f, %s", c.unit_number, c.force.name, c.max_health, describe_armor(c)))
  end
end

local update

local function register_logging()
  script.on_nth_tick(60, report_state)
  script.on_nth_tick(1, function() if update then update() end end)
  local character = { { filter = "type", type = "character" } }
  if not script.get_event_handler(defines.events.on_entity_damaged) then
    script.on_event(defines.events.on_entity_damaged, function(e)
      local per = damage[e.entity.unit_number] or {}
      damage[e.entity.unit_number] = per
      local key = e.damage_type.name .. "/" .. (e.cause and e.cause.valid and e.cause.name or "?")
      per[key] = (per[key] or 0) + e.final_damage_amount
    end, character)
  end
  if not script.get_event_handler(defines.events.on_entity_died) then
    script.on_event(defines.events.on_entity_died, function(e)
      out(string.format("DIED tick=%d character=%d force=%s cause=%s damage=%s", game.tick, e.entity.unit_number,
        e.entity.force.name, e.cause and e.cause.valid and e.cause.name or "?", e.damage_type and e.damage_type.name or "?"))
    end, character)
  end
end

local function start()
  __menusim_camera = camera_stub()
  local init = compile(sim.init, "init")
  update = compile(sim.update, "update")
  if init then init() end
  if game.finished or game.finished_but_continuing then
    -- the menu keeps running a simulation after a win (its scripts too), the benchmark does not
    out("game finished by the init chunk; state reset to running, as in the menu")
    game.set_game_state({ game_finished = false })
  end
  register_logging()
  report_start()
  out("init done")
end

script.on_init(function()
  if not sim then
    out("FAIL simulation " .. config.name .. " is not in main_menu_simulations")
    return
  end
  -- the menu runs the init chunk once the save is loaded, so after the mods' on_init and
  -- on_configuration_changed (Gregtorio's resets the technology effects there): on the first tick
  script.on_nth_tick(1, start)
end)
