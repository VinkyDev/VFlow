-- StyleEngine — 样式引擎入口/编排器
local VFlow = _G.VFlow
if not VFlow then return end

local FD = VFlow.FD
local ModuleControlConstants = VFlow.ModuleControlConstants
local RefreshBus = VFlow.RefreshBus
local ViewerRuntime = VFlow.ViewerRuntime
local StyleApply = VFlow.StyleApply
local StyleLayout = VFlow.StyleLayout
local SkillStylePass = VFlow.SkillStylePass
local SkillPostPass = VFlow.SkillPostPass
local ViewerRefreshQueue = VFlow.ViewerRefreshQueue

local CORE_ENABLED = ModuleControlConstants.CORE_ENABLED
local BUFF_BAR_ENABLED = ModuleControlConstants.BUFF_BAR_ENABLED
if not (CORE_ENABLED or BUFF_BAR_ENABLED) then return end

local StyleSkill = VFlow.StyleSkill
local StyleBuff = VFlow.StyleBuff

local QK_ESSENTIAL = "EssentialCooldownViewer"
local QK_UTILITY = "UtilityCooldownViewer"
local QK_BUFF_ICONS = "BuffIconCooldownViewer"
local QK_BUFF_BAR = "BuffBarCooldownViewer"

local viewerPhaseRegistered = false
local skillRefreshPending = false
local specDrivenSkillRefreshPending = false
local hooked = false

-- =========================================================
-- 样式版本
-- =========================================================
local _buttonStyleVersion = 0
VFlow._buttonStyleVersion = _buttonStyleVersion

local function BumpButtonStyleVersion()
    _buttonStyleVersion = _buttonStyleVersion + 1
    VFlow._buttonStyleVersion = _buttonStyleVersion
end

-- =========================================================
-- 请求分发
-- =========================================================

