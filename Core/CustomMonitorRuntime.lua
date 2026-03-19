-- =========================================================
-- VFlow CustomMonitorRuntime - 自定义图形监控运行时
-- 职责：在容器帧内创建真实的StatusBar并驱动动画
-- 支持：技能冷却/充能、BUFF持续时间、BUFF堆叠层数
--
-- 生命周期由 CustomMonitorGroups 驱动：
--   onContainerReady(storeKey, spellID, cfg, container)
--   onContainerDestroyed(storeKey, spellID)
-- Runtime 不监听 Store，消除与 Groups 的执行顺序竞争。
-- =========================================================

local VFlow = _G.VFlow
if not VFlow then return end

local MODULE_KEY = "VFlow.CustomMonitor"
local PP = VFlow.PixelPerfect  -- 完美像素工具
local Profiler = VFlow.Profiler

-- =========================================================
-- SECTION 1: 常量
-- =========================================================

local UPDATE_INTERVAL = 0.1
local MAP_RETRY_INTERVAL = 1.5
local INACTIVE_PROBE_INTERVAL = 0.4
local BAR_TEXTURE     = "Interface\\Buttons\\WHITE8X8"

local BUFF_VIEWERS = {
    "BuffIconCooldownViewer",
    "BuffBarCooldownViewer",
    "EssentialCooldownViewer",
    "UtilityCooldownViewer",
}

local INTERP_EASE_OUT = Enum.StatusBarInterpolation and Enum.StatusBarInterpolation.ExponentialEaseOut or 1

-- 环形纹理路径格式
local RING_TEXTURE_FMT = "Interface\\AddOns\\VFlow\\Assets\\Ring\\Ring_%spx.tga"

-- =========================================================
-- SECTION 2: 显示条件判断
-- =========================================================

-- 判断是否应该显示条
local function ShouldShowBar(cfg, isBuffActive)
    Profiler.count("CMR:ShouldShowBar")
    local mode = cfg.visibilityMode or "hide"
    local conditionMet = false

    -- 检查各个条件（任一条件满足即为true）
    if cfg.hideInCombat and VFlow.State.get("inCombat") then
        conditionMet = true
    end
    if cfg.hideOnMount and VFlow.State.get("isMounted") then
        conditionMet = true
    end
    if cfg.hideOnSkyriding and VFlow.State.get("isSkyriding") then
        conditionMet = true
    end
    if cfg.hideInSpecial and (VFlow.State.get("inVehicle") or VFlow.State.get("inPetBattle")) then
        conditionMet = true
    end
    if cfg.hideWhenInactive and not isBuffActive then
        conditionMet = true
    end

    -- 根据模式返回结果
    if mode == "show" then
        -- "仅...时显示"模式：条件满足时显示，否则隐藏
        return conditionMet
    else
        -- "仅...时隐藏"模式（默认）：条件满足时隐藏，否则显示
        return not conditionMet
    end
end

-- =========================================================
-- SECTION 2: 模块状态
-- =========================================================

-- { [spellID] = barFrame }
local _activeSkillBars    = {}
local _activeBuffBars     = {}
-- duration 条子集，避免 UNIT_AURA 遍历所有 buff bars
local _activeDurationBars = {}

-- spellID → cooldownID 映射（buff 监控专用）
local _spellToCooldownID = {}
-- cooldownID → CDM帧 缓存
local _cooldownIDToFrame = {}

-- CDM帧 Hook 管理
local _hookedFrames   = setmetatable({}, { __mode = "k" })  -- cdmFrame → { barIDs = {key→true} }
local _everHookedFrames = setmetatable({}, { __mode = "k" })
local _frameToBarKeys = setmetatable({}, { __mode = "k" })  -- cdmFrame → { barKey, ... }
-- aura key "unit#instanceID" → { barKey → true }（stacks 专用）
local _auraKeyToBars  = {}
local _barToAuraKey   = {}  -- barKey → aura key
local _spellMapRetryAt = {}

-- =========================================================
-- SECTION 3: 通用辅助
-- =========================================================

local function ConfigureStatusBar(bar)
    local tex = bar:GetStatusBarTexture()
    if tex then
        tex:SetSnapToPixelGrid(false)
        tex:SetTexelSnappingBias(0)
    end
end

local function ResolveBarTexture(name)
    if not name or name == "默认" then return BAR_TEXTURE end
    local LSM = LibStub and LibStub("LibSharedMedia-3.0", true)
    if LSM then
        local path = LSM:Fetch("statusbar", name)
        if path then return path end
    end
    return BAR_TEXTURE
end

local function SetRemainingText(text, durObj)
    local remaining
    pcall(function() remaining = durObj:GetRemainingDuration() end)
    if not remaining then text:SetText("") return end
    local ok = pcall(function()
        text:SetFormattedText("%.1f", remaining)
    end)
    if not ok then text:SetText("") end
end

local function FillDirection(fillMode)
    if fillMode == "fill" then
        return Enum.StatusBarTimerDirection and Enum.StatusBarTimerDirection.RemainingTime or 1
    end
    return Enum.StatusBarTimerDirection and Enum.StatusBarTimerDirection.ElapsedTime or 0
end

local INTERP_EASE_OUT = Enum.StatusBarInterpolation
    and Enum.StatusBarInterpolation.ExponentialEaseOut or 0

local function ApplyTimerDuration(seg, durObj, interpolation, direction)
    if not (durObj and seg.SetTimerDuration) then return false end
    seg:SetMinMaxValues(0, 1)
    seg:SetTimerDuration(durObj, interpolation, direction)
    if seg.SetToTargetValue then seg:SetToTargetValue() end
    return true
end

-- =========================================================
-- SECTION 4: ShadowCooldown（技能冷却用）
-- =========================================================

local function GetOrCreateShadowCooldown(barFrame)
    if barFrame._shadowCooldown then return barFrame._shadowCooldown end
    local cd = CreateFrame("Cooldown", nil, barFrame, "CooldownFrameTemplate")
    cd:SetAllPoints(barFrame)
    cd:SetDrawSwipe(false)
    cd:SetDrawEdge(false)
    cd:SetDrawBling(false)
    cd:SetHideCountdownNumbers(true)
    cd:SetAlpha(0)
    cd:EnableMouse(false)
    barFrame._shadowCooldown = cd
    return cd
end

-- =========================================================
-- SECTION 5: Arc Detector（堆叠层数 secret value 解码）
-- 原理：为每个阈值 i 创建不可见 StatusBar，SetMinMaxValues(i-1, i)。
--       SetValue(secretStacks) 后引擎内部比较决定是否填充纹理。
--       遍历 IsShown() 即可还原出整数层数。
-- =========================================================

local function GetArcDetector(barFrame, threshold)
    barFrame._arcDetectors = barFrame._arcDetectors or {}
    local det = barFrame._arcDetectors[threshold]
    if det then return det end
    det = CreateFrame("StatusBar", nil, barFrame)
    det:SetSize(1, 1)
    det:SetPoint("BOTTOMLEFT", barFrame, "BOTTOMLEFT", 0, 0)
    det:SetAlpha(0)
    det:SetStatusBarTexture(BAR_TEXTURE)
    det:SetMinMaxValues(threshold - 1, threshold)
    det:EnableMouse(false)
    ConfigureStatusBar(det)
    barFrame._arcDetectors[threshold] = det
    return det
end

local function FeedArcDetectors(barFrame, secretValue, maxVal)
    for i = 1, maxVal do
        GetArcDetector(barFrame, i):SetValue(secretValue)
    end
end

