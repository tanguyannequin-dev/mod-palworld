-- PalScouter profile.lua — opt-in section timers + periodic UE4SS.log dumps.
local Util = require("util")

local Profile = {}
Profile._log = nil

local window = {} -- name -> { count, total_ms, max_ms }
local context_fn = nil
local prev_mem = nil -- baseline snapshot for deltas
local dump_gen = 0

local function logger()
    return Profile._log or Util.log
end

local function record(name, ms)
    local s = window[name]
    if s == nil then
        s = { count = 0, total_ms = 0, max_ms = 0 }
        window[name] = s
    end
    s.count = s.count + 1
    s.total_ms = s.total_ms + ms
    if ms > s.max_ms then s.max_ms = ms end
end

local function pair_count(t)
    if type(t) ~= "table" then return 0 end
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

function Profile.reset_window()
    window = {}
end

function Profile.reset_mem_baseline()
    prev_mem = nil
end

function Profile.set_context(fn)
    context_fn = fn
end

function Profile.span(name, fn, ...)
    if not Util.PROFILE then
        return fn(...)
    end
    local t0 = os.clock()
    local ok, a, b, c, d, e, f = pcall(fn, ...)
    local ms = (os.clock() - t0) * 1000
    record(name, ms)
    if not ok then error(a) end
    return a, b, c, d, e, f
end

local function sorted_names()
    local names = {}
    for name, s in pairs(window) do
        if s.count > 0 then names[#names + 1] = name end
    end
    table.sort(names)
    return names
end

function Profile.format_perf(window_s)
    local names = sorted_names()
    if #names == 0 then return nil end
    local parts = {
        string.format("[perf] window=%.1fs", tonumber(window_s) or 10.0),
    }
    for i = 1, #names do
        local name = names[i]
        local s = window[name]
        parts[#parts + 1] = string.format(
            "%s n=%d avg=%.2f max=%.2f", name, s.count, s.total_ms / s.count, s.max_ms)
    end
    return table.concat(parts, " | ")
end

local function lua_kb()
    local ok, kb = pcall(collectgarbage, "count")
    if ok and type(kb) == "number" and kb > 0 then return kb end
    return prev_mem and prev_mem.lua_kb or 0
end

local function delta_str(key, cur, prev)
    local d = cur - (prev and prev[key] or cur)
    return string.format("%+g", d)
end

function Profile.format_mem()
    local ctx = {}
    if context_fn then
        local ok, got = pcall(context_fn)
        if ok and type(got) == "table" then ctx = got end
    end
    local snap = {
        lua_kb = lua_kb(),
        cache = tonumber(ctx.cache) or 0,
        verdicts = tonumber(ctx.verdicts) or 0,
        pending = tonumber(ctx.pending) or 0,
        rows = tonumber(ctx.rows) or 0,
        tex = tonumber(ctx.tex) or 0,
        missing = tonumber(ctx.missing) or 0,
        wanted = tonumber(ctx.wanted) or 0,
        failed = tonumber(ctx.failed) or 0,
        colors = tonumber(ctx.colors) or 0,
        mats = tonumber(ctx.mats) or 0,
        hook = tonumber(ctx.hook) or 0,
    }
    local line = string.format(
        "[mem] lua_kb=%.1f d_lua_kb=%s | cache=%d d_cache=%s verdicts=%d pending=%d rows=%d | tex=%d missing=%d wanted=%d failed=%d colors=%d mats=%d | hook=%d",
        snap.lua_kb, delta_str("lua_kb", snap.lua_kb, prev_mem),
        snap.cache, delta_str("cache", snap.cache, prev_mem),
        snap.verdicts, snap.pending, snap.rows,
        snap.tex, snap.missing, snap.wanted, snap.failed, snap.colors, snap.mats,
        snap.hook)
    -- Stash for dump_window to commit as baseline after logging.
    Profile._last_mem_snap = snap
    return line
end

function Profile.dump_window(window_s)
    local perf = Profile.format_perf(window_s)
    if perf then logger()(perf) end
    local mem = Profile.format_mem()
    logger()(mem)
    if Profile._last_mem_snap then
        prev_mem = Profile._last_mem_snap
        Profile._last_mem_snap = nil
    end
    Profile.reset_window()
end

function Profile.start_dump_loop(delay_ms, schedule)
    if not Util.PROFILE then return end
    dump_gen = dump_gen + 1
    local gen = dump_gen
    local delay = delay_ms or 10000
    local sched = schedule or ExecuteWithDelay
    local function tick()
        if gen ~= dump_gen or not Util.PROFILE then return end
        Profile.dump_window(delay / 1000)
        pcall(sched, delay, tick)
    end
    pcall(sched, delay, tick)
end

-- Exported for tests / rare callers; not required by production.
Profile._pair_count = pair_count

return Profile
