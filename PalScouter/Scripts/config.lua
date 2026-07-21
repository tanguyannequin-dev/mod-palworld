-- PalScouter config.lua — defaults, userconfig persistence, filter presets.
local Util = require("util")

local Config = {}

local function deep_copy(t)
    local out = {}
    for k, v in pairs(t) do
        if type(v) == "table" then out[k] = deep_copy(v) else out[k] = v end
    end
    return out
end

-- Native lifecycle registry keeps the 1000 m option bounded and free of
-- FindAllOf; poll batches still cap per-tick snapshot work.
Config.RADIUS_STEPS = { 50, 100, 200, 500, 1000 }
Config.INTERVAL_STEPS = { 500, 1000, 2000, 4000 } -- 0.5s / 1s / 2s / 4s
-- Worst-case latency before the aim card appears (idle aim-scan cadence).
-- Lower = snappier popup at the cost of more game-thread polling.
Config.AIM_DELAY_STEPS = { 250, 500, 1000, 2000 } -- 0.25s / 0.5s / 1s / 2s
Config.SCORE_MODES = { "combat", "work", "travel", "breeding" }
Config.SORT_MODES = { "score", "distance", "level" }
Config.OWNERSHIP_MODES = { "wild", "all" }
Config.MAX_ROWS_MIN = 5
Config.MAX_ROWS_MAX = 20
Config.OPACITY_MIN = 0.50
Config.OPACITY_MAX = 1.00
Config.OPACITY_STEP = 0.05
Config.SCALE_MIN = 0.5
Config.SCALE_MAX = 2.0
Config.SCALE_STEP = 0.1
Config.WATCHLIST_MAX = 8

Config.DEFAULTS = {
    LayoutVersion = 6,
    Enabled = true,
    Language = "en",
    AimCard = { ShowMode = "always", OffsetX = -500, OffsetY = 24, Scale = 1.0, BackgroundOpacity = 0.90, AcquireMs = 1000 },
    Panel = { OffsetX = 20, OffsetY = 140, Scale = 1.0, MaxRows = 10, BackgroundOpacity = 0.90 },
    Scan = { RadiusMeters = 100, IntervalMs = 1000, MaxNewPerTick = 4, EvictAfterMisses = 2 },
    Score = {
        Mode = "combat",
        WeightHP = 0.25, WeightAttack = 0.50, WeightDefense = 0.25,
        IVWeight = 0.60, PassiveBaseline = 20,
        PassivePoints = { R1 = 5, R2 = 9, R3 = 14, R4 = 18 },
        Grades = { S = 85, A = 70, B = 55, C = 40 },
    },
    Filter = {
        Preset = "Off",
        MinScore = 0, MinSingleIV = 0,
        RequirePositivePassive = false, HideIfNegativePassive = false,
        Species = "", -- deprecated; migrated into Watchlist
        ShowUnknownOwnership = false,
        Ownership = "wild", -- "wild" | "all"
        Watchlist = {}, -- lowercase character-id needles; empty = no species gate
    },
    Base = { HideUiInBase = false },
    Sort = "score",
    Keys = {
        TogglePanel = "F8",
        ToggleSettings = "F7",
        CycleSort = "F6",
        ToggleCard = "SHIFT+F8",
        NextPage = "SHIFT+F7",
    },
}

Config.current = deep_copy(Config.DEFAULTS)

Config.FILTER_PRESETS = {
    { name = "Off",          apply = { MinScore = 0,  MinSingleIV = 0,  RequirePositivePassive = false } },
    { name = "Grade B+",     apply = { MinScore = 55, MinSingleIV = 0,  RequirePositivePassive = false } },
    { name = "Grade A+",     apply = { MinScore = 70, MinSingleIV = 0,  RequirePositivePassive = false } },
    { name = "Good passive", apply = { MinScore = 0,  MinSingleIV = 0,  RequirePositivePassive = true } },
    { name = "Elite IV",     apply = { MinScore = 0,  MinSingleIV = 85, RequirePositivePassive = false } },
}

