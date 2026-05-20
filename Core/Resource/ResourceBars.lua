-- =========================================================
-- SECTION 1: 模块入口
-- ResourceBars — 主/次资源条运行时、事件、轮询与生命周期
-- =========================================================

local VFlow = _G.VFlow
if not VFlow then return end

local MODULE_KEY = "VFlow.Resources"
local ModuleControlConstants = VFlow.ModuleControlConstants

if not ModuleControlConstants.RESOURCES_ENABLED then return end
local EVENT_OWNER = "Core.ResourceBars.Runtime"
local FD = VFlow.FD
local Utils = VFlow.Utils
local CR = VFlow.ClassResourceMap
local CA = VFlow.ContainerAnchor
local RS = VFlow.ResourceStyles
local CustomTrackers = VFlow.ResourceCustomTrackers or {}
local BFK = VFlow.BarFrameKit
local PP = VFlow.PixelPerfect
local E_PT = _G.Enum and Enum.PowerType

local RR = VFlow._RR
local IsSecretNumber = RR.IsSecretNumber
local IsPositivePlainNumber = RR.IsPositivePlainNumber

local rb = {}
local RefreshAll, RefreshValuesOnly

-- =========================================================
-- SECTION 2: 运行时状态与资源解析
-- =========================================================

local runtimeEventsRegistered = false
local RESOURCE_BAR_POLL_INTERVAL = 0.2
local resourceBarPollDriver = nil

local function GetDb()
    return VFlow.getDBIfReady(MODULE_KEY)
end

local function CurrentSpecId()
    local specIndex = C_SpecializationInfo.GetSpecialization()
    return C_SpecializationInfo.GetSpecializationInfo(specIndex)
end

local function GetCustomResourceTracker(resource)
    if not resource then return nil end
    return CustomTrackers[resource]
end

local function NotifyTrackersOfSharedRuntimeEvent(event)
    for _, tracker in pairs(CustomTrackers) do
        if tracker and tracker.OnSharedRuntimeEvent then
            tracker.OnSharedRuntimeEvent(event)
        end
    end
end

local function ResolveRuntimeResourceToken(resourceToken)
    if not resourceToken then return nil end
    if RS and RS.StyleKeyToRuntimeResource then
        return RS.StyleKeyToRuntimeResource(resourceToken)
    end
    return resourceToken
end

local function FindActiveResourceRow(specID, formID)
    local rows = CR and CR.GetRowsForPlayer and CR.GetRowsForPlayer() or nil
    if not rows then return nil end
    local fallbackRow
    for _, row in ipairs(rows) do
        if row.specId == specID then
            if row.formId == formID then return row end
            if row.formId == nil then fallbackRow = row end
        end
    end
    return fallbackRow
end

local function BuildRuntimeContext(db, forceRebuild)
    local existing = rb._runtimeContext
    if existing and not forceRebuild and rb._runtimeContextDirty ~= true then
        existing.db = db or GetDb()
        return existing
    end
    local specID = CurrentSpecId()
    local row = FindActiveResourceRow(specID, GetShapeshiftFormID())
    local primaryResource = ResolveRuntimeResourceToken(row and row.primary)
    local secondaryResource = ResolveRuntimeResourceToken(row and row.secondary)
    if primaryResource ~= nil and primaryResource == secondaryResource then
        secondaryResource = nil
    end
    rb._runtimeContext = rb._runtimeContext or {}
    local context = rb._runtimeContext
    context.db = db or GetDb()
    context.specID = specID
    context.primaryResource = primaryResource
    context.secondaryResource = secondaryResource
    rb._runtimeContextDirty = false
    return context
end

local function MarkRuntimeContextDirty()
    rb._runtimeContextDirty = true
end

-- =========================================================
-- SECTION 3: 能量值获取
-- =========================================================

--- 符文快照引用（写入后 ResourceRender 的 BuildRuneSegmentState 读取）
local runeCooldownSnapshot = RR.runeCooldownSnapshot

