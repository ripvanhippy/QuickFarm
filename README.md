# QuickFarm — Developer README

**Purpose:** Auto-swap to skinning gear (gloves / mainhand / offhand weapon with
+Skinning) the moment a "Requires Skinning ###" error appears, then reliably
swap back the original gear afterward — safely, even with combat interruptions
or lag. Built for WoW 1.12.1 (OctoWoW server), pure Lua, no external tools
(SuperWoW/UnitXP/nampower/classicapi) required.

This file must be kept up to date after every change, so any future
conversation/session can read it and immediately understand the full design
without re-reading all the code.

---

## Files

- `QuickFarm.toc` — addon manifest. Declares SavedVariablesPerCharacter `QuickFarmDB`.
- `Core.lua` — all logic: detection, swapping, combat safety, timeout, saved vars, slash commands.
- `UI.lua` — minimap button, its dropdown menu, and the popup window for entering item names.
- `README.md` — this file.

---

## The problem this solves

In 1.12.1, trying to skin a mob above your skill fails with a red error in the
middle of the screen: `Requires Skinning 305` (number = required skill).
Nothing is logged to chat or the combat log — it's a pure UI event.
The game *does* fire a normal Lua event for this (`UI_ERROR_MESSAGE`), so a
plain addon can detect it and react — no memory reading / external tools needed.

Important distinction: `Requires Skinning Knife` (wrong error, missing tool —
gear swap won't fix it) and `Out of range.` are different messages and must
**not** trigger a swap. Only the "number after Skinning" version does.

---

## High-level flow

1. Player clicks skin, doesn't have enough skill → `UI_ERROR_MESSAGE` fires with
   text `"Requires Skinning 305"`.
2. Addon detects this exact pattern → **forward swap**: equips whatever gear
   the user configured (gloves/mainhand/offhand), after **snapshotting**
   what was equipped in each of those slots *right before* swapping.
3. Player clicks skin again → succeeds → loot window opens.
4. Player loots → loot window closes → `LOOT_CLOSED` fires → **backward
   swap**: re-equips the snapshotted original gear.
5. Safety nets in case step 4 never happens cleanly (see below).

---

## Why snapshot every single time?

Gear can change during a play session (respec to healer, etc.), so we can't
assume "the pre-skinning gear" is always the same items. Every time a forward
swap happens, `Core.lua` re-reads what is *currently* equipped in each
relevant slot and stores that as the thing to restore — not a fixed/remembered
loadout.

---

## Combat safety (important failsafe)

On this server, equipping gear during combat silently fails. To guard against
"someone pulls while I'm skinning, and I never notice I'm still in skinning
gear":

- `QuickFarm_InCombat` (global boolean in `Core.lua`) is kept in sync via
  `PLAYER_REGEN_DISABLED` (entering combat → true) and `PLAYER_REGEN_ENABLED`
  (leaving combat → false).
- **Forward swap** refuses to run at all while `QuickFarm_InCombat` is true
  (prints a message instead of silently failing).
- **Backward swap**: if combat is active when it's triggered (e.g. `LOOT_CLOSED`
  fires mid-fight), it does **not** attempt the swap. Instead it sets
  `QuickFarmDB.pending.waiting = true` and does nothing else.
- The moment `PLAYER_REGEN_ENABLED` fires (combat truly over), the addon
  checks `QuickFarmDB.pending.active` and — if still true — runs the backward
  swap automatically. This means the swap is never lost, just delayed until
  it's safe, with zero user action required.

## Lag safety

The addon never *assumes* a swap succeeded just because it sent the equip
command. Every check (is it currently "EMPTY"? is a swap still pending?) reads
live game state (`GetInventoryItemLink`, `QuickFarmDB.pending.active`) rather
than trusting a timing assumption. This avoids the addon's internal belief
about your gear drifting out of sync with reality under lag.

## Timeout failsafe

If `LOOT_CLOSED` never fires at all (second skin attempt also failed, you
rode away, whatever) the addon would otherwise leave you in skinning gear
forever. `Core.lua` starts a 15-second countdown (`TIMEOUT_SECONDS`, hidden
frame `QuickFarmTimeoutFrame` using `OnUpdate`, since vanilla has no
`C_Timer`) the moment a forward swap happens. If nothing has cleared
`QuickFarmDB.pending.active` by then, it force-runs the backward swap
(still respecting the combat check above).

## Crash / relog recovery

`QuickFarmDB.pending` is saved to disk (SavedVariablesPerCharacter), not just
kept in memory. On login/reload, `PLAYER_ENTERING_WORLD` checks if
`QuickFarmDB.pending.active` is still `true` from before — meaning you logged
out or crashed while still wearing the swapped gear — and immediately
attempts to restore it.

## Manual override (extra safety net, not requested but cheap insurance)

Slash commands:
- `/qf status` — prints enabled/disabled, whether a swap is currently pending, and combat state.
- `/qf back` — forces an immediate backward swap attempt right now (still respects the combat check).

---

## Saved variables — `QuickFarmDB` (per character)

```lua
QuickFarmDB = {
  enabled = true,             -- right-click toggle on minimap button

  slots = {
    gloves   = { itemName = "Exact Item Name", texture = "Interface\\Icons\\..." },
    mainhand = { ... },        -- optional, only if user configured it
    offhand  = { ... },        -- optional, only if user configured it AND class can offhand
  },

  pending = {
    active  = false,           -- true while currently wearing swapped-in gear
    waiting = false,           -- true if a swap-back was blocked by combat, waiting for combat to end
    slots   = {                -- snapshot of what to restore, per slot key
      gloves = "Original Glove Name",   -- or "EMPTY" if nothing was equipped there
      -- mainhand / offhand entries only exist if that slot was swapped this time
    },
  },

  minimap = { angle = 220 },   -- minimap button position, degrees around the minimap
}
```

