-- =========================================================
-- SECTION 1: 模块入口
-- WhirlwindTracker — 狂暴战旋风斩强化层数跟踪
-- =========================================================

local VFlow = _G.VFlow
if not VFlow then return end

VFlow.ResourceCustomTrackers = VFlow.ResourceCustomTrackers or {}

local tracker = {}

-- =========================================================
-- SECTION 2: 常量与状态
-- =========================================================

local MAX_STACKS = 4
local DURATION = 20
local REQUIRED_TALENT_ID = 12950
local CRASHING_THUNDER_TALENT_ID = 436707
local UNHINGED_TALENT_ID = 386628

local GENERATOR_IDS = {
    [190411] = true, -- Whirlwind
    [6343] = true,   -- Thunder Clap
    [435222] = true, -- Thunder Blast
}

local SPENDER_IDS = {
    [23881] = true,  -- Bloodthirst
    [85288] = true,  -- Raging Blow
    [280735] = true, -- Execute
    [202168] = true, -- Impending Victory
    [184367] = true, -- Rampage
    [335096] = true, -- Bloodbath
    [335097] = true, -- Crushing Blow
    [5308] = true,   -- Execute
}

local state = {
    stacks = 0,
    expiresAt = nil,
    playerInCombat = false,
    pendingGenToken = 0,
    seenCastGUID = {},
}

local callbacks = {}

-- =========================================================
-- SECTION 3: 工具与公共接口
-- =========================================================

local function RefreshAll()
    if callbacks.refreshAll then
        callbacks.refreshAll()
    end
end

local function RefreshValuesOnly()
    if callbacks.refreshValuesOnly then
        callbacks.refreshValuesOnly()
    end
end

local function MarkRuntimeContextDirty()
    if callbacks.markRuntimeContextDirty then
        callbacks.markRuntimeContextDirty()
    end
end

local function CurrentSpecId()
    local specIndex = C_SpecializationInfo.GetSpecialization()
    return C_SpecializationInfo.GetSpecializationInfo(specIndex)
end

local function IsSpellKnownSafe(spellID)
    return C_SpellBook and C_SpellBook.IsSpellKnown and C_SpellBook.IsSpellKnown(spellID) or false
end

local function IsWarrior()
    return select(2, UnitClass("player")) == "WARRIOR"
end

function tracker.IsActive()
    return IsWarrior()
        and CurrentSpecId() == 72
        and IsSpellKnownSafe(REQUIRED_TALENT_ID)
end

local function HasCrashingThunderTalent()
    return IsSpellKnownSafe(CRASHING_THUNDER_TALENT_ID)
end

local function HasUnhingedTalent()
    return IsSpellKnownSafe(UNHINGED_TALENT_ID)
end

function tracker.Reset()
    state.stacks = 0
    state.expiresAt = nil
    state.pendingGenToken = 0
    wipe(state.seenCastGUID)
end

local function SetCombatState(inCombat)
    state.playerInCombat = inCombat == true
    if inCombat ~= true then
        state.pendingGenToken = state.pendingGenToken + 1
    end
end

local function HasNearbyHostile(spellID)
    if not CheckInteractDistance then
        return false
    end
    local useMeleeRange = spellID == 190411 or not HasCrashingThunderTalent()
    local interactIndex = useMeleeRange and 2 or 4
    for i = 1, 40 do
        local unit = "nameplate" .. i
        if UnitExists(unit)
            and UnitCanAttack("player", unit)
            and not UnitIsDead(unit)
            and CheckInteractDistance(unit, interactIndex) then
            return true
        end
    end
    return false
end

function tracker.GetValue()
    if not tracker.IsActive() then
        tracker.Reset()
        return nil, nil
    end
    if state.expiresAt and GetTime() >= state.expiresAt then
        state.stacks = 0
        state.expiresAt = nil
    end
    return MAX_STACKS, state.stacks or 0
end

-- =========================================================
-- SECTION 4: 事件处理
-- =========================================================

function tracker.OnSharedRuntimeEvent(event)
    if event == "PLAYER_REGEN_DISABLED" then
        SetCombatState(true)
        return
    end
    if event == "PLAYER_REGEN_ENABLED" then
        SetCombatState(false)
        return
    end
    if event == "PLAYER_SPECIALIZATION_CHANGED" then
        tracker.Reset()
    end
end

local function UpdateStacksAfterSpellcast(spellID)
    if not tracker.IsActive() then
        tracker.Reset()
        return
    end

    if GENERATOR_IDS[spellID] then
        if (spellID == 6343 or spellID == 435222) and not HasCrashingThunderTalent() then
            return
        end
        local combatAtCast = InCombatLockdown() or state.playerInCombat
        local hostileTargetAtCast = UnitExists("target")
            and UnitCanAttack("player", "target")
            and not UnitIsDead("target")
        state.pendingGenToken = state.pendingGenToken + 1
        local myToken = state.pendingGenToken
        C_Timer.After(0.15, function()
            if myToken ~= state.pendingGenToken then
                return
            end
            if not (combatAtCast or hostileTargetAtCast) and not HasNearbyHostile(spellID) then
                return
            end
            state.stacks = MAX_STACKS
            state.expiresAt = GetTime() + DURATION
            RefreshValuesOnly()
        end)
        return
    end

    if not SPENDER_IDS[spellID] or state.stacks <= 0 then
        return
    end

    local bladestormUsable = C_Spell and C_Spell.IsSpellUsable and select(1, C_Spell.IsSpellUsable(446035))
    if HasUnhingedTalent()
        and not bladestormUsable
        and (spellID == 23881 or spellID == 335096) then
        return
    end

    state.stacks = math.max(0, state.stacks - 1)
    if state.stacks == 0 then
        state.expiresAt = nil
    end
    RefreshValuesOnly()
end

local function HandleTalentChanged()
    tracker.Reset()
    MarkRuntimeContextDirty()
    RefreshAll()
end

local function HandleLifeStateChanged()
    tracker.Reset()
    RefreshAll()
end

local function HandleSpellcast(_, unit, castGUID, spellID)
    if unit ~= "player" or not spellID then
        return
    end
    if castGUID and state.seenCastGUID[castGUID] then
        return
    end
    if castGUID then
        state.seenCastGUID[castGUID] = true
    end
    UpdateStacksAfterSpellcast(spellID)
end

function tracker.RegisterEvents(registerEvent, runtimeCallbacks)
    callbacks = runtimeCallbacks or callbacks
    if not IsWarrior() then
        return
    end
    registerEvent("PLAYER_TALENT_UPDATE", "Core.ResourceBars.Whirlwind", HandleTalentChanged, nil, "WT:HandleTalentChanged", "count")
    registerEvent("TRAIT_CONFIG_UPDATED", "Core.ResourceBars.Whirlwind", HandleTalentChanged, nil, "WT:HandleTalentChanged", "count")
    registerEvent("PLAYER_DEAD", "Core.ResourceBars.Whirlwind", HandleLifeStateChanged, nil, "WT:HandleLifeStateChanged", "count")
    registerEvent("PLAYER_ALIVE", "Core.ResourceBars.Whirlwind", HandleLifeStateChanged, nil, "WT:HandleLifeStateChanged", "count")
    registerEvent("UNIT_SPELLCAST_SUCCEEDED", "Core.ResourceBars.Whirlwind", HandleSpellcast, "player", "WT:HandleSpellcast", "count")
end

VFlow.ResourceCustomTrackers.WHIRLWIND = tracker