local function RequestNamedViewers(scopeOrScopes, viewerNames, opts)
    if not (RefreshBus and RefreshBus.requestViewers) then return end
    local filtered = {}
    for _, viewerName in ipairs(viewerNames or {}) do
        if viewerName == QK_BUFF_ICONS then
            if CORE_ENABLED then filtered[#filtered + 1] = viewerName end
        elseif viewerName == QK_BUFF_BAR then
            if BUFF_BAR_ENABLED then filtered[#filtered + 1] = viewerName end
        else
            filtered[#filtered + 1] = viewerName
        end
    end
    if not filtered[1] then return end
    RefreshBus.requestViewers(scopeOrScopes, filtered, opts or {})
end

-- 供 StyleBuff 运行时回退使用
VFlow._RequestNamedViewers = RequestNamedViewers

local function RequestSkillRefresh(scopeOrScopes, opts)
    if not CORE_ENABLED then return end
    if not (RefreshBus and RefreshBus.requestAllSkillViewers) then return end
    opts = opts or {}
    if opts.viewers then
        RefreshBus.requestSkillViewers(scopeOrScopes, opts.viewers, opts)
    else
        RefreshBus.requestAllSkillViewers(scopeOrScopes, opts)
    end
end

local function RequestDelayedSkillRefresh(delay, scopeOrScopes, opts)
    if delay and delay > 0 then
        if skillRefreshPending then return end
        skillRefreshPending = true
        C_Timer.After(delay, function()
            skillRefreshPending = false
            RequestSkillRefresh(scopeOrScopes, opts)
        end)
        return
    end
    RequestSkillRefresh(scopeOrScopes, opts)
end

VFlow.RequestSkillRefresh = RequestSkillRefresh

-- =========================================================
-- RefreshBus 阶段注册
-- =========================================================

local function CopyRequestOpts(opts)
    local out = {}
    for key, value in pairs(opts or {}) do
        out[key] = value
    end
    return out
end

local function RegisterViewerRefreshPhases()
    if viewerPhaseRegistered or not RefreshBus then return end
    viewerPhaseRegistered = true

    RefreshBus.register(RefreshBus.SCOPES.SKILL_GROUP_MAP, "CooldownStyle_SkillGroupMap", StyleSkill.RunSkillDataPhase)
    RefreshBus.register(RefreshBus.SCOPES.SKILL_DATA, "CooldownStyle_SkillData", StyleSkill.RunSkillDataPhase)
    RefreshBus.register(RefreshBus.SCOPES.ITEM_APPEND_LAYOUT, "CooldownStyle_ItemAppend", StyleSkill.RunSkillDataPhase)
    RefreshBus.register(RefreshBus.SCOPES.SKILL_LAYOUT, "CooldownStyle_SkillLayout", StyleSkill.RunSkillLayoutPhase)
    RefreshBus.register(RefreshBus.SCOPES.SKILL_GROUP_LAYOUT, "CooldownStyle_SkillGroupLayout", StyleSkill.RunSkillGroupLayoutPhase)
    RefreshBus.register(RefreshBus.SCOPES.SKILL_STYLE, "CooldownStyle_SkillStyle", StyleSkill.RunSkillStylePhase)
    RefreshBus.register(RefreshBus.SCOPES.SKILL_COOLDOWN, "CooldownStyle_SkillCooldownOnly", function()
        StyleSkill.RunSkillCooldownOnlyPhase()
    end)
    RefreshBus.register(RefreshBus.SCOPES.BUFF_LAYOUT, "CooldownStyle_BuffLayout", function(context)
        if not CORE_ENABLED then return end
        if context.dirtyViewers and context.dirtyViewers[QK_BUFF_ICONS] then
            StyleBuff.DoBuffRefresh(0)
        end
    end)
    RefreshBus.register(RefreshBus.SCOPES.BUFFBAR_LAYOUT, "CooldownStyle_BuffBarLayout", function(context)
        if not BUFF_BAR_ENABLED then return end
        if context.dirtyViewers and context.dirtyViewers[QK_BUFF_BAR] then
            StyleBuff.DoBuffBarRefresh(0)
        end
    end)
    RefreshBus.register(RefreshBus.SCOPES.HIGHLIGHT, "CooldownStyle_Highlight", function(context)
        if not CORE_ENABLED then return end
        if SkillPostPass and SkillPostPass.RunHighlights then
            SkillPostPass.RunHighlights(context)
        end
    end)
    RefreshBus.register(RefreshBus.SCOPES.DEPENDENT_LAYOUT, "CooldownStyle_Dependents", function(context)
        if not CORE_ENABLED then return end
        if SkillPostPass and SkillPostPass.RunDependents then
            SkillPostPass.RunDependents(context)
        end
    end)
end

RegisterViewerRefreshPhases()

-- =========================================================
-- SkillPostPass 注册
-- =========================================================

if SkillPostPass and SkillPostPass.registerHighlight then
    SkillPostPass.registerHighlight("CooldownStyle_SkillHighlightViewer", function(context)
        for _, layoutResult in ipairs(context.viewerLayoutResults or {}) do
            StyleBuff.ScanCooldownViewerIcons(layoutResult.viewer, layoutResult.allIcons)
        end
        StyleBuff.ScanSkillGroupCustomHighlights()
    end)
end

if SkillPostPass and SkillPostPass.registerDependent then
    SkillPostPass.registerDependent("CooldownStyle_SkillDependents", function(context)
        local force = context and context.flags and context.flags.forceDependentLayout
        StyleSkill.NotifySkillViewerLayoutDependents(force == true)
    end)
end

-- =========================================================
-- SetupHooks — Viewer 注册
-- =========================================================

local SetupHooks

local function RequestInitialViewerRefresh()
    if CORE_ENABLED then
        RequestSkillRefresh(RefreshBus.PRESETS.SKILL_FULL, {
            flags = { forceDependentLayout = true },
        })
    end

    local get = VFlow and VFlow.Store and VFlow.Store.getModuleRef
    local buffsDB = CORE_ENABLED and get and get("VFlow.Buffs") or nil
    local buffBarDB = BUFF_BAR_ENABLED and get and get("VFlow.BuffBar") or nil

    if buffsDB and buffsDB.buffMonitor then
        StyleBuff.RequestBuffRefresh()
    end
    if buffBarDB then
        StyleBuff.RequestBuffBarRefresh()
    end
end

local function RequestSpecDrivenSkillRefresh()
    if not CORE_ENABLED or specDrivenSkillRefreshPending then return end
    specDrivenSkillRefreshPending = true
    -- 专精切换时，CDM/档案绑定可能在当前事件帧后才稳定
    C_Timer.After(0.1, function()
        specDrivenSkillRefreshPending = false
        RequestSkillRefresh(RefreshBus.PRESETS.SKILL_FULL, {
            flags = { forceDependentLayout = true },
        })
    end)
end

local function RequestKeybindStyleRefresh(delay)
    if not CORE_ENABLED then return end
    BumpButtonStyleVersion()
    RequestDelayedSkillRefresh(delay, RefreshBus.PRESETS.SKILL_STYLE)
end

VFlow.RequestKeybindStyleRefresh = RequestKeybindStyleRefresh

SetupHooks = function()
    if hooked then return end

    local TouchCustomHighlight = StyleBuff.TouchCustomHighlight
    local EnsureCustomHighlightHooks = StyleBuff.EnsureCustomHighlightHooks

    local queueBuffIconAfterHighlight = function(frame)
        if not frame then return end
        StyleLayout.InvalidateCooldownViewerInfoCache(frame)
        FD(frame).cdmKind = "buff"
        local viewer, cfg = StyleBuff.GetBuffViewerAndConfig()
        if not viewer or not cfg then return end
        TouchCustomHighlight(frame)
        StyleBuff.RequestBuffRefresh()
    end

    local function enforceScaleOnViewer(viewer)
        if not viewer then return end
        if viewer.SetScale and viewer:GetScale() ~= 1 then
            viewer:SetScale(1)
        end
        if viewer.itemFramePool then
            for frame in viewer.itemFramePool:EnumerateActive() do
                if frame and frame.SetScale and frame:GetScale() ~= 1 then
                    frame:SetScale(1)
                end
            end
        end
    end

    local function HookSkillFrameForCustomHighlight(viewer, frame)
        if not frame then return end
        if viewer then StyleLayout.InvalidateCollectIconsCache(viewer) end
        FD(frame).cdmKind = "skill"
        if frame.OnCooldownIDSet and not frame._vf_skillCDHooked then
            frame._vf_skillCDHooked = true
            hooksecurefunc(frame, "OnCooldownIDSet", function(self)
                StyleLayout.InvalidateCooldownViewerInfoCache(self)
                if StyleApply and StyleApply.InvalidateButtonStyle then
                    StyleApply.InvalidateButtonStyle(self)
                end
                if StyleApply and StyleApply.SyncSpellOnlyCooldownWatcher then
                    StyleApply.SyncSpellOnlyCooldownWatcher(self)
                end
                TouchCustomHighlight(self)
            end)
        end
        EnsureCustomHighlightHooks(frame)
        TouchCustomHighlight(frame)
    end

    local function registerSkillViewer(name, enablePoolRelease)
        ViewerRuntime.register({
            name = name,
            lockViewerScale = true,
            lockFrameScale = true,
            invalidateCollectIcons = true,
            hookRefreshLayout = true,
            hookRefreshData = false,
            hookUpdateLayout = false,
            hookPoolRelease = enablePoolRelease == true,
            requestMap = {
                refreshLayout = RefreshBus.PRESETS.SKILL_LAYOUT,
                onShow = RefreshBus.PRESETS.SKILL_FULL,
                acquire = {
                    RefreshBus.SCOPES.SKILL_DATA,
                    RefreshBus.SCOPES.ITEM_APPEND_LAYOUT,
                    RefreshBus.SCOPES.SKILL_LAYOUT,
                    RefreshBus.SCOPES.SKILL_GROUP_LAYOUT,
                    RefreshBus.SCOPES.HIGHLIGHT,
                    RefreshBus.SCOPES.DEPENDENT_LAYOUT,
                },
                poolRelease = RefreshBus.PRESETS.SKILL_LAYOUT,
            },
            requestHandler = function(scopes, viewers, opts)
                local reqOpts = CopyRequestOpts(opts)
                reqOpts.viewers = viewers
                RequestSkillRefresh(scopes, reqOpts)
            end,
            onSetup = function(viewer)
                enforceScaleOnViewer(viewer)
                if viewer.UpdateSystemSettingIconSize then
                    hooksecurefunc(viewer, "UpdateSystemSettingIconSize", function()
                        enforceScaleOnViewer(viewer)
                    end)
                end
            end,
            onShow = function(viewer)
                enforceScaleOnViewer(viewer)
            end,
            onAcquireFrame = function(viewer, frame)
                HookSkillFrameForCustomHighlight(viewer, frame)
            end,
        })
    end

    if CORE_ENABLED then
        registerSkillViewer(QK_ESSENTIAL, false)
        registerSkillViewer(QK_UTILITY, true)
    end

    if CORE_ENABLED then
        ViewerRuntime.register({
            name = QK_BUFF_ICONS,
            lockViewerScale = true,
            lockFrameScale = true,
            invalidateCollectIcons = true,
            hookRefreshLayout = true,
            hookRefreshData = true,
            hookUpdateLayout = true,
            requestMap = {
                manual = RefreshBus.PRESETS.BUFF_FULL,
                refreshLayout = RefreshBus.PRESETS.BUFF_FULL,
                refreshData = RefreshBus.PRESETS.BUFF_FULL,
                updateLayout = RefreshBus.PRESETS.BUFF_FULL,
                onShow = RefreshBus.PRESETS.BUFF_FULL,
                acquire = RefreshBus.PRESETS.BUFF_FULL,
            },
            requestHandler = function(scopes, viewers, opts)
                RequestNamedViewers(scopes, viewers, opts)
            end,
            onSetup = function(viewer)
                enforceScaleOnViewer(viewer)
            end,
            onAcquireFrame = function(_, frame)
                if frame.OnCooldownIDSet and not frame._vf_cdIDHooked then
                    frame._vf_cdIDHooked = true
                    hooksecurefunc(frame, "OnCooldownIDSet", function(self)
                        StyleLayout.InvalidateCooldownViewerInfoCache(self)
                        queueBuffIconAfterHighlight(self)
                    end)
                end
                if frame.OnActiveStateChanged and not frame._vf_activeStateHooked then
                    frame._vf_activeStateHooked = true
                    hooksecurefunc(frame, "OnActiveStateChanged", function(self)
                        if not self then return end
                        FD(self).cdmKind = "buff"
                        TouchCustomHighlight(self)
                        StyleBuff.RequestBuffRefresh()
                    end)
                end
                FD(frame).cdmKind = "buff"
                TouchCustomHighlight(frame)
            end,
        })

        if CooldownViewerBuffIconItemMixin and CooldownViewerBuffIconItemMixin.OnCooldownIDSet then
            hooksecurefunc(CooldownViewerBuffIconItemMixin, "OnCooldownIDSet", function(frame)
                if frame then StyleLayout.InvalidateCooldownViewerInfoCache(frame) end
                queueBuffIconAfterHighlight(frame)
            end)
        end
    end

    if BUFF_BAR_ENABLED then
        ViewerRuntime.register({
            name = QK_BUFF_BAR,
            lockViewerScale = false,
            lockFrameScale = true,
            invalidateCollectIcons = false,
            hookRefreshLayout = false,
            hookRefreshData = false,
            hookUpdateLayout = false,
            hookPoolRelease = true,
            requestMap = {
                manual = RefreshBus.PRESETS.BUFFBAR_FULL,
                onShow = RefreshBus.PRESETS.BUFFBAR_FULL,
                acquire = RefreshBus.PRESETS.BUFFBAR_FULL,
                poolRelease = RefreshBus.PRESETS.BUFFBAR_FULL,
            },
            requestHandler = function(scopes, viewers, opts)
                RequestNamedViewers(scopes, viewers, opts)
            end,
            onAcquireFrame = function(_, frame)
                local viewer, cfg = StyleBuff.GetBuffBarViewerAndConfig()
                if not viewer or not cfg then return end

                if frame.SetScale then frame:SetScale(1) end

                local fd = FD(frame)
                if frame.OnActiveStateChanged and not frame._vf_buffBarActiveStateHooked then
                    frame._vf_buffBarActiveStateHooked = true
                    fd.barLastShown = frame.IsShown and frame:IsShown() or false
                    hooksecurefunc(frame, "OnActiveStateChanged", function(self)
                        if not self then return end
                        local shown = self.IsShown and self:IsShown() or false
                        local sfd = FD(self)
                        if sfd.barLastShown == shown then return end
                        sfd.barLastShown = shown
                        StyleBuff.RequestBuffBarRefresh()
                    end)
                end

                fd.barStyled = false
                fd.barLastShown = frame.IsShown and frame:IsShown() or false
                StyleBuff.ApplyBuffBarFrameStyle(frame, cfg, StyleBuff.ResolveBuffBarWidth(cfg), cfg.barHeight or 20)
            end,
        })
    end

    if CORE_ENABLED and EventRegistry then
        EventRegistry:RegisterCallback("CooldownViewerSettings.OnDataChanged", function()
            RequestDelayedSkillRefresh(0.2, RefreshBus.PRESETS.SKILL_FULL)
        end)
    end

    ViewerRuntime.setupAll()
    hooked = true
end

-- =========================================================
-- 初始化
-- =========================================================

VFlow.on("PLAYER_ENTERING_WORLD", "VFlow.SkillStyle", function()
    if not (CORE_ENABLED or BUFF_BAR_ENABLED) then return end
    StyleBuff.InvalidateDBCache()
    BumpButtonStyleVersion()
    StyleBuff.BumpBuffBarStyleVersion()
    if ViewerRefreshQueue then ViewerRefreshQueue.bumpVersion() end
    SetupHooks()
    C_Timer.After(0.5, RequestInitialViewerRefresh)
end)

VFlow.on("PLAYER_SPECIALIZATION_CHANGED", "VFlow.SkillStyle.SpecRefresh", function()
    RequestSpecDrivenSkillRefresh()
end)

-- =========================================================
-- Store 监听
-- =========================================================

local function IsSkillStyleConfigKey(key)
    if not key then return false end
    local lowerKey = string.lower(key)
    return lowerKey:find("font")
        or lowerKey:find("border")
        or lowerKey:find("overlay")
        or lowerKey:find("glow")
        or lowerKey:find("keybind")
        or lowerKey:find("zoom")
        or lowerKey:find("color")
        or lowerKey:find("mask")
end

local function IsSkillGroupMapConfigKey(key)
    if not key then return false end
    return key:find("%.spellIDs$")
        or key:find("^customGroups%.%d+%.config%.spellIDs")
        or key:find("%.hideInCooldownManager$")
end

if CORE_ENABLED then
    VFlow.Store.watch("VFlow.Skills", "CooldownStyle_Skills", function(key, value)
        if key:find("^customGroups%.%d+%.config%.")
            and (key:find("%.x$") or key:find("%.y$")
                or key:find("%.anchorFrame$") or key:find("%.relativePoint$")
                or key:find("%.playerAnchorPosition$")) then
            local groupIndex = tonumber(key:match("^customGroups%.(%d+)%."))
            RequestSkillRefresh(RefreshBus.SCOPES.SKILL_GROUP_LAYOUT, {
                groupIndex = groupIndex,
                flags = { reanchorOnly = true },
            })
            return
        end
        if IsSkillStyleConfigKey(key) then
            BumpButtonStyleVersion()
            if SkillStylePass and SkillStylePass.Invalidate then
                SkillStylePass.Invalidate()
            end
            RequestSkillRefresh(RefreshBus.PRESETS.SKILL_STYLE)
            return
        end
        if IsSkillGroupMapConfigKey(key) then
            RequestSkillRefresh(RefreshBus.PRESETS.SKILL_GROUP_MAP)
            return
        end
        RequestSkillRefresh(RefreshBus.PRESETS.SKILL_LAYOUT)
    end)
end

if CORE_ENABLED then
    VFlow.Store.watch("VFlow.Buffs", "CooldownStyle_Buffs", function(key, value)
        StyleBuff.InvalidateDBCache()
        if key:find("%.x$") or key:find("%.y$")
            or key:find("%.anchorFrame$") or key:find("%.relativePoint$") or key:find("%.playerAnchorPosition$") then
            return
        end
        BumpButtonStyleVersion()
        if ViewerRefreshQueue then ViewerRefreshQueue.bumpVersion() end
        StyleBuff.RequestBuffRefresh()
    end)
end

if BUFF_BAR_ENABLED then
    VFlow.Store.watch("VFlow.BuffBar", "CooldownStyle_BuffBar", function(key, value)
        StyleBuff.InvalidateDBCache()
        BumpButtonStyleVersion()
        StyleBuff.BumpBuffBarStyleVersion()
        if ViewerRefreshQueue then ViewerRefreshQueue.bumpVersion() end
        StyleBuff.RequestBuffBarRefresh()
    end)
end

if CORE_ENABLED then
    VFlow.Store.watch("VFlow.CustomMonitor", "CooldownStyle_CustomMonitor", function(key, value)
        if key:find("%.hideInCooldownManager$") then
            RequestSkillRefresh(RefreshBus.PRESETS.SKILL_LAYOUT)
        end
    end)
end

if CORE_ENABLED then
    VFlow.Store.watch("VFlow.OtherFeatures", "CooldownStyle_SharedSettingsHL", function(key, _)
        if not key then return end
        if key == "skillRules" or key:find("^skillRules%.") then
            BumpButtonStyleVersion()
            RequestSkillRefresh({
                RefreshBus.SCOPES.SKILL_STYLE,
                RefreshBus.SCOPES.HIGHLIGHT,
            })
        end
        if key == "highlightRules" or key:find("^highlightRules%.")
            or key == "highlightOnlyInCombat" then
            RequestSkillRefresh(RefreshBus.PRESETS.SKILL_HIGHLIGHT, { immediate = false })
            C_Timer.After(0, StyleBuff.RefreshAllOtherFeatureHighlights)
        end
    end)
end

if CORE_ENABLED then
    VFlow.Store.watch("VFlow.StyleIcon", "CooldownStyle_StyleIcon", function(key, value)
        BumpButtonStyleVersion()
        StyleBuff.BumpBuffBarStyleVersion()
        if SkillStylePass and SkillStylePass.Invalidate then
            SkillStylePass.Invalidate()
        end
        RequestSkillRefresh(RefreshBus.PRESETS.SKILL_STYLE)
        StyleBuff.RequestBuffRefresh()
        StyleBuff.RequestBuffBarRefresh()
    end)
end
