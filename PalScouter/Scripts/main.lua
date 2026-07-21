-- PalScouter — client-only Pal stats, IVs, and nearby wild-Pal scouting.
-- Entry point: config, keybinds, scan schedulers, HUD hook lifecycle.
--
-- Client-safety invariants (see DEV-NOTES.md):
--   * every UObject touch happens on the game thread inside pcall
--   * gameplay data is read-only; names resolve via the game's own localization utilities
--   * no gameplay setters, save writes, remote calls, or network messages
--   * no unstable by-value save reads or collection/capture-state reads
local Util = require("util")
local Config = require("config")
local Scanner = require("scanner")
local G = require("gamedata")
local UI = require("ui")
local Profile = require("profile")
local Card = require("ui_card")
local List = require("ui_list")
local Settings = require("ui_settings")
local Picker = require("ui_pal_picker")
local L = require("localization")
local UEHelpers = require("UEHelpers")

local VERSION = "0.7.0"
local HUD_HOOK_PATH = "/Game/Pal/Blueprint/UI/BP_PalHUD_InGame.BP_PalHUD_InGame_C:ReceiveDrawHUD"

local State = {
    panel_open = false,
    settings_open = false,
    pal_picker_open = false,
    move_target = nil,       -- nil | "AimCard" | "Panel"
    hook_ids = nil,          -- {pre_id, post_id} while the draw hook is registered
    unhook_generation = 0,
    frame = 0,
    aim_queued = false,
    nearby_queued = false,
    prefetch_queued = false,
    prefetch_timer = false,
    caches_ready = false,
    aim_started = false,
    warm_started = false,
    warm_queued = false,
    picker_warm_queued = false,
    picker_warm_needed = false,
    picker_trim_generation = 0,
    nearby_open_generation = 0,
}

local cfg = Config.current

-- ------------------------------------------------------------ draw hook

local function ui_visible()
    return cfg.Enabled and (State.panel_open or State.settings_open
        or State.pal_picker_open or Scanner.aim.data ~= nil)
end

local close_settings -- forward
local close_pal_picker -- forward
local open_pal_picker -- forward
local sync_hook -- forward
local schedule_nearby -- forward
local ensure_warm -- forward
local schedule_picker_warm -- forward

local function apply_show_mode(mode)
    if mode ~= "always" then Scanner.clear_aim() end
    if mode ~= "off" and ensure_warm ~= nil then ensure_warm() end
    sync_hook()
    Util.log("Aim card: " .. Config.show_mode_label(mode))
end

local function toggle_card()
    if State.settings_open or State.pal_picker_open then return end
    apply_show_mode(Config.cycle_show_mode(1))
end

local function aim_scan_paused_for_modal()
    return State.settings_open or State.pal_picker_open
end

local function nearby_scan_paused_for_modal()
    return State.pal_picker_open
end

