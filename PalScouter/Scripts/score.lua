-- PalScouter score.lua — PURE Lua scoring/grading/filter/sort.
-- No UObject access anywhere in this file; testable with a plain Lua interpreter.
local PassiveTags = require("passive_tags")

local Score = {}

Score.MODE_LABELS = {
    combat = "COMBAT SCORE",
    work = "WORK SCORE",
    travel = "TRAVEL SCORE",
    breeding = "BREEDING SCORE",
}

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

local function rank_magnitude(rank, cfg)
    if rank == nil then return 0 end
    local abs_rank = rank < 0 and -rank or rank
    local s = cfg.Score.PassivePoints
    if abs_rank >= 4 then return s.R4 or s.R3 or 0 end
    if abs_rank == 3 then return s.R3 or 0 end
    if abs_rank == 2 then return s.R2 or 0 end
    if abs_rank == 1 then return s.R1 or 0 end
    return 0
end

local function iv_weighted(ivs, wh, wa, wd)
    if not ivs or ivs.hp == nil or ivs.atk == nil or ivs.def == nil then return nil end
    local wsum = wh + wa + wd
    if wsum <= 0 then wsum = 1 end
    return (ivs.hp * wh + ivs.atk * wa + ivs.def * wd) / wsum
end

local function peak_work_rank(works)
    local peak = 0
    for i = 1, #(works or {}) do
        local r = tonumber(works[i].rank) or 0
        if r > peak then peak = r end
    end
    if peak < 0 then peak = 0 end
    if peak > 5 then peak = 5 end
    return peak
end

-- Weighted IV average scaled into the IV share of the combat score.
-- Returns nil when any IV is unknown (unreplicated) — the entry grades "?".
function Score.iv_part(ivs, cfg)
    local avg = iv_weighted(ivs, cfg.Score.WeightHP, cfg.Score.WeightAttack, cfg.Score.WeightDefense)
    if avg == nil then return nil end
    return avg * cfg.Score.IVWeight
end

-- Baseline + per-passive points by data-table rank, clamped to the passive share.
-- Pure work-tagged passives are skipped so worker rainbows do not pad Combat.
function Score.passive_part(passives, cfg)
    local s = cfg.Score
    local pts = 0
    for i = 1, #(passives or {}) do
        local p = passives[i]
        if PassiveTags.is_work_only(p.raw) then
            -- skip
        else
            local rank = p.rank
            if rank ~= nil then
                local mag = rank_magnitude(rank, cfg)
                if rank < 0 then mag = -mag end
                pts = pts + mag
            end
        end
    end
    local max_part = 100 - (100 * s.IVWeight)
    return clamp(s.PassiveBaseline + pts, 0, max_part)
end

local function role_passive_part(passives, cfg, opts)
    local pts = opts.baseline or 0
    for i = 1, #(passives or {}) do
        local p = passives[i]
        local tags = PassiveTags.tags_for(p.raw)
        local mag = rank_magnitude(p.rank, cfg)
        if opts.tag == nil then
            if p.rank ~= nil and p.rank > 0 then
                pts = pts + mag
            elseif p.rank ~= nil and p.rank < 0 then
                pts = pts - mag
            end
        else
            if tags[opts.tag] then
                if p.rank ~= nil and p.rank < 0 then
                    pts = pts - mag
                else
                    pts = pts + mag
                end
            end
            if opts.penalties and tags.work_penalty then
                pts = pts - mag
            end
        end
    end
    return clamp(pts, 0, opts.max_part)
end

function Score.compute_combat(entry, cfg)
    local ivp = Score.iv_part(entry.ivs, cfg)
    if ivp == nil then return nil end
    local pp = Score.passive_part(entry.passives, cfg)
    return math.floor(ivp + pp + 0.5)
end

function Score.compute_work(entry, cfg)
    local iv_avg = iv_weighted(entry.ivs, 1, 1, 1)
    if iv_avg == nil then return nil end
    local ivp = iv_avg * 0.10
    local pp = role_passive_part(entry.passives, cfg, {
        tag = "work", max_part = 70, baseline = 10, penalties = true,
    })
    local suit = math.floor(20 * peak_work_rank(entry.works) / 5 + 0.5)
    return math.floor(ivp + pp + suit + 0.5)
end

function Score.compute_travel(entry, cfg)
    local iv_avg = iv_weighted(entry.ivs, 0.40, 0.20, 0.40)
    if iv_avg == nil then return nil end
    local ivp = iv_avg * 0.15
    local pp = role_passive_part(entry.passives, cfg, {
        tag = "travel", max_part = 85, baseline = 15, penalties = false,
    })
    return math.floor(ivp + pp + 0.5)
end

