-- =========================================================
-- SECTION 1: 模块入口
-- SkillGroupLayoutPass — 技能组 / 物品组布局阶段
-- =========================================================

local VFlow = _G.VFlow
if not VFlow then return end

local Profiler = VFlow.Profiler

local SkillGroupLayoutPass = {}
VFlow.SkillGroupLayoutPass = SkillGroupLayoutPass

function SkillGroupLayoutPass.Layout(context)
    if not context then
        return
    end

    if context.flags and context.flags.reanchorOnly then
        if VFlow.SkillGroups and VFlow.SkillGroups.applyGroupAnchor then
            for groupIndex in pairs(context.dirtyGroups or {}) do
                VFlow.SkillGroups.applyGroupAnchor(groupIndex)
            end
        end
        if VFlow.ItemGroups and VFlow.ItemGroups.applyGroupAnchor then
            for groupIndex in pairs(context.dirtyGroups or {}) do
                VFlow.ItemGroups.applyGroupAnchor(groupIndex)
            end
        end
        return
    end

    if VFlow.SkillGroups and VFlow.SkillGroups.syncContainers then
        VFlow.SkillGroups.syncContainers()
    end

    if context.skillGroupBuckets and VFlow.SkillGroups and VFlow.SkillGroups.layoutGroupBuckets then
        VFlow.SkillGroups.layoutGroupBuckets(context.skillGroupBuckets, context)
    end

    if VFlow.ItemGroups and VFlow.ItemGroups.refreshStandaloneLayouts then
        VFlow.ItemGroups.refreshStandaloneLayouts(context)
    end
end

if Profiler and Profiler.registerScope then
    Profiler.registerScope("SKG:LayoutGroup", function()
        return SkillGroupLayoutPass.Layout
    end, function(fn)
        SkillGroupLayoutPass.Layout = fn
    end)
end