-- Action ids are "dist_next", "mode_prev", etc.
-- Lua patterns have no '|'; match suffix separately.
local function apply_settings_action(action)
    if action == nil then return end
    if action == "close" then
        close_settings()
        return
    end
    if action == "watch_toggle" then
        local aim = Scanner.aim.data
        if not (aim and aim.character_id and aim.character_id ~= "") then
            Util.log("Watchlist: aim a Pal, then Shift+Enter on WATCHLIST to add/remove it")
            return
        end
        local value = Config.watchlist_toggle(aim.character_id)
        Scanner.rebuild_view(cfg)
        Util.log("Watchlist = " .. tostring(value))
        return
    end
    if action == "watch_open" then
        open_pal_picker()
        return
    end
    local id, suffix = action:match("^([a-z]+)_(%a+)$")
    if not id or (suffix ~= "prev" and suffix ~= "next") then
        Util.log("WARNING: bad settings action " .. tostring(action))
        return
    end
    local delta = (suffix == "prev") and -1 or 1
    local value
    if id == "language" then
        value = Config.cycle_language(delta)
        Scanner.rebuild_view(cfg)
    elseif id == "dist" then
        value = Config.cycle_radius(delta)
        Scanner.rebuild_view(cfg)
    elseif id == "interval" then
        value = Config.interval_label(Config.cycle_interval(delta))
        if Scanner.nearby.active then schedule_nearby() end
    elseif id == "mode" then
        value = Config.cycle_score_mode(delta)
        Scanner.recompute_scores(cfg)
        Scanner.rebuild_view(cfg)
        if Scanner.nearby.active then schedule_nearby() end
    elseif id == "filter" then
        value = Config.cycle_preset(delta)
        Scanner.rebuild_view(cfg)
    elseif id == "own" then
        value = Config.ownership_label(Config.cycle_ownership(delta))
        Scanner.invalidate_ownership_cache(cfg)
        Scanner.rebuild_view(cfg)
        if Scanner.nearby.active then schedule_nearby() end
    elseif id == "watch" then
        value = Config.cycle_watchlist(delta)
        if value == Config.WATCHLIST_OPEN_PICKER then
            open_pal_picker()
            return
        end
        Scanner.rebuild_view(cfg)
    elseif id == "sort" then
        value = Config.cycle_sort(delta)
        Scanner.sort_mode = value
        Scanner.rebuild_view(cfg)
    elseif id == "rows" then
        value = Config.cycle_max_rows(delta)
        Scanner.rebuild_view(cfg)
    elseif id == "aimen" then
        value = Config.show_mode_label(Config.cycle_show_mode(delta))
        apply_show_mode(Config.current.AimCard.ShowMode)
    elseif id == "aimdelay" then
        -- schedule_aim re-reads the interval each idle cycle; no re-arm needed.
        value = Config.aim_delay_label(Config.cycle_aim_delay(delta))
    elseif id == "aimsize" then
        value = Config.scale_label(Config.cycle_scale("AimCard", delta))
    elseif id == "panelsize" then
        value = Config.scale_label(Config.cycle_scale("Panel", delta))
    elseif id == "aimmove" then
        State.move_target = "AimCard"
        value = "move mode"
    elseif id == "panelmove" then
        State.move_target = "Panel"
        value = "move mode"
    elseif id == "aimop" then
        value = Config.cycle_opacity("AimCard", delta)
    elseif id == "panelop" then
        value = Config.cycle_opacity("Panel", delta)
        Scanner.rebuild_view(cfg)
    elseif id == "basehide" then
        value = Config.hide_in_base_label(Config.cycle_hide_in_base(delta))
        Scanner._base.needs_probe = true
        if not cfg.Base.HideUiInBase then Scanner.in_base = false end
    end
    if value ~= nil then
        Util.log(string.format("Settings %s = %s", id, tostring(value)))
    end
end

-- Plain-Lua sample card so move mode can preview placement with nothing aimed.
local SAMPLE_CARD = {
    character_id = "SheepBall", name = "Lamball", name_resolved = true,
    level = 12, gender = 1, is_alpha = false,
    hp = 320, max_hp = 400, atk = 82, def = 76, craft = 70,
    ivs = { hp = 78, atk = 92, def = 45 },
    elements = { "Neutral" }, element_ids = { 1 },
    works = { { id = 5, rank = 1 } },
    active_skills = { { name = "Roly Poly", element = 1, power = 35 } },
    passives = { { name = "Brave", rank = 1 } },
    score = 72, grade = "A", anchor = 120,
}
local SAMPLE_SCREEN = { x = 0, y = 0 }

local function draw_move_outline(hud, x, y, w, h, sh)
    if x == nil then return end
    local c = UI.col.accent
    UI.rect(hud, c, x - 2, y - 2, w + 4, 2)
    UI.rect(hud, c, x - 2, y + h, w + 4, 2)
    UI.rect(hud, c, x - 2, y, 2, h)
    UI.rect(hud, c, x + w, y, 2, h)
    local hint_y = y > 30 and (y - 24) or (y + h + 6)
    UI.text(hud, "ARROWS MOVE   ENTER/ESC DONE", c, x, hint_y, 0.60)
end

local function canvas_size(hud)
    local canvas = hud.Canvas
    if canvas == nil then return nil, nil end
    return tonumber(canvas.SizeX), tonumber(canvas.SizeY)
end

