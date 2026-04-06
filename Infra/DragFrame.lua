-- =========================================================
-- VFlow DragFrame - 可拖拽框架基建
-- 提供通用的可拖拽区域功能，支持编辑模式
-- =========================================================

local VFlow = _G.VFlow
if not VFlow then return end
local L = VFlow.L

-- =========================================================
-- 模块状态
-- =========================================================

local _registry = {} -- {[frame] = {selection, options}}
local _selectedFrame = nil
--- 正在鼠标拖拽移动的宿主（StartMoving 中）；用于避免外部布局把条拉回旧坐标。
local _draggingHostFrame = nil
local _backgroundClickCatcher = nil
local _overlapRing = nil --- 当前光标处重叠宿主列表（已排序）
local _overlapRingIndex = nil
local _overlapHintFrame = nil
local _overlapHintAutoHideToken = 0
local OVERLAP_SELECTION_LEVEL_BASE = 1000
local OVERLAP_SELECTION_LEVEL_BOOST = 80 --- 选中项抬高，保证滚轮/点击总落在当前选中 overlay 上

-- 初始化编辑模式状态
VFlow.State.update("systemEditMode", false)
VFlow.State.update("internalEditMode", false)
VFlow.State.update("isEditMode", false)

-- =========================================================
-- 工具函数
-- =========================================================

-- 四舍五入到整数像素
local function roundOffset(val)
    local n = tonumber(val) or 0
    if math.abs(n) < 0.001 then return 0 end
    if n >= 0 then
        return math.floor(n + 0.5)
    else
        return math.ceil(n - 0.5)
    end
end

local CA = VFlow.ContainerAnchor
local PP = VFlow.PixelPerfect

--- 偏移与锚点参照帧同一套比例尺（优于纯 round 整数屏幕坐标）
local function quantizeAnchorOffset(val, refFrame)
    local n = tonumber(val) or 0
    if PP and PP.PixelSnap and refFrame then
        return PP.PixelSnap(n, refFrame)
    end
    return roundOffset(n)
end

local function getEffectiveAnchorConfig(options)
    return CA.NormalizeAnchorConfig(options.getAnchorConfig())
end

local function getCursorUIParentLocal()
    local x, y = GetCursorPosition()
    local scale = UIParent:GetEffectiveScale() or 1
    return x / scale, y / scale
end

-- =========================================================
-- 选择框视觉：对标 Blizzard EditModeSystemSelectionBaseTemplate
--（EditModeSystemTemplates.xml：NineSlice + highlight/selected kit + MouseOverHighlight ADD）
-- =========================================================

--- 与 EditModeSystemTemplates.lua EditModeSystemSelectionLayout 一致
local EDIT_MODE_SYSTEM_SELECTION_LAYOUT = {
    ["TopRightCorner"] = { atlas = "%s-NineSlice-Corner", mirrorLayout = true, x = 8, y = 8 },
    ["TopLeftCorner"] = { atlas = "%s-NineSlice-Corner", mirrorLayout = true, x = -8, y = 8 },
    ["BottomLeftCorner"] = { atlas = "%s-NineSlice-Corner", mirrorLayout = true, x = -8, y = -8 },
    ["BottomRightCorner"] = { atlas = "%s-NineSlice-Corner", mirrorLayout = true, x = 8, y = -8 },
    ["TopEdge"] = { atlas = "_%s-NineSlice-EdgeTop" },
    ["BottomEdge"] = { atlas = "_%s-NineSlice-EdgeBottom" },
    ["LeftEdge"] = { atlas = "!%s-NineSlice-EdgeLeft" },
    ["RightEdge"] = { atlas = "!%s-NineSlice-EdgeRight" },
    ["Center"] = { atlas = "%s-NineSlice-Center", x = -8, y = 8, x1 = 8, y1 = -8 },
}

local TEXTURE_KIT_EDITMODE_HIGHLIGHT = "editmode-actionbar-highlight"
local TEXTURE_KIT_EDITMODE_SELECTED = "editmode-actionbar-selected"