local function GetExactCount(barFrame, maxVal)
    if not barFrame._arcDetectors then return 0 end
    local count = 0
    for i = 1, maxVal do
        local det = barFrame._arcDetectors[i]
        if det and det:GetStatusBarTexture():IsShown() then
            count = i
        else
            break
        end
    end
    return count
end

-- =========================================================
-- SECTION 6: CDM 帧扫描 & spellID→cooldownID 映射
-- =========================================================

local function HasAuraInstanceID(value)
    if value == nil then return false end
    if issecretvalue and issecretvalue(value) then return true end
    if type(value) == "number" and value == 0 then return false end
    return true
end

local function GetCooldownIDFromFrame(frame)
    local cdID = frame.cooldownID
    if not cdID and frame.cooldownInfo then
        cdID = frame.cooldownInfo.cooldownID
    end
    return cdID
end

local function ResolveSpellID(info)
    if not info then return nil end
    local linked = info.linkedSpellIDs and info.linkedSpellIDs[1]
    return linked or info.overrideSpellID or (info.spellID and info.spellID > 0 and info.spellID) or nil
end

-- 从单个 CDM 帧注册映射（只追加，可在战斗中调用）
local function RegisterCDMFrame(frame)
    local cdID = GetCooldownIDFromFrame(frame)
    if not cdID then return end
    _cooldownIDToFrame[cdID] = frame
    local info = C_CooldownViewer.GetCooldownViewerCooldownInfo(cdID)
    if not info then return end
    local sid = ResolveSpellID(info)
    if sid and sid > 0 and not _spellToCooldownID[sid] then
        _spellToCooldownID[sid] = cdID
    end
    if info.linkedSpellIDs then
        for _, lid in ipairs(info.linkedSpellIDs) do
            if lid and lid > 0 and not _spellToCooldownID[lid] then
                _spellToCooldownID[lid] = cdID
            end
        end
    end
    if info.spellID and info.spellID > 0 and not _spellToCooldownID[info.spellID] then
        _spellToCooldownID[info.spellID] = cdID
    end
end

-- 全量扫描重建映射（仅脱战时调用，需要 wipe 清表）
local function ScanCDMViewers()
    if InCombatLockdown() then return end
    wipe(_spellToCooldownID)
    wipe(_cooldownIDToFrame)
    wipe(_spellMapRetryAt)
    for _, viewerName in ipairs(BUFF_VIEWERS) do
        local viewer = _G[viewerName]
        if viewer then
            if viewer.itemFramePool then
                for frame in viewer.itemFramePool:EnumerateActive() do RegisterCDMFrame(frame) end
            else
                for _, child in ipairs({ viewer:GetChildren() }) do RegisterCDMFrame(child) end
            end
        end
    end
end

-- 战斗中为单个 spellID 补建映射（只追加，找到即停）
-- 调用方负责检查 _spellToCooldownID[spellID] == nil 后再调用
local function TryMapSpellID(spellID)
    local now = GetTime and GetTime() or 0
    local retryAt = _spellMapRetryAt[spellID]
    if retryAt and now < retryAt then return end
    for _, viewerName in ipairs(BUFF_VIEWERS) do
        local viewer = _G[viewerName]
        if viewer then
            local function check(frame)
                local cdID = GetCooldownIDFromFrame(frame)
                if not cdID then return false end
                local info = C_CooldownViewer.GetCooldownViewerCooldownInfo(cdID)
                if not info then return false end
                local sid = ResolveSpellID(info)
                if sid == spellID or info.spellID == spellID then
                    RegisterCDMFrame(frame)
                    return true
                end
                if info.linkedSpellIDs then
                    for _, lid in ipairs(info.linkedSpellIDs) do
                        if lid == spellID then RegisterCDMFrame(frame); return true end
                    end
                end
                return false
            end
            if viewer.itemFramePool then
                for frame in viewer.itemFramePool:EnumerateActive() do
                    if check(frame) then
                        _spellMapRetryAt[spellID] = nil
                        return
                    end
                end
            else
                for _, child in ipairs({ viewer:GetChildren() }) do
                    if check(child) then
                        _spellMapRetryAt[spellID] = nil
                        return
                    end
                end
            end
        end
    end
    _spellMapRetryAt[spellID] = now + MAP_RETRY_INTERVAL
end

local function FindCDMFrame(cooldownID)
    if not cooldownID then return nil end
    local cached = _cooldownIDToFrame[cooldownID]
    if cached then return cached end
    for _, viewerName in ipairs(BUFF_VIEWERS) do
        local viewer = _G[viewerName]
        if viewer then
            if viewer.itemFramePool then
                for frame in viewer.itemFramePool:EnumerateActive() do
                    local cdID = GetCooldownIDFromFrame(frame)
                    if cdID == cooldownID then
                        _cooldownIDToFrame[cdID] = frame
                        return frame
                    end
                end
            else
                for _, child in ipairs({ viewer:GetChildren() }) do
                    local cdID = GetCooldownIDFromFrame(child)
                    if cdID == cooldownID then
                        _cooldownIDToFrame[cdID] = child
                        return child
                    end
                end
            end
        end
    end
    return nil
end

-- =========================================================
-- SECTION 7: Aura 追踪 & CDM Hook（stacks/duration 共用）
-- =========================================================

local function BuildAuraKey(unit, auraInstanceID)
    if not HasAuraInstanceID(auraInstanceID) then return nil end
    local u = (type(unit) == "string" and unit ~= "") and unit or "player"
    return u .. "#" .. tostring(auraInstanceID)
end

local function UnlinkBarFromAura(barKey)
    local oldAuraKey = _barToAuraKey[barKey]
    if not oldAuraKey then return end
    local bars = _auraKeyToBars[oldAuraKey]
    if bars then
        bars[barKey] = nil
        if not next(bars) then _auraKeyToBars[oldAuraKey] = nil end
    end
    _barToAuraKey[barKey] = nil
end

local function LinkBarToAura(barFrame, barKey, unit, auraInstanceID)
    local auraKey = BuildAuraKey(unit, auraInstanceID)
    if not auraKey then return end
    local oldKey = _barToAuraKey[barKey]
    if oldKey ~= auraKey then UnlinkBarFromAura(barKey) end
    if not _auraKeyToBars[auraKey] then _auraKeyToBars[auraKey] = {} end
    _auraKeyToBars[auraKey][barKey] = true
    _barToAuraKey[barKey] = auraKey
    barFrame._trackedAuraInstanceID = auraInstanceID
    barFrame._trackedUnit           = unit
end

-- 按优先级在多个单位上查找 aura（展开版，避免闭包分配）
local function GetAuraDataByInstanceID(auraInstanceID, preferredUnit, secondUnit)
    if not HasAuraInstanceID(auraInstanceID) then return nil, nil end
    local data
    if preferredUnit and preferredUnit ~= "" then
        data = C_UnitAuras.GetAuraDataByAuraInstanceID(preferredUnit, auraInstanceID)
        if data then return data, preferredUnit end
    end
    if secondUnit and secondUnit ~= "" and secondUnit ~= preferredUnit then
        data = C_UnitAuras.GetAuraDataByAuraInstanceID(secondUnit, auraInstanceID)
        if data then return data, secondUnit end
    end
    if preferredUnit ~= "player" and secondUnit ~= "player" then
        data = C_UnitAuras.GetAuraDataByAuraInstanceID("player", auraInstanceID)
        if data then return data, "player" end
    end
    if preferredUnit ~= "target" and secondUnit ~= "target" then
        data = C_UnitAuras.GetAuraDataByAuraInstanceID("target", auraInstanceID)
        if data then return data, "target" end
    end
    if preferredUnit ~= "pet" and secondUnit ~= "pet" then
        data = C_UnitAuras.GetAuraDataByAuraInstanceID("pet", auraInstanceID)
        if data then return data, "pet" end
    end
    return nil, nil
