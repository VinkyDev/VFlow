-- =========================================================
-- SECTION 1: 模块入口
-- OtherBuffMonitor — 主动 + 被动 BUFF 监控（合并容器）
-- =========================================================

local VFlow = _G.VFlow
if not VFlow then return end

local L = VFlow.L
local Profiler = VFlow.Profiler
local Utils = VFlow.Utils
local StyleApply = VFlow.StyleApply
local ModuleControlConstants = VFlow.ModuleControlConstants

local MODULE_KEY = "VFlow.Buffs"

if not ModuleControlConstants.CORE_ENABLED then return end
local MasqueSupport = VFlow.MasqueSupport

local function getBuffsDB()
    return VFlow.getDBIfReady and VFlow.getDBIfReady(MODULE_KEY) or nil
end

-- =========================================================
-- SECTION 2: 模块状态
-- =========================================================

local _container = nil
-- 主动池：物品/技能，UNIT_SPELLCAST_SUCCEEDED
local _activeIconPool = {}
local _autoDetectedItems = {}
local _scanTooltip = nil
local _activeScanRetryCount = 0
local _activeScanTimer = nil
-- 被动池：SPELL_UPDATE_COOLDOWN，支持层数
local _passiveIconPool = {}

-- =========================================================
-- SECTION 3: 持续时间解析
-- =========================================================

local function ParseDuration(text)
    if not text then return nil end

    local patterns = {
        "(%d+)%s*秒",
        "(%d+)%s*sec",
        "(%d+)%s*second",
        "持续%s*(%d+)",
        "for%s*(%d+)",
    }

    for _, pattern in ipairs(patterns) do
        local duration = text:match(pattern)
        if duration then
            return tonumber(duration)
        end
    end

    return nil
end

local function GetSpellDurationInfo(spellID)
    if not spellID then return nil, nil end

    local spellInfo = C_Spell.GetSpellInfo(spellID)
    if not spellInfo then
        return nil, nil
    end

    local description = C_Spell.GetSpellDescription(spellID)
    if description then
        local duration = ParseDuration(description)
        if duration then
            return spellInfo, duration
        end
    end

    local tooltipInfo = C_TooltipInfo.GetSpellByID(spellID)
    if tooltipInfo and tooltipInfo.lines then
        for _, line in ipairs(tooltipInfo.lines) do
            if line.leftText then
                local duration = ParseDuration(line.leftText)
                if duration then
                    return spellInfo, duration
                end
            end
        end
    end

    return spellInfo, nil
end

local function GetItemMonitorInfo(itemID)
    if not itemID then return nil end

    local spellID = select(2, C_Item.GetItemSpell(itemID))
    if not spellID then
        return nil
    end

    local spellInfo, duration = GetSpellDurationInfo(spellID)
    if not spellInfo then
        return nil
    end

    local _, _, _, _, _, _, _, _, _, itemIcon = C_Item.GetItemInfo(itemID)
    if duration then
        return {
            spellID = spellID,
            name = spellInfo.name,
            icon = itemIcon or spellInfo.iconID or 134400,
            duration = duration,
            sourceType = "item",
            sourceID = itemID,
        }
    end

    if not _scanTooltip then
        _scanTooltip = CreateFrame("GameTooltip", "VFlowOtherBuffScanTooltip", UIParent, "GameTooltipTemplate")
        _scanTooltip:SetOwner(UIParent, "ANCHOR_NONE")
    end

    _scanTooltip:ClearLines()
    _scanTooltip:SetItemByID(itemID)

    for i = 1, _scanTooltip:NumLines() do
        local line = _G["VFlowOtherBuffScanTooltipTextLeft" .. i]
        if line then
            local text = line:GetText()
            if text then
                duration = ParseDuration(text)
                if duration then
                    break
                end
            end
        end
    end

    return {
        spellID = spellID,
        name = spellInfo.name,
        icon = itemIcon or spellInfo.iconID or 134400,
        duration = duration,
        sourceType = "item",
        sourceID = itemID,
    }