local function canApplyEditModeSelectionNineSlice()
    return NineSliceUtil and NineSliceUtil.ApplyLayout
end

local function editModeClickToEditText()
    if L and L["Right-click to edit"] then
        return L["Right-click to edit"]
    end
    return "Right-click to edit"
end

local function resolveOpenMenuTarget(frame, options)
    if not options then
        return nil, nil
    end
    if type(options.getOpenMenuTarget) == "function" then
        local menuKey, context = options.getOpenMenuTarget(frame)
        if menuKey then
            return menuKey, context
        end
    end
    return options.menuKey, options.menuContext
end

local function applySelectionVisualKit(selection, textureKit)
    if selection._vfUseNineSlice and NineSliceUtil and NineSliceUtil.ApplyLayout then
        NineSliceUtil.ApplyLayout(selection, EDIT_MODE_SYSTEM_SELECTION_LAYOUT, textureKit)
        return
    end
    if selection.SetBackdropBorderColor then
        if textureKit == TEXTURE_KIT_EDITMODE_SELECTED then
            selection:SetBackdropColor(1.00, 0.75, 0.05, 0.10)
            selection:SetBackdropBorderColor(1.00, 0.82, 0.10, 0.95)
        else
            selection:SetBackdropColor(0.05, 0.35, 0.65, 0.10)
            selection:SetBackdropBorderColor(0.25, 0.70, 1.00, 0.90)
        end
    end
end

-- =========================================================
-- 选择框创建
-- =========================================================

local function createSelection(frame, options)
    local selection
    local useNineSlice = false
    if canApplyEditModeSelectionNineSlice() then
        --- 须为 Button：Plain Frame 无 RegisterForClicks，OnClick/右键菜单无法触发
        local ok, framed = pcall(function()
            return CreateFrame("Button", nil, UIParent, "NineSliceCodeTemplate")
        end)
        if ok and framed then
            selection = framed
            useNineSlice = true
        end
    end
    if not selection then
        selection = CreateFrame("Button", nil, UIParent, "BackdropTemplate")
        selection:SetBackdrop({
            bgFile = "Interface/Buttons/WHITE8X8",
            edgeFile = "Interface/Buttons/WHITE8X8",
            tile = false,
            edgeSize = 2,
        })
    end

    selection._vfUseNineSlice = useNineSlice
    selection:SetParent(UIParent)
    selection:ClearAllPoints()
    selection:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
    selection:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
    selection:EnableMouse(true)
    selection:RegisterForDrag("LeftButton")
    --- 左键仅在 OnMouseDown 处理（重叠框体菜单）；保留右键打开界面
    selection:RegisterForClicks("RightButtonUp", "RightButtonDown")
    --- 与 EditModeSystemSelectionBaseTemplate 一致：MEDIUM + 1000；背景点击层用 MEDIUM 低压，避免挡住选择框
    selection:SetFrameStrata("MEDIUM")
    selection:SetFrameLevel(1000)
    if selection.SetTopLevel then
        selection:SetTopLevel(true)
    end
    if selection.SetIgnoreParentAlpha then
        selection:SetIgnoreParentAlpha(true)
    end

    if useNineSlice then
        NineSliceUtil.ApplyLayout(selection, EDIT_MODE_SYSTEM_SELECTION_LAYOUT, TEXTURE_KIT_EDITMODE_HIGHLIGHT)
        local okGlow, glow = pcall(function()
            return CreateFrame("Frame", nil, selection, "NineSliceCodeTemplate")
        end)
        if okGlow and glow then
            glow:SetAllPoints()
            NineSliceUtil.ApplyLayout(glow, EDIT_MODE_SYSTEM_SELECTION_LAYOUT, TEXTURE_KIT_EDITMODE_HIGHLIGHT)
            pcall(function()
                glow:SetBlendMode("ADD")
            end)
            glow:SetAlpha(0.4)
            glow:Hide()
            selection._vfMouseOverHighlight = glow
        end
    end

    local centerLabel = selection:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    centerLabel:SetAllPoints(true)
    centerLabel:SetJustifyH("CENTER")
    centerLabel:SetJustifyV("MIDDLE")
    if centerLabel.SetFontObjectsToTry then
        centerLabel:SetFontObjectsToTry("GameFontHighlightLarge", "GameFontHighlightMedium", "GameFontHighlightSmall")
    end
    selection._vfCenterLabel = centerLabel

    --- 坐标：相对选区框固定位置（右侧），不随鼠标移动
    local coordLabel = selection:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    coordLabel:SetPoint("LEFT", selection, "RIGHT", 8, 0)
    coordLabel:SetJustifyH("LEFT")
    coordLabel:SetJustifyV("MIDDLE")
    selection._vfCoordLabel = coordLabel
    selection.label = coordLabel

    selection:Hide()

    return selection
