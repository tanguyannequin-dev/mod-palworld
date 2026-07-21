-- PalScouter ui_settings.lua — settings menu.
local Util = require("util")
local Config = require("config")
local UI = require("ui")
local L = require("localization")

local Settings = {
    focus = 1, -- 1..#ROWS, or #ROWS+1 for Close
}

local MODAL_W = 600
local ROW_H = 32
local PAD = 16
local HEADER_H = 48
local BTN_W = 28

Settings.ROWS = {
    { id = "language", label = "opt_language" },
    { id = "dist", label = "opt_distance" },
    { id = "interval", label = "opt_refresh" },
    { id = "mode", label = "opt_score" },
    { id = "filter", label = "opt_filter" },
    { id = "own", label = "opt_ownership" },
    { id = "watch", label = "opt_watchlist" },
    { id = "sort", label = "opt_sort" },
    { id = "rows", label = "opt_rows" },
    { id = "aimen", label = "opt_aimcard" },
    { id = "aimdelay", label = "opt_aimdelay" },
    { id = "aimsize", label = "opt_aimsize" },
    { id = "aimop", label = "opt_aimopacity" },
    { id = "aimmove", label = "opt_moveaim" },
    { id = "panelsize", label = "opt_panelsize" },
    { id = "panelop", label = "opt_panelopacity" },
    { id = "panelmove", label = "opt_movepanel" },
    { id = "basehide", label = "opt_hideinbase" },
}

local function value_for(id, cfg)
    local lang = cfg.Language
    if id == "language" then
        local raw = cfg.Language or "system"
        return L.t("val_" .. raw, lang)
    end
    if id == "dist" then return tostring(cfg.Scan.RadiusMeters or 100) .. " m" end
    if id == "interval" then return Config.interval_label(cfg.Scan.IntervalMs) end
    if id == "mode" then
        local raw = cfg.Score.Mode or "combat"
        return L.t("val_" .. raw, lang)
    end
    if id == "filter" then
        local preset = cfg.Filter.Preset or "Off"
        if preset == "Off" then return L.t("val_off", lang) end
        return string.upper(preset)
    end
    if id == "own" then
        local own = cfg.Filter.Ownership or "wild"
        if own == "wild" then return L.t("val_wild_only", lang)
        elseif own == "all" then return L.t("val_all", lang)
        else return L.t("val_owned_only", lang)
        end
    end
    if id == "watch" then
        local names = nil
        local ok, Picker = pcall(require, "ui_pal_picker")
        if ok and Picker and Picker.display_names then names = Picker.display_names() end
        local lbl = Config.watchlist_label(cfg, names)
        if lbl == "OFF" then return L.t("val_off", lang) end
        return lbl
    end
    if id == "sort" then
        local sort = cfg.Sort or "score"
        return L.t("val_" .. sort, lang)
    end
    if id == "rows" then return tostring(cfg.Panel.MaxRows or 10) end
    if id == "aimen" then
        local mode = cfg.AimCard.ShowMode or "always"
        return L.t("val_" .. mode, lang)
    end
    if id == "aimdelay" then return Config.aim_delay_label(cfg.AimCard.AcquireMs) end
    if id == "aimsize" then return Config.scale_label(cfg.AimCard.Scale) end
    if id == "panelsize" then return Config.scale_label(cfg.Panel.Scale) end
    if id == "aimmove" then
        return string.format("%.0f,%.0f", cfg.AimCard.OffsetX or -500, cfg.AimCard.OffsetY or 24)
    end
    if id == "panelmove" then
        return string.format("%.0f,%.0f", cfg.Panel.OffsetX or 20, cfg.Panel.OffsetY or 140)
    end
    if id == "aimop" then
        return tostring(math.floor((cfg.AimCard.BackgroundOpacity or 0.9) * 100 + 0.5)) .. "%"
    end
    if id == "panelop" then
        return tostring(math.floor((cfg.Panel.BackgroundOpacity or 0.9) * 100 + 0.5)) .. "%"
    end
    if id == "basehide" then
        local hide = cfg.Base and cfg.Base.HideUiInBase
        return L.t(hide and "val_on" or "val_off", lang)
    end
    return "?"
end

local function draw_chevron_btn(hud, label, x, y, w, h, s, lit)
    local bg = lit and UI.col.bg_deep or UI.col.row
    UI.rect(hud, bg, x, y, w, h)
    UI.rect(hud, lit and UI.col.accent or UI.col.hairfaint, x, y, w, 1)
    UI.rect(hud, lit and UI.col.accent or UI.col.hairfaint, x, y + h - 1, w, 1)
    UI.rect(hud, lit and UI.col.accent or UI.col.hairfaint, x, y, 1, h)
    UI.rect(hud, lit and UI.col.accent or UI.col.hairfaint, x + w - 1, y, 1, h)
    local tw = #label * 8 * s
    UI.text(hud, label, UI.col.accent, x + (w - tw) / 2, UI.vtext_y(y, h, 0.70, s), 0.70 * s)
end