end

local function GetSpellMonitorInfo(spellID)
    local spellInfo, duration = GetSpellDurationInfo(spellID)
    if not spellInfo then
        return nil
    end

    return {
        spellID = spellID,
        name = spellInfo.name,
        icon = spellInfo.iconID or 134400,
        duration = duration,
        sourceType = "spell",
        sourceID = spellID,
    }
end

local function GetPassiveDisplayName(iconID, spellID)
    local iconSpell = C_Spell.GetSpellInfo(iconID)
    if iconSpell and iconSpell.name then
        return iconSpell.name
    end
    local buffSpell = C_Spell.GetSpellInfo(spellID)
    if buffSpell and buffSpell.name then
        return buffSpell.name
    end
    return string.format(L["Spell %s"], spellID)
end

-- =========================================================
-- SECTION 4: 容器管理
-- =========================================================

local function InitContainer()
    if _container then return end

    local db = getBuffsDB()
    if not db or not db.trinketPotion then return end

    local config = db.trinketPotion

    _container = CreateFrame("Frame", "VFlowOtherBuffContainer", UIParent)
    _container:SetSize(100, 100)
    _container:SetMovable(true)
    _container:SetClampedToScreen(true)

    VFlow.ContainerAnchor.ApplyFramePosition(_container, config, nil)

    if VFlow.DragFrame then
        VFlow.DragFrame.register(_container, {
            label = (L and L["Other BUFF"]) or "其他BUFF",
            menuKey = "buff_other",
            getAnchorConfig = function()
                local d = getBuffsDB()
                return d and d.trinketPotion
            end,
            onPositionChanged = function(_, kind, x, y)
                if kind ~= "PLAYER_ANCHOR" and kind ~= "SYMMETRIC" then return end
                VFlow.Store.set(MODULE_KEY, "trinketPotion.x", x)
                VFlow.Store.set(MODULE_KEY, "trinketPotion.y", y)
            end,
        })
        if VFlow.DragFrame.applyRegisteredPosition then
            VFlow.DragFrame.applyRegisteredPosition(_container)
        end
    end
end

local function UpdateContainerPosition()
    if not _container then return end

    local db = getBuffsDB()
    local config = db and db.trinketPotion
    if not config then return end

    VFlow.ContainerAnchor.ApplyFramePosition(_container, config, nil)
    if VFlow.DragFrame and VFlow.DragFrame.applyRegisteredPosition then
        VFlow.DragFrame.applyRegisteredPosition(_container)
    end
end

-- =========================================================
-- SECTION 5: 图标管理
-- =========================================================

local function UpdateStackText(frame, count, hasStacks)
    if not frame or not StyleApply then return end
    local stackFS = StyleApply.GetStackFontString(frame)
    if not stackFS then return end
    if hasStacks and count and count > 0 then
        stackFS:SetText(tostring(count))
        stackFS:Show()
    else
        stackFS:SetText("")
    end
end

local function ClearPassiveRuntimeState(poolData)
    if not poolData then return end
    local frame = poolData.frame
    if frame and frame.hideTimer then
        frame.hideTimer:Cancel()
        frame.hideTimer = nil
    end
    poolData.count = 0
    poolData.lastTrigger = nil
    poolData.active = false
    if frame then
        UpdateStackText(frame, 0, poolData.hasStacks)
        if frame.cooldown and frame.cooldown.Clear then
            frame.cooldown:Clear()
        end
        frame:Hide()
    end
end

