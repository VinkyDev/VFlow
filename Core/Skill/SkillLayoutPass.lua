-- =========================================================
-- SECTION 1: 模块入口
-- SkillLayoutPass — 技能 viewer 主区布局
-- =========================================================

local VFlow = _G.VFlow
if not VFlow then return end

local StyleApply = VFlow.StyleApply
local StyleLayout = VFlow.StyleLayout
local MasqueSupport = VFlow.MasqueSupport
local PP = VFlow.PixelPerfect
local Profiler = VFlow.Profiler

local SkillLayoutPass = {}
VFlow.SkillLayoutPass = SkillLayoutPass

local function addFrame(frameList, frameSet, frame)
    if not frame or frameSet[frame] then
        return
    end
    frameSet[frame] = true
    frameList[#frameList + 1] = frame
end

local function buildRowContentWidth(rowCells, rowIndex, cellWidth, spacingX)
    local sum = 0
    for idx, cell in ipairs(rowCells) do
        sum = sum + cellWidth(cell, rowIndex)
        if idx < #rowCells then
            sum = sum + spacingX
        end
    end
    return sum
end

function SkillLayoutPass.LayoutViewer(viewModel)
    if not viewModel or not viewModel.viewer or not viewModel.cfg then
        return nil
    end

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
        viewer._vf_layoutSpan = nil
        result.layoutSignature = "empty"
        return result
    end

    local rowCells = viewModel.rowCells or {}
    local iconsChanged = StyleLayout.IconSetChanged(viewer, mainVisible)
    result.iconsChanged = iconsChanged

    if not viewModel.hasItemCells and iconsChanged then
        for _, icon in ipairs(mainVisible) do
            if not icon._vf_itemAppendFrame then
                if icon._vf_skillGroupOwner ~= nil then
                    icon._vf_skillGroupOwner = nil
                    icon._vf_spellMaskKey = nil
                end
                icon._vf_btnStyleVer = nil
                icon._vf_styleVer = nil
                icon._vf_skillVisualVersion = nil
                icon._vf_skillVisualFingerprint = nil
                icon._vf_w = nil
                icon._vf_h = nil
                icon._vf_zoomKey = nil
                icon._vf_cdSizeKey = nil
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
            if height > rowMaxHeight then
                rowMaxHeight = height
            end
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
        if iconDir == -1 then
            startX = -startX
        end

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
                if button._vf_skillGroupOwner ~= nil then
                    button._vf_skillGroupOwner = nil
                    button._vf_spellMaskKey = nil
                    button._vf_btnStyleVer = nil
                    button._vf_styleVer = nil
                    button._vf_skillVisualVersion = nil
                    button._vf_skillVisualFingerprint = nil
                end
                if button:GetParent() ~= viewer then
                    button:SetParent(viewer)
                end
                local width = cellWidth(cell, rowIndex)
                local height = cellHeight(cell, rowIndex)
                if width > rowMaxWidth then
                    rowMaxWidth = width
                end

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
                if button:IsShown() then
                    button:SetAlpha(1)
                end
                button._vf_cdmKind = "skill"

                addFrame(result.styledFrames, result.styledFrameSet, button)
            end
        end

        if not isHorizontal then
            xAccum = xAccum + rowMaxWidth + spacingX
        end
    end

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
            if icon._vf_border then icon._vf_border:Hide() end
            icon._vf_btnStyleVer = nil
            icon._vf_styleVer = nil
            icon._vf_skillVisualVersion = nil
            icon._vf_skillVisualFingerprint = nil
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
    local newHeight = viewer:GetHeight() or 0
    if isHorizontal then
        viewer._vf_layoutSpan = (newWidth > 1) and newWidth or nil
    else
        viewer._vf_layoutSpan = (newHeight > 1) and newHeight or nil
    end
    result.layoutSpan = viewer._vf_layoutSpan
    result.widthChanged = math.abs(newWidth - oldWidth) >= 0.5
    result.layoutSignature = table.concat({
        tostring(#rowCells),
        tostring(#mainVisible),
        tostring(maxRowWidth),
        tostring(viewer:GetHeight() or 0),
    }, ":")
    if iconsChanged then
        StyleLayout.SaveIconSetSnapshot(viewer, mainVisible)
    end

    return result
end

if Profiler and Profiler.registerScope then
    Profiler.registerScope("SKL:LayoutViewer", function()
        return SkillLayoutPass.LayoutViewer
    end, function(fn)
        SkillLayoutPass.LayoutViewer = fn
    end)
end