local function draw_hud(context)
    local hud = context:get()
    if hud == nil or not Util.valid(hud) then return end
    local sw, sh = 1920, 1080
    local size_ok, canvas_w, canvas_h = pcall(canvas_size, hud)
    if size_ok then
        sw = canvas_w or sw
        sh = canvas_h or sh
    end
    if State.frame % 30 == 1 then Scanner.refresh_base_presence(cfg) end
    local hide_for_base = cfg.Base and cfg.Base.HideUiInBase and Scanner.in_base
        and not State.settings_open and not State.pal_picker_open
        and State.move_target == nil
    if not hide_for_base and (State.panel_open or State.move_target == "Panel") then
        local px, py, pw, ph = Profile.span("hud.list", List.draw, hud, Scanner, cfg, sw, sh,
            State.move_target == "Panel", State.frame)
        if State.move_target == "Panel" then
            draw_move_outline(hud, px, py, pw, ph, sh)
        end
    end
    if State.move_target == "AimCard" then
        SAMPLE_SCREEN.x = sw * 0.5
        SAMPLE_SCREEN.y = sh * 0.5
        SAMPLE_CARD.screen = SAMPLE_SCREEN
        local cx, cy, cw, ch = Profile.span("hud.card", Card.draw,
            hud, SAMPLE_CARD, cfg, sw, sh, State.frame)
        draw_move_outline(hud, cx, cy, cw, ch, sh)
    elseif not hide_for_base then
        local aim = Scanner.aim.data
        if aim ~= nil and (cfg.AimCard.ShowMode or "always") ~= "off"
            and not State.settings_open and not State.pal_picker_open then
            if aim.screen == nil or State.frame % 30 == 0 then
                Profile.span("hud.card.project", Card.update_projection, hud, aim)
            end
            Profile.span("hud.card", Card.draw, hud, aim, cfg, sw, sh, State.frame)
        end
    end
    -- Keep the nearby list visible under the nested watchlist picker,
    -- but do not also render the settings modal underneath it.
    if State.settings_open and not State.pal_picker_open and State.move_target == nil then
        Profile.span("hud.settings", Settings.draw, hud, cfg, sw, sh)
    end
    if State.pal_picker_open then
        Profile.span("hud.picker", Picker.draw, hud, sw, sh, State.frame)
    end
end

local function check_schedulers_heartbeat()
    if not cfg.Enabled then return end
    local now = os.clock()
    if (cfg.AimCard.ShowMode or "always") ~= "off" and not aim_scan_paused_for_modal() then
        if State.last_aim_tick == nil or (now - State.last_aim_tick > 5.0) then
            State.aim_queued = false
            State.last_aim_tick = now
            pcall(schedule_aim)
        end
    end
    if Scanner.nearby.active and not nearby_scan_paused_for_modal() then
        if State.last_nearby_tick == nil or (now - State.last_nearby_tick > 5.0) then
            State.nearby_queued = false
            State.last_nearby_tick = now
            pcall(schedule_nearby)
        end
    end
end

local function on_draw_hud(context)
    State.frame = State.frame + 1
    if State.frame % 60 == 0 then
        pcall(check_schedulers_heartbeat)
    end
    pcall(Profile.span, "hud.draw", draw_hud, context)
end

local register_hud_hook -- forward declaration (retry closure below references it)

register_hud_hook = function()
    if State.hook_ids ~= nil then return end
    local ok, pre_id, post_id = pcall(RegisterHook, HUD_HOOK_PATH, on_draw_hud)
    if ok then
        State.hook_ids = { pre_id, post_id }
        Util.dbg("HUD hook registered")
    else
        pcall(ExecuteWithDelay, 1000, function()
            if ui_visible() and State.hook_ids == nil then register_hud_hook() end
        end)
    end
end

local function unregister_hud_hook_deferred()
    State.unhook_generation = State.unhook_generation + 1
    local gen = State.unhook_generation
    pcall(ExecuteWithDelay, 1200, function()
        if gen ~= State.unhook_generation then return end
        if ui_visible() then return end
        if State.hook_ids ~= nil then
            pcall(UnregisterHook, HUD_HOOK_PATH, State.hook_ids[1], State.hook_ids[2])
            State.hook_ids = nil
            Util.dbg("HUD hook unregistered")
        end
    end)
end

sync_hook = function()
    if ui_visible() then register_hud_hook() else unregister_hud_hook_deferred() end
end

-- ------------------------------------------------------------ schedulers

local function count_pairs(t)
    local n = 0
    if type(t) ~= "table" then return 0 end
    for _ in pairs(t) do n = n + 1 end
    return n
end

local schedule_aim
schedule_aim = function()
    -- A locked target only needs a cheap validity/dynamic-data refresh.  With no
    -- target, wait longer so the 200 m acquisition overlap cannot become a
    -- permanent four-times-per-second game-thread load.
    local interval = Scanner.aim_interval_ms(cfg)
    local range = math.floor(interval * 0.1)
    local jitter = range > 0 and math.random(-range, range) or 0
    local delay = math.max(50, interval + jitter)
    pcall(ExecuteWithDelay, delay, function()
        if cfg.Enabled and (cfg.AimCard.ShowMode or "always") ~= "off"
            and not aim_scan_paused_for_modal() and not State.aim_queued then
            Util.run_queued_game_thread(State, "aim_queued", function()
                State.last_aim_tick = os.clock()
                -- Recheck at execution time: user may have switched to OFF
                -- or opened a modal while this callback sat in the queue.
                if not cfg.Enabled or aim_scan_paused_for_modal()
                    or (cfg.AimCard.ShowMode or "always") == "off" then return end
                Scanner.scan_aim(cfg)
                if Scanner.aim.data ~= nil then
                    UI.warm_pal_icons({ Scanner.aim.data }, 1)
                end
                sync_hook()
            end, "aim")
        end
        schedule_aim()
    end)