local function CreateIconFrame()
    local frame = CreateFrame("Frame", nil, _container)
    frame:SetSize(40, 40)

    local icon = frame:CreateTexture(nil, "ARTWORK")
    icon:SetAllPoints()
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    local cooldown = CreateFrame("Cooldown", nil, frame, "CooldownFrameTemplate")
    cooldown:SetAllPoints()
    cooldown:SetDrawEdge(false)
    cooldown:SetDrawSwipe(true)
    cooldown:SetReverse(true)

    frame.Icon = icon
    frame.icon = icon
    frame.Cooldown = cooldown
    frame.cooldown = cooldown

    local stackHolder = CreateFrame("Frame", nil, frame)
    stackHolder:SetAllPoints()
    stackHolder:SetFrameLevel(frame:GetFrameLevel() + 6)
    local stackFS = stackHolder:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
    stackFS:SetDrawLayer("OVERLAY", 7)
    stackHolder.Current = stackFS
    frame.ChargeCount = stackHolder

    frame:Hide()
    return frame
end

local function ApplyCooldownSwipe(frame, startTime, duration)
    if not frame or not duration or duration <= 0 then return end
    if not (Utils and Utils.setCooldownFromStartAndDuration(frame.cooldown, frame, startTime, duration)) then
        if frame.cooldown and frame.cooldown.Clear then
            frame.cooldown:Clear()
        end
    end
end

local function ActivateActiveIcon(spellID)
    local poolData = _activeIconPool[spellID]
    if not poolData then return end

    local frame = poolData.frame
    local duration = poolData.duration

    if not frame or not duration then return end

    if poolData.icon then
        frame.icon:SetTexture(poolData.icon)
    end

    if not (Utils and Utils.setCooldownFromStartAndDuration(frame.cooldown, frame, GetTime(), duration)) then
        if frame.cooldown.Clear then frame.cooldown:Clear() end
    end
    frame:Show()

    if frame.hideTimer then
        frame.hideTimer:Cancel()
        frame.hideTimer = nil
    end

    frame.hideTimer = C_Timer.NewTimer(duration, function()
        frame:Hide()
        frame.hideTimer = nil
        RefreshLayout()
    end)
    RefreshLayout()
end

local function TriggerSimple(spellID, poolData)
    local frame = poolData.frame
    local duration = poolData.duration
    if not frame or not duration then return end

    if poolData.icon then
        frame.icon:SetTexture(poolData.icon)
    end

    poolData.active = true
    ApplyCooldownSwipe(frame, GetTime(), duration)
    frame:Show()

    if frame.hideTimer then
        frame.hideTimer:Cancel()
        frame.hideTimer = nil
    end

    frame.hideTimer = C_Timer.NewTimer(duration, function()
        frame.hideTimer = nil
        poolData.active = false
        frame:Hide()
        if frame.cooldown and frame.cooldown.Clear then
            frame.cooldown:Clear()
        end
        RefreshLayout()
    end)
    RefreshLayout()
end

local function TriggerStacked(spellID, poolData)
    local frame = poolData.frame
    local duration = poolData.duration
    if not frame or not duration then return end

    if poolData.icon then
        frame.icon:SetTexture(poolData.icon)
    end

    poolData.count = (poolData.count or 0) + 1
    poolData.lastTrigger = GetTime()

    ApplyCooldownSwipe(frame, poolData.lastTrigger, duration)
    UpdateStackText(frame, poolData.count, true)
    frame:Show()

    C_Timer.After(duration, function()
        local current = _passiveIconPool[spellID]
        if not current or current ~= poolData then
            return
        end
        poolData.count = math.max(0, (poolData.count or 0) - 1)
        if poolData.count <= 0 then
            poolData.lastTrigger = nil
            frame:Hide()
            if frame.cooldown and frame.cooldown.Clear then
                frame.cooldown:Clear()
            end
            UpdateStackText(frame, 0, true)
        else
            if poolData.lastTrigger then
                ApplyCooldownSwipe(frame, poolData.lastTrigger, duration)
            end
            UpdateStackText(frame, poolData.count, true)
        end
        RefreshLayout()
    end)

    RefreshLayout()
end

local function TriggerPassive(spellID)
    local poolData = _passiveIconPool[spellID]
    if not poolData then return end

    if poolData.hasStacks then
        TriggerStacked(spellID, poolData)
    else
        TriggerSimple(spellID, poolData)
    end
