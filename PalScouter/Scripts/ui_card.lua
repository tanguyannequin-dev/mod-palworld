-- PalScouter ui_card.lua — aim card in Palworld 1.0's native menu language.
local Util = require("util")
local UI = require("ui")
local Score = require("score")
local Profile = require("profile")
local Config = require("config")
local L = require("localization")

local Card = {}

-- Layout constants (unscaled units). Card.height() and Card.draw() must agree.
local W = 320
local PAD = 12
local HEADER_H = 62
local SECTION_H = 21          -- section bar (16) + gap before rows
local STAT_ROW_H = 24
local WORK_ROW_H = 26
local SKILL_ROW_H = 26
local PASSIVE_ROW_H = 28
local GAP = 6
local SCORE_H = 34

local function content_rows(list) return math.max(#(list or {}), 1) end

local function stat_labels_for()
    local lang = Config.current.Language
    return {
        attack = L.t("label_attack", lang),
        defense = L.t("label_defense", lang),
        work_speed = L.t("label_work_speed", lang),
    }
end

Card.stat_labels_for = stat_labels_for

local EMPTY = {}

local function health_text(data)
    if data.hp == nil or data.max_hp == nil or data.max_hp <= 0 then return nil end
    local current = Util.round(data.hp)
    local maximum = Util.round(data.max_hp)
    if data._ui_hp_current ~= current or data._ui_hp_maximum ~= maximum then
        data._ui_hp_current = current
        data._ui_hp_maximum = maximum
        data._ui_hp_text = string.format("%d / %d", current, maximum)
    end
    return data._ui_hp_text
end

function Card.height(data)
    return HEADER_H + 10
        + SECTION_H + STAT_ROW_H * 4 + GAP                            -- stats (hp + 3 rows)
        + SECTION_H + WORK_ROW_H + GAP                                -- work suitability
        + SECTION_H + SKILL_ROW_H * content_rows(data.active_skills) + GAP
        + SECTION_H + PASSIVE_ROW_H * content_rows(data.passives) + GAP
        + SCORE_H + 6
end

local function draw_passives(hud, cx, py, cw, s, passives, lang)
    UI.section(hud, L.t("card_passive", lang), cx, py, cw, s)
    local y = py + SECTION_H * s
    if #passives == 0 then
        UI.row_box(hud, cx, y, cw, (PASSIVE_ROW_H - 4) * s, UI.col.faint)
        UI.text(hud, L.t("card_no_passive", lang), UI.col.faint, cx + 8 * s, y + 3 * s, 0.50 * s)
        y = y + PASSIVE_ROW_H * s
    else
        for i = 1, #passives do
            local box_h = (PASSIVE_ROW_H - 4) * s
            UI.passive_row(hud, cx, y, cw, box_h, s, passives[i])
            y = y + PASSIVE_ROW_H * s
        end
    end
    return y + GAP * s
end

-- World->screen projection for the card anchor; throttled by main to every 30th frame.
-- Stores plain scalars only. data.screen: table {x,y} | false (behind camera) | nil (unknown).
function Card.update_projection(hud, data)
    local ok = pcall(function()
        local actor = data.actor
        if actor == nil or not Util.valid(actor) then
            data.screen = nil
            return
        end
        local x, y, z = tonumber(data.x), tonumber(data.y), tonumber(data.z)
        if x == nil or y == nil or z == nil then
            local loc
            local ok_loc, l = pcall(function() return actor:K2_GetActorLocation() end)
            if ok_loc and l ~= nil then loc = l end
            if loc ~= nil then x, y, z = tonumber(loc.X), tonumber(loc.Y), tonumber(loc.Z) end
        end
        if x == nil or y == nil or z == nil then
            data.screen = nil
            return
        end
        local elevated = { X = x, Y = y, Z = z + (data.anchor or 120) }
        local proj = hud:Project(elevated, true)
        if proj == nil and type(FVector) == "function" then
            local ok_fv, fv = pcall(FVector, elevated.X, elevated.Y, elevated.Z)
            if ok_fv and fv ~= nil then proj = hud:Project(fv, true) end
        end
        if proj == nil then
            data.screen = nil
            return
        end
        local px, py, depth = tonumber(proj.X), tonumber(proj.Y), tonumber(proj.Z)
        if px == nil or (depth or 0) <= 0 then
            data.screen = false
            return
        end
        data.screen = { x = px, y = py }
    end)
    if not ok then data.screen = nil end
end

function Card.draw(hud, data, cfg, sw, sh, frame)
    if data.screen == false then return end -- target behind camera

    local s = (cfg.AimCard.Scale or 1.0) * Util.clamp(sh / 1080, 0.85, 1.5)
    local w = W * s
    local h = Card.height(data) * s
    local passives = data.passives or EMPTY
    local active_skills = data.active_skills or EMPTY
    local works = data.works or EMPTY
    local lang = cfg.Language
    local stat_labels = stat_labels_for()

    -- Anchor beside the pal when projected; fixed fallback otherwise.
    local x, y
    if data.screen then
        x = data.screen.x + (cfg.AimCard.OffsetX or -500) * s
        y = data.screen.y + (cfg.AimCard.OffsetY or 24) * s
    else
        x = sw * 0.62
        y = sh * 0.30
    end
    x = Util.clamp(x, 8, math.max(8, sw - w - 8))
    y = Util.clamp(y, 8, math.max(8, sh - h - 8))

    local opacity = cfg.AimCard.BackgroundOpacity or 0.90
    UI.panel(hud, x, y, w, h, HEADER_H * s, opacity, s)

    local lb_w = UI.level_box(hud, data.level, x + 6 * s, y + 6 * s, s)
    local portrait_size = 40 * s
    local px = x + 6 * s + lb_w + 8 * s
    local portrait_drawn = UI.portrait(hud, data.character_id, px, y + 8 * s, portrait_size, frame)
    local name_x = portrait_drawn and (px + portrait_size + 8 * s) or px
    if data.is_alpha then
        UI.text(hud, "◆", UI.col.gold, name_x, y + 10 * s, 0.62 * s)
        name_x = name_x + 15 * s
    end
    UI.text(hud, Util.truncate(data.name or ("? " .. tostring(data.character_id or "Unknown")), 13),
        data.name_resolved and UI.col.white or UI.col.red, name_x, y + 7 * s, 0.88 * s)
    local tag_x = name_x + 2 * s
    for i, element in ipairs(data.elements or EMPTY) do
        tag_x = tag_x + UI.element_tag(hud, data.element_ids and data.element_ids[i],
            element, tag_x, y + 34 * s, s)
    end
    UI.gender_icon(hud, data.gender, x + w - 28 * s, y + 10 * s, 18 * s)

    local cx = x + PAD * s              -- content left edge
    local cw = w - PAD * 2 * s          -- content width
    local py = y + (HEADER_H + 10) * s

    -- STATS ------------------------------------------------------------
    UI.section(hud, L.t("card_stats", lang), cx, py, cw, s)
    UI.text(hud, "IV", UI.col.cyan, cx + cw - 25 * s, py - s, 0.40 * s)
    py = py + SECTION_H * s
    local row_h = (STAT_ROW_H - 3) * s
    UI.row_box(hud, cx, py, cw, row_h)
    local icon_slot = 22 * s
    UI.rect(hud, UI.col.icon_sq, cx + 2 * s, py + 2 * s, icon_slot - 2 * s, row_h - 4 * s)
    UI.status_icon(hud, 0, cx + 4 * s, py + (row_h - 14 * s) / 2, 14 * s)
    local bar_x = cx + icon_slot + 6 * s
    local bar_w = cw - icon_slot - 56 * s
    local bar_y = py + 2 * s
    local bar_h = row_h - 4 * s
    local hp_text_scale = 0.50
    UI.rect(hud, UI.col.track, bar_x, bar_y, bar_w, bar_h)
    local hp_text_y = UI.vtext_y(bar_y, bar_h, hp_text_scale, s) + 1 * s
    local hp_text = health_text(data)
    if hp_text ~= nil then
        UI.rect(hud, UI.col.hp, bar_x, bar_y, bar_w * Util.clamp(data.hp / data.max_hp, 0, 1), bar_h)
        UI.text(hud, hp_text, UI.col.text, bar_x + 6 * s, hp_text_y, hp_text_scale * s)
    else
        UI.text(hud, "? / ?", UI.col.faint, bar_x + 6 * s, hp_text_y, hp_text_scale * s)
    end
    local hp_iv = data.ivs and data.ivs.hp
    local hp_iv_text = hp_iv ~= nil and tostring(hp_iv) or "?"
    UI.text(hud, hp_iv_text, UI.iv_color(hp_iv),
        UI.right_text_x(hp_iv_text, cx + cw - 10 * s, s), UI.vtext_y(py, row_h, 0.58, s), 0.58 * s)
    py = py + STAT_ROW_H * s
    UI.stat_row(hud, cx, py, cw, row_h, s, 2, stat_labels.attack,
        data.atk ~= nil and Util.round(data.atk) or nil, data.ivs and data.ivs.atk, true)
    py = py + STAT_ROW_H * s
    UI.stat_row(hud, cx, py, cw, row_h, s, 3, stat_labels.defense,
        data.def ~= nil and Util.round(data.def) or nil, data.ivs and data.ivs.def, true)
    py = py + STAT_ROW_H * s
    UI.stat_row(hud, cx, py, cw, row_h, s, 5, stat_labels.work_speed,
        data.craft ~= nil and Util.round(data.craft) or nil, nil, false)
    py = py + (STAT_ROW_H + GAP) * s

    -- WORK SUITABILITY ---------------------------------------------------
    UI.section(hud, L.t("card_work", lang), cx, py, cw, s)
    py = py + SECTION_H * s
    local work_x = cx + 2 * s
    for _, work in ipairs(works) do
        UI.work_icon(hud, work.id, work_x, py, 18 * s)
        UI.text(hud, "Lv. " .. tostring(work.rank or "?"), UI.col.white,
            work_x + 21 * s, UI.vtext_y(py, 18 * s, 0.56, s), 0.56 * s)
        work_x = work_x + 58 * s
    end
    if #works == 0 then UI.text(hud, L.t("val_none", lang), UI.col.faint, work_x, py + 4 * s, 0.62 * s) end
    py = py + (WORK_ROW_H + GAP) * s

    -- ACTIVE SKILLS ------------------------------------------------------
    UI.section(hud, L.t("card_active", lang), cx, py, cw, s)
    py = py + SECTION_H * s
    if #active_skills == 0 then
        UI.row_box(hud, cx, py, cw, (SKILL_ROW_H - 4) * s, UI.col.faint)
        UI.text(hud, L.t("card_no_active", lang), UI.col.faint, cx + 8 * s, py + 4 * s, 0.50 * s)
        py = py + SKILL_ROW_H * s
    else
        for _, skill in ipairs(active_skills) do
            local box_h = (SKILL_ROW_H - 4) * s
            UI.row_box(hud, cx, py, cw, box_h)
            local skill_label = skill.name or ("? " .. tostring(skill.raw or skill.id or "Unknown"))
            UI.text(hud, Util.truncate(skill_label, 22),
                skill.name and UI.col.white or UI.col.red, cx + 10 * s,
                UI.vtext_y(py, box_h, 0.54, s), 0.54 * s)
            local wedge_w = 84 * s
            local wx = cx + cw - wedge_w
            local fill = UI.ELEMENT_COLORS[tonumber(skill.element)] or UI.col.chip
            for _, r in ipairs(UI.chip_rects(wedge_w, box_h, s, true, 12 * s)) do
                UI.rect(hud, fill, wx + r.dx, py + r.dy, r.w, r.h)
            end
            UI.element_icon(hud, skill.element, wx + 16 * s, py + (box_h - 15 * s) / 2, 15 * s)
            local power = skill.power and tostring(skill.power) or "?"
            UI.text(hud, power, UI.col.white,
                UI.right_text_x(power, cx + cw - 8 * s, s),
                UI.vtext_y(py, box_h, 0.58, s), 0.58 * s)
            py = py + SKILL_ROW_H * s
        end
    end
    py = py + GAP * s

    -- PASSIVE SKILLS ------------------------------------------------------
    py = Profile.span("hud.card.passives", draw_passives,
        hud, cx, py, cw, s, passives, lang)

    -- Role score band ------------------------------------------------------
    UI.rect(hud, UI.col.hairline, x, py, w, 1)
    local band_h = SCORE_H * s
    UI.rect(hud, UI.col.bg_deep, x + 1, py + 1, w - 2, band_h, math.min(1, opacity + 0.05))
    local mode = (cfg.Score and cfg.Score.Mode) or "combat"
    local score_label = L.t("score_" .. mode, lang)
    UI.text(hud, score_label, UI.col.dim, x + PAD * s,
        UI.vtext_y(py, band_h, 0.48, s), 0.48 * s)
    local gx = x + (PAD + 118) * s
    UI.grade_chip(hud, data.grade or "?", gx, py + (band_h - 18 * s) / 2, s)
    UI.text(hud, data.score ~= nil and tostring(data.score) or "--",
        UI.col.white, gx + 30 * s, UI.vtext_y(py, band_h, 0.76, s), 0.76 * s)
    return x, y, w, h
end

return Card