end

-- CDM 帧回调：当帧刷新时通知关联的 buff 监控条
local UpdateStackBar   -- 前向声明
local UpdateDurationBar

local function OnCDMFrameChanged(frame, ...)
    local auraInstanceID, auraUnit
    for i = 1, select("#", ...) do
        local v = select(i, ...)
        if not auraInstanceID and HasAuraInstanceID(v) then auraInstanceID = v end
        if not auraUnit and type(v) == "string" and v ~= "" then auraUnit = v end
    end

    local barKeys = _frameToBarKeys[frame]
    if not barKeys then return end

    for _, barKey in ipairs(barKeys) do
        local spellID  = tonumber(barKey:match("^buffs/(%d+)$"))
        local barFrame = spellID and _activeBuffBars[spellID]
        if barFrame then
            if barFrame._monitorType == "stacks" then
                if auraInstanceID then
                    local trackedUnit = auraUnit or frame.auraDataUnit
                        or barFrame._trackedUnit or "player"
                    LinkBarToAura(barFrame, barKey, trackedUnit, auraInstanceID)
                end
                UpdateStackBar(barFrame, spellID, barKey)
            end
        end
    end
end

local function HookCDMFrame(cdmFrame, barKey)
    if not cdmFrame then return end
    if not _hookedFrames[cdmFrame] then
        _hookedFrames[cdmFrame] = { barIDs = {} }
        _frameToBarKeys[cdmFrame] = {}
    end
    if not _everHookedFrames[cdmFrame] then
        if cdmFrame.RefreshData         then hooksecurefunc(cdmFrame, "RefreshData",         OnCDMFrameChanged) end
        if cdmFrame.RefreshApplications then hooksecurefunc(cdmFrame, "RefreshApplications", OnCDMFrameChanged) end
        if cdmFrame.SetAuraInstanceInfo then hooksecurefunc(cdmFrame, "SetAuraInstanceInfo",  OnCDMFrameChanged) end
        _everHookedFrames[cdmFrame] = true
    end
    if not _hookedFrames[cdmFrame].barIDs[barKey] then
        _hookedFrames[cdmFrame].barIDs[barKey] = true
        table.insert(_frameToBarKeys[cdmFrame], barKey)
    end
end

local function ClearAllHooks()
    for frame in pairs(_hookedFrames) do
        _hookedFrames[frame] = nil
        _frameToBarKeys[frame] = nil
    end
    wipe(_auraKeyToBars)
    wipe(_barToAuraKey)
    wipe(_spellToCooldownID)
    wipe(_cooldownIDToFrame)
    wipe(_spellMapRetryAt)
end

-- =========================================================
-- SECTION 8: StatusBar 分段创建（共用）
-- =========================================================

local function ClearSegments(barFrame)
    if barFrame._segments then
        for _, seg in ipairs(barFrame._segments) do seg:Hide(); seg:SetParent(nil) end
    end
    if barFrame._segBGs then
        for _, bg in ipairs(barFrame._segBGs) do bg:Hide(); bg:SetParent(nil) end
    end
    if barFrame._thresholdOverlays then
        for _, ov in ipairs(barFrame._thresholdOverlays) do ov:Hide(); ov:SetParent(nil) end
    end
    if barFrame._segFrames then
        for _, frame in ipairs(barFrame._segFrames) do frame:Hide(); frame:SetParent(nil) end
    end
    barFrame._segments          = {}
    barFrame._segBGs            = {}
    barFrame._thresholdOverlays = {}
    barFrame._segFrames         = {}
end