end

local nearby_loop_gen = 0

local function stop_nearby_loop()
    nearby_loop_gen = nearby_loop_gen + 1
end

-- Native overlap is a single bounded game-thread operation. Between refreshes,
-- drain at most one localization/work item every 200 ms; no 33 ms polling loop.
schedule_nearby = function()
    if not Scanner.nearby.active then return end
    stop_nearby_loop()
    local gen = nearby_loop_gen
    local function delay_chain()
        if gen ~= nearby_loop_gen or not Scanner.nearby.active then return end
        local has_work = Scanner.has_nearby_work()
        local base_delay = has_work and 200 or (cfg.Scan.IntervalMs or 1000)
        local jitter = 0
        if not has_work then
            local range = math.floor(base_delay * 0.1)
            if range > 0 then jitter = math.random(-range, range) end
        else
            jitter = math.random(-20, 20)
        end
        local delay = math.max(50, base_delay + jitter)
        local delayed = pcall(ExecuteWithDelay, delay, function()
            if gen ~= nearby_loop_gen or not Scanner.nearby.active then return end
            if nearby_scan_paused_for_modal() then
                delay_chain()
                return
            end
            if State.nearby_queued then
                delay_chain()
                return
            end
            local queued = Util.run_queued_game_thread(State, "nearby_queued", function()
                State.last_nearby_tick = os.clock()
                if gen == nearby_loop_gen and Scanner.nearby.active
                    and not nearby_scan_paused_for_modal() then
                    Scanner.scan_nearby(cfg, not has_work)
                    local rows = Scanner.visible_rows or {}
                    if #rows > 0 then UI.warm_pal_icons(rows, #rows) end
                end
                delay_chain()
            end, "nearby")
            if not queued then delay_chain() end
        end)
        if not delayed then Util.log("WARNING: nearby timer failed") end
    end
    delay_chain()
end

local schedule_prefetch
schedule_prefetch = function()
    -- LoadAsset is synchronous. Decorative art remains settings-only, while the
    -- small work/element/rank icon allowlist may hydrate during normal gameplay.
    if not cfg.Enabled or not UI.prefetch_can_run(State.settings_open)
        or State.prefetch_timer or State.prefetch_queued then return end
    State.prefetch_timer = true
    -- This scheduler restarts only after the previous step completes. Recheck
    -- fast while async portrait streams are in flight so they appear promptly;
    -- the picker warms fastest; otherwise fall back to the slow idle cadence.
    local base_delay = 1000
    if State.pal_picker_open then
        base_delay = 50
    elseif UI.has_pending_async and UI.has_pending_async() then
        base_delay = 150
    end
    local range = math.floor(base_delay * 0.1)
    local jitter = range > 0 and math.random(-range, range) or 0
    local delay_ms = math.max(10, base_delay + jitter)
    local ok = pcall(ExecuteWithDelay, delay_ms, function()
        State.prefetch_timer = false
        if not cfg.Enabled or not UI.prefetch_can_run(State.settings_open) then return end
        State.prefetch_queued = true
        local queued = pcall(ExecuteInGameThread, function()
            if UI.prefetch_can_run(State.settings_open) then
                local wok, err = pcall(Profile.span, "prefetch", UI.prefetch_step)
                if not wok then Util.log("texture prefetch error: " .. tostring(err)) end
            end
            State.prefetch_queued = false
            schedule_prefetch()
        end)
        if not queued then
            State.prefetch_queued = false
            Util.log("WARNING: texture prefetch queue failed")
        end
    end)
    if not ok then State.prefetch_timer = false end
end

UI.set_prefetch_wake(schedule_prefetch)

-- Picker localization is limited to rows currently on screen and selected
-- entries. It reuses Scanner's cached controller, so opening/searching never
-- reintroduces UEHelpers' repeated FindAllOf("PlayerController") path.
local PICKER_WARM_BUDGET = 4
local PICKER_WARM_DELAY_MS = 250

local function picker_cached_name(id, casing)
    return G.species_name_cache[casing or id] or G.species_name_cache[id]
end

local function picker_sync_names()
    Picker.refresh_names(picker_cached_name)