-- Index of value, or nil when absent (unlike step_in's default-to-1 lookup).
local function find_index(list, value)
    for i = 1, #list do
        if list[i] == value then return i end
    end
    return nil
end

local function step_in(list, value, delta)
    local i = find_index(list, value) or 1
    local n = #list
    local j = ((i - 1 + (delta or 1)) % n) + 1
    if j < 1 then j = j + n end
    return list[j]
end

-- Nearest discrete step to value (ties resolve to the earlier/smaller step).
local function nearest_step(steps, value, default)
    local v = tonumber(value) or default
    local best, best_dist = steps[1], math.huge
    for i = 1, #steps do
        local d = math.abs(steps[i] - v)
        if d < best_dist then best, best_dist = steps[i], d end
    end
    return best
end

function Config.snap_radius(meters)
    return nearest_step(Config.RADIUS_STEPS, meters, 100)
end

function Config.snap_interval(ms)
    return nearest_step(Config.INTERVAL_STEPS, ms, 1000)
end

function Config.snap_aim_delay(ms)
    return nearest_step(Config.AIM_DELAY_STEPS, ms, 1000)
end

function Config.snap_opacity(v)
    v = tonumber(v) or 0.90
    v = Util.clamp(v, Config.OPACITY_MIN, Config.OPACITY_MAX)
    local steps = math.floor((v - Config.OPACITY_MIN) / Config.OPACITY_STEP + 0.5)
    return Config.OPACITY_MIN + steps * Config.OPACITY_STEP
end

function Config.cycle_preset(delta)
    delta = delta or 1
    local names = {}
    for i, preset in ipairs(Config.FILTER_PRESETS) do names[i] = preset.name end
    local nxt_name = step_in(names, Config.current.Filter.Preset or "Off", delta)
    for _, preset in ipairs(Config.FILTER_PRESETS) do
        if preset.name == nxt_name then
            Config.current.Filter.Preset = preset.name
            for k, v in pairs(preset.apply) do Config.current.Filter[k] = v end
            break
        end
    end
    Config.queue_save()
    return Config.current.Filter.Preset
end

function Config.cycle_radius(delta)
    local value = step_in(Config.RADIUS_STEPS, Config.snap_radius(Config.current.Scan.RadiusMeters), delta or 1)
    Config.current.Scan.RadiusMeters = value
    Config.queue_save()
    return value
end

function Config.cycle_interval(delta)
    local value = step_in(Config.INTERVAL_STEPS, Config.snap_interval(Config.current.Scan.IntervalMs), delta or 1)
    Config.current.Scan.IntervalMs = value
    Config.queue_save()
    return value
end

function Config.interval_label(ms)
    local v = Config.snap_interval(ms or Config.current.Scan.IntervalMs)
    if v % 1000 == 0 then
        return string.format("%ds", v / 1000)
    end
    return string.format("%.1fs", v / 1000)
end

-- Discrete steps map cleanly to exact labels; keep them explicit so 250 ms
-- reads as "0.25s" rather than a rounded "0.2s".
local AIM_DELAY_LABELS = { [250] = "0.25s", [500] = "0.5s", [1000] = "1s", [2000] = "2s" }

function Config.aim_delay_label(ms)
    local v = Config.snap_aim_delay(ms or Config.current.AimCard.AcquireMs)
    return AIM_DELAY_LABELS[v] or string.format("%.2fs", v / 1000)
end

function Config.cycle_aim_delay(delta)
    local value = step_in(Config.AIM_DELAY_STEPS, Config.snap_aim_delay(Config.current.AimCard.AcquireMs), delta or 1)
    Config.current.AimCard.AcquireMs = value
    Config.queue_save()
    return value
end

Config.SHOW_MODES = { "always", "sphere", "off" }
local SHOW_MODE_LABELS = { always = "ALWAYS", sphere = "SPHERE ONLY", off = "OFF" }

function Config.show_mode_label(mode)
    return SHOW_MODE_LABELS[mode] or "ALWAYS"
end

function Config.cycle_show_mode(delta)
    local value = step_in(Config.SHOW_MODES, Config.current.AimCard.ShowMode or "always", delta or 1)
    Config.current.AimCard.ShowMode = value
    Config.queue_save()
    return value
end

Config.LANGUAGES = { "en", "fr", "es", "zh", "ko" }

function Config.cycle_language(delta)
    local value = step_in(Config.LANGUAGES, Config.current.Language or "en", delta or 1)
    Config.current.Language = value
    Config.queue_save()
    return value
end

-- Pure migration rule for pre-v4 userconfigs (exposed for tests).
function Config.migrate_show_mode(aim_section)
    if type(aim_section) ~= "table" then return "always" end
    if aim_section.ShowMode ~= nil then return aim_section.ShowMode end
    if aim_section.Enabled == false then return "off" end
    return "always"
end

function Config.cycle_score_mode(delta)
    local value = step_in(Config.SCORE_MODES, Config.current.Score.Mode or "combat", delta or 1)
    Config.current.Score.Mode = value
    Config.queue_save()
    return value
end

function Config.cycle_sort(delta)
    local value = step_in(Config.SORT_MODES, Config.current.Sort or "score", delta or 1)
    Config.current.Sort = value
    Config.queue_save()
    return value
end

local OWNERSHIP_LABELS = { wild = "WILD ONLY", all = "EVERYTHING" }

function Config.ownership_label(mode)
    return OWNERSHIP_LABELS[mode] or "WILD ONLY"
end

function Config.cycle_ownership(delta)
    local value = step_in(Config.OWNERSHIP_MODES, Config.current.Filter.Ownership or "wild", delta or 1)
    Config.current.Filter.Ownership = value
    Config.queue_save()
    return value
end

function Config.cycle_hide_in_base(delta)
    -- delta ignored for boolean toggle; kept for Left/Right symmetry.
    local nxt = not (Config.current.Base.HideUiInBase == true)
    Config.current.Base.HideUiInBase = nxt
    Config.queue_save()
    return nxt
end

function Config.hide_in_base_label(v)
    return (v == true) and "ON" or "OFF"
end

-- Lazy-built Off + sorted pal_icon_names keys for F7 watchlist cycling.
local watch_picks = nil
function Config.watch_picks()
    if watch_picks then return watch_picks end
    local ok, icons = pcall(require, "pal_icon_names")
    local names = {}
    if ok and type(icons) == "table" then
        for id in pairs(icons) do names[#names + 1] = id end
        table.sort(names)
    end
    watch_picks = { "" }
    for i = 1, #names do watch_picks[#watch_picks + 1] = names[i] end
    return watch_picks
end

-- NPC / tutorial stubs — not scoutable; some AV on localize (Help01/Hunter).
Config.WATCH_DENY_EXACT = {
    commonhuman = true,
    believer = true,
    believer_fat = true,
    doctor = true,
    firecult = true,
    policeman = true,
    police = true,
    salesman = true,
    scientist = true,
    help01 = true,
    help02 = true,
    help03 = true,
    help04 = true,
    hunter = true,
    hunter_fat = true,
}

Config.WATCH_DENY_PREFIXES = {
    "male_",
    "female_",
    "human_",
    "reward_",
    "mobucitizen",
    "help",
}

function Config.is_watchlist_denied(id)
    id = string.lower(tostring(id or ""))
    if id == "" then return true end
    if Config.WATCH_DENY_EXACT[id] then return true end
    for i = 1, #Config.WATCH_DENY_PREFIXES do
        local p = Config.WATCH_DENY_PREFIXES[i]
        if string.sub(id, 1, #p) == p then return true end
    end
    if string.find(id, "_male", 1, true) or string.find(id, "_female", 1, true) then
        return true
    end
    return false
end

function Config.normalize_watchlist(list)
    if type(list) == "string" then
        local parts = {}
        for part in string.gmatch(list, "[^,]+") do
            parts[#parts + 1] = part
        end
        list = parts
    end
    if type(list) ~= "table" then return {} end
    local out, seen = {}, {}
    for i = 1, #list do
        local needle = Util.lower_trim(list[i])
        if needle ~= "" and not seen[needle] and not Config.is_watchlist_denied(needle) then
            seen[needle] = true
            out[#out + 1] = needle
            if #out >= Config.WATCHLIST_MAX then break end
        end
    end
    return out
end

local function set_watchlist(list)
    Config.current.Filter.Watchlist = Config.normalize_watchlist(list)
    Config.queue_save()
    return Config.watchlist_label(Config.current)
end

Config.WATCHLIST_OPEN_PICKER = "__OPEN_PICKER__"

function Config.apply_watchlist(list)
    return set_watchlist(list)
end

function Config.clear_watchlist()
    return set_watchlist({})
end

function Config.watchlist_label(cfg, names)
    local list = Config.normalize_watchlist(cfg and cfg.Filter and cfg.Filter.Watchlist)
    if #list == 0 then return "OFF" end
    if #list == 1 then
        local id = list[1]
        if type(names) == "table" and type(names[id]) == "string" and names[id] ~= "" then
            return names[id]
        end
        return string.upper(id)
    end
    return string.format("CUSTOM (%d)", #list)
end

-- Left clears; Right/positive returns open-picker sentinel (UI opens nested picker).
function Config.cycle_watchlist(delta)
    delta = delta or 1
    if delta < 0 then return Config.clear_watchlist() end
    return Config.WATCHLIST_OPEN_PICKER
end

-- Add/remove one species id on the watchlist (Enter-on-WATCHLIST with aim target).
function Config.watchlist_toggle(id)
    local needle = Util.lower_trim(id)
    if needle == "" then return Config.watchlist_label(Config.current) end
    -- Strip BOSS_/GYM_ so alphas match the base species watch entry.
    needle = needle:gsub("^boss_", ""):gsub("^gym_", "")
    if Config.is_watchlist_denied(needle) then
        return Config.watchlist_label(Config.current)
    end
    local list = Config.normalize_watchlist(Config.current.Filter.Watchlist)
    local found = find_index(list, needle)
    if found then
        table.remove(list, found)
    elseif #list < Config.WATCHLIST_MAX then
        list[#list + 1] = needle
    end
    return set_watchlist(list)
end

-- Migrate pre-v5 Species string into Watchlist (exposed for tests).
function Config.migrate_watchlist(filter_section)
    if type(filter_section) ~= "table" then return {} end
    local existing = Config.normalize_watchlist(filter_section.Watchlist)
    if #existing > 0 then return existing end
    local species = filter_section.Species
    if type(species) == "string" and species ~= "" then
        return Config.normalize_watchlist({ species })
    end
    return {}
end

function Config.cycle_max_rows(delta)
    local cur = tonumber(Config.current.Panel.MaxRows) or 10
    local nxt = Util.clamp(cur + (delta or 1), Config.MAX_ROWS_MIN, Config.MAX_ROWS_MAX)
    Config.current.Panel.MaxRows = nxt
    Config.queue_save()
    return nxt
end

function Config.cycle_opacity(section_name, delta)
    local section = Config.current[section_name]
    if type(section) ~= "table" then return nil end
    local cur = Config.snap_opacity(section.BackgroundOpacity)
    local steps = math.floor((delta or 1))
    local nxt = Config.snap_opacity(cur + steps * Config.OPACITY_STEP)
    section.BackgroundOpacity = nxt
    Config.queue_save()
    return nxt
end

function Config.snap_scale(v)
    v = Util.clamp(tonumber(v) or 1.0, Config.SCALE_MIN, Config.SCALE_MAX)
    local steps = math.floor((v - Config.SCALE_MIN) / Config.SCALE_STEP + 0.5)
    -- Round to one decimal so 0.1 float steps stay exact for display/compare.
    return math.floor((Config.SCALE_MIN + steps * Config.SCALE_STEP) * 10 + 0.5) / 10
end

function Config.scale_label(v)
    return tostring(math.floor(Config.snap_scale(v) * 100 + 0.5)) .. "%"
end

function Config.cycle_scale(section_name, delta)
    local section = Config.current[section_name]
    if type(section) ~= "table" then return nil end
    local nxt = Config.snap_scale(Config.snap_scale(section.Scale) + (delta or 1) * Config.SCALE_STEP)
    section.Scale = nxt
    Config.queue_save()
    return nxt
end

-- Offset clamp ranges match sanitize(): AimCard is anchor-relative (+/-),
-- Panel offsets are measured from the right/top screen edges (>= 0).
local OFFSET_RANGE = {
    AimCard = { -2000, 2000, -2000, 2000 },
    Panel = { 0, 2000, 0, 2000 },
}

function Config.nudge_offset(section_name, dx, dy)
    local section = Config.current[section_name]
    local range = OFFSET_RANGE[section_name]
    if type(section) ~= "table" or range == nil then return nil end
    section.OffsetX = Util.clamp((tonumber(section.OffsetX) or 0) + (dx or 0), range[1], range[2])
    section.OffsetY = Util.clamp((tonumber(section.OffsetY) or 0) + (dy or 0), range[3], range[4])
    Config.queue_save()
    return section.OffsetX, section.OffsetY
end

-- ------------------------------------------------------------ sanitize

local function num(section, key, lo, hi)
    local v = tonumber(section[key])
    if v == nil then return end
    section[key] = Util.clamp(v, lo, hi)
end

function Config.sanitize()
    local c = Config.current
    num(c.AimCard, "OffsetX", -2000, 2000); num(c.AimCard, "OffsetY", -2000, 2000)
    num(c.AimCard, "Scale", 0.5, 2.0);      num(c.AimCard, "BackgroundOpacity", 0, 1)
    num(c.Panel, "OffsetX", 0, 2000);       num(c.Panel, "OffsetY", 0, 2000)
    num(c.Panel, "Scale", 0.5, 2.0)
    num(c.Panel, "MaxRows", Config.MAX_ROWS_MIN, Config.MAX_ROWS_MAX)
    num(c.Panel, "BackgroundOpacity", 0, 1)
    num(c.Scan, "RadiusMeters", 10, 2000);  num(c.Scan, "IntervalMs", 500, 10000)
    num(c.Scan, "MaxNewPerTick", 1, 16);    num(c.Scan, "EvictAfterMisses", 1, 10)
    num(c.Score, "IVWeight", 0.1, 1.0);     num(c.Score, "PassiveBaseline", 0, 40)
    c.Scan.RadiusMeters = Config.snap_radius(c.Scan.RadiusMeters)
    c.Scan.IntervalMs = Config.snap_interval(c.Scan.IntervalMs)
    c.AimCard.BackgroundOpacity = Config.snap_opacity(c.AimCard.BackgroundOpacity)
    c.AimCard.AcquireMs = Config.snap_aim_delay(c.AimCard.AcquireMs)
    c.Panel.BackgroundOpacity = Config.snap_opacity(c.Panel.BackgroundOpacity)
    local mode = c.Score.Mode or "combat"
    local known = false
    for i = 1, #Config.SCORE_MODES do
        if Config.SCORE_MODES[i] == mode then known = true break end
    end
    if not known then c.Score.Mode = "combat" end
    if c.Sort ~= "score" and c.Sort ~= "distance" and c.Sort ~= "level" then c.Sort = "score" end
    local lang = c.Language or "en"
    local lang_known = false
    for i = 1, #Config.LANGUAGES do
        if Config.LANGUAGES[i] == lang then lang_known = true break end
    end
    if not lang_known then c.Language = "en" end
    local sm = c.AimCard.ShowMode
    if sm ~= "always" and sm ~= "sphere" and sm ~= "off" then c.AimCard.ShowMode = "always" end
    c.AimCard.Enabled = nil

    local own = c.Filter.Ownership
    if own ~= "wild" and own ~= "all" then c.Filter.Ownership = "wild" end
    c.Filter.Watchlist = Config.normalize_watchlist(c.Filter.Watchlist)
    c.Filter.Species = ""

    c.Base = c.Base or {}
    if c.Base.HideUiInBase ~= true then c.Base.HideUiInBase = false end

    -- Fill missing Rank point buckets (older userconfigs may lack R4).
    c.Score.PassivePoints = c.Score.PassivePoints or {}
    local pp, dpp = c.Score.PassivePoints, Config.DEFAULTS.Score.PassivePoints
    for _, key in ipairs({ "R1", "R2", "R3", "R4" }) do
        if tonumber(pp[key]) == nil then pp[key] = dpp[key] end
    end

    -- Ensure required keybinds exist; drop obsolete strip/ShadowPlay-colliding names.
    c.Keys = c.Keys or {}
    local defaults = Config.DEFAULTS.Keys
    for k, v in pairs(defaults) do
        if c.Keys[k] == nil or c.Keys[k] == "" then c.Keys[k] = v end
    end
    c.Keys.CycleFilter = nil
    c.Keys.CycleSettingsFocus = nil
    c.Keys.CycleSettingsValue = nil
end

-- ------------------------------------------------------------ persistence

local FILE_NAME = "PalScouter.userconfig.lua"

function Config.resolve_dir()
    if Config.dir ~= nil then return Config.dir end
    local source = debug and debug.getinfo and debug.getinfo(1, "S").source or ""
    local scripts_dir = source:gsub("^@", ""):match("^(.*)[/\\][^/\\]+$")
    local mod_dir = scripts_dir and scripts_dir:match("^(.*)[/\\][^/\\]+$")
    if mod_dir then Config.dir = mod_dir return mod_dir end
    local ok, dirs = pcall(IterateGameDirectories)
    if not ok or type(dirs) ~= "table" then return nil end
    local game = dirs.Game
    local binaries = game and game.Binaries
    local win = binaries and (binaries.Win64 or binaries.WinGDK)
    local candidates = {}
    if win then
        if win.ue4ss and win.ue4ss.Mods then candidates[#candidates + 1] = win.ue4ss.Mods end
        if win.Mods then candidates[#candidates + 1] = win.Mods end
    end
    for _, mods in ipairs(candidates) do
        -- The integrated release ships in Mods/PalScouter. Keep the
        -- contributor's original folder name as a compatibility fallback.
        local our = mods.PalScouter or mods.PalScouterNative
        if our and our.__absolute_path then
            Config.dir = our.__absolute_path
            return Config.dir
        end
    end
    return nil
end

local function serialize(value, indent)
    indent = indent or ""
    if type(value) ~= "table" then
        if type(value) == "string" then return string.format("%q", value) end
        return tostring(value)
    end
    local keys = {}
    for k in pairs(value) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local parts = { "{" }
    local child_indent = indent .. "    "
    for _, k in ipairs(keys) do
        parts[#parts + 1] = child_indent .. k .. " = " .. serialize(value[k], child_indent) .. ","
    end
    parts[#parts + 1] = indent .. "}"
    return table.concat(parts, "\n")
end

function Config.save()
    local dir = Config.resolve_dir()
    if not dir then return false end
    local ok = pcall(function()
        local file = io.open(dir .. "/" .. FILE_NAME, "wb")
        if not file then error("open failed") end
        file:write("-- PalScouter user settings (auto-generated; safe to edit while the game is closed)\nreturn " ..
            serialize(Config.current) .. "\n")
        file:close()
    end)
    if not ok then Util.log("WARNING: could not save userconfig") end
    return ok
end

local save_generation = 0
function Config.queue_save()
    save_generation = save_generation + 1
    local gen = save_generation
    pcall(ExecuteWithDelay, 750, function()
        if gen == save_generation then Config.save() end
    end)
end

local function merge_into(target, loaded)
    for k, v in pairs(loaded) do
        if target[k] ~= nil then
            if type(target[k]) == "table" and type(v) == "table" then
                merge_into(target[k], v)
            elseif type(target[k]) == type(v) then
                target[k] = v
            end
        end
    end
end

-- Load userconfig as a data-only chunk (no _ENV / no engine APIs).
-- Returns ok, table_or_nil.
function Config.parse_userconfig_source(src)
    if type(src) ~= "string" or src == "" then return false, nil end
    local env = {}
    local chunk, err = load(src, "@" .. FILE_NAME, "t", env)
    if not chunk then return false, nil end
    local ok, data = pcall(chunk)
    if ok and type(data) == "table" then return true, data end
    return false, nil
end

function Config.load()
    local dir = Config.resolve_dir()
    if not dir then
        Util.log("Config dir not found; using defaults (no persistence)")
        return
    end
    local path = dir .. "/" .. FILE_NAME
    local src
    local ok_read = pcall(function()
        local file = io.open(path, "rb")
        if not file then return end
        src = file:read("*a")
        file:close()
    end)
    if not ok_read or src == nil or src == "" then
        Config.save() -- first run: write defaults
        Util.log("Wrote default userconfig")
        return
    end
    local ok, data = Config.parse_userconfig_source(src)
    if ok and type(data) == "table" then
        local old_ver = tonumber(data.LayoutVersion)
        if old_ver == nil then
            data.AimCard = data.AimCard or {}
            data.AimCard.OffsetX = data.AimCard.OffsetX or Config.DEFAULTS.AimCard.OffsetX
            data.AimCard.OffsetY = data.AimCard.OffsetY or Config.DEFAULTS.AimCard.OffsetY
            data.AimCard.BackgroundOpacity = data.AimCard.BackgroundOpacity
                or Config.DEFAULTS.AimCard.BackgroundOpacity
        end
        if old_ver == nil or old_ver < 3 then
            -- Force ShadowPlay-safe key defaults when upgrading from strip-era configs.
            data.Keys = deep_copy(Config.DEFAULTS.Keys)
            data.LayoutVersion = 3
        end
        if tonumber(data.LayoutVersion) < 4 then
            data.AimCard = data.AimCard or {}
            data.AimCard.ShowMode = Config.migrate_show_mode(data.AimCard)
            data.LayoutVersion = 4
        end
        if tonumber(data.LayoutVersion) < 5 then
            data.Filter = data.Filter or {}
            data.Filter.Watchlist = Config.migrate_watchlist(data.Filter)
            data.Filter.Species = ""
            data.Filter.Ownership = data.Filter.Ownership or "wild"
            data.Base = data.Base or {}
            if data.Base.HideUiInBase == nil then data.Base.HideUiInBase = false end
            data.LayoutVersion = 5
        end
        if tonumber(data.LayoutVersion) < 6 then
            data.AimCard = data.AimCard or {}
            if data.AimCard.AcquireMs == nil then
                data.AimCard.AcquireMs = Config.DEFAULTS.AimCard.AcquireMs
            end
            data.LayoutVersion = 6
        end
        merge_into(Config.current, data)
        -- Array Watchlist does not merge into {} via merge_into key-existence rule.
        if type(data.Filter) == "table" and data.Filter.Watchlist ~= nil then
            Config.current.Filter.Watchlist = data.Filter.Watchlist
        end
        Config.current.LayoutVersion = 6
        Config.sanitize()
        Util.log("Loaded userconfig")
    else
        Util.log("WARNING: userconfig unreadable; using defaults")
    end
end

return Config