-- count=1 → 单段；count>1 → 多段（充能/stacks）
-- isStack=true 时启用阈值覆盖层
-- isRing=true 时创建环形（仅用于BUFF持续时间，单段）
local function CreateSegments(barFrame, count, cfg, isStack, isRing)
    ClearSegments(barFrame)
    if count < 1 then return end

    local segContainer = barFrame._segContainer
    local totalW, totalH = segContainer:GetSize()
    if totalW <= 0 then
        barFrame._segsDirty     = true
        barFrame._segsNeedCount = count
        return
    end

    -- 环形模式（仅BUFF持续时间）
    if isRing then
        local ringTexture = cfg.ringTexture or "10"
        local ringTex = string.format(RING_TEXTURE_FMT, ringTexture)
        local rc = cfg.ringColor or { r = 0.2, g = 0.6, b = 1, a = 1 }

        -- 背景环（使用环形纹理，深灰色）
        local bg = segContainer:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetTexture(ringTex)
        bg:SetVertexColor(0.1, 0.1, 0.1, 0.5)
        bg:Show()
        barFrame._segBGs[1] = bg

        -- 隐藏barFrame自身的矩形背景
        local barBG = barFrame.GetBackdrop and barFrame:GetBackdrop()
        local bgTex = barFrame.GetRegions and select(1, barFrame:GetRegions())
        if bgTex and bgTex.SetColorTexture then
            bgTex:SetColorTexture(0, 0, 0, 0)
        end

        -- 使用CooldownFrame作为进度显示
        local cd = CreateFrame("Cooldown", nil, segContainer, "CooldownFrameTemplate")
        cd:SetAllPoints()
        cd:SetDrawEdge(false)
        cd:SetDrawBling(false)
        cd:SetSwipeTexture(ringTex)
        cd:SetSwipeColor(rc.r, rc.g, rc.b, rc.a)
        cd:SetReverse(false)  -- 不反向：黑色遮罩从满到空消退，露出背景环
        cd:SetHideCountdownNumbers(true)
        cd:SetUseCircularEdge(false)
        cd:EnableMouse(false)
        cd:Show()
        cd._isRing = true
        cd._needsRefresh = true
        barFrame._segments[1] = cd

        barFrame._segsDirty = false
        barFrame._segsNeedCount = nil
        return
    end

    -- 条形模式（使用像素对齐计算）
    local borderThickness = tonumber(cfg.borderThickness) or 1
    local userGap = tonumber(cfg.segmentGap) or 0
    -- 实际间距 = 用户间距 - 边框厚度（让边框重合）
    local segmentGap = (count > 1) and (userGap - borderThickness) or 0
    local dir = cfg.barDirection or "horizontal"
    local tex = ResolveBarTexture(cfg.barTexture)
    local bc  = cfg.barColor or { r = 0.2, g = 0.6, b = 1, a = 1 }
    local borderColor = cfg.borderColor or { r = 0.3, g = 0.3, b = 0.3, a = 1 }

    -- 阈值配置（isStack 时读取）
    local t1 = isStack and (tonumber(cfg.stackThreshold1) or 0) or 0
    local t2 = isStack and (tonumber(cfg.stackThreshold2) or 0) or 0
    local c1 = cfg.stackColor1 or { r = 1, g = 0.5, b = 0, a = 1 }
    local c2 = cfg.stackColor2 or { r = 1, g = 0,   b = 0, a = 1 }

    -- 像素对齐计算
    local ppScale = PP.GetPixelScale()
    local function ToPixel(v) return math.floor(v / ppScale + 0.5) end
    local function ToLogical(px) return px * ppScale end

    local pxTotalW = ToPixel(totalW)
    local pxTotalH = ToPixel(totalH)
    local pxGap = ToPixel(segmentGap)

    -- 计算分段尺寸（处理余数分配）
    local pxSegW_Base, pxSegH_Base, pxRemainder
    if dir == "vertical" then
        pxSegW_Base = pxTotalW
        local pxAvailableH = math.max(0, pxTotalH - (count - 1) * pxGap)
        pxSegH_Base = math.floor(pxAvailableH / count)
        pxRemainder = pxAvailableH % count
    else
        pxSegH_Base = pxTotalH
        local pxAvailableW = math.max(0, pxTotalW - (count - 1) * pxGap)
        pxSegW_Base = math.floor(pxAvailableW / count)
        pxRemainder = pxAvailableW % count
    end

    local baseLevel = segContainer:GetFrameLevel()
    local currentPxOffset = 0

    for i = 1, count do
        -- 将余数像素分配给前几个分段
        local thisPxSegW, thisPxSegH
        if dir == "vertical" then
            thisPxSegW = pxSegW_Base
            thisPxSegH = pxSegH_Base
            if i <= pxRemainder then
                thisPxSegH = thisPxSegH + 1
            end
        else
            thisPxSegW = pxSegW_Base
            if i <= pxRemainder then
                thisPxSegW = thisPxSegW + 1
            end
            thisPxSegH = pxSegH_Base
        end

        local logOffset = ToLogical(currentPxOffset)
        local logSegW = ToLogical(thisPxSegW)
        local logSegH = ToLogical(thisPxSegH)

        local offsetX = (dir == "vertical") and 0 or logOffset
        local offsetY = (dir == "vertical") and logOffset or 0
        local anchor  = (dir == "vertical") and "BOTTOMLEFT" or "TOPLEFT"

        -- 创建段容器（用于应用边框）
        local segFrame = CreateFrame("Frame", nil, segContainer)
        segFrame:SetFrameLevel(baseLevel)
        segFrame:SetPoint(anchor, segContainer, anchor, offsetX, offsetY)
        PP.SetSize(segFrame, logSegW, logSegH)

        -- 更新下一个分段的偏移量
        if dir == "vertical" then
            currentPxOffset = currentPxOffset + thisPxSegH + pxGap
        else
            currentPxOffset = currentPxOffset + thisPxSegW + pxGap
        end

        local bg = segFrame:CreateTexture(nil, "BACKGROUND")
        bg:SetColorTexture(0.1, 0.1, 0.1, 0.5)
        bg:SetAllPoints(segFrame)

        local seg = CreateFrame("StatusBar", nil, segFrame)
        seg:SetStatusBarTexture(tex)
        seg:SetStatusBarColor(bc.r, bc.g, bc.b, bc.a)
        seg:SetValue(0)
        seg:EnableMouse(false)
        seg:SetFrameLevel(baseLevel + 1)
        seg:SetAllPoints(segFrame)
        ConfigureStatusBar(seg)

        if isStack then
            seg:SetMinMaxValues(i - 1, i)
            if dir == "vertical" and seg.SetFillStyle then
                seg:SetFillStyle(Enum.StatusBarFillStyle.Standard)
            end
        else
            seg:SetMinMaxValues(0, 1)
        end

        barFrame._segBGs[i]   = bg
        barFrame._segments[i] = seg
        barFrame._segFrames = barFrame._segFrames or {}
        barFrame._segFrames[i] = segFrame

        -- 阈值覆盖层
        if isStack then
            if t1 > 0 then
                local ov1 = CreateFrame("StatusBar", nil, segFrame)
                ov1:SetAllPoints(segFrame)
                ov1:SetStatusBarTexture(tex)
                ov1:SetStatusBarColor(c1.r, c1.g, c1.b, c1.a)
                ov1:SetValue(0)
                ov1:EnableMouse(false)
                ov1:SetFrameLevel(baseLevel + 2)
                ov1:SetMinMaxValues((i < t1) and (t1 - 1) or (i - 1), (i < t1) and t1 or i)
                ConfigureStatusBar(ov1)
                table.insert(barFrame._thresholdOverlays, ov1)
            end
            if t2 > 0 then
                local ov2 = CreateFrame("StatusBar", nil, segFrame)
                ov2:SetAllPoints(segFrame)
                ov2:SetStatusBarTexture(tex)
                ov2:SetStatusBarColor(c2.r, c2.g, c2.b, c2.a)
                ov2:SetValue(0)
                ov2:EnableMouse(false)
                ov2:SetFrameLevel(baseLevel + 3)
                ov2:SetMinMaxValues((i < t2) and (t2 - 1) or (i - 1), (i < t2) and t2 or i)
                ConfigureStatusBar(ov2)
                table.insert(barFrame._thresholdOverlays, ov2)
            end
        end

        -- 创建边框Frame（在所有内容之上）
        local borderFrame = CreateFrame("Frame", nil, segFrame)
        borderFrame:SetFrameLevel(baseLevel + 4)
        borderFrame:SetAllPoints(segFrame)
        borderFrame:EnableMouse(false)
        PP.CreateBorder(borderFrame, borderThickness, borderColor, true)
    end

    barFrame._segsDirty     = false
    barFrame._segsNeedCount = nil
end

-- 将层数值同时设给基础分段和阈值覆盖层
local function SetStackSegmentsValue(barFrame, value)
    for _, seg in ipairs(barFrame._segments) do seg:SetValue(value) end
    for _, ov  in ipairs(barFrame._thresholdOverlays) do ov:SetValue(value) end
end

-- =========================================================
-- SECTION 9: 技能冷却/充能 更新逻辑
-- =========================================================

local function UpdateRegularCooldownBar(barFrame, spellID)
    local cfg = barFrame._cfg
    local isOnGCD = false
    pcall(function()
        local info = C_Spell.GetSpellCooldown(spellID)
        if info and info.isOnGCD then isOnGCD = true end
    end)

    local shadowCD = GetOrCreateShadowCooldown(barFrame)
    local durObj
    if isOnGCD then
        shadowCD:SetCooldown(0, 0)
    else
        pcall(function() durObj = C_Spell.GetSpellCooldownDuration(spellID) end)
        if durObj then
            shadowCD:Clear()
            pcall(function() shadowCD:SetCooldownFromDurationObject(durObj, true) end)
        else
            shadowCD:SetCooldown(0, 0)
        end
    end

    local isOnCooldown = shadowCD:IsShown()

    if not barFrame._segments or #barFrame._segments ~= 1 then
        CreateSegments(barFrame, 1, cfg)
    end
    local seg = barFrame._segments and barFrame._segments[1]
    if not seg then return end

    -- 根据冷却状态设置颜色
    if isOnCooldown and not isOnGCD and durObj then
        -- 冷却中：使用rechargeColor（冷却中颜色）
        local rc = cfg.rechargeColor or cfg.barColor
        seg:SetStatusBarColor(rc.r, rc.g, rc.b, rc.a)
        local dir = FillDirection(cfg.barFillMode)
        if not ApplyTimerDuration(seg, durObj, INTERP_EASE_OUT, dir) then
            seg:SetValue(0)
        end
        barFrame._lastFillMode = cfg.barFillMode
        if barFrame._text then SetRemainingText(barFrame._text, durObj) end
    else
        -- 就绪时：使用barColor（就绪时颜色）
        seg:SetStatusBarColor(cfg.barColor.r, cfg.barColor.g, cfg.barColor.b, cfg.barColor.a)
        seg:SetMinMaxValues(0, 1)
        seg:SetValue(1)
        if barFrame._text then barFrame._text:SetText("") end
    end
end