local function GetRuneMaxCurrentAndFillSnapshot()
    if not E_PT then return nil, nil end
    local max = UnitPowerMax("player", E_PT.Runes)
    if not IsPositivePlainNumber(max) then return nil, nil end
    local current = 0
    for i = 1, max do
        local slot = runeCooldownSnapshot[i]
        local start, duration, runeReady = GetRuneCooldown(i)
        slot.start = start
        slot.duration = duration
        slot.runeReady = runeReady
        if runeReady then
            current = current + 1
        end
    end
    return max, current
end

local function GetPrimaryResourceValue(resource)
    if not resource then return nil, nil end
    if E_PT and resource == E_PT.Runes then
        return GetRuneMaxCurrentAndFillSnapshot()
    end
    local max = UnitPowerMax("player", resource)
    local cur = UnitPower("player", resource)
    if not IsSecretNumber(max) and type(max) == "number" and max <= 0 then
        return nil, nil
    end
    return max, cur
end

local function GetSecondaryResourceValue(resource)
    if not resource then return nil, nil end
    local tracker = GetCustomResourceTracker(resource)
    if tracker and tracker.GetValue then
        return tracker.GetValue()
    end

    if resource == "STAGGER" then
        local stagger = UnitStagger("player") or 0
        local maxHealth = UnitHealthMax("player")
        if IsSecretNumber(stagger) or IsSecretNumber(maxHealth) then
            return maxHealth, stagger
        end
        if type(maxHealth) ~= "number" or maxHealth <= 0 then
            return nil, nil
        end
        RR.lastStaggerPercent = (stagger / maxHealth) * 100
        return maxHealth, stagger
    end

    if resource == "SOUL_FRAGMENTS_VENGEANCE" then
        local current = 0
        if C_Spell and C_Spell.GetSpellCastCount then
            current = C_Spell.GetSpellCastCount(228477) or 0
        end
        return 6, current
    end

    if resource == "SOUL_FRAGMENTS" or resource == "DEVOURER_SOUL" then
        local auraData = C_UnitAuras.GetPlayerAuraBySpellID(1225789) or C_UnitAuras.GetPlayerAuraBySpellID(1227702)
        local current = auraData and auraData.applications or 0
        local max = (C_SpellBook and C_SpellBook.IsSpellKnown(1247534)) and 35 or 50
        return max, current
    end

    if E_PT and resource == E_PT.Runes then
        return GetRuneMaxCurrentAndFillSnapshot()
    end

    if resource == Enum.PowerType.SoulShards then
        local spec = C_SpecializationInfo.GetSpecialization()
        local specID = C_SpecializationInfo.GetSpecializationInfo(spec)
        -- 毁灭：UnitPower(..., true) 为整碎片*10 + 小数格
        if specID == 267 then
            local raw = UnitPower("player", resource, true)
            if IsSecretNumber(raw) then
                local cur0 = UnitPower("player", resource, false)
                local max0 = UnitPowerMax("player", resource, false)
                if not IsPositivePlainNumber(max0) then return nil, nil end
                return max0, cur0
            end
            local r = tonumber(raw) or 0
            local curShards = math.floor(r / 10) + (r % 10) / 10
            local maxP = UnitPowerMax("player", resource, false) or 5
            if not IsPositivePlainNumber(maxP) then return nil, nil end
            return maxP, curShards
        end
        local cur = UnitPower("player", resource, false)
        local max = UnitPowerMax("player", resource, false)
        if not IsPositivePlainNumber(max) then return nil, nil end
        return max, cur
    end

    if resource == "MAELSTROM_WEAPON" then
        local auraData = C_UnitAuras.GetPlayerAuraBySpellID(344179)
        local current = auraData and auraData.applications or 0
        return 10, current
    end

    if resource == "TIP_OF_THE_SPEAR" then
        local auraData = C_UnitAuras.GetPlayerAuraBySpellID(260286)
        local current = auraData and auraData.applications or 0
        return 3, current
    end

    if resource == "ICICLES" then
        local auraData = C_UnitAuras.GetPlayerAuraBySpellID(205473)
        local current = auraData and auraData.applications or 0
        return 5, current
    end

    local cur = UnitPower("player", resource)
    local max = UnitPowerMax("player", resource)
    if not IsPositivePlainNumber(max) then return nil, nil end
    return max, cur
