-- =========================================================
-- SECTION 1: 模块入口
-- SpellStateWatcher — 单 frame 技能状态 watcher（按 spellID 订阅）
-- =========================================================

local VFlow = _G.VFlow
if not VFlow then return end

local Profiler = VFlow.Profiler

local SpellStateWatcher = {}
VFlow.SpellStateWatcher = SpellStateWatcher

local watcherFrame = CreateFrame("Frame")
local dispatchFrame = CreateFrame("Frame")
dispatchFrame:Hide()

local ownerStates = setmetatable({}, { __mode = "k" })
local spellOwners = {}
local spellRefCounts = {}
local activeSpellCount = 0

local dispatchPending = false
local hasCooldownPending = false
local hasChargesPending = false

local dispatchSpellChanges

local function CreateWeakOwnerSet()
    return setmetatable({}, { __mode = "k" })
end

local function RefreshWatcherEventRegistration()
    if activeSpellCount > 0 then
        watcherFrame:RegisterEvent("SPELL_UPDATE_COOLDOWN")
        watcherFrame:RegisterEvent("SPELL_UPDATE_CHARGES")
    else
        watcherFrame:UnregisterEvent("SPELL_UPDATE_COOLDOWN")
        watcherFrame:UnregisterEvent("SPELL_UPDATE_CHARGES")
    end
end

local function EnsureOwnerState(ownerKey, callback)
    local ownerState = ownerStates[ownerKey]
    if ownerState then
        if type(callback) == "function" then
            ownerState.callback = callback
        end
        return ownerState
    end

    ownerState = {
        callback = callback,
        spells = {},
    }
    ownerStates[ownerKey] = ownerState
    return ownerState
end

local function RemoveOwnerIfEmpty(ownerKey)
    local ownerState = ownerStates[ownerKey]
    if not ownerState then
        return
    end
    if next(ownerState.spells) then
        return
    end
    ownerStates[ownerKey] = nil
end

local function RemoveSpellOwner(spellID, ownerKey)
    local owners = spellOwners[spellID]
    if not owners then
        return
    end
    owners[ownerKey] = nil
    if next(owners) == nil then
        spellOwners[spellID] = nil
    end
end

local function QueueDispatch()
    if dispatchPending or activeSpellCount <= 0 then
        return
    end
    dispatchPending = true
    dispatchFrame:Show()
end

dispatchSpellChanges = function()
    dispatchPending = false

    if activeSpellCount <= 0 then
        hasCooldownPending = false
        hasChargesPending = false
        return
    end

    local cooldownChanged = hasCooldownPending
    local chargesChanged = hasChargesPending
    hasCooldownPending = false
    hasChargesPending = false

    if not cooldownChanged and not chargesChanged then
        return
    end

    for spellID, refCount in pairs(spellRefCounts) do
        if refCount and refCount > 0 then
            local owners = spellOwners[spellID]
            if owners then
                for ownerKey in pairs(owners) do
                    local ownerState = ownerStates[ownerKey]
                    local callback = ownerState and ownerState.callback
                    if callback then
                        callback(spellID, cooldownChanged, chargesChanged)
                    end
                end
            end
        end
    end
end

dispatchFrame:SetScript("OnUpdate", function(self)
    self:Hide()
    dispatchSpellChanges()
end)

watcherFrame:SetScript("OnEvent", function(_, event)
    if event == "SPELL_UPDATE_COOLDOWN" then
        hasCooldownPending = true
        QueueDispatch()
    elseif event == "SPELL_UPDATE_CHARGES" then
        hasChargesPending = true
        QueueDispatch()
    end
end)

function SpellStateWatcher.watch(ownerKey, spellID, callback)
    if ownerKey == nil or type(spellID) ~= "number" or spellID <= 0 or type(callback) ~= "function" then
        return false
    end

    local ownerState = EnsureOwnerState(ownerKey, callback)
    local watchState = ownerState.spells[spellID]
    if not watchState then
        watchState = { refCount = 0 }
        ownerState.spells[spellID] = watchState
    end

    watchState.refCount = watchState.refCount + 1
    if watchState.refCount > 1 then
        return true
    end

    local refCount = spellRefCounts[spellID] or 0
    if refCount <= 0 then
        activeSpellCount = activeSpellCount + 1
        spellOwners[spellID] = spellOwners[spellID] or CreateWeakOwnerSet()
        RefreshWatcherEventRegistration()
    end

    spellRefCounts[spellID] = refCount + 1
    spellOwners[spellID][ownerKey] = true
    return true
end

function SpellStateWatcher.unwatch(ownerKey, spellID)
    local ownerState = ownerStates[ownerKey]
    local watchState = ownerState and ownerState.spells and ownerState.spells[spellID]
    if not watchState then
        return false
    end

    watchState.refCount = (watchState.refCount or 0) - 1
    if watchState.refCount > 0 then
        return true
    end

    ownerState.spells[spellID] = nil
    RemoveOwnerIfEmpty(ownerKey)
    RemoveSpellOwner(spellID, ownerKey)

    local refCount = spellRefCounts[spellID]
    if not refCount then
        return true
    end

    refCount = refCount - 1
    if refCount <= 0 then
        spellRefCounts[spellID] = nil
        activeSpellCount = activeSpellCount - 1
        if activeSpellCount < 0 then
            activeSpellCount = 0
        end
        RefreshWatcherEventRegistration()
    else
        spellRefCounts[spellID] = refCount
    end

    return true
end

function SpellStateWatcher.unwatchAll(ownerKey)
    local ownerState = ownerStates[ownerKey]
    if not ownerState then
        return
    end

    local spellIDs = {}
    for spellID in pairs(ownerState.spells) do
        spellIDs[#spellIDs + 1] = spellID
    end

    for i = 1, #spellIDs do
        SpellStateWatcher.unwatch(ownerKey, spellIDs[i])
    end
end

if Profiler and Profiler.registerScope then
    Profiler.registerScope("SSW:Dispatch", function()
        return dispatchSpellChanges
    end, function(fn)
        dispatchSpellChanges = fn
    end)
end

if Profiler and Profiler.registerTableCount then
    Profiler.registerTableCount(SpellStateWatcher, "watch", "SSW:Watch")
    Profiler.registerTableCount(SpellStateWatcher, "unwatch", "SSW:Unwatch")
    Profiler.registerTableCount(SpellStateWatcher, "unwatchAll", "SSW:UnwatchAll")
end
