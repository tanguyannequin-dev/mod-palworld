-- PalScouter ui_pal_picker.lua — searchable nested SELECT PALS overlay.
local Util = require("util")
local UI = require("ui")
local Config = require("config")
local L = require("localization")
local icon_names_ok, PAL_ICON_NAMES = pcall(require, "pal_icon_names")
if not icon_names_ok or type(PAL_ICON_NAMES) ~= "table" then PAL_ICON_NAMES = {} end

local Picker = {
    open_flag = false,
    search = "",
    focus = 1,
    scroll = 0,
    working = {},
    status = "",
    footer_focus = 0, -- 0 = list, 1 = CLEAR, 2 = DONE
    _catalog = nil,
    _filtered = nil,
    _names = {}, -- id_lower -> display name (for settings label)
    _casing = {}, -- id_lower -> canonical asset casing
    _summary = nil,
}

-- Shared with Config.normalize_watchlist (single source of truth).
Picker.DENY_EXACT = Config.WATCH_DENY_EXACT
Picker.DENY_PREFIXES = Config.WATCH_DENY_PREFIXES

local VISIBLE_ROWS = 10
local MODAL_W = 600
local ROW_H = 34
local PAD = 16
local HEADER_H = 48
local DIM_OVERLAY = { 0, 0, 0, 0.50 }
local FOCUSED_ROW = { 0.08, 0.18, 0.22, 0.95 }

function Picker.is_denied(id)
    return Config.is_watchlist_denied(id)
end

function Picker.build_catalog(icon_map, name_fn)
    local rows = {}
    for id_lower, casing in pairs(icon_map or {}) do
        local id = string.lower(tostring(id_lower))
        if not Picker.is_denied(id) then
            local name = name_fn and name_fn(id, tostring(casing or id)) or nil
            if type(name) ~= "string" or name == "" then
                name = tostring(casing or id)
            end
            rows[#rows + 1] = {
                id = id,
                name = name,
                sort = string.lower(name),
                casing = tostring(casing or id),
            }
        end
    end
    table.sort(rows, function(a, b)
        if a.sort == b.sort then return a.id < b.id end
        return a.sort < b.sort
    end)
    return rows
end

