-- PalScouter ui.lua — design tokens + Canvas draw primitives.
-- Visual language matches Palworld 1.0's own menus: near-black translucent
-- panels, stepped section bands, boxed rows, compact chips,
-- thin-outlined rows with a white left bar, right-aligned values, quality-colored numbers.
local Util = require("util")
local G = require("gamedata")
local Score = require("score")
local Profile = require("profile")

local UI = {
    vector_only = true,       -- avoid streamed texture/material render-thread crashes
    font = nil,
    color_cache = {},        -- "r,g,b,a" string -> FLinearColor (bounded; never key by ephemeral tables)
    texture_cache = {},
    texture_missing = {},    -- path -> os.clock() of last failed probe (retried; assets stream in over time)
    texture_wanted = {},     -- FIFO of missing paths for main.lua's prefetch loop
    texture_wanted_set = {},
    texture_load_attempts = {},
    texture_load_failed = {},
    texture_force_reload = {}, -- path -> true: LoadAsset even if Find already hits
    -- Non-blocking portrait streaming via native PalScouterNativeRequestAsync.
    -- KILL SWITCH: set async_prefetch=false + redeploy Scripts (no DLL rebuild)
    -- to fall back to the proven synchronous LoadAsset path immediately.
    async_prefetch = false,
    texture_async_wait = {}, -- path -> recheck count while an async load is in flight
    picker_texture_allowed = {}, -- explicit Pal portraits requested by visible picker rows
    picker_texture_ready_frame = {}, -- delay newly streamed portraits before first draw
    picker_texture_last_use = {}, -- path -> monotonic use serial for closed-picker LRU trimming
    picker_texture_use_serial = 0,
    material_cache = {},
    material_draw_ok = false,  -- vector-only build never submits streamed materials
    draw_rect_ok = nil,
    draw_text_ok = nil,
    texture_mode = nil,      -- probe DrawTexture only for the small safe-icon allowlist
    texture_rect_ok = nil,
    prefetch_wake = nil,
    hband_cache = {},
    chip_metrics_cache = {},
    chip_rect_cache = {},
    color_spec_key_cache = setmetatable({}, { __mode = "k" }),
}

function UI.set_prefetch_wake(fn)
    UI.prefetch_wake = fn
end

-- ------------------------------------------------------------ tokens

UI.col = {
    bg        = { 0.04, 0.08, 0.10, 1.0 },   -- teal-black panel
    bg_deep   = { 0.02, 0.05, 0.07, 1.0 },
    shadow    = { 0.0, 0.0, 0.0, 0.55 },
    hairline  = { 0.72, 0.76, 0.82, 0.38 },    -- thin light rules, native menu style
    hairfaint = { 0.72, 0.76, 0.82, 0.16 },    -- row outlines
    row       = { 1.0, 1.0, 1.0, 0.04 },       -- zebra row tint
    row_bar   = { 1.0, 1.0, 1.0, 0.055 },      -- passive/skill row background
    accent    = { 0.35, 0.82, 0.92, 1.0 },
    chip      = { 0.72, 0.58, 0.44, 1.0 },
    text      = { 0.93, 0.95, 0.97, 1.0 },
    white     = { 1.0, 1.0, 1.0, 1.0 },
    dim       = { 0.62, 0.66, 0.72, 1.0 },
    faint     = { 0.42, 0.46, 0.52, 1.0 },
    black     = { 0.0, 0.0, 0.0, 1.0 },
    track     = { 0.0, 0.0, 0.0, 0.45 },       -- HP bar track
    hp        = { 0.35, 0.78, 0.42, 1.0 },
    gold      = { 1.00, 0.80, 0.28, 1.0 },     -- S grade / alpha marker / IV 90+
    green     = { 0.35, 0.84, 0.55, 1.0 },     -- A grade / R1–R2 passive / IV 70+
    cyan      = { 0.45, 0.82, 0.95, 1.0 },     -- B grade
    -- Creative Menu / PalBox passive tiers (left bar + chevrons).
    passive_gold = { 0.98, 0.86, 0.35, 1.0 }, -- R3
    passive_cyan = { 0.15, 0.88, 0.92, 1.0 }, -- R4 rainbow (+ under chevrons)
    red       = { 0.90, 0.38, 0.34, 1.0 },     -- negative passive
    band      = { 0.08, 0.14, 0.16, 0.92 },
    icon_sq   = { 1.0, 1.0, 1.0, 0.06 },       -- darker square behind stat icons
    divider   = { 0.72, 0.76, 0.82, 0.30 },    -- thin rule under section headers
}

UI.GRADE_COLORS = {
    S = UI.col.gold, A = UI.col.green, B = UI.col.cyan,
    C = UI.col.text, D = UI.col.faint, ["?"] = UI.col.faint,
}

UI.ELEMENT_COLORS = {
    [1] = UI.col.chip,
    [2] = { 0.65, 0.12, 0.04, 1.0 },
    [3] = { 0.04, 0.28, 0.65, 1.0 },
    [4] = { 0.08, 0.48, 0.10, 1.0 },
    [5] = { 0.85, 0.55, 0.02, 1.0 },
    [6] = { 0.04, 0.50, 0.65, 1.0 },
    [7] = { 0.55, 0.25, 0.07, 1.0 },
    [8] = { 0.28, 0.08, 0.45, 1.0 },
    [9] = { 0.22, 0.12, 0.45, 1.0 },
}

local ELEMENT_ICON_INDEX = {
    [1] = 0, [2] = 1, [3] = 2, [4] = 4, [5] = 3,
    [6] = 8, [7] = 7, [8] = 5, [9] = 6,
}

function UI.element_icon_index(element)
    return ELEMENT_ICON_INDEX[math.floor(tonumber(element) or 0)]
end

function UI.iv_color(v)
    if v == nil then return UI.col.faint end
    if v >= 90 then return UI.col.gold end
    if v >= 70 then return UI.col.green end
    if v >= 45 then return UI.col.text end
    return UI.col.dim
end

-- Rank-tier colors matching Creative Menu / native PalBox passives:
-- R1–R2 green, R3 gold, R4 cyan (rainbow), negatives red.
function UI.passive_color(rank)
    if rank == nil then return UI.col.dim end
    if rank < 0 then return UI.col.red end
    if rank == 0 then return UI.col.dim end
    local abs_rank = math.abs(rank)
    if abs_rank >= 4 then return UI.col.passive_cyan end
    if abs_rank == 3 then return UI.col.passive_gold end
    return UI.col.green
end

-- Best→worst by rank; nil ranks sort last. Returns a new array.
function UI.sort_passives(passives)
    local out = {}
    for i = 1, #(passives or {}) do out[i] = passives[i] end
    return Score.sort_passives(out)
end

-- ------------------------------------------------------------ pure geometry

-- Horizontal fade-out band as N adjacent segments (native section-header look).
-- Returns { {dx, w, af}, ... }; af = alpha factor fading 1.0 -> 1/steps.
function UI.hband_steps(w, steps)
    steps = steps or 6
    local key = tostring(steps) .. ":" .. tostring(math.floor((w or 0) * 10 + 0.5))
    local cached = UI.hband_cache[key]
    if cached ~= nil then return cached end
    local out = {}
    local seg = w / steps
    for i = 1, steps do
        out[i] = { dx = (i - 1) * seg, w = seg + 0.5, af = (steps - i + 1) / steps }
    end
    UI.hband_cache[key] = out
    return out
end

-- Chip size from content so values never clip. opts = { icon = bool, s = scale }.
function UI.chip_metrics(label, opts, direct_scale)
    local icon, s
    if type(opts) == "boolean" then
        -- direct_scale form is used by the hot draw path to avoid an options table.
        icon, s = opts, direct_scale or 1
    else
        opts = opts or {}
        icon, s = opts.icon == true, opts.s or 1
    end
    local text = tostring(label or "")
    local key = text .. ":" .. (icon and "1:" or "0:")
        .. tostring(math.floor(s * 1000 + 0.5))
    local cached = UI.chip_metrics_cache[key]
    if cached ~= nil then return cached end
    local chars = (utf8 and utf8.len(text)) or #text
    local result = {
        w = (14 + chars * 9 + (icon and 20 or 0)) * s,
        h = 18 * s,
        text_dx = (icon and 24 or 7) * s,
    }
    UI.chip_metrics_cache[key] = result
    return result
end

-- Numeric columns use tabular-looking right edges without an engine text-size call.
function UI.right_text_x(value, right_x, s)
    return right_x - #tostring(value or "") * 9 * (s or 1)
end

-- Vertically center a text run inside a box of height h (in screen px).
-- 24 ≈ Pal font line height at DrawText scale 1.0; -3*s is an optical
-- nudge (DrawText sits low in these row boxes without it).
function UI.vtext_y(y, h, scale, s)
    s = s or 1
    return y + (h - 24 * scale * s) / 2 - 3 * s
end