`slots` only contains keys the user has actually configured via the dropdown
popup — an unconfigured slot is simply not swapped.

---

## Core.lua — reference

### Constants / globals
- `QUICKFARM_SLOTID` — table mapping `"gloves"→10`, `"mainhand"→16`, `"offhand"→17` (real WoW inventory slot IDs).
- `QuickFarm_InCombat` — boolean, true while in combat (kept in sync by events).

### Functions
- `QuickFarm_Print(msg)` / `QuickFarm_Error(msg)` — chat output helpers (green / red).
- `QuickFarm_InitDB()` — creates `QuickFarmDB` and all its sub-tables with defaults if missing. Called once on `ADDON_LOADED`.
- `QuickFarm_CanOffhand()` — returns true only for Warrior/Rogue/Hunter (Shaman excluded: no Dual Wield talent on this server).
- `QuickFarm_FindItemInBags(name)` — searches bags 0–4 for an item matching `name` (case-insensitive, exact match on the item's display name). Returns `found (bool), texture (string or nil)`.
- `QuickFarm_IsSkinningSkillError(msg)` — returns true only for the pattern `"Requires Skinning <number>"`, explicitly excluding `"Requires Skinning Knife"` and anything else.
- `QuickFarm_DoForwardSwap()` — the swap-in logic. Checks enabled/combat/already-pending, then for every configured slot: finds the item in bags (errors via `QuickFarm_Error` if missing), snapshots current equipped name, equips the configured item, marks `pending.active = true`, starts the timeout timer.
- `QuickFarm_DoBackwardSwap()` — the swap-back logic. If in combat, just flags `pending.waiting = true` and stops. Otherwise restores every snapshotted slot (re-equips by name, or unequips-to-bag if the snapshot was `"EMPTY"`), then clears `pending`.
- `QuickFarm_StartTimeoutTimer()` / `QuickFarm_CancelTimeoutTimer()` — control the 15s failsafe frame.

### Events registered (all on `QuickFarmEventFrame`)
- `ADDON_LOADED` — init DB + trigger UI creation (checks `arg1 == "QuickFarm"`).
- `PLAYER_ENTERING_WORLD` — crash/relog recovery check.
- `UI_ERROR_MESSAGE` — main detection point.
- `LOOT_CLOSED` — normal swap-back trigger.
- `PLAYER_REGEN_DISABLED` / `PLAYER_REGEN_ENABLED` — combat tracking + auto-retry swap-back on combat end.

### Slash commands
- `/qf`, `/quickfarm` → `status` or `back` (see above).

---

## UI.lua — reference

### Frames created (inside `QuickFarm_UI_Init()`, called once from Core after DB init)
- `QuickFarmMinimapButton` — draggable button on the minimap.
  - Left-click → opens `QuickFarmDropDown`.
  - Right-click → toggles `QuickFarmDB.enabled`, dims/brightens the icon.
  - Drag → repositions around the minimap, saves angle to `QuickFarmDB.minimap.angle`.
- `QuickFarmDropDown` (`UIDropDownMenuTemplate`) — three entries: "Set Gloves", "Set Mainhand", "Set Offhand". Offhand entry is greyed out (`info.disabled`) unless `QuickFarm_CanOffhand()` is true.
- `QuickFarmPopup` — the item-name entry window.
  - Close button, top-right.
  - Icon (updates to the found item's texture once "Set" succeeds).
  - Edit box for the item name (Enter key also triggers "Set").
  - "Set" button → `QuickFarm_Popup_OnSet()`.
  - Red error text shown if the typed item isn't found in bags.

### Functions
- `QuickFarm_OpenPopup(slotKey)` — opens the popup for `"gloves"|"mainhand"|"offhand"`, pre-filling saved data if present.
- `QuickFarm_Popup_OnSet()` — reads the edit box, searches bags via `QuickFarm_FindItemInBags`, saves to `QuickFarmDB.slots[currentSlotKey]` on success, shows red error text on failure.
- `QuickFarm_UI_Init()` — one-time setup, guarded by local `uiCreated` flag.

---

## Known limitations / things to watch

- **Two-handed weapons vs offhand swap:** if the user wears a 2H weapon and
  also configures an offhand skinning item, equipping into the offhand slot
  while a 2H weapon occupies the mainhand can behave oddly (client-dependent).
  Not specially handled — user should avoid configuring offhand swap while
  using a 2H weapon.
- **Exact name matching:** the typed item name must match the real item name
  exactly (case doesn't matter, but spelling does). No fuzzy matching or
  autocomplete yet.
- **Locale:** the "Requires Skinning" text match assumes an English client.

---

## Change log
- v0.1 — Initial build: detection via `UI_ERROR_MESSAGE`, forward/backward
  swap with per-attempt snapshotting, combat-safe swap-back with automatic
  retry on `PLAYER_REGEN_ENABLED`, 15s timeout failsafe, crash/relog
  recovery, minimap button + dropdown + popup UI, class-aware offhand
  greyout (Warrior/Rogue/Hunter only), `/qf status` and `/qf back` slash
  commands.
- Cosmetic (no version bump): addon display title reordered to
  `<Gaha> QuickFarm` in `QuickFarm.toc`. "Gaha" stays orange
  (`|cffff8000`), "QuickFarm" is now entirely dark green (`|cff006400`)
  instead of the old white/green letter-by-letter coloring.
