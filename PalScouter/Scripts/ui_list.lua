-- PalScouter ui_list.lua — nearby wild-Pals panel.
-- Same native menu language as the aim card: section bands, boxed rows,
-- grade chips, dim column labels, and quality-colored IVs.
local Util = require("util")
local G = require("gamedata")
local UI = require("ui")
local L = require("localization")

local List = {}

-- Column x-offsets (unscaled units, multiplied by panel scale at draw time).
-- Spaced so multi-letter headers (SEX, DIST) and H/A/D don't collide.
local COL = {
    grade = 14, score = 54, name = 114, lv = 295, sex = 338,
    dist = 400, iv_h = 502, iv_a = 556, iv_d = 610, passive = 655,
}
local PANEL_W = 880
-- Title + status only; column labels sit in the body below this divider.
local HEADER_H = 52
local ROW_H = 28          -- base row (0–1 passives)
local PASSIVE_LINE_H = 16 -- extra height per passive beyond the first

local function passive_count(entry)
    return #(entry.passives or {})
end

local function row_height(entry, s)
    local n = passive_count(entry)
    local extra = math.max(0, n - 1) * PASSIVE_LINE_H
    return (ROW_H + extra) * s
end

local function iv_cell(hud, x, y, s, v)
    UI.text(hud, v ~= nil and tostring(v) or "?", UI.iv_color(v), x, y, 0.85 * s)
end

