-- PalScouter passive_tags.lua — raw PassiveSkillDataTable row id -> role tags.
-- Keys are lowercase. Magnitude still comes from game Rank in score.lua.
local PassiveTags = {}

local TAGS = {
    -- Work speed
    craftspeed_up3 = { work = true, breeding = true },           -- Remarkable Craftsmanship
    craftspeed_up2 = { work = true, breeding = true },           -- Artisan
    craftspeed_up1 = { work = true, breeding = true },           -- Serious
    craftspeed_down1 = { work_penalty = true },                  -- Clumsy
    craftspeed_down2 = { work_penalty = true },                  -- Slacker
    worldtree_craftspeed = { work = true, breeding = true },     -- Demon's Hand
    pal_corporateslave = { work = true, breeding = true },       -- Work Slave
    pal_conceited = { work = true },                             -- Conceited
    nocturnal = { work = true, breeding = true },
    nightowl = { work = true },                                  -- Night Owl (day nap / night work)
    worksuitabilityaddrank_monsterfarm_1 = { work = true },     -- Farmhand
    worksuitabilityaddrank_monsterfarm_2 = { work = true, breeding = true }, -- Ranch Master
    -- Work sustain (hunger / SAN)
    pal_fullstomach_down_2 = { work = true },                    -- Diet Lover
    pal_fullstomach_down_3 = { work = true, breeding = true },   -- Mastery of Fasting
    pal_sanity_down_2 = { work = true },                         -- Workaholic
    pal_sanity_down_3 = { work = true, breeding = true },        -- Heart of the Immovable King
    rare = { work = true, combat = true, breeding = true },      -- Lucky
    vampire = { work = true, combat = true, breeding = true },   -- Vampiric
    -- Breeding farm only (not base work speed)
    test_palegg_hatchingspeed_up = { breeding = true },          -- Philanthropist
    mutationpal_babysitter = { breeding = true },                -- Babysitter
    -- Work penalties (also attack trade-offs)
    pal_rude = { combat = true, work_penalty = true },           -- Hooligan
    noukin = { combat = true, work_penalty = true, breeding = true }, -- Musclehead
    -- Travel / mount
    movespeed_up_1 = { travel = true, breeding = true },         -- Nimble
    movespeed_up_2 = { travel = true, breeding = true },         -- Runner
    movespeed_up_3 = { travel = true, breeding = true },         -- Swift
    swimspeed_up_1 = { travel = true },                          -- Sleek Stroke
    swimspeed_up_2 = { travel = true },                          -- Ace Swimmer
    swimspeed_up_3 = { travel = true },                          -- King of the Waves
    stamina_up_1 = { travel = true, breeding = true },           -- Infinite Stamina
    stamina_up_2 = { travel = true },                            -- Fit as a Fiddle
    stamina_up_3 = { travel = true, breeding = true },           -- Eternal Engine
    stamina_down_1 = { travel = true },                          -- Sickly (negative rank)
    ridejumpcount_increase1 = { travel = true },                 -- Lightfooted
    ridejumpcount_increase2 = { travel = true, breeding = true }, -- Skymarcher
    worldtree_movespeed = { travel = true, breeding = true },    -- Dimensional Leap
    legend = { combat = true, travel = true, breeding = true },
    -- Combat
    pal_allattack_up3 = { combat = true, breeding = true },      -- Demon God
    pal_allattack_up2 = { combat = true, breeding = true },      -- Ferocious
    pal_allattack_up1 = { combat = true, breeding = true },      -- Brave
    deffence_up3 = { combat = true, breeding = true },           -- Diamond Body
    deffence_up2 = { combat = true, breeding = true },           -- Burly Body
    deffence_up2_2 = { combat = true, breeding = true },         -- Heavyweight
    deffence_up1 = { combat = true },                            -- Hard Skin
    cooltimereduction_up_1 = { combat = true, breeding = true }, -- Serenity
    cooltimereduction_up_2 = { combat = true },                  -- Impatient
    cooltimereduction_up_3 = { combat = true, breeding = true }, -- Tempest Fury
    mutationpal_immortal = { combat = true, breeding = true },   -- Immortality
}

function PassiveTags.tags_for(raw)
    if raw == nil or raw == "" then return {} end
    return TAGS[string.lower(tostring(raw))] or {}
end

-- Pure work passives pad Combat falsely; dual-role (Lucky/Vampiric) still count.
function PassiveTags.is_work_only(raw)
    local tags = PassiveTags.tags_for(raw)
    return tags.work == true and tags.combat ~= true
end

return PassiveTags