end

local function applySymmetricPosition(frame, options, cfg, x, y, silent)
    local ox, oy = x, y
    if options.getAnchorOffset then
        local ax, ay = options.getAnchorOffset(frame)
        if ax and ay then
            ox = ox + ax
            oy = oy + ay
        end
    end
    local target = CA.ResolveSymmetricTarget(cfg)
    ox = quantizeAnchorOffset(ox, target)
    oy = quantizeAnchorOffset(oy, target)
    local myPt, theirPt = CA.GetSymmetricSetPoints(cfg)
    frame:ClearAllPoints()
    frame:SetPoint(myPt, target, theirPt, ox, oy)
    if PP and PP.SnapFrameToPixelGrid then
        PP.SnapFrameToPixelGrid(frame)
    end
    if not silent and options.onPositionChanged then
        local fx, fy = CA.ComputeStoredOffset(frame, target, cfg)
        options.onPositionChanged(frame, "SYMMETRIC", fx, fy)
    end
end

local function applyPlayerAnchorPosition(frame, options, cfg, ox, oy, silent)
    local playerPoint = cfg.playerAnchorPosition
    if options.getAnchorOffset then
        local ax, ay = options.getAnchorOffset(frame)
        if ax and ay then
            ox = ox + ax
            oy = oy + ay
        end
    end
    local ref = CA.ResolvePlayerFrame() or UIParent
    ox = quantizeAnchorOffset(ox, ref)
    oy = quantizeAnchorOffset(oy, ref)
    CA.ApplyContainerToPlayer(frame, playerPoint, ox, oy)
    if PP and PP.SnapFrameToPixelGrid then
        PP.SnapFrameToPixelGrid(frame)
    end
    if not silent and options.onPositionChanged then
        local target = CA.ResolvePlayerFrame()
        if target then
            local fx, fy = CA.ComputePlayerAnchorOffsets(frame, target, playerPoint)
            options.onPositionChanged(frame, "PLAYER_ANCHOR", fx, fy)
        end
    end
end

local function updateDragOverlayPositionLabel(frame)
    local data = frame and _registry[frame]
    if not data or not data.selection or not data.options then return end
    if not VFlow.State.isEditMode then return end
    local selection, options = data.selection, data.options
    local eff = getEffectiveAnchorConfig(options)
    if eff.anchorFrame == "player" then
        local target = CA.ResolvePlayerFrame()
        if target then
            local ox, oy = CA.ComputePlayerAnchorOffsets(frame, target, eff.playerAnchorPosition)
            selection.label:SetFormattedText("偏移: %.0f, %.0f", ox, oy)
        else
            selection.label:SetText(options.label or "无玩家框体")
        end
    else
        local target = CA.ResolveSymmetricTarget(eff)
        local ox, oy = CA.ComputeStoredOffset(frame, target, eff)
        selection.label:SetFormattedText("%s: %.0f, %.0f", eff.relativePoint, ox, oy)
    end
end

local function refreshOverlayLabels(selection, options, frame, isSelected)
    local center = selection._vfCenterLabel
    local coord = selection._vfCoordLabel
    if not center or not coord then
        return
    end
    if isSelected then
        center:SetText(options.label or "Frame")
        center:Show()
        coord:Show()
        if frame then
            updateDragOverlayPositionLabel(frame)
        end
    else
        coord:Hide()
        if selection:IsMouseOver() then
            center:SetText(editModeClickToEditText())
            center:Show()
        else
            center:Hide()
        end
    end