function Score.compute_breeding(entry, cfg)
    local iv_avg = iv_weighted(entry.ivs, 1, 1, 1)
    if iv_avg == nil then return nil end
    local ivp = iv_avg * 0.70
    local pp = role_passive_part(entry.passives, cfg, {
        tag = nil, max_part = 30, baseline = 8, penalties = false,
    })
    return math.floor(ivp + pp + 0.5)
end

-- Composite 0-100 score, or nil when IVs are unknown.
function Score.compute(entry, cfg)
    local mode = (cfg.Score and cfg.Score.Mode) or "combat"
    if mode == "work" then return Score.compute_work(entry, cfg) end
    if mode == "travel" then return Score.compute_travel(entry, cfg) end
    if mode == "breeding" then return Score.compute_breeding(entry, cfg) end
    return Score.compute_combat(entry, cfg)
end

function Score.grade(total, cfg)
    if total == nil then return "?" end
    local g = cfg.Score.Grades
    if total >= g.S then return "S" end
    if total >= g.A then return "A" end
    if total >= g.B then return "B" end
    if total >= g.C then return "C" end
    return "D"
end

function Score.best_passive(passives)
    local best
    for i = 1, #(passives or {}) do
        local p = passives[i]
        if best == nil or (p.rank or 0) > (best.rank or 0) then best = p end
    end
    return best
end

-- Best→worst by rank; nil ranks sort last. Mutates and returns the array.
function Score.sort_passives(passives)
    local list = passives or {}
    table.sort(list, function(a, b)
        local ra, rb = a.rank, b.rank
        if ra == rb then return false end
        if ra == nil then return false end
        if rb == nil then return true end
        return ra > rb
    end)
    return list
end

local function watchlist_needles(filter)
    local watch = filter.Watchlist
    if type(watch) == "table" and #watch > 0 then return watch end
    -- Backward-compat: legacy Species string until configs migrate.
    if type(filter.Species) == "string" and filter.Species ~= "" then
        return { string.lower(filter.Species) }
    end
    return nil
end

local function matches_watchlist(entry, needles)
    if needles == nil or #needles == 0 then return true end
    local hay = string.lower((entry.name or "") .. " " .. (entry.character_id or ""))
    for i = 1, #needles do
        local needle = string.lower(tostring(needles[i] or ""))
        if needle ~= "" and string.find(hay, needle, 1, true) then return true end
    end
    return false
end

function Score.passes_filter(entry, cfg)
    local f = cfg.Filter
    local ownership = f.Ownership or "wild"
    -- Defense in depth: WILD ONLY never lists owned; EVERYTHING never lists local-owned.
    if entry.wild == "owned" then
        if ownership ~= "all" then return false end
        if entry.local_owned == true then return false end
    end
    if entry.wild == "unknown" and not f.ShowUnknownOwnership and ownership ~= "all" then
        return false
    end
    if not matches_watchlist(entry, watchlist_needles(f)) then return false end

    local has_positive, has_negative = false, false
    for i = 1, #(entry.passives or {}) do
        local r = entry.passives[i].rank
        if r ~= nil and r > 0 then has_positive = true end
        if r ~= nil and r < 0 then has_negative = true end
    end
    if f.RequirePositivePassive and not has_positive then return false end
    if f.HideIfNegativePassive and has_negative and not has_positive then return false end

    -- Score-based filters never hide unknown-IV pals silently.
    if entry.score ~= nil then
        if entry.score < (f.MinScore or 0) then return false end
        if (f.MinSingleIV or 0) > 0 and entry.ivs then
            local best_iv = math.max(entry.ivs.hp or 0, entry.ivs.atk or 0, entry.ivs.def or 0)
            if best_iv < f.MinSingleIV then return false end
        end
    end
    return true
end

local function by_distance_then_key(a, b)
    local ad, bd = a.distance or math.huge, b.distance or math.huge
    if ad ~= bd then return ad < bd end
    return tostring(a.key or a.name or "") < tostring(b.key or b.name or "")
end

-- In-place deterministic sort. Modes: "score" (desc, unknowns last), "distance" (asc), "level" (desc).
function Score.sort_entries(entries, mode)
    local cmp
    if mode == "distance" then
        cmp = by_distance_then_key
    elseif mode == "level" then
        cmp = function(a, b)
            local al, bl = a.level or -1, b.level or -1
            if al ~= bl then return al > bl end
            return by_distance_then_key(a, b)
        end
    else
        cmp = function(a, b)
            local as, bs = a.score, b.score
            if as == nil and bs == nil then return by_distance_then_key(a, b) end
            if as == nil then return false end
            if bs == nil then return true end
            if as ~= bs then return as > bs end
            return by_distance_then_key(a, b)
        end
    end
    table.sort(entries, cmp)
    return entries
end

return Score