local function draw_footer(hud, x, y, w, h, pad, s, lang)
    local footer_hints = {
        { key = "F6", label = L.t("hint_sort", lang), x = 0 },
        { key = "F7", label = L.t("hint_settings", lang), x = 120 },
        { key = "SHIFT+F7", label = L.t("hint_next", lang), x = 280 },
        { key = "F8", label = L.t("hint_close", lang), x = 460 },
    }
    local fy = y + h - 25 * s
    for _, seg in ipairs(UI.hband_steps(w - pad * 2, 6)) do
        UI.rect(hud, UI.col.band, x + pad + seg.dx, fy - 5 * s, seg.w, 2,
            UI.col.band[4] * seg.af)
    end
    for i = 1, #footer_hints do
        local hx = x + pad + footer_hints[i].x * s
        UI.text(hud, footer_hints[i].key, UI.col.accent, hx, fy, 0.58 * s)
        UI.text(hud, footer_hints[i].label, UI.col.dim,
            hx + (#footer_hints[i].key * 9.0 + 14) * s, fy, 0.58 * s)
    end
end

-- Panel frame height. compact = header band + one message line (empty panel).
function List.height(rows, s, compact)
    if compact then return (HEADER_H + 36) * s end
    local rows_h = 0
    if #rows == 0 then
        rows_h = ROW_H * s
    else
        for i = 1, #rows do rows_h = rows_h + row_height(rows[i], s) end
    end
    return HEADER_H * s + 36 * s + rows_h + 40 * s
end

function List.draw(hud, scanner, cfg, sw, sh, force_full, frame)
    local s = (cfg.Panel.Scale or 1.0) * Util.clamp(sh / 1080, 0.85, 1.5)
    local pad = 14 * s
    local w = PANEL_W * s
    local rows = scanner.visible_rows or {}
    local compact = (#rows == 0) and not force_full
    local h = List.height(rows, s, compact)
    local lang = cfg.Language

    local x = sw - w - (cfg.Panel.OffsetX or 20)
    local y = cfg.Panel.OffsetY or 140
    x = Util.clamp(x, 8, math.max(8, sw - w - 8))
    y = Util.clamp(y, 8, math.max(8, sh - h - 8))

    local opacity = cfg.Panel.BackgroundOpacity or 0.90
    UI.panel(hud, x, y, w, h, HEADER_H * s, opacity, s)

    local title_y = y + 8 * s
    UI.section(hud, L.t("title_nearby", lang), x + pad, title_y, w - pad * 2, s)
    UI.text(hud, scanner.header or "", UI.col.dim, x + pad, y + 33 * s, 0.58 * s)

    if #rows == 0 then
        local msg = scanner.empty_reason
        if msg ~= nil then
            -- Scanner includes the active score mode and threshold here. This
            -- distinguishes a working-but-empty travel/work filter from no scan.
        elseif (scanner.wild_count or 0) == 0 then
            msg = ((cfg.Filter and cfg.Filter.Ownership) == "all")
                and L.t("msg_no_pals", lang) or L.t("msg_no_wild", lang)
        else
            msg = L.t("msg_no_match", lang)
        end
        UI.text(hud, msg, UI.col.dim, x + pad + 4 * s, y + (HEADER_H + 8) * s, 0.72 * s)
        if not compact then draw_footer(hud, x, y, w, h, pad, s, lang) end
        return x, y, w, h
    end

    -- Column labels sit just under the header divider; results box starts below them.
    local column_labels = {
        { L.t("col_grade", lang), COL.grade }, { L.t("col_score", lang), COL.score }, 
        { L.t("col_pal", lang), COL.name }, { L.t("col_lv", lang), COL.lv },
        { L.t("col_sex", lang), COL.sex }, { L.t("col_dist", lang), COL.dist }, 
        { L.t("col_h", lang), COL.iv_h }, { L.t("col_a", lang), COL.iv_a },
        { L.t("col_d", lang), COL.iv_d }, { L.t("col_passive", lang), COL.passive },
    }
    local cy = y + (HEADER_H + 2) * s
    for i = 1, #column_labels do
        UI.text(hud, column_labels[i][1], UI.col.faint,
            x + column_labels[i][2] * s, cy, 0.62 * s)
    end
    local ry = cy + 30 * s
    for i = 1, #rows do
        local e = rows[i]
        local rh = row_height(e, s)
        local box_h = rh - 2 * s
        UI.row_box(hud, x + 4 * s, ry, w - 8 * s, box_h)
        UI.grade_chip(hud, e.grade or "?", x + COL.grade * s, ry + 1 * s, s * 0.95)
        UI.text(hud, e.score ~= nil and tostring(e.score) or "--", UI.col.text, x + COL.score * s, ry + 2 * s, 0.70 * s)
        local name_x = x + COL.name * s
        UI.pal_icon(hud, e.character_id, name_x - 30 * s, ry, 24 * s, frame)
        if e.is_alpha then
            UI.text(hud, "*", UI.col.gold, name_x, ry + 2 * s, 0.70 * s)
            name_x = name_x + 10 * s
        end
        local name = Util.truncate(e.name or "?", 19)
        UI.text(hud, name, UI.col.text, name_x, ry + 2 * s, 0.70 * s)
        UI.text(hud, tostring(e.level or "?"), UI.col.text, x + COL.lv * s, ry + 2 * s, 0.70 * s)
        local gender = G.GENDER_NAMES[e.gender or 0] or "?"
        UI.text(hud, gender, UI.col.dim, x + COL.sex * s, ry + 2 * s, 0.70 * s)
        UI.text(hud, e.dist_disp or "?", UI.col.dim, x + COL.dist * s, ry + 2 * s, 0.70 * s)
        iv_cell(hud, x + COL.iv_h * s, ry + 2 * s, s * 0.82, e.ivs and e.ivs.hp)
        iv_cell(hud, x + COL.iv_a * s, ry + 2 * s, s * 0.82, e.ivs and e.ivs.atk)
        iv_cell(hud, x + COL.iv_d * s, ry + 2 * s, s * 0.82, e.ivs and e.ivs.def)
        local passives = e.passives or {}
        local px = x + COL.passive * s
        local pscale = 0.70 * s
        local max_chars = 24
        for pi = 1, #passives do
            local p = passives[pi]
            local label = Util.truncate(p.name or "?", max_chars)
            UI.text(hud, label, UI.passive_color(p.rank),
                px, ry + 2 * s + (pi - 1) * PASSIVE_LINE_H * s, pscale)
        end
        if e.wild == "unknown" then
            UI.text(hud, "?", UI.col.faint, x + w - 14 * s, ry, 0.85 * s)
        end
        ry = ry + rh
    end
    draw_footer(hud, x, y, w, h, pad, s, lang)
    return x, y, w, h
end

return List
