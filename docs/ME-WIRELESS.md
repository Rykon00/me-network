# Wireless ME Terminal: design note (issue #153)

Status: **design only, no code.** The decisions of 2026-10-06 and the confirmation of 2026-10-08 are fixed; the work is split
into the issues named in the last section.

## Fixed by the maintainer

- Trigger: a **Wireless Terminal item** and a **power-armour equipment module**, each opened by a rebindable hotkey.
- Range: a **Wireless Access Point** with a range that **boosters** extend (AE2's idea), a network member that draws its power
  through the controller.
- Power: the **item has an energy buffer** (in its tags); the **module** takes its energy from the armour's equipment grid.
- **One item with a mode switch** (terminal / pattern terminal); the module follows the same rule.

## What AE2-Unofficial does (read, not copied; LGPL, a port would be written anew)

From `core/AEConfig.java`, `tile/networking/TileWireless.java`, `helpers/WirelessTerminalGuiObject.java`,
`items/tools/powered/ToolWirelessTerminal.java`:

- A Wireless Access Point holds **one stack of boosters** (0 to 64). Range = `16 + boosters^1.5` blocks; its own power use
  `8 + boosters^(1 + boosters / 64)` AE per tick. The terminal picks the **nearest active access point of its network that
  has it in range** (three-dimensional distance, the same dimension only); no access point in range: no window.
- The terminal item has a **battery of 1 600 000 AE**; using it drains `range x multiplier` per tick while it is open (so a far
  access point costs more), an empty battery closes the window. In the pack an energy card gives it infinite energy.
- A terminal is **bound to one network** by a click on a security terminal; it keeps that link in its tags.
- GTNH's "wireless pattern terminal" is the **Wireless Ultra Terminal** (`ae2fc:wireless_ultra_terminal`, the AE2 Fluid Crafting
  addon): one item that combines the crafting, pattern, interface and level terminals; the quests recommend a keybind.
  That matches the decision (one item, modes).

## What Factorio 2.0 gives us

- **Hotkey**: a `custom-input` with a default key sequence (rebindable in the controls), handled in script
  (`on_custom_input`), like `fork-me-terminal-open` and `fork-me-focus-search` that exist.
- **Item with data**: an `item-with-tags` (like the storage cell) can keep a link and an energy value in its tags; such items
  do not stack. The script finds the item in the player's inventory when the hotkey is pressed (one lookup per key press).
- **Equipment**: a mod can add equipment of the game's types only (`battery-equipment`, `night-vision-equipment`, ...); script
  recognises it by name in `character.grid` and can read and write `LuaEquipment.energy`. A piece of type
  `battery-equipment` is charged by the grid and holds a small buffer: the script **pays for the open window from that
  buffer**. Equipment has no tags, so a link for the module is kept per player in `storage`. (To be confirmed with a prototype:
  how `LuaEquipment.energy` and the grid's charging behave when the script lowers it; this is checked headless in the first step.)
- **No periodic work is needed.** The range is checked at the key press and at the window's existing once-a-second refresh
  (`G.refresh_all`); power is drained there too.

## What has to change in the mod

The windows are tied to an entity (`G.open_window(player, kind, caption, { unit })`, `G.entity_of` also needs
`player.can_reach_entity`). The terminal module (`fork-me-terminal.lua`, about 35 lines that mention the entity, mostly passing it to
`N.network_of`/`problem`) and the pattern terminal (`fork-me-patternterm.lua`, with its own two-slot inventory) work on an
entity.

1. **A terminal handle instead of an entity.** `network(terminal)` and the functions the window calls take a *handle*: an
   entity, or `{ wireless = <controller unit number> }` that `N.network_of` resolves to the network of that controller. The
   controller is the stable name of a network (network ids change on split and merge; a network has exactly one controller). The
   window frame carries the handle in its tags instead of `unit`; `G.entity_of` returns the handle for a wireless frame after
   the range check instead of `can_reach_entity`. The block windows (drive, cell, provider, ...) opened from the terminal keep
   their `via` tag: for a wireless window `via` is the handle and the reach test is the range test.
2. **Range query**: the network keeps the list of its access points (a member kind, kept as members join and leave like the
   other kinds); the check is a loop over them with the player's position (character position, also in remote view): a query by
   position at a key press or a refresh, never per tick.
3. **The pane**: a wireless window uses the mod's own inventory pane (the game's inventory window may not be open when a hotkey
   opens it); with #176 the pane already works from the character's inventory, so the wireless window is the same case.