function Picker.filter_catalog(catalog, query)
    query = string.lower((tostring(query or "")):match("^%s*(.-)%s*$") or "")
    if query == "" then return catalog end
    local out = {}
    for i = 1, #(catalog or {}) do
        local row = catalog[i]
        local hay = string.lower((row.name or "") .. " " .. (row.id or ""))
        if string.find(hay, query, 1, true) then
            out[#out + 1] = row
        end
    end
    return out
end

function Picker.toggle_working(working, id, max)
    max = max or 8
    id = string.lower(tostring(id or ""))
    if id == "" then return working or {}, "noop" end
    local list = {}
    for i = 1, #(working or {}) do list[i] = working[i] end
    for i = 1, #list do
        if list[i] == id then
            table.remove(list, i)
            return list, "removed"
        end
    end
    if #list >= max then return list, "full" end
    list[#list + 1] = id
    return list, "added"
end

local function copy_list(src)
    local out = {}
    for i = 1, #(src or {}) do out[i] = src[i] end
    return out
end

local function working_has(id)
    for i = 1, #Picker.working do
        if Picker.working[i] == id then return true end
    end
    return false
end

local function selected_summary_names()
    local parts = {}
    for i = 1, #Picker.working do
        local id = Picker.working[i]
        parts[#parts + 1] = Picker._names[id] or string.upper(id)
        if #parts >= 4 then break end
    end
    if #Picker.working > 4 then
        parts[#parts + 1] = "+" .. tostring(#Picker.working - 4)
    end
    return table.concat(parts, ", ")
end

local function invalidate_summary()
    Picker._summary = nil
end

local function picker_summary()
    if Picker._summary ~= nil then return Picker._summary end
    local sel_n = #Picker.working
    local lang = Config.current.Language
    local summary = string.format("%d / %d %s", sel_n, Config.WATCHLIST_MAX, L.t("status_selected", lang))
    if sel_n > 0 then
        summary = summary .. "  ·  " .. selected_summary_names()
    end
    if Picker.status ~= "" then
        summary = summary .. "  ·  " .. string.upper(Picker.status)
    end
    Picker._summary = summary
    return summary
end

local function refilter()
    Picker._filtered = Picker.filter_catalog(Picker._catalog or {}, Picker.search)
    if Picker.focus < 1 then Picker.focus = 1 end
    if #Picker._filtered == 0 then
        Picker.focus = 1
        Picker.scroll = 0
        return
    end
    if Picker.focus > #Picker._filtered then Picker.focus = #Picker._filtered end
    if Picker.focus < Picker.scroll + 1 then
        Picker.scroll = Picker.focus - 1
    elseif Picker.focus > Picker.scroll + VISIBLE_ROWS then
        Picker.scroll = Picker.focus - VISIBLE_ROWS
    end
    if Picker.scroll < 0 then Picker.scroll = 0 end
end

function Picker.is_open()
    return Picker.open_flag == true
end

function Picker.display_names()
    return Picker._names
end

function Picker.ensure_catalog(name_fn)
    if Picker._catalog then return Picker._catalog end
    -- Prefer any already-warmed localized names so search works immediately.
    local function resolve(id, casing)
        if name_fn then
            local n = name_fn(id, casing)
            if type(n) == "string" and n ~= "" then return n end
        end
        local G = package.loaded["gamedata"]
        if type(G) == "table" and type(G.species_name_cache) == "table" then
            local n = G.species_name_cache[casing] or G.species_name_cache[id]
            if type(n) == "string" and n ~= "" then return n end
        end
        return nil
    end
    Picker._catalog = Picker.build_catalog(PAL_ICON_NAMES, resolve)
    for i = 1, #Picker._catalog do
        local row = Picker._catalog[i]
        Picker._names[row.id] = row.name
        Picker._casing[row.id] = row.casing
    end
    refilter()
    return Picker._catalog
end

function Picker.refresh_names(name_fn)
    if not Picker._catalog or type(name_fn) ~= "function" then return 0 end
    -- Preserve focused species across re-sort (warm updates change name order).
    local keep_id = nil
    if Picker.footer_focus == 0 and Picker._filtered then
        local row = Picker._filtered[Picker.focus]
        if row then keep_id = row.id end
    end
    local updated = 0
    for i = 1, #Picker._catalog do
        local row = Picker._catalog[i]
        local name = name_fn(row.id, row.casing)
        if type(name) == "string" and name ~= "" and name ~= row.name then
            row.name = name
            row.sort = string.lower(name)
            Picker._names[row.id] = name
            updated = updated + 1
        end
    end
    if updated > 0 then
        table.sort(Picker._catalog, function(a, b)
            if a.sort == b.sort then return a.id < b.id end
            return a.sort < b.sort
        end)
        refilter()
        if keep_id then
            local filtered = Picker._filtered or {}
            local n = 0
            for i = 1, #filtered do
                if filtered[i].id == keep_id then n = i break end
            end
            if n > 0 then Picker.focus = n end
        end
    end
    return updated
end

function Picker.type_char(ch)
    Picker.search = Picker.search .. ch
    refilter()
    invalidate_summary()
end

function Picker.backspace()
    if #Picker.search > 0 then
        -- Multi-byte backspace safety (utf8.offset fallback/byte-slicing).
        local length = utf8 and utf8.len(Picker.search)
        if length then
            local end_byte = utf8.offset(Picker.search, length)
            Picker.search = Picker.search:sub(1, end_byte - 1)
        else
            Picker.search = Picker.search:sub(1, #Picker.search - 1)
        end
        refilter()
        invalidate_summary()
    end
end

function Picker.clear_working()
    Picker.working = {}
    Picker.status = ""
    invalidate_summary()
end

function Picker.setup(watchlist)
    Picker.search = ""
    Picker.focus = 1
    Picker.scroll = 0
    Picker.footer_focus = 0
    Picker.working = copy_list(watchlist)
    Picker.status = ""
    refilter()
    invalidate_summary()
end

function Picker.commit()
    return Picker.working
end

function Picker.discard()
    Picker.working = {}
    invalidate_summary()
end

function Picker.handle(dir)
    local filtered = Picker._filtered or {}
    local n = #filtered

    if dir == "up" then
        if Picker.footer_focus == 1 or Picker.footer_focus == 2 then
            Picker.footer_focus = 0
            if n > 0 then Picker.focus = n end
            refilter()
            return nil
        end
        if n == 0 then return nil end
        Picker.focus = Picker.focus <= 1 and n or (Picker.focus - 1)
        refilter()
        return nil
    elseif dir == "down" then
        if Picker.footer_focus == 1 then
            Picker.footer_focus = 2
            return nil
        end
        if Picker.footer_focus == 2 then
            Picker.footer_focus = 0
            if n > 0 then Picker.focus = 1 end
            refilter()
            return nil
        end
        if n == 0 then
            Picker.footer_focus = 1
            return nil
        end
        if Picker.focus >= n then
            Picker.footer_focus = 1
            return nil
        end
        Picker.focus = Picker.focus + 1
        refilter()
        return nil
    elseif dir == "prev" then
        if Picker.footer_focus == 2 then
            Picker.footer_focus = 1
        end
        return nil
    elseif dir == "next" then
        if Picker.footer_focus == 1 then
            Picker.footer_focus = 2
        end
        return nil
    elseif dir == "activate" then
        local lang = Config.current.Language
        if Picker.footer_focus == 1 then
            Picker.clear_working()
            return nil
        end
        if Picker.footer_focus == 2 then
            return "done"
        end
        local row = Picker._filtered and Picker._filtered[Picker.focus]
        if not row then return nil end
        local list, result = Picker.toggle_working(Picker.working, row.id, Config.WATCHLIST_MAX)
        Picker.working = list
        if result == "full" then
            Picker.status = L.t("status_max", lang) .. " " .. tostring(Config.WATCHLIST_MAX)
        elseif result == "added" then
            Picker.status = L.t("status_added", lang)
        elseif result == "removed" then
            Picker.status = L.t("status_removed", lang)
        end
        invalidate_summary()
        return nil
    elseif dir == "clear" then
        Picker.clear_working()
        return nil
    elseif dir == "done" then
        return "done"
    end
    return nil
end

local function draw_btn(hud, label, x, y, w, h, s, lit)
    UI.rect(hud, lit and UI.col.bg_deep or UI.col.row, x, y, w, h)
    local border = lit and UI.col.gold or UI.col.hairfaint
    UI.rect(hud, border, x, y, w, 1)
    UI.rect(hud, border, x, y + h - 1, w, 1)
    UI.rect(hud, border, x, y, 1, h)
    UI.rect(hud, border, x + w - 1, y, 1, h)
    if lit then
        UI.rect(hud, UI.col.accent, x, y, 3 * s, h)
    end
    local tw = #label * 8 * s
    UI.text(hud, label, lit and UI.col.white or UI.col.accent,
        x + (w - tw) / 2, UI.vtext_y(y, h, 0.70, s), 0.70 * s)
end

local function draw_search_box(hud, x, y, w, h, s, text, frame)
    UI.rect(hud, UI.col.bg_deep, x, y, w, h)
    UI.rect(hud, UI.col.accent, x, y, w, 1)
    UI.rect(hud, UI.col.hairfaint, x, y + h - 1, w, 1)
    UI.rect(hud, UI.col.hairfaint, x, y, 1, h)
    UI.rect(hud, UI.col.hairfaint, x + w - 1, y, 1, h)
    local caret = (frame and (frame % 60) < 30) and "_" or " "
    local line
    if text ~= "" then
        line = text .. caret
    else
        line = "Type to filter..." .. ((frame and (frame % 60) < 30) and "_" or "")
    end
    UI.text(hud, line, text ~= "" and UI.col.white or UI.col.faint,
        x + 10 * s, UI.vtext_y(y, h, 0.62, s), 0.62 * s)
end

-- Rows currently on screen (for lazy name/icon warm). Pure; no UObject work.
function Picker.visible_rows()
    local filtered = Picker._filtered or {}
    local scroll = Picker.scroll or 0
    local out = {}
    for i = 1, VISIBLE_ROWS do
        local row = filtered[scroll + i]
        if row then out[#out + 1] = row end
    end
    return out
end

-- Canonical icon casing for a lowercase species id (PAL_NAME_* / FName).
function Picker.casing_for(id)
    id = string.lower(tostring(id or ""))
    if id == "" then return id end
    return Picker._casing[id] or PAL_ICON_NAMES[id] or id
end

function Picker.draw(hud, sw, sh, frame)
    if not Picker.open_flag then return end
    local s = Util.clamp(sh / 1080, 0.85, 1.5)
    local w = MODAL_W * s
    local row_h = ROW_H * s
    local list_h = VISIBLE_ROWS * row_h
    local search_h = 34 * s
    local body_extra = search_h + 28 * s -- search + selected summary
    local footer_h = 68 * s
    local h = HEADER_H * s + body_extra + list_h + footer_h + 8 * s
    local x = (sw - w) / 2
    local y = math.max(12 * s, (sh - h) / 2)
    local lang = Config.current.Language

    -- Nested overlay dim (settings may already be dimmed underneath).
    UI.rect(hud, DIM_OVERLAY, 0, 0, sw, sh)
    UI.panel(hud, x, y, w, h, HEADER_H * s, 0.96, s)

    local pad = PAD * s
    UI.section(hud, L.t("title_picker", lang), x + pad, y + 10 * s, w - pad * 2, s)

    local ry = y + HEADER_H * s + 6 * s
    draw_search_box(hud, x + pad, ry, w - pad * 2, search_h, s, Picker.search, frame)
    ry = ry + search_h + 8 * s

    UI.text(hud, picker_summary(), UI.col.dim, x + pad, ry, 0.48 * s)
    ry = ry + 20 * s

    local filtered = Picker._filtered or {}
    local scroll = Picker.scroll or 0
    local list_top = ry
    UI.rect(hud, UI.col.bg_deep, x + 4 * s, list_top, w - 8 * s, list_h)

    if #filtered == 0 then
        UI.text(hud, L.t("msg_no_pals", lang), UI.col.faint,
            x + pad + 8 * s, list_top + list_h / 2 - 8 * s, 0.62 * s)
    end

    for i = 1, VISIBLE_ROWS do
        local idx = scroll + i
        local row = filtered[idx]
        local yy = list_top + (i - 1) * row_h
        local focused = (Picker.footer_focus == 0 and idx == Picker.focus)
        if focused then
            UI.rect(hud, FOCUSED_ROW, x + 4 * s, yy, w - 8 * s, row_h - 1 * s)
            UI.rect(hud, UI.col.accent, x + 4 * s, yy, 3 * s, row_h - 1 * s)
        elseif i % 2 == 0 then
            UI.rect(hud, UI.col.row, x + 4 * s, yy, w - 8 * s, row_h - 1 * s)
        end
        if row then
            local icon_sz = 28 * s
            UI.picker_pal_icon(hud, row.casing or row.id,
                x + pad + 4 * s, yy + (row_h - icon_sz) / 2, icon_sz, frame)
            local checked = working_has(row.id)
            -- Accent tick instead of ASCII brackets.
            if checked then
                UI.rect(hud, UI.col.accent,
                    x + w - pad - 18 * s, yy + row_h / 2 - 5 * s, 10 * s, 10 * s)
            else
                UI.rect(hud, UI.col.hairfaint,
                    x + w - pad - 18 * s, yy + row_h / 2 - 5 * s, 10 * s, 10 * s)
            end
            UI.text(hud, row.name, focused and UI.col.white or UI.col.text,
                x + pad + icon_sz + 12 * s, UI.vtext_y(yy, row_h, 0.64, s), 0.64 * s)
        end
    end

    -- Scroll cue
    if #filtered > VISIBLE_ROWS then
        local page = string.format("%d-%d / %d",
            scroll + 1, math.min(scroll + VISIBLE_ROWS, #filtered), #filtered)
        UI.text(hud, page, UI.col.faint, x + w - pad - #page * 6 * s,
            list_top + list_h + 2 * s, 0.40 * s)
    end

    local btn_y = y + h - footer_h + 10 * s
    local btn_h = 28 * s
    local btn_w = 110 * s
    draw_btn(hud, L.t("btn_clear", lang), x + pad, btn_y, btn_w, btn_h, s, Picker.footer_focus == 1)
    draw_btn(hud, L.t("btn_done", lang), x + w - pad - btn_w, btn_y, btn_w, btn_h, s, Picker.footer_focus == 2)
    local help_text = L.t("help_picker", lang)
    UI.text(hud, help_text, UI.col.faint, x + pad, btn_y + btn_h + 6 * s, 0.40 * s)
end

return Picker