end

-- =========================================================
-- SECTION 4: 帧引用与布局
-- =========================================================

local primaryHost, secondaryHost
local primarySB, secondarySB
local primaryText, secondaryText
local initialized = false

local function GetBarHostPixelDimensions(cfg)
    local along = Utils.ResolveSyncedBarSpan(cfg, {
        manualKey = "barWidth",
        modeKey = "barWidthMode",
        defaultMode = "sync_essential",
    })
    local thick = cfg.barHeight or 16
    if cfg and cfg.barDirection == "vertical" then
        return thick, along
    end
    return along, thick
end

--- 运行时刷新只消费现有配置，不反写 Store
local function ApplyLayoutHost(host, layoutCfg, anchorCfg)
    if not host or not layoutCfg then return end
    anchorCfg = anchorCfg or layoutCfg
    local w, h = GetBarHostPixelDimensions(layoutCfg)
    if PP and PP.SetSize then
        PP.SetSize(host, w, h)
    else
        host:SetSize(w, h)
    end
    local DF = VFlow.DragFrame
    if not (DF and DF.isHostDragging and DF.isHostDragging(host)) then
        CA.ApplyFramePosition(host, anchorCfg, nil)
    end
end

local function SecondaryAnchorsToPrimaryBar(db)
    return db and db.secondaryBar
        and db.secondaryBar.usePrimaryPositionWhenPrimaryHidden ~= false
        and primaryHost
        and not primaryHost:IsShown()
end

local function SecondaryAnchorOwner(db)
    if SecondaryAnchorsToPrimaryBar(db) then return "primary" end
    return "secondary"
end

local function AnchorConfigForSecondary(db)
    if not db or not db.secondaryBar then return nil end
    if SecondaryAnchorsToPrimaryBar(db) then return db.primaryBar end
    return db.secondaryBar
end

local function EditModeActive()
    return VFlow.State and (VFlow.State.isEditMode or VFlow.State.systemEditMode or VFlow.State.internalEditMode) or false
end

local function ResourceNeedsContinuousValueRefresh(resource)
    return E_PT and (resource == E_PT.Essence or resource == E_PT.Runes)
end

local function CanSkipValueOnlyRefresh(host, resource, max, cur, style)
    if not host or not style then return false end
    if ResourceNeedsContinuousValueRefresh(resource) then return false end
    if IsSecretNumber(max) or IsSecretNumber(cur) then return false end
    local fd = FD(host)
    return fd.lastValueResource == resource
        and fd.lastValueMax == max
        and fd.lastValueCur == cur
        and fd.lastValueShowText == (style.showText ~= false)
end

local function RememberLastValueState(host, resource, max, cur, style)
    if not host or IsSecretNumber(max) or IsSecretNumber(cur) then
        if host then
            local fd = FD(host)
            fd.lastValueResource = nil
            fd.lastValueMax = nil
            fd.lastValueCur = nil
            fd.lastValueShowText = nil
        end
        return
    end
    local fd = FD(host)
    fd.lastValueResource = resource
    fd.lastValueMax = max
    fd.lastValueCur = cur
    fd.lastValueShowText = style and (style.showText ~= false) or false
end

--- 全局显隐策略
local function StyleDisplayForcesResourceBarHide()
    local VC = VFlow.VisibilityControl
    if VC and VC.ShouldApplyGlobalVisibilityHide then
        return VC.ShouldApplyGlobalVisibilityHide("resourceBars")
    end
    return false
end

