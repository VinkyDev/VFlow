-- SkillPipeline — 技能 Viewer 管线（ViewModel → Layout → Style → Post）

local VFlow = _G.VFlow
if not VFlow then return end

local FD = VFlow.FD
local StyleApply = VFlow.StyleApply
local StyleLayout = VFlow.StyleLayout
local MasqueSupport = VFlow.MasqueSupport
local PP = VFlow.PixelPerfect

-- =========================================================
-- SECTION 1: SkillViewModel — 数据准备与归属拆分
-- =========================================================

local SkillViewModel = {}

local function restoreIconVisibility(icon)
    if icon and icon.Show and not icon:IsShown() then
        icon:Show()
    end
    if icon and icon.SetAlpha and icon.GetAlpha and icon:GetAlpha() < 0.1 then
        icon:SetAlpha(1)
    end
end

local function hideIcon(icon)
    if not icon then return end
    if icon.Hide then icon:Hide() end
    if icon.SetAlpha then icon:SetAlpha(0) end
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
            local fd = FD(icon)
            fd.itemStandaloneHidden = hideStandalone or nil
            fd.itemAppendHidden = hideAppend or nil
            fd.itemHideInCDM = hideInCDM or nil
            hideIcon(icon)
        else
            local fd = FD(icon)
            fd.itemStandaloneHidden = nil
            fd.itemAppendHidden = nil
            fd.itemHideInCDM = nil
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
            if cell.isItem then return true end
        end
    end
    return false
end

function SkillViewModel.BuildViewModel(viewer, cfg)
    if not viewer or not cfg then return nil end

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

-- =========================================================
-- SECTION 2: SkillLayoutPass — 主区布局
-- =========================================================

local SkillLayoutPass = {}

