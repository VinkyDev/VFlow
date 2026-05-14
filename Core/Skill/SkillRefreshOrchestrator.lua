-- =========================================================
-- VFlow SkillRefreshOrchestrator
-- 职责：把 RefreshBus 的技能相关 SCOPE 与 Skill Pass 流水线衔接
--
-- 流水线：
--   SKILL_GROUP_MAP / SKILL_DATA / ITEM_APPEND_LAYOUT
--     → SkillViewModel.BuildViewModel（写入 context.skillViewModels）
--   SKILL_LAYOUT      → SkillLayoutPass.LayoutViewer
--   SKILL_GROUP_LAYOUT → SkillGroupLayoutPass.Layout
--   SKILL_STYLE       → SkillStylePass.Apply
--   SKILL_COOLDOWN    → SkillStylePass.RefreshCooldownOnly
--   HIGHLIGHT         → SkillPostPass.RunHighlights（含 CustomHighlight 扫描）
--   DEPENDENT_LAYOUT  → SkillPostPass.RunDependents（通知 ResourceBars / CustomMonitorGroups）
--
-- 同时暴露：VFlow.RequestSkillRefresh / VFlow.RequestKeybindStyleRefresh
-- 监听 VFlow.Skills / VFlow.OtherFeatures / VFlow.StyleIcon / VFlow.CustomMonitor 配置变化
-- =========================================================

local VFlow = _G.VFlow
if not VFlow then return end

local ModuleControlConstants = VFlow.ModuleControlConstants
if not ModuleControlConstants.CORE_ENABLED then return end

local RefreshBus = VFlow.RefreshBus
local SkillViewModel = VFlow.SkillViewModel
local SkillLayoutPass = VFlow.SkillLayoutPass
local SkillGroupLayoutPass = VFlow.SkillGroupLayoutPass
local SkillStylePass = VFlow.SkillStylePass
local SkillPostPass = VFlow.SkillPostPass
local CustomHighlight = VFlow.CustomHighlight

local SkillRefreshOrchestrator = {}
VFlow.SkillRefreshOrchestrator = SkillRefreshOrchestrator

-- =========================================================
-- SECTION 1: DB 与 Viewer 解析
-- =========================================================

local function GetSkillsDB()
    local get = VFlow and VFlow.Store and VFlow.Store.getModuleRef
    return get and get("VFlow.Skills")
end

local function ResolveSkillViewerAndConfig(viewerName)
    local db = GetSkillsDB()
    if not db then
        return nil, nil
    end
    if viewerName == "EssentialCooldownViewer" and EssentialCooldownViewer then
        return EssentialCooldownViewer, db.importantSkills
    end
    if viewerName == "UtilityCooldownViewer" and UtilityCooldownViewer then
        return UtilityCooldownViewer, db.efficiencySkills
    end
    return nil, nil
end

-- =========================================================
-- SECTION 2: ViewModel 构建（SCOPE GROUP_MAP / DATA / ITEM_APPEND）
-- =========================================================