local function UpdateChargeBar(barFrame, spellID)
    local cfg = barFrame._cfg

    -- 使用配置中预先判断的技能类型
    if not cfg.isChargeSpell then
        UpdateRegularCooldownBar(barFrame, spellID)
        return
    end

    if barFrame._needsChargeRefresh then
        barFrame._cachedChargeInfo   = C_Spell.GetSpellCharges(spellID)
        barFrame._needsChargeRefresh = false
    end

    local chargeInfo = barFrame._cachedChargeInfo
    if not chargeInfo then return end

    local currentCharges = chargeInfo.currentCharges
    local maxCharges = chargeInfo.maxCharges

    -- 缓存非secret的maxCharges值，战斗中可能需要fallback
    if not (issecretvalue and issecretvalue(maxCharges)) then
        barFrame._cachedMaxCharges = maxCharges
    else
        local cached = barFrame._cachedMaxCharges
        if cached and cached > 0 then
            maxCharges = cached
        end
    end

    -- 如果maxCharges仍是secret或无效，无法设置条
    if issecretvalue and issecretvalue(maxCharges) then return end
    if not maxCharges or maxCharges < 1 then return end

    -- 创建背景层（显示未充能部分）
    if not barFrame._chargeBG then
        local bg = barFrame._segContainer:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints(barFrame._segContainer)
        bg:SetColorTexture(0.1, 0.1, 0.1, 0.5)
        barFrame._chargeBG = bg
    end

    -- 设置主充能条（显示已有充能数）
    if not barFrame._chargeBar then
        local chargeBar = CreateFrame("StatusBar", nil, barFrame._segContainer)
        chargeBar:SetStatusBarTexture(ResolveBarTexture(cfg.barTexture))
        chargeBar:SetAllPoints(barFrame._segContainer)
        chargeBar:SetFrameLevel(barFrame._segContainer:GetFrameLevel() + 1)
        ConfigureStatusBar(chargeBar)
        barFrame._chargeBar = chargeBar
    end

    -- 每次更新颜色（配置可能变化）
    barFrame._chargeBar:SetStatusBarColor(cfg.barColor.r, cfg.barColor.g, cfg.barColor.b, cfg.barColor.a)
    barFrame._chargeBar:SetMinMaxValues(0, maxCharges)
    barFrame._chargeBar:SetValue(currentCharges)

    -- 设置充能进度条（显示正在充能的进度）
    if not barFrame._refreshCharge then
        local refreshCharge = CreateFrame("StatusBar", nil, barFrame._segContainer)
        refreshCharge:SetStatusBarTexture(ResolveBarTexture(cfg.barTexture))
        refreshCharge:SetPoint("LEFT", barFrame._chargeBar:GetStatusBarTexture(), "RIGHT")
        ConfigureStatusBar(refreshCharge)
        barFrame._refreshCharge = refreshCharge
    end

    if not barFrame._refreshChargeText then
        local tf = cfg.timerFont or {}
        local fc = tf.color or { r = 1, g = 1, b = 1, a = 1 }
        local txt = barFrame._refreshCharge:CreateFontString(nil, "OVERLAY")
        txt:SetAllPoints(barFrame._refreshCharge)
        txt:SetJustifyH("CENTER")
        txt:SetFont(
            VFlow.UI.resolveFontPath(tf.font),
            tf.size or 14,
            tf.outline or "OUTLINE"
        )
        txt:SetTextColor(fc.r, fc.g, fc.b, fc.a)
        barFrame._refreshChargeText = txt
    end

    -- 每次更新颜色（配置可能变化）
    local rc = cfg.rechargeColor or { r = 0.5, g = 0.8, b = 1, a = 1 }
    barFrame._refreshCharge:SetStatusBarColor(rc.r, rc.g, rc.b, rc.a)

    -- 计算每个充能的宽度，设置refreshCharge的尺寸
    local totalW = barFrame._segContainer:GetWidth()
    local totalH = barFrame._segContainer:GetHeight()
    if totalW > 0 and totalH > 0 then
        local chargeWidth = totalW / maxCharges
        barFrame._refreshCharge:SetSize(chargeWidth, totalH)
    end

    -- 使用SetTimerDuration设置充能进度动画
    local chargeDurObj = nil
    pcall(function() chargeDurObj = C_Spell.GetSpellChargeDuration(spellID) end)
    pcall(function()
        barFrame._refreshCharge:SetTimerDuration(
            chargeDurObj,
            Enum.StatusBarInterpolation.Immediate or 0,
            Enum.StatusBarTimerDirection.ElapsedTime or 0
        )
    end)

    local activeChargeDurObj = nil
    if barFrame._refreshCharge.GetTimerDuration then
        activeChargeDurObj = barFrame._refreshCharge:GetTimerDuration()
    end

    local shouldShowRecharge = (chargeDurObj ~= nil) and (activeChargeDurObj ~= nil)

    if shouldShowRecharge then
        barFrame._refreshCharge:Show()
    else
        barFrame._refreshCharge:Hide()
    end

    -- 创建分隔线（使用完美像素边框）- 边框重合自动形成分隔线
    local borderThickness = tonumber(cfg.borderThickness) or 1
    if maxCharges > 1 and borderThickness > 0 then
        barFrame._chargeBorders = barFrame._chargeBorders or {}
        -- 清理多余的边框
        for i = maxCharges + 1, #barFrame._chargeBorders do
            if barFrame._chargeBorders[i] then
                PP.HideBorder(barFrame._chargeBorders[i])
                barFrame._chargeBorders[i]:Hide()
                barFrame._chargeBorders[i] = nil
            end
        end
        -- 创建或更新每段的边框容器
        if totalW > 0 and totalH > 0 then
            -- 应用segmentGap配置和像素对齐
            local userGap = tonumber(cfg.segmentGap) or 0
            local segmentGap = userGap - borderThickness

            -- 像素对齐计算
            local ppScale = PP.GetPixelScale()
            local function ToPixel(v) return math.floor(v / ppScale + 0.5) end
            local function ToLogical(px) return px * ppScale end

            local pxTotalW = ToPixel(totalW)
            local pxTotalH = ToPixel(totalH)
            local pxGap = ToPixel(segmentGap)

            -- 计算分段宽度（处理余数分配）
            local pxAvailableW = math.max(0, pxTotalW - (maxCharges - 1) * pxGap)
            local pxSegW_Base = math.floor(pxAvailableW / maxCharges)
            local pxRemainder = pxAvailableW % maxCharges

            local bc = cfg.borderColor or { r = 0.3, g = 0.3, b = 0.3, a = 1 }
            local currentPxOffset = 0

            for i = 1, maxCharges do
                -- 将余数像素分配给前几个分段
                local thisPxSegW = pxSegW_Base
                if i <= pxRemainder then
                    thisPxSegW = thisPxSegW + 1
                end

                local logOffset = ToLogical(currentPxOffset)
                local logSegW = ToLogical(thisPxSegW)

                if not barFrame._chargeBorders[i] then
                    local borderFrame = CreateFrame("Frame", nil, barFrame._segContainer)
                    borderFrame:SetFrameLevel(barFrame._segContainer:GetFrameLevel() + 10)
                    barFrame._chargeBorders[i] = borderFrame
                end
                local borderFrame = barFrame._chargeBorders[i]
                borderFrame:ClearAllPoints()
                borderFrame:SetPoint("LEFT", barFrame._segContainer, "LEFT", logOffset, 0)
                PP.SetSize(borderFrame, logSegW, totalH)
                local needRebuild = (not borderFrame._vfBorderThickness)
                    or (borderFrame._vfBorderThickness ~= borderThickness)
                    or (borderFrame._vfBorderW ~= logSegW)
                    or (borderFrame._vfBorderH ~= totalH)
                if needRebuild then
                    PP.CreateBorder(borderFrame, borderThickness, bc, true)
                    borderFrame._vfBorderThickness = borderThickness
                    borderFrame._vfBorderW = logSegW
                    borderFrame._vfBorderH = totalH
                    borderFrame._vfBorderColor = {
                        r = bc.r or 1,
                        g = bc.g or 1,
                        b = bc.b or 1,
                        a = bc.a or 1,
                    }
                else
                    local last = borderFrame._vfBorderColor
                    local r = bc.r or 1
                    local g = bc.g or 1
                    local b = bc.b or 1
                    local a = bc.a or 1
                    if (not last)
                        or (last.r ~= r)
                        or (last.g ~= g)
                        or (last.b ~= b)
                        or (last.a ~= a) then
                        PP.UpdateBorderColor(borderFrame, bc)
                        borderFrame._vfBorderColor = { r = r, g = g, b = b, a = a }
                    end
                end
                borderFrame:Show()

                -- 更新下一个分段的偏移量
                currentPxOffset = currentPxOffset + thisPxSegW + pxGap
            end
        end
    else
        -- 隐藏所有边框
        if barFrame._chargeBorders then
            for _, borderFrame in ipairs(barFrame._chargeBorders) do
                PP.HideBorder(borderFrame)
                borderFrame:Hide()
            end
        end
    end

    -- 更新文字显示
    if barFrame._text then
        barFrame._text:SetText("")
    end
    if barFrame._refreshChargeText then
        if shouldShowRecharge then
            SetRemainingText(barFrame._refreshChargeText, activeChargeDurObj)
        else
            barFrame._refreshChargeText:SetText("")
        end
    end