local function SetResourceHostShown(host, wantShown)
    if not host then return end
    if StyleDisplayForcesResourceBarHide() then
        if host:IsShown() then host:Hide() end
        return
    end
    if wantShown and not host:IsShown() then
        host:Show()
    elseif not wantShown and host:IsShown() then
        host:Hide()
    end
end

-- =========================================================
-- SECTION 5: 单槽刷新
-- =========================================================

---@param skipLayout boolean|nil true 时跳过尺寸/锚点/字体，仅刷新数值
local function UpdateOneSlot(context, isSecondary, skipLayout)
    local db = context and context.db or GetDb()
    if not db then return end
    local cfg, host, sb, fs
    if isSecondary then
        cfg = db.secondaryBar
        host = secondaryHost
        sb = secondarySB
        fs = secondaryText
    else
        cfg = db.primaryBar
        host = primaryHost
        sb = primarySB
        fs = primaryText
    end
    if not host or not cfg or not sb then return end

    FD(host).slotIsSecondary = isSecondary

    local forceLayout = skipLayout ~= true
    local anchorCfg = nil
    if isSecondary then
        anchorCfg = AnchorConfigForSecondary(db)
        local desiredAnchorOwner = SecondaryAnchorOwner(db)
        if skipLayout and FD(host).anchorOwner ~= nil and FD(host).anchorOwner ~= desiredAnchorOwner then
            forceLayout = true
        end
    end

    if forceLayout then
        ApplyLayoutHost(host, cfg, anchorCfg)
        RR.ApplyTextFont(fs, cfg.textFont)
        RR.ApplyBarBackground(host, db)
        FD(sb).fillColorSig = nil
        if BFK and BFK.ApplyResourceBarChrome then
            BFK.ApplyResourceBarChrome(host, cfg)
        end
        if isSecondary then
            FD(host).anchorOwner = SecondaryAnchorOwner(db)
        end
    end

    if C_PetBattles and C_PetBattles.IsInBattle and C_PetBattles.IsInBattle() then
        RR.ClearSegmentUI(host)
        host:Hide()
        return
    end

    if cfg.enabled == false then
        RR.ClearSegmentUI(host)
        host:Hide()
        return
    end

    local specID = context and context.specID or CurrentSpecId()
    if CR and CR.IsBarEnabledForSpec and not CR.IsBarEnabledForSpec(cfg, specID) then
        RR.ClearSegmentUI(host)
        host:Hide()
        return
    end

    local resource
    if isSecondary then
        resource = context and context.secondaryResource or nil
    else
        resource = context and context.primaryResource or nil
    end

    if not resource then
        if EditModeActive() then
            RR.ClearSegmentUI(host)
            local placeholderResource = (E_PT and E_PT.Mana) or "MANA"
            local phStyle = RS.ResolveStyle(db, placeholderResource)
            SetResourceHostShown(host, true)
            RR.ApplyBarProgressCached(sb, 0, 5, 4, false)
            RR.ApplyMainBarFillColor(sb, placeholderResource, phStyle, 4, 5)
            RR.SetTextIfChanged(fs, "4")
            RR.SetShownIfChanged(fs, phStyle.showText ~= false)
        else
            RR.ClearSegmentUI(host)
            host:Hide()
        end
        return
    end

    local style = RS.ResolveStyle(db, resource)

    local max, cur
    if isSecondary then
        max, cur = GetSecondaryResourceValue(resource)
    else
        max, cur = GetPrimaryResourceValue(resource)
    end

    if max == nil then
        if EditModeActive() then
            RR.ClearSegmentUI(host)
            SetResourceHostShown(host, true)
            RR.ApplyBarProgressCached(sb, 0, 5, 4, false)
            RR.ApplyMainBarFillColor(sb, type(resource) == "number" and resource or ((E_PT and E_PT.Mana) or "MANA"), style, 4, 5)
            RR.SetTextIfChanged(fs, "4")
            RR.SetShownIfChanged(fs, style.showText ~= false)
        else
            RR.ClearSegmentUI(host)
            host:Hide()
        end
        return
    end

    SetResourceHostShown(host, true)
    if skipLayout and CanSkipValueOnlyRefresh(host, resource, max, cur, style) then
        return
    end
    local segOn = RR.UpdateDiscreteSegmentDisplay(host, cfg, db, resource, max, cur, style, skipLayout)
    if not segOn then
        RR.ApplyBarProgressCached(sb, 0, max, cur, RR.BarUsesSmooth(cfg))
        RR.ApplyMainBarFillColor(sb, resource, style, cur, max)
    end
    if style.showText ~= false then
        RR.SetTextIfChanged(fs, RR.FormatText(style, max, cur, resource))
    else
        RR.SetTextIfChanged(fs, "")
    end
    RR.SetShownIfChanged(fs, style.showText ~= false)
    RememberLastValueState(host, resource, max, cur, style)
