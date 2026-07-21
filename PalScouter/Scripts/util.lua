-- PalScouter util.lua — hardened helpers
local Util = {}

Util.DEBUG = false
Util.PROFILE = false

function Util.log(msg)
    print("[PalScouter] " .. tostring(msg) .. "\n")
end

function Util.dbg(msg)
    if Util.DEBUG then Util.log("[dbg] " .. tostring(msg)) end
end

local function call_is_valid(obj) return obj:IsValid() end
local function call_full_name(obj) return obj:GetFullName() end
local function call_address(obj) return obj:GetAddress() end

function Util.valid(obj)
    if obj == nil then return false end
    local ok, result = pcall(call_is_valid, obj)
    return ok and result == true
end

-- Calls fn(...) in pcall; returns default on error.
function Util.safe_call(default, fn, ...)
    local ok, result = pcall(fn, ...)
    if ok then return result end
    return default
end

-- Unwrap TWeakObjectPtr / remote-object wrappers to a plain UObject.
function Util.unwrap(value)
    if value == nil then return nil end
    for _, method in ipairs({ "get", "Get", "LoadSynchronous" }) do
        local ok, inner = pcall(function() return value[method](value) end)
        if ok and inner ~= nil then return inner end
    end
    return value
end

function Util.stringify_name(name)
    if name == nil then return "" end
    name = Util.unwrap(name)
    if type(name) == "string" then return name end
    local ok, s = pcall(function() return name:ToString() end)
    if ok and s ~= nil then return tostring(s) end
    ok, s = pcall(function() return name:GetName() end)
    if ok and s ~= nil then return tostring(s) end
    return tostring(name)
end

function Util.display_text(value)
    local text = Util.stringify_name(value):match("^%s*(.-)%s*$")
    if text == "" or text == "None" or text == "Unknown" or text == "true" or text == "false"
        or text:find("RemoteUnrealParam", 1, true) then return nil end
    return text
end

-- Game localization APIs sometimes echo an internal key with different casing.
function Util.is_localization_key(value, expected)
    local text = tostring(value or ""):lower()
    return (expected ~= nil and text == tostring(expected):lower())
        or text:match("^pal_name_") ~= nil
        or text:match("^action_skill_") ~= nil
        or text:match("^passive_skill_") ~= nil
end

-- Palworld FixedPoint64 -> plain number (raw value is x1000).
function Util.fixed_point_to_number(fp)
    if fp == nil then return nil end
    if type(fp) == "number" then return fp end
    local ok, v = pcall(function() return fp.Value end)
    if not ok or v == nil then return nil end
    local n = tonumber(v) or tonumber(tostring(v))
    if n then return n / 1000 end
    return nil
end

function Util.round(n)
    return math.floor(n + 0.5)
end

function Util.clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

function Util.trim(s)
    return tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

function Util.lower_trim(s)
    return Util.trim(s):lower()
end

function Util.full_name(obj)
    local ok, result = pcall(call_full_name, obj)
    if ok then return result end
    return nil
end

function Util.same_object(a, b)
    if a == nil or b == nil then return false end
    if a == b then return true end
    local ak, bk = Util.full_name(a), Util.full_name(b)
    return ak ~= nil and ak == bk
end

-- Used only by the optional in-base fallback; never performs a global actor list.
function Util.find_first_valid(class_names)
    if type(class_names) ~= "table" then return nil end
    for i = 1, #class_names do
        local obj = Util.safe_call(nil, function() return FindFirstOf(class_names[i]) end)
        if obj ~= nil and Util.valid(obj) then return obj end
    end
    return nil
end

-- Stable for an actor lifetime and much cheaper than GetFullName for registry keys.
function Util.address(obj)
    local ok, result = pcall(call_address, obj)
    if ok and result ~= nil then return tonumber(result) or tostring(result) end
    return nil
end

function Util.truncate(text, max_chars)
    text = tostring(text or "")
    local length = utf8 and utf8.len(text)
    if length and length > max_chars then
        local end_byte = utf8.offset(text, max_chars + 1)
        return text:sub(1, end_byte - 1) .. "..."
    end
    if not length and #text > max_chars then return text:sub(1, max_chars) .. "..." end
    return text
end

-- Hold state[flag] while scheduling `work` onto the game thread.
-- Clears the flag if the scheduler itself fails (otherwise the queue sticks forever).
-- `schedule` is injectable for tests; defaults to global ExecuteInGameThread.
function Util.run_queued_game_thread(state, flag, work, warn_label, schedule)
    state[flag] = true
    local sched = schedule or ExecuteInGameThread
    local ok = pcall(sched, function()
        local wok, err = pcall(work)
        if not wok then
            Util.log((warn_label or "game thread") .. " error: " .. tostring(err))
        end
        state[flag] = false
    end)
    if not ok then
        state[flag] = false
        Util.log("WARNING: " .. (warn_label or "ExecuteInGameThread") .. " failed")
    end
    return ok
end

return Util
