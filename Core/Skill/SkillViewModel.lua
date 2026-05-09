-- =========================================================
-- SECTION 1: 模块入口
-- SkillViewModel — 技能 viewer 数据准备与归属拆分
-- =========================================================

local VFlow = _G.VFlow
if not VFlow then return end

local StyleLayout = VFlow.StyleLayout
local Profiler = VFlow.Profiler

local SkillViewModel = {}
VFlow.SkillViewModel = SkillViewModel

local function restoreIconVisibility(icon)
    if icon and icon.Show and not icon:IsShown() then
        icon:Show()
    end
    if icon and icon.SetAlpha and icon.GetAlpha and icon:GetAlpha() < 0.1 then
        icon:SetAlpha(1)
    end
end

local function hideIcon(icon)
    if not icon then
        return
    end
    if icon.Hide then
        icon:Hide()
    end
    if icon.SetAlpha then
        icon:SetAlpha(0)
    end
end

local function isIconVisible(icon)
    return icon
        and icon.IsShown
        and icon:IsShown()
        and icon.Icon
        and icon.Icon.GetTexture
        and icon.Icon:GetTexture()
end

local function classifySkillGroups(allIcons)
    local skillGroups = VFlow.SkillGroups
    if not (skillGroups and skillGroups.buildGroupSpellMap and skillGroups.resolveGroupIndexForIcon) then
        return StyleLayout.FilterVisible(allIcons), {}
    end

    local spellMap = skillGroups.buildGroupSpellMap()
    if not spellMap or not next(spellMap) then
        return StyleLayout.FilterVisible(allIcons), {}
    end

    local mainVisible = {}
    local groupBuckets = {}

    for _, icon in ipairs(allIcons) do
        local groupIndex = skillGroups.resolveGroupIndexForIcon(icon, spellMap)
        if groupIndex == -1 then
            hideIcon(icon)
        elseif groupIndex then
            restoreIconVisibility(icon)
            if isIconVisible(icon) then
                groupBuckets[groupIndex] = groupBuckets[groupIndex] or {}
                groupBuckets[groupIndex][#groupBuckets[groupIndex] + 1] = icon
            end
        else
            restoreIconVisibility(icon)
            if isIconVisible(icon) then
                mainVisible[#mainVisible + 1] = icon
            end
        end
    end

    return mainVisible, groupBuckets
end

local function applyItemGroupVisibility(viewer, icons)
    local itemGroups = VFlow.ItemGroups
    if not (itemGroups and itemGroups.buildSpellMap and itemGroups.resolveGroupIdForIcon and itemGroups.getConfigForGroupId) then
        return icons
    end

    local spellMap = itemGroups.buildSpellMap()
    local visible = {}

    for _, icon in ipairs(icons) do
        local groupId = itemGroups.resolveGroupIdForIcon(icon, spellMap)
        local cfg = groupId ~= nil and itemGroups.getConfigForGroupId(groupId) or nil
        local hideStandalone = groupId ~= nil and cfg and itemGroups.shouldStandaloneExtract and itemGroups.shouldStandaloneExtract(cfg)
        local hideAppend = groupId ~= nil and cfg and itemGroups.shouldAppendToViewer and itemGroups.shouldAppendToViewer(cfg, viewer)
        local hideInCDM = cfg and cfg.hideInCooldownManager

        if hideStandalone or hideAppend or hideInCDM then
            icon._vf_itemStandaloneHidden = hideStandalone or nil
            icon._vf_itemAppendHidden = hideAppend or nil
            icon._vf_itemHideInCDM = hideInCDM or nil
            hideIcon(icon)
        else
            icon._vf_itemStandaloneHidden = nil
            icon._vf_itemAppendHidden = nil
            icon._vf_itemHideInCDM = nil
            restoreIconVisibility(icon)
            if isIconVisible(icon) then
                visible[#visible + 1] = icon
            end
        end
    end

    return visible
end

local function buildViewerRowCells(viewer, limit, rows)
    local itemGroups = VFlow.ItemGroups
    if itemGroups and itemGroups.buildViewerRowCells then
        return itemGroups.buildViewerRowCells(viewer, limit, rows)
    end

    local out = {}
    for rowIndex, rowIcons in ipairs(rows or {}) do
        out[rowIndex] = {}
        for _, icon in ipairs(rowIcons) do
            out[rowIndex][#out[rowIndex] + 1] = { frame = icon, isItem = false }
        end
    end
    return out
end

local function detectItemCells(rowCells)
    for _, row in ipairs(rowCells or {}) do
        for _, cell in ipairs(row) do
            if cell.isItem then
                return true
            end
        end
    end
    return false
end

function SkillViewModel.BuildViewModel(viewer, cfg)
    if not viewer or not cfg then
        return nil
    end

    local allIcons = StyleLayout.CollectIcons(viewer)
    local mainVisible, groupBuckets = classifySkillGroups(allIcons)
    mainVisible = applyItemGroupVisibility(viewer, mainVisible)

    local limit = cfg.maxIconsPerRow or 8
    local rows = StyleLayout.BuildRows(limit, mainVisible)
    local rowCells = buildViewerRowCells(viewer, limit, rows)
    local hasItemCells = detectItemCells(rowCells)
    local appendOnly = (#mainVisible == 0 and hasItemCells)

    return {
        viewer = viewer,
        cfg = cfg,
        allIcons = allIcons,
        mainVisible = mainVisible,
        groupBuckets = groupBuckets,
        limit = limit,
        rows = rows,
        rowCells = rowCells,
        hasItemCells = hasItemCells,
        appendOnly = appendOnly,
    }
end

if Profiler and Profiler.registerScope then
    Profiler.registerScope("SKVM:BuildViewModel", function()
        return SkillViewModel.BuildViewModel
    end, function(fn)
        SkillViewModel.BuildViewModel = fn
    end)
end