end

-- =========================================================
-- SECTION 6: 条目扫描
-- =========================================================

local function ScanActiveItems()
    InitContainer()
    local db = getBuffsDB()
    if not db or not db.trinketPotion then
        return 0
    end
    local config = db.trinketPotion

    local oldPool = _activeIconPool
    _activeIconPool = {}
    _autoDetectedItems = {}

    local unloadedCount = 0

    if config.autoTrinkets then
        for slotID = 13, 14 do
            local itemID = GetInventoryItemID("player", slotID)
            if itemID then
                C_Item.RequestLoadItemDataByID(itemID)

                local itemData = GetItemMonitorInfo(itemID)
                if itemData then
                    _activeIconPool[itemData.spellID] = {
                        frame = oldPool[itemData.spellID] and oldPool[itemData.spellID].frame or nil,
                        sourceType = itemData.sourceType,
                        sourceID = itemData.sourceID,
                        icon = itemData.icon,
                        duration = itemData.duration,
                        isAuto = true,
                    }

                    _autoDetectedItems[itemID] = {
                        spellID = itemData.spellID,
                        icon = itemData.icon or 134400,
                        duration = itemData.duration or 0,
                    }

                    if not itemData.duration then
                        unloadedCount = unloadedCount + 1
                    end
                else
                    unloadedCount = unloadedCount + 1
                end
            end
        end
    end

    for itemID in pairs(config.itemIDs or {}) do
        C_Item.RequestLoadItemDataByID(itemID)

        local itemData = GetItemMonitorInfo(itemID)

        if itemData and not itemData.duration and config.itemDurations[itemID] then
            itemData.duration = config.itemDurations[itemID]
        end

        if itemData then
            _activeIconPool[itemData.spellID] = {
                frame = oldPool[itemData.spellID] and oldPool[itemData.spellID].frame or nil,
                sourceType = itemData.sourceType,
                sourceID = itemData.sourceID,
                icon = itemData.icon,
                duration = itemData.duration,
                isAuto = false,
            }

            if not itemData.duration then
                unloadedCount = unloadedCount + 1
            end
        else
            unloadedCount = unloadedCount + 1
        end
    end

    for spellID in pairs(config.spellIDs or {}) do
        local spellData = GetSpellMonitorInfo(spellID)

        if spellData and not spellData.duration and config.spellDurations[spellID] then
            spellData.duration = config.spellDurations[spellID]
        end

        if spellData then
            _activeIconPool[spellID] = {
                frame = oldPool[spellID] and oldPool[spellID].frame or nil,
                sourceType = spellData.sourceType,
                sourceID = spellData.sourceID,
                icon = spellData.icon,
                duration = spellData.duration,
                isAuto = false,
            }

            if not spellData.duration then
                unloadedCount = unloadedCount + 1
            end
        else
            unloadedCount = unloadedCount + 1
        end
    end

    for spellID, poolData in pairs(oldPool) do
        if not _activeIconPool[spellID] and poolData and poolData.frame then
            local frame = poolData.frame
            if frame.hideTimer then
                frame.hideTimer:Cancel()
                frame.hideTimer = nil
            end
            frame:Hide()
            frame:SetParent(nil)
        end
    end

    for spellID, poolData in pairs(_activeIconPool) do
        if not poolData.frame then
            poolData.frame = CreateIconFrame()
        end
        if poolData.frame and poolData.icon then
            poolData.frame.icon:SetTexture(poolData.icon)
        end
    end

    RefreshLayout()
    return unloadedCount
end

local function ScheduleActiveScan()
    if _activeScanTimer then
        _activeScanTimer:Cancel()
        _activeScanTimer = nil
    end

    _activeScanRetryCount = 0

    local unloadedCount = ScanActiveItems()

    if unloadedCount > 0 then
        _activeScanTimer = C_Timer.NewTicker(0.5, function()
            _activeScanRetryCount = _activeScanRetryCount + 1

            local stillUnloaded = ScanActiveItems()

            if stillUnloaded == 0 or _activeScanRetryCount >= 10 then
                if _activeScanTimer then
                    _activeScanTimer:Cancel()
                    _activeScanTimer = nil
                end
            end
        end)
    end