end

-- =========================================================
-- SECTION 6: 刷新调度与运行时事件
-- =========================================================

local function StartResourceBarValuePoll()
    if resourceBarPollDriver then return end
    local f = CreateFrame("Frame", "VFlow_ResourceBarPollDriver", UIParent)
    f:SetSize(1, 1)
    f:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 0, 0)
    f:EnableMouse(false)
    f:SetAlpha(0)
    f:Show()
    f:SetScript("OnUpdate", function(self, dt)
        FD(self).pollElapsed = (FD(self).pollElapsed or 0) + dt
        if FD(self).pollElapsed >= RESOURCE_BAR_POLL_INTERVAL then
            FD(self).pollElapsed = 0
            RefreshValuesOnly()
        end
    end)
    resourceBarPollDriver = f
end

RefreshAll = function()
    local context = BuildRuntimeContext(nil, true)
    UpdateOneSlot(context, false, false)
    UpdateOneSlot(context, true, false)
end

local function RefreshLayoutOnly()
    local context = BuildRuntimeContext(nil, false)
    UpdateOneSlot(context, false, false)
    UpdateOneSlot(context, true, false)
end

local function RefreshVisibilityOnly()
    local context = BuildRuntimeContext(nil, false)
    UpdateOneSlot(context, false, true)
    UpdateOneSlot(context, true, true)
end

--- 双槽均隐藏且非编辑模式时跳过轮询
local function ResourceBarsPollShouldSkip()
    if EditModeActive() then return false end
    local p = primaryHost
    local s = secondaryHost
    if (not p or not p:IsShown()) and (not s or not s:IsShown()) then
        return true
    end
    return false
end

local function RuntimeContextNeedsRecovery(context)
    if not context then return true end
    if context.specID == nil then return true end
    if primaryHost and not primaryHost:IsShown() and context.primaryResource == nil then
        return true
    end
    if secondaryHost and not secondaryHost:IsShown() and context.secondaryResource == nil then
        local row = FindActiveResourceRow(context.specID, GetShapeshiftFormID())
        local expectedSecondary = ResolveRuntimeResourceToken(row and row.secondary)
        if expectedSecondary ~= nil then return true end
    end
    return false
end

RefreshValuesOnly = function()
    local context = BuildRuntimeContext(nil, false)
    if RuntimeContextNeedsRecovery(context) then
        context = BuildRuntimeContext(nil, true)
    end
    if ResourceBarsPollShouldSkip() and not RuntimeContextNeedsRecovery(context) then
        return
    end
    UpdateOneSlot(context, false, true)
    UpdateOneSlot(context, true, true)
end

local function HandleLayoutRuntimeEvent(event)
    NotifyTrackersOfSharedRuntimeEvent(event)
    MarkRuntimeContextDirty()
    RefreshAll()
end

local function RegisterCustomTrackerEvents(registerEvent)
    for _, tracker in pairs(CustomTrackers) do
        if tracker and tracker.RegisterEvents then
            tracker.RegisterEvents(registerEvent, {
                refreshAll = RefreshAll,
                refreshValuesOnly = RefreshValuesOnly,
                markRuntimeContextDirty = MarkRuntimeContextDirty,
            })
        end
    end