end

-- =========================================================
-- SECTION 10: BUFF 持续时间更新逻辑
-- =========================================================

UpdateDurationBar = function(barFrame, spellID, barKey)
    local cfg = barFrame._cfg

    -- 若尚未有映射，尝试补建（找到后不再重复查，barKey 已缓存在 barFrame 上）
    if not _spellToCooldownID[spellID] then
        TryMapSpellID(spellID)
    end

    local auraActive     = false
    local auraInstanceID = nil
    local unit           = nil

    -- 路径1：CDM 帧
    local cooldownID = _spellToCooldownID[spellID]
    if cooldownID then
        local cdmFrame = FindCDMFrame(cooldownID)
        if cdmFrame then
            HookCDMFrame(cdmFrame, barKey)
            if HasAuraInstanceID(cdmFrame.auraInstanceID) then
                auraActive     = true
                auraInstanceID = cdmFrame.auraInstanceID
                unit           = cdmFrame.auraDataUnit or "player"
                barFrame._trackedAuraInstanceID = auraInstanceID
                barFrame._trackedUnit           = unit
            end
        end
    end

    -- 路径2：上次记录的 auraInstanceID
    if not auraActive and HasAuraInstanceID(barFrame._trackedAuraInstanceID) then
        local d
        d = C_UnitAuras.GetAuraDataByAuraInstanceID("player", barFrame._trackedAuraInstanceID)
        if d then
            unit = "player"
        else
            d = C_UnitAuras.GetAuraDataByAuraInstanceID("target", barFrame._trackedAuraInstanceID)
            if d then unit = "target" end
        end
        if d then
            auraActive     = true
            auraInstanceID = barFrame._trackedAuraInstanceID
            barFrame._trackedUnit = unit
        end
    end

    -- 路径3：按 spellID 直接扫描（首次触发/CDM 尚未激活时兜底）
    -- 战斗中 spellId 是 secret value，pcall 比较失败时直接退出循环
    if not auraActive then
        for _, scanUnit in ipairs({ "player", "target", "pet" }) do
            local auraData
            if C_UnitAuras.GetPlayerAuraBySpellID and scanUnit == "player" then
                auraData = C_UnitAuras.GetPlayerAuraBySpellID(spellID)
            end
            if not auraData then
                local index = 1
                while true do
                    local data = C_UnitAuras.GetAuraDataByIndex(scanUnit, index)
                    if not data then break end
                    local matched = false
                    local ok = pcall(function() matched = (data.spellId == spellID) end)
                    if not ok then break end  -- secret value，战斗中放弃
                    if matched then auraData = data; break end
                    index = index + 1
                end
            end
            if auraData and HasAuraInstanceID(auraData.auraInstanceID) then
                unit           = scanUnit
                auraInstanceID = auraData.auraInstanceID
                auraActive     = true
                barFrame._trackedAuraInstanceID = auraInstanceID
                barFrame._trackedUnit           = unit
                break
            end
        end
    end

    -- 判断是否为环形
    local isRing = (cfg.shape == "ring")

    -- 检测形状变化，强制重建
    local needRebuild = false
    if barFrame._segments and #barFrame._segments == 1 then
        local seg = barFrame._segments[1]
        if isRing and not seg._isRing then
            needRebuild = true  -- 从条形切换到环形
        elseif not isRing and seg._isRing then
            needRebuild = true  -- 从环形切换到条形
        end
    end

    -- 单段
    if not barFrame._segments or #barFrame._segments ~= 1 or needRebuild then
        CreateSegments(barFrame, 1, cfg, false, isRing)
    end
    local seg = barFrame._segments and barFrame._segments[1]
    if not seg then return end

    if auraActive and auraInstanceID and unit then
        barFrame._lastKnownActive = true

        if isRing and seg._isRing then
            -- 环形模式：只在需要刷新时更新，避免重复SetCooldown导致动画重置
            if seg._needsRefresh then
                local durObj = C_UnitAuras.GetAuraDuration(unit, auraInstanceID)
                if durObj then
                    if seg.SetCooldownFromDurationObject then
                        seg:SetCooldownFromDurationObject(durObj)
                    else
                        local start    = durObj:GetCooldownStartTime()
                        local duration = durObj:GetCooldownDuration()
                        if start and duration and duration > 0 then
                            seg:SetCooldown(start, duration)
                        end
                    end
                    -- 每帧更新颜色
                    local rc = cfg.ringColor or { r = 0.2, g = 0.6, b = 1, a = 1 }
                    seg:SetSwipeColor(rc.r, rc.g, rc.b, rc.a)
                    seg._needsRefresh = false
                end
            end
            if barFrame._text then
                local durObj = C_UnitAuras.GetAuraDuration(unit, auraInstanceID)
                if durObj then SetRemainingText(barFrame._text, durObj)
                else barFrame._text:SetText("") end
            end
        else
            -- 条形模式：使用StatusBar
            local timerOK = pcall(function()
                local durObj = C_UnitAuras.GetAuraDuration(unit, auraInstanceID)
                if not durObj then return end
                ApplyTimerDuration(seg, durObj, INTERP_EASE_OUT, FillDirection(cfg.barFillMode))
                barFrame._lastFillMode = cfg.barFillMode
                if barFrame._text then SetRemainingText(barFrame._text, durObj) end
            end)
            if not timerOK then
                seg:SetMinMaxValues(0, 1); seg:SetValue(1)
                if barFrame._text then barFrame._text:SetText("") end
            end
        end
    else
        barFrame._lastKnownActive = false
        barFrame._trackedAuraInstanceID = nil
        barFrame._trackedUnit           = nil

        if isRing and seg._isRing then
            seg:SetCooldown(0, 0)  -- 清除进度
            seg._needsRefresh = true  -- 下次激活时重新设置
        else
            seg:SetMinMaxValues(0, 1); seg:SetValue(0)
        end
        if barFrame._text then barFrame._text:SetText("") end
    end
end

-- =========================================================
-- SECTION 11: BUFF 堆叠层数更新逻辑
-- =========================================================

