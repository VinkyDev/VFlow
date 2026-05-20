-- StyleSkill — 技能 Viewer 刷新管线

local VFlow = _G.VFlow
if not VFlow then return end

local ModuleControlConstants = VFlow.ModuleControlConstants
local CORE_ENABLED = ModuleControlConstants.CORE_ENABLED
if not CORE_ENABLED then return end

local SkillViewModel = VFlow.SkillViewModel
local FD = VFlow.FD
local SkillLayoutPass = VFlow.SkillLayoutPass
local SkillGroupLayoutPass = VFlow.SkillGroupLayoutPass
local SkillStylePass = VFlow.SkillStylePass
local SkillPostPass = VFlow.SkillPostPass

local _lastLayoutNotifyEssWidth, _lastLayoutNotifyUtilWidth

local function GetSkillsDB()
    local get = VFlow and VFlow.Store and VFlow.Store.getModuleRef
    return get and get("VFlow.Skills")
end

local function ResolveSkillViewerAndConfig(viewerName)
    local db = GetSkillsDB()
    if not db then return nil, nil end
    if viewerName == "EssentialCooldownViewer" and EssentialCooldownViewer then
        return EssentialCooldownViewer, db.importantSkills
    end
    if viewerName == "UtilityCooldownViewer" and UtilityCooldownViewer then
        return UtilityCooldownViewer, db.efficiencySkills
    end
    return nil, nil
end

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
            local viewModel = SkillViewModel and SkillViewModel.BuildViewModel and SkillViewModel.BuildViewModel(viewer, cfg)
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

local function RunSkillLayoutPhase(context)
    EnsureSkillViewModels(context)
    context.viewerLayoutResults = context.viewerLayoutResults or {}
    wipe(context.viewerLayoutResults)

    for viewerName in pairs(context.dirtySkillViewers or {}) do
        local viewModel = context.skillViewModels and context.skillViewModels[viewerName]
        local layoutResult = SkillLayoutPass and SkillLayoutPass.LayoutViewer and SkillLayoutPass.LayoutViewer(viewModel)
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
    if not ConsumeSkillViewerWidthChange(force) then return end
    if VFlow.ResourceBars and VFlow.ResourceBars.OnSkillViewerLayoutChanged then
        VFlow.ResourceBars.OnSkillViewerLayoutChanged()
    end
    if VFlow.CustomMonitorGroups and VFlow.CustomMonitorGroups.OnSkillViewerLayoutChanged then
        VFlow.CustomMonitorGroups.OnSkillViewerLayoutChanged()
    end
end

local function FinishSkillViewerRefresh(viewer)
    if not viewer then return end
    local fd = FD(viewer)
    fd.refreshing = nil
    fd.needsReRefresh = nil
end

local function RefreshSkillViewer(viewer, cfg)
    if not viewer or not cfg then return end
    local context = {
        dirtySkillViewers = { [viewer:GetName()] = true },
        skillViewModels = {},
        skillGroupBuckets = {},
        viewerLayoutResults = {},
    }
    local viewModel = SkillViewModel and SkillViewModel.BuildViewModel and SkillViewModel.BuildViewModel(viewer, cfg)
    if not viewModel then return end
    context.skillViewModels[viewer:GetName()] = viewModel
    context.skillGroupBuckets = viewModel.groupBuckets or {}
    local layoutResult = SkillLayoutPass and SkillLayoutPass.LayoutViewer and SkillLayoutPass.LayoutViewer(viewModel)
    if layoutResult then
        layoutResult.rowCells = viewModel.rowCells
        context.viewerLayoutResults[1] = layoutResult
    end
    RunSkillGroupLayoutPhase(context)
    RunSkillStylePhase(context)
    if SkillPostPass and SkillPostPass.RunHighlights then
        SkillPostPass.RunHighlights(context)
    end
    if SkillPostPass and SkillPostPass.RunDependents then
        SkillPostPass.RunDependents(context)
    end
    FinishSkillViewerRefresh(viewer)
end

VFlow.StyleSkill = {
    RunSkillDataPhase = RunSkillDataPhase,
    RunSkillLayoutPhase = RunSkillLayoutPhase,
    RunSkillGroupLayoutPhase = RunSkillGroupLayoutPhase,
    RunSkillStylePhase = RunSkillStylePhase,
    RunSkillCooldownOnlyPhase = RunSkillCooldownOnlyPhase,
    NotifySkillViewerLayoutDependents = NotifySkillViewerLayoutDependents,
    RefreshSkillViewer = RefreshSkillViewer,
}