end

local function RegisterRuntimeEvents()
    if runtimeEventsRegistered then return end
    runtimeEventsRegistered = true
    local registerEvent = function(event, owner, callback, units)
        VFlow.on(event, owner, callback, units)
    end
    registerEvent("PLAYER_SPECIALIZATION_CHANGED", EVENT_OWNER, HandleLayoutRuntimeEvent, "player")
    registerEvent("PLAYER_REGEN_ENABLED", EVENT_OWNER, HandleLayoutRuntimeEvent, nil)
    registerEvent("PLAYER_REGEN_DISABLED", EVENT_OWNER, HandleLayoutRuntimeEvent, nil)
    RegisterCustomTrackerEvents(registerEvent)
    if select(2, UnitClass("player")) == "DRUID" then
        registerEvent("UPDATE_SHAPESHIFT_FORM", EVENT_OWNER, HandleLayoutRuntimeEvent, nil)
    end
    StartResourceBarValuePoll()
end

-- =========================================================
-- SECTION 7: UI 帧生命周期
-- =========================================================

local function EnsureFrames()
    if primaryHost and secondaryHost then return end

    if not primaryHost then
        primaryHost = CreateFrame("Frame", "VFlow_ResourceBarPrimary", UIParent, "BackdropTemplate")
        primaryHost:SetFrameStrata("MEDIUM")
        primaryHost:SetFrameLevel(20)
        primaryHost:SetClampedToScreen(true)
        primaryHost:SetMovable(true)
        primaryHost:EnableMouse(false)
        if BFK and BFK.SetupResourceBarHost then
            BFK.SetupResourceBarHost(primaryHost)
        end
        primarySB = FD(primaryHost).sb
        primaryText = RR.EnsureBarLabel(primaryHost, nil)
    else
        primarySB = FD(primaryHost).sb or primarySB
        primaryText = RR.EnsureBarLabel(primaryHost, primaryText)
    end

    if not secondaryHost then
        secondaryHost = CreateFrame("Frame", "VFlow_ResourceBarSecondary", UIParent, "BackdropTemplate")
        secondaryHost:SetFrameStrata("MEDIUM")
        secondaryHost:SetFrameLevel(21)
        secondaryHost:SetClampedToScreen(true)
        secondaryHost:SetMovable(true)
        secondaryHost:EnableMouse(false)
        if BFK and BFK.SetupResourceBarHost then
            BFK.SetupResourceBarHost(secondaryHost)
        end
        secondarySB = FD(secondaryHost).sb
        secondaryText = RR.EnsureBarLabel(secondaryHost, nil)
    else
        secondarySB = FD(secondaryHost).sb or secondarySB
        secondaryText = RR.EnsureBarLabel(secondaryHost, secondaryText)
    end
end

-- =========================================================
-- SECTION 8: 拖拽与模块生命周期
-- =========================================================