local function MergeSkillGroupBuckets(target, source)
    if not source then return end
    for groupIndex, bucket in pairs(source) do
        target[groupIndex] = target[groupIndex] or {}
        local out = target[groupIndex]
        for _, icon in ipairs(bucket) do
            out[#out + 1] = icon
        end
    end
end

local function EnsureSkillViewModels(context)
    context.skillViewModels = context.skillViewModels or {}
    context.skillGroupBuckets = context.skillGroupBuckets or {}

    for viewerName in pairs(context.dirtySkillViewers or {}) do
        if not context.skillViewModels[viewerName] then
            local viewer, cfg = ResolveSkillViewerAndConfig(viewerName)
            local viewModel = SkillViewModel and SkillViewModel.BuildViewModel
                and SkillViewModel.BuildViewModel(viewer, cfg)
            if viewModel then
                context.skillViewModels[viewerName] = viewModel
                MergeSkillGroupBuckets(context.skillGroupBuckets, viewModel.groupBuckets)
            end
        end
    end
end

local function RunSkillDataPhase(context)
    EnsureSkillViewModels(context)
end

-- =========================================================
-- SECTION 3: 布局 / 样式 / 冷却 Phase
-- =========================================================

local function RunSkillLayoutPhase(context)
    EnsureSkillViewModels(context)
    context.viewerLayoutResults = context.viewerLayoutResults or {}
    wipe(context.viewerLayoutResults)

    for viewerName in pairs(context.dirtySkillViewers or {}) do
        local viewModel = context.skillViewModels and context.skillViewModels[viewerName]
        local layoutResult = SkillLayoutPass and SkillLayoutPass.LayoutViewer
            and SkillLayoutPass.LayoutViewer(viewModel)
        if layoutResult then
            layoutResult.rowCells = viewModel.rowCells
            context.viewerLayoutResults[#context.viewerLayoutResults + 1] = layoutResult
        end
    end
end

local function RunSkillGroupLayoutPhase(context)
    if SkillGroupLayoutPass and SkillGroupLayoutPass.Layout then
        SkillGroupLayoutPass.Layout(context)
    end
end

local function RunSkillStylePhase(context)
    if SkillStylePass and SkillStylePass.Apply then
        SkillStylePass.Apply(context)
    end
end

local function RunSkillCooldownOnlyPhase()
    if SkillStylePass and SkillStylePass.RefreshCooldownOnly then
        SkillStylePass.RefreshCooldownOnly()
    end
end

-- =========================================================
-- SECTION 4: 依赖布局通知（DEPENDENT_LAYOUT）
-- =========================================================

local _lastLayoutNotifyEssWidth, _lastLayoutNotifyUtilWidth

local function ConsumeSkillViewerWidthChange(force)
    local ew = _G.EssentialCooldownViewer and _G.EssentialCooldownViewer:GetWidth() or 0
    local uw = _G.UtilityCooldownViewer and _G.UtilityCooldownViewer:GetWidth() or 0
    if not force
        and _lastLayoutNotifyEssWidth ~= nil
        and _lastLayoutNotifyUtilWidth ~= nil
        and math.abs(ew - _lastLayoutNotifyEssWidth) < 0.5
        and math.abs(uw - _lastLayoutNotifyUtilWidth) < 0.5 then
        return false
    end
    _lastLayoutNotifyEssWidth = ew
    _lastLayoutNotifyUtilWidth = uw
    return true
end

local function NotifySkillViewerLayoutDependents(force)
    if not ConsumeSkillViewerWidthChange(force) then
        return
    end
    if VFlow.ResourceBars and VFlow.ResourceBars.OnSkillViewerLayoutChanged then
        VFlow.ResourceBars.OnSkillViewerLayoutChanged()
    end
    if VFlow.CustomMonitorGroups and VFlow.CustomMonitorGroups.OnSkillViewerLayoutChanged then
        VFlow.CustomMonitorGroups.OnSkillViewerLayoutChanged()
    end
end

-- =========================================================
-- SECTION 5: 注册到 RefreshBus
-- =========================================================

local viewerPhaseRegistered = false

local function RegisterViewerRefreshPhases()
    if viewerPhaseRegistered or not RefreshBus then
        return
    end
    viewerPhaseRegistered = true

    RefreshBus.register(RefreshBus.SCOPES.SKILL_GROUP_MAP, "CooldownStyle_SkillGroupMap", RunSkillDataPhase)
    RefreshBus.register(RefreshBus.SCOPES.SKILL_DATA, "CooldownStyle_SkillData", RunSkillDataPhase)
    RefreshBus.register(RefreshBus.SCOPES.ITEM_APPEND_LAYOUT, "CooldownStyle_ItemAppend", RunSkillDataPhase)
    RefreshBus.register(RefreshBus.SCOPES.SKILL_LAYOUT, "CooldownStyle_SkillLayout", RunSkillLayoutPhase)
    RefreshBus.register(RefreshBus.SCOPES.SKILL_GROUP_LAYOUT, "CooldownStyle_SkillGroupLayout", RunSkillGroupLayoutPhase)
    RefreshBus.register(RefreshBus.SCOPES.SKILL_STYLE, "CooldownStyle_SkillStyle", RunSkillStylePhase)
    RefreshBus.register(RefreshBus.SCOPES.SKILL_COOLDOWN, "CooldownStyle_SkillCooldownOnly", function()
        RunSkillCooldownOnlyPhase()
    end)
    RefreshBus.register(RefreshBus.SCOPES.HIGHLIGHT, "CooldownStyle_Highlight", function(context)
        if SkillPostPass and SkillPostPass.RunHighlights then
            SkillPostPass.RunHighlights(context)
        end
    end)
    RefreshBus.register(RefreshBus.SCOPES.DEPENDENT_LAYOUT, "CooldownStyle_Dependents", function(context)
        if SkillPostPass and SkillPostPass.RunDependents then
            SkillPostPass.RunDependents(context)
        end
    end)
end

-- =========================================================
-- SECTION 6: 请求入口（VFlow.RequestSkillRefresh）
-- =========================================================

local skillRefreshPending = false
local specDrivenSkillRefreshPending = false

local function CopyRequestOpts(opts)
    local out = {}
    for key, value in pairs(opts or {}) do
        out[key] = value
    end
    return out
end

local function RequestSkillRefresh(scopeOrScopes, opts)
    if not (RefreshBus and RefreshBus.requestAllSkillViewers) then
        return
    end

    opts = opts or {}
    if opts.viewers then
        RefreshBus.requestSkillViewers(scopeOrScopes, opts.viewers, opts)
    else
        RefreshBus.requestAllSkillViewers(scopeOrScopes, opts)
    end
end

local function RequestDelayedSkillRefresh(delay, scopeOrScopes, opts)
    if delay and delay > 0 then
        if skillRefreshPending then
            return
        end
        skillRefreshPending = true
        C_Timer.After(delay, function()
            skillRefreshPending = false
            RequestSkillRefresh(scopeOrScopes, opts)
        end)
        return
    end
    RequestSkillRefresh(scopeOrScopes, opts)
end

local function RequestSpecDrivenSkillRefresh()
    if specDrivenSkillRefreshPending then
        return
    end
    specDrivenSkillRefreshPending = true
    -- 专精切换时，CDM/档案绑定可能在当前事件帧后才稳定；延后一小拍再重排可避免依赖宽度读到临时值。
    C_Timer.After(0.1, function()
        specDrivenSkillRefreshPending = false
        RequestSkillRefresh(RefreshBus.PRESETS.SKILL_FULL, {
            flags = { forceDependentLayout = true },
        })
    end)
end

-- =========================================================
-- SECTION 7: SkillPostPass 注册（高亮 + 依赖布局）
-- =========================================================

local function RegisterSkillPostPassHooks()
    if SkillPostPass and SkillPostPass.registerHighlight and CustomHighlight then
        SkillPostPass.registerHighlight("CooldownStyle_SkillHighlightViewer", function(context)
            for _, layoutResult in ipairs(context.viewerLayoutResults or {}) do
                CustomHighlight.scanViewer(layoutResult.viewer, layoutResult.allIcons)
            end
            CustomHighlight.scanSkillGroups()
        end)
    end

    if SkillPostPass and SkillPostPass.registerDependent then
        SkillPostPass.registerDependent("CooldownStyle_SkillDependents", function(context)
            local force = context and context.flags and context.flags.forceDependentLayout
            NotifySkillViewerLayoutDependents(force == true)
        end)
    end
end

-- =========================================================
-- SECTION 8: 模块装载
-- =========================================================

RegisterViewerRefreshPhases()
RegisterSkillPostPassHooks()

VFlow.RequestSkillRefresh = RequestSkillRefresh

SkillRefreshOrchestrator.requestSkillRefresh = RequestSkillRefresh
SkillRefreshOrchestrator.requestDelayedSkillRefresh = RequestDelayedSkillRefresh
SkillRefreshOrchestrator.requestSpecDrivenSkillRefresh = RequestSpecDrivenSkillRefresh
SkillRefreshOrchestrator.notifyDependents = NotifySkillViewerLayoutDependents
SkillRefreshOrchestrator.copyRequestOpts = CopyRequestOpts