UpdateStackBar = function(barFrame, spellID, barKey)
    local cfg       = barFrame._cfg
    local maxStacks = tonumber(cfg.maxStacks) or 5
    if maxStacks < 1 then maxStacks = 1 end

    local stacks     = 0
    local auraActive = false

    if not _spellToCooldownID[spellID] then
        TryMapSpellID(spellID)
    end

    local cooldownID = _spellToCooldownID[spellID]
    if cooldownID then
        local cdmFrame = FindCDMFrame(cooldownID)
        if cdmFrame then
            HookCDMFrame(cdmFrame, barKey)
            if HasAuraInstanceID(cdmFrame.auraInstanceID) then
                local baseUnit = cdmFrame.auraDataUnit or barFrame._trackedUnit or "player"
                local auraData, trackedUnit = GetAuraDataByInstanceID(
                    cdmFrame.auraInstanceID, baseUnit, barFrame._trackedUnit)
                LinkBarToAura(barFrame, barKey, trackedUnit or baseUnit, cdmFrame.auraInstanceID)
                if auraData then
                    auraActive = true
                    stacks     = auraData.applications or 0
                end
            end
        end
    end

    if not auraActive and HasAuraInstanceID(barFrame._trackedAuraInstanceID) then
        local auraData, trackedUnit = GetAuraDataByInstanceID(
            barFrame._trackedAuraInstanceID, barFrame._trackedUnit, nil)
        if auraData then
            auraActive = true
            stacks     = auraData.applications or 0
            if trackedUnit then
                LinkBarToAura(barFrame, barKey, trackedUnit, barFrame._trackedAuraInstanceID)
            end
        end
    end

    if not auraActive then
        if barFrame._lastKnownActive then
            barFrame._nilCount = (barFrame._nilCount or 0) + 1
            if barFrame._nilCount > 5 then
                barFrame._lastKnownActive       = false
                barFrame._lastKnownStacks       = 0
                barFrame._trackedAuraInstanceID = nil
                barFrame._trackedUnit           = nil
                UnlinkBarFromAura(barKey)
                stacks = 0
            else
                return  -- 冻结显示，等待 CDM 确认
            end
        end
    else
        barFrame._nilCount = 0
    end

    if not barFrame._segments or #barFrame._segments ~= maxStacks then
        CreateSegments(barFrame, maxStacks, cfg, true)
    end
    if not barFrame._segments then return end

    local isSecret = issecretvalue and issecretvalue(stacks)

    if isSecret then
        SetStackSegmentsValue(barFrame, stacks)
        FeedArcDetectors(barFrame, stacks, maxStacks)
        local resolved = GetExactCount(barFrame, maxStacks)
        if type(resolved) == "number" then
            barFrame._lastKnownStacks = resolved
        end
    else
        if barFrame._arcDetectors then
            for i = 1, maxStacks do
                local det = barFrame._arcDetectors[i]
                if det then det:SetValue(0) end
            end
        end
        SetStackSegmentsValue(barFrame, stacks)
    end

    if auraActive then
        barFrame._lastKnownActive = true
        if not isSecret and type(stacks) == "number" then
            barFrame._lastKnownStacks = stacks
        end
    end

    if barFrame._text then
        if isSecret then
            barFrame._text:SetText(stacks)
        else
            barFrame._text:SetText(tostring(stacks))
        end
    end
end

-- =========================================================
-- SECTION 12: 条形帧创建（技能/buff 共用）
-- =========================================================

local function CreateBarFrame(spellID, cfg, container)
    if container._bar then container._bar:Hide() end

    local barFrame = CreateFrame("Frame", nil, container)
    barFrame:SetAllPoints(container)
    barFrame:SetFrameStrata(container:GetFrameStrata())
    barFrame:SetFrameLevel(container:GetFrameLevel() + 1)

    local bg = barFrame:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    -- 环形模式下隐藏矩形背景（环形纹理自带透明通道）
    if cfg.shape == "ring" then
        bg:SetColorTexture(0, 0, 0, 0)
    else
        bg:SetColorTexture(0.1, 0.1, 0.1, 0.5)
    end
    barFrame._bg = bg

    if cfg.showIcon ~= false then
        local iconFrame = CreateFrame("Frame", nil, container)
        iconFrame:SetFrameStrata(container:GetFrameStrata())
        local iconSize  = cfg.iconSize or 20
        iconFrame:SetSize(iconSize, iconSize)
        local pos = cfg.iconPosition or "LEFT"
        local ox  = cfg.iconOffsetX  or 0
        local oy  = cfg.iconOffsetY  or 0
        local iconAnchor, relAnchor
        if     pos == "LEFT"  then iconAnchor, relAnchor = "RIGHT",  "LEFT"
        elseif pos == "RIGHT" then iconAnchor, relAnchor = "LEFT",   "RIGHT"
        elseif pos == "TOP"   then iconAnchor, relAnchor = "BOTTOM", "TOP"
        else                       iconAnchor, relAnchor = "TOP",    "BOTTOM"
        end
        iconFrame:SetPoint(iconAnchor, container, relAnchor, ox, oy)
        local si = C_Spell.GetSpellInfo(spellID)
        if si and si.iconID then
            local t = iconFrame:CreateTexture(nil, "ARTWORK")
            t:SetAllPoints()
            t:SetTexture(si.iconID)
            t:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        end
        barFrame._iconFrame = iconFrame
    end

    local segContainer = CreateFrame("Frame", nil, barFrame)
    segContainer:SetAllPoints(barFrame)
    segContainer:SetFrameLevel(barFrame:GetFrameLevel() + 1)
    segContainer:EnableMouse(false)
    segContainer:SetClipsChildren(true)  -- 裁剪超出容器的子元素（充能条关键）
    barFrame._segContainer = segContainer

    local textHolder = CreateFrame("Frame", nil, barFrame)
    textHolder:SetAllPoints(barFrame)
    textHolder:SetFrameLevel(barFrame:GetFrameLevel() + 6)
    textHolder:EnableMouse(false)

    local tf      = cfg.timerFont or {}
    local fc      = tf.color or { r = 1, g = 1, b = 1, a = 1 }
    local tAnchor = tf.position or "CENTER"

    barFrame._text = textHolder:CreateFontString(nil, "OVERLAY")
    barFrame._text:SetFont(
        VFlow.UI.resolveFontPath(tf.font),
        tf.size    or 14,
        tf.outline or "OUTLINE"
    )
    barFrame._text:SetTextColor(fc.r, fc.g, fc.b, fc.a)
    barFrame._text:SetPoint(tAnchor, textHolder, tAnchor, tf.offsetX or 0, tf.offsetY or 0)
    barFrame._text:SetJustifyH("CENTER")

    barFrame._cfg                  = cfg
    barFrame._spellID              = spellID
    barFrame._segments             = {}
    barFrame._segBGs               = {}
    barFrame._thresholdOverlays    = {}
    barFrame._arcDetectors         = nil
    barFrame._shadowCooldown       = nil
    -- 技能冷却/充能
    barFrame._cachedChargeInfo     = nil
    barFrame._cachedMaxCharges     = 0
    barFrame._needsChargeRefresh   = true
    barFrame._lastFillMode         = nil
    barFrame._chargeBar            = nil  -- OctoChargeBar方案：主充能条
    barFrame._refreshCharge        = nil  -- OctoChargeBar方案：充能进度条
    barFrame._chargeBorders        = nil  -- OctoChargeBar方案：边框容器
    -- buff 堆叠
    barFrame._lastKnownActive      = false
    barFrame._lastKnownStacks      = 0
    barFrame._nilCount             = 0
    barFrame._trackedAuraInstanceID = nil
    barFrame._trackedUnit          = nil
    -- 通用
    barFrame._segsDirty            = false
    barFrame._segsNeedCount        = nil

    return barFrame
end