-- Angled chip edge as approximately one-pixel horizontal strips. Four coarse
-- strips were cheaper, but made skill-power and grade edges visibly stair-step.
-- Geometry remains cached, so only the DrawRect submissions repeat per frame.
-- slant = horizontal run of the diagonal (defaults to the small-chip chamfer).
function UI.chip_rects(w, h, s, wedge_left, slant)
    s = s or 1
    slant = slant or 6 * (s or 1)
    -- Pack the quantized HUD-pixel dimensions instead of allocating a temporary
    -- table and string for every grade chip on every frame.
    local key_base = 65536
    local key = (((math.floor((w or 0) * 10 + 0.5) * key_base
        + math.floor((h or 0) * 10 + 0.5)) * key_base
        + math.floor((slant or 0) * 10 + 0.5)) * 2)
        + (wedge_left and 1 or 0)
    local cached = UI.chip_rect_cache[key]
    if cached ~= nil then return cached end
    local rows = math.floor(Util.clamp(h, 4, 32) + 0.5)
    local out = {}
    for i = 0, rows - 1 do
        local dy = i * h / rows
        local rh = h / rows + 0.5
        local inset = slant * (rows - 1 - i) / math.max(rows - 1, 1)
        if wedge_left then
            out[#out + 1] = { dx = inset, dy = dy, w = w - inset, h = rh }
        else
            out[#out + 1] = { dx = 0, dy = dy, w = w - inset, h = rh }
        end
    end
    UI.chip_rect_cache[key] = out
    return out
end

local level_box_metrics_cache = {}

function UI.level_box_metrics(s)
    s = s or 1
    local cached = level_box_metrics_cache[s]
    if cached ~= nil then return cached end
    cached = { w = 72 * s, h = 48 * s }
    level_box_metrics_cache[s] = cached
    return cached
end

-- Inclusive screen-space hit test for modal / button rects.
function UI.point_in_rect(px, py, x, y, w, h)
    if px == nil or py == nil or x == nil or y == nil or w == nil or h == nil then
        return false
    end
    return px >= x and py >= y and px <= x + w and py <= y + h
end

-- LEVEL cell: filled block + left cyan bar (no full outline — full cyan
-- rectangles read as debug selection boxes on the aim overlay).
-- Number is oversized to match the PalBox header weight and centered
-- horizontally (16 ≈ digit advance at scale 1.35).
function UI.level_box(hud, level, x, y, s)
    local m = UI.level_box_metrics(s)
    UI.rect(hud, UI.col.row, x, y, m.w, m.h)
    UI.rect(hud, UI.col.accent, x, y, 3 * s, m.h)
    UI.text(hud, "LEVEL", UI.col.dim, x + 10 * s, y + 5 * s, 0.44 * s)
    local num = tostring(level or "?")
    -- Large digit: optical nudge up/left (DrawText origin sits low/right at 1.35).
    UI.text(hud, num, UI.col.white,
        x + (m.w - #num * 16 * s) / 2 - 5 * s, y + 10 * s, 1.35 * s)
    return m.w, m.h
end

-- Portrait: draw the icon only. Never paint an empty frame — a failed
-- StaticFindObject left a cyan box overlapping the name.
function UI.portrait(hud, character_id, x, y, size, frame)
    return UI.pal_icon(hud, character_id, x, y, size, frame)
end

-- ------------------------------------------------------------ primitives

local function call_draw_rect(hud, color, x, y, w, h)
    return hud:DrawRect(color, x, y, w, h)
end

local function call_draw_text(hud, str, color, x, y, font, scale)
    return hud:DrawText(str, color, x, y, font, scale, false)
end

local function call_make_color(math_lib, r, g, b, a)
    return math_lib:MakeColor(r, g, b, a)
end

function UI.get_font()
    -- Font assets are process-lifetime objects once loaded; avoid IsValid for every
    -- text primitive on every frame.
    if UI.font ~= nil then return UI.font end
    for _, path in ipairs({
        "/Game/Pal/Font/Ft_PalDefaultFont.Ft_PalDefaultFont",
        "/Engine/EngineFonts/Roboto.Roboto",
        "/Engine/EngineFonts/RobotoDistanceField.RobotoDistanceField",
    }) do
        local ok, font = pcall(StaticFindObject, path)
        if ok and font ~= nil and Util.valid(font) then
            UI.font = font
            return font
        end
    end
    return nil
end

-- Stable cache key so ephemeral {r,g,b,a} tables cannot unbounded-grow the cache.
function UI.color_cache_key(spec, alpha_override)
    if type(spec) ~= "table" then return nil end
    local a = alpha_override
    if a == nil then a = spec[4] or 1.0 end
    local aq = math.floor(Util.clamp(tonumber(a) or 1, 0, 1) * 255 + 0.5)
    local per_spec = UI.color_spec_key_cache[spec]
    if per_spec ~= nil and per_spec[aq] ~= nil then return per_spec[aq] end
    local rq = math.floor(Util.clamp(tonumber(spec[1]) or 0, 0, 1) * 255 + 0.5)
    local gq = math.floor(Util.clamp(tonumber(spec[2]) or 0, 0, 1) * 255 + 0.5)
    local bq = math.floor(Util.clamp(tonumber(spec[3]) or 0, 0, 1) * 255 + 0.5)
    local key = (((rq * 256) + gq) * 256 + bq) * 256 + aq
    if per_spec == nil then
        per_spec = {}
        UI.color_spec_key_cache[spec] = per_spec
    end
    per_spec[aq] = key
    return key
end

-- spec = {r,g,b,a}; optional alpha_override replaces the spec alpha (also cached).
function UI.color(spec, alpha_override)
    local math_lib = G.kismet_math()
    if not math_lib then return nil end
    local key = UI.color_cache_key(spec, alpha_override)
    if key ~= nil then
        local cached = UI.color_cache[key]
        if cached ~= nil then return cached end
    end
    local a = alpha_override
    if a == nil then a = (spec and spec[4]) or 1.0 end
    local ok, c = pcall(call_make_color, math_lib, spec[1], spec[2], spec[3], a)
    if ok and c ~= nil then
        if key ~= nil then UI.color_cache[key] = c end
        return c
    end
    return nil
end

function UI.rect(hud, spec, x, y, w, h, alpha_override)
    if UI.draw_rect_ok == false or w <= 0 or h <= 0 then return end
    local color = UI.color(spec, alpha_override)
    if not color then return end
    local ok = pcall(call_draw_rect, hud, color, x, y, w, h)
    if ok then
        UI.draw_rect_ok = true
    elseif UI.draw_rect_ok == nil then
        UI.draw_rect_ok = false
        Util.log("WARNING: DrawRect unavailable; panels disabled")
    end
end

function UI.text(hud, str, spec, x, y, scale)
    if UI.draw_text_ok == false or str == nil or str == "" then return end
    local color = UI.color(spec)
    local font = UI.get_font()
    if not color or not font then return end
    local ok = pcall(call_draw_text, hud, str, color, x, y, font, scale or 1.0)
    if ok then
        UI.draw_text_ok = true
    elseif UI.draw_text_ok == nil then
        UI.draw_text_ok = false
        Util.log("WARNING: DrawText unavailable; overlay disabled")
    end
end

-- Outlined text for content drawn over variable backgrounds (HP bar numbers).
function UI.text_outlined(hud, str, spec, x, y, scale)
    local o = math.max(1, math.floor((scale or 1) + 0.5))
    UI.text(hud, str, UI.col.black, x - o, y, scale)
    UI.text(hud, str, UI.col.black, x + o, y, scale)
    UI.text(hud, str, UI.col.black, x, y - o, scale)
    UI.text(hud, str, UI.col.black, x, y + o, scale)
    UI.text(hud, str, spec, x, y, scale)
end

-- Resolve an already-resident UTexture2D. Never call LoadAsset here: forced
-- package loads during ReceiveDrawHUD have AV'd on Palworld 1.0 when probing
-- unknown PalBox parts (e.g. T_prt_status_arrow) that are not streamed in yet.
-- Missing paths are queued for main.lua's prefetch loop, which LoadAssets them
-- on the game thread outside the draw hook (that path is safe); until then the
-- callers draw their rect fallbacks.
local PREFETCH_PREFIX = "/Game/Pal/Texture/"
-- Skill-plate parts used by WBP_MainMenu_Pal_Skill_Passive / Creative Menu.
-- Whitelisted for outside-draw LoadAsset; other T_prt_* stay blocked.
local PREFETCH_OK_PRT = {
    ["T_prt_menu_pal_base_tri"] = true,
    ["T_prt_pal_skill_base_00"] = true,
    ["T_prt_pal_skill_base_01"] = true,
    ["T_prt_pal_skill_base_02"] = true,
}

-- Small fixed UI icons are safe to load on the game thread outside ReceiveDrawHUD.
-- Large Pal portraits, passive plate materials and streamed decorative textures stay
-- vector-only because those were involved in the earlier render-thread crashes.
local function is_safe_hud_texture(path)
    if type(path) ~= "string" then return false end
    return path:find("/T_icon_palwork_", 1, true) ~= nil
        or path:find("/T_Icon_element_s_", 1, true) ~= nil
        or path:find("/T_icon_status_", 1, true) ~= nil
        or path:find("/T_Icon_PanGender_", 1, true) ~= nil
        or path:find("/T_icon_skillstatus_rank_arrow_", 1, true) ~= nil
        or path:find("/T_icon_plus", 1, true) ~= nil
end

local function is_pal_portrait_path(path)
    return type(path) == "string"
        and path:find("/Game/Pal/Texture/PalIcon/Normal/", 1, true) ~= nil
end

local function is_picker_pal_texture(path)
    return UI.picker_texture_allowed[path] == true and is_pal_portrait_path(path)
end

-- The two crystalline plate decorations (WBP_MainMenu_Pal_Skill_Passive base +
-- facet). Unlike the small safe-hud icons these stream in larger and, resolved
-- via StaticFindObject, are unrooted — so they share the portrait RootSet-pin
-- pipeline: resolved + pinned off the draw path, cache-only blit on the HUD.
local function is_pinned_plate_texture(path)
    if type(path) ~= "string" then return false end
    return path:find("/T_prt_pal_skill_base_02.", 1, true) ~= nil
        or path:find("/T_prt_menu_pal_base_tri.", 1, true) ~= nil
end

-- Keep every portrait alive across the RenderThread command that consumes it.
-- This is shared by cold LoadAsset completion and the resident fast path, so
-- no picker texture becomes drawable before native lifetime protection.
local function pin_picker_texture(path, texture)
    if not is_picker_pal_texture(path) then return true end
    if texture == nil or not Util.valid(texture) then return false end
    if type(PalScouterNativePinTexture) ~= "function" then return true end
    local ok, pinned = pcall(PalScouterNativePinTexture, texture)
    if ok and pinned == true then return true end
    UI.texture_cache[path] = nil
    UI.texture_load_failed[path] = true
    Util.log("WARNING: picker texture could not be pinned: " .. path)
    return false
end

-- RootSet-pin a resolved plate decoration so a RenderThread DrawTexture can never
-- reference a GC'd texture. Conservative: without the native pinner (non-native
-- host) the plate stays unresolved and the flat underlay shows instead.
local function pin_plate_texture(texture)
    if texture == nil or not Util.valid(texture) then return false end
    if type(PalScouterNativePinTexture) ~= "function" then return false end
    local ok, pinned = pcall(PalScouterNativePinTexture, texture)
    return ok and pinned == true
end

local function vector_texture_allowed(path)
    return is_safe_hud_texture(path)
        or is_picker_pal_texture(path)
        or is_pinned_plate_texture(path)
end

-- Pure visibility hook used by the smoke test and by the guarded cache path.
function UI.vector_texture_allowed(path)
    return vector_texture_allowed(path)
end

function UI.prefetch_can_run(settings_open)
    if #UI.texture_wanted == 0 then return false end
    if settings_open then return true end
    for _, path in ipairs(UI.texture_wanted) do
        if is_safe_hud_texture(path) or is_picker_pal_texture(path)
            or is_pinned_plate_texture(path) then return true end
    end
    return false
end

local function texture_prefetch_allowed(path)
    if path:find("/Game/Pal/Material/UI/Texture/T_prt_pal_skill_base_", 1, true) then
        return true
    end
    if path:sub(1, #PREFETCH_PREFIX) ~= PREFETCH_PREFIX then return false end
    local prt = path:match("/(T_prt_[^./]+)")
    if prt then return PREFETCH_OK_PRT[prt] == true end
    return true
end

-- Creative Menu SoftObjectPaths omit the `.AssetName` suffix
-- (`/Game/.../T_prt_pal_skill_base_02`). That bare path often resolves to a
-- UPackage; the Texture2D itself is at `.../Name.Name`. LoadAsset may need
-- either form; Find must require a real Texture2D.
local function texture_path_variants(path)
    local bare = path:match("^(.+)%.[^./]+$")
    if bare then
        return { bare, path }
    end
    local leaf = path:match("([^/]+)$")
    if leaf then
        return { path, path .. "." .. leaf }
    end
    return { path }
end

local function texture_object_path(path)
    if path:match("%.[^./]+$") then return path end
    local leaf = path:match("([^/]+)$")
    if leaf then return path .. "." .. leaf end
    return path
end

local function texture_short_name(path)
    local leaf = path:match("([^/]+)$") or path
    return leaf:match("^(.+)%.") or leaf
end

local function is_texture2d(obj)
    if obj == nil or not Util.valid(obj) then return false end
    local full = Util.safe_call("", function() return obj:GetFullName() end)
    return type(full) == "string" and full:find("Texture2D ", 1, true) ~= nil
end

local function describe_object(obj)
    if obj == nil then return "nil" end
    if not Util.valid(obj) then return "invalid" end
    local full = Util.safe_call("?", function() return obj:GetFullName() end)
    if is_texture2d(obj) then
        local sx = tonumber(Util.safe_call(-1, function() return obj:GetSizeX() end)) or -1
        local sy = tonumber(Util.safe_call(-1, function() return obj:GetSizeY() end)) or -1
        return string.format("Texture2D %dx%d %s", sx, sy, tostring(full))
    end
    return tostring(full)
end

local function describe_texture(obj)
    return describe_object(obj)
end

local function describe_material(obj)
    if obj == nil then return "nil" end
    if not Util.valid(obj) then return "invalid" end
    return tostring(Util.safe_call("?", function() return obj:GetFullName() end))
end

-- One-shot draw diagnostics for passive plates / ranks (HUD is every frame).
local passive_draw_logged = {}

local function log_passive_draw_once(key, msg)
    if passive_draw_logged[key] then return end
    passive_draw_logged[key] = true
    Util.dbg(msg)
end

local function find_texture_object(path)
    -- Prefer the object path (.../Name.Name). Bare SoftObject paths can return
    -- a valid UPackage, which we previously cached and then failed to draw.
    local named = texture_object_path(path)
    local texture = Util.safe_call(nil, function() return StaticFindObject(named) end)
    if is_texture2d(texture) then return texture end
    if named ~= path then
        texture = Util.safe_call(nil, function() return StaticFindObject(path) end)
        if is_texture2d(texture) then return texture end
    end
    return nil
end

-- Probe every SoftObject/object-path variant and log what Find returns
-- (packages vs Texture2D stubs). Used once during ensure / force-reload.
local function probe_texture_paths(path, tag)
    local seen = {}
    for _, candidate in ipairs(texture_path_variants(path)) do
        if not seen[candidate] then
            seen[candidate] = true
            local obj = Util.safe_call(nil, function() return StaticFindObject(candidate) end)
            Util.dbg(string.format("%s Find %s -> %s",
                tag or "probe", candidate, describe_object(obj)))
        end
    end
    local named = texture_object_path(path)
    if not seen[named] then
        local obj = Util.safe_call(nil, function() return StaticFindObject(named) end)
        Util.dbg(string.format("%s Find %s -> %s",
            tag or "probe", named, describe_object(obj)))
    end
end

local function queue_texture(path, front, force)
    if UI.vector_only and not vector_texture_allowed(path) then return false end
    if UI.texture_wanted_set[path] then return false end
    if UI.texture_load_failed[path] and not force then return false end
    if not force and is_texture2d(UI.texture_cache[path]) then return false end
    if force then
        UI.texture_load_failed[path] = nil
        UI.texture_force_reload[path] = true
    end
    UI.texture_wanted_set[path] = true
    if front then
        table.insert(UI.texture_wanted, 1, path)
    else
        UI.texture_wanted[#UI.texture_wanted + 1] = path
    end
    if UI.prefetch_wake ~= nil then pcall(UI.prefetch_wake) end
    return true
end

function UI.get_texture(path)
    if UI.vector_only and not vector_texture_allowed(path) then return nil end
    local cached = UI.texture_cache[path]
    -- Loaded texture assets remain resident while referenced. Trust the cache instead
    -- of calling IsValid + GetFullName for every visible icon on every HUD frame.
    if cached ~= nil then return cached end
    -- Plate decorations are resolved + RootSet-pinned only by the prefetch worker
    -- (which pins before caching); the draw path never probes/caches them unpinned.
    -- Kick the prefetch on first sight, then stay cache-only until a pinned texture
    -- lands — same discipline warm_pal_icons uses for streamed portraits.
    if is_pinned_plate_texture(path) then
        if UI.texture_missing[path] == nil and not UI.texture_load_failed[path] then
            UI.texture_missing[path] = true
            queue_texture(path, false, false)
        end
        return nil
    end
    -- HUD drawing never retries failed/missing paths. The explicit prefetch worker
    -- owns retries so dozens of paths cannot synchronize a StaticFindObject burst.
    if UI.texture_missing[path] ~= nil or UI.texture_load_failed[path] then return nil end
    local texture = find_texture_object(path)
    if texture then
        UI.texture_missing[path] = nil
        UI.texture_cache[path] = texture
        return texture
    end
    UI.texture_missing[path] = true
    if texture_prefetch_allowed(path) then
        queue_texture(path, false)
    end
    return nil
end

-- Native skill-passive widget SoftObject path. Loading it pulls the same
-- SoftObject texture deps Creative Menu gets via UMG (not a Texture2D itself).
local PASSIVE_SKILL_WIDGET =
    "/Game/Pal/Blueprint/UI/UserInterface/MainMenu/Pal/WBP_MainMenu_Pal_Skill_Passive"

local function is_passive_widget_path(path)
    return path == PASSIVE_SKILL_WIDGET
        or path:find("WBP_MainMenu_Pal_Skill_Passive", 1, true) ~= nil
end

-- Native gradient materials used by UMG Image brushes on passive plates.
local function is_material_path(path)
    return type(path) == "string" and path:find("MI_UI_BaseGrd", 1, true) ~= nil
end

-- Plate/widget/rank assets from the PalBox restyle (vs pal-icon prefetch).
local function is_passive_prefetch_path(path)
    if type(path) ~= "string" then return false end
    if is_passive_widget_path(path) or is_material_path(path) then return true end
    local short = texture_short_name(path)
    if PREFETCH_OK_PRT[short] then return true end
    if short == "T_icon_plus" then return true end
    if short:find("^T_icon_skillstatus_rank_arrow_") then return true end
    if path:find("T_prt_pal_skill_base_", 1, true) then return true end
    return false
end

-- How many prefetch steps to wait for an in-flight async portrait to become
-- Async residency polling. StaticFindObject is an O(N) linear scan over every
-- UObject when it MISSES (texture not yet resident), so we must not scan on every
-- prefetch tick while a load is in flight. Instead: wait ASYNC_SETTLE ticks for
-- the stream to land, then scan only every ASYNC_CHECK_EVERY ticks, giving up to a
-- synchronous load after ASYNC_MAX ticks. Ticks are ~150 ms apart while pending.
local ASYNC_SETTLE = 2
local ASYNC_CHECK_EVERY = 2
local ASYNC_MAX = 20

-- True while any portrait is mid async-stream, so the prefetch scheduler can
-- recheck residency quickly instead of on the slow steady-state cadence.
function UI.has_pending_async()
    return next(UI.texture_async_wait) ~= nil
end

-- Pop the next queued path and resolve it. MUST be called from the game
-- thread outside ReceiveDrawHUD (LoadAsset inside the draw hook AV'd on 1.0).
-- Prefer StaticFindObject when the asset is already resident; otherwise
-- LoadAsset once per step. Paths that fail twice are dropped for the session.
-- Plate textures set texture_force_reload so we still LoadAsset when Find hits
-- a stub Texture2D (queued 0 / blank backgrounds in the HUD).
function UI.prefetch_step()
    local path
    repeat
        path = table.remove(UI.texture_wanted, 1)
        if path == nil then return false end
        UI.texture_wanted_set[path] = nil
        local force = UI.texture_force_reload[path]
        if force then break end
    until not is_texture2d(UI.texture_cache[path]) and not UI.texture_load_failed[path]

    -- Async settle gate: while a portrait's native load is in flight, skip the
    -- expensive residency scan on most ticks (see ASYNC_* above). Advance the try
    -- counter here; only fall through to resolve() on a scan tick or at timeout.
    do
        local tries = UI.texture_async_wait[path]
        if type(tries) == "number" and not UI.texture_force_reload[path] then
            tries = tries + 1
            UI.texture_async_wait[path] = tries
            if tries >= ASYNC_MAX then
                UI.texture_async_wait[path] = false -- timed out; resolve() will sync-load
            elseif tries < ASYNC_SETTLE
                or (tries - ASYNC_SETTLE) % ASYNC_CHECK_EVERY ~= 0 then
                queue_texture(path, false, false)
                return true -- cheap requeue, no O(N) residency scan this tick
            end
        end
    end

    local function resolve()
        -- Widget bootstrap: LoadAsset the UMG asset so soft refs stream in.
        if is_passive_widget_path(path) then
            UI.texture_force_reload[path] = nil
            Util.dbg("passive widget LoadAsset begin: " .. path)
            probe_texture_paths(path, "passive widget pre")
            local loaded_ok, last_err = false, nil
            for _, candidate in ipairs(texture_path_variants(path)) do
                local ok, result = pcall(function() return LoadAsset(candidate) end)
                if ok then
                    loaded_ok = true
                    Util.dbg("passive widget LoadAsset ok via " .. candidate
                        .. " -> " .. describe_object(result))
                    return true
                end
                last_err = tostring(result)
                Util.dbg("passive widget LoadAsset fail via " .. candidate .. ": " .. last_err)
            end
            Util.dbg("passive widget unavailable"
                .. (last_err and (": " .. last_err) or (loaded_ok and "" or " (LoadAsset failed)")))
            return true
        end

        -- Material instances for AHUD DrawMaterial (UMG plate look).
        if is_material_path(path) then
            UI.texture_force_reload[path] = nil
            Util.dbg("passive material LoadAsset begin: " .. path)
            local loaded_ok, last_err = false, nil
            for _, candidate in ipairs(texture_path_variants(path)) do
                local ok, result = pcall(function() return LoadAsset(candidate) end)
                if ok then
                    loaded_ok = true
                    local mat = result
                    if not (mat and Util.valid(mat)) then
                        mat = Util.safe_call(nil, function()
                            return StaticFindObject(texture_object_path(path))
                        end)
                    end
                    if mat and Util.valid(mat) then
                        UI.material_cache[path] = mat
                        Util.dbg("passive material loaded via " .. candidate
                            .. " -> " .. describe_material(mat))
                        return true
                    end
                    Util.dbg("passive material LoadAsset ok but Find missed via " .. candidate
                        .. " -> " .. describe_object(result))
                else
                    last_err = tostring(result)
                    Util.dbg("passive material LoadAsset fail via " .. candidate .. ": " .. last_err)
                end
            end
            Util.dbg("passive material unavailable: " .. path
                .. (last_err and (": " .. last_err) or ""))
            return true
        end

        local force = UI.texture_force_reload[path]
        local short = texture_short_name(path)
        local texture = find_texture_object(path)
        if texture and not force then
            UI.texture_cache[path] = texture
            UI.texture_missing[path] = nil
            UI.texture_async_wait[path] = nil
            Util.dbg("texture ready (resident): " .. short
                .. " [" .. describe_texture(texture) .. "]")
            return true
        end
        if force then
            Util.dbg("texture force-reload begin: " .. short
                .. (texture and (" was [" .. describe_texture(texture) .. "]") or " (Find miss)"))
            probe_texture_paths(path, "force-reload")
        end

        -- Non-blocking portrait streaming: kick a native async LoadAsset and let a
        -- later prefetch step pick the texture up resident (the branch above),
        -- instead of blocking this frame on synchronous LoadAsset. Portraits only
        -- (force reloads and plate/widget/material paths stay synchronous).
        -- Fail-closed: after ASYNC_MAX_RECHECK misses, or if the native request is
        -- unavailable, fall through to the sync path so a portrait is never stuck blank.
        if UI.async_prefetch and not force and not is_passive_prefetch_path(path)
            and type(PalScouterNativeRequestAsync) == "function" then
            local w = UI.texture_async_wait[path]
            if w == nil then
                -- First encounter: kick only the object-path form (.../Name.Name);
                -- the bare package form never resolves to a Texture2D and just
                -- doubles the cost. Measured separately as prefetch.async. The
                -- settle gate above then paces residency rechecks (counter at 0).
                local ok, res = pcall(Profile.span, "prefetch.async",
                    PalScouterNativeRequestAsync, texture_object_path(path))
                if ok and res then
                    UI.texture_async_wait[path] = 0
                    queue_texture(path, false, false)
                    Util.dbg("async portrait requested: " .. short)
                    return true
                end
                -- Native request failed this call: fall through to sync load.
            elseif w ~= false then
                -- In flight and this scan tick still missed: requeue and keep
                -- waiting (the settle gate advances/limits the counter).
                queue_texture(path, false, false)
                return true
            else
                -- Timed out (w == false): clear and fall through to sync load.
                UI.texture_async_wait[path] = nil
                Util.dbg("async portrait timed out, sync fallback: " .. short)
            end
        end

        -- LoadAsset: bare SoftObject path first (Creative Menu), then `.Name`.
        -- Accept LoadAsset's return value only when it is actually a Texture2D.
        local loaded_ok = false
        local last_err = nil
        for _, candidate in ipairs(texture_path_variants(path)) do
            local ok, result = pcall(function() return LoadAsset(candidate) end)
            if ok then
                loaded_ok = true
                if is_texture2d(result) then
                    UI.texture_cache[path] = result
                    UI.texture_missing[path] = nil
                    UI.texture_force_reload[path] = nil
                    Util.dbg("texture loaded: " .. short .. " via LoadAsset return " .. candidate
                        .. " [" .. describe_texture(result) .. "]")
                    return true
                end
                Util.dbg("texture LoadAsset returned non-Texture2D via " .. candidate
                    .. " -> " .. describe_object(result))
            else
                last_err = tostring(result)
                Util.dbg("texture LoadAsset error via " .. candidate .. ": " .. last_err)
            end
            texture = find_texture_object(path)
            if texture then
                UI.texture_cache[path] = texture
                UI.texture_missing[path] = nil
                UI.texture_force_reload[path] = nil
                Util.dbg("texture loaded: " .. short .. " via Find after " .. candidate
                    .. " [" .. describe_texture(texture) .. "]")
                return true
            end
        end

        local max_attempts = PREFETCH_OK_PRT[texture_short_name(path)] and 4 or 2
        local attempts = (UI.texture_load_attempts[path] or 0) + 1
        UI.texture_load_attempts[path] = attempts
        if attempts >= max_attempts then
            UI.texture_load_failed[path] = true
            UI.texture_force_reload[path] = nil
            Util.dbg("texture unavailable: " .. path
                .. (loaded_ok and " (LoadAsset returned but Texture2D Find missed)"
                    or (" (LoadAsset failed" .. (last_err and (": " .. last_err) or "") .. ")")))
        else
            queue_texture(path, false, force)
            Util.dbg("texture retry " .. attempts .. "/" .. max_attempts .. ": " .. path)
        end
        return true
    end

    local resolved
    if is_passive_prefetch_path(path) then
        resolved = Profile.span("prefetch.plate", resolve)
    else
        resolved = resolve()
    end
    if resolved and is_picker_pal_texture(path) then
        pin_picker_texture(path, UI.texture_cache[path])
    elseif resolved and is_pinned_plate_texture(path) then
        -- Pin before the next HUD frame can cache-read it; drop on failure so the
        -- draw path never blits an unrooted plate.
        local tex = UI.texture_cache[path]
        if tex ~= nil and not pin_plate_texture(tex) then
            UI.texture_cache[path] = nil
            UI.texture_load_failed[path] = true
            Util.log("WARNING: plate texture could not be pinned: " .. path)
        end
    end
    return resolved
end

-- Draws a texture at exactly size x size on screen.
-- Preferred path: AHUD:DrawTexture with explicit screen W/H and full-texture
-- UVs — immune to GetSizeX/GetSizeY lying while a texture is mip-streaming
-- (the bug that rendered pal portraits several times too large).
-- AHUD EBlendMode: Opaque=0, Masked=1, Translucent=2, Additive=3, Modulate=4.
-- Additive washed plates solid white; Masked clips soft alpha; prefer Translucent
-- for soft masks, Opaque when RGB carries the pattern with alpha=0.
local BLEND_OPAQUE = 0
local BLEND_TRANSLUCENT = 2
local BLEND_MODULATE = 4
local ZERO_PIVOT = { X = 0, Y = 0 }

local function call_draw_texture(hud, texture, x, y, w, h, u, v, uw, vh, tint, blend)
    return hud:DrawTexture(texture, x, y, w, h, u, v, uw, vh,
        tint, blend, 1.0, false, 0.0, ZERO_PIVOT)
end

local function call_draw_texture_simple(hud, texture, x, y, scale)
    return hud:DrawTextureSimple(texture, x, y, scale, false)
end

local function call_draw_material(hud, mat, x, y, w, h)
    return hud:DrawMaterial(mat, x, y, w, h, 0, 0, 1, 1)
end

local function draw_texture_full(hud, texture, x, y, size)
    local white = UI.color(UI.col.white)
    if not white then return false end
    return pcall(call_draw_texture, hud, texture, x, y, size, size,
        0, 0, 1, 1, white, BLEND_TRANSLUCENT)
end

local function draw_texture_simple(hud, texture, x, y, size)
    local source_size = math.max(
        tonumber(Util.safe_call(0, function() return texture:GetSizeX() end)) or 0,
        tonumber(Util.safe_call(0, function() return texture:GetSizeY() end)) or 0)
    if source_size <= 0 then return false end
    return pcall(call_draw_texture_simple, hud, texture, x, y, size / source_size)
end

function UI.texture(hud, path, x, y, size)
    if UI.texture_mode == false then return false end
    local texture = UI.get_texture(path)
    if not texture then return false end
    if UI.texture_mode == "full" then return draw_texture_full(hud, texture, x, y, size) end
    if UI.texture_mode == "simple" then return draw_texture_simple(hud, texture, x, y, size) end
    -- First draw decides the supported method for the rest of the session.
    if draw_texture_full(hud, texture, x, y, size) then
        UI.texture_mode = "full"
        return true
    end
    if draw_texture_simple(hud, texture, x, y, size) then
        UI.texture_mode = "simple"
        Util.dbg("DrawTexture unavailable; using DrawTextureSimple (sizes may vary while streaming)")
        return true
    end
    UI.texture_mode = false
    Util.log("WARNING: texture drawing unavailable; native icons disabled")
    return false
end

-- Draw a texture stretched to an explicit rect ("full" DrawTexture only).
-- opts = { flip_v, tint, blend, uv_h } — uv_h < 1 crops the bottom of the atlas
-- (used to hide the baked-in "+" on T_icon_skillstatus_rank_arrow_04).
function UI.texture_rect(hud, path, x, y, w, h, opts)
    if UI.texture_mode == false or UI.texture_mode == "simple"
        or UI.texture_rect_ok == false then return false end
    local texture = UI.get_texture(path)
    if not texture then return false end
    local tint = UI.color((opts and opts.tint) or UI.col.white)
    if not tint then return false end
    local uv_h = (opts and opts.uv_h) or 1
    local v, vh = 0, uv_h
    if opts and opts.flip_v then v, vh = uv_h, -uv_h end
    local blend = (opts and opts.blend) or BLEND_TRANSLUCENT
    local ok = pcall(call_draw_texture, hud, texture, x, y, w, h,
        0, v, 1, vh, tint, blend)
    if ok then
        UI.texture_rect_ok = true
    elseif UI.texture_rect_ok == nil then
        UI.texture_rect_ok = false
        Util.dbg("DrawTexture(rect) unavailable; native UI parts use rect fallbacks")
    end
    return ok
end

function UI.get_material(path)
    if UI.vector_only then return nil end
    local cached = UI.material_cache[path]
    if cached ~= nil then return cached end
    local named = texture_object_path(path)
    local obj = Util.safe_call(nil, function() return StaticFindObject(named) end)
    if obj and Util.valid(obj) then
        local full = Util.safe_call("", function() return obj:GetFullName() end)
        if type(full) == "string" and full:find("Material", 1, true) then
            UI.material_cache[path] = obj
            return obj
        end
    end
    return nil
end

function UI.material_rect(hud, path, x, y, w, h)
    if UI.material_draw_ok == false then return false end
    local mat = UI.get_material(path)
    if not mat then return false end
    -- AHUD::DrawMaterial(Material, ScreenX, ScreenY, ScreenW, ScreenH, MaterialU, MaterialV, MaterialUWidth, MaterialVHeight)
    local ok = pcall(call_draw_material, hud, mat, x, y, w, h)
    if ok then
        UI.material_draw_ok = true
    elseif UI.material_draw_ok == nil then
        UI.material_draw_ok = false
        Util.dbg("DrawMaterial unavailable; falling back to T_prt DrawTexture")
    end
    return ok
end

local ICON_NAME_CASE = require("pal_icon_names")
local pal_icon_paths = {}

local function pal_icon_path(character_id)
    local raw_id = tostring(character_id or "")
    local cached = pal_icon_paths[raw_id]
    if cached ~= nil then return cached end
    local id = raw_id:gsub("^BOSS_", ""):gsub("^GYM_", "")
    id = ICON_NAME_CASE[string.lower(id)] or id
    local asset = "T_" .. id .. "_icon_normal"
    local path = "/Game/Pal/Texture/PalIcon/Normal/" .. asset .. "." .. asset
    pal_icon_paths[raw_id] = path
    return path
end

local function touch_picker_texture(path)
    UI.picker_texture_use_serial = UI.picker_texture_use_serial + 1
    UI.picker_texture_last_use[path] = UI.picker_texture_use_serial
end

-- Warm at most `budget` visible portraits from main.lua's queued game-thread
-- workers. Nothing is searched, queued or scheduled by the HUD draw callback;
-- pal_icon and picker_pal_icon below are cache-only operations.
function UI.warm_pal_icons(rows, budget)
    budget = math.max(1, math.floor(tonumber(budget) or 1))
    local queued = 0
    local pending = false
    for i = 1, #(rows or {}) do
        local row = rows[i]
        local character_id = type(row) == "table"
            and (row.casing or row.character_id or row.id) or row
        local path = pal_icon_path(character_id)
        UI.picker_texture_allowed[path] = true
        local cached = UI.texture_cache[path]
        if cached ~= nil and not Util.valid(cached) then
            UI.texture_cache[path] = nil
            UI.picker_texture_ready_frame[path] = nil
            cached = nil
        end
        -- Match the original mod's perceived speed without UObject work in
        -- DrawHUD: probe visible resident portraits on this queued game-thread
        -- pass, then pin them before the cache-only draw can see them.
        if cached == nil then
            local resident = find_texture_object(path)
            if resident ~= nil then
                UI.texture_cache[path] = resident
                UI.texture_missing[path] = nil
                UI.texture_load_attempts[path] = nil
                if pin_picker_texture(path, resident) then
                    cached = resident
                end
            end
        end
        if cached == nil and not UI.texture_load_failed[path] then
            pending = true
            if not UI.texture_wanted_set[path] and queued < budget then
                -- Prevent get_texture from probing StaticFindObject while the
                -- asset waits for prefetch_step outside ReceiveDrawHUD.
                UI.texture_missing[path] = true
                if queue_texture(path, false) then queued = queued + 1 end
            end
        end
    end
    return pending, queued
end

-- Stop unopened-picker work without disturbing fixed HUD icon prefetches.
function UI.cancel_picker_texture_prefetch()
    local kept = {}
    for i = 1, #UI.texture_wanted do
        local path = UI.texture_wanted[i]
        if is_pal_portrait_path(path) then
            UI.texture_wanted_set[path] = nil
            UI.texture_force_reload[path] = nil
        else
            kept[#kept + 1] = path
        end
    end
    UI.texture_wanted = kept
end

-- Portraits are rooted by the native bridge to protect RenderThread commands.
-- Trim only after main.lua's closed-picker grace period; use hysteresis so a
-- later picker session does not repeatedly evict and reload around the limit.
function UI.trim_picker_texture_cache(high_water, target)
    high_water = math.max(1, math.floor(tonumber(high_water) or 128))
    target = math.max(0, math.min(high_water, math.floor(tonumber(target) or 96)))
    if type(PalScouterNativeUnpinTexture) ~= "function" then return 0 end

    local entries = {}
    for path, texture in pairs(UI.texture_cache) do
        if is_pal_portrait_path(path) then
            entries[#entries + 1] = {
                path = path,
                texture = texture,
                used = tonumber(UI.picker_texture_last_use[path]) or 0,
            }
        end
    end
    if #entries <= high_water then return 0 end
    table.sort(entries, function(a, b)
        if a.used == b.used then return a.path < b.path end
        return a.used < b.used
    end)

    local removed = 0
    local remove_count = #entries - target
    for i = 1, remove_count do
        local entry = entries[i]
        local ok, released = pcall(PalScouterNativeUnpinTexture, entry.texture)
        if ok and released == true then
            local path = entry.path
            UI.texture_cache[path] = nil
            UI.texture_missing[path] = nil
            UI.texture_load_attempts[path] = nil
            UI.texture_load_failed[path] = nil
            UI.texture_force_reload[path] = nil
            UI.texture_wanted_set[path] = nil
            UI.picker_texture_allowed[path] = nil
            UI.picker_texture_ready_frame[path] = nil
            UI.picker_texture_last_use[path] = nil
            removed = removed + 1
        end
    end
    return removed
end

local function call_draw_picker_texture(hud, texture, x, y, size, tint, pivot)
    return hud:DrawTexture(texture, x, y, size, size, 0, 0, 1, 1,
        tint, BLEND_TRANSLUCENT, 1.0, false, 0.0, pivot)
end

function UI.picker_pal_icon(hud, character_id, x, y, size, frame)
    local path = pal_icon_path(character_id)
    local texture = UI.texture_cache[path]
    if UI.picker_texture_allowed[path] ~= true or texture == nil then return false end
    if not Util.valid(texture) then
        UI.texture_cache[path] = nil
        UI.picker_texture_ready_frame[path] = nil
        return false
    end
    frame = tonumber(frame) or 0
    touch_picker_texture(path)
    local ready_frame = UI.picker_texture_ready_frame[path]
    if ready_frame == nil then
        ready_frame = frame + 2
        UI.picker_texture_ready_frame[path] = ready_frame
    end
    if frame < ready_frame then return false end
    local white = UI.color(UI.col.white)
    if not white then return false end
    -- Match the original PalScouter call shape for streamed portraits: validate
    -- immediately before submission and use a fresh pivot value for the remote
    -- AHUD invocation. The native hot-path wrapper remains for fixed HUD icons.
    return pcall(call_draw_picker_texture, hud, texture, x, y, size, white,
        { X = 0, Y = 0 })
end

function UI.pal_icon(hud, character_id, x, y, size, frame)
    return UI.picker_pal_icon(hud, character_id, x, y, size, frame)
end

local element_icon_paths = {}
local status_icon_paths = {}
local gender_icon_paths = {}

function UI.element_icon(hud, element, x, y, size)
    local index = UI.element_icon_index(element)
    if index == nil then return false end
    local path = element_icon_paths[index]
    if path == nil then
        local asset = string.format("T_Icon_element_s_%02d", index)
        path = "/Game/Pal/Texture/UI/InGame/" .. asset .. "." .. asset
        element_icon_paths[index] = path
    end
    return UI.texture(hud, path, x, y, size)
end

-- EPalWorkSuitability is None=0, EmitFlame=1..MonsterFarm=13; texture index is
-- enum - 1. Small fixed work icons use the safe prefetch path; colored badges
-- remain as an immediate fallback until each icon is resident.
function UI.work_icon_index(work_id)
    local id = math.floor(tonumber(work_id) or 0)
    if id < 1 or id > 13 then return nil end
    return id - 1
end

local WORK_BADGE = {
    [1] = "F", [2] = "W", [3] = "P", [4] = "E", [5] = "H", [6] = "G",
    [7] = "L", [8] = "M", [9] = "+", [10] = "C", [11] = "T", [12] = "O", [13] = "R",
}
local WORK_BADGE_COLOR = {
    [1] = { 0.95, 0.34, 0.14, 1.0 }, [2] = { 0.20, 0.62, 0.95, 1.0 },
    [3] = { 0.30, 0.78, 0.34, 1.0 }, [4] = { 0.98, 0.78, 0.18, 1.0 },
    [5] = { 0.90, 0.66, 0.36, 1.0 }, [6] = { 0.58, 0.82, 0.42, 1.0 },
    [7] = { 0.52, 0.72, 0.28, 1.0 }, [8] = { 0.68, 0.70, 0.74, 1.0 },
    [9] = { 0.92, 0.44, 0.52, 1.0 }, [10] = { 0.42, 0.84, 0.94, 1.0 },
    [11] = { 0.80, 0.62, 0.34, 1.0 }, [12] = { 0.38, 0.38, 0.42, 1.0 },
    [13] = { 0.84, 0.58, 0.32, 1.0 },
}

function UI.work_icon(hud, work_id, x, y, size)
    local index = UI.work_icon_index(work_id)
    if index == nil then return false end
    local asset = string.format("T_icon_palwork_%02d", index)
    if UI.texture(hud, "/Game/Pal/Texture/UI/InGame/" .. asset .. "." .. asset, x, y, size) then
        return true
    end
    local id = index + 1
    local color = WORK_BADGE_COLOR[id] or UI.col.accent
    local scale = size / 18
    UI.rect(hud, UI.col.icon_sq, x, y, size, size)
    UI.rect(hud, color, x, y, math.max(2, 2 * scale), size)
    UI.text(hud, WORK_BADGE[id] or "?", color, x + 6 * scale, y + 2 * scale, 0.44 * scale)
    return true
end

function UI.status_icon(hud, index, x, y, size)
    local path = status_icon_paths[index]
    if path == nil then
        local asset = string.format("T_icon_status_%02d", index)
        path = "/Game/Pal/Texture/UI/Main_Menu/" .. asset .. "." .. asset
        status_icon_paths[index] = path
    end
    return UI.texture(hud, path, x, y, size)
end

function UI.gender_icon(hud, gender, x, y, size)
    local suffix = gender == 2 and "Female" or "Male"
    local path = gender_icon_paths[suffix]
    if path == nil then
        local asset = "T_Icon_PanGender_" .. suffix
        path = "/Game/Pal/Texture/UI/Main_Menu/" .. asset .. "." .. asset
        gender_icon_paths[suffix] = path
    end
    return UI.texture(hud, path, x, y, size)
end

-- Native-menu section header: small accent label over a fading hairline.
-- PalBox separates sections with light labels + whitespace, not solid bands.
function UI.section(hud, label, x, y, w, s)
    local h = 16 * s
    -- Tiny lift so the label isn't glued to the hairline under it.
    UI.text(hud, label, UI.col.accent, x, y - s, 0.48 * s)
    local ly = y + h - 2
    UI.rect(hud, UI.col.hairline, x, ly, w, 1, UI.col.hairline[4] * 0.65)
end

-- Native-style row container: faint fill, hairline outline, white left bar.
function UI.row_box(hud, x, y, w, h, left_bar_spec)
    UI.rect(hud, UI.col.row_bar, x, y, w, h)
    UI.rect(hud, left_bar_spec or UI.col.text, x, y, 2, h)
end

-- Native boxed stat row: icon in a darker square, dim label, right-aligned
-- value, optional quality-colored IV column.
function UI.stat_row(hud, x, y, w, h, s, icon, label, value, iv, with_iv)
    UI.row_box(hud, x, y, w, h)
    UI.rect(hud, UI.col.icon_sq, x + 2, y + 2, h - 4, h - 4)
    local isz = 16 * s
    UI.status_icon(hud, icon, x + (h - isz) / 2, y + (h - isz) / 2, isz)
    UI.text(hud, label, UI.col.dim, x + h + 7 * s, UI.vtext_y(y, h, 0.52, s), 0.52 * s)
    local value_text = value ~= nil and tostring(value) or "?"
    UI.text(hud, value_text, UI.col.text,
        UI.right_text_x(value_text, x + w - 62 * s, s), UI.vtext_y(y, h, 0.58, s), 0.58 * s)
    if with_iv then
        local iv_text = iv ~= nil and tostring(iv) or "?"
        UI.text(hud, iv_text, UI.iv_color(iv),
            UI.right_text_x(iv_text, x + w - 10 * s, s), UI.vtext_y(y, h, 0.58, s), 0.58 * s)
    end
end

function UI.panel(hud, x, y, w, h, header_h, opacity, s)
    s = s or 1
    UI.rect(hud, UI.col.shadow, x + 4 * s, y + 5 * s, w, h)
    if opacity > 0 then
        UI.rect(hud, UI.col.bg, x, y, w, h, opacity)
        UI.rect(hud, UI.col.bg_deep, x, y, w, header_h, math.min(1, opacity + 0.05))
    end
    UI.rect(hud, UI.col.hairline, x, y, w, 1)
    UI.rect(hud, UI.col.hairline, x, y + h - 1, w, 1)
    UI.rect(hud, UI.col.hairline, x, y + header_h, w, 1)
end

-- Native power/element chip. Header chips chamfer right; skill chips wedge left.
-- opts = { w = fixed width, element = id, wedge_left = bool, align_right = bool }.
function UI.chip(hud, spec, label, label_spec, x, y, s, opts)
    opts = opts or {}
    local m = UI.chip_metrics(label, opts.element ~= nil, s)
    local w, h = opts.w or m.w, m.h
    -- opts.fill wins so skill power chips can stay dark against an element bar.
    local fill = opts.fill or UI.ELEMENT_COLORS[tonumber(opts.element)] or spec
    for _, rect in ipairs(UI.chip_rects(w, h, s, opts.wedge_left)) do
        UI.rect(hud, fill, x + rect.dx, y + rect.dy, rect.w, rect.h)
    end
    if opts.element ~= nil then
        UI.element_icon(hud, opts.element, x + (opts.wedge_left and 8 or 3) * s,
            y + 2 * s, 14 * s)
    end
    local text_x = x + m.text_dx
    if opts.align_right then
        text_x = UI.right_text_x(label, x + w - 6 * s, s)
    end
    UI.text(hud, label, label_spec, text_x, UI.vtext_y(y, h, 0.52, s), 0.52 * s)
    return w
end

-- Tan chip with element icon + localized element name (card header).
function UI.element_chip(hud, element_id, name, x, y, s)
    return UI.chip(hud, UI.col.chip, name or "?", UI.col.bg_deep, x, y, s,
        { element = element_id })
end

-- Header element marker: native icon when resident, colored square fallback,
-- plus a small dim element name (PalBox shows bare icons, not tan chips).
-- Returns consumed width so multiple elements can flow horizontally.
function UI.element_tag(hud, element_id, name, x, y, s)
    local isz = 15 * s
    -- Drop the icon onto the label's centerline; at y it rides above the text.
    local icon_y = y + 4 * s
    if not UI.element_icon(hud, element_id, x, icon_y, isz) then
        UI.rect(hud, UI.ELEMENT_COLORS[tonumber(element_id)] or UI.col.chip,
            x + 2 * s, icon_y + 2 * s, isz - 4 * s, isz - 4 * s)
    end
    local label = tostring(name or "?")
    UI.text(hud, label, UI.col.dim, x + isz + 4 * s, y + 5 * s, 0.46 * s)
    local chars = (utf8 and utf8.len(label)) or #label
    return isz + (10 + chars * 8) * s
end

local grade_chip_opts = {}
function UI.grade_chip(hud, grade, x, y, s)
    local key = math.floor((s or 1) * 1000 + 0.5)
    local opts = grade_chip_opts[key]
    if opts == nil then
        opts = { w = 24 * s }
        grade_chip_opts[key] = opts
    end
    UI.chip(hud, UI.GRADE_COLORS[grade] or UI.col.faint, grade, UI.col.bg_deep,
        x, y, s, opts)
end

-- Creative Menu / WBP_MainMenu_PalSkillInfo use these per-rank icons
-- (tint = GetColorBasedOnRank). Prefetch-safe: Main_Menu path, not T_prt_*.
local rank_icon_paths = {}

local function rank_icon_path(abs_rank)
    local n = Util.clamp(math.floor(abs_rank + 0.5), 0, 5)
    local cached = rank_icon_paths[n]
    if cached ~= nil then return cached end
    local name = string.format("T_icon_skillstatus_rank_arrow_%02d", n)
    cached = "/Game/Pal/Texture/UI/Main_Menu/" .. name .. "." .. name
    rank_icon_paths[n] = cached
    return cached
end

local PLUS_TX = "/Game/Pal/Texture/UI/Main_Menu/T_icon_plus.T_icon_plus"
-- Native WBP_MainMenu_Pal_Skill_Passive layers (force-LoadAsset on the
-- game-thread prefetch queue; DrawTexture / DrawMaterial outside draw-hook load).
local TRI_TX = "/Game/Pal/Texture/UI/Main_Menu/T_prt_menu_pal_base_tri.T_prt_menu_pal_base_tri"
local SKILL_BASE_TX = {
    "/Game/Pal/Texture/UI/Main_Menu/T_prt_pal_skill_base_00.T_prt_pal_skill_base_00",
    "/Game/Pal/Texture/UI/Main_Menu/T_prt_pal_skill_base_01.T_prt_pal_skill_base_01",
    "/Game/Pal/Texture/UI/Main_Menu/T_prt_pal_skill_base_02.T_prt_pal_skill_base_02",
}
-- UMG plate materials (AHUD DrawMaterial). Rank picks BaseGrd_1/2/3.
local PLATE_MAT = {
    "/Game/Pal/Material/UI/Ingame/MI_UI_BaseGrd_1",
    "/Game/Pal/Material/UI/Ingame/MI_UI_BaseGrd_2",
    "/Game/Pal/Material/UI/Ingame/MI_UI_BaseGrd_3",
}
local GRD_TX = "/Game/Pal/Material/UI/Texture/T_prt_pal_skill_base_grd.T_prt_pal_skill_base_grd"
local MASK_TX = "/Game/Pal/Material/UI/Texture/T_prt_pal_skill_base_mask.T_prt_pal_skill_base_mask"

-- Only crystalline plates need extra art. Rank icons and other UI assets are
-- discovered on demand by their draw call; geometric fallbacks remain immediate.
local passive_crystal_ensured = false

function UI.ensure_passive_textures(rank)
    if rank == nil or rank < 3 or passive_crystal_ensured then return end
    passive_crystal_ensured = true
    -- Crystalline plates draw only through the RootSet-pin pipeline (portraits'
    -- proven RenderThread GC-safety). Resident on this (game-thread) probe: pin
    -- then cache so the first HUD frame sees a rooted texture. Otherwise queue for
    -- the prefetch worker, which pins-or-drops on resolve; the pin gate downstream
    -- means a non-native host (no pinner) simply keeps the flat-underlay fallback.
    for _, path in ipairs({ TRI_TX, SKILL_BASE_TX[3] }) do
        local tex = find_texture_object(path)
        if tex ~= nil and pin_plate_texture(tex) then
            UI.texture_cache[path] = tex
            UI.texture_missing[path] = nil
        else
            UI.texture_missing[path] = true
            queue_texture(path, false, false)
        end
    end
end

-- Fallback only when native plate textures/materials are not drawable yet.
local function fill_tri(hud, spec, x0, y0, x1, y1, mode, alpha)
    local h = y1 - y0
    local w = x1 - x0
    if h < 1 or w < 1 then return end
    local rows = math.max(1, math.floor(h + 0.5))
    for i = 0, rows - 1 do
        local t = (i + 0.5) / rows
        local left, width
        if mode == "bl" then
            left, width = x0, w * t
        elseif mode == "tl" then
            left, width = x0, w * (1 - t)
        elseif mode == "br" then
            width = w * t
            left = x1 - width
        else -- tr
            width = w * (1 - t)
            left = x1 - width
        end
        if width > 0.5 then
            UI.rect(hud, spec, left, y0 + i * h / rows, width, h / rows + 0.5, alpha)
        end
    end
end

function UI.passive_facet_fill(hud, x, y, w, h, spec)
    local mid = y + h * 0.5
    local x1 = x + w * 0.42
    local x2 = x + w * 0.72
    fill_tri(hud, spec, x, y, x1, mid, "br", 0.18)
    fill_tri(hud, spec, x1, y, x2, mid, "bl", 0.12)
    fill_tri(hud, spec, x, mid, x1, y + h, "tr", 0.14)
    fill_tri(hud, spec, x1, mid, x2, y + h, "tl", 0.08)
end

-- Try several blend modes; Additive washes white so it is intentionally omitted.
local function draw_passive_layer(hud, path, x, y, w, h, tint, layer)
    local short = texture_short_name(path)
    local tex = UI.get_texture(path)
    if not tex then
        log_passive_draw_once("draw-miss-" .. short,
            "passive draw miss " .. layer .. " " .. short
                .. " (failed=" .. tostring(UI.texture_load_failed[path] == true)
                .. " force=" .. tostring(UI.texture_force_reload[path] == true)
                .. " wanted=" .. tostring(UI.texture_wanted_set[path] == true) .. ")")
        return false
    end
    local blends = { BLEND_TRANSLUCENT, BLEND_OPAQUE, BLEND_MODULATE }
    local ok, blend_used = false, nil
    for _, blend in ipairs(blends) do
        if UI.texture_rect(hud, path, x, y, w, h, { tint = tint, blend = blend }) then
            ok, blend_used = true, blend
            break
        end
    end
    log_passive_draw_once("draw-" .. short,
        "passive draw " .. layer .. " " .. short
            .. " ok=" .. tostring(ok)
            .. " blend=" .. tostring(blend_used)
            .. " [" .. describe_texture(tex) .. "]"
            .. " rect=" .. string.format("%.0fx%.0f", w, h)
            .. " mode=" .. tostring(UI.texture_mode)
            .. " rect_ok=" .. tostring(UI.texture_rect_ok))
    return ok
end

-- Flat charcoal fill for Buff/Debuff (R1–R2 / negatives) — matches native
-- WBP_MainMenu_Pal_Skill_Passive Anm_Buff_Normal / Anm_Debuff_Normal.
local PASSIVE_PLATE_FLAT_COLOR = { 0.05, 0.055, 0.065, 0.94 }

-- Stable per-rank crystal parts: RGB fixed, only the R4 base alpha animates. The
-- base tint table is reused (identity stable) so an animated plate allocates
-- nothing per frame — UI.color caches the FLinearColor by quantized rgba.
local crystal_parts_cache = {}

local function crystal_parts(rank)
    local hit = crystal_parts_cache[rank]
    if hit ~= nil then return hit end
    local spec = UI.passive_color(rank)
    local r, g, b = spec[1] or 0, spec[2] or 0, spec[3] or 0
    hit = {
        underlay = { r * 0.025, g * 0.028, b * 0.032, 0.96 },
        tri = { r * 0.38, g * 0.38, b * 0.38, 0.16 },
        base = { r * 0.40, g * 0.40, b * 0.40, 0.55 }, -- [4] set per frame (R4 shimmer)
    }
    crystal_parts_cache[rank] = hit
    return hit
end

-- Rare / Rare2 / Rare3 (positive R3 gold, R4 cyan) use crystalline skill_base_02.
-- Negatives use Anm_Debuff (flat) even at |rank| 3 — never crystal.
local function passive_uses_crystal(rank)
    return rank ~= nil and rank >= 3
end

-- R4 native plays Anm_Rare2/Rare3 + SkillBase_Eff shimmer; approximate with
-- a gentle alpha pulse (AHUD cannot run the UMG widget animation).
local function passive_crystal_alpha(rank)
    if rank == nil or rank < 4 then return 1.0 end
    return 0.82 + 0.18 * (0.5 + 0.5 * math.sin(os.clock() * 3.2))
end

-- Native-style passive skill plate (WBP_MainMenu_Pal_Skill_Passive):
--   positive R3/R4 → LoadAsset T_prt_pal_skill_base_02 + light tri (crystalline)
--   R1/R2/negatives → flat charcoal + left accent only (no crystal blit)
function UI.passive_plate(hud, x, y, w, h, rank)
    UI.ensure_passive_textures(rank)
    local spec = UI.passive_color(rank)
    local crystal = passive_uses_crystal(rank)

    if crystal then
        -- Near-black underlay + dim facets so bright skill text meets contrast.
        -- The crystal blits are cache-only (get_texture returns the pinned texture
        -- once resident); until then draw_passive_layer no-ops to the underlay.
        local parts = crystal_parts(rank)
        UI.rect(hud, parts.underlay, x, y, w, h)
        parts.base[4] = passive_crystal_alpha(rank) * 0.55
        local tri_ok = draw_passive_layer(hud, TRI_TX, x, y, w, h, parts.tri, "tri")
        local base_ok = draw_passive_layer(hud, SKILL_BASE_TX[3], x, y, w, h, parts.base, "base02")
        log_passive_draw_once("plate-crystal-" .. tostring(rank),
            "passive plate crystal rank=" .. tostring(rank)
                .. " base02=" .. tostring(base_ok)
                .. " tri=" .. tostring(tri_ok)
                .. (rank >= 4 and " (R4 shimmer)" or ""))
    else
        UI.rect(hud, PASSIVE_PLATE_FLAT_COLOR, x, y, w, h)
        log_passive_draw_once("plate-flat-" .. tostring(rank),
            "passive plate flat rank=" .. tostring(rank) .. " (Buff/Debuff)")
    end

    -- Full tier border + thick left accent (native LineFrame + edge bar).
    UI.rect(hud, spec, x, y, w, 1)
    UI.rect(hud, spec, x, y + h - 1, w, 1)
    UI.rect(hud, spec, x + w - 1, y, 1, h)
    UI.rect(hud, spec, x, y, math.max(3, h * 0.12), h)
end

-- Aim-card passive row: plate + tier-colored name + rank chevrons.
function UI.passive_row(hud, x, y, w, h, s, passive)
    local p = passive or {}
    local rank = p.rank
    local spec = UI.passive_color(rank)
    UI.passive_plate(hud, x, y, w, h, rank)
    local name = p.name
    local label = Util.truncate(name or "Unresolved passive", 28)
    UI.text(hud, label, name and spec or UI.col.faint, x + 10 * s,
        UI.vtext_y(y, h, 0.54, s), 0.54 * s)
    UI.rank_marker(hud, x + w - 26 * s, y + (h - 14 * s) / 2 - 2 * s, 13 * s, rank, s)
end

-- Small "+" under R4 chevrons only when the native rank texture missed
-- (arrow_04 already carries the rainbow mark — drawing plus on top looked wrong).
local function draw_rank_plus(hud, x, y, size, spec)
    local psz = size * 0.65
    if UI.texture_rect(hud, PLUS_TX, x + (size - psz) / 2, y, psz, psz, { tint = spec }) then
        return
    end
    local arm = math.max(1, size * 0.14)
    local span = math.max(4, size * 0.45)
    local cx = x + size * 0.5
    local cy = y + size * 0.30
    UI.rect(hud, spec, cx - span / 2, cy - arm / 2, span, arm)
    UI.rect(hud, spec, cx - arm / 2, cy - span / 2, arm, span)
end

-- Thin V chevron (rect fallback when rank icon texture is still loading).
local function draw_chevron(hud, spec, x, y, size, up)
    local bar = math.max(1, size * 0.10)
    local steps = 8
    for i = 0, steps - 1 do
        local t = i / (steps - 1)
        local frac = up and (0.20 + 0.80 * t) or (1.0 - 0.80 * t)
        local ww = frac * size
        UI.rect(hud, spec, x + (size - ww) / 2, y + i * bar, ww, bar)
    end
end

-- Passive rank marker: native per-rank icon (flip_v for negatives). Else
-- thin chevrons. R4 adds T_icon_plus / rect plus.
local rank_texture_options_cache = {}

local function rank_texture_options(rank, spec, flip_v)
    local cached = rank_texture_options_cache[rank]
    if cached ~= nil then return cached end
    cached = { tint = spec, flip_v = flip_v }
    rank_texture_options_cache[rank] = cached
    return cached
end

function UI.rank_marker(hud, x, y, size, rank, s)
    if rank == nil then UI.text(hud, "?", UI.col.faint, x, y, 0.70 * s) return end
    if rank == 0 then UI.text(hud, "=", UI.col.dim, x, y, 0.70 * s) return end
    local up = rank > 0
    local abs_rank = Util.clamp(math.abs(rank), 1, 4)
    local spec = UI.passive_color(rank)
    local path = rank_icon_path(abs_rank)
    local icon_w = size * 1.12
    -- R4 atlas includes a baked "+" under the chevrons — draw the full icon.
    local icon_h = size * (abs_rank >= 4 and 1.65 or 1.35)
    -- Rank-arrow icons are on the safe-hud allowlist (small fixed atlas, drawn
    -- unpinned like the element/work icons), so they blit even under vector_only.
    local tex = UI.get_texture(path)
    local texture_options = rank_texture_options(rank, spec, not up)
    if UI.texture_rect(hud, path, x, y, icon_w, icon_h, texture_options) then
        log_passive_draw_once("rank-" .. tostring(rank),
            "passive rank " .. tostring(rank) .. " texture ok flip="
                .. tostring(not up) .. " [" .. describe_texture(tex) .. "]")
        return
    end
    log_passive_draw_once("rank-" .. tostring(rank),
        "passive rank " .. tostring(rank) .. " texture miss -> chevron fallback ["
            .. describe_texture(tex) .. "]")

    local chevs = math.min(abs_rank, 3)
    local step = size * 0.28
    for c = 0, chevs - 1 do
        -- Until the fixed rank texture is resident, use one glyph per marker.
        -- The old eight-strip approximation cost up to 24 DrawRect calls per
        -- passive, every frame, and was the main vector-only card hot spot.
        UI.text(hud, up and "^" or "v", spec,
            x + size * 0.28, y - size * 0.20 + c * step, 0.46 * (s or 1))
    end
    if up and abs_rank >= 4 then
        draw_rank_plus(hud, x, y + chevs * step + size * 0.02, size, spec)
    end
end

return UI
