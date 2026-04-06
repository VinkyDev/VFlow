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
local BFK = VFlow.BarFrameKit
local Profiler = VFlow.Profiler

-- =========================================================
-- SECTION 1: 模块入口
-- =========================================================

-- =========================================================
-- SECTION 2: 常量
-- =========================================================

local UPDATE_INTERVAL = 0.1
local MAP_RETRY_INTERVAL = 1.5
local INACTIVE_PROBE_INTERVAL = 0.4
local BUFF_VIEWERS = {
    "BuffIconCooldownViewer",
    "BuffBarCooldownViewer",
    "EssentialCooldownViewer",
    "UtilityCooldownViewer",
}

local INTERP_EASE_OUT = Enum.StatusBarInterpolation and Enum.StatusBarInterpolation.ExponentialEaseOut or 1

-- 环形纹理路径格式
local RING_TEXTURE_FMT = "Interface\\AddOns\\VFlow\\Assets\\Ring\\Ring_%spx.tga"

local function ResolveFontFlags(outline)
    if outline == "OUTLINE" or outline == "THICKOUTLINE" then
        return outline
    end
    return ""
end

local function ApplyConfiguredFont(fs, tf)
    if not fs then return end
    local fontSize = tf and tf.size or 14
    local fontFlags = ResolveFontFlags(tf and tf.outline)
    local applyFont = VFlow.UI and VFlow.UI.applyFont
    if applyFont then
        applyFont(fs, tf and tf.font, fontSize, fontFlags)
    end
    if tf and tf.outline == "SHADOW" then
        fs:SetShadowColor(0, 0, 0, 1)
        fs:SetShadowOffset(1, -1)
    else
        fs:SetShadowColor(0, 0, 0, 0)
        fs:SetShadowOffset(0, 0)
    end
end

-- =========================================================
-- SECTION 3: 显示条件判断
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
    if cfg.hideNoTarget and not VFlow.State.get("hasTarget") then
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

--- 勾选「不在系统编辑模式中显示」时：仅暴雪编辑预览阶段隐藏，内部编辑模式仍显示
local function IsHiddenForSystemEditOnly(cfg)
    if not cfg or not cfg.hideInSystemEditMode then return false end
    local sys = VFlow.State.systemEditMode or false
    local internal = VFlow.State.internalEditMode or false
    return sys and not internal
end

-- =========================================================
-- SECTION 4: 模块状态
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

-- CDM RefreshData 等钩子同帧可能触发多次：合并到帧末一次处理，减少 UpdateStackBar 重复
local _cdmFlushPending  = setmetatable({}, { __mode = "k" })  -- [cdmFrame] = true
local _cdmFlushLastAura = setmetatable({}, { __mode = "k" })  -- [cdmFrame] = { auraInstanceID?, auraUnit? }
local _cdmFlushFrame = CreateFrame("Frame")
_cdmFlushFrame:Hide()

-- =========================================================
-- SECTION 5: 通用辅助
-- =========================================================

--- 先尝试一位小数；含 secret 等对 format 有限制时回退为原值（引擎默认约三位小数）
local function SetRemainingText(text, durObj)
    local remaining
    pcall(function() remaining = durObj:GetRemainingDuration() end)
    if remaining == nil then
        text:SetText("")
        return
    end
    local ok1 = pcall(function()
        text:SetFormattedText("%.1f", remaining)
    end)
    if ok1 then return end
    local ok2 = pcall(function()
        text:SetText(remaining)
    end)
    if not ok2 then text:SetText("") end
end

local function FillDirection(fillMode)
    if fillMode == "fill" then
        return Enum.StatusBarTimerDirection and Enum.StatusBarTimerDirection.RemainingTime or 1
    end
    return Enum.StatusBarTimerDirection and Enum.StatusBarTimerDirection.ElapsedTime or 0
end

local function ApplyTimerDuration(seg, durObj, interpolation, direction)
    if not (durObj and seg.SetTimerDuration) then return false end
    seg:SetMinMaxValues(0, 1)
    seg:SetTimerDuration(durObj, interpolation, direction)
    if seg.SetToTargetValue then seg:SetToTargetValue() end
    return true
end

-- =========================================================
-- SECTION 6: ShadowCooldown（技能冷却用）
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
-- SECTION 7: Arc Detector（堆叠层数 secret value 解码）
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
    det:SetStatusBarTexture(BFK and BFK.DEFAULT_BAR_TEXTURE or "Interface\\Buttons\\WHITE8X8")
    det:SetMinMaxValues(threshold - 1, threshold)
    det:EnableMouse(false)
    if BFK then BFK.ConfigureStatusBar(det) end
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
-- SECTION 8: CDM 帧扫描 & spellID→cooldownID 映射
-- =========================================================

local function HasAuraInstanceID(value)
    if value == nil then return false end
    if issecretvalue and issecretvalue(value) then return true end
    if type(value) == "number" and value == 0 then return false end
    return true
end

-- CDM 偶发把整份 AuraData 挂在 auraInstanceID 上；C_UnitAuras 只要数值 ID。
local function AuraInstanceIDForAPI(v)
    if type(v) == "table" and v.auraInstanceID ~= nil then return v.auraInstanceID end
    return v
end

local function GetCooldownIDFromFrame(frame)
    local cdID = frame.cooldownID
    if not cdID and frame.cooldownInfo then
        cdID = frame.cooldownInfo.cooldownID
    end
    return cdID
end

--- 仅用于映射/表键：含 secret 的 spellID 不可参与 >0 或与配置 ID 比较
local function IsUsableNonSecretSpellId(id)
    if not id or type(id) ~= "number" then return false end
    if issecretvalue and issecretvalue(id) then return false end
    return id > 0
end

local function SafeSpellIdEquals(a, b)
    local ok, eq = pcall(function() return a == b end)
    return ok and eq
end

local function ResolveSpellID(info)
    if not info then return nil end
    local linked = info.linkedSpellIDs and info.linkedSpellIDs[1]
    if IsUsableNonSecretSpellId(linked) then return linked end
    if IsUsableNonSecretSpellId(info.overrideSpellID) then return info.overrideSpellID end
    if IsUsableNonSecretSpellId(info.spellID) then return info.spellID end
    return nil
end

