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
| **Complete C++ Crash Protection (Sync Polling)** | Disabled the native C++ 'batching' system that held raw memory pointers across ticks. This fixes the fatal `0xffffffffffffffff` UE4SS freeze that occurred when a Pal disappeared or died mid-batch. | [scanner.lua](PalScouter/Scripts/scanner.lua) |
| **Teleportation & Fast Travel Safety** | Added a 100-meter distance jump detection. Automatically purges all C++ references and pauses the scan for 1.5 seconds during fast travel, allowing UE4 to safely garbage collect old actors without crashing. | [scanner.lua](PalScouter/Scripts/scanner.lua) |
| **Alt-Tab / Resolution Crash Fix** | Added an explicit validity check on `hud.Canvas`. Fixes the `0x18` Access Violation that crashed the game entirely when Alt-Tabbing or resizing the window on the title screen. | [main.lua](PalScouter/Scripts/main.lua) |
| **Capture Crash Protection** | Checked `SaveParameter` validity before querying combat stats. Fixes a fatal `EXCEPTION_ACCESS_VIOLATION` in UE4 when scanning a Pal that was just successfully captured (since its save data is transferred to the Palbox, leaving a dangling pointer). | [gamedata.lua](PalScouter/Scripts/gamedata.lua) |
| **Poisoned Pointer Protection** | Pre-filtered `0xffffffffffffffff` (and `-1`) raw memory addresses before invoking `IsValid()`. Fixes a fatal UE4 crash during intense sphere assaults where the engine momentarily returns unmapped memory before garbage collection. | [util.lua](PalScouter/Scripts/util.lua) |


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

### 4. Complete C++ Crash Prevention & Teleport Safety (`scanner.lua`)
* **Problem 1 (Base Freezes):** The C++ DLL used a batching system (`PalScouterNativePollBatch`) that held raw `AActor*` pointers in memory across multiple 200ms ticks. If a Pal was returned to the Palbox or died mid-batch, accessing the dangling pointer caused a fatal `0xffffffffffffffff` Access Violation, permanently killing the UE4SS game thread.
* **Solution 1:** Bypassed the batching system entirely by exclusively invoking the synchronous `PalScouterNativePoll`. The scan now executes safely in a single frame, eliminating all dangling pointer crashes without noticeable FPS drops.
* **Problem 2 (Teleport Freezes):** When fast traveling, UE4 destroys massive amounts of actors. The physics octree briefly returns `PendingKill` actors, which crashed the C++ bridge if scanned immediately. The old 15m distance check was also aggressively triggering mid-batch resets (`batch_restart = true`), further corrupting C++ memory.
* **Solution 2:** Removed the aggressive 15m reset. Replaced it with a 100-meter teleport detection that instantly flushes Lua caches and enforces a strict **1.5-second scan pause**, allowing the UE4 engine to stabilize garbage collection safely.

### 5. Alt-Tab & Capture Crash Fixes
* **Problem 1 (Alt-Tab):** Alt-Tabbing or changing resolution caused `EXCEPTION_ACCESS_VIOLATION reading address 0x18`. During screen resize, the D3D device resets and `hud.Canvas` briefly becomes a dead pointer.
* **Solution 1:** Introduced `Util.valid(canvas)` before property access. The mod gracefully skips drawing while the window is being resized.
* **Problem 2 (Capture):** Capturing a Pal transfers its internal `SaveParameter` data to the Palbox. If the mod attempted to read its HP or Attack power in the exact frame before the actor was destroyed, the C++ getter dereferenced a `nullptr`, crashing the entire game.
* **Solution 2:** Added an explicit `parameter.SaveParameter` null-check in `G.get_parameter` before allowing any C++ stat reads.
* **Problem 3 (Poisoned Pointers):** Spamming spheres on a single Pal causes rapid state changes. The engine occasionally returns `0xffffffffffffffff` (unmapped memory) for the reticle target. Calling `IsValid()` on this address bypasses standard Lua pcalls and instantly kills the game.
* **Solution 3:** Hooked `Util.valid()` to inspect the raw hex address via `GetAddress()` before asking C++ to validate it. Any `-1` or `0xffffffff...` pointer is instantly rejected in Lua.

### 6. Localization & Font Geometry (`localization.lua`, `ui_settings.lua`)
* **Problem:** Default 8px font width calculations caused long French/Spanish option names (e.g. `"SAUVAGES SEULS"`, `"LISTA DE SEGUIM."`) to overlap with `<` and `>` chevron buttons.
* **Solution:** Created a standalone translation dictionary `localization.lua`. Corrected font character width to **13.5px** (matching in-game capital letter rendering), expanded setting panel width to **600px**, and centered option text dynamically within a 200px bounding box.

---

## 📦 Applying Changes to Original Source
You can apply all these enhancements directly to the original repository using Git:
```bash
git apply 0001-Introduce-PalScouter-localization-keyboard-navigatio.patch
```
Or simply copy the files from [PalScouter/Scripts/](PalScouter/Scripts/) into your mod directory.