end

local function ScanPassiveEntries()
    InitContainer()
    local db = getBuffsDB()
    if not db or not db.passiveBuff then
        return
    end
    local config = db.passiveBuff

    local oldPool = _passiveIconPool
    _passiveIconPool = {}

    for spellID in pairs(config.spellIDs or {}) do
        local iconID = config.iconIDs and config.iconIDs[spellID]
        local duration = config.spellDurations and config.spellDurations[spellID]
        local hasStacks = config.hasStacks and config.hasStacks[spellID] == true
        if iconID and duration and duration > 0 then
            local old = oldPool[spellID]
            _passiveIconPool[spellID] = {
                frame = old and old.frame or nil,
                icon = iconID,
                duration = duration,
                hasStacks = hasStacks,
                count = 0,
                lastTrigger = nil,
                active = false,
            }
        end
    end

    for spellID, poolData in pairs(oldPool) do
        if not _passiveIconPool[spellID] then
            ClearPassiveRuntimeState(poolData)
            if poolData.frame then
                poolData.frame:SetParent(nil)
            end
        end
    end

    for spellID, poolData in pairs(_passiveIconPool) do
        if not poolData.frame then
            poolData.frame = CreateIconFrame()
        end
        if poolData.frame and poolData.icon then
            poolData.frame.icon:SetTexture(poolData.icon)
        end
        UpdateStackText(poolData.frame, poolData.count, poolData.hasStacks)
    end

    RefreshLayout()
end

-- =========================================================
-- SECTION 7: 布局刷新
-- =========================================================

local function IsPassiveEntryVisible(poolData)
    if poolData.hasStacks then
        return (poolData.count or 0) > 0
    end
    return poolData.active == true
end

local function IsActiveEntryVisible(poolData)
    return poolData.frame and poolData.frame.hideTimer ~= nil
end

local function CollectOrderedEntries()
    local allEntries = {}

    for spellID, poolData in pairs(_activeIconPool) do
        if poolData.frame then
            table.insert(allEntries, { pool = "active", spellID = spellID, poolData = poolData })
        end
    end
    for spellID, poolData in pairs(_passiveIconPool) do
        if poolData.frame then
            table.insert(allEntries, { pool = "passive", spellID = spellID, poolData = poolData })
        end
    end

    table.sort(allEntries, function(a, b)
        if a.pool ~= b.pool then
            return a.pool == "active"
        end
        return a.spellID < b.spellID
    end)

    return allEntries
end

