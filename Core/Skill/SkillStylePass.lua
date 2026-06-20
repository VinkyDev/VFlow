-- =========================================================
-- SECTION 1: 模块入口
-- SkillStylePass — 技能相关视觉应用与 cooldown-only 更新
-- =========================================================

local VFlow = _G.VFlow
if not VFlow then return end

local StyleApply = VFlow.StyleApply
local StyleLayout = VFlow.StyleLayout
local MasqueSupport = VFlow.MasqueSupport
local Profiler = VFlow.Profiler

local SkillStylePass = {}
VFlow.SkillStylePass = SkillStylePass

local visualVersion = 0

function SkillStylePass.Invalidate()
    visualVersion = visualVersion + 1
end

local function applyFrameStyle(button, cfg, isItem, entry)
    if not button or not cfg then
        return
    end

    StyleApply.ApplyButtonStyleIfStale(button, cfg)
    if MasqueSupport and MasqueSupport:IsActive() and button.Icon then
        MasqueSupport:RegisterButton(button, button.Icon)
    end
    if isItem and VFlow.ItemGroups and VFlow.ItemGroups.refreshAppendFrameStack then
        VFlow.ItemGroups.refreshAppendFrameStack(button, entry)
    end

    button._vf_skillVisualVersion = visualVersion
    button._vf_skillVisualFingerprint = tostring(VFlow._buttonStyleVersion or 0) .. ":" .. tostring(visualVersion)
end

local function getSkillGroupConfigForFrame(frame)
    local parent = frame and frame:GetParent()
    local name = parent and parent.GetName and parent:GetName()
    local groupIndex = name and tonumber(name:match("^VFlow_SkillGroup_(%d+)$"))
    if not groupIndex then
        return nil
    end
    local db = VFlow.getDB("VFlow.Skills")
    local group = db and db.customGroups and db.customGroups[groupIndex]
    return group and group.config
end

local function getItemGroupConfigForFrame(frame)
    local parent = frame and frame:GetParent()
    local name = parent and parent.GetName and parent:GetName()
    local groupId = name and tonumber(name:match("^VFlow_ItemGroup_(%d+)$"))
    if groupId == nil then
        return nil
    end
    return VFlow.ItemGroups and VFlow.ItemGroups.getConfigForGroupId and VFlow.ItemGroups.getConfigForGroupId(groupId) or nil
end

local function getSkillViewerConfig(viewerName)
    local db = VFlow.getDB("VFlow.Skills")
    if not db then
        return nil
    end
    if viewerName == "EssentialCooldownViewer" then
        return db.importantSkills
    end
    if viewerName == "UtilityCooldownViewer" then
        return db.efficiencySkills
    end
    return nil
end

local function applyCurrentViewerStyles(context)
    if not (context and context.dirtySkillViewers and StyleLayout and StyleLayout.CollectIcons) then
        return
    end
    for viewerName in pairs(context.dirtySkillViewers) do
        local viewer = _G[viewerName]
        local cfg = getSkillViewerConfig(viewerName)
        if viewer and cfg then
            local icons = StyleLayout.CollectIcons(viewer)
            for i = 1, #icons do
                applyFrameStyle(icons[i], cfg, false)
            end
        end
    end
end

local function applyCurrentAppendStyles(context)
    local itemGroups = VFlow.ItemGroups
    if not (context and context.dirtySkillViewers and itemGroups and itemGroups.forEachAppendFrame) then
        return
    end
    for viewerName in pairs(context.dirtySkillViewers) do
        local viewerCfg = getSkillViewerConfig(viewerName)
        itemGroups.forEachAppendFrame(viewerName, function(frame, groupId)
            applyFrameStyle(frame, viewerCfg, true, frame and frame._vf_entry)
        end)
    end
end

function SkillStylePass.Apply(context)
    if not context then
        return
    end

    local hasLayoutResults = context.viewerLayoutResults and #context.viewerLayoutResults > 0
    for _, layoutResult in ipairs(context.viewerLayoutResults or {}) do
        if layoutResult.iconsChanged ~= false then
            for _, row in ipairs(layoutResult.rowCells or {}) do
                for _, cell in ipairs(row) do
                    applyFrameStyle(cell.frame, layoutResult.cfg, cell.isItem == true, cell.entry)
                end
            end
        end
    end

    if not hasLayoutResults then
        applyCurrentViewerStyles(context)
        applyCurrentAppendStyles(context)
    end

    if context.skillGroupBuckets then
        local db = VFlow.getDB("VFlow.Skills")
        for groupIndex, bucket in pairs(context.skillGroupBuckets) do
            local group = db and db.customGroups and db.customGroups[groupIndex]
            local cfg = group and group.config
            if cfg then
                for _, frame in ipairs(bucket) do
                    applyFrameStyle(frame, cfg, false)
                end
            end
        end
    elseif VFlow.SkillGroups and VFlow.SkillGroups.forEachGroupIcon then
        VFlow.SkillGroups.forEachGroupIcon(function(frame)
            local cfg = getSkillGroupConfigForFrame(frame)
            applyFrameStyle(frame, cfg, false)
        end)
    end

    if VFlow.ItemGroups and VFlow.ItemGroups.forEachStandaloneIcon then
        VFlow.ItemGroups.forEachStandaloneIcon(function(frame)
            local cfg = getItemGroupConfigForFrame(frame)
            applyFrameStyle(frame, cfg, false)
        end)
    end
end

function SkillStylePass.RefreshCooldownOnly()
    if VFlow.ItemGroups and VFlow.ItemGroups.refreshAllAppendCooldowns then
        VFlow.ItemGroups.refreshAllAppendCooldowns()
    end
    if VFlow.ItemGroups and VFlow.ItemGroups.refreshStandaloneCooldownsOnly then
        VFlow.ItemGroups.refreshStandaloneCooldownsOnly()
    end
end

if Profiler and Profiler.registerScope then
    Profiler.registerScope("SKS:ApplyStyle", function()
        return SkillStylePass.Apply
    end, function(fn)
        SkillStylePass.Apply = fn
    end)
end