4. **The wireless pattern terminal** has no block with a blank and an output slot. Proposal: the window encodes from the
   editor as the block does, takes the blank pattern from the network (never from nothing) and puts the encoded pattern **into
   the player's inventory** (what shift + click on Encode does at the block), so no per-player item inventory is needed.
5. **Nothing else changes**: the schedule, the storage engine and the planner do not know about wireless.

## Open points: confirmed by the maintainer on 2026-10-08 (boosters, charging by an ME Charger, linking, the pattern mode)

**Booster numbers (the maintainer asked for AE2's as the start).** AE2's 16 blocks base range fits a Minecraft base; a Factorio base
is wider. Proposal, written as a table so the numbers can be moved: the access point has a card slot row (the generic card code)
for up to 4 **Wireless Boosters**; range `32 + 24 x b^1.5` tiles (b = 0..4: 32, 56, 99, 156, 224); its power draw through the
controller `20 kW + 10 kW x b^(1 + b / 16)` (20, 30, 45, 66, 90 kW). Same dimension (surface) only, nearest active access point.
Cap and prices are one table in mod-data, not scattered.

**Charging the item (decided: an ME Charger block, 2026-10-08).** As in AE2: a 1x1 **ME Charger**, a member of the network that
draws its power through the controller, holds one Wireless Terminal item in a one-slot script inventory (shown in its window,
given back when it is mined, spilled when it is destroyed) and fills the item's energy tag while the network has power. Its
power draw is its charge rate while an item is not full and a small idle draw otherwise; it changes only when an item is put in
or taken out or becomes full (an event, not a tick: the controller's power is recomputed through the existing `power_dirty`).
Numbers to start from (one table in mod-data): item buffer 100 MJ, charge rate 1 MW (a full charge in 100 s), idle 2 kW; use of
the item `0.2 MW` over the distance factor `1 + distance / range` while its window is open. An empty item closes the window
(`G.refresh_all` finds it); nothing is lost, the window only shows the network. The equipment module needs no charger.

**Linking.** The item keeps **one linked network** in its tags (the controller's unit number plus a display name), as AE2's
does; the module keeps one link per player. Linking: the "open GUI" key with the item in the cursor on an access point or a
controller (the way a cell in the cursor goes into a drive today); for the module the hotkey pressed while pointing at an
access point. More than one network: one link at a time, the new link replaces the old one; a list of links is a later step if
asked for.

**The player's real inventory (#150, #168).** The hand-over buffer of #168 is the game's inventory window beside a script
inventory; a hotkey can open that as well (`player.opened = buffer`), and in remote view #176's rule (the pane) applies. So the
wireless window needs no special case; it uses `open_window` like every other.

**Multiplayer.** Two players on one network: each has their own link and window; the network is one object, the windows are
local. Nothing is exclusive (the terminal block already works so).

## Costs, by piece

| Piece | New | Changed |
|---|---|---|
| Access point block | entity + item + recipe + sprites, member kind, booster item and its card rules | graph kinds, power table, `docs/API.md` |
| Remote window path | handle in `N.network_of`, `G.entity_of`, window tags | terminal module (about 35 lines), blueprints untouched |
| Item + hotkey | `item-with-tags`, custom input, link and energy in tags | the open-key handler (link by click) |
| ME Charger block | entity + item + recipe + sprites, member kind, one-slot inventory, charge power | graph kinds, power table |
| Equipment module | equipment prototype, per-player link, drain at refresh | none |
| Wireless pattern mode | mode switch in the window, encode into the inventory | pattern terminal module (editor reuse) |
| Gregtorio | nothing in this mod | its compat file: recipes of the item, the module, the access point, the booster |

## Split into issues

- #205 the Wireless Access Point and the Wireless Boosters (with the range query)
- #206 the terminal handle and the wireless window path
- #207 the Wireless ME Terminal item and its hotkey (linking, energy, the mode switch)
- #208 the ME Charger
- #209 the power-armour equipment module (first step: check the equipment energy headless)
- #210 the pattern mode
- #211 graphics, locale, docs and the Gregtorio recipes

Order: #205 and #206 first (the second can start with a stub range), then #207 and #208, then #209 and #210, #211 alongside.
A `[Task-Ingame]` issue follows each piece that has something to look at.