function RefreshLayout()
    InitContainer()
    if not _container then return end
    local db = getBuffsDB()
    if not db or not db.trinketPotion then
        return
    end
    local config = db.trinketPotion
    local isEditMode = VFlow.State.get("isEditMode")

    local allEntries = CollectOrderedEntries()
    local visibleIcons = {}

    if isEditMode then
        for index, entry in ipairs(allEntries) do
            if index <= 2 then
                entry.poolData.frame:Show()
                table.insert(visibleIcons, entry.poolData.frame)
            else
                entry.poolData.frame:Hide()
            end
        end
    else
        for _, entry in ipairs(allEntries) do
            local poolData = entry.poolData
            local visible = entry.pool == "active"
                and IsActiveEntryVisible(poolData)
                or IsPassiveEntryVisible(poolData)
            if visible then
                poolData.frame:Show()
                table.insert(visibleIcons, poolData.frame)
            else
                poolData.frame:Hide()
            end
        end
    end

    local count = #visibleIcons
    if count == 0 then
        if isEditMode then
            _container:SetSize(100, 100)
        else
            _container:SetSize(1, 1)
        end
        return
    end

    local w = config.width or 40
    local h = config.height or 40
    local spacingX = config.spacingX or 2
    local spacingY = config.spacingY or 2
    local isVertical = (config.vertical == true)
    local growDir = config.growDirection or "center"

    for _, frame in ipairs(visibleIcons) do
        if VFlow.StyleApply then
            VFlow.StyleApply.ApplyIconSize(frame, w, h)
            StyleApply.ApplyButtonStyleIfStale(frame, config)
        end
        if MasqueSupport and MasqueSupport:IsActive() and frame.Icon then
            MasqueSupport:RegisterButton(frame, frame.Icon)
        end
        frame:SetAlpha(1)
    end

    if not isVertical then
        if config.dynamicLayout then
            local totalW = count * w + (count - 1) * spacingX
            _container:SetSize(totalW, h)

            if growDir == "center" then
                local startX = -(totalW / 2) + w / 2
                for i, frame in ipairs(visibleIcons) do
                    local offsetX = startX + (i - 1) * (w + spacingX)
                    frame:ClearAllPoints()
                    frame:SetPoint("CENTER", _container, "CENTER", offsetX, 0)
                    frame:SetSize(w, h)
                end
            elseif growDir == "start" then
                for i, frame in ipairs(visibleIcons) do
                    local offsetX = (i - 1) * (w + spacingX)
                    frame:ClearAllPoints()
                    frame:SetPoint("LEFT", _container, "LEFT", offsetX, 0)
                    frame:SetSize(w, h)
                end
            elseif growDir == "end" then
                for i, frame in ipairs(visibleIcons) do
                    local offsetX = -((i - 1) * (w + spacingX))
                    frame:ClearAllPoints()
                    frame:SetPoint("RIGHT", _container, "RIGHT", offsetX, 0)
                    frame:SetSize(w, h)
                end
            end
        else
            local totalW = count * w + (count - 1) * spacingX
            _container:SetSize(totalW, h)
            for i, frame in ipairs(visibleIcons) do
                local offsetX = (i - 1) * (w + spacingX)
                frame:ClearAllPoints()
                frame:SetPoint("LEFT", _container, "LEFT", offsetX, 0)
                frame:SetSize(w, h)
            end
        end
    else
        if config.dynamicLayout then
            local totalH = count * h + (count - 1) * spacingY
            _container:SetSize(w, totalH)

            if growDir == "center" then
                local startY = (totalH / 2) - h / 2
                for i, frame in ipairs(visibleIcons) do
                    local offsetY = startY - (i - 1) * (h + spacingY)
                    frame:ClearAllPoints()
                    frame:SetPoint("CENTER", _container, "CENTER", 0, offsetY)
                    frame:SetSize(w, h)
                end
            elseif growDir == "start" then
                for i, frame in ipairs(visibleIcons) do
                    local offsetY = -((i - 1) * (h + spacingY))
                    frame:ClearAllPoints()
                    frame:SetPoint("TOP", _container, "TOP", 0, offsetY)
                    frame:SetSize(w, h)
                end
            elseif growDir == "end" then
                for i, frame in ipairs(visibleIcons) do
                    local offsetY = (i - 1) * (h + spacingY)
                    frame:ClearAllPoints()
                    frame:SetPoint("BOTTOM", _container, "BOTTOM", 0, offsetY)
                    frame:SetSize(w, h)
                end
            end
        else
            local totalH = count * h + (count - 1) * spacingY
            _container:SetSize(w, totalH)
            for i, frame in ipairs(visibleIcons) do
                local offsetY = -((i - 1) * (h + spacingY))
                frame:ClearAllPoints()
                frame:SetPoint("TOP", _container, "TOP", 0, offsetY)
                frame:SetSize(w, h)
            end
        end
    end
end

-- =========================================================
-- SECTION 8: 事件监听
-- =========================================================

VFlow.on("PLAYER_ENTERING_WORLD", "OtherBuffMonitor", function()
    C_Timer.After(0, function()
        InitContainer()
        ScheduleActiveScan()
        ScanPassiveEntries()
    end)
end)