end

local function applyStoredPosition(frame, options)
    local eff = getEffectiveAnchorConfig(options)
    if eff.anchorFrame == "player" then
        applyPlayerAnchorPosition(frame, options, eff, eff.x, eff.y, true)
    else
        applySymmetricPosition(frame, options, eff, eff.x, eff.y, true)
    end
end

local function nudgeSelectedFrame(frame, options, dx, dy)
    if InCombatLockdown() then return end
    if not VFlow.State.isEditMode then return end
    if _selectedFrame ~= frame then return end

    local eff = getEffectiveAnchorConfig(options)
    if eff.anchorFrame == "player" then
        local target = CA.ResolvePlayerFrame()
        if not target then return end
        local ox, oy = CA.ComputePlayerAnchorOffsets(frame, target, eff.playerAnchorPosition)
        applyPlayerAnchorPosition(frame, options, eff, ox + dx, oy + dy)
    else
        local target = CA.ResolveSymmetricTarget(eff)
        local ox, oy = CA.ComputeStoredOffset(frame, target, eff)
        applySymmetricPosition(frame, options, eff, ox + dx, oy + dy)
    end
    updateDragOverlayPositionLabel(frame)
end

local updateAllSelections

local function frameEditOverlaySuppressed(data)
    if not data or not data.options then return false end
    local fn = data.options.suppressSystemEditPreview
    if type(fn) ~= "function" then return false end
    local sys = VFlow.State.systemEditMode or false
    local internal = VFlow.State.internalEditMode or false
    if not sys or internal then return false end
    return not not fn()
end

-- =========================================================
-- 多框体重叠（VFlow）
-- 启发排序：同层时更小面积的宿主优先（大面板上的小条更可能是意图目标）；
-- 滚轮在候选间循环；当前选中项的选择 overlay 临时抬高 FrameLevel，滚轮始终命中正确层。
-- =========================================================

local STRATA_RANK = {
    BACKGROUND = 1,
    LOW = 2,
    MEDIUM = 3,
    HIGH = 4,
    DIALOG = 5,
    FULLSCREEN = 6,
    FULLSCREEN_DIALOG = 7,
    TOOLTIP = 8,
}

local function hostStackDepth(host)
    if not host then
        return 0
    end
    local strata = host.GetFrameStrata and host:GetFrameStrata() or "MEDIUM"
    local rank = STRATA_RANK[strata] or 3
    local level = host.GetFrameLevel and host:GetFrameLevel() or 0
    return rank * 100000 + level
end

local function hostPixelArea(host)
    if not host or not host.GetWidth then
        return math.huge
    end
    local w = host:GetWidth() or 0
    local h = host:GetHeight() or 0
    if w <= 0 or h <= 0 then
        return math.huge
    end
    return w * h
end

local function hostContainsCursorPoint(host, cx, cy)
    if not host or not host.IsVisible or not host:IsVisible() then
        return false
    end
    local l, r, b, t = host:GetLeft(), host:GetRight(), host:GetBottom(), host:GetTop()
    if not l or not r or not b or not t then
        return false
    end
    return cx >= l and cx <= r and cy >= b and cy <= t
end

local function hitLabelForFrame(f)
    local data = f and _registry[f]
    local opt = data and data.options
    if opt and opt.label and opt.label ~= "" then
        return tostring(opt.label)
    end
    local n = f.GetName and f:GetName()
    if n and n ~= "" then
        return n
    end
    return "Frame"
end

--- 深度降序 → 面积升序 → 名称（更易点中小块、少依赖菜单）
local function sortOverlapCandidatesSmart(hits)
    table.sort(hits, function(a, b)
        local da = hostStackDepth(a)
        local db = hostStackDepth(b)
        if da ~= db then
            return da > db
        end
        local aa = hostPixelArea(a)
        local ab = hostPixelArea(b)
        if aa ~= ab then
            return aa < ab
        end
        return hitLabelForFrame(a) < hitLabelForFrame(b)
    end)
