-- =========================================================
-- VFlow ViewerHooks
-- 职责：为 Blizzard CooldownViewer 注册 ViewerRuntime descriptor，
--       以及挂接 OnAcquireFrame / OnCooldownIDSet / OnActiveStateChanged 等 hook
--
-- 涉及 viewer：
--   - EssentialCooldownViewer / UtilityCooldownViewer（技能）
--   - BuffIconCooldownViewer（BUFF 图标）
--   - BuffBarCooldownViewer（BUFF 条形）
-- =========================================================

local VFlow = _G.VFlow
if not VFlow then return end

local ModuleControlConstants = VFlow.ModuleControlConstants
local CORE_ENABLED = ModuleControlConstants.CORE_ENABLED
local BUFF_BAR_ENABLED = ModuleControlConstants.BUFF_BAR_ENABLED

if not (CORE_ENABLED or BUFF_BAR_ENABLED) then return end

local StyleLayout = VFlow.StyleLayout
local StyleApply = VFlow.StyleApply
local RefreshBus = VFlow.RefreshBus
local ViewerRuntime = VFlow.ViewerRuntime
local CustomHighlight = VFlow.CustomHighlight
local SkillRefreshOrchestrator = VFlow.SkillRefreshOrchestrator
local BuffRuntime = VFlow.BuffRuntime
local BuffBarRuntime = VFlow.BuffBarRuntime
local Profiler = VFlow.Profiler

local ViewerHooks = {}
VFlow.ViewerHooks = ViewerHooks

local QK_ESSENTIAL = "EssentialCooldownViewer"
local QK_UTILITY = "UtilityCooldownViewer"
local QK_BUFF_ICONS = "BuffIconCooldownViewer"
local QK_BUFF_BAR = "BuffBarCooldownViewer"

-- =========================================================
-- SECTION 1: 通用辅助
-- =========================================================

local function EnforceScaleOnViewer(viewer)
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

-- =========================================================
-- SECTION 2: 技能 Viewer 注册
-- =========================================================

local function HookSkillFrameForCustomHighlight(viewer, frame)
    if not frame then return end
    if viewer then StyleLayout.InvalidateCollectIconsCache(viewer) end
    frame._vf_cdmKind = "skill"
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
            if CustomHighlight then
                CustomHighlight.touch(self)
            end
        end)
    end
    if CustomHighlight then
        CustomHighlight.ensureHooks(frame)
        CustomHighlight.touch(frame)
    end
end

local function RegisterSkillViewer(name, enablePoolRelease)
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
            local reqOpts = SkillRefreshOrchestrator.copyRequestOpts(opts)
            reqOpts.viewers = viewers
            SkillRefreshOrchestrator.requestSkillRefresh(scopes, reqOpts)
        end,
        onSetup = function(viewer)
            EnforceScaleOnViewer(viewer)
            if viewer.UpdateSystemSettingIconSize then
                hooksecurefunc(viewer, "UpdateSystemSettingIconSize", function()
                    EnforceScaleOnViewer(viewer)
                end)
            end
        end,
        onShow = function(viewer)
            EnforceScaleOnViewer(viewer)
        end,
        onAcquireFrame = function(viewer, frame)
            HookSkillFrameForCustomHighlight(viewer, frame)
        end,
    })
end

-- =========================================================
-- SECTION 3: BUFF 图标 Viewer 注册
-- =========================================================

local function RegisterBuffIconViewer()
    local function queueBuffIconAfterHighlight(frame)
        if not frame then return end
        StyleLayout.InvalidateCooldownViewerInfoCache(frame)
        frame._vf_cdmKind = "buff"
        if not BuffRuntime then return end
        local viewer, cfg = BuffRuntime.getBuffViewerAndConfig()
        if not viewer or not cfg then return end
        if CustomHighlight then CustomHighlight.touch(frame) end
        if BuffRuntime.requestBuffRefresh then
            BuffRuntime.requestBuffRefresh()
        end
    end

    if Profiler and Profiler.registerCount then
        Profiler.registerCount("CDS:queueBuffIconAfterHighlight", function()
            return queueBuffIconAfterHighlight
        end, function(fn)
            queueBuffIconAfterHighlight = fn
        end)
    end

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
            if RefreshBus and RefreshBus.requestViewers then
                RefreshBus.requestViewers(scopes, viewers, opts or {})
            end
        end,
        onSetup = function(viewer)
            EnforceScaleOnViewer(viewer)
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
                    self._vf_cdmKind = "buff"
                    if CustomHighlight then CustomHighlight.touch(self) end
                    if BuffRuntime and BuffRuntime.requestBuffRefresh then
                        BuffRuntime.requestBuffRefresh()
                    end
                end)
            end
            frame._vf_cdmKind = "buff"
            if CustomHighlight then CustomHighlight.touch(frame) end
        end,
    })

    if CooldownViewerBuffIconItemMixin and CooldownViewerBuffIconItemMixin.OnCooldownIDSet then
        hooksecurefunc(CooldownViewerBuffIconItemMixin, "OnCooldownIDSet", function(frame)
            if frame then StyleLayout.InvalidateCooldownViewerInfoCache(frame) end
            queueBuffIconAfterHighlight(frame)
        end)
    end
end

-- =========================================================
-- SECTION 4: BuffBar Viewer 注册
-- =========================================================

local function RegisterBuffBarViewer()
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
            if RefreshBus and RefreshBus.requestViewers then
                RefreshBus.requestViewers(scopes, viewers, opts or {})
            end
        end,
        onAcquireFrame = function(_, frame)
            if not BuffBarRuntime then return end
            local viewer, cfg = BuffBarRuntime.getViewerAndConfig()
            if not viewer or not cfg then return end

            if frame.SetScale then frame:SetScale(1) end

            if frame.OnActiveStateChanged and not frame._vf_buffBarActiveStateHooked then
                frame._vf_buffBarActiveStateHooked = true
                frame._vf_barLastShown = frame.IsShown and frame:IsShown() or false
                hooksecurefunc(frame, "OnActiveStateChanged", function(self)
                    if not self then return end
                    local shown = self.IsShown and self:IsShown() or false
                    if self._vf_barLastShown == shown then
                        return
                    end
                    self._vf_barLastShown = shown
                    BuffBarRuntime.requestRefresh()
                end)
            end

            frame._vf_barStyled = false
            frame._vf_barLastShown = frame.IsShown and frame:IsShown() or false
            BuffBarRuntime.applyFrameStyle(frame, cfg, BuffBarRuntime.resolveBuffBarWidth(cfg), cfg.barHeight or 20)
        end,
    })
end

-- =========================================================
-- SECTION 5: 一次性安装
-- =========================================================

local hooked = false

local function SetupHooks()
    if hooked then return end

    if CORE_ENABLED then
        RegisterSkillViewer(QK_ESSENTIAL, false)
        RegisterSkillViewer(QK_UTILITY, true)
        RegisterBuffIconViewer()
    end

    if BUFF_BAR_ENABLED then
        RegisterBuffBarViewer()
    end

    if CORE_ENABLED and EventRegistry then
        EventRegistry:RegisterCallback("CooldownViewerSettings.OnDataChanged", function()
            if SkillRefreshOrchestrator then
                SkillRefreshOrchestrator.requestDelayedSkillRefresh(0.2, RefreshBus.PRESETS.SKILL_FULL)
            end
        end)
    end

    ViewerRuntime.setupAll()
    hooked = true
end

ViewerHooks.setup = SetupHooks
