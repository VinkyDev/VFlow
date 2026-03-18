-- =========================================================
-- VFlow DragFrame - 可拖拽框架基建
-- 提供通用的可拖拽区域功能，支持编辑模式
-- =========================================================

local VFlow = _G.VFlow
if not VFlow then return end

-- =========================================================
-- 模块状态
-- =========================================================

local _registry = {} -- {[frame] = {selection, options}}
local _selectedFrame = nil
local _backgroundClickCatcher = nil

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

-- 计算相对于CENTER的偏移
local function getCenterOffset(frame)
    local parent = UIParent

    local scale = frame:GetScale()
    if not scale or scale == 0 then return 0, 0 end

    local left = frame:GetLeft()
    local right = frame:GetRight()
    local top = frame:GetTop()
    local bottom = frame:GetBottom()

    if not (left and right and top and bottom) then
        return 0, 0
    end

    left = left * scale
    right = right * scale
    top = top * scale
    bottom = bottom * scale

    local parentWidth, parentHeight = parent:GetSize()
    if not parentWidth or not parentHeight then
        return 0, 0
    end

    -- 计算框架中心相对于父框架中心的偏移
    local cx = (left + right) * 0.5 - parentWidth * 0.5
    local cy = (bottom + top) * 0.5 - parentHeight * 0.5

    return cx / scale, cy / scale
end

-- =========================================================
-- 选择框创建
-- =========================================================

local function createSelection(frame, options)
    local selection = CreateFrame("Button", nil, UIParent, "BackdropTemplate")
    selection:SetParent(UIParent)
    selection:SetAllPoints(frame)
    selection:EnableMouse(true)
    selection:RegisterForDrag("LeftButton")
    selection:RegisterForClicks("LeftButtonUp", "RightButtonUp", "RightButtonDown")
    selection:SetFrameStrata("HIGH")
    selection:SetFrameLevel(100)

    -- 视觉样式
    selection:SetBackdrop({
        bgFile = "Interface/Buttons/WHITE8X8",
        edgeFile = "Interface/Buttons/WHITE8X8",
        tile = false,
        edgeSize = 2,
    })

    -- 标签
    local label = selection:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    label:SetPoint("TOP", selection, "BOTTOM", 0, -4)
    label:SetTextColor(1, 1, 1, 1)
    selection.label = label

    -- 初始隐藏
    selection:Hide()

    return selection
end

local function applyCenterPosition(frame, options, x, y)
    if options.getAnchorOffset then
        local offsetX, offsetY = options.getAnchorOffset(frame)
        if offsetX and offsetY then
            x = x + offsetX
            y = y + offsetY
        end
    end

    x = roundOffset(x)
    y = roundOffset(y)

    frame:ClearAllPoints()
    frame:SetPoint("CENTER", UIParent, "CENTER", x, y)

    if options.onPositionChanged then
        options.onPositionChanged(frame, "CENTER", x, y)
    end
end

local function nudgeSelectedFrame(frame, options, dx, dy)
    if InCombatLockdown() then return end
    if not VFlow.State.isEditMode then return end
    if _selectedFrame ~= frame then return end

    local x, y = getCenterOffset(frame)
    applyCenterPosition(frame, options, x + dx, y + dy)
end

local updateAllSelections

local function updateEffectiveEditMode()
    local isSystem = VFlow.State.systemEditMode or false
    local isInternal = VFlow.State.internalEditMode or false
    VFlow.State.update("isEditMode", isSystem or isInternal)
end

