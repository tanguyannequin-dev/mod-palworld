-- PalScouter scanner.lua — native broadphase/snapshot consumer.
-- UObject discovery, distance checks and static Pal reads live in
-- PalScouterNative. Lua keeps only UI state, scoring and bounded enrichment.
local Util = require("util")
local G = require("gamedata")
local Score = require("score")
local Direction = require("direction")
local UEHelpers = require("UEHelpers")
local Profile = require("profile")
local L = require("localization")

local Scanner = {
    aim = {
        data = nil, key = nil, last_dynamic = 0, last_combat = 0,
        cone_ok = nil, cone_check_t = nil,
    },
    nearby = {
        active = false,
        cache = {},
        staged = {}, stage_queue = {}, stage_head = 1, stage_tail = 0, stage_count = 0,
        candidates = {},
        generation = 0,
        native_more = false,
        work_queue = {}, work_head = 1, work_tail = 0, work_keys = {},
    },
    sort_mode = "score",
    page = 1,
    pages = 1,
    visible_rows = {},
    filtered_count = 0,
    wild_count = 0,
    staging_count = 0,
    header = "",
    empty_reason = nil,
    native_error = nil,
    in_base = false,
    _base = { last_probe = nil, needs_probe = true },
    last_world_address = nil,
}

local AIM_DOT_ACQUIRE = 0.92
local AIM_DOT_HOLD = 0.85
local AIM_CONE_RANGE_METERS = 200
local DYNAMIC_REFRESH_SECONDS = 1.5
local COMBAT_REFRESH_SECONDS = 10.0
local CONE_RECHECK_SECONDS = 1.5
local AIM_IDLE_INTERVAL_MS = 2000
local AIM_LOCKED_INTERVAL_MS = 1500
local NEARBY_BATCH_BUDGET = 32
local WORK_REFINES_PER_TICK = 2
local HYDRATE_ROWS_PER_TICK = 2

local player_cache = { controller = nil }

local function get_controller()
    return Profile.span("player.controller", function()
        local cached = player_cache.controller
        if cached ~= nil and Util.valid(cached) then return cached end
        local ok, pc = pcall(function() return UEHelpers.GetPlayerController() end)
        if ok and pc ~= nil and Util.valid(pc) then
            player_cache.controller = pc
            return pc
        end
        player_cache.controller = nil
        return nil
    end)
end

local pawn_nil_since = nil

local function get_pawn(controller)
    return Profile.span("player.pawn", function()
        local pawn = Util.safe_call(nil, function() return controller.Pawn end)
        if pawn ~= nil and Util.valid(pawn) then
            pawn_nil_since = nil
            return pawn
        end
        local now = os.clock()
        if pawn_nil_since == nil then
            pawn_nil_since = now
        elseif now - pawn_nil_since > 2.0 then
            Scanner.reset_player_cache()
            pawn_nil_since = now -- Wait another 2s before searching again to avoid 0xA crashes
        end
        return nil
    end)
end

local function get_player_pawn(controller)
    return get_pawn(controller)
end

function Scanner.reset_player_cache()
    player_cache.controller = nil
end

function Scanner.player_controller()
    return get_controller()
end

function Scanner.is_pal_character(actor)
    if actor == nil or not Util.valid(actor) then return false end
    local full_name = Util.full_name(actor)
    if full_name == nil then return true end
    local lower = full_name:lower()
    if lower:find("dropitem", 1, true) or lower:find("worldobject", 1, true) then return false end
    return true
end

-- Verify an actor's internal state is still intact before sending it to C++.
-- During capture/despawn, the UObject stays "valid" in UE4SS's registry for
-- a few frames while its internal component pointers are already nullified.
-- Calling native C++ on such a zombie actor corrupts UE4SS's game-thread
-- dispatcher, permanently freezing both the aim card and the nearby scanner.
local function actor_alive(actor)
    if actor == nil or not Util.valid(actor) then return false end
    -- Check if critical components are still attached. During destruction (e.g.,
    -- condensing a Pal or moving to Palbox), these are nulled before the actor dies.
    local mesh = Util.safe_call(nil, function() return actor.Mesh end)
    if mesh == nil or not Util.valid(mesh) then return false end

    local movement = Util.safe_call(nil, function() return actor.CharacterMovement end)
    if movement == nil or not Util.valid(movement) then return false end

    local comp = Util.safe_call(nil, function() return actor:GetCharacterParameterComponent() end)
    if comp ~= nil and Util.valid(comp) then return true end
    comp = Util.safe_call(nil, function() return actor.CharacterParameterComponent end)
    return comp ~= nil and Util.valid(comp)
end

function Scanner.scout_allowed(verdict, cfg, local_owned)
    if verdict == nil or verdict == "notpal" then return false end
    local ownership = (cfg and cfg.Filter and cfg.Filter.Ownership) or "wild"
    if ownership == "all" then
        if verdict == "wild" or verdict == "unknown" then return true end
        if verdict == "owned" then return local_owned ~= true end
        return false
    end
    if verdict == "wild" then return true end
    return verdict == "unknown" and cfg.Filter and cfg.Filter.ShowUnknownOwnership == true
end

local function finish_scores(entry, cfg)
    local work_mode = cfg.Score and cfg.Score.Mode == "work"
    -- Native CraftSpeeds supplies the wild-Pal list value on its first frame.
    -- Never turn an otherwise valid work score into "?" on the compatibility
    -- fallback while its bounded UObject read is pending.
    entry.score = Score.compute(entry, cfg)
    entry.score_pending = work_mode and entry.works_exact ~= true
    entry.grade = Score.grade(entry.score, cfg)
    local bp = Score.best_passive(entry.passives)
    entry.best_passive = bp and (bp.name or bp.raw or "?") or ""
    entry.best_passive_rank = bp and bp.rank or nil
