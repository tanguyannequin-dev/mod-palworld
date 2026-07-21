-- PalScouter gamedata.lua — cached game-object access, localization, passive ranks.
-- Every UObject touch is pcall-guarded. All functions must be called on the game thread.
local Util = require("util")
local PassiveRanks = require("passive_ranks")

local G = {
    passive_rank = PassiveRanks, -- lowercase raw passive name -> rank (-4..4)
    passive_name_cache = {},
    passive_name_failed = {},
    species_name_cache = {},
    species_name_failed = {},
    waza_cache = nil,            -- populated once, before aim-card scanning starts
    waza_cache_failed = false,
    waza_name_cache = {},
}

G.GENDER_NAMES = { [0] = "?", [1] = "M", [2] = "F" }
G.ELEMENT_NAMES = {
    [1] = "Neutral", [2] = "Fire", [3] = "Water", [4] = "Grass", [5] = "Electric",
    [6] = "Ice", [7] = "Ground", [8] = "Dark", [9] = "Dragon",
}

local singleton_cache = {}
local function singleton(path)
    local cached = singleton_cache[path]
    -- These are class default objects and live for the process lifetime. Revalidating
    -- them for every HUD primitive turns a cheap cache lookup into a UObject call.
    if cached ~= nil then return cached end
    local ok, obj = pcall(StaticFindObject, path)
    if ok and obj ~= nil and Util.valid(obj) then
        singleton_cache[path] = obj
        return obj
    end
    return nil
end

function G.pal_utility() return singleton("/Script/Pal.Default__PalUtility") end
function G.master_data_utility() return singleton("/Script/Pal.Default__PalMasterDataTablesUtility") end
function G.pal_ui_utility() return singleton("/Script/Pal.Default__PalUIUtility") end
function G.kismet_math() return singleton("/Script/Engine.Default__KismetMathLibrary") end

-- EPalMasterDataTableTextCategory value for the passive-skill name table
-- (verified working: passives localize through it).
local TEXT_CATEGORY_SKILL_NAME = 16

-- ------------------------------------------------- localized text lookup
-- GetLocalizedText echoes the row key back on a miss (observed in-game), so
-- a result equal to the key means "not found". Only call categories verified
-- from the current EPalLocalizeTextCategory enum. Probing arbitrary enum values
-- and consuming FString/FText out-parameter wrappers can corrupt UE4SS's Lua
-- stack, particularly when the game language is English.
local TEXT_CATEGORY_PAL_MONSTER_NAME = 4

local function localized_text(controller, family, key, preferred_category)
    if preferred_category == nil then return nil end
    local mdu = G.master_data_utility()
    if not mdu then return nil end
    local text = Util.safe_call(nil, function()
        return Util.display_text(mdu:GetLocalizedText(
            controller, preferred_category, FName(key)))
    end)
    if text ~= nil and not Util.is_localization_key(text, key) then return text end
    return nil
end

local character_database = nil
function G.character_database(controller)
    if character_database ~= nil and Util.valid(character_database) then return character_database end
    local utility = G.pal_utility()
    if not utility then return nil end
    local db = Util.safe_call(nil, function() return utility:GetDatabaseCharacterParameter(controller) end)
    if db ~= nil and Util.valid(db) then
        character_database = db
        return db
    end
    return nil
end

function G.passive_manager(controller)
    local utility = G.pal_utility()
    if not utility then return nil end
    local manager = Util.safe_call(nil, function() return utility:GetPassiveSkillManager(controller) end)
    if manager ~= nil and Util.valid(manager) then return manager end
    return nil
end

function G.waza_database(controller)
    local utility = G.pal_utility()
    if not utility then return nil end
    local db = Util.safe_call(nil, function() return utility:GetWazaDatabase(controller) end)
    if db ~= nil and Util.valid(db) then return db end
    return nil
end

-- ---------------------------------------------------------------- passives

-- Rank data is precomputed from the installed APSE table. Calling UDataTable
-- ForEachRow from an F8 scan can access-violate inside UE4SS before Lua pcall can
-- recover, so runtime global table traversal is deliberately forbidden.
function G.build_passive_cache(_) return true end

function G.passive_rank_for(raw_name)
    if not G.passive_rank then return nil end
    return G.passive_rank[string.lower(raw_name)]