-- 从单个 CDM 帧注册映射（只追加，可在战斗中调用）
local function RegisterCDMFrame(frame)
    local cdID = GetCooldownIDFromFrame(frame)
    if not cdID then return end
    _cooldownIDToFrame[cdID] = frame
    local info = C_CooldownViewer.GetCooldownViewerCooldownInfo(cdID)
    if not info then return end
    local sid = ResolveSpellID(info)
    if sid and not _spellToCooldownID[sid] then
        _spellToCooldownID[sid] = cdID
    end
    if info.linkedSpellIDs then
        for _, lid in ipairs(info.linkedSpellIDs) do
            if IsUsableNonSecretSpellId(lid) and not _spellToCooldownID[lid] then
                _spellToCooldownID[lid] = cdID
            end
        end
    end
    if IsUsableNonSecretSpellId(info.spellID) and not _spellToCooldownID[info.spellID] then
        _spellToCooldownID[info.spellID] = cdID
    end
end

-- 全量扫描重建映射（仅脱战时调用，需要 wipe 清表）
local function ScanCDMViewers()
    if InCombatLockdown() then return end
    local _pt = Profiler.start("CMR:ScanCDMViewers")
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
    Profiler.stop(_pt)
end

-- 战斗中为单个 spellID 补建映射（只追加，找到即停）
-- 调用方负责检查 _spellToCooldownID[spellID] == nil 后再调用
local function TryMapSpellID(spellID)
    local now = GetTime and GetTime() or 0
    local retryAt = _spellMapRetryAt[spellID]
    if retryAt and now < retryAt then return end
    local _pt = Profiler.start("CMR:TryMapSpellID")
    for _, viewerName in ipairs(BUFF_VIEWERS) do
        local viewer = _G[viewerName]
        if viewer then
            local function check(frame)
                local cdID = GetCooldownIDFromFrame(frame)
                if not cdID then return false end
                local info = C_CooldownViewer.GetCooldownViewerCooldownInfo(cdID)
                if not info then return false end
                local sid = ResolveSpellID(info)
                if SafeSpellIdEquals(sid, spellID) or SafeSpellIdEquals(info.spellID, spellID) then
                    RegisterCDMFrame(frame)
                    return true
                end
                if info.linkedSpellIDs then
                    for _, lid in ipairs(info.linkedSpellIDs) do
                        if SafeSpellIdEquals(lid, spellID) then RegisterCDMFrame(frame); return true end
                    end
                end
                return false
            end
            if viewer.itemFramePool then
                for frame in viewer.itemFramePool:EnumerateActive() do
                    if check(frame) then
                        _spellMapRetryAt[spellID] = nil
                        Profiler.stop(_pt)
                        return
                    end
                end
            else
                for _, child in ipairs({ viewer:GetChildren() }) do
                    if check(child) then
                        _spellMapRetryAt[spellID] = nil
                        Profiler.stop(_pt)
                        return
                    end
                end
            end
        end
    end
    _spellMapRetryAt[spellID] = now + MAP_RETRY_INTERVAL
    Profiler.stop(_pt)
end

local function FindCDMFrame(cooldownID)
    if not cooldownID then return nil end
    local cached = _cooldownIDToFrame[cooldownID]
    if cached then return cached end
    local _pt = Profiler.start("CMR:FindCDMFrame")
    for _, viewerName in ipairs(BUFF_VIEWERS) do
        local viewer = _G[viewerName]
        if viewer then
            if viewer.itemFramePool then
                for frame in viewer.itemFramePool:EnumerateActive() do
                    local cdID = GetCooldownIDFromFrame(frame)
                    if cdID == cooldownID then
                        _cooldownIDToFrame[cdID] = frame
                        Profiler.stop(_pt)
                        return frame
                    end
                end
            else
                for _, child in ipairs({ viewer:GetChildren() }) do
                    local cdID = GetCooldownIDFromFrame(child)
                    if cdID == cooldownID then
                        _cooldownIDToFrame[cdID] = child
                        Profiler.stop(_pt)
                        return child
                    end
                end
            end
        end
    end
    Profiler.stop(_pt)
    return nil
end

-- =========================================================
-- SECTION 9: Aura 追踪 & CDM Hook（stacks/duration 共用）
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
    auraInstanceID = AuraInstanceIDForAPI(auraInstanceID)
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
    auraInstanceID = AuraInstanceIDForAPI(auraInstanceID)
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
    if preferredUnit ~= "pet" and secondUnit ~= "pet" then
        data = C_UnitAuras.GetAuraDataByAuraInstanceID("pet", auraInstanceID)
        if data then return data, "pet" end
    end
    return nil, nil
end

-- CDM 帧回调：当帧刷新时通知关联的 buff 监控条
local UpdateStackBar   -- 前向声明
local UpdateDurationBar