local function ensureBackgroundClickCatcher()
    if _backgroundClickCatcher then return end
    local catcher = CreateFrame("Button", nil, UIParent)
    catcher:SetAllPoints(UIParent)
    catcher:SetFrameStrata("HIGH")
    catcher:SetFrameLevel(1)
    catcher:EnableMouse(true)
    catcher:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    catcher:SetScript("OnClick", function(self, button)
        if not VFlow.State.isEditMode then return end
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

local function beginDrag(selection, frame)
    if InCombatLockdown() then return end
    if not VFlow.State.isEditMode then return end

    frame:StartMoving()

    -- 实时显示坐标
    selection:SetScript("OnUpdate", function(self)
        local x, y = getCenterOffset(frame)
        self.label:SetFormattedText("CENTER: %.0f, %.0f", x, y)
    end)
end

local function endDrag(selection, frame, options)
    frame:StopMovingOrSizing()
    selection:SetScript("OnUpdate", nil)

    -- 计算相对于CENTER的偏移
    local x, y = getCenterOffset(frame)

    applyCenterPosition(frame, options, x, y)

    -- 更新标签
    selection.label:SetText(options.label or frame:GetName() or "Frame")
end

-- =========================================================
-- 视觉状态
-- =========================================================

local function showHighlighted(selection, options)
    selection:SetBackdropColor(0.05, 0.35, 0.65, 0.10)       -- 蓝色背景
    selection:SetBackdropBorderColor(0.25, 0.70, 1.00, 0.90) -- 蓝色边框
    selection.label:SetText(options.label or "Frame")
    selection:Show()
end

local function showSelected(selection, options)
    selection:SetBackdropColor(1.00, 0.75, 0.05, 0.10)       -- 金色背景
    selection:SetBackdropBorderColor(1.00, 0.82, 0.10, 0.95) -- 金色边框
    selection.label:SetText(options.label or "Frame")
    selection:Show()
end

-- =========================================================
-- 编辑模式管理
-- =========================================================

updateAllSelections = function()
    local isEditMode = VFlow.State.isEditMode
    ensureBackgroundClickCatcher()
    local shouldCatchBackgroundClick = isEditMode and (_selectedFrame ~= nil)
    if _backgroundClickCatcher then
        if shouldCatchBackgroundClick then
            _backgroundClickCatcher:Show()
        else
            _backgroundClickCatcher:Hide()
        end
    end
    for frame, data in pairs(_registry) do
        if isEditMode then
            local isSelected = (_selectedFrame == frame)
            data.selection:EnableKeyboard(isSelected)
            if isSelected then
                showSelected(data.selection, data.options)
            else
                showHighlighted(data.selection, data.options)
            end
        else
            data.selection:EnableKeyboard(false)
            data.selection:Hide()
        end
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

    -- 创建选择框
    local selection = createSelection(frame, options)

    -- 设置拖拽事件
    selection:SetScript("OnDragStart", function(self)
        _selectedFrame = frame
        updateAllSelections()
        beginDrag(selection, frame)
    end)

    selection:SetScript("OnDragStop", function(self)
        endDrag(selection, frame, options)
    end)

    selection:SetScript("OnEnter", function(self)
        if VFlow.State.isEditMode then
            if _selectedFrame == frame then
                showSelected(selection, options)
            else
                showHighlighted(selection, options)
            end
        end
    end)

    selection:SetScript("OnLeave", function(self)
        if VFlow.State.isEditMode then
            if _selectedFrame == frame then
                showSelected(selection, options)
            else
                showHighlighted(selection, options)
            end
        end
    end)

    selection:SetScript("OnClick", function(self, button)
        if not VFlow.State.isEditMode then return end
        if button == "LeftButton" then
            _selectedFrame = frame
            updateAllSelections()
            return
        end
        if button ~= "RightButton" then return end
        if not VFlow.MainUI or not VFlow.MainUI.show then return end

        local mainFrame = _G.VFlowMainFrame
        if mainFrame and mainFrame:IsShown() then
            return
        end

        VFlow.MainUI.show()
    end)

    selection:SetScript("OnKeyDown", function(self, key)
        if _selectedFrame ~= frame then return end
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
        if data.selection then
            data.selection:EnableKeyboard(false)
            data.selection:Hide()
            data.selection:SetParent(nil)
        end
        _registry[frame] = nil
        if _selectedFrame == frame then
            _selectedFrame = nil
            updateAllSelections()
        end
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

-- 应用保存的位置
function VFlow.DragFrame.applyPosition(frame, point, x, y)
    if not frame then return end

    frame:ClearAllPoints()
    frame:SetPoint(point or "CENTER", UIParent, point or "CENTER", x or 0, y or 0)
end

-- =========================================================
-- 战斗锁定处理
-- =========================================================

VFlow.on("PLAYER_REGEN_DISABLED", "DragFrame", function()
    _selectedFrame = nil
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
    end
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