local function addFrame(frameList, frameSet, frame)
    if not frame or frameSet[frame] then return end
    frameSet[frame] = true
    frameList[#frameList + 1] = frame
end

local function buildRowContentWidth(rowCells, rowIndex, cellWidth, spacingX)
    local sum = 0
    for idx, cell in ipairs(rowCells) do
        sum = sum + cellWidth(cell, rowIndex)
        if idx < #rowCells then sum = sum + spacingX end
    end
    return sum
end

function SkillLayoutPass.LayoutViewer(viewModel)
    if not viewModel or not viewModel.viewer or not viewModel.cfg then return nil end

    local viewer = viewModel.viewer
    local cfg = viewModel.cfg
    local allIcons = viewModel.allIcons or {}
    local mainVisible = viewModel.mainVisible or {}
    local groupBuckets = viewModel.groupBuckets or {}

    local result = {
        viewer = viewer,
        cfg = cfg,
        allIcons = allIcons,
        groupBuckets = groupBuckets,
        styledFrames = {},
        styledFrameSet = {},
        layoutSignature = nil,
        widthChanged = false,
    }

    if #mainVisible == 0 and not viewModel.appendOnly then
        for _, icon in ipairs(allIcons) do
            if icon:IsShown() and not (icon.Icon and icon.Icon:GetTexture()) then
                icon:SetAlpha(0)
            end
        end
        viewer:SetSize(1, 1)
        result.layoutSignature = "empty"
        return result
    end

    local rowCells = viewModel.rowCells or {}
    if not viewModel.hasItemCells then
        for _, icon in ipairs(mainVisible) do
            if not FD(icon).itemAppendFrame then
                local fd = FD(icon)
                if fd.skillGroupOwner ~= nil then
                    fd.skillGroupOwner = nil
                    fd.spellMaskKey = nil
                end
                fd.btnStyleVer = nil
                fd.styleVer = nil
                fd.skillVisualVersion = nil
                fd.skillVisualFingerprint = nil
                fd.w = nil
                fd.h = nil
                fd.zoomKey = nil
                fd.cdSizeKey = nil
            end
        end
    end

    local growUp = (cfg.growDirection == "up")
    local iconW = cfg.iconWidth or 40
    local iconH = cfg.iconHeight or 40
    local row2W = cfg.secondRowIconWidth or iconW
    local row2H = cfg.secondRowIconHeight or iconH
    local isHorizontal = (viewer.isHorizontal ~= false)
    local iconDir = (viewer.iconDirection == 1) and 1 or -1
    local spacingX = cfg.spacingX or 0
    local spacingY = cfg.spacingY or 0
    local fixedRowLengthByLimit = (cfg.fixedRowLengthByLimit == true)
    local rowAnchor = cfg.rowAnchor or "center"

    local function cellWidth(_, rowIndex)
        return (rowIndex == 1) and iconW or row2W
    end

    local function cellHeight(_, rowIndex)
        return (rowIndex == 1) and iconH or row2H
    end

    local rowContentWidths = {}
    for rowIndex, cells in ipairs(rowCells) do
        rowContentWidths[rowIndex] = buildRowContentWidth(cells, rowIndex, cellWidth, spacingX)
    end

    local rowBaseWidths = {}
    local maxRowWidth = 0
    for rowIndex, _ in ipairs(rowCells) do
        local rowWidth = (rowIndex == 1) and iconW or row2W
        local rowContentWidth = rowContentWidths[rowIndex] or 0
        local slotBandWidth = math.max(viewModel.limit or 0, 1) * (rowWidth + spacingX) - spacingX
        if fixedRowLengthByLimit then
            rowBaseWidths[rowIndex] = math.max(slotBandWidth, rowContentWidth)
        else
            rowBaseWidths[rowIndex] = rowContentWidth
        end
        if rowBaseWidths[rowIndex] > maxRowWidth then
            maxRowWidth = rowBaseWidths[rowIndex]
        end
    end
    if not fixedRowLengthByLimit then
        for rowIndex = 1, #rowCells do
            rowBaseWidths[rowIndex] = maxRowWidth
        end
    end

    local rowHeights = {}
    local prefixY = { [0] = 0 }
    for rowIndex, cells in ipairs(rowCells) do
        local rowMaxHeight = 0
        for _, cell in ipairs(cells) do
            local height = cellHeight(cell, rowIndex)
            if height > rowMaxHeight then rowMaxHeight = height end
        end
        rowHeights[rowIndex] = rowMaxHeight
        prefixY[rowIndex] = prefixY[rowIndex - 1] + rowMaxHeight + (rowIndex < #rowCells and spacingY or 0)
    end

    local xAccum = 0

    for rowIndex, cells in ipairs(rowCells) do
        local rowContentWidth = rowContentWidths[rowIndex] or 0
        local rowBaseWidth = rowBaseWidths[rowIndex] or maxRowWidth
        local alignOffset = rowBaseWidth - rowContentWidth
        local anchorOffset = 0
        if rowAnchor == "right" then
            anchorOffset = alignOffset
        elseif rowAnchor == "center" then
            anchorOffset = alignOffset / 2
        end

        local startX = ((maxRowWidth - rowBaseWidth) / 2 + anchorOffset) * iconDir
        if iconDir == -1 then startX = -startX end

        local rowWidth = (rowIndex == 1) and iconW or row2W
        local rowHeight = (rowIndex == 1) and iconH or row2H
        local widthSnap = rowWidth
        local heightSnap = rowHeight
        local strideX = rowWidth + spacingX
        local currentX = startX

        if isHorizontal and PP and PP.NormalizeColumnStride and PP.PixelSnap then
            widthSnap, strideX = PP.NormalizeColumnStride(rowWidth, spacingX, viewer)
            heightSnap = PP.PixelSnap(rowHeight, viewer)
            currentX = PP.PixelSnap(startX, viewer)
        end

        local rowMaxWidth = 0
        for colIndex, cell in ipairs(cells) do
            local button = cell.frame
            if button then
                local bfd = FD(button)
                if bfd.skillGroupOwner ~= nil then
                    bfd.skillGroupOwner = nil
                    bfd.spellMaskKey = nil
                    bfd.btnStyleVer = nil
                    bfd.styleVer = nil
                    bfd.skillVisualVersion = nil
                    bfd.skillVisualFingerprint = nil
                end
                if button:GetParent() ~= viewer then
                    button:SetParent(viewer)
                end
                local width = cellWidth(cell, rowIndex)
                local height = cellHeight(cell, rowIndex)
                if width > rowMaxWidth then rowMaxWidth = width end

                if isHorizontal then
                    StyleApply.ApplyIconSize(button, widthSnap, heightSnap)
                else
                    StyleApply.ApplyIconSize(button, width, height)
                end

                local x, y
                if isHorizontal then
                    x = currentX
                    local downSlot = growUp and (#rowCells - rowIndex) or (rowIndex - 1)
                    y = -prefixY[downSlot]
                    currentX = currentX + strideX * iconDir
                else
                    y = -(colIndex - 1) * (height + spacingY) * iconDir
                    x = growUp and -xAccum or xAccum
                end

                StyleLayout.SetPointCached(button, "TOPLEFT", viewer, "TOPLEFT", x, y)
                if button:IsShown() then button:SetAlpha(1) end
                bfd.cdmKind = "skill"

                addFrame(result.styledFrames, result.styledFrameSet, button)
            end
        end

        if not isHorizontal then
            xAccum = xAccum + rowMaxWidth + spacingX
        end
    end

    -- 隐藏未参与布局的图标
    local laidOutFrames = {}
    for _, frame in ipairs(result.styledFrames) do
        laidOutFrames[frame] = true
    end
    for _, bucket in pairs(groupBuckets) do
        for _, icon in ipairs(bucket) do
            laidOutFrames[icon] = true
        end
    end

    for _, icon in ipairs(allIcons) do
        if not laidOutFrames[icon] then
            if StyleApply.HideCustomGlow then StyleApply.HideCustomGlow(icon) end
            if StyleApply.HideGlow then StyleApply.HideGlow(icon) end
            local ifd = FD(icon)
            if ifd.border then ifd.border:Hide() end
            ifd.btnStyleVer = nil
            ifd.styleVer = nil
            ifd.skillVisualVersion = nil
            ifd.skillVisualFingerprint = nil
            if icon:IsShown() and not (icon.Icon and icon.Icon:GetTexture()) then
                icon:SetAlpha(0)
            end
        end
    end

    local bboxIcons = {}
    for _, frame in ipairs(result.styledFrames) do
        if frame and frame.IsShown and frame:IsShown() then
            bboxIcons[#bboxIcons + 1] = frame
        end
    end

    local oldWidth = viewer:GetWidth() or 0
    StyleLayout.UpdateViewerSizeToMatchIcons(viewer, #bboxIcons > 0 and bboxIcons or mainVisible)
    if fixedRowLengthByLimit and isHorizontal and maxRowWidth > 0 then
        local curWidth = viewer:GetWidth()
        if curWidth and curWidth < maxRowWidth then
            viewer:SetWidth(maxRowWidth)
        end
    end

    local newWidth = viewer:GetWidth() or 0
    result.widthChanged = math.abs(newWidth - oldWidth) >= 0.5
    result.layoutSignature = table.concat({
        tostring(#rowCells),
        tostring(#mainVisible),
        tostring(maxRowWidth),
        tostring(viewer:GetHeight() or 0),
    }, ":")

    return result
end

-- =========================================================
-- SECTION 3: SkillStylePass — 视觉应用
-- =========================================================

local SkillStylePass = {}

local visualVersion = 0

function SkillStylePass.Invalidate()
    visualVersion = visualVersion + 1
end

local function applyFrameStyle(button, cfg, isItem, entry)
    if not button or not cfg then return end

    StyleApply.ApplyButtonStyleIfStale(button, cfg)
    if MasqueSupport and MasqueSupport:IsActive() and button.Icon then
        MasqueSupport:RegisterButton(button, button.Icon)
    end
    if isItem and VFlow.ItemGroups and VFlow.ItemGroups.refreshAppendFrameStack then
        VFlow.ItemGroups.refreshAppendFrameStack(button, entry)
    end

    local bfd = FD(button)
    bfd.skillVisualVersion = visualVersion
    bfd.skillVisualFingerprint = tostring(VFlow._buttonStyleVersion or 0) .. ":" .. tostring(visualVersion)
end

local function getSkillGroupConfigForFrame(frame)
    local parent = frame and frame:GetParent()
    local name = parent and parent.GetName and parent:GetName()
    local groupIndex = name and tonumber(name:match("^VFlow_SkillGroup_(%d+)$"))
    if not groupIndex then return nil end
    local db = VFlow.getDB("VFlow.Skills")
    local group = db and db.customGroups and db.customGroups[groupIndex]
    return group and group.config
end

local function getItemGroupConfigForFrame(frame)
    local parent = frame and frame:GetParent()
    local name = parent and parent.GetName and parent:GetName()
    local groupId = name and tonumber(name:match("^VFlow_ItemGroup_(%d+)$"))
    if groupId == nil then return nil end
    return VFlow.ItemGroups and VFlow.ItemGroups.getConfigForGroupId and VFlow.ItemGroups.getConfigForGroupId(groupId) or nil
end

local function getSkillViewerConfig(viewerName)
    local db = VFlow.getDB("VFlow.Skills")
    if not db then return nil end
    if viewerName == "EssentialCooldownViewer" then return db.importantSkills end
    if viewerName == "UtilityCooldownViewer" then return db.efficiencySkills end
    return nil
end

local function applyCurrentViewerStyles(context)
    if not (context and context.dirtySkillViewers and StyleLayout and StyleLayout.CollectIcons) then return end
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
    if not (context and context.dirtySkillViewers and itemGroups and itemGroups.forEachAppendFrame) then return end
    for viewerName in pairs(context.dirtySkillViewers) do
        itemGroups.forEachAppendFrame(viewerName, function(frame, groupId)
            local cfg = itemGroups.getConfigForGroupId and itemGroups.getConfigForGroupId(groupId) or nil
            applyFrameStyle(frame, cfg, true, frame and FD(frame).entry)
        end)
    end
end

function SkillStylePass.Apply(context)
    if not context then return end

    local hasLayoutResults = context.viewerLayoutResults and #context.viewerLayoutResults > 0
    for _, layoutResult in ipairs(context.viewerLayoutResults or {}) do
        for _, row in ipairs(layoutResult.rowCells or {}) do
            for _, cell in ipairs(row) do
                applyFrameStyle(cell.frame, layoutResult.cfg, cell.isItem == true, cell.entry)
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

-- =========================================================
-- SECTION 4: SkillPostPass — 高亮与依赖回调
-- =========================================================

local SkillPostPass = {}

local highlightCallbacks = {}
local dependentCallbacks = {}

function SkillPostPass.registerHighlight(owner, callback)
    highlightCallbacks[owner] = callback
end

function SkillPostPass.registerDependent(owner, callback)
    dependentCallbacks[owner] = callback
end

function SkillPostPass.RunHighlights(context)
    for _, callback in pairs(highlightCallbacks) do
        callback(context)
    end
end

function SkillPostPass.RunDependents(context)
    for _, callback in pairs(dependentCallbacks) do
        callback(context)
    end
end

-- =========================================================
-- 导出：保持原有命名空间兼容
-- =========================================================

VFlow.SkillViewModel = SkillViewModel
VFlow.SkillLayoutPass = SkillLayoutPass
VFlow.SkillStylePass = SkillStylePass
VFlow.SkillPostPass = SkillPostPass