local function FlushCDMFrameChanges()
    local _pt = Profiler.start("CMR:OnCDMFrameChanged")
    local batch = {}
    for fr in pairs(_cdmFlushPending) do
        batch[#batch + 1] = fr
    end
    for _, frame in ipairs(batch) do
        _cdmFlushPending[frame] = nil
        local slot = _cdmFlushLastAura[frame]
        _cdmFlushLastAura[frame] = nil

        local auraInstanceID = slot and slot[1]
        local auraUnit = slot and slot[2]
        if not HasAuraInstanceID(auraInstanceID) and frame.auraInstanceID then
            if HasAuraInstanceID(frame.auraInstanceID) then
                auraInstanceID = frame.auraInstanceID
            end
        end
        if (not auraUnit or auraUnit == "") and frame.auraDataUnit then
            auraUnit = frame.auraDataUnit
        end

        local barKeys = _frameToBarKeys[frame]
        if barKeys then
            for _, barKey in ipairs(barKeys) do
                local spellID  = tonumber(barKey:match("^buffs/(%d+)$"))
                local barFrame = spellID and _activeBuffBars[spellID]
                if barFrame and barFrame._monitorType == "stacks" then
                    if auraInstanceID then
                        local trackedUnit = auraUnit or frame.auraDataUnit
                            or barFrame._trackedUnit or "player"
                        LinkBarToAura(barFrame, barKey, trackedUnit, auraInstanceID)
                    end
                    UpdateStackBar(barFrame, spellID, barKey)
                    barFrame._buffBarDirty = false
                end
            end
        end
    end
    Profiler.stop(_pt)
end

local function DeferCDMFrameChanged(frame, ...)
    if not frame then return end
    local barKeysEarly = _frameToBarKeys[frame]
    if not barKeysEarly then return end

    local auraInstanceID, auraUnit
    for i = 1, select("#", ...) do
        local v = select(i, ...)
        if not auraInstanceID and HasAuraInstanceID(v) then auraInstanceID = v end
        if not auraUnit and type(v) == "string" and v ~= "" then auraUnit = v end
    end

    local slot = _cdmFlushLastAura[frame]
    if not slot then
        slot = {}
        _cdmFlushLastAura[frame] = slot
    end
    if HasAuraInstanceID(auraInstanceID) then slot[1] = auraInstanceID end
    if auraUnit and auraUnit ~= "" then slot[2] = auraUnit end

    for _, barKey in ipairs(barKeysEarly) do
        local spellID = tonumber(barKey:match("^buffs/(%d+)$"))
        local barFrame = spellID and _activeBuffBars[spellID]
        if barFrame then
            barFrame._buffBarDirty = true
        end
    end

    _cdmFlushPending[frame] = true
    _cdmFlushFrame:Show()
end

_cdmFlushFrame:SetScript("OnUpdate", function(self)
    self:Hide()
    if next(_cdmFlushPending) then
        FlushCDMFrameChanges()
    end
end)

local function HookCDMFrame(cdmFrame, barKey)
    if not cdmFrame then return end
    if not _hookedFrames[cdmFrame] then
        _hookedFrames[cdmFrame] = { barIDs = {} }
        _frameToBarKeys[cdmFrame] = {}
    end
    if not _everHookedFrames[cdmFrame] then
        if cdmFrame.RefreshData         then hooksecurefunc(cdmFrame, "RefreshData",         DeferCDMFrameChanged) end
        if cdmFrame.RefreshApplications then hooksecurefunc(cdmFrame, "RefreshApplications", DeferCDMFrameChanged) end
        if cdmFrame.SetAuraInstanceInfo then hooksecurefunc(cdmFrame, "SetAuraInstanceInfo",  DeferCDMFrameChanged) end
        _everHookedFrames[cdmFrame] = true
    end
    if not _hookedFrames[cdmFrame].barIDs[barKey] then
        _hookedFrames[cdmFrame].barIDs[barKey] = true
        table.insert(_frameToBarKeys[cdmFrame], barKey)
    end
end

local function ClearAllHooks()
    for frame in pairs(_cdmFlushPending) do
        _cdmFlushPending[frame] = nil
    end
    for frame in pairs(_cdmFlushLastAura) do
        _cdmFlushLastAura[frame] = nil
    end
    _cdmFlushFrame:Hide()
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
-- SECTION 10: StatusBar 分段创建（共用）
-- =========================================================

local function colKey(c)
    if not c then return "-" end
    return table.concat({ tostring(c.r), tostring(c.g), tostring(c.b), tostring(c.a) }, ";")
end

local function ShouldRenderGraphics(cfg)
    return cfg and cfg.showGraphics ~= false
end

local function ShouldRenderText(cfg)
    return cfg and cfg.showText ~= false
end

local function timerFontKey(cfg)
    local t = cfg.timerFont or {}
    local fc = t.color or {}
    return table.concat({
        tostring(t.font or ""),
        tostring(t.size or 0),
        tostring(t.outline or ""),
        tostring(t.position or "CENTER"),
        tostring(t.offsetX or 0),
        tostring(t.offsetY or 0),
        colKey(fc),
    }, "\031")
end

--- CreateBarFrame 维度（含环形/条形共用的背景与计时文字区；不含 monitorType/充能业务模式）
local function innerBarSignature(cfg)
    return table.concat({
        tostring(cfg.shape or "bar"),
        tostring(cfg.showGraphics ~= false),
        tostring(cfg.showText ~= false),
        colKey(cfg.bgColor or { r = 0.1, g = 0.1, b = 0.1, a = 0.5 }),
        tostring(cfg.showGraphics ~= false and cfg.showIcon ~= false),
        tostring(cfg.iconSize or 20),
        tostring(cfg.iconPosition or "LEFT"),
        tostring(cfg.iconOffsetX or 0),
        tostring(cfg.iconOffsetY or 0),
        timerFontKey(cfg),
    }, "\031")
end

--- CreateSegments 维度（含环形/堆叠阈值/充能路径）
local function segmentLayoutSignature(cfg, barFrame)
    local storeKey = barFrame._storeKey or "skills"
    local shape = cfg.shape or "bar"
    local mon = (storeKey == "buffs") and (barFrame._monitorType or cfg.monitorType or "duration") or ""
    local bt = (BFK and BFK.ParseBorderThickness and BFK.ParseBorderThickness(cfg.borderThickness))
        or tonumber(cfg.borderThickness) or 1
    return table.concat({
        shape,
        storeKey,
        mon,
        tostring(cfg.showGraphics ~= false),
        tostring(tonumber(cfg.maxStacks) or 5),
        tostring(tonumber(cfg.segmentGap) or 0),
        cfg.barDirection or "horizontal",
        tostring(cfg.barReverse == true),
        tostring(cfg.barTexture or ""),
        tostring(tonumber(cfg.stackThreshold1) or 0),
        tostring(tonumber(cfg.stackThreshold2) or 0),
        colKey(cfg.stackColor1),
        colKey(cfg.stackColor2),
        colKey(cfg.barColor),
        colKey(cfg.bgColor),
        tostring(cfg.ringTexture or ""),
        colKey(cfg.ringColor or { r = 0.2, g = 0.6, b = 1, a = 1 }),
        tostring(cfg.ringThickness or 0),
        tostring(cfg.barFillMode or ""),
        tostring(bt),
        colKey(cfg.borderColor),
        storeKey == "skills" and tostring(cfg.isChargeSpell == true) or "",
        tostring(cfg.ringSize or 0),
    }, "\031")
end

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
    local _pt = Profiler.start("CMR:CreateSegments")
    ClearSegments(barFrame)
    if not ShouldRenderGraphics(cfg) then
        barFrame._segSig = segmentLayoutSignature(cfg, barFrame)
        barFrame._segsDirty = false
        barFrame._segsNeedCount = nil
        Profiler.stop(_pt)
        return
    end
    if count < 1 then
        Profiler.stop(_pt)
        return
    end

    local segContainer = barFrame._segContainer
    local totalW, totalH = segContainer:GetSize()
    if totalW <= 0 then
        barFrame._segsDirty     = true
        barFrame._segsNeedCount = count
        Profiler.stop(_pt)
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
        local bgc = cfg.bgColor or { r = 0.1, g = 0.1, b = 0.1, a = 0.5 }
        bg:SetVertexColor(bgc.r, bgc.g, bgc.b, bgc.a)
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

        barFrame._segSig = segmentLayoutSignature(cfg, barFrame)
        barFrame._segsDirty = false
        barFrame._segsNeedCount = nil
        Profiler.stop(_pt)
        return
    end

    -- 条形模式：分段几何与边框同 BarFrameKit / ResourceBars（ref 像素比例 + 末格双锚点）
    local dir = cfg.barDirection or "horizontal"
    local barReverse = cfg.barReverse == true
    local tex = BFK and BFK.ResolveBarTexture(cfg.barTexture) or "Interface\\Buttons\\WHITE8X8"
    local bc  = cfg.barColor or { r = 0.2, g = 0.6, b = 1, a = 1 }

    -- 阈值配置（isStack 时读取）
    local t1 = isStack and (tonumber(cfg.stackThreshold1) or 0) or 0
    local t2 = isStack and (tonumber(cfg.stackThreshold2) or 0) or 0
    local c1 = cfg.stackColor1 or { r = 1, g = 0.5, b = 0, a = 1 }
    local c2 = cfg.stackColor2 or { r = 1, g = 0,   b = 0, a = 1 }

    local baseLevel = segContainer:GetFrameLevel()

    for i = 1, count do
        local segFrame = CreateFrame("Frame", nil, segContainer)
        segFrame:SetFrameLevel(baseLevel)

        local bg = segFrame:CreateTexture(nil, "BACKGROUND")
        local bgc = cfg.bgColor or { r = 0.1, g = 0.1, b = 0.1, a = 0.5 }
        bg:SetColorTexture(bgc.r, bgc.g, bgc.b, bgc.a)
        bg:SetAllPoints(segFrame)

        local seg = CreateFrame("StatusBar", nil, segFrame)
        seg:SetStatusBarTexture(tex)
        seg:SetStatusBarColor(bc.r, bc.g, bc.b, bc.a)
        seg:SetValue(0)
        seg:EnableMouse(false)
        seg:SetFrameLevel(baseLevel + 1)
        seg:SetAllPoints(segFrame)
        if BFK then
            BFK.ConfigureStatusBar(seg)
            BFK.SetOrientation(seg, dir)
            BFK.SetReverseFill(seg, barReverse)
        end

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
                if BFK then
                    BFK.ConfigureStatusBar(ov1)
                    BFK.SetOrientation(ov1, dir)
                    BFK.SetReverseFill(ov1, barReverse)
                end
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
                if BFK then
                    BFK.ConfigureStatusBar(ov2)
                    BFK.SetOrientation(ov2, dir)
                    BFK.SetReverseFill(ov2, barReverse)
                end
                table.insert(barFrame._thresholdOverlays, ov2)
            end
        end

        local borderFrame = CreateFrame("Frame", nil, segFrame)
        borderFrame:SetFrameLevel(baseLevel + 4)
        borderFrame:SetAllPoints(segFrame)
        borderFrame:EnableMouse(false)
        segFrame._vf_segmentBorder = borderFrame
    end

    --- 与 ResourceBars 一致：像素比例以「正在分割的容器」为 ref（totalW/H 亦来自该容器）
    if BFK and BFK.LayoutDiscreteBarSegmentFrames then
        BFK.LayoutDiscreteBarSegmentFrames(segContainer, cfg, count, dir, barFrame._segFrames or {}, segContainer)
    end
    if BFK and BFK.ApplySegmentCellBorder then
        for i = 1, count do
            local sf = barFrame._segFrames and barFrame._segFrames[i]
            if sf and sf._vf_segmentBorder then
                BFK.ApplySegmentCellBorder(sf._vf_segmentBorder, cfg)
            end
        end
    end

    barFrame._segSig = segmentLayoutSignature(cfg, barFrame)
    barFrame._segsDirty     = false
    barFrame._segsNeedCount = nil
    Profiler.stop(_pt)
end

-- 将层数值同时设给基础分段和阈值覆盖层
local function SetStackSegmentsValue(barFrame, value)
    for _, seg in ipairs(barFrame._segments) do seg:SetValue(value) end
    for _, ov  in ipairs(barFrame._thresholdOverlays) do ov:SetValue(value) end
end

-- =========================================================
-- SECTION 11: 技能冷却/充能 更新逻辑
-- =========================================================

local function UpdateRegularCooldownBar(barFrame, spellID)
    local cfg = barFrame._cfg
    local showGraphics = ShouldRenderGraphics(cfg)
    local showText = ShouldRenderText(cfg)
    local cdInfo
    pcall(function()
        cdInfo = C_Spell.GetSpellCooldown(spellID)
    end)
    local isOnGCD = cdInfo and cdInfo.isOnGCD == true
    local spellCdActive = true
    if cdInfo and cdInfo.isActive ~= nil then
        spellCdActive = cdInfo.isActive == true
    end

    local durObj
    local shadowCD = showGraphics and GetOrCreateShadowCooldown(barFrame) or nil
    if not isOnGCD then
        pcall(function() durObj = C_Spell.GetSpellCooldownDuration(spellID) end)
    end
    if showGraphics then
        if isOnGCD then
            shadowCD:Clear()
        elseif durObj and spellCdActive then
            shadowCD:Clear()
            pcall(function() shadowCD:SetCooldownFromDurationObject(durObj, true) end)
        else
            shadowCD:Clear()
        end
    end

    local isOnCooldown = false
    if showGraphics then
        isOnCooldown = shadowCD:IsShown()
    elseif durObj and spellCdActive then
        pcall(function()
            isOnCooldown = durObj:GetRemainingDuration() > 0
        end)
    end

    if not showGraphics then
        if barFrame._text then
            if isOnCooldown and not isOnGCD and durObj and spellCdActive and showText then
                SetRemainingText(barFrame._text, durObj)
            else
                barFrame._text:SetText("")
            end
        end
        return
    end

    if not barFrame._segments or #barFrame._segments ~= 1 then
        CreateSegments(barFrame, 1, cfg)
    end
    local seg = barFrame._segments and barFrame._segments[1]
    if not seg then return end

    -- 根据冷却状态设置颜色
    if isOnCooldown and not isOnGCD and durObj and spellCdActive then
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
    if BFK then BFK.SetReverseFill(seg, cfg.barReverse == true) end
end

local function UpdateChargeBar(barFrame, spellID)
    local cfg = barFrame._cfg
    local showGraphics = ShouldRenderGraphics(cfg)
    local showText = ShouldRenderText(cfg)

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
    local wasFullyCharged = barFrame._lastChargeWasFull == true

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

    local chargeDurObj = nil
    pcall(function() chargeDurObj = C_Spell.GetSpellChargeDuration(spellID) end)

    local activeChargeDurObj = chargeDurObj
    local recharging = true
    pcall(function()
        if type(currentCharges) == "number" and type(maxCharges) == "number" then
            if not (issecretvalue and (issecretvalue(currentCharges) or issecretvalue(maxCharges))) then
                recharging = currentCharges < maxCharges
            end
        end
    end)

    local shouldShowRecharge = recharging and (chargeDurObj ~= nil) and (activeChargeDurObj ~= nil)
    if not showGraphics then
        if barFrame._text then
            if showText and shouldShowRecharge then
                SetRemainingText(barFrame._text, activeChargeDurObj)
            else
                barFrame._text:SetText("")
            end
        end
        if type(currentCharges) == "number" and type(maxCharges) == "number"
            and not (issecretvalue and (issecretvalue(currentCharges) or issecretvalue(maxCharges))) then
            barFrame._lastChargeWasFull = currentCharges >= maxCharges
        else
            barFrame._lastChargeWasFull = false
        end
        return
    end

    local borderThickness = tonumber(cfg.borderThickness) or 1

    -- 创建背景层（显示未充能部分）
    if not barFrame._chargeBG then
        local bg = barFrame._segContainer:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints(barFrame._segContainer)
        local bgc = cfg.bgColor or { r = 0.1, g = 0.1, b = 0.1, a = 0.5 }
        bg:SetColorTexture(bgc.r, bgc.g, bgc.b, bgc.a)
        barFrame._chargeBG = bg
    end

    -- 设置主充能条（显示已有充能数）
    if not barFrame._chargeBar then
        local chargeBar = CreateFrame("StatusBar", nil, barFrame._segContainer)
        chargeBar:SetStatusBarTexture(BFK and BFK.ResolveBarTexture(cfg.barTexture) or "Interface\\Buttons\\WHITE8X8")
        chargeBar:SetAllPoints(barFrame._segContainer)
        chargeBar:SetFrameLevel(barFrame._segContainer:GetFrameLevel() + 1)
        if BFK then BFK.ConfigureStatusBar(chargeBar) end
        barFrame._chargeBar = chargeBar
    end

    -- 每次更新颜色与材质（配置可能变化）
    local barTex = BFK and BFK.ResolveBarTexture(cfg.barTexture) or "Interface\\Buttons\\WHITE8X8"
    barFrame._chargeBar:SetStatusBarTexture(barTex)
    if BFK then BFK.ConfigureStatusBar(barFrame._chargeBar) end
    barFrame._chargeBar:SetStatusBarColor(cfg.barColor.r, cfg.barColor.g, cfg.barColor.b, cfg.barColor.a)
    barFrame._chargeBar:SetMinMaxValues(0, maxCharges)
    barFrame._chargeBar:SetValue(currentCharges)
    local dir = cfg.barDirection or "horizontal"
    if BFK then
        BFK.SetOrientation(barFrame._chargeBar, dir)
        BFK.SetReverseFill(barFrame._chargeBar, cfg.barReverse == true)
    end

    -- 设置充能进度条（显示正在充能的进度）
    if not barFrame._refreshCharge then
        local refreshCharge = CreateFrame("StatusBar", nil, barFrame._segContainer)
        refreshCharge:SetStatusBarTexture(BFK and BFK.ResolveBarTexture(cfg.barTexture) or "Interface\\Buttons\\WHITE8X8")
        if BFK then BFK.ConfigureStatusBar(refreshCharge) end
        barFrame._refreshCharge = refreshCharge
    end

    if showText and not barFrame._refreshChargeText then
        local tf = cfg.timerFont or {}
        local fc = tf.color or { r = 1, g = 1, b = 1, a = 1 }
        -- 裁剪容器：跟随 _refreshCharge，隐藏时文字自动隐藏，SetClipsChildren 处理溢出
        local clip = CreateFrame("Frame", nil, barFrame._refreshCharge)
        clip:SetAllPoints(barFrame._refreshCharge)
        clip:SetFrameLevel(barFrame._textHolder:GetFrameLevel())
        clip:SetClipsChildren(true)
        clip:EnableMouse(false)
        barFrame._refreshChargeClip = clip

        local txt = clip:CreateFontString(nil, "OVERLAY")
        ApplyConfiguredFont(txt, tf)
        txt:SetTextColor(fc.r, fc.g, fc.b, fc.a)
        txt:SetJustifyH("CENTER")
        local anchor = tf.position or "CENTER"
        txt:SetPoint(anchor, clip, anchor, tf.offsetX or 0, tf.offsetY or 0)
        barFrame._refreshChargeText = txt
    end

    -- 每次更新颜色与材质（配置可能变化）
    local rc = cfg.rechargeColor or { r = 0.5, g = 0.8, b = 1, a = 1 }
    barFrame._refreshCharge:SetStatusBarTexture(barTex)
    if BFK then BFK.ConfigureStatusBar(barFrame._refreshCharge) end
    barFrame._refreshCharge:SetStatusBarColor(rc.r, rc.g, rc.b, rc.a)
    if BFK then
        BFK.SetOrientation(barFrame._refreshCharge, dir)
        BFK.SetReverseFill(barFrame._refreshCharge, cfg.barReverse == true)
    end

    -- 与 CreateSegments 一致：按 barDirection 计算单格尺寸，并锚定到主条填充前沿（下一格）
    local totalW = barFrame._segContainer:GetWidth()
    local totalH = barFrame._segContainer:GetHeight()
    local barReverse = cfg.barReverse == true
    if totalW > 0 and totalH > 0 then
        local userGap = tonumber(cfg.segmentGap) or 0
        local segmentGap = (maxCharges > 1) and (userGap - borderThickness) or 0
        local ppScale = PP.GetPixelScale()
        local function ToPixel(v) return math.floor(v / ppScale + 0.5) end
        local function ToLogical(px) return px * ppScale end

        local pxTotalW = ToPixel(totalW)
        local pxTotalH = ToPixel(totalH)
        local pxGap = ToPixel(segmentGap)

        local pxSegW_Base, pxSegH_Base, pxRemainder
        if dir == "vertical" then
            pxSegW_Base = pxTotalW
            local pxAvailableH = math.max(0, pxTotalH - (maxCharges - 1) * pxGap)
            pxSegH_Base = math.floor(pxAvailableH / maxCharges)
            pxRemainder = pxAvailableH % maxCharges
        else
            pxSegH_Base = pxTotalH
            local pxAvailableW = math.max(0, pxTotalW - (maxCharges - 1) * pxGap)
            pxSegW_Base = math.floor(pxAvailableW / maxCharges)
            pxRemainder = pxAvailableW % maxCharges
        end

        local thisPxSegW = pxSegW_Base
        local thisPxSegH = pxSegH_Base
        if dir == "vertical" then
            if 1 <= pxRemainder then thisPxSegH = thisPxSegH + 1 end
        else
            if 1 <= pxRemainder then thisPxSegW = thisPxSegW + 1 end
        end
        local logSegW = ToLogical(thisPxSegW)
        local logSegH = ToLogical(thisPxSegH)

        barFrame._refreshCharge:ClearAllPoints()
        local tex = barFrame._chargeBar:GetStatusBarTexture()
        if tex then
            if dir == "vertical" then
                if not barReverse then
                    barFrame._refreshCharge:SetPoint("BOTTOM", tex, "TOP", 0, 0)
                else
                    barFrame._refreshCharge:SetPoint("TOP", tex, "BOTTOM", 0, 0)
                end
            else
                if not barReverse then
                    barFrame._refreshCharge:SetPoint("LEFT", tex, "RIGHT", 0, 0)
                else
                    barFrame._refreshCharge:SetPoint("RIGHT", tex, "LEFT", 0, 0)
                end
            end
        end
        barFrame._refreshCharge:SetSize(logSegW, logSegH)
    end

    -- 使用SetTimerDuration设置充能进度动画
    pcall(function()
        barFrame._refreshCharge:SetTimerDuration(
            chargeDurObj,
            Enum.StatusBarInterpolation.Immediate or 0,
            Enum.StatusBarTimerDirection.ElapsedTime or 0
        )
    end)

    activeChargeDurObj = nil
    if barFrame._refreshCharge.GetTimerDuration then
        activeChargeDurObj = barFrame._refreshCharge:GetTimerDuration()
    end

    local suppressRechargeThisFrame = false
    if wasFullyCharged and recharging then
        suppressRechargeThisFrame = true
    end

    shouldShowRecharge = recharging and (chargeDurObj ~= nil) and (activeChargeDurObj ~= nil)

    if shouldShowRecharge then
        barFrame._refreshCharge:Show()
        barFrame._refreshCharge:SetAlpha(suppressRechargeThisFrame and 0 or 1)
    else
        barFrame._refreshCharge:Hide()
        barFrame._refreshCharge:SetAlpha(1)
    end

    -- 创建分隔线（使用完美像素边框）- 边框重合自动形成分隔线
    if maxCharges > 1 and borderThickness > 0 then
        barFrame._chargeBorders = barFrame._chargeBorders or {}
        for i = maxCharges + 1, #barFrame._chargeBorders do
            if barFrame._chargeBorders[i] then
                PP.HideBorder(barFrame._chargeBorders[i])
                barFrame._chargeBorders[i]:Hide()
                barFrame._chargeBorders[i] = nil
            end
        end
        if totalW > 0 and totalH > 0 then
            local userGap = tonumber(cfg.segmentGap) or 0
            local segmentGap = (maxCharges > 1) and (userGap - borderThickness) or 0

            local ppScale = PP.GetPixelScale()
            local function ToPixel(v) return math.floor(v / ppScale + 0.5) end
            local function ToLogical(px) return px * ppScale end

            local pxTotalW = ToPixel(totalW)
            local pxTotalH = ToPixel(totalH)
            local pxGap = ToPixel(segmentGap)

            local pxSegW_Base, pxSegH_Base, pxRemainder
            if dir == "vertical" then
                pxSegW_Base = pxTotalW
                local pxAvailableH = math.max(0, pxTotalH - (maxCharges - 1) * pxGap)
                pxSegH_Base = math.floor(pxAvailableH / maxCharges)
                pxRemainder = pxAvailableH % maxCharges
            else
                pxSegH_Base = pxTotalH
                local pxAvailableW = math.max(0, pxTotalW - (maxCharges - 1) * pxGap)
                pxSegW_Base = math.floor(pxAvailableW / maxCharges)
                pxRemainder = pxAvailableW % maxCharges
            end

            local bc = cfg.borderColor or { r = 0.3, g = 0.3, b = 0.3, a = 1 }
            local currentPxOffset = 0

            for i = 1, maxCharges do
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

                if not barFrame._chargeBorders[i] then
                    local borderFrame = CreateFrame("Frame", nil, barFrame._segContainer)
                    borderFrame:SetFrameLevel(barFrame._segContainer:GetFrameLevel() + 10)
                    barFrame._chargeBorders[i] = borderFrame
                end
                local borderFrame = barFrame._chargeBorders[i]
                borderFrame:ClearAllPoints()
                local anchor = (dir == "vertical") and "BOTTOMLEFT" or "TOPLEFT"
                local offsetX = (dir == "vertical") and 0 or logOffset
                local offsetY = (dir == "vertical") and logOffset or 0
                borderFrame:SetPoint(anchor, barFrame._segContainer, anchor, offsetX, offsetY)
                PP.SetSize(borderFrame, logSegW, logSegH)

                local needRebuild = (not borderFrame._vfBorderThickness)
                    or (borderFrame._vfBorderThickness ~= borderThickness)
                    or (borderFrame._vfBorderW ~= logSegW)
                    or (borderFrame._vfBorderH ~= logSegH)
                if needRebuild then
                    PP.CreateBorder(borderFrame, borderThickness, bc, true)
                    borderFrame._vfBorderThickness = borderThickness
                    borderFrame._vfBorderW = logSegW
                    borderFrame._vfBorderH = logSegH
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

                if dir == "vertical" then
                    currentPxOffset = currentPxOffset + thisPxSegH + pxGap
                else
                    currentPxOffset = currentPxOffset + thisPxSegW + pxGap
                end
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

    if type(currentCharges) == "number" and type(maxCharges) == "number"
        and not (issecretvalue and (issecretvalue(currentCharges) or issecretvalue(maxCharges))) then
        barFrame._lastChargeWasFull = currentCharges >= maxCharges
    else
        barFrame._lastChargeWasFull = false
    end
end

-- =========================================================
-- SECTION 12: BUFF 持续时间更新逻辑
-- =========================================================

UpdateDurationBar = function(barFrame, spellID, barKey)
    local cfg = barFrame._cfg
    local showGraphics = ShouldRenderGraphics(cfg)
    local showText = ShouldRenderText(cfg)

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
                auraInstanceID = AuraInstanceIDForAPI(cdmFrame.auraInstanceID)
                unit           = cdmFrame.auraDataUnit or "player"
                barFrame._trackedAuraInstanceID = auraInstanceID
                barFrame._trackedUnit           = unit
            end
        end
    end

    -- 路径2：上次记录的 auraInstanceID
    if not auraActive and HasAuraInstanceID(barFrame._trackedAuraInstanceID) then
        local tid = AuraInstanceIDForAPI(barFrame._trackedAuraInstanceID)
        local d
        d = C_UnitAuras.GetAuraDataByAuraInstanceID("player", tid)
        if d then
            unit = "player"
        else
            d = C_UnitAuras.GetAuraDataByAuraInstanceID("pet", tid)
            if d then unit = "pet" end
        end
        if d then
            auraActive     = true
            auraInstanceID = tid
            barFrame._trackedAuraInstanceID = tid
            barFrame._trackedUnit = unit
        end
    end

    -- 路径3：按 spellID 直接扫描（首次触发/CDM 尚未激活时兜底）
    -- 战斗中 spellId 是 secret value，pcall 比较失败时直接退出循环
    if not auraActive then
        for _, scanUnit in ipairs({ "player", "pet" }) do
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

    if not showGraphics then
        if auraActive and auraInstanceID and unit then
            barFrame._lastKnownActive = true
            if barFrame._text then
                local durObj = C_UnitAuras.GetAuraDuration(unit, auraInstanceID)
                if showText and durObj then
                    SetRemainingText(barFrame._text, durObj)
                else
                    barFrame._text:SetText("")
                end
            end
        else
            barFrame._lastKnownActive = false
            barFrame._trackedAuraInstanceID = nil
            barFrame._trackedUnit = nil
            if barFrame._text then
                barFrame._text:SetText("")
            end
        end
        return
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
            -- 环形模式：每帧更新，与条形的SetTimerDuration行为一致
            local durObj = C_UnitAuras.GetAuraDuration(unit, auraInstanceID)
            if durObj and seg.SetCooldownFromDurationObject then
                pcall(function()
                    seg:SetCooldownFromDurationObject(durObj)
                end)
                local rc = cfg.ringColor or { r = 0.2, g = 0.6, b = 1, a = 1 }
                seg:SetSwipeColor(rc.r, rc.g, rc.b, rc.a)
                seg._needsRefresh = false
            end
            if barFrame._text then
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
            if BFK then BFK.SetReverseFill(seg, cfg.barReverse == true) end
        end
    else
        barFrame._lastKnownActive = false
        barFrame._trackedAuraInstanceID = nil
        barFrame._trackedUnit           = nil

        if isRing and seg._isRing then
            if seg.Clear then
                seg:Clear()
            end
            seg._needsRefresh = true  -- 下次激活时重新设置
        else
            seg:SetMinMaxValues(0, 1); seg:SetValue(0)
            if BFK then BFK.SetReverseFill(seg, cfg.barReverse == true) end
        end
        if barFrame._text then barFrame._text:SetText("") end
    end
end

-- =========================================================
-- SECTION 13: BUFF 堆叠层数更新逻辑
-- =========================================================

UpdateStackBar = function(barFrame, spellID, barKey)
    local cfg       = barFrame._cfg
    local showGraphics = ShouldRenderGraphics(cfg)
    local showText = ShouldRenderText(cfg)
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
                barFrame._nilCount             = 0
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

    if showGraphics and (not barFrame._segments or #barFrame._segments ~= maxStacks) then
        CreateSegments(barFrame, maxStacks, cfg, true)
    end
    if showGraphics and not barFrame._segments then return end

    local isSecret = issecretvalue and issecretvalue(stacks)

    if showGraphics and isSecret then
        SetStackSegmentsValue(barFrame, stacks)
        FeedArcDetectors(barFrame, stacks, maxStacks)
        local resolved = GetExactCount(barFrame, maxStacks)
        if type(resolved) == "number" then
            barFrame._lastKnownStacks = resolved
        end
    elseif showGraphics then
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
        if not showText then
            barFrame._text:SetText("")
            return
        end
        if isSecret then
            barFrame._text:SetText(stacks)
        elseif stacks == 0 then
            barFrame._text:SetText("")
        else
            barFrame._text:SetText(tostring(stacks))
        end
    end
end

-- =========================================================
-- SECTION 14: 条形帧创建（技能/buff 共用）
-- =========================================================

local function CreateBarFrame(spellID, cfg, container)
    if container._bar then container._bar:Hide() end

    local showGraphics = ShouldRenderGraphics(cfg)
    local showText = ShouldRenderText(cfg)
    local barFrame = CreateFrame("Frame", nil, container)
    barFrame:SetAllPoints(container)
    barFrame:SetFrameStrata(container:GetFrameStrata())
    barFrame:SetFrameLevel(container:GetFrameLevel() + 1)

    if showGraphics then
        local bg = barFrame:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        if cfg.shape == "ring" then
            bg:SetColorTexture(0, 0, 0, 0)
        else
            local bgc = cfg.bgColor or { r = 0.1, g = 0.1, b = 0.1, a = 0.5 }
            bg:SetColorTexture(bgc.r, bgc.g, bgc.b, bgc.a)
        end
        barFrame._bg = bg
    end

    if showGraphics and cfg.showIcon ~= false then
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
    --- 勿对整条形容器 Clip：与 ResourceBars 一致；Clip 会在接缝/尾部与 PixelPerfect 1px 边框锯齿叠粗。
    --- 充能数字溢出由 _refreshChargeClip:SetClipsChildren(true) 处理。
    segContainer:SetClipsChildren(false)
    barFrame._segContainer = segContainer

    local textHolder = CreateFrame("Frame", nil, barFrame)
    textHolder:SetAllPoints(barFrame)
    textHolder:SetFrameStrata(container:GetFrameStrata())
    textHolder:SetFrameLevel(container:GetFrameLevel() + 50)
    textHolder:EnableMouse(false)
    barFrame._textHolder = textHolder

    if showText then
        local tf      = cfg.timerFont or {}
        local fc      = tf.color or { r = 1, g = 1, b = 1, a = 1 }
        local tAnchor = tf.position or "CENTER"

        barFrame._text = textHolder:CreateFontString(nil, "OVERLAY")
        ApplyConfiguredFont(barFrame._text, tf)
        barFrame._text:SetTextColor(fc.r, fc.g, fc.b, fc.a)
        barFrame._text:SetPoint(tAnchor, textHolder, tAnchor, tf.offsetX or 0, tf.offsetY or 0)
        barFrame._text:SetJustifyH("CENTER")
    end

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
    barFrame._lastChargeWasFull    = false
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
    barFrame._buffBarDirty         = true

    return barFrame
end

-- =========================================================
-- SECTION 15: 生命周期管理
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
    barFrame._lastChargeWasFull = false
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
    if storeKey == "buffs" then
        cfg.isChargeSpell = false
    end
    local tbl = (storeKey == "skills") and _activeSkillBars or _activeBuffBars
    if tbl[spellID] then DestroyBar(storeKey, spellID) end

    local barFrame = CreateBarFrame(spellID, cfg, container)
    barFrame._container = container  -- 存储容器引用，用于显示/隐藏
    barFrame._storeKey = storeKey
    barFrame._innerSig = innerBarSignature(cfg)
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
-- SECTION 16: OnUpdate 主循环
-- =========================================================

local _elapsed = 0

--- 条件不满足时不 Hide：保持 Shown + Alpha=0，布局/API/充能等与「始终显示」同路径（避免因 Hide 跳过更新）
local function ApplyMonitorContainerVisibility(container, shouldShow)
    if not container then return end
    container:Show()
    container:SetAlpha(shouldShow and 1 or 0)
end

local function ApplyBgColor(barFrame)
    local cfg = barFrame._cfg
    if not ShouldRenderGraphics(cfg) then return end
    local bgc = cfg.bgColor or { r = 0.1, g = 0.1, b = 0.1, a = 0.5 }
    if barFrame._bg then
        if cfg.shape == "ring" then
            barFrame._bg:SetColorTexture(0, 0, 0, 0)
        else
            barFrame._bg:SetColorTexture(bgc.r, bgc.g, bgc.b, bgc.a)
        end
    end
    if barFrame._chargeBG then
        barFrame._chargeBG:SetColorTexture(bgc.r, bgc.g, bgc.b, bgc.a)
    end
    if barFrame._segBGs then
        for _, bg in ipairs(barFrame._segBGs) do
            if cfg.shape == "ring" then
                bg:SetVertexColor(bgc.r, bgc.g, bgc.b, bgc.a)
            else
                bg:SetColorTexture(bgc.r, bgc.g, bgc.b, bgc.a)
            end
        end
    end
end

local function UpdateAllBars()
    local _ps = Profiler.start("CMR:UpdateSkillBars")
    for spellID, barFrame in pairs(_activeSkillBars) do
        -- 检查显示条件
        local shouldShow = ShouldShowBar(barFrame._cfg, false)
        if shouldShow and IsHiddenForSystemEditOnly(barFrame._cfg) then
            shouldShow = false
        end
        local container = barFrame._container

        ApplyMonitorContainerVisibility(container, shouldShow)
        ApplyBgColor(barFrame)
        if not barFrame._cfg.isChargeSpell then
            if barFrame._segsDirty then
                local cw = barFrame._segContainer:GetWidth()
                if cw and cw > 0 then
                    CreateSegments(barFrame, barFrame._segsNeedCount or 1, barFrame._cfg)
                end
            end
            UpdateRegularCooldownBar(barFrame, spellID)
        else
            UpdateChargeBar(barFrame, spellID)
        end
    end
    Profiler.stop(_ps)

    local _pb = Profiler.start("CMR:UpdateBuffBars")
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
            ApplyBgColor(barFrame)
            if ShouldRenderGraphics(cfg) and barFrame._segsDirty then
                local cw = barFrame._segContainer:GetWidth()
                if cw and cw > 0 then
                    local isRing = (cfg.shape == "ring") and barFrame._monitorType ~= "stacks"
                    CreateSegments(barFrame, barFrame._segsNeedCount or 1, cfg,
                        barFrame._monitorType == "stacks", isRing)
                end
            end
            if barFrame._monitorType == "stacks" then
                -- 层数条：CDM 钩子帧末已刷新时可跳过大部分 0.1s 轮询；约每 1s 兜底同步一次
                barFrame._vf_stackPollCounter = (barFrame._vf_stackPollCounter or 0) + 1
                local forceStackPoll = false
                if barFrame._vf_stackPollCounter >= 10 then
                    barFrame._vf_stackPollCounter = 0
                    forceStackPoll = true
                end
                -- _nilCount>0：BUFF 刚消失、CDM 暂未同步时防抖计数；须每tick轮询否则仅靠 forceStackPoll 会拖成数秒
                if barFrame._buffBarDirty or barFrame._segsDirty or not barFrame._lastKnownActive or forceStackPoll
                    or (barFrame._nilCount or 0) > 0 then
                    UpdateStackBar(barFrame, spellID, barFrame._barKey)
                end
                barFrame._buffBarDirty = false
            else
                UpdateDurationBar(barFrame, spellID, barFrame._barKey)
                barFrame._buffBarDirty = false
            end
            isBuffActive = barFrame._lastKnownActive or false
        end
        local shouldShow = ShouldShowBar(cfg, isBuffActive)
        if shouldShow and IsHiddenForSystemEditOnly(cfg) then
            shouldShow = false
        end
        ApplyMonitorContainerVisibility(barFrame._container, shouldShow)
    end
    Profiler.stop(_pb)
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

VFlow.State.watch("systemEditMode", "CustomMonitorRuntime_Vis", function()
    if next(_activeSkillBars) or next(_activeBuffBars) then
        UpdateAllBars()
    end
end)

VFlow.State.watch("internalEditMode", "CustomMonitorRuntime_Vis", function()
    if next(_activeSkillBars) or next(_activeBuffBars) then
        UpdateAllBars()
    end
end)

-- =========================================================
-- SECTION 17: 事件响应
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
        barFrame._buffBarDirty          = true
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
-- SECTION 18: 公共接口（由 CustomMonitorGroups 调用）
-- =========================================================

--- 配置变化时按「内线框 / 分段」签名增量更新，无需 Store 键正则维护。
local function SyncBarConfig(storeKey, spellID, cfg)
    if not cfg then return end
    local tbl = (storeKey == "skills") and _activeSkillBars or _activeBuffBars
    local barFrame = tbl[spellID]
    if not barFrame then return end

    if storeKey == "buffs" then
        cfg.isChargeSpell = false
    end

    local newInner = innerBarSignature(cfg)
    if newInner ~= barFrame._innerSig then
        EnsureBar(storeKey, spellID, cfg, barFrame._container)
        return
    end

    barFrame._cfg = cfg

    if storeKey == "buffs" then
        local monitorType = cfg.monitorType or "duration"
        if barFrame._monitorType ~= monitorType then
            barFrame._monitorType = monitorType
            if monitorType == "duration" then
                _activeDurationBars[spellID] = barFrame
            else
                _activeDurationBars[spellID] = nil
            end
        end
        barFrame._buffBarDirty = true
    elseif storeKey == "skills" and cfg.isChargeSpell then
        barFrame._needsChargeRefresh = true
    end

    local newSeg = segmentLayoutSignature(cfg, barFrame)
    if newSeg ~= (barFrame._segSig or "") then
        barFrame._segsDirty = true
        if barFrame._segsNeedCount == nil then
            barFrame._segsNeedCount = 1
        end
    end
end

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

    --- 容器像素尺寸变化（如同步技能条宽度）：段几何需重建
    notifyContainerGeometryChanged = function(storeKey, spellID)
        local tbl = storeKey == "skills" and _activeSkillBars or _activeBuffBars
        local barFrame = spellID and tbl[spellID]
        if barFrame then
            barFrame._segsDirty = true
            barFrame._needsChargeRefresh = true
            if barFrame._segsNeedCount == nil then
                barFrame._segsNeedCount = 1
            end
        end
    end,

    syncBarConfig = SyncBarConfig,
}