local function RegisterDrag()
    local db = GetDb()
    if not db or not primaryHost then return end

    if not FD(primaryHost).dragReg then
        VFlow.DragFrame.register(primaryHost, {
            label = (VFlow.L and VFlow.L["Primary resource bar"]) or "Primary resource",
            menuKey = "resource_primary",
            getAnchorConfig = function()
                local d = GetDb()
                return d and d.primaryBar
            end,
            onPositionChanged = function(_, kind, x, y)
                if kind ~= "PLAYER_ANCHOR" and kind ~= "SYMMETRIC" then return end
                local d = GetDb()
                if not d then return end
                d.primaryBar.x = x
                d.primaryBar.y = y
                VFlow.Store.set(MODULE_KEY, "primaryBar.x", x)
                VFlow.Store.set(MODULE_KEY, "primaryBar.y", y)
            end,
        })
        FD(primaryHost).dragReg = true
    end
    if secondaryHost and not FD(secondaryHost).dragReg then
        VFlow.DragFrame.register(secondaryHost, {
            label = (VFlow.L and VFlow.L["Secondary resource bar"]) or "Secondary resource",
            menuKey = "resource_secondary",
            getAnchorConfig = function()
                local d = GetDb()
                if not d or not d.secondaryBar then return end
                if SecondaryAnchorsToPrimaryBar(d) then return d.primaryBar end
                return d.secondaryBar
            end,
            onPositionChanged = function(_, kind, x, y)
                if kind ~= "PLAYER_ANCHOR" and kind ~= "SYMMETRIC" then return end
                local d = GetDb()
                if not d then return end
                if SecondaryAnchorsToPrimaryBar(d) then
                    d.primaryBar.x = x
                    d.primaryBar.y = y
                    VFlow.Store.set(MODULE_KEY, "primaryBar.x", x)
                    VFlow.Store.set(MODULE_KEY, "primaryBar.y", y)
                else
                    d.secondaryBar.x = x
                    d.secondaryBar.y = y
                    VFlow.Store.set(MODULE_KEY, "secondaryBar.x", x)
                    VFlow.Store.set(MODULE_KEY, "secondaryBar.y", y)
                end
            end,
        })
        FD(secondaryHost).dragReg = true
    end
    VFlow.DragFrame.applyRegisteredPosition(primaryHost)
    if secondaryHost then
        VFlow.DragFrame.applyRegisteredPosition(secondaryHost)
    end
end

rb.RefreshAll = RefreshAll
rb.RefreshVisibilityOnly = RefreshVisibilityOnly

function rb.OnSkillViewerLayoutChanged()
    local d = GetDb()
    if not d then return end
    local need = false
    for _, bar in ipairs({ d.primaryBar, d.secondaryBar }) do
        local m = bar and (bar.barWidthMode or "sync_essential")
        if m == "sync_essential" or m == "sync_utility" then
            need = true
            break
        end
    end
    if need then RefreshLayoutOnly() end
end

local MODULE_DB_DEFAULT_BG = { r = 0.2, g = 0.2, b = 0.2, a = 0.5 }

function rb.OnModuleReady()
    if initialized then
        MarkRuntimeContextDirty()
        if RS and RS.WipeRuntimeCaches then
            RS.WipeRuntimeCaches(GetDb())
        end
        RefreshAll()
        return
    end
    if not VFlow.getDBIfReady(MODULE_KEY) then return end
    local d0 = GetDb()
    if d0 and VFlow.Utils then
        d0.resourceStyles = d0.resourceStyles or {}
        VFlow.Utils.applyDefaults(d0.resourceStyles, RS.BuildFullResourceStylesDefaults())
        VFlow.Utils.applyDefaults(d0, { resourceBarBackground = MODULE_DB_DEFAULT_BG })
    end
    EnsureFrames()
    RegisterRuntimeEvents()
    if RS and RS.WipeRuntimeCaches then
        RS.WipeRuntimeCaches(d0)
    end
    RefreshAll()
    RegisterDrag()

    if not rb._storeWatched then
        rb._storeWatched = true
        VFlow.Store.watch(MODULE_KEY, "Core.ResourceBars", function(key)
            local d = GetDb()
            if not d then return end
            if key and (key:find("%.x$") or key:find("%.y$")) then
                EnsureFrames()
                ApplyLayoutHost(primaryHost, d.primaryBar)
                if d.secondaryBar and secondaryHost then
                    ApplyLayoutHost(secondaryHost, d.secondaryBar, AnchorConfigForSecondary(d))
                end
                RegisterDrag()
                return
            end
            if RS and RS.WipeRuntimeCaches then
                RS.WipeRuntimeCaches(d)
            end
            RefreshLayoutOnly()
            RegisterDrag()
        end)
    end

    initialized = true
end

VFlow.ResourceBars = rb

VFlow.on("PLAYER_ENTERING_WORLD", "ResourceBars.Boot", function()
    if VFlow.ResourceBars and VFlow.ResourceBars.OnModuleReady then
        VFlow.ResourceBars.OnModuleReady()
    end
end)