function Settings.row_count()
    return #Settings.ROWS
end

function Settings.move_delta(target, dir)
    local dx, dy = 0, 0
    if dir == "up" then dy = -1
    elseif dir == "down" then dy = 1
    elseif dir == "prev" then dx = -1
    elseif dir == "next" then dx = 1
    else return nil end
    if target == "Panel" then dx = -dx end
    return dx, dy
end

function Settings.focus_action(delta_or_dir)
    local n = #Settings.ROWS
    local close_i = n + 1
    if Settings.focus < 1 then Settings.focus = 1 end
    if Settings.focus > close_i then Settings.focus = close_i end

    if delta_or_dir == "up" then
        Settings.focus = Settings.focus <= 1 and close_i or (Settings.focus - 1)
        return nil
    elseif delta_or_dir == "down" then
        Settings.focus = Settings.focus >= close_i and 1 or (Settings.focus + 1)
        return nil
    elseif delta_or_dir == "activate" then
        if Settings.focus == close_i then return "close" end
        local row = Settings.ROWS[Settings.focus]
        if not row then return nil end
        if row.id == "watch" then return "watch_open" end
        return row.id .. "_next"
    elseif delta_or_dir == "prev" or delta_or_dir == "next" then
        if Settings.focus == close_i then return nil end
        local row = Settings.ROWS[Settings.focus]
        if not row then return nil end
        return row.id .. "_" .. delta_or_dir
    end
    return nil
end

function Settings.draw(hud, cfg, sw, sh)
    local s = Util.clamp(sh / 1080, 0.85, 1.5)
    local rows_n = #Settings.ROWS
    local body_h = rows_n * ROW_H * s + 18 * s
    local footer_h = 56 * s
    local h = HEADER_H * s + body_h + footer_h
    local w = MODAL_W * s
    local x = (sw - w) / 2
    local y = (sh - h) / 2

    UI.rect(hud, { 0, 0, 0, 0.45 }, 0, 0, sw, sh)
    UI.panel(hud, x, y, w, h, HEADER_H * s, 0.94, s)

    local pad = PAD * s
    UI.section(hud, L.t("title_settings", cfg.Language), x + pad, y + 10 * s, w - pad * 2, s)

    local ry = y + HEADER_H * s + 4 * s
    local label_x = x + pad
    local btn_w = BTN_W * s
    local right = x + w - pad
    local val_w = 200 * s
    local prev_x = right - btn_w * 2 - 8 * s - val_w
    local next_x = right - btn_w
    local focus = Settings.focus or 1

    for i = 1, rows_n do
        local row = Settings.ROWS[i]
        local rh = ROW_H * s
        local focused = (focus == i)
        if focused then
            UI.rect(hud, UI.col.bg_deep, x + 4 * s, ry, w - 8 * s, rh - 2 * s)
            UI.rect(hud, UI.col.accent, x + 4 * s, ry, 3 * s, rh - 2 * s)
        elseif i % 2 == 0 then
            UI.rect(hud, UI.col.row, x + 4 * s, ry, w - 8 * s, rh - 2 * s)
        end
        UI.text(hud, L.t(row.label, cfg.Language), focused and UI.col.white or UI.col.dim,
            label_x + (focused and 6 * s or 0), UI.vtext_y(ry, rh, 0.58, s), 0.58 * s)
        local val = value_for(row.id, cfg)
        draw_chevron_btn(hud, "<", prev_x, ry + 3 * s, btn_w, rh - 8 * s, s, focused)
        local val_text_w = #val * 13.5 * 0.70 * s
        local value_x = prev_x + btn_w + (val_w - val_text_w) / 2
        UI.text(hud, val, UI.col.white, value_x, UI.vtext_y(ry, rh, 0.70, s), 0.70 * s)
        draw_chevron_btn(hud, ">", next_x, ry + 3 * s, btn_w, rh - 8 * s, s, focused)
        ry = ry + rh
    end

    local close_w = 120 * s
    local close_h = 28 * s
    local cx = x + (w - close_w) / 2
    local cy = y + h - footer_h + 6 * s
    local close_focused = (focus == rows_n + 1)
    UI.rect(hud, UI.col.bg_deep, cx, cy, close_w, close_h)
    UI.rect(hud, close_focused and UI.col.gold or UI.col.accent, cx, cy, 3 * s, close_h)
    local close_text = L.t("hint_close", cfg.Language)
    local close_text_w = #close_text * 13.5 * 0.70 * s
    local close_x = cx + (close_w - close_text_w) / 2
    UI.text(hud, close_text, UI.col.white, close_x, UI.vtext_y(cy, close_h, 0.70, s), 0.70 * s)

    local help_text = L.t("help_settings", cfg.Language)
    UI.text(hud, help_text, UI.col.faint, x + pad, cy + close_h + 4 * s, 0.40 * s)
end

function Settings.watch_row_index()
    for i = 1, #Settings.ROWS do
        if Settings.ROWS[i].id == "watch" then return i end
    end
    return nil
end

return Settings