end

function G.localize_passive(controller, raw_name)
    local cached = G.passive_name_cache[raw_name]
    if cached then return cached end
    local name, expected_key
    local manager = G.passive_manager(controller)
    local mdu = G.master_data_utility()
    if manager and mdu then
        name = Util.safe_call(nil, function()
            local text_id = manager:GetNameTextId(FName(raw_name))
            expected_key = Util.stringify_name(text_id)
            local text = mdu:GetLocalizedText(controller, TEXT_CATEGORY_SKILL_NAME, text_id)
            return Util.display_text(text)
        end)
    end
    if name then
        local compact = tostring(name):gsub("%s", "")
        if compact:match("^%?+$") or Util.is_localization_key(name, expected_key) then
            name = nil
        end
    end
    if not name then
        if not G.passive_name_failed[raw_name] then
            G.passive_name_failed[raw_name] = true
            Util.log("WARNING: game passive name unavailable for " .. raw_name)
        end
        -- Never put the game's placeholder "???" on the card.  The stable raw
        -- passive ID is still useful and retains rank/score lookup semantics.
        return tostring(raw_name)
    end
    G.passive_name_cache[raw_name] = name
    return name
end

-- ---------------------------------------------------------------- species

-- Ordered PAL_NAME_<key> localization keys to try for a character id. Variant
-- prefixes fall back to their base species entry: alpha/gym bosses (BOSS_/GYM_)
-- and raid predators (PREDATOR_<Base>_<Element>, which additionally drops the
-- trailing _<Element> token). Pure/string-only so it is unit-testable without
-- the engine; every candidate is still miss-safe through localized_text.
function G.species_name_keys(character_id)
    local keys = { character_id }
    local base_id = character_id:gsub("^BOSS_", ""):gsub("^GYM_", ""):gsub("^PREDATOR_", "")
    if base_id ~= character_id then
        keys[#keys + 1] = base_id
        local bare_id = base_id:gsub("_[%a]+$", "")
        if bare_id ~= base_id then keys[#keys + 1] = bare_id end
    end
    return keys
end

local function species_via_text_table(controller, character_id)
    for _, key in ipairs(G.species_name_keys(character_id)) do
        local name = localized_text(controller, "pal-name", "PAL_NAME_" .. key,
            TEXT_CATEGORY_PAL_MONSTER_NAME)
        if name ~= nil then return name end
    end
    return nil
end

function G.localize_species(controller, character_id, character_fname)
    local cached = G.species_name_cache[character_id]
    if cached then return cached end
    if character_fname == nil then
        character_fname = Util.safe_call(nil, function() return FName(character_id) end)
    end

    local name = species_via_text_table(controller, character_id)

    if name then
        G.species_name_cache[character_id] = name
        return name
    end
    if not G.species_name_failed[character_id] then
        G.species_name_failed[character_id] = true
        Util.log("WARNING: game display name unavailable for " .. character_id)
    end
    return nil
end

-- ---------------------------------------------------------------- per-pal reads

-- Returns parameter (PalIndividualCharacterParameter), component.
function G.get_parameter(actor)
    local component = Util.safe_call(nil, function() return actor:GetCharacterParameterComponent() end)
    if component == nil or not Util.valid(component) then
        component = Util.safe_call(nil, function() return actor.CharacterParameterComponent end)
    end
    if component == nil or not Util.valid(component) then return nil, nil end
    local parameter = Util.safe_call(nil, function() return component.IndividualParameter end)
    if parameter == nil or not Util.valid(parameter) then return nil, component end
    return parameter, component
end

function G.is_pal(actor)
    local static = Util.safe_call(nil, function() return actor.StaticCharacterParameterComponent end)
    local is_pal = static and Util.safe_call(nil, function() return static.IsPal end)
    if is_pal ~= nil then return is_pal == true end
    local utility = G.pal_utility()
    return utility ~= nil and Util.safe_call(false, function() return utility:IsPalMonster(actor) end) == true
end

-- IVs from the replicated save struct, read IN PLACE.
-- Never call the by-value save-parameter getter: its struct return crashes native code.
function G.read_ivs(parameter)
    local ok, ivs = pcall(function()
        local sp = parameter.SaveParameter
        if sp == nil then return nil end
        local function norm(v)
            v = tonumber(v)
            if v == nil then return nil end
            return Util.clamp(math.floor(v), 0, 100)
        end
        local hp = norm(sp.Talent_HP)
        local atk = norm(sp.Talent_Shot)
        local def = norm(sp.Talent_Defense)
        if hp == nil and atk == nil and def == nil then return nil end
        return { hp = hp, atk = atk, def = def }
    end)
    if ok then return ivs end
    return nil
end

function G.read_passives(controller, parameter)
    local result = {}
    pcall(function()
        local list = parameter:GetPassiveSkillList()
        if list == nil then return end
        local n = 0
        pcall(function() n = #list end)
        for i = 1, math.min(n, 4) do
            local ok_e, element = pcall(function() return list[i] end)
            if ok_e and element ~= nil then
                local raw = Util.display_text(element)
                if raw then
                    result[#result + 1] = {
                        raw = raw,
                        name = G.localize_passive(controller, raw),
                        rank = G.passive_rank_for(raw),
                    }
                end
            end
        end
    end)
    return result
end

local function waza_metadata(value)
    value = Util.unwrap(value)
    if value == nil or type(value) == "boolean" then return nil, nil end
    local power = tonumber(Util.safe_call(nil, function() return value.DisplayPower end))
        or tonumber(Util.safe_call(nil, function() return value.Power end))
    local element = tonumber(Util.safe_call(nil, function() return value.Element end))
    if power then power = math.floor(power + 0.5) end
    if element then element = math.floor(element + 0.5) end
    return power, element
end

-- Numeric EPalWazaID from an EquipWaza entry (enum values arrive as numbers,
-- wrappers, or wrapped structs depending on the UE4SS build).
local function waza_numeric_id(value)
    value = Util.unwrap(value)
    local id = tonumber(value)
        or tonumber(Util.stringify_name(value))
        or tonumber(Util.safe_call(nil, function() return value.Value end))
    if id then return math.floor(id + 0.5) end
    return nil
end

-- EPalWazaID value -> code name ("Unique_ChickenPal_ChickenPeck"), from the
-- live enum when UE4SS can enumerate it, else the static snapshot table.
-- WazaDataTable row names are auto-generated (NewRow_*) in Palworld 1.0, so
-- the enum is the only runtime source of real waza code names.
local waza_enum_names = nil
local function waza_code_name(id)
    if id == nil then return nil end
    if waza_enum_names == nil then
        local map = {}
        pcall(function()
            local enum = StaticFindObject("/Script/Pal.EPalWazaID")
            if enum == nil or not Util.valid(enum) then return end
            enum:ForEachName(function(a, b)
                -- Handle either (name, value) or (value, name) argument order.
                local value = tonumber(a) or tonumber(Util.stringify_name(a))
                local name = b
                if value == nil then
                    value = tonumber(b) or tonumber(Util.stringify_name(b))
                    name = a
                end
                local code = Util.stringify_name(name)
                    :gsub("^EPalWazaID::", ""):gsub("^.-::", "")
                if value ~= nil and code ~= "" then map[math.floor(value)] = code end
            end)
        end)
        if next(map) ~= nil then
            waza_enum_names = map
            Util.dbg("EPalWazaID enum enumerated")
        else
            waza_enum_names = require("waza_ids")
            Util.dbg("EPalWazaID enum unavailable; using static waza id table")
        end
    end
    local code = waza_enum_names[id]
    if code == nil or code == "None" then return nil end
    return code
end

-- Build id/name -> {code, power, element} once from the game's WazaDataTable.
-- This is scheduled before the aim scanner starts, so no table walk occurs while
-- a card is visible and skill power never depends on FindWazaForBP's out-params.
function G.build_waza_cache(controller)
    if G.waza_cache ~= nil or G.waza_cache_failed then return true end
    local database = G.waza_database(controller)
    if not database then return false end -- database not ready yet; retry later
    local ok_table, data_table = pcall(function() return database.WazaDataTable end)
    if not ok_table or data_table == nil or not Util.valid(data_table) then
        G.waza_cache_failed = true
        Util.log("WARNING: WazaDataTable unavailable; active-skill metadata disabled")
        return false
    end

    local cache, count = {}, 0
    local ok = pcall(function()
        data_table:ForEachRow(function(row_name, row)
            local code = Util.stringify_name(row_name)
            if code ~= "" then
                local power, element = waza_metadata(row)
                local entry = { code = code, power = power, element = element }
                cache["name:" .. string.lower(code)] = entry
                local id = waza_numeric_id(Util.safe_call(nil, function() return row.WazaType end))
                if id ~= nil then cache["id:" .. id] = entry end
                count = count + 1
            end
        end)
    end)
    if ok and count > 0 then
        G.waza_cache = cache
        Util.dbg("Waza table cached (" .. count .. " rows)")
        return true
    end

    G.waza_cache_failed = true
    Util.log("WARNING: could not iterate WazaDataTable; active-skill metadata disabled")
    return false
end

function G.warm_static_caches(controller)
    if controller == nil then return false end
    G.build_waza_cache(controller)
    -- Touch the enum map now so the first aimed Pal does not enumerate it.
    waza_code_name(0)
    return G.static_caches_ready()
end

function G.static_caches_ready()
    return G.waza_cache ~= nil or G.waza_cache_failed == true
end

-- Warm only the picker rows requested by the caller. Canonical icon casing is
-- required because lowercase PAL_NAME_* keys poison the miss cache.
function G.warm_species_names(controller, ids, budget)
    if controller == nil or type(ids) ~= "table" then return 0 end
    budget = tonumber(budget) or 4
    local ok, icons = pcall(require, "pal_icon_names")
    if not ok or type(icons) ~= "table" then icons = {} end
    local warmed = 0
    for i = 1, #ids do
        if warmed >= budget then break end
        local item = ids[i]
        local id = type(item) == "table" and (item.id or item[1]) or item
        local casing = type(item) == "table" and (item.casing or item[2]) or nil
        id = string.lower(tostring(id or ""))
        casing = tostring(casing or icons[id] or id)
        if id ~= "" and not G.species_name_cache[casing]
            and not G.species_name_cache[id] and not G.species_name_failed[casing] then
            local fname = Util.safe_call(nil, function() return FName(casing) end)
            local name = G.localize_species(controller, casing, fname)
            if name ~= nil and id ~= casing then G.species_name_cache[id] = name end
            warmed = warmed + 1
        end
    end
    return warmed
end

-- "Unique_ChickenPal_ChickenPeck" -> "Chicken Pal Chicken Peck" (last resort).
local function prettify_waza_code(code)
    local text = tostring(code or "")
    text = text:gsub("^EPalWazaID::", ""):gsub("^.-::", ""):gsub("^Unique_", "")
    text = text:gsub("_", " "):gsub("([a-z0-9])([A-Z])", "%1 %2"):gsub("%s+", " ")
    text = text:match("^%s*(.-)%s*$")
    if text == "" or text == "None" or text == "0" then return nil end
    return text
end

-- Localized active-skill name: use only the verified SkillName text category.
-- Avoid PalUIUtility:GetWazaName because its FString out-parameter has the same
-- transient-wrapper lifetime hazard as GetDisplayNickName under UE4SS.
local function localize_waza(controller, numeric_id, code)
    local cache_key = code or tostring(numeric_id)
    local cached = G.waza_name_cache[cache_key]
    if cached ~= nil then return cached end

    local name
    if code then
        name = localized_text(controller, "waza-name",
            "ACTION_SKILL_" .. code, TEXT_CATEGORY_SKILL_NAME)
    end
    if name == nil then name = prettify_waza_code(code) end
    if name ~= nil then G.waza_name_cache[cache_key] = name end
    return name
end

function G.read_active_skills(controller, parameter)
    G.build_waza_cache(controller)
    local skills = Util.safe_call(nil, function() return parameter.SaveParameter.EquipWaza end)
    if type(skills) ~= "table" then
        skills = Util.safe_call(nil, function() return parameter:GetEquipWaza() end)
    end
    if type(skills) ~= "table" then return {} end

    local result, count = {}, Util.safe_call(0, function() return #skills end)
    for i = 1, math.min(count, 3) do
        local raw_value = Util.safe_call(nil, function() return skills[i] end)
        local numeric_id = waza_numeric_id(raw_value)
        local entry = G.waza_cache
            and (G.waza_cache["id:" .. tostring(numeric_id)]
                or G.waza_cache["name:" .. string.lower(Util.stringify_name(raw_value))])
            or nil
        local power, element = entry and entry.power or nil, entry and entry.element or nil
        if power == nil then
            local database = G.waza_database(controller)
            if database then
                local ok, a, b, c, d, e = pcall(function()
                    return database:FindWazaForBP(Util.unwrap(raw_value))
                end)
                if ok then
                    local candidates = { a, b, c, d, e }
                    for index = 1, 5 do
                        local p, el = waza_metadata(candidates[index])
                        if power == nil then power = p end
                        if element == nil then element = el end
                    end
                end
            end
        end
        if numeric_id ~= nil or entry ~= nil then
            -- Real code name comes from the enum; DT row names are NewRow_*.
            local code = waza_code_name(numeric_id)
            result[#result + 1] = {
                id = numeric_id,
                raw = code or Util.display_text(raw_value) or tostring(i),
                name = localize_waza(controller, numeric_id, code),
                power = power,
                element = element,
            }
        end
    end
    return result
end

function G.read_work_levels(parameter)
    local result = {}
    for id = 1, 13 do
        if Util.safe_call(false, function() return parameter:HasWorkSuitability(id) end) == true then
            local rank = Util.safe_call(nil, function()
                return parameter:GetWorkSuitabilityRankWithCharacterRank(id)
            end) or Util.safe_call(nil, function() return parameter:GetWorkSuitabilityRank(id) end)
            result[#result + 1] = { id = id, rank = tonumber(rank) }
        end
    end
    return result
end

function G.read_identity(parameter)
    local character_fname = Util.safe_call(nil, function() return parameter:GetCharacterID() end)
    local id = Util.display_text(character_fname)
    local level = tonumber(Util.safe_call(nil, function() return parameter:GetLevel() end))
    local gender = tonumber(Util.safe_call(nil, function() return parameter:GetGenderType() end))
    return id, level, gender, character_fname
end

function G.read_hp(parameter)
    local hp = Util.safe_call(nil, function() return Util.fixed_point_to_number(parameter:GetHP()) end)
    -- GetMaxHP() is the unbuffed base value.  Current HP already reflects MaxHP
    -- passives, so pairing the two can produce impossible values such as
    -- 1349 / 1173.  Keep both sides in the buff-aware runtime domain.
    local max_hp = Util.safe_call(nil, function()
        return Util.fixed_point_to_number(parameter:GetMaxHP_withBuff())
    end)
    if max_hp == nil or max_hp <= 0 then
        -- Compatibility fallback for game builds where the buff-aware getter is
        -- temporarily unavailable during parameter initialization.
        max_hp = Util.safe_call(nil, function()
            return Util.fixed_point_to_number(parameter:GetMaxHP())
        end)
    end
    return hp, max_hp
end

function G.read_combat_stats(parameter)
    local atk = tonumber(Util.safe_call(nil, function() return parameter:GetShotAttack_withBuff() end))
    local def = tonumber(Util.safe_call(nil, function() return parameter:GetDefense_withBuff() end))
    local craft = tonumber(Util.safe_call(nil, function() return parameter:GetCraftSpeed_withBuff() end))
    return atk, def, craft
end

function G.read_elements(component)
    local names, ids = {}, {}
    if component == nil then return names, ids end
    for _, field in ipairs({ "ElementType1", "ElementType2" }) do
        local v = tonumber(Util.safe_call(nil, function() return component[field] end))
        local name = v and G.ELEMENT_NAMES[v]
        if name then names[#names + 1] = name; ids[#ids + 1] = v end
    end
    return names, ids
end

-- ---------------------------------------------------------------- wildness

local function guid_is_zero(guid)
    local a = tonumber(Util.safe_call(nil, function() return guid.A end))
    local b = tonumber(Util.safe_call(nil, function() return guid.B end))
    local c = tonumber(Util.safe_call(nil, function() return guid.C end))
    local d = tonumber(Util.safe_call(nil, function() return guid.D end))
    if a == nil and b == nil and c == nil and d == nil then return nil end
    return (a or 0) == 0 and (b or 0) == 0 and (c or 0) == 0 and (d or 0) == 0
end

local function guid_parts(guid)
    if guid == nil then return nil end
    local a = tonumber(Util.safe_call(nil, function() return guid.A end))
    local b = tonumber(Util.safe_call(nil, function() return guid.B end))
    local c = tonumber(Util.safe_call(nil, function() return guid.C end))
    local d = tonumber(Util.safe_call(nil, function() return guid.D end))
    if a == nil and b == nil and c == nil and d == nil then return nil end
    return { a or 0, b or 0, c or 0, d or 0 }
end

function G.guid_parts_equal(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    return a[1] == b[1] and a[2] == b[2] and a[3] == b[3] and a[4] == b[4]
end

function G.is_local_owned_from_signals(signals)
    signals = signals or {}
    return signals.is_otomo == true
        or signals.trainer_is_local == true
        or signals.owner_matches_local == true
end

local function has_inside_base_component(actor)
    return Util.safe_call(false, function()
        local component = actor.InsideBaseCampCheckComponent
        return component ~= nil and Util.valid(component)
    end) == true
end

-- Prefer the real player character; controller.Pawn may be the mount.
function G.local_player_character(controller)
    if controller == nil or not Util.valid(controller) then return nil end
    local default_character = Util.safe_call(nil, function()
        return controller:GetDefaultPlayerCharacter()
    end)
    if default_character ~= nil and Util.valid(default_character) then return default_character end
    local control_character = Util.safe_call(nil, function()
        return controller:GetControlPalCharacter()
    end)
    local pawn = Util.safe_call(nil, function() return controller.Pawn end)
    if control_character ~= nil and Util.valid(control_character)
        and has_inside_base_component(control_character) then return control_character end
    if pawn ~= nil and Util.valid(pawn) and has_inside_base_component(pawn) then return pawn end
    if control_character ~= nil and Util.valid(control_character) then return control_character end
    if pawn ~= nil and Util.valid(pawn) then return pawn end
    return nil
end

local function read_guid_parts(getter)
    local ok, parts = pcall(function() return guid_parts(getter()) end)
    if ok and type(parts) == "table" then return parts end
    return nil
end

function G.local_player_uid_parts(controller)
    if controller == nil or not Util.valid(controller) then return nil end
    local parts = read_guid_parts(function() return controller:GetPlayerUId() end)
    if parts then return parts end
    return read_guid_parts(function()
        local player_state = controller:GetPalPlayerState() or controller.PlayerState
        return player_state and player_state.PlayerUId or nil
    end)
end

function G.is_locally_owned(actor, parameter, component, controller)
    local is_otomo = Util.safe_call(false, function()
        local utility = G.pal_utility()
        if utility and utility:IsOtomo(actor) == true then return true end
        return component ~= nil and Util.valid(component) and component:IsOtomo() == true
    end) == true
    local local_character = G.local_player_character(controller)
    local trainer_is_local = local_character ~= nil and Util.safe_call(false, function()
        if component == nil or not Util.valid(component) then return false end
        return Util.same_object(Util.unwrap(component.Trainer), local_character)
    end) == true
    local owner_matches_local = false
    local local_uid = G.local_player_uid_parts(controller)
    if local_uid and parameter ~= nil and Util.valid(parameter) then
        local owner_uid = read_guid_parts(function()
            return parameter.SaveParameter.OwnerPlayerUId
        end)
        owner_matches_local = G.guid_parts_equal(local_uid, owner_uid)
    end
    return G.is_local_owned_from_signals({
        is_otomo = is_otomo,
        trainer_is_local = trainer_is_local,
        owner_matches_local = owner_matches_local,
    })
end

local BASE_CAMP_MANAGER_CLASSES = { "PalBaseCampManager", "BP_PalBaseCampManager_C" }

function G.player_inside_base_camp(controller, px, py, pz)
    local player = G.local_player_character(controller)
    if player ~= nil then
        local inside = Util.safe_call(nil, function()
            local component = player.InsideBaseCampCheckComponent
            if component == nil or not Util.valid(component) then return nil end
            return component:IsInsideBaseCamp() == true
        end)
        if inside == true or inside == false then return inside end
    end
    if px == nil then return false end
    local manager = Util.find_first_valid(BASE_CAMP_MANAGER_CLASSES)
    if manager == nil then return false end
    local camp = Util.safe_call(nil, function()
        return manager:GetInRangedBaseCamp({ X = px, Y = py, Z = pz }, 0.0)
    end)
    return camp ~= nil and Util.valid(camp)
end

-- Pure ownership rule (testable). owner_zero: true=empty GUID, false=has owner, nil=unreadable.
-- IMPORTANT: owner_zero=true alone is NOT enough for "wild" — secondary owned signals win.
function G.ownership_from_signals(s)
    s = s or {}
    if s.owner_zero == false then return "owned" end
    if s.has_old_owners or s.is_otomo or s.has_trainer or s.assigned_work then
        return "owned"
    end
    if s.owner_zero == true then return "wild" end
    return "unknown"
end

-- Classifies an actor: "wild" | "owned" | "unknown" | "notpal".
-- Ordered probes feed ownership_from_signals so zero OwnerUId no longer
-- short-circuits past base-worker / otomo / trainer signals.
function G.classify(actor, parameter, component)
    if not G.is_pal(actor) then return "notpal" end
    if parameter == nil or not Util.valid(parameter) then return "unknown" end
    if Util.safe_call(false, function() return parameter:IsPlayer() end) == true then return "notpal" end

    if component == nil or not Util.valid(component) then
        local _, c = G.get_parameter(actor)
        component = c
    end

    local owner_zero = Util.safe_call(nil, function()
        local guid = parameter.SaveParameter.OwnerPlayerUId
        if guid == nil then return nil end
        return guid_is_zero(guid)
    end)

    local has_old_owners = Util.safe_call(false, function()
        local old = parameter.SaveParameter.OldOwnerPlayerUIds
        if old == nil then return false end
        local n = 0
        pcall(function() n = #old end)
        return n > 0
    end) == true

    local is_otomo = Util.safe_call(false, function()
        local utility = G.pal_utility()
        if utility and utility:IsOtomo(actor) == true then return true end
        if component ~= nil and Util.valid(component) and component:IsOtomo() == true then return true end
        return false
    end) == true

    local has_trainer = Util.safe_call(false, function()
        if component == nil or not Util.valid(component) then return false end
        local trainer = Util.unwrap(component.Trainer)
        return trainer ~= nil and Util.valid(trainer)
    end) == true

    local assigned_work = Util.safe_call(false, function()
        if component == nil or not Util.valid(component) then return false end
        return component:IsAssignedToAnyWork() == true
    end) == true

    return G.ownership_from_signals({
        owner_zero = owner_zero,
        has_old_owners = has_old_owners,
        is_otomo = is_otomo,
        has_trainer = has_trainer,
        assigned_work = assigned_work,
    })
end

-- DEBUG-only ownership/IV dump. Logs once per actor full-name while Util.DEBUG.
local probe_seen = {}
function G.debug_probe(actor, parameter, component)
    if not Util.DEBUG then return end
    local key = Util.full_name(actor) or tostring(actor)
    if probe_seen[key] then return end
    probe_seen[key] = true
    if component == nil or not Util.valid(component) then
        local _, c = G.get_parameter(actor)
        component = c
    end
    local lines = {}
    local function probe(label, fn)
        local ok, v = pcall(fn)
        lines[#lines + 1] = label .. "=" .. (ok and tostring(v) or "<err>")
    end
    probe("CharacterID", function() return Util.stringify_name(parameter:GetCharacterID()) end)
    probe("OwnerUId.A", function() return parameter.SaveParameter.OwnerPlayerUId.A end)
    probe("OwnerZero", function() return tostring(guid_is_zero(parameter.SaveParameter.OwnerPlayerUId)) end)
    probe("OldOwners#", function() return #parameter.SaveParameter.OldOwnerPlayerUIds end)
    probe("util.IsOtomo", function() return G.pal_utility():IsOtomo(actor) end)
    probe("comp.IsOtomo", function() return component:IsOtomo() end)
    probe("Trainer", function()
        local t = Util.unwrap(component.Trainer)
        return (t ~= nil and Util.valid(t)) and "yes" or "no"
    end)
    probe("AssignedWork", function() return component:IsAssignedToAnyWork() end)
    probe("WorkType", function() return component.WorkType end)
    probe("classify", function() return G.classify(actor, parameter, component) end)
    Util.log("PROBE " .. table.concat(lines, " | "))
end

return G