VFlow.on("PLAYER_EQUIPMENT_CHANGED", "OtherBuffMonitor", function(event, slotID)
    if slotID == 13 or slotID == 14 then
        ScheduleActiveScan()
    end
end)

VFlow.on("UNIT_SPELLCAST_SUCCEEDED", "OtherBuffMonitor", function(event, unit, _, spellID)
    if _activeIconPool[spellID] then
        ActivateActiveIcon(spellID)
    end
end, "player")

VFlow.on("SPELL_UPDATE_COOLDOWN", "OtherBuffMonitor", function(_, spellID)
    if spellID and _passiveIconPool[spellID] then
        TriggerPassive(spellID)
    end
end)

-- =========================================================
-- SECTION 9: Store / State 监听
-- =========================================================

VFlow.Store.watch(MODULE_KEY, "OtherBuffMonitor", function(key, value)
    if key:find("^trinketPotion%.") then
        if key:find("%.x$") or key:find("%.y$")
            or key == "trinketPotion.anchorFrame" or key == "trinketPotion.relativePoint" or key == "trinketPotion.playerAnchorPosition" then
            UpdateContainerPosition()
            return
        end

        if key == "trinketPotion.autoTrinkets" or
            key == "trinketPotion.itemIDs" or
            key == "trinketPotion.itemDurations" or
            key == "trinketPotion.spellIDs" or
            key == "trinketPotion.spellDurations" then
            ScheduleActiveScan()
            return
        end

        RefreshLayout()
        return
    end

    if key == "passiveBuff.spellIDs" or
        key == "passiveBuff.iconIDs" or
        key == "passiveBuff.spellDurations" or
        key == "passiveBuff.hasStacks" then
        ScanPassiveEntries()
    end
end)

VFlow.State.watch("isEditMode", "OtherBuffMonitor", function()
    RefreshLayout()
end)

-- =========================================================
-- SECTION 10: 公共接口
-- =========================================================

VFlow.OtherBuffMonitor = {
    parseDurationFromItem = function(itemID)
        local itemData = GetItemMonitorInfo(itemID)
        return itemData and itemData.duration or nil
    end,

    parseDurationFromSpell = function(spellID)
        local spellData = GetSpellMonitorInfo(spellID)
        return spellData and spellData.duration or nil
    end,

    resolveItemMonitorEntry = function(itemID, manualDuration)
        local itemData = GetItemMonitorInfo(itemID)
        if not itemData then
            return nil
        end
        if manualDuration and manualDuration > 0 then
            itemData.duration = manualDuration
        end
        return itemData
    end,

    resolveSpellMonitorEntry = function(spellID, manualDuration)
        local spellData = GetSpellMonitorInfo(spellID)
        if not spellData then
            return nil
        end
        if manualDuration and manualDuration > 0 then
            spellData.duration = manualDuration
        end
        return spellData
    end,

    getAutoDetectedItems = function()
        local items = {}
        for itemID, data in pairs(_autoDetectedItems) do
            table.insert(items, {
                itemID = itemID,
                spellID = data.spellID,
                icon = data.icon,
                duration = data.duration,
            })
        end
        table.sort(items, function(a, b) return a.itemID < b.itemID end)
        return items
    end,

    getPassiveDisplayName = GetPassiveDisplayName,
    refresh = RefreshLayout,
}

if Profiler and Profiler.registerScope then
    Profiler.registerScope("OBM:ScanActiveItems", function()
        return ScanActiveItems
    end, function(fn)
        ScanActiveItems = fn
    end)
    Profiler.registerScope("OBM:ScanPassiveEntries", function()
        return ScanPassiveEntries
    end, function(fn)
        ScanPassiveEntries = fn
    end)
    Profiler.registerScope("OBM:RefreshLayout", function()
        return RefreshLayout
    end, function(fn)
        RefreshLayout = fn
        VFlow.OtherBuffMonitor.refresh = fn
    end)
end