end

local function picker_needs_name(id, casing)
    local key = casing or id
    return picker_cached_name(id, key) == nil and not G.species_name_failed[key]
end

local function request_picker_warm()
    if not State.pal_picker_open then return end
    State.picker_warm_needed = true
    schedule_picker_warm()
end

schedule_picker_warm = function()
    if not State.pal_picker_open or State.picker_warm_queued then return end
    Util.run_queued_game_thread(State, "picker_warm_queued", function()
        if not State.pal_picker_open then return end
        local controller = Scanner.player_controller()
        if controller == nil then
            local delay = PICKER_WARM_DELAY_MS + math.random(-math.floor(PICKER_WARM_DELAY_MS * 0.1), math.floor(PICKER_WARM_DELAY_MS * 0.1))
            pcall(ExecuteWithDelay, delay, schedule_picker_warm)
            return
        end
        Picker.ensure_catalog(nil)
        picker_sync_names()
        local batch, seen = {}, {}
        local function want(row)
            if not row or seen[row.id] or Picker.is_denied(row.id) then return end
            seen[row.id] = true
            local casing = row.casing or Picker.casing_for(row.id)
            if picker_needs_name(row.id, casing) then
                batch[#batch + 1] = { id = row.id, casing = casing }
            end
        end
        local visible = Picker.visible_rows()
        -- Queue every visible portrait at once; prefetch still resolves only one
        -- cold texture per step so LoadAsset stalls never stack in one frame.
        local icons_pending = UI.warm_pal_icons(visible, #visible)
        for i = 1, #visible do want(visible[i]) end
        for i = 1, #Picker.working do
            want({ id = Picker.working[i], casing = Picker.casing_for(Picker.working[i]) })
        end
        G.warm_species_names(controller, batch, PICKER_WARM_BUDGET)
        picker_sync_names()
        local needed = State.picker_warm_needed or icons_pending
            or #batch > PICKER_WARM_BUDGET
        State.picker_warm_needed = false
        if State.pal_picker_open and needed then
            local delay = PICKER_WARM_DELAY_MS + math.random(-math.floor(PICKER_WARM_DELAY_MS * 0.1), math.floor(PICKER_WARM_DELAY_MS * 0.1))
            pcall(ExecuteWithDelay, delay, schedule_picker_warm)
        end
    end, "picker species warm")
end

-- ------------------------------------------------------------ key handlers

local function schedule_picker_cache_trim()
    State.picker_trim_generation = State.picker_trim_generation + 1
    local generation = State.picker_trim_generation
    -- Give the render thread several seconds to consume every portrait command
    -- submitted before the picker closed. Reopening cancels this trim pass.
    pcall(ExecuteWithDelay, 3000, function()
        if generation ~= State.picker_trim_generation or State.pal_picker_open then return end
        pcall(ExecuteInGameThread, function()
            if generation ~= State.picker_trim_generation or State.pal_picker_open then return end
            local ok, trimmed = pcall(UI.trim_picker_texture_cache, 128, 96)
            if not ok then
                Util.log("WARNING: picker texture cache trim failed: " .. tostring(trimmed))
            elseif trimmed > 0 then
                Util.dbg("picker texture cache trimmed: " .. tostring(trimmed))
            end
        end)
    end)
end

open_pal_picker = function()
    if State.pal_picker_open then return end
    State.picker_trim_generation = State.picker_trim_generation + 1
    if not State.settings_open then
        State.settings_open = true
        Settings.focus = Settings.watch_row_index() or 1
    end
    Picker.open(cfg.Filter.Watchlist)
    picker_sync_names()
    State.pal_picker_open = true
    State.picker_warm_needed = false
    register_hud_hook()
    schedule_picker_warm()
    schedule_prefetch()
    Util.log("Pal picker ON — type to filter, Enter toggle, Esc done")
end

close_pal_picker = function(apply)
    if not State.pal_picker_open then return end
    if apply ~= false then
        Util.log("Watchlist = " .. tostring(Picker.close_apply()))
        Scanner.rebuild_view(cfg)
    else
        Picker.discard()
    end
    State.pal_picker_open = false
    UI.cancel_picker_texture_prefetch()
    schedule_picker_cache_trim()
    sync_hook()
end

local function open_settings()
    if State.settings_open then return end
    State.settings_open = true
    Settings.focus = 1
    register_hud_hook()
    schedule_prefetch()
    pcall(function()
        local controller = Scanner.player_controller()
        if controller ~= nil then
            controller:DisableInput(controller)
        end
    end)
    Util.log("Settings modal ON — Keyboard navigation active, Game input blocked")
end

close_settings = function()
    if State.pal_picker_open then close_pal_picker(true) end
    if not State.settings_open then return end
    State.move_target = nil
    State.settings_open = false
    pcall(function()
        local controller = Scanner.player_controller()
        if controller ~= nil then
            controller:EnableInput(controller)
        end
    end)
    sync_hook()
    Util.log("Settings modal OFF")
end

local function toggle_settings()
    if State.settings_open or State.pal_picker_open then close_settings() else open_settings() end
end

local MOVE_STEP = 10

local function move_nav(dir)
    if dir == "activate" then
        State.move_target = nil
        return
    end
    local dx, dy = Settings.move_delta(State.move_target, dir)
    if dx ~= nil then
        Config.nudge_offset(State.move_target, dx * MOVE_STEP, dy * MOVE_STEP)
    end
end

local function settings_nav(dir)
    if State.pal_picker_open then
        local result = Picker.handle(dir)
        if result == "done" then close_pal_picker(true) else request_picker_warm() end
        return
    end
    if not State.settings_open then return end
    if State.move_target ~= nil then
        move_nav(dir)
        return
    end
    local action = Settings.focus_action(dir)
    if action then apply_settings_action(action) end
end

local queue_opening_nearby_scan
queue_opening_nearby_scan = function(open_generation, allow_empty_retry)
    if State.nearby_queued then return false end
    State.nearby_queued = true
    local ok = pcall(ExecuteInGameThread, function()
        if Scanner.nearby.active and open_generation == State.nearby_open_generation
            and not nearby_scan_paused_for_modal() then
            pcall(Scanner.scan_nearby, cfg, true)
            local rows = Scanner.visible_rows or {}
            if #rows > 0 then UI.warm_pal_icons(rows, #rows) end
        end
        State.nearby_queued = false
        if not Scanner.nearby.active or open_generation ~= State.nearby_open_generation then return end

        -- The native registry/overlap can transiently return no actors on the
        -- very first game-thread tick after opening. Retry that empty result
        -- once quickly instead of making the user wait the full scan interval.
        local empty = count_pairs(Scanner.nearby.cache) == 0
            and not Scanner.has_nearby_work()
        if allow_empty_retry and empty then
            local delay = 500 + math.random(-50, 50)
            local delayed = pcall(ExecuteWithDelay, delay, function()
                if not Scanner.nearby.active
                    or open_generation ~= State.nearby_open_generation then return end
                if not queue_opening_nearby_scan(open_generation, false) then
                    schedule_nearby()
                end
            end)
            if delayed then return end
        end
        schedule_nearby()
    end)
    if not ok then State.nearby_queued = false end
    return ok
end

local function toggle_panel()
    if State.settings_open then return end
    State.panel_open = not State.panel_open
    if State.panel_open then
        State.nearby_open_generation = State.nearby_open_generation + 1
        local open_generation = State.nearby_open_generation
        Scanner.nearby.active = true
        Scanner.sort_mode = cfg.Sort or "score"
        if ensure_warm ~= nil then ensure_warm() end
        register_hud_hook()
        -- Immediate first scan; one 500 ms retry is allowed only when that
        -- first result is completely empty.
        if not queue_opening_nearby_scan(open_generation, true) then
            schedule_nearby()
        end
        Util.log("Nearby panel ON")
    else
        State.nearby_open_generation = State.nearby_open_generation + 1
        Scanner.nearby.active = false
        stop_nearby_loop()
        Scanner.reset_nearby()
        sync_hook()
        Util.log("Nearby panel OFF")
    end
end

local function cycle_sort()
    if State.settings_open or not State.panel_open then return end
    local mode = Scanner.cycle_sort(cfg)
    Config.queue_save()
    Util.log("Sort: " .. mode)
end

local function next_page()
    if State.settings_open or not State.panel_open then return end
    Scanner.next_page(cfg)
end

-- ------------------------------------------------------------ keybinds

local MOD_NAMES = { CTRL = "CONTROL", CONTROL = "CONTROL", ALT = "ALT", SHIFT = "SHIFT" }

local function bind(spec, action, fn)
    local ok, err = pcall(function()
        local tokens = {}
        for token in string.gmatch(spec or "", "[^+]+") do tokens[#tokens + 1] = token:upper() end
        if #tokens == 0 then error("empty keybind") end
        local key_name = tokens[#tokens]
        local key = Key[key_name]
        if key == nil then error("unknown key " .. key_name) end
        local mods = {}
        for i = 1, #tokens - 1 do
            local m = MOD_NAMES[tokens[i]]
            if m and ModifierKey[m] then mods[#mods + 1] = ModifierKey[m] end
        end
        local handler = function()
            local ok2, err2 = pcall(fn)
            if not ok2 then Util.log("ERROR " .. action .. ": " .. tostring(err2)) end
        end
        if #mods > 0 then
            RegisterKeyBind(key, mods, handler)
        else
            RegisterKeyBind(key, handler)
        end
    end)
    if ok then
        Util.dbg(action .. ": " .. spec)
    else
        Util.log("WARNING: could not bind " .. tostring(spec) .. " for " .. action
            .. " (" .. tostring(err) .. ")")
    end
end

-- ------------------------------------------------------------ startup

Util.log("PalScouter v" .. VERSION .. " loading (client-only, read-only)")

-- UE4SS remote DrawHUD submissions create userdata faster than Lua's default
-- collector keeps pace with the always-visible panel. Keep collection
-- incremental, but restart close to the previous live-set size and do enough
-- work per step that the heap does not ratchet upward between long full cycles.
-- Both controls are standard Lua APIs and remain feature-detected for hosts
-- that compile a restricted collector surface.
local GC_PAUSE = 110
local GC_STEP_MULTIPLIER = 300
local pause_ok, previous_pause = pcall(collectgarbage, "setpause", GC_PAUSE)
local step_ok, previous_step_multiplier = pcall(
    collectgarbage, "setstepmul", GC_STEP_MULTIPLIER)
if Util.PROFILE then
    if pause_ok and step_ok then
        Util.log(string.format("GC tuned pause=%d stepmul=%d (was %s/%s)",
            GC_PAUSE, GC_STEP_MULTIPLIER,
            tostring(previous_pause), tostring(previous_step_multiplier)))
    else
        Util.log("WARNING: incremental GC tuning unavailable")
    end
end

pcall(function()
    math.randomseed(os.time() + math.floor(os.clock() * 1000))
    for _ = 1, 3 do math.random() end
end)
pcall(Config.load)
Scanner.sort_mode = cfg.Sort or "score"
Config.sanitize()

local native_ready, native_error, native_version = Scanner.native_status()
if native_ready then
    Util.log("Native snapshot core ON (" .. tostring(native_version) .. ")")
else
    Util.log("ERROR: Native snapshot core unavailable: " .. tostring(native_error))
end

local map_ok, map_err = pcall(RegisterLoadMapPreHook, function()
    if State.settings_open then
        close_settings()
    end
    if State.pal_picker_open then
        Picker.discard()
        State.pal_picker_open = false
    end
    Scanner.reset_player_cache()
    Scanner.clear_aim()
    Scanner.reset_nearby(false)
end)
if not map_ok then Util.log("WARNING: map lifecycle hook unavailable: " .. tostring(map_err)) end

bind(cfg.Keys.TogglePanel, "Toggle nearby panel", toggle_panel)
bind(cfg.Keys.ToggleSettings, "Toggle settings modal", toggle_settings)
bind(cfg.Keys.CycleSort, "Cycle sort", cycle_sort)
bind(cfg.Keys.ToggleCard, "Toggle aim card", toggle_card)
bind(cfg.Keys.NextPage, "Next page", next_page)
bind("ESCAPE", "Close picker or settings", function()
    Util.log("INFO: ESCAPE key pressed. settings_open=" .. tostring(State.settings_open) .. ", picker_open=" .. tostring(State.pal_picker_open))
    if State.pal_picker_open then
        close_pal_picker(true)
    elseif State.move_target ~= nil then
        State.move_target = nil
    elseif State.settings_open then
        close_settings()
    end
end)

bind("UP_ARROW", "Settings focus up", function() settings_nav("up") end)
bind("DOWN_ARROW", "Settings focus down", function() settings_nav("down") end)
bind("LEFT_ARROW", "Settings value prev", function() settings_nav("prev") end)
bind("RIGHT_ARROW", "Settings value next", function() settings_nav("next") end)
-- UE4SS can dispatch both SHIFT+RETURN and plain RETURN for one key edge.
-- Let the aimed-Pal shortcut claim that edge before delayed settings Enter.
-- Picker Enter remains immediate so list selection still feels responsive.
local watch_aim_toggle_at = -1e9
bind("RETURN", "Settings activate", function()
    if State.pal_picker_open then
        settings_nav("activate")
        return
    end
    if not State.settings_open then return end
    pcall(ExecuteWithDelay, 40, function()
        if (os.clock() - watch_aim_toggle_at) < 0.2 then return end
        if State.pal_picker_open or not State.settings_open then return end
        settings_nav("activate")
    end)
end)
bind("SHIFT+RETURN", "Watchlist aim toggle", function()
    if not State.settings_open or State.pal_picker_open then return end
    if Settings.focus ~= Settings.watch_row_index() then return end
    watch_aim_toggle_at = os.clock()
    apply_settings_action("watch_toggle")
end)

-- Search input is inert outside the picker, so normal gameplay keys retain
-- their existing behavior while the overlay is closed.
local function bind_picker_char(key_name, ch)
    bind(key_name, "Picker type " .. key_name, function()
        if State.pal_picker_open then
            Picker.type_char(ch)
            request_picker_warm()
        end
    end)
end
for i = 0, 25 do
    local letter = string.char(65 + i)
    bind_picker_char(letter, string.char(97 + i))
end
local DIGITS = {
    { "ZERO", "0" }, { "ONE", "1" }, { "TWO", "2" }, { "THREE", "3" }, { "FOUR", "4" },
    { "FIVE", "5" }, { "SIX", "6" }, { "SEVEN", "7" }, { "EIGHT", "8" }, { "NINE", "9" },
}
for i = 1, #DIGITS do bind_picker_char(DIGITS[i][1], DIGITS[i][2]) end
bind("SPACE", "Settings activate / Picker toggle", function()
    if State.pal_picker_open then
        settings_nav("activate")
    elseif State.settings_open then
        settings_nav("activate")
    end
end)
bind("BACKSPACE", "Picker backspace / Settings close", function()
    if State.pal_picker_open then
        Picker.backspace()
        request_picker_warm()
    elseif State.settings_open then
        if State.move_target ~= nil then
            State.move_target = nil
        else
            close_settings()
        end
    end
end)

local function start_aim_if_needed()
    if (cfg.AimCard.ShowMode or "always") == "off" or State.aim_started then return end
    State.aim_started = true
    schedule_aim()
    Util.dbg("Static caches ready — aim scanner started")
end

local warm_attempts = 0
local function kick_warm()
    if State.caches_ready then
        start_aim_if_needed()
        return
    end
    warm_attempts = warm_attempts + 1
    if State.warm_queued then
        local delay = 400 + math.random(-40, 40)
        pcall(ExecuteWithDelay, delay, kick_warm)
        return
    end
    Util.run_queued_game_thread(State, "warm_queued", function()
        local ok, controller = pcall(function() return UEHelpers.GetPlayerController() end)
        if ok and controller ~= nil and Util.valid(controller) then
            G.warm_static_caches(controller)
        end
        if G.static_caches_ready() or warm_attempts >= 25 then
            State.caches_ready = true
            start_aim_if_needed()
            Util.dbg("Static skill cache ready — aim scanner started")
            return
        end
        local delay = 400 + math.random(-40, 40)
        pcall(ExecuteWithDelay, delay, kick_warm)
    end, "skill cache warm")
end

ensure_warm = function()
    if State.caches_ready then
        start_aim_if_needed()
        return
    end
    if State.warm_started then return end
    State.warm_started = true
    local delay = 100 + math.random(-15, 15)
    pcall(ExecuteWithDelay, delay, kick_warm)
end

if cfg.Enabled and (cfg.AimCard.ShowMode or "always") ~= "off" then ensure_warm() end

if Util.PROFILE then
    Profile.set_context(function()
        local n = Scanner.nearby
        local pending = (n.stage_count or 0)
            + math.max(0, (n.work_tail or 0) - (n.work_head or 1) + 1)
            + (n.native_more and 1 or 0)
        return {
            cache = count_pairs(n.cache),
            verdicts = count_pairs(n.verdicts),
            pending = pending,
            rows = Scanner.filtered_count or 0,
            tex = count_pairs(UI.texture_cache),
            missing = count_pairs(UI.texture_missing),
            wanted = #(UI.texture_wanted or {}),
            failed = count_pairs(UI.texture_load_failed),
            colors = count_pairs(UI.color_cache),
            mats = count_pairs(UI.material_cache),
            hook = State.hook_ids ~= nil and 1 or 0,
        }
    end)
    Profile.start_dump_loop(10000)
    Util.log("PROFILE on — dumping [perf]/[mem] every 10s to UE4SS.log")
end

Util.log("Ready. " .. tostring(cfg.Keys.TogglePanel) .. " nearby panel; "
    .. tostring(cfg.Keys.ToggleSettings) .. " settings (arrows).")
