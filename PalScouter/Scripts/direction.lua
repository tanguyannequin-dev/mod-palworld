-- PalScouter direction.lua — world-compass bearing + elevation for nearby DIST.
-- Pure Lua; N = +X, E = +Y (matches Palworld map-up / HUD compass).
local Direction = {}

local ELEV_UU = 500   -- 5 m
local NEAR_UU = 100   -- 1 m horizontal → "•"
local LABELS = { "N", "NE", "E", "SE", "S", "SW", "W", "NW" }

-- Lua 5.4: math.atan(y, x); Lua 5.1: math.atan2(y, x)
local function atan2(y, x)
    if math.atan2 then return math.atan2(y, x) end
    return math.atan(y, x)
end

function Direction.bearing_label(dx, dy)
    dx = tonumber(dx) or 0
    dy = tonumber(dy) or 0
    local h = math.sqrt(dx * dx + dy * dy)
    if h < NEAR_UU then return "•" end
    local deg = math.deg(atan2(dy, dx))
    if deg < 0 then deg = deg + 360 end
    local idx = math.floor((deg + 22.5) / 45) % 8 + 1
    return LABELS[idx]
end

function Direction.elev_arrow(dz)
    dz = tonumber(dz) or 0
    if dz >= ELEV_UU then return "↑" end
    if dz <= -ELEV_UU then return "↓" end
    return ""
end

function Direction.format_dist_disp(dx, dy, dz)
    dx = tonumber(dx) or 0
    dy = tonumber(dy) or 0
    dz = tonumber(dz) or 0
    local dist_m = math.floor(math.sqrt(dx * dx + dy * dy + dz * dz) / 100 + 0.5)
    return string.format("%s%s %d", Direction.bearing_label(dx, dy), Direction.elev_arrow(dz), dist_m)
end

return Direction