-- =========================================================
-- SECTION 13: 生命周期管理
-- =========================================================

local function DestroyBar(storeKey, spellID)
    local tbl    = (storeKey == "skills") and _activeSkillBars or _activeBuffBars
    local barFrame = tbl[spellID]
    if not barFrame then return end

    if storeKey == "buffs" then
        local barKey = "buffs/" .. spellID
        UnlinkBarFromAura(barKey)
        _activeDurationBars[spellID] = nil
    end

    local container = barFrame:GetParent()
    if container and container._bar then container._bar:Show() end

    ClearSegments(barFrame)

    -- 清理充能条相关帧
    if barFrame._chargeBG then
        barFrame._chargeBG:Hide()
        barFrame._chargeBG = nil
    end
    if barFrame._chargeBar then
        barFrame._chargeBar:Hide()
        barFrame._chargeBar:SetParent(nil)
        barFrame._chargeBar = nil
    end
    if barFrame._refreshCharge then
        barFrame._refreshCharge:Hide()
        barFrame._refreshCharge:SetParent(nil)
        barFrame._refreshCharge = nil
        barFrame._refreshChargeText = nil
    end
    if barFrame._chargeBorders then
        for _, borderFrame in ipairs(barFrame._chargeBorders) do
            PP.HideBorder(borderFrame)
            borderFrame:Hide()
            borderFrame:SetParent(nil)
        end
        barFrame._chargeBorders = nil
    end

    barFrame:Hide()
    barFrame:SetParent(nil)
    if barFrame._iconFrame then
        barFrame._iconFrame:Hide()
        barFrame._iconFrame:SetParent(nil)
    end
    tbl[spellID] = nil
end

local function EnsureBar(storeKey, spellID, cfg, container)
    local tbl = (storeKey == "skills") and _activeSkillBars or _activeBuffBars
    if tbl[spellID] then DestroyBar(storeKey, spellID) end

    local barFrame = CreateBarFrame(spellID, cfg, container)
    barFrame._container = container  -- 存储容器引用，用于显示/隐藏
    if storeKey == "buffs" then
        local monitorType = cfg.monitorType or "duration"
        barFrame._monitorType = monitorType
        -- 缓存 barKey，避免每次 tick 拼字符串
        barFrame._barKey = "buffs/" .. spellID
        if monitorType == "duration" then
            _activeDurationBars[spellID] = barFrame
        end
    end
    tbl[spellID] = barFrame

    barFrame._segsDirty     = true
    barFrame._segsNeedCount = 1
    barFrame:Show()
end

-- =========================================================
-- SECTION 14: OnUpdate 主循环
-- =========================================================

local _elapsed = 0

local function UpdateAllBars()
    for spellID, barFrame in pairs(_activeSkillBars) do
        -- 检查显示条件
        local shouldShow = ShouldShowBar(barFrame._cfg, false)
        local container = barFrame._container

        if not shouldShow then
            if container then container:Hide() end
        else
            if container then container:Show() end

            -- 使用配置中的isChargeSpell判断
            if not barFrame._cfg.isChargeSpell then
                -- 普通冷却条需要检查_segsDirty
                if barFrame._segsDirty then
                    local cw = barFrame._segContainer:GetWidth()
                    if cw and cw > 0 then
                        CreateSegments(barFrame, barFrame._segsNeedCount or 1, barFrame._cfg)
                    end
                end
                UpdateRegularCooldownBar(barFrame, spellID)
            else
                -- 充能条直接更新
                UpdateChargeBar(barFrame, spellID)
            end
        end
    end

    for spellID, barFrame in pairs(_activeBuffBars) do
        local cfg = barFrame._cfg
        local isBuffActive = barFrame._lastKnownActive or false
        local doUpdate = true
        if cfg.hideWhenInactive and not isBuffActive and not barFrame._segsDirty then
            local now = GetTime and GetTime() or 0
            local nextProbeAt = barFrame._nextInactiveProbeAt or 0
            if now < nextProbeAt then
                doUpdate = false
            else
                barFrame._nextInactiveProbeAt = now + INACTIVE_PROBE_INTERVAL
            end
        else
            barFrame._nextInactiveProbeAt = nil
        end
        if doUpdate then
            if barFrame._segsDirty then
                local cw = barFrame._segContainer:GetWidth()
                if cw and cw > 0 then
                    CreateSegments(barFrame, barFrame._segsNeedCount or 1, cfg,
                        barFrame._monitorType == "stacks")
                end
            end
            if barFrame._monitorType == "stacks" then
                UpdateStackBar(barFrame, spellID, barFrame._barKey)
            else
                UpdateDurationBar(barFrame, spellID, barFrame._barKey)
            end
            isBuffActive = barFrame._lastKnownActive or false
        end
        local shouldShow = ShouldShowBar(cfg, isBuffActive)
        local container = barFrame._container

        if not shouldShow then
            if container then container:Hide() end
        else
            if container then container:Show() end
        end
    end
end

local _updateFrame = CreateFrame("Frame")
_updateFrame:SetScript("OnUpdate", function(_, dt)
    _elapsed = _elapsed + dt
    if _elapsed < UPDATE_INTERVAL then return end
    _elapsed = 0
    local _pt = Profiler.start("CMR:UpdateAllBars")
    UpdateAllBars()
    Profiler.stop(_pt)
end)
_updateFrame:Hide()

-- =========================================================
-- SECTION 15: 事件响应
-- =========================================================

VFlow.on("PLAYER_ENTERING_WORLD", "CustomMonitorRuntime", function()
    C_Timer.After(1.6, function()
        if next(_activeSkillBars) or next(_activeBuffBars) then
            _updateFrame:Show()
        end
    end)
end)

local function HandleSpecOrTalentChange()
    ScanCDMViewers()
    ClearAllHooks()
    for _, barFrame in pairs(_activeSkillBars) do
        barFrame._needsChargeRefresh = true
        barFrame._cachedMaxCharges   = 0
    end
    for _, barFrame in pairs(_activeBuffBars) do
        barFrame._trackedAuraInstanceID = nil
        barFrame._trackedUnit           = nil
        barFrame._lastKnownActive       = false
        barFrame._lastKnownStacks       = 0
    end
end

VFlow.on("PLAYER_SPECIALIZATION_CHANGED", "CustomMonitorRuntime", HandleSpecOrTalentChange)
VFlow.on("TRAIT_CONFIG_UPDATED", "CustomMonitorRuntime", HandleSpecOrTalentChange)

VFlow.on("PLAYER_REGEN_ENABLED", "CustomMonitorRuntime", function()
    ScanCDMViewers()
    ClearAllHooks()
    for _, barFrame in pairs(_activeSkillBars) do
        barFrame._needsChargeRefresh = true
    end
end)

VFlow.on("SPELL_UPDATE_CHARGES", "CustomMonitorRuntime", function()
    for _, barFrame in pairs(_activeSkillBars) do
        barFrame._needsChargeRefresh = true
    end
end)



-- UNIT_AURA 事件：duration 条每次 OnUpdate 都会调用 SetTimerDuration，无需额外标志

-- =========================================================
-- SECTION 16: 公共接口（由 CustomMonitorGroups 调用）
-- =========================================================

VFlow.CustomMonitorRuntime = {
    onContainerReady = function(storeKey, spellID, cfg, container)
        EnsureBar(storeKey, spellID, cfg, container)
        _updateFrame:Show()
    end,

    onContainerDestroyed = function(storeKey, spellID)
        DestroyBar(storeKey, spellID)
        if not next(_activeSkillBars) and not next(_activeBuffBars) then
            _updateFrame:Hide()
        end
    end,
}