end

local function collectCursorOverlappingFrames(cx, cy)
    local hits = {}
    for f, data in pairs(_registry) do
        if f and data and not frameEditOverlaySuppressed(data) and f:IsVisible() and hostContainsCursorPoint(f, cx, cy) then
            hits[#hits + 1] = f
        end
    end
    return hits
end

local function indexOfHostInList(list, host)
    for i = 1, #list do
        if list[i] == host then
            return i
        end
    end
    return 1
end

local function resetAllSelectionFrameLevels()
    for _, data in pairs(_registry) do
        if data and data.selection and data.selection.SetFrameLevel then
            data.selection:SetFrameLevel(OVERLAP_SELECTION_LEVEL_BASE)
        end
    end
end

local function applyOverlapRingZOrder()
    if not _overlapRing or #_overlapRing < 2 then
        resetAllSelectionFrameLevels()
        return
    end
    local base = OVERLAP_SELECTION_LEVEL_BASE
    for i, h in ipairs(_overlapRing) do
        local data = _registry[h]
        if data and data.selection and data.selection.SetFrameLevel then
            local boost = (h == _selectedFrame) and OVERLAP_SELECTION_LEVEL_BOOST or 0
            --- 环内也拉开次序，避免与环外同 1000 撞车
            data.selection:SetFrameLevel(base + i + boost)
        end
    end
end

local function hideOverlapWheelHint()
    _overlapHintAutoHideToken = _overlapHintAutoHideToken + 1
    if _overlapHintFrame then
        _overlapHintFrame:Hide()
    end
end

local function showOverlapWheelHint(cursorX, cursorY)
    if not _overlapRing or #_overlapRing < 2 then
        hideOverlapWheelHint()
        return
    end
    if not _overlapHintFrame then
        local f = CreateFrame("Frame", nil, UIParent)
        f:SetFrameStrata("TOOLTIP")
        f:SetFrameLevel(2500)
        f:SetSize(280, 28)
        local fs = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        fs:SetAllPoints()
        fs:SetJustifyH("CENTER")
        fs:SetJustifyV("MIDDLE")
        f.fontString = fs
        _overlapHintFrame = f
    end
    local idx = _overlapRingIndex or 1
    local fs = _overlapHintFrame.fontString
    fs:SetFormattedText(
        "重叠：滚轮切换 · %d/%d「%s」",
        idx,
        #_overlapRing,
        hitLabelForFrame(_overlapRing[idx])
    )
    _overlapHintFrame:ClearAllPoints()
    _overlapHintFrame:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", cursorX + 12, cursorY + 12)
    _overlapHintFrame:Show()

    _overlapHintAutoHideToken = _overlapHintAutoHideToken + 1
    local token = _overlapHintAutoHideToken
    if C_Timer and C_Timer.After then
        C_Timer.After(6, function()
            if token ~= _overlapHintAutoHideToken then
                return
            end
            if _overlapHintFrame then
                _overlapHintFrame:Hide()
            end
        end)
    end
end

local function refreshOverlapWheelHintPosition()
    if not (_overlapHintFrame and _overlapHintFrame:IsShown() and _overlapRing and #_overlapRing > 1) then
        return
    end
    local cx, cy = getCursorUIParentLocal()
    _overlapHintFrame:ClearAllPoints()
    _overlapHintFrame:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", cx + 12, cy + 12)
    local idx = _overlapRingIndex or 1
    _overlapHintFrame.fontString:SetFormattedText(
        "重叠：滚轮切换 · %d/%d「%s」",
        idx,
        #_overlapRing,
        hitLabelForFrame(_overlapRing[idx])
    )
end

local function clearOverlapWheelState()
    _overlapRing = nil
    _overlapRingIndex = nil
    hideOverlapWheelHint()
    resetAllSelectionFrameLevels()
end

--- 滚轮：delta>0 通常为向上 → 上一项
local function overlapWheelAdvance(delta)
    if not _overlapRing or #_overlapRing < 2 or not VFlow.State.isEditMode or InCombatLockdown() then
        return
    end
    local n = #_overlapRing
    local idx = _overlapRingIndex or 1
    if delta > 0 then
        idx = idx - 1
        if idx < 1 then
            idx = n
        end
    else
        idx = idx + 1
        if idx > n then
            idx = 1
        end
    end
    _overlapRingIndex = idx
    _selectedFrame = _overlapRing[idx]
    updateAllSelections()
    refreshOverlapWheelHintPosition()
end

local function handleSelectionLeftMouseDown(clickedHost)
    if InCombatLockdown() or not VFlow.State.isEditMode then
        return
    end
    clearOverlapWheelState()
    local cx, cy = getCursorUIParentLocal()
    local hits = collectCursorOverlappingFrames(cx, cy)
    if #hits == 0 then
        return
    end
    if #hits == 1 then
        if hits[1] == _selectedFrame then
            return
        end
        _selectedFrame = hits[1]
        updateAllSelections()
        return
    end
    sortOverlapCandidatesSmart(hits)
    _overlapRing = hits
    _overlapRingIndex = indexOfHostInList(hits, clickedHost)
    _selectedFrame = hits[_overlapRingIndex]
    updateAllSelections()
    showOverlapWheelHint(cx, cy)
end

local function updateEffectiveEditMode()
    local isSystem = VFlow.State.systemEditMode or false
    local isInternal = VFlow.State.internalEditMode or false
    VFlow.State.update("isEditMode", isSystem or isInternal)
end

local function ensureBackgroundClickCatcher()
    if _backgroundClickCatcher then return end
    local catcher = CreateFrame("Button", nil, UIParent)
    catcher:SetAllPoints(UIParent)
    --- 须低于选择框（MEDIUM/1000），否则全屏挡点击
    catcher:SetFrameStrata("MEDIUM")
    catcher:SetFrameLevel(1)
    catcher:EnableMouse(true)
    catcher:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    catcher:SetScript("OnClick", function(self, button)
        if not VFlow.State.isEditMode then return end
        clearOverlapWheelState()
        if not _selectedFrame then return end
        _selectedFrame = nil
        updateAllSelections()
    end)
    catcher:Hide()
    _backgroundClickCatcher = catcher
end

-- =========================================================
-- 拖拽处理
-- =========================================================

local function beginDrag(selection, frame, options)
    if InCombatLockdown() then return end
    if not VFlow.State.isEditMode then return end
    clearOverlapWheelState()

    _draggingHostFrame = frame
    frame:StartMoving()

    selection:SetScript("OnUpdate", function()
        updateDragOverlayPositionLabel(frame)
    end)
end

local function endDrag(selection, frame, options)
    frame:StopMovingOrSizing()
    selection:SetScript("OnUpdate", nil)

    local eff = getEffectiveAnchorConfig(options)
    if eff.anchorFrame == "player" then
        local target = CA.ResolvePlayerFrame()
        if target then
            local ox, oy = CA.ComputePlayerAnchorOffsets(frame, target, eff.playerAnchorPosition)
            applyPlayerAnchorPosition(frame, options, eff, ox, oy)
        end
    else
        local target = CA.ResolveSymmetricTarget(eff)
        local ox, oy = CA.ComputeStoredOffset(frame, target, eff)
        applySymmetricPosition(frame, options, eff, ox, oy)
    end

    updateDragOverlayPositionLabel(frame)
    _draggingHostFrame = nil
end

-- =========================================================
-- 视觉状态
-- =========================================================

local function showHighlighted(selection, options, frame)
    applySelectionVisualKit(selection, TEXTURE_KIT_EDITMODE_HIGHLIGHT)
    refreshOverlayLabels(selection, options, frame, false)
    selection:Show()
end

local function showSelected(selection, options, frame)
    applySelectionVisualKit(selection, TEXTURE_KIT_EDITMODE_SELECTED)
    refreshOverlayLabels(selection, options, frame, true)
    selection:Show()
end

-- =========================================================
-- 编辑模式管理
-- =========================================================

updateAllSelections = function()
    local isEditMode = VFlow.State.isEditMode
    ensureBackgroundClickCatcher()

    if _selectedFrame and _registry[_selectedFrame] then
        if frameEditOverlaySuppressed(_registry[_selectedFrame]) then
            _selectedFrame = nil
            clearOverlapWheelState()
        end
    end

    local shouldCatchBackgroundClick = isEditMode and (_selectedFrame ~= nil)
    if _backgroundClickCatcher then
        if shouldCatchBackgroundClick then
            _backgroundClickCatcher:Show()
        else
            _backgroundClickCatcher:Hide()
        end
    end
    for frame, data in pairs(_registry) do
        if isEditMode and not frameEditOverlaySuppressed(data) then
            local isSelected = (_selectedFrame == frame)
            data.selection:EnableKeyboard(isSelected)
            if isSelected then
                showSelected(data.selection, data.options, frame)
                --- 无焦点时 OnKeyDown 常收不到方向键；显式聚焦选择与暴雪编辑模式一致。
                pcall(function()
                    if data.selection.SetFocus then
                        data.selection:SetFocus()
                    end
                end)
            else
                showHighlighted(data.selection, data.options, frame)
            end
        else
            data.selection:EnableKeyboard(false)
            data.selection:Hide()
        end
    end
    if isEditMode and _overlapRing and #_overlapRing > 1 then
        applyOverlapRingZOrder()
    end
end

-- 更新编辑模式状态
local function syncEditModeState()
    local isActive = EditModeManagerFrame and EditModeManagerFrame:IsEditModeActive() or false
    VFlow.State.update("systemEditMode", isActive)
    updateEffectiveEditMode()
end

-- =========================================================
-- 公共API
-- =========================================================

VFlow.DragFrame = {}

-- 注册可拖拽帧
function VFlow.DragFrame.register(frame, options)
    if not frame then return end

    options = options or {}
    if type(options.getAnchorConfig) ~= "function" then
        error("VFlow.DragFrame.register: options.getAnchorConfig is required")
    end

    -- 创建选择框
    local selection = createSelection(frame, options)

    -- 设置拖拽事件
    selection:SetScript("OnDragStart", function(self)
        _selectedFrame = frame
        updateAllSelections()
        beginDrag(selection, frame, options)
    end)

    selection:SetScript("OnDragStop", function(self)
        endDrag(selection, frame, options)
    end)

    selection:SetScript("OnMouseDown", function(self, button)
        if button ~= "LeftButton" then
            return
        end
        handleSelectionLeftMouseDown(frame)
    end)

    selection:EnableMouseWheel(true)
    selection:SetScript("OnMouseWheel", function(_, delta)
        if _overlapRing and #_overlapRing > 1 and VFlow.State.isEditMode and not InCombatLockdown() then
            overlapWheelAdvance(delta)
        end
    end)

    selection:SetScript("OnEnter", function(self)
        if VFlow.State.isEditMode then
            if selection._vfMouseOverHighlight then
                selection._vfMouseOverHighlight:Show()
            end
            if _selectedFrame == frame then
                showSelected(selection, options, frame)
            else
                showHighlighted(selection, options, frame)
            end
        end
    end)

    selection:SetScript("OnLeave", function(self)
        if selection._vfMouseOverHighlight then
            selection._vfMouseOverHighlight:Hide()
        end
        if VFlow.State.isEditMode then
            if _selectedFrame == frame then
                showSelected(selection, options, frame)
            else
                showHighlighted(selection, options, frame)
            end
        end
    end)

    selection:SetScript("OnClick", function(self, button)
        if not VFlow.State.isEditMode then return end
        if button ~= "RightButton" then return end
        if not VFlow.MainUI or not VFlow.MainUI.show then return end
        local menuKey, menuContext = resolveOpenMenuTarget(frame, options)
        if menuKey and VFlow.MainUI.openMenu then
            VFlow.MainUI.openMenu(menuKey, menuContext)
        else
            VFlow.MainUI.show()
        end
    end)

    selection:SetScript("OnKeyDown", function(self, key)
        if _selectedFrame ~= frame then return end
        if key == "UP" or key == "DOWN" or key == "LEFT" or key == "RIGHT" then
            if self.SetPropagateKeyboardInput then
                self:SetPropagateKeyboardInput(false)
            end
        end
        local step = IsShiftKeyDown() and 10 or 1
        if key == "UP" then
            nudgeSelectedFrame(frame, options, 0, step)
        elseif key == "DOWN" then
            nudgeSelectedFrame(frame, options, 0, -step)
        elseif key == "LEFT" then
            nudgeSelectedFrame(frame, options, -step, 0)
        elseif key == "RIGHT" then
            nudgeSelectedFrame(frame, options, step, 0)
        end
    end)

    -- 注册到表
    _registry[frame] = {
        selection = selection,
        options = options,
    }

    -- 如果编辑模式已开启，显示选择框
    if VFlow.State.isEditMode then
        updateAllSelections()
    end

    return selection
end

-- 取消注册
function VFlow.DragFrame.unregister(frame)
    if not frame then return end

    local data = _registry[frame]
    if data then
        clearOverlapWheelState()
        if data.selection then
            data.selection:EnableKeyboard(false)
            data.selection:Hide()
            data.selection:SetParent(nil)
        end
        _registry[frame] = nil
        if _selectedFrame == frame then
            _selectedFrame = nil
        end
        updateAllSelections()
    end
end

-- 获取编辑模式状态
function VFlow.DragFrame.isEditMode()
    return VFlow.State.isEditMode or false
end

function VFlow.DragFrame.isInternalEditMode()
    return VFlow.State.internalEditMode or false
end

function VFlow.DragFrame.setInternalEditMode(isActive)
    local active = not not isActive
    VFlow.State.update("internalEditMode", active)
    updateEffectiveEditMode()
end

function VFlow.DragFrame.toggleInternalEditMode()
    VFlow.DragFrame.setInternalEditMode(not (VFlow.State.internalEditMode or false))
end

function VFlow.DragFrame.applyRegisteredPosition(frame)
    local data = frame and _registry[frame]
    if not data or not data.options then return end
    applyStoredPosition(frame, data.options)
end

--- 是否正由 DragFrame 鼠标拖拽（避免 Refresh 时 ApplyFramePosition 覆盖拖拽中的位置）。
function VFlow.DragFrame.isHostDragging(host)
    return host ~= nil and _draggingHostFrame == host
end

-- =========================================================
-- 战斗锁定处理
-- =========================================================

VFlow.on("PLAYER_REGEN_DISABLED", "DragFrame", function()
    _selectedFrame = nil
    _draggingHostFrame = nil
    clearOverlapWheelState()
    -- 战斗中自动隐藏所有选择框
    for frame, data in pairs(_registry) do
        data.selection:EnableKeyboard(false)
        data.selection:Hide()
    end
end)

-- =========================================================
-- 系统编辑模式监听
-- =========================================================

VFlow.State.watch("isEditMode", "DragFrame", function(isEditMode, oldValue)
    if not isEditMode then
        _selectedFrame = nil
        _draggingHostFrame = nil
        clearOverlapWheelState()
    end
    updateAllSelections()
end)

VFlow.State.watch("systemEditMode", "DragFrame_Overlay", function()
    updateAllSelections()
end)

VFlow.State.watch("internalEditMode", "DragFrame_Overlay", function()
    updateAllSelections()
end)

-- Hook系统编辑模式，同步到VFlow.State
if EditModeManagerFrame then
    hooksecurefunc(EditModeManagerFrame, "EnterEditMode", function()
        syncEditModeState()
    end)

    hooksecurefunc(EditModeManagerFrame, "ExitEditMode", function()
        syncEditModeState()
    end)

    syncEditModeState()
end
