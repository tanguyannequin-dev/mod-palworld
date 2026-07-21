# PalScouter Fork: Localizations, Keyboard Refinements & Crash Fixes

This repository contains a fork of **PalScouter**, a client-only UI mod for Palworld.
These changes have been developed to improve stability under heavy loads (level streaming, dungeon loading), prevent crashes from invalid actors, refine keyboard navigation to be conflict-free, and introduce a modular internationalization framework (localization) supporting **English, French, Spanish, Chinese, and Korean**.

---

## 🛠 Summary of Key Improvements

| Feature / Fix | Description | Affected Files |
|---|---|---|
| **Actor Safety Checks** | Prevents random desktop crashes by checking `.actor:IsValid()` inside all polling and collection hooks before calling native methods. | [scanner.lua](PalScouter/Scripts/scanner.lua) |
| **Dungeon & Map Load Fix** | Fixed empty UI panel issues in dungeons by hook-binding to level loading (`RegisterLoadMapPreHook`) to safely reset cache registries. | [main.lua](PalScouter/Scripts/main.lua), [scanner.lua](PalScouter/Scripts/scanner.lua) |
| **Scheduler Jitter (Anti-Lag)** | Added randomized temporal jitter (±10%) to `math.randomseed` scan timers so they do not overlap ticks, lowering CPU spikes. | [main.lua](PalScouter/Scripts/main.lua) |
| **Modular Localization** | Created `localization.lua` separating strings from draw routines. Fully translated the entire UI (settings, wild list, aim card, search picker). | [localization.lua](PalScouter/Scripts/localization.lua), [ui_card.lua](PalScouter/Scripts/ui_card.lua), [ui_list.lua](PalScouter/Scripts/ui_list.lua), [ui_settings.lua](PalScouter/Scripts/ui_settings.lua), [ui_pal_picker.lua](PalScouter/Scripts/ui_pal_picker.lua) |
| **Conflict-Free Keyboard** | Block/unblock inputs via PlayerController `DisableInput`/`EnableInput` (solving mouse focus camera bugs). Mapped `Space` to select/toggle and `Backspace`/`F7` to close. | [main.lua](PalScouter/Scripts/main.lua), [ui_pal_picker.lua](PalScouter/Scripts/ui_pal_picker.lua) |
| **UI Spacing & Font Width Fix** | Solved French/Spanish text overlaps by using the game's actual capital letter font width (13.5px instead of 8px) for dynamic centering offsets. | [ui_settings.lua](PalScouter/Scripts/ui_settings.lua), [ui_list.lua](PalScouter/Scripts/ui_list.lua), [ui_pal_picker.lua](PalScouter/Scripts/ui_pal_picker.lua) |

---

## 🔍 Detailed Walkthrough of Code Changes

### 1. Stability & Crash Prevention
* **Actor Validation:** In [scanner.lua](PalScouter/Scripts/scanner.lua), checking `actor:IsValid()` inside `native_poll`, `native_track`, and `make_entry` ensures that if a Pal is unloaded (e.g. fast travel, death), the mod does not attempt reflection calls on invalid pointers.
* **Level Streaming Hooks:** In [main.lua](PalScouter/Scripts/main.lua), added hooks to `RegisterLoadMapPreHook` to clean up state trackers and prevent stale registry objects when loading into dungeons or switching worlds.
* **Scheduler Jittering:** To avoid micro-stutters from simultaneous cron runs, random jitter offsets are applied to the aim card and nearby scan schedules.

### 2. Conflict-Free Input Blocking
* We replaced the original mod's complex mouse/UIOnly setups (which broke camera controls) with native game controller input blocking:
  ```lua
  -- On open:
  player_controller:DisableInput(player_controller)
  -- On close:
  player_controller:EnableInput(player_controller)
  ```
* Intercepted `Space` in the species watchlist picker so it toggles selection instead of inserting space characters that filter out the whole list.

### 3. Translation & Localization Framework
A new central translation library [localization.lua](PalScouter/Scripts/localization.lua) provides quick lookups using:
```lua
L.t("key_name", cfg.Language)
```
* Custom language setting option `Language` added to the F7 menu, supporting `"en"`, `"fr"`, `"es"`, `"zh"`, and `"ko"`.
* All files (`ui_card.lua`, `ui_list.lua`, `ui_settings.lua`, `ui_pal_picker.lua`) draw labels dynamically using `L.t`.

### 4. UI Precision & Centering
* Calculated that capital letters in `Ft_PalDefaultFont` average **13.5 pixels wide** at scale 1.0 (rather than the hardcoded 8px estimate).
* Increased settings panel width to **600px** and value bounding boxes to **200px** to handle long translations (e.g. `"SAUVAGES SEULS"`, `"LISTA DE SEGUIM."`) and center them dynamically using:
  ```lua
  local val_text_w = #val * 13.5 * 0.70 * s
  local value_x = prev_x + btn_w + (val_w - val_text_w) / 2
  ```

---

## 🚀 How to Review Diffs
The files in this repository represent a clean build. You can compare the modified scripts in [PalScouter/Scripts/](PalScouter/Scripts/) to the original release to inspect the precise structural changes.