end

local function fallback_species(id)
    local value = tostring(id or "?"):gsub("^BOSS_", ""):gsub("^GYM_", "")
    return value:gsub("_", " ")
end

local function queue_work(key)
    local n = Scanner.nearby
    if key == nil or n.work_keys[key] then return end
    n.work_tail = n.work_tail + 1
    n.work_queue[n.work_tail] = key
    n.work_keys[key] = true
end

local function passives_from_native(ids)
    local result = {}
    for i = 1, math.min(#(ids or {}), 4) do
        local raw = tostring(ids[i] or "")
        if raw ~= "" and raw ~= "None" then
            local name = G.passive_name_cache and G.passive_name_cache[raw]
            result[#result + 1] = {
                raw = raw,
                name = name or raw,
                name_resolved = name ~= nil,
                -- Rank is available synchronously from passive_ranks.lua. Keeping
                -- this on the first frame preserves the original rank colours.
                rank = G.passive_rank_for(raw),
            }
        end
    end
    return Score.sort_passives(result)
end

local function ivs_from_native(row)
    local hp, atk, def = tonumber(row.iv_hp), tonumber(row.iv_atk), tonumber(row.iv_def)
    if hp == nil or atk == nil or def == nil or hp < 0 or atk < 0 or def < 0 then return nil end
    return { hp = hp, atk = atk, def = def }
end

local function works_from_native(row)
    if row.work_levels_available ~= true then return nil, false end
    local ids, ranks = row.work_ids or {}, row.work_ranks or {}
    local result = {}
    for i = 1, math.min(#ids, #ranks) do
        local id, rank = tonumber(ids[i]), tonumber(ranks[i])
        if id ~= nil and id >= 1 and id <= 13 and rank ~= nil and rank > 0 then
            result[#result + 1] = { id = id, rank = rank }
        end
    end
    return result, true
end

local function make_entry(row, cfg)
    if not Util.valid(row.actor) then return nil end
    local id = tostring(row.character_id or "")
    if id == "" or id == "None" then return nil end
    local name = G.species_name_cache and G.species_name_cache[id]
    local works, works_loaded = works_from_native(row)
    local entry = {
        actor = row.actor,
        key = tostring(row.key or id),
        character_id = id,
        name = name or fallback_species(id),
        name_resolved = name ~= nil,
        level = tonumber(row.level),
        gender = tonumber(row.gender),
        is_alpha = row.is_alpha == true,
        ivs = ivs_from_native(row),
        passives = passives_from_native(row.passive_ids),
        works = works,
        works_loaded = works_loaded,
        works_exact = works_loaded,
        wild = tostring(row.ownership or "unknown"),
    }
    finish_scores(entry, cfg)
    return entry
end

local function update_pose(entry, row, generation)
    entry.actor = row.actor
    entry.distance = tonumber(row.distance) or math.huge
    entry.dx, entry.dy, entry.dz = tonumber(row.dx), tonumber(row.dy), tonumber(row.dz)
    entry.x, entry.y, entry.z = tonumber(row.x), tonumber(row.y), tonumber(row.z)
    entry.wild = tostring(row.ownership or entry.wild or "unknown")
    entry.last_seen = generation
end

local function update_static(entry, row, cfg)
    entry.level = tonumber(row.level) or entry.level
    entry.gender = tonumber(row.gender) or entry.gender
    entry.is_alpha = row.is_alpha == true
    entry.ivs = ivs_from_native(row)
    entry.passives = passives_from_native(row.passive_ids)
    if entry.works_exact ~= true then
        local works, works_loaded = works_from_native(row)
        if works_loaded then
            entry.works, entry.works_loaded = works, true
            entry.works_exact = true
        end
    end
    finish_scores(entry, cfg)
end

local function stage_entry(entry)
    local n = Scanner.nearby
    if entry == nil or entry.key == nil or n.staged[entry.key] ~= nil then return false end
    n.staged[entry.key] = entry
    n.stage_tail = n.stage_tail + 1
    n.stage_queue[n.stage_tail] = entry.key
    n.stage_count = n.stage_count + 1
    return true
end

-- Original PalScouter semantics: finish every localized string belonging to
-- one Pal before the entry becomes displayable. Repeated species/passives are
-- cheap after their first hit because gamedata caches the localized result.
local function localize_entry(controller, entry, cfg)
    if not (entry and Util.valid(entry.actor)) then return false end
    if entry.name_resolved ~= true then
        local resolved = G.localize_species(controller, entry.character_id, nil)
        if resolved ~= nil then entry.name = resolved end
        entry.name_resolved = resolved ~= nil
    end
    for i = 1, #(entry.passives or {}) do
        local passive = entry.passives[i]
        if passive.name_resolved ~= true then
            passive.name = G.localize_passive(controller, passive.raw) or passive.raw
            passive.name_resolved = true
        end
    end
    if entry.wild == "owned" and entry.local_owned == nil then
        local parameter, component = G.get_parameter(entry.actor)
        entry.local_owned = parameter ~= nil
            and G.is_locally_owned(entry.actor, parameter, component, controller) == true
            or false
    end
    if entry.passives then Score.sort_passives(entry.passives) end
    finish_scores(entry, cfg)
    return true
end

local function publish_staged(key, entry, cfg)
    local n = Scanner.nearby
    if key == nil or entry == nil or n.staged[key] ~= entry then return false end
    n.staged[key] = nil
    n.stage_count = math.max(0, n.stage_count - 1)
    n.cache[key] = entry
    if cfg.Score and cfg.Score.Mode == "work" and entry.works_exact ~= true then
        queue_work(key)
    end
    return true
end

local function hydrate_one(controller, cfg)
    local n = Scanner.nearby
    while n.stage_head <= n.stage_tail do
        local key = n.stage_queue[n.stage_head]
        n.stage_queue[n.stage_head] = nil
        n.stage_head = n.stage_head + 1
        local entry = key and n.staged[key]
        if entry ~= nil then
            localize_entry(controller, entry, cfg)
            publish_staged(key, entry, cfg)
            return true
        end
    end
    return false
end

local function log_native_error(message)
    message = tostring(message or "unknown native bridge error")
    if Scanner.native_error ~= message then
        Scanner.native_error = message
        Util.log("ERROR: PalScouterNative unavailable: " .. message)
    end
end

local function native_poll(controller, pawn, radius_meters, cfg, batch_restart)
    local poll_fn = PalScouterNativePoll
    if batch_restart ~= nil then poll_fn = PalScouterNativePollBatch end
    if type(poll_fn) ~= "function" then
        if batch_restart ~= nil then Scanner.nearby.native_more = false end
        log_native_error(batch_restart ~= nil
            and "PalScouterNativePollBatch was not registered"
            or "PalScouterNativePoll was not registered")
        return false
    end
    local ok, rows
    if batch_restart ~= nil then
        ok, rows = Profile.span("bridge.poll.batch", pcall,
            poll_fn, pawn, radius_meters, batch_restart, NEARBY_BATCH_BUDGET)
    else
        ok, rows = Profile.span("bridge.poll.full", pcall, poll_fn, pawn, radius_meters)
    end
    if not ok or type(rows) ~= "table" then
        if batch_restart ~= nil then Scanner.nearby.native_more = false end
        log_native_error(ok and "native poll returned no table" or rows)
        return false
    end
    if rows.native_error ~= nil then
        if batch_restart ~= nil then Scanner.nearby.native_more = false end
        log_native_error(rows.native_error)
        return false
    end
    Scanner.native_error = nil

    local n = Scanner.nearby
    if batch_restart == nil or batch_restart == true then
        n.generation = n.generation + 1
    end
    local generation = n.generation
    local candidates = (batch_restart == false) and n.candidates or {}
    for i = 1, #rows do
        local row = rows[i]
        if type(row) == "table" then
            local verdict = tostring(row.ownership or "unknown")
            if Scanner.scout_allowed(verdict, cfg, false) then
                local key = tostring(row.key or "")
                if key ~= "" and Util.valid(row.actor) then
                    local published = n.cache[key] ~= nil
                    local entry = n.cache[key] or n.staged[key]
                    local created = false
                    if entry == nil then
                        entry = make_entry(row, cfg)
                        if entry ~= nil then
                            stage_entry(entry)
                            created = true
                        end
                    end
                    if entry ~= nil then
                        if not created and row.static_refreshed == true then
                            update_static(entry, row, cfg)
                        end
                        update_pose(entry, row, generation)
                        candidates[#candidates + 1] = entry
                        if published and cfg.Score and cfg.Score.Mode == "work"
                            and entry.works_exact ~= true then
                            queue_work(key)
                        end
                    end
                end
            end
        end
    end
    n.candidates = candidates
    if batch_restart ~= nil then n.native_more = rows.native_more == true end

    local evict_after = cfg.Scan.EvictAfterMisses or 2
    for key, entry in pairs(n.cache) do
        if generation - (entry.last_seen or 0) > evict_after then
            n.cache[key] = nil
            n.work_keys[key] = nil
        end
    end
    for key, entry in pairs(n.staged) do
        if generation - (entry.last_seen or 0) > evict_after then
            n.staged[key] = nil
            n.stage_count = math.max(0, n.stage_count - 1)
        end
    end
    return true
end

local function native_track(pawn, actor, radius_meters, cfg)
    if type(PalScouterNativeTrack) ~= "function" then return nil end
    if pawn == nil or not Util.valid(pawn) then return nil end
    if actor == nil or not actor_alive(actor) or not Scanner.is_pal_character(actor) then return nil end
    local ok, row = Profile.span("bridge.track", pcall,
        PalScouterNativeTrack, pawn, actor, radius_meters)
    if not ok or type(row) ~= "table" or row.native_error ~= nil then return nil end
    if not Util.valid(row.actor) then return nil end
    local key = tostring(row.key or "")
    if key == "" then return nil end
    local verdict = tostring(row.ownership or "unknown")
    if not Scanner.scout_allowed(verdict, cfg, false) then return nil end
    local n = Scanner.nearby
    local entry = n.cache[key] or n.staged[key]
    local created = false
    if entry == nil then
        entry = make_entry(row, cfg)
        if entry == nil then return nil end
        stage_entry(entry)
        created = true
    end
    if not created and row.static_refreshed == true then update_static(entry, row, cfg) end
    update_pose(entry, row, math.max(1, n.generation))
    return entry
end

local function native_pose(entry)
    if entry == nil or entry.actor == nil or type(PalScouterNativePose) ~= "function" then return false end
    if not actor_alive(entry.actor) or not Scanner.is_pal_character(entry.actor) then return false end
    local ok, row = Profile.span("bridge.pose", pcall, PalScouterNativePose, entry.actor)
    if not ok or type(row) ~= "table" then return false end
    local x, y, z = tonumber(row.x), tonumber(row.y), tonumber(row.z)
    if x == nil or y == nil or z == nil then return false end
    entry.x, entry.y, entry.z = x, y, z
    local hp = tonumber(row.hp)
    -- SaveParameter.MaxHP is either zero or the unbuffed base stat on wild Pals.
    -- entry.max_hp comes from GetMaxHP_withBuff(); never mix the raw maximum into
    -- that pair. The raw current HP is safe to refresh against the cached maximum.
    if hp ~= nil and hp >= 0 and (entry.max_hp or 0) > 0 then
        entry.hp = hp
    end
    return true
end

local function read_one_work(cfg)
    local n = Scanner.nearby
    if n.work_head > n.work_tail then return false end
    local key = n.work_queue[n.work_head]
    n.work_queue[n.work_head] = nil
    n.work_head = n.work_head + 1
    n.work_keys[key] = nil
    local entry = key and n.cache[key]
    if entry == nil or entry.actor == nil or not Util.valid(entry.actor) then return true end
    local parameter = G.get_parameter(entry.actor)
    if parameter ~= nil then
        entry.works = G.read_work_levels(parameter)
        entry.works_loaded = true
        entry.works_exact = true
        finish_scores(entry, cfg)
    end
    return true
end

local function refine_one(controller, cfg)
    if hydrate_one(controller, cfg) then return true end
    if cfg.Score and cfg.Score.Mode == "work" and read_one_work(cfg) then return true end
    return false
end

local function refine_nearby(controller, cfg)
    -- Publish a small number of fully localized rows atomically. A row is never
    -- inserted into the display cache with raw English/internal identifiers.
    local changed = false
    for _ = 1, HYDRATE_ROWS_PER_TICK do
        if not hydrate_one(controller, cfg) then break end
        changed = true
    end
    if changed then return true end

    -- Native data normally leaves this queue empty. On a reflected-layout
    -- compatibility fallback, refine only two Pals per 200 ms continuation.
    if cfg.Score and cfg.Score.Mode == "work" then
        local changed = false
        for _ = 1, WORK_REFINES_PER_TICK do
            if not read_one_work(cfg) then break end
            changed = true
        end
        if changed then return true end
    end
    return false
end

function Scanner.native_status()
    if type(PalScouterNativeStatus) ~= "function" then
        return false, "PalScouterNativeStatus was not registered"
    end
    local ok, status = pcall(PalScouterNativeStatus)
    if not ok or type(status) ~= "table" then return false, tostring(status) end
    return status.ready == true, tostring(status.error or ""), tostring(status.version or "")
end

-- Compatibility no-ops: lifecycle discovery was deliberately removed.
function Scanner.observe_actor(_) return false end
function Scanner.forget_actor(_) return false end

-- ------------------------------------------------------------ aim card

local function is_player_aiming(pawn)
    local shooter = Util.safe_call(nil, function() return pawn.ShooterComponent end)
    if shooter == nil or not Util.valid(shooter) then
        local controller = get_controller()
        local player = G.local_player_character(controller)
        if player ~= nil and player ~= pawn then
            shooter = Util.safe_call(nil, function() return player.ShooterComponent end)
        end
    end
    if shooter == nil or not Util.valid(shooter) then return false end
    local aiming = Util.safe_call(nil, function() return shooter:IsAiming() end)
    if not aiming then aiming = Util.safe_call(false, function() return shooter:IsRequestAiming() end) end
    return aiming == true
end

function Scanner.sphere_class_allows_card(full_name)
    if full_name == nil then return true end
    local class_token = tostring(full_name):match("^(%S+)") or ""
    local lower = class_token:lower()
    return lower:find("sphere", 1, true) ~= nil or lower:find("ball", 1, true) ~= nil
end

local function is_sphere_equipped(pawn)
    local shooter = Util.safe_call(nil, function() return pawn.ShooterComponent end)
    if shooter == nil or not Util.valid(shooter) then
        local controller = get_controller()
        local player = G.local_player_character(controller)
        if player ~= nil and player ~= pawn then
            shooter = Util.safe_call(nil, function() return player.ShooterComponent end)
        end
    end
    if shooter == nil or not Util.valid(shooter) then return true end
    local weapon = Util.unwrap(Util.safe_call(nil, function() return shooter:GetHasWeapon() end))
    if weapon == nil or not Util.valid(weapon) then
        weapon = Util.unwrap(Util.safe_call(nil, function() return shooter.HasWeapon end))
    end
    if weapon == nil or not Util.valid(weapon) then return true end
    return Scanner.sphere_class_allows_card(Util.full_name(weapon))
end

local function get_reticle_target(controller, pawn)
    local shooter = Util.safe_call(nil, function() return pawn.ShooterComponent end)
    if shooter == nil or not Util.valid(shooter) then
        local player = G.local_player_character(controller)
        if player ~= nil and player ~= pawn then
            shooter = Util.safe_call(nil, function() return player.ShooterComponent end)
        end
    end
    if shooter ~= nil and Util.valid(shooter) then
        local target = Util.unwrap(Util.safe_call(nil, function() return shooter.ReticleTargetActor end))
        if target == nil or not Util.valid(target) then
            target = Util.unwrap(Util.safe_call(nil, function() return shooter:GetReticleTargetActor() end))
        end
        if target ~= nil and Util.valid(target) and Scanner.is_pal_character(target) then return target end
    end
    local target = Util.unwrap(Util.safe_call(nil, function() return controller.AutoAimTarget end))
    if target ~= nil and Util.valid(target) and Scanner.is_pal_character(target) then return target end
    return nil
end

function Scanner.aim_cone_dot(dx, dy, dz, fx, fy, fz)
    local len = math.sqrt(dx * dx + dy * dy + dz * dz)
    if len < 1 then return -1 end
    return (dx * fx + dy * fy + dz * fz) / len
end

local function camera_basis(controller)
    local cam = Util.safe_call(nil, function() return controller.PlayerCameraManager end)
    if cam == nil or not Util.valid(cam) then return nil end
    local loc = Util.safe_call(nil, function() return cam:GetCameraLocation() end)
    local rot = Util.safe_call(nil, function() return cam:GetCameraRotation() end)
    if loc == nil or rot == nil then return nil end
    local cx, cy, cz = tonumber(loc.X), tonumber(loc.Y), tonumber(loc.Z)
    local pitch, yaw = math.rad(tonumber(rot.Pitch) or 0), math.rad(tonumber(rot.Yaw) or 0)
    if cx == nil or cy == nil or cz == nil then return nil end
    return cx, cy, cz,
        math.cos(pitch) * math.cos(yaw),
        math.cos(pitch) * math.sin(yaw),
        math.sin(pitch)
end

local function entry_location(entry)
    if entry == nil then return nil end
    local x, y, z = tonumber(entry.x), tonumber(entry.y), tonumber(entry.z)
    if x ~= nil and y ~= nil and z ~= nil then return x, y, z end
    local actor = entry.actor
    if actor == nil or not Util.valid(actor) then return nil end
    local loc = Util.safe_call(nil, function() return actor:K2_GetActorLocation() end)
    if loc == nil then return nil end
    return tonumber(loc.X), tonumber(loc.Y), tonumber(loc.Z)
end

local function find_cone_entry(controller, cfg)
    local candidates = Scanner.nearby.candidates
    local cx, cy, cz, fx, fy, fz = camera_basis(controller)
    if cx == nil then return nil end
    local best, best_dot = nil, AIM_DOT_ACQUIRE - 1e-6
    local max_uu = AIM_CONE_RANGE_METERS * 100
    local max_sq = max_uu * max_uu
    for i = 1, #candidates do
        local entry = candidates[i]
        if Scanner.scout_allowed(entry.wild, cfg, entry.local_owned) then
            local ax, ay, az = entry_location(entry)
            if ax ~= nil then
                local dx, dy, dz = ax - cx, ay - cy, az - cz
                local dist_sq = dx * dx + dy * dy + dz * dz
                if dist_sq <= max_sq then
                    local dot = Scanner.aim_cone_dot(dx, dy, dz, fx, fy, fz)
                    if dot >= AIM_DOT_ACQUIRE and dot > best_dot then
                        entry.x, entry.y, entry.z = ax, ay, az
                        best, best_dot = entry, dot
                    end
                end
            end
        end
    end
    return best
end

local function inside_aim_cone(controller, entry)
    local cx, cy, cz, fx, fy, fz = camera_basis(controller)
    if cx == nil then return true end
    local ax, ay, az = entry_location(entry)
    if ax == nil then return true end
    return Scanner.aim_cone_dot(ax - cx, ay - cy, az - cz, fx, fy, fz) >= AIM_DOT_HOLD
end

local function enrich_card(controller, entry, cfg)
    if entry == nil or entry.actor == nil or not Util.valid(entry.actor) then return false end
    local parameter, component = G.get_parameter(entry.actor)
    if parameter == nil then return false end
    entry.hp, entry.max_hp = G.read_hp(parameter)
    entry.atk, entry.def, entry.craft = G.read_combat_stats(parameter)
    entry.elements, entry.element_ids = G.read_elements(component)
    entry.works = G.read_work_levels(parameter)
    entry.works_loaded = true
    entry.works_exact = true
    -- The direct parameter path is the one used by the original Lua mod and
    -- returns real passive FNames.  Prefer it for the one-time aim-card build;
    -- retain native IDs only when the direct list is temporarily unavailable.
    local direct_passives = G.read_passives(controller, parameter)
    if #direct_passives > 0 or #(entry.passives or {}) == 0 then
        entry.passives = Score.sort_passives(direct_passives)
    end
    entry.active_skills = G.read_active_skills(controller, parameter)
    entry.anchor = Util.safe_call(120, function()
        local caps = Util.unwrap(Util.safe_call(nil, function() return entry.actor.CapsuleComponent end))
        if caps ~= nil and Util.valid(caps) then
            local h = Util.safe_call(nil, function() return caps:GetScaledCapsuleHalfHeight() end)
            if h ~= nil then return tonumber(h) + 12 end
        end
        return 120
    end)
    finish_scores(entry, cfg)
    return true
end

local function refresh_card_combat(entry)
    if entry == nil or entry.actor == nil or not Util.valid(entry.actor) then return false end
    local parameter = G.get_parameter(entry.actor)
    if parameter == nil then return false end
    local hp, max_hp = G.read_hp(parameter)
    if hp ~= nil and max_hp ~= nil and max_hp > 0 then
        entry.hp, entry.max_hp = hp, max_hp
    end
    entry.atk, entry.def, entry.craft = G.read_combat_stats(parameter)
    return true
end

function Scanner.clear_aim()
    Scanner.aim.data = nil
    Scanner.aim.key = nil
    Scanner.aim.last_dynamic = 0
    Scanner.aim.last_combat = 0
    Scanner.aim.cone_ok = nil
    Scanner.aim.cone_check_t = nil
end

function Scanner.aim_interval_ms(cfg)
    -- A shown card only needs the cheap locked-refresh cadence; the configurable
    -- idle delay governs how long aiming at a Pal takes to surface the card.
    if Scanner.aim.data ~= nil then return AIM_LOCKED_INTERVAL_MS end
    local ms = cfg and cfg.AimCard and tonumber(cfg.AimCard.AcquireMs)
    return ms or AIM_IDLE_INTERVAL_MS
end

function Scanner.scan_aim(cfg)
    return Profile.span("scan.aim.native", function()
        local controller = get_controller()
        if controller == nil then Scanner.clear_aim() return end
        local world = Util.safe_call(nil, function() return controller:GetWorld() end)
        local world_addr = Util.address(world)
        if world_addr ~= nil then
            if Scanner.last_world_address ~= nil and Scanner.last_world_address ~= world_addr then
                Util.log("INFO: World changed from " .. tostring(Scanner.last_world_address) .. " to " .. tostring(world_addr) .. " - resetting native registry")
                Scanner.reset_nearby(true)
                Scanner.reset_player_cache()
                Scanner.clear_aim()
                Scanner.last_world_address = world_addr
                return
            end
            Scanner.last_world_address = world_addr
        end
        -- Skip aim scanning during teleportation cooldown
        if Scanner.teleport_cooldown ~= nil and os.clock() < Scanner.teleport_cooldown then
            Scanner.clear_aim()
            return
        end
        local pawn = get_player_pawn(controller)
        if pawn == nil or not actor_alive(pawn) or not is_player_aiming(pawn) then Scanner.clear_aim() return end
        if (cfg.AimCard.ShowMode or "always") == "sphere" and not is_sphere_equipped(pawn) then
            Scanner.clear_aim()
            return
        end

        local radius = math.max(AIM_CONE_RANGE_METERS, tonumber(cfg.Scan.RadiusMeters) or 100)
        local now = os.clock()

        -- Locked fast path: retain the actor directly.  Do not call NativeTrack,
        -- rebuild its static snapshot or allocate a full Lua row every locked tick.
        local locked = Scanner.aim.data
        if locked ~= nil and locked.actor ~= nil and actor_alive(locked.actor)
            and Scanner.scout_allowed(locked.wild, cfg, locked.local_owned) then
            
            -- Check if player is directly reticle-aiming at a DIFFERENT actor
            local reticle = get_reticle_target(controller, pawn)
            local reticle_switched = (reticle ~= nil and Util.valid(reticle) and Util.address(reticle) ~= Util.address(locked.actor))

            if not reticle_switched then
                local pose_ok = native_pose(locked)
                local need_cone = Scanner.aim.cone_check_t == nil
                    or now - Scanner.aim.cone_check_t >= CONE_RECHECK_SECONDS
                if need_cone then
                    Scanner.aim.cone_check_t = now
                    Scanner.aim.cone_ok = inside_aim_cone(controller, locked)
                end
                if Scanner.aim.cone_ok then
                    -- Check if another candidate is much closer to the center of reticle than locked
                    local best_cone = find_cone_entry(controller, cfg)
                    if best_cone ~= nil and best_cone.key ~= locked.key then
                        local ax, ay, az = entry_location(locked)
                        local bx, by, bz = entry_location(best_cone)
                        local cx, cy, cz, fx, fy, fz = camera_basis(controller)
                        if ax and bx and cx then
                            local dot_locked = Scanner.aim_cone_dot(ax - cx, ay - cy, az - cz, fx, fy, fz)
                            local dot_best = Scanner.aim_cone_dot(bx - cx, by - cy, bz - cz, fx, fy, fz)
                            if dot_best > dot_locked + 0.04 then
                                Scanner.clear_aim()
                            end
                        end
                    end

                    if Scanner.aim.data ~= nil then
                        if now - Scanner.aim.last_dynamic >= DYNAMIC_REFRESH_SECONDS then
                            local refresh_combat = now - Scanner.aim.last_combat >= COMBAT_REFRESH_SECONDS
                            if not pose_ok then
                                local parameter = G.get_parameter(locked.actor)
                                if parameter == nil then Scanner.clear_aim() return end
                                locked.hp, locked.max_hp = G.read_hp(parameter)
                            end
                            if refresh_combat and not refresh_card_combat(locked) then
                                Scanner.clear_aim()
                                return
                            end
                            Scanner.aim.last_dynamic = now
                            if refresh_combat then Scanner.aim.last_combat = now end
                        end
                        return
                    end
                end
            end
        end
        Scanner.clear_aim()

        local target
        local reticle = get_reticle_target(controller, pawn)
        local reticle_is_own_pal = false
        if reticle ~= nil then
            local direct = native_track(pawn, reticle, radius, cfg)
            if direct ~= nil then
                if Scanner.scout_allowed(direct.wild, cfg, direct.local_owned) then
                    target = direct
                else
                    reticle_is_own_pal = true
                end
            end
        end
        if target == nil and not reticle_is_own_pal then
            target = find_cone_entry(controller, cfg)
            if target == nil then
                if not native_poll(controller, pawn, radius, cfg) then return end
                target = find_cone_entry(controller, cfg)
            end
        end
        local refined = refine_one(controller, cfg)
        if refined and Scanner.nearby.active then Scanner.rebuild_view(cfg) end
        if target == nil then return end
        if Scanner.aim.key ~= target.key then
            -- A directly aimed staged Pal follows the same atomic publication
            -- rule as the nearby list before the card performs deeper reads.
            localize_entry(controller, target, cfg)
            publish_staged(target.key, target, cfg)
            if not Scanner.scout_allowed(target.wild, cfg, target.local_owned) then return end
            if not enrich_card(controller, target, cfg) then return end
            Scanner.aim.data, Scanner.aim.key = target, target.key
            Scanner.aim.last_dynamic = now
            Scanner.aim.last_combat = now
            Scanner.aim.cone_ok = true
            Scanner.aim.cone_check_t = now
        end
    end)
end

-- ------------------------------------------------------------ nearby list

function Scanner.reset_nearby(reset_native)
    local active = Scanner.nearby.active
    Scanner.nearby = {
        active = active,
        cache = {},
        staged = {}, stage_queue = {}, stage_head = 1, stage_tail = 0, stage_count = 0,
        candidates = {}, generation = 0,
        native_more = false,
        work_queue = {}, work_head = 1, work_tail = 0, work_keys = {},
    }
    Scanner.visible_rows, Scanner.header, Scanner.empty_reason = {}, "", nil
    Scanner.filtered_count, Scanner.wild_count, Scanner.staging_count = 0, 0, 0
    Scanner.page, Scanner.pages = 1, 1
    Scanner.in_base = false
    Scanner._base = { last_probe = nil, needs_probe = true }
    Scanner.last_scan_x, Scanner.last_scan_y, Scanner.last_scan_z = nil, nil, nil
    if reset_native and type(PalScouterNativeReset) == "function" then pcall(PalScouterNativeReset) end
end

function Scanner.invalidate_ownership_cache(cfg)
    local n = Scanner.nearby
    if ((cfg and cfg.Filter and cfg.Filter.Ownership) or "wild") ~= "all" then
        for key, entry in pairs(n.cache) do
            if entry.wild == "owned" then
                n.cache[key] = nil
                n.work_keys[key] = nil
            end
        end
        for key, entry in pairs(n.staged) do
            if entry.wild == "owned" then
                n.staged[key] = nil
                n.stage_count = math.max(0, n.stage_count - 1)
            end
        end
    end
end

local BASE_PROBE_INTERVAL_S = 2.0
function Scanner.refresh_base_presence(cfg)
    if not (cfg and cfg.Base and cfg.Base.HideUiInBase) then
        Scanner.in_base = false
        Scanner._base.needs_probe = true
        return false
    end
    local b, now = Scanner._base, os.clock()
    if b.needs_probe ~= true and b.last_probe ~= nil
        and now - b.last_probe < BASE_PROBE_INTERVAL_S then return Scanner.in_base end
    b.needs_probe, b.last_probe = false, now
    local controller = get_controller()
    if controller == nil then Scanner.in_base = false return false end
    local player = get_player_pawn(controller)
    local loc = player and Util.safe_call(nil, function() return player:K2_GetActorLocation() end)
    local x, y, z = loc and tonumber(loc.X), loc and tonumber(loc.Y), loc and tonumber(loc.Z)
    Scanner.in_base = G.player_inside_base_camp(controller, x, y, z) == true
    return Scanner.in_base
end

function Scanner.has_nearby_work()
    local n = Scanner.nearby
    return n.native_more == true
        or (n.stage_count or 0) > 0
        or ((n.work_head <= n.work_tail) and true or false)
end

function Scanner.scan_nearby(cfg, start_cycle)
    return Profile.span("scan.nearby.native", function()
        local n = Scanner.nearby
        if not n.active then return end
        local now = os.clock()
        if Scanner.teleport_cooldown ~= nil and now < Scanner.teleport_cooldown then
            return
        end

        local controller = get_controller()
        if controller == nil then return end

        local world = Util.safe_call(nil, function() return controller:GetWorld() end)
        local world_addr = Util.address(world)
        if world_addr ~= nil then
            if Scanner.last_world_address ~= nil and Scanner.last_world_address ~= world_addr then
                Util.log("INFO: World changed from " .. tostring(Scanner.last_world_address) .. " to " .. tostring(world_addr) .. " - resetting native registry")
                Scanner.reset_nearby(true)
                Scanner.reset_player_cache()
                Scanner.teleport_cooldown = now + 1.5
                return
            end
            Scanner.last_world_address = world_addr
        end

        local player = get_player_pawn(controller)
        if player ~= nil then
            local loc = Util.safe_call(nil, function() return player:K2_GetActorLocation() end)
            if loc ~= nil then
                local px, py, pz = tonumber(loc.X), tonumber(loc.Y), tonumber(loc.Z)
                if px ~= nil and py ~= nil and pz ~= nil then
                    if Scanner.last_scan_x ~= nil then
                        local dx, dy, dz = px - Scanner.last_scan_x, py - Scanner.last_scan_y, pz - Scanner.last_scan_z
                        local dist_sq = dx * dx + dy * dy + dz * dz
                        -- Si le joueur a bougé de plus de 100 mètres (10000 uu), c'est une téléportation
                        if dist_sq > 10000 * 10000 then
                            Scanner.reset_nearby(true)
                            Scanner.clear_aim()
                            Scanner.last_scan_x, Scanner.last_scan_y, Scanner.last_scan_z = px, py, pz
                            Scanner.teleport_cooldown = now + 1.5
                            Util.log("INFO: Teleportation detected. Pausing scan for 1.5s.")
                            return
                        end
                    end
                    if start_cycle == true then
                        Scanner.last_scan_x, Scanner.last_scan_y, Scanner.last_scan_z = px, py, pz
                    end
                end
            end
        end

        local pawn = player or get_player_pawn(controller)
        if pawn == nil or not actor_alive(pawn) then return end
        local changed = false
        local polled = false
        if start_cycle == true then
            polled = true
            changed = native_poll(controller, pawn, cfg.Scan.RadiusMeters or 100, cfg)
            n.native_more = false -- Reset just in case
        else
            changed = refine_nearby(controller, cfg)
        end
        -- If the native poll completed on this tick, publish the first fully
        -- localized rows immediately instead of waiting another 200 ms.
        if polled and (n.stage_count or 0) > 0 then
            changed = refine_nearby(controller, cfg) or changed
        end
        if changed then Profile.span("scan.nearby.rebuild", Scanner.rebuild_view, cfg) end
    end)
end

function Scanner.rebuild_view(cfg)
    local n = Scanner.nearby
    local radius_uu = (cfg.Scan.RadiusMeters or 100) * 100
    local rows, wild_total = {}, 0
    for _, entry in pairs(n.cache) do
        if n.generation - (entry.last_seen or 0) <= (cfg.Scan.EvictAfterMisses or 2)
            and (entry.distance or math.huge) <= radius_uu then
            if entry.dx ~= nil then
                entry.dist_disp = Direction.format_dist_disp(entry.dx, entry.dy, entry.dz)
            end
            wild_total = wild_total + 1
            if Score.passes_filter(entry, cfg) then rows[#rows + 1] = entry end
        end
    end
    Score.sort_entries(rows, Scanner.sort_mode)

    local max_rows = cfg.Panel.MaxRows or 10
    Scanner.pages = math.max(1, math.ceil(#rows / max_rows))
    if Scanner.page > Scanner.pages then Scanner.page = Scanner.pages end
    local first = (Scanner.page - 1) * max_rows + 1
    local visible = {}
    for i = first, math.min(first + max_rows - 1, #rows) do visible[#visible + 1] = rows[i] end
    Scanner.visible_rows = visible
    Scanner.filtered_count, Scanner.wild_count = #rows, wild_total
    local lang = cfg.Language
    Scanner.staging_count = n.stage_count or 0
    Scanner.empty_reason = nil
    local min_score = tonumber(cfg.Filter and cfg.Filter.MinScore) or 0
    if #rows == 0 and wild_total > 0 and min_score > 0 then
        local score_mode_name = L.t("val_" .. (cfg.Score.Mode or "combat"), lang)
        local filter_preset_name = cfg.Filter.Preset ~= "Off" and cfg.Filter.Preset or L.t("val_off", lang)
        Scanner.empty_reason = string.format(
            L.t("msg_no_score_meet", lang),
            score_mode_name,
            tostring(filter_preset_name), min_score)
    end

    local pending = (n.stage_count or 0) > 0
        and string.format("  %s %d...", L.t("header_scanning", lang), n.stage_count)
        or (Scanner.has_nearby_work() and "  " .. L.t("header_resolving", lang) .. "..." or "")
    local scope = ((cfg.Filter and cfg.Filter.Ownership) == "all") and L.t("header_pals", lang) or L.t("header_wild", lang)
    local watch = ""
    local wl = cfg.Filter and cfg.Filter.Watchlist
    if type(wl) == "table" and #wl > 0 then
        watch = (#wl == 1) and ("  |  " .. L.t("header_watch", lang) .. " " .. string.upper(wl[1]))
            or string.format("  |  " .. L.t("header_watch", lang) .. " %d", #wl)
    end
    local sort_key = Scanner.sort_mode or "score"
    if sort_key == "distance" then sort_key = "dist" end
    Scanner.header = string.format(
        "%d / %d %s  |  %dm  |  %s  |  " .. L.t("header_sort", lang) .. " %s  |  " .. L.t("header_filter", lang) .. " %s%s  |  " .. L.t("header_page", lang) .. " %d/%d%s",
        #rows, wild_total, scope, cfg.Scan.RadiusMeters or 100,
        L.t("val_" .. (cfg.Score.Mode or "combat"), lang), L.t("val_" .. sort_key, lang),
        cfg.Filter.Preset ~= "Off" and string.upper(cfg.Filter.Preset) or L.t("val_off", lang), watch, Scanner.page, Scanner.pages, pending)
end

function Scanner.recompute_scores(cfg)
    local n = Scanner.nearby
    n.work_queue, n.work_keys, n.work_head, n.work_tail = {}, {}, 1, 0
    local work_mode = cfg.Score and cfg.Score.Mode == "work"
    for key, entry in pairs(n.cache) do
        if entry.passives then Score.sort_passives(entry.passives) end
        if work_mode and entry.works_exact ~= true then queue_work(key) end
        finish_scores(entry, cfg)
    end
    local aim = Scanner.aim.data
    if aim then finish_scores(aim, cfg) end
end

function Scanner.cycle_sort(cfg)
    local order = { score = "distance", distance = "level", level = "score" }
    Scanner.sort_mode = order[Scanner.sort_mode] or "score"
    cfg.Sort = Scanner.sort_mode
    Scanner.rebuild_view(cfg)
    return Scanner.sort_mode
end

function Scanner.next_page(cfg)
    Scanner.page = Scanner.page + 1
    if Scanner.page > Scanner.pages then Scanner.page = 1 end
    Scanner.rebuild_view(cfg)
end

return Scanner
