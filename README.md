# PalScouter Enhanced: Localizations, Mount Support, Dynamic Reticle & Self-Healing Watchdogs

This repository contains an enhanced version / fork of **PalScouter**, a client-only UI mod for Palworld.

These modifications address long-standing limitations noted by the original mod author (such as mount support and reticle target switching), introduce a modular **localization system** (supporting English, French, Spanish, Chinese, and Korean), solve UI font overflow bugs, and implement an **automatic self-healing watchdog architecture** to guarantee 100% stability during extended play sessions (20+ minutes).

---

## 🛠 Summary of Key Improvements

| Feature / Fix | Technical Description | Primary Files |
|---|---|---|
| **Mount / Riding Support** | Resolved aim card scanning when riding mounts. When mounted, `controller.Pawn` changes to the mount character (which lacks `ShooterComponent`). Added fallback to `G.local_player_character(controller)` to access the human player's `ShooterComponent`. | [scanner.lua](PalScouter/Scripts/scanner.lua) |
| **Dynamic Reticle Switching** | Replaced sticky locked aim cone behavior. The scanner now checks `ReticleTargetActor` changes and relative reticle centering (`dot_best > dot_locked + 0.04`) to instantly switch targets when sweeping crosshairs across multiple Pals. | [scanner.lua](PalScouter/Scripts/scanner.lua) |
| **Self-Healing Watchdog System** | Implemented a 2-tier watchdog architecture: (1) a 3-second queue lock timeout in `run_queued_game_thread` to unblock stuck queues, and (2) a 5-second heartbeat check inside the frame draw loop (`on_draw_hud`) that automatically revives background scan loops if UE4SS drops timer callbacks after 20+ minutes of play. | [util.lua](PalScouter/Scripts/util.lua), [main.lua](PalScouter/Scripts/main.lua) |
| **Dynamic Radar Refresh on Move** | Added player position tracking (`dist_sq > 1500 * 1500` ~ 15m). Automatically purges stale candidate queues and restarts a fresh native scan when flying or traveling to new areas. | [scanner.lua](PalScouter/Scripts/scanner.lua) |
| **Modular i18n Localization** | Created `localization.lua` separating strings from draw routines. Fully translated the entire UI into **English, French, Spanish, Chinese, and Korean**. | [localization.lua](PalScouter/Scripts/localization.lua), [ui_card.lua](PalScouter/Scripts/ui_card.lua), [ui_list.lua](PalScouter/Scripts/ui_list.lua), [ui_settings.lua](PalScouter/Scripts/ui_settings.lua), [ui_pal_picker.lua](PalScouter/Scripts/ui_pal_picker.lua) |
| **UI Alignment & Font Scaling** | Solved Spanish/French text overlaps by calculating game capital letter font width (13.5px instead of 8px). Expanded settings width to 600px and added dynamic value centering between `<` and `>`. | [ui_settings.lua](PalScouter/Scripts/ui_settings.lua), [ui_pal_picker.lua](PalScouter/Scripts/ui_pal_picker.lua) |
| **Conflict-Free Keyboard Controls** | Replaced camera-locking UIOnly mouse mode with PlayerController `DisableInput`/`EnableInput`. Remapped `Space` to toggle watchlist items without text filter conflicts, and `Backspace`/`F7` to close. | [main.lua](PalScouter/Scripts/main.lua), [ui_pal_picker.lua](PalScouter/Scripts/ui_pal_picker.lua) |
| **Dungeon & Level Load Safety** | Bound state cleanup to `RegisterLoadMapPreHook` and added `actor:IsValid()` checks across all polling hooks to prevent crashes during level streaming or fast travel. | [main.lua](PalScouter/Scripts/main.lua), [scanner.lua](PalScouter/Scripts/scanner.lua) |

---

## 🔍 Deep Dive into Key Technical Solutions

### 1. Pal Mount / Riding Support (`scanner.lua`)
* **Problem:** When mounted on a Pal (ground or flying), `controller.Pawn` resolves to the mount character (`APalMonster`). The original code attempted `pawn.ShooterComponent:IsAiming()`, which returned `nil`/`false` because the mount lacks a `ShooterComponent`. This caused `is_player_aiming` to clear the card every tick.
* **Solution:** Modified `is_player_aiming`, `is_sphere_equipped`, and `get_reticle_target` to check `G.local_player_character(controller)` whenever `pawn.ShooterComponent` is missing. This accesses the human character riding the mount, allowing full scanning while mounted.

### 2. Responsive Reticle Target Switching (`scanner.lua`)
* **Problem:** In the original mod, once Pal A entered the aim cone (31.7°), it activated a "Locked Fast Path" that short-circuited every tick. Moving the crosshair to Pal B while holding the aim button kept the card locked on Pal A until Pal A left the screen entirely.
* **Solution:** Enhanced the locked path to check:
  1. `ReticleTargetActor` changes (`reticle_switched`).
  2. Relative centering offset (`dot_best > dot_locked + 0.04`).
  If a new Pal is targeted or significantly closer to the reticle center, the lock is released instantly, enabling smooth crosshair sweeping across crowds of Pals.

### 3. Self-Healing Watchdog Architecture (`util.lua` & `main.lua`)
* **Problem:** Extended play sessions (20+ minutes) could result in UE4SS timer callback drops or delayed game-thread tasks. When a callback was dropped, `State.nearby_queued` or `State.aim_queued` remained `true` forever, freezing the nearby radar and aim card while leaving the F7 modal functional.
* **Solution:** Implemented a 2-tier watchdog system:
  * **Queue Lock Watchdog (`util.lua`):** `Util.run_queued_game_thread` tracks queue entry timestamps. If a lock remains active for > 3.0s, it automatically unblocks the queue.
  * **Heartbeat Watchdog (`main.lua`):** Inside `on_draw_hud` (which runs every frame), the mod checks scheduler timestamps every 60 frames (~1s). If `schedule_nearby` or `schedule_aim` haven't ticked for > 5.0s, it automatically restarts them seamlessly.

### 4. Dynamic Radar Refresh on Travel (`scanner.lua`)
* **Problem:** When flying fast across the map, `refine_nearby` could get stuck processing stale candidates from a previous area, preventing `native_poll` from running a fresh scan for the new position.
* **Solution:** `scan_nearby` now tracks the player's 3D coordinates. Moving more than 15 meters (`dist_sq > 1500 * 1500`) automatically clears stale refinement queues and triggers an instant native scan for the new location.

### 5. Localization & Font Geometry (`localization.lua`, `ui_settings.lua`)
* **Problem:** Default 8px font width calculations caused long French/Spanish option names (e.g. `"SAUVAGES SEULS"`, `"LISTA DE SEGUIM."`) to overlap with `<` and `>` chevron buttons.
* **Solution:** Created a standalone translation dictionary `localization.lua`. Corrected font character width to **13.5px** (matching in-game capital letter rendering), expanded setting panel width to **600px**, and centered option text dynamically within a 200px bounding box.

---

## 📦 Applying Changes to Original Source
You can apply all these enhancements directly to the original repository using Git:
```bash
git apply 0001-Introduce-PalScouter-localization-keyboard-navigatio.patch
```
Or simply copy the files from [PalScouter/Scripts/](PalScouter/Scripts/) into your mod directory.