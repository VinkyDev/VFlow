-- =========================================================
-- VFlow UI - 组件工厂
-- 职责：创建标准UI组件、应用统一样式
-- =========================================================

local VFlow = _G.VFlow
if not VFlow then
    error("VFlow.UI: Core模块未加载")
end

local UI = {}
VFlow.UI = UI

local Pool = VFlow.Pool
local LSM = LibStub and LibStub("LibSharedMedia-3.0", true)

-- =========================================================
-- 样式定义 (Modern Flat Style)
-- =========================================================

UI.style = {
    colors = {
        primary = { 0.25, 0.52, 0.95, 1 },       -- VFlow Royal Blue (Updated)
        background = { 0.1, 0.1, 0.1, 0.9 },     -- Dark Charcoal (Lighter & Transparent)
        panel = { 0.14, 0.14, 0.14, 1 },         -- Panel BG
        element = { 0.18, 0.18, 0.18, 1 },       -- Element BG
        input = { 0.1, 0.1, 0.1, 0.8 },          -- Input BG
        border = { 0.3, 0.3, 0.3, 1 },           -- Subtle Border
        hover = { 0.24, 0.24, 0.24, 1 },         -- Hover State
        text = { 0.9, 0.9, 0.9, 1 },             -- Primary Text
        textDim = { 0.6, 0.6, 0.6, 1 },          -- Secondary Text
        success = { 0.2, 0.8, 0.2, 1 },          -- Success Green
        warning = { 1, 0.8, 0.2, 1 },            -- Warning Orange
        error = { 1, 0.2, 0.2, 1 },              -- Error Red
    },
    fonts = {
        title = "GameFontNormalHuge",
        subtitle = "GameFontNormalLarge",
        default = "GameFontHighlight",
        small = "GameFontHighlightSmall",
    },
    spacing = {
        padding = 10,
        gap = 8,
    },
    icons = {
        check = "Interface\\AddOns\\VFlow\\Assets\\Icons\\check",
        expand = "Interface\\AddOns\\VFlow\\Assets\\Icons\\expand_more",
        collapse = "Interface\\AddOns\\VFlow\\Assets\\Icons\\chevron_right",
        close = "Interface\\AddOns\\VFlow\\Assets\\Icons\\close",
    }
}

-- =========================================================
-- 辅助函数
-- =========================================================

--- 创建元素背景（扁平化风格）
-- @param frame Frame
local function CreateElementBackdrop(frame)
    if not frame.SetBackdrop then
        Mixin(frame, BackdropTemplateMixin)
    end
    frame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    local c = UI.style.colors.element
    frame:SetBackdropColor(c[1], c[2], c[3], c[4])

    local b = UI.style.colors.border
    frame:SetBackdropBorderColor(b[1], b[2], b[3], b[4])
end

--- 创建面板背景
-- @param frame Frame
local function CreatePanelBackdrop(frame)
    if not frame.SetBackdrop then
        Mixin(frame, BackdropTemplateMixin)
    end
    frame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    local c = UI.style.colors.panel
    frame:SetBackdropColor(c[1], c[2], c[3], c[4])
    frame:SetBackdropBorderColor(0, 0, 0, 1)
end

--- 获取主题色
local function GetThemeColor()
    return UI.style.colors.primary
end

local function GetScrollBar(scrollFrame)
    if not scrollFrame then return nil end
    if scrollFrame.ScrollBar then return scrollFrame.ScrollBar end
    local name = scrollFrame.GetName and scrollFrame:GetName()
    if name and _G[name .. "ScrollBar"] then
        return _G[name .. "ScrollBar"]
    end
    return nil
end

local function HideClassicScrollButton(btn)
    if not btn then return end
    btn:Hide()
    btn:SetAlpha(0)
    btn:EnableMouse(false)
    btn:ClearAllPoints()
    btn:SetSize(1, 1)
    local normal = btn.GetNormalTexture and btn:GetNormalTexture()
    if normal and normal.SetTexture then
        normal:SetTexture(nil)
    end
    local pushed = btn.GetPushedTexture and btn:GetPushedTexture()
    if pushed and pushed.SetTexture then
        pushed:SetTexture(nil)
    end
    local highlight = btn.GetHighlightTexture and btn:GetHighlightTexture()
    if highlight and highlight.SetTexture then
        highlight:SetTexture(nil)
    end
    local disabled = btn.GetDisabledTexture and btn:GetDisabledTexture()
    if disabled and disabled.SetTexture then
        disabled:SetTexture(nil)
    end
    if not btn._vf_hideHook then
        btn:HookScript("OnShow", function(self)
            self:Hide()
        end)
        btn._vf_hideHook = true
    end
end

function UI.styleScrollFrame(scrollFrame, opts)
    opts = opts or {}
    local scrollBar = GetScrollBar(scrollFrame)
    if not scrollBar then
        return nil
    end

    local anchorParent = opts.anchorParent or scrollFrame:GetParent() or scrollFrame
    local offsetX = opts.offsetX or -2
    local topOffset = opts.topOffset or -6
    local bottomOffset = opts.bottomOffset or 6
    local width = opts.width or 6

    if opts.reanchor ~= false then
        scrollBar:ClearAllPoints()
        scrollBar:SetPoint("TOPRIGHT", anchorParent, "TOPRIGHT", offsetX, topOffset)
        scrollBar:SetPoint("BOTTOMRIGHT", anchorParent, "BOTTOMRIGHT", offsetX, bottomOffset)
    end
    scrollBar:SetWidth(width)

    HideClassicScrollButton(scrollBar.ScrollUpButton)
    HideClassicScrollButton(scrollBar.ScrollDownButton)
    if scrollBar.Track then scrollBar.Track:Hide() end
    if scrollBar.Top then scrollBar.Top:Hide() end
    if scrollBar.Bottom then scrollBar.Bottom:Hide() end
    if scrollBar.Middle then scrollBar.Middle:Hide() end
    if scrollBar.BG then scrollBar.BG:Hide() end

    if not scrollBar._vf_bg then
        local bg = scrollBar:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(1, 1, 1, 0.06)
        scrollBar._vf_bg = bg
    end

    if not scrollBar._vf_thumb then
        local thumb = scrollBar:CreateTexture(nil, "ARTWORK")
        thumb:SetColorTexture(1, 1, 1, 0.35)
        thumb:SetSize(math.max(4, width - 1), 36)
        scrollBar:SetThumbTexture(thumb)
        scrollBar._vf_thumb = thumb
        scrollBar:SetScript("OnEnter", function(self)
            if self._vf_thumb then
                self._vf_thumb:SetColorTexture(1, 1, 1, 0.55)
            end
        end)
        scrollBar:SetScript("OnLeave", function(self)
            if self._vf_thumb then
                self._vf_thumb:SetColorTexture(1, 1, 1, 0.35)
            end
        end)
    end

    return scrollBar
end

function UI.updateScrollFrameState(scrollFrame, contentHeight, viewHeight)
    local scrollBar = GetScrollBar(scrollFrame)
    if not scrollBar then
        return false
    end

    local child = scrollFrame:GetScrollChild()
    local actualContentHeight = contentHeight or (child and child:GetHeight() or 0)
    local actualViewHeight = viewHeight or scrollFrame:GetHeight()
    local overflow = actualContentHeight > actualViewHeight + 0.5

    if overflow then
        local maxScroll = math.max(0, actualContentHeight - actualViewHeight)
        scrollBar:SetMinMaxValues(0, maxScroll)
        local current = scrollFrame:GetVerticalScroll() or 0
        if current < 0 then current = 0 end
        if current > maxScroll then current = maxScroll end
        scrollBar:SetValue(current)
        if scrollBar._vf_thumb then
            local ratio = actualViewHeight / actualContentHeight
            local thumbHeight = math.max(20, scrollBar:GetHeight() * ratio)
            scrollBar._vf_thumb:SetHeight(thumbHeight)
        end
        scrollBar:Show()
    else
        scrollBar:SetMinMaxValues(0, 0)
        scrollBar:SetValue(0)
        scrollFrame:SetVerticalScroll(0)
        scrollBar:Hide()
    end

    return overflow
end

function UI.bindScrollWheel(frame, scrollFrame, step)
    if not frame or not scrollFrame then return end
    local deltaStep = step or 36
    frame:EnableMouseWheel(true)
    frame:SetScript("OnMouseWheel", function(_, delta)
        local scrollBar = GetScrollBar(scrollFrame)
        if not scrollBar or not scrollBar:IsShown() then return end
        local minVal, maxVal = scrollBar:GetMinMaxValues()
        if maxVal <= minVal then return end
        local value = scrollBar:GetValue()
        if delta > 0 then
            value = math.max(minVal, value - deltaStep)
        else
            value = math.min(maxVal, value + deltaStep)
        end
        scrollBar:SetValue(value)
    end)
end

local function ResolveFontSelection(value)
    if not value then
        return nil, nil
    end
    if not LSM then
        return value, value
    end
    local fonts = LSM:HashTable("font")
    local path = fonts[value]
    if path then
        return value, path
    end
    for name, fontPath in pairs(fonts) do
        if fontPath == value then
            return name, fontPath
        end
    end
    return value, value
end

function UI.resolveFontSelection(value)
    return ResolveFontSelection(value)
end

function UI.resolveFontPath(value)
    local _, path = ResolveFontSelection(value)
    return path
end

-- =========================================================
-- 文本组件
-- =========================================================

--- 创建大标题
-- @param parent Frame 父帧
-- @param text string 文本内容
-- @return FontString 文本对象
function UI.title(parent, text)
    local fs = parent:CreateFontString(nil, "OVERLAY", UI.style.fonts.title)
    fs:SetText(text or "")
    fs:SetJustifyH("LEFT")
    local c = UI.style.colors.primary
    fs:SetTextColor(c[1], c[2], c[3], c[4])
    return fs
end

--- 创建副标题
-- @param parent Frame 父帧
-- @param text string 文本内容
-- @return FontString 文本对象
function UI.subtitle(parent, text)
    local fs = parent:CreateFontString(nil, "OVERLAY", UI.style.fonts.subtitle)
    fs:SetText(text or "")
    fs:SetJustifyH("LEFT")
    local c = UI.style.colors.text
    fs:SetTextColor(c[1], c[2], c[3], c[4])
    return fs
end

--- 创建描述文本
-- @param parent Frame 父帧
-- @param text string 文本内容
-- @return FontString 文本对象
function UI.description(parent, text)
    local fs = parent:CreateFontString(nil, "OVERLAY", UI.style.fonts.default)
    fs:SetText(text or "")
    fs:SetJustifyH("LEFT")
    local c = UI.style.colors.textDim
    fs:SetTextColor(c[1], c[2], c[3], c[4])
    return fs
end

-- =========================================================
-- 输入组件
-- =========================================================

--- 创建按钮
-- @param parent Frame 父帧
-- @param text string 按钮文本
-- @param onClick function 点击回调
-- @return Button 按钮对象
function UI.button(parent, text, onClick)
    local btn = Pool.acquire("VFlowButton", parent)
    btn._vf_poolType = "VFlowButton"

    btn:SetText(text or "")

    -- 样式重置 (确保颜色正确)
    local ec = UI.style.colors.element
    btn:SetBackdropColor(ec[1], ec[2], ec[3], ec[4])
    local bc = UI.style.colors.border
    btn:SetBackdropBorderColor(bc[1], bc[2], bc[3], bc[4])

    local font = btn:GetFontString()
    if font then
        local tc = UI.style.colors.text
        font:SetTextColor(tc[1], tc[2], tc[3], tc[4])
    end

    -- 交互
    btn:SetScript("OnEnter", function(self)
        if self:IsEnabled() then
            local hc = UI.style.colors.hover
            self:SetBackdropColor(hc[1], hc[2], hc[3], hc[4])
        end
    end)

    btn:SetScript("OnLeave", function(self)
        if self:IsEnabled() then
            local ec = UI.style.colors.element
            self:SetBackdropColor(ec[1], ec[2], ec[3], ec[4])
        end
    end)

    btn:SetScript("OnMouseDown", function(self)
        if self:IsEnabled() then
            local ac = UI.style.colors.primary
            self:SetBackdropBorderColor(ac[1], ac[2], ac[3], ac[4])
        end
    end)

    btn:SetScript("OnMouseUp", function(self)
        if self:IsEnabled() then
            local bc = UI.style.colors.border
            self:SetBackdropBorderColor(bc[1], bc[2], bc[3], bc[4])
        end
    end)

    if onClick then
        btn:SetScript("OnClick", function(self)
            PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
            onClick(self)
        end)
    end

    return btn
end

--- 创建复选框
-- @param parent Frame 父帧
-- @param label string 标签文本
-- @param value boolean 初始值
-- @param onChange function 变更回调 function(checked)
-- @return Frame 容器帧（包含checkbox和label）
function UI.checkbox(parent, label, value, onChange)
    local container = Pool.acquire("VFlowCheckbox", parent)
    container._vf_poolType = "VFlowCheckbox"

    -- 设置标签
    container.label:SetText(label or "")
    local c = UI.style.colors.text
    container.label:SetTextColor(c[1], c[2], c[3], c[4])

    -- 设置初始值
    container.checkbox:SetChecked(value)

    -- 交互颜色反馈
    local function updateState()
        local checked = container.checkbox:GetChecked()
        if checked then
            local ac = UI.style.colors.primary
            container.checkbox:SetBackdropBorderColor(ac[1], ac[2], ac[3], ac[4])
            container.fill:Show()
        else
            local bc = UI.style.colors.border
            container.checkbox:SetBackdropBorderColor(bc[1], bc[2], bc[3], bc[4])
            container.fill:Hide()
        end
    end
    updateState()

    -- 设置回调
    container.checkbox:SetScript("OnClick", function(self)
        local checked = self:GetChecked()
        updateState()
        if onChange then
            onChange(checked)
        end
        PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
    end)

    container.checkbox:SetScript("OnEnter", function(self)
        local hc = UI.style.colors.hover
        if not self:GetChecked() then
            self:SetBackdropColor(hc[1], hc[2], hc[3], hc[4])
        end
    end)

    container.checkbox:SetScript("OnLeave", function(self)
        local ec = UI.style.colors.element
        self:SetBackdropColor(ec[1], ec[2], ec[3], ec[4])
    end)

    return container
end

--- 创建滑块
-- @param parent Frame 父帧
-- @param label string 标签文本
-- @param min number 最小值
-- @param max number 最大值
-- @param value number 当前值
-- @param step number 步进值
-- @param onChange function 变更回调 function(value)
-- @return Slider 滑块对象
function UI.slider(parent, label, min, max, value, step, onChange)
    local container = Pool.acquire("VFlowSlider", parent)
    container._vf_poolType = "VFlowSlider"
    step = step or 1
    container.fill:SetColorTexture(0.2, 0.6, 1, 0.8)
    container.fill:Show()
    container.thumb:SetColorTexture(0.2, 0.6, 1, 1)

    -- 设置范围和值
    container.slider:SetMinMaxValues(min, max)
    container.slider:SetValue(value)
    container.slider:SetValueStep(step)

    -- 更新输入框样式
    local ic = UI.style.colors.input
    container.editBox:SetBackdropColor(ic[1], ic[2], ic[3], ic[4])
    local bc = UI.style.colors.border
    container.editBox:SetBackdropBorderColor(bc[1], bc[2], bc[3], bc[4])

    -- 设置标签
    if label then
        container.label:SetText(label)
        local c = UI.style.colors.text
        container.label:SetTextColor(c[1], c[2], c[3], c[4])
    end

    -- 格式化函数
    local function formatValue(val)
        if step >= 1 and math.floor(step) == step then
            return string.format("%d", val)
        elseif step < 0.1 or (step * 10) % 1 > 0.001 then
            return string.format("%.2f", val)
        else
            return string.format("%.1f", val)
        end
    end

    -- 设置最小值和最大值文本
    container.minText:SetText(formatValue(min))
    container.maxText:SetText(formatValue(max))

    -- 更新填充条和文本
    local function updateVisuals(val)
        local pct = (val - min) / (max - min)
        if pct < 0 then pct = 0 end
        if pct > 1 then pct = 1 end

        local width = container.track:GetWidth()
        if width < 2 then
            return
        end
        container.fill:SetWidth(math.max(1, pct * width))
        container.editBox:SetText(formatValue(val))
    end

    updateVisuals(value)

    function container:RefreshVisuals()
        updateVisuals(self.slider:GetValue())
    end

    container:SetScript("OnSizeChanged", function()
        container:RefreshVisuals()
    end)

    -- Slider 回调
    local isDragging = false
    container.slider:SetScript("OnMouseDown", function(self)
        isDragging = true
    end)

    container.slider:SetScript("OnMouseUp", function(self)
        isDragging = false
        if onChange then onChange(self:GetValue()) end
    end)

    container.slider:SetScript("OnValueChanged", function(self, val)
        -- 移除自动取整，保留精度以支持微调
        -- val = math.floor(val / step + 0.5) * step
        updateVisuals(val)
        if not isDragging and onChange then
            onChange(val)
        end
    end)

    -- 微调按钮回调
    if container.minusBtn then
        container.minusBtn:SetScript("OnClick", function()
            local current = container.slider:GetValue()
            local newVal = math.max(min, current - step)
            container.slider:SetValue(newVal)
            -- 手动触发 OnValueChanged 的逻辑已经包含在 SetValue 中
            PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
        end)
    end

    if container.plusBtn then
        container.plusBtn:SetScript("OnClick", function()
            local current = container.slider:GetValue()
            local newVal = math.min(max, current + step)
            container.slider:SetValue(newVal)
            PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
        end)
    end

    -- EditBox 回调
    container.editBox:SetScript("OnEnterPressed", function(self)
        local val = tonumber(self:GetText())
        if val then
            val = math.max(min, math.min(max, val))
            container.slider:SetValue(val) -- 触发 OnValueChanged
            if onChange then onChange(val) end
        else
            self:SetText(formatValue(container.slider:GetValue()))
        end
        self:ClearFocus()
    end)

    container.editBox:SetScript("OnEscapePressed", function(self)
        self:SetText(formatValue(container.slider:GetValue()))
        self:ClearFocus()
    end)

    -- 便捷方法
    function container:SetValue(val)
        self.slider:SetValue(val)
    end

    function container:GetValue()
        return self.slider:GetValue()
    end

    C_Timer.After(0, function()
        if container and container.slider then
            container:RefreshVisuals()
        end
    end)

    return container
end

--- 创建输入框
-- @param parent Frame 父帧
-- @param label string 标签文本
-- @param value string 初始值
-- @param onChange function 变更回调 function(text)
-- @param options table|nil 额外配置 { labelOnLeft = boolean }
-- @return EditBox 输入框对象
function UI.input(parent, label, value, onChange, options)
    local outerContainer = Pool.acquire("VFlowInput", parent)
    outerContainer._vf_poolType = "VFlowInput"

    options = options or {}

    -- 重置/设置布局
    outerContainer.label:ClearAllPoints()
    outerContainer.editBox:ClearAllPoints()

    if options.labelOnLeft then
        -- 左侧标签模式
        outerContainer:SetHeight(24)
        
        if label then
            outerContainer.label:SetPoint("LEFT", 0, 0)
            outerContainer.editBox:SetPoint("LEFT", outerContainer.label, "RIGHT", 8, 0)
        else
            outerContainer.editBox:SetPoint("LEFT", 0, 0)
        end
        
        outerContainer.editBox:SetPoint("RIGHT", 0, 0)
        outerContainer.editBox:SetHeight(24)
    else
        -- 默认模式（标签在上方）
        outerContainer:SetHeight(44)
        outerContainer.label:SetPoint("TOPLEFT", 0, 0)
        
        outerContainer.editBox:SetPoint("TOPLEFT", 0, -15)
        outerContainer.editBox:SetPoint("TOPRIGHT", 0, -15)
        outerContainer.editBox:SetHeight(24)
    end

    -- 设置标签
    if label then
        outerContainer.label:SetText(label)
        outerContainer.label:Show()
        local c = UI.style.colors.text
        outerContainer.label:SetTextColor(c[1], c[2], c[3], c[4])
    else
        outerContainer.label:Hide()
    end

    -- 设置初始值
    outerContainer.editBox:SetText(value or "")

    -- 设置输入框背景色
    local ic = UI.style.colors.input
    outerContainer.editBox:SetBackdropColor(ic[1], ic[2], ic[3], ic[4])
    local bc = UI.style.colors.border
    outerContainer.editBox:SetBackdropBorderColor(bc[1], bc[2], bc[3], bc[4])

    -- 交互样式
    outerContainer.editBox:SetScript("OnEditFocusGained", function(self)
        local ac = UI.style.colors.primary
        self:SetBackdropBorderColor(ac[1], ac[2], ac[3], ac[4])
    end)

    outerContainer.editBox:SetScript("OnEditFocusLost", function(self)
        local bc = UI.style.colors.border
        self:SetBackdropBorderColor(bc[1], bc[2], bc[3], bc[4])
        if onChange then onChange(self:GetText()) end
    end)

    -- 设置回调
    outerContainer.editBox:SetScript("OnEnterPressed", function(self)
        self:ClearFocus() -- 触发 OnEditFocusLost
    end)

    outerContainer.editBox:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
    end)

    return outerContainer
end

--- 创建下拉框
-- @param parent Frame 父帧
-- @param label string 标签文本
-- @param items table 选项列表 { "选项1", "选项2" } 或 { {"显示", "值"}, ... }
-- @param value any 当前值
-- @param onChange function 变更回调 function(value)
-- @param options table|nil 额外配置 { labelOnLeft = boolean }
-- @return DropdownButton 下拉框对象
function UI.dropdown(parent, label, items, value, onChange, options)
    local outerContainer = Pool.acquire("VFlowDropdown", parent)
    outerContainer._vf_poolType = "VFlowDropdown"

    options = options or {}

    local btn = outerContainer.dropdown
    local menu = outerContainer.menu

    -- 重置/设置布局
    outerContainer.label:ClearAllPoints()
    btn:ClearAllPoints()

    if options.labelOnLeft then
        -- 左侧标签模式
        outerContainer:SetHeight(24)

        if label then
            outerContainer.label:SetPoint("LEFT", 0, 0)
            btn:SetPoint("LEFT", outerContainer.label, "RIGHT", 8, 0)
        else
            btn:SetPoint("LEFT", 0, 0)
        end

        btn:SetPoint("RIGHT", 0, 0)
        btn:SetHeight(24)
    else
        -- 默认模式（标签在上方）
        outerContainer:SetHeight(50)
        outerContainer.label:SetPoint("TOPLEFT", 0, 0)

        btn:SetPoint("TOPLEFT", 0, -16)
        btn:SetPoint("TOPRIGHT", 0, -16)
        btn:SetHeight(24)
    end

    -- 设置标签
    if label then
        outerContainer.label:SetText(label)
        outerContainer.label:Show()
        local c = UI.style.colors.text
        outerContainer.label:SetTextColor(c[1], c[2], c[3], c[4])
    else
        outerContainer.label:Hide()
    end

    -- 存储状态
    btn._items = items
    btn._value = value
    btn._onChange = onChange

    -- 获取显示文本
    local function getDisplayText(val)
        for _, item in ipairs(items) do
            if type(item) == "table" then
                if item[2] == val then return item[1] end
            else
                if item == val then return item end
            end
        end
        return "请选择..."
    end

    btn.text:SetText(getDisplayText(value))

    -- 构建菜单
    local function buildMenu()
        -- 清理旧按钮 (简单隐藏，实际应复用)
        if not menu.items then menu.items = {} end
        for _, item in ipairs(menu.items) do item:Hide() end

        local height = 4
        for i, itemData in ipairs(items) do
            local displayText, itemValue
            if type(itemData) == "table" then
                displayText, itemValue = itemData[1], itemData[2]
            else
                displayText, itemValue = itemData, itemData
            end

            local itemBtn = menu.items[i]
            if not itemBtn then
                itemBtn = CreateFrame("Button", nil, menu)
                itemBtn:SetHeight(22)
                itemBtn:SetPoint("LEFT", 2, 0)
                itemBtn:SetPoint("RIGHT", -2, 0)

                itemBtn.text = itemBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                itemBtn.text:SetPoint("LEFT", 8, 0)
                itemBtn.text:SetJustifyH("LEFT")

                itemBtn.highlight = itemBtn:CreateTexture(nil, "BACKGROUND")
                itemBtn.highlight:SetAllPoints()
                local hc = UI.style.colors.primary
                itemBtn.highlight:SetColorTexture(hc[1], hc[2], hc[3], 0.3)
                itemBtn.highlight:Hide()

                itemBtn:SetScript("OnEnter", function(self) self.highlight:Show() end)
                itemBtn:SetScript("OnLeave", function(self) self.highlight:Hide() end)

                menu.items[i] = itemBtn
            end

            itemBtn:SetPoint("TOP", 0, -2 - (i - 1) * 22)
            itemBtn.text:SetText(displayText)
            itemBtn:Show()

            if itemValue == btn._value then
                local ac = UI.style.colors.primary
                itemBtn.text:SetTextColor(ac[1], ac[2], ac[3], 1)
            else
                local tc = UI.style.colors.text
                itemBtn.text:SetTextColor(tc[1], tc[2], tc[3], 1)
            end

            itemBtn:SetScript("OnClick", function()
                btn._value = itemValue
                btn.text:SetText(displayText)
                menu:Hide()
                if onChange then onChange(itemValue) end
            end)

            height = height + 22
        end

        menu:SetHeight(height + 4)
    end

    -- 按钮交互
    btn:SetScript("OnClick", function()
        if menu:IsShown() then
            menu:Hide()
        else
            buildMenu()
            menu:Show()
        end
        PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
    end)

    btn:SetScript("OnEnter", function(self)
        local hc = UI.style.colors.hover
        self:SetBackdropColor(hc[1], hc[2], hc[3], hc[4])
    end)

    btn:SetScript("OnLeave", function(self)
        if not menu:IsShown() then
            local ec = UI.style.colors.element
            self:SetBackdropColor(ec[1], ec[2], ec[3], ec[4])
        end
    end)

    menu:SetScript("OnHide", function()
        local ec = UI.style.colors.element
        btn:SetBackdropColor(ec[1], ec[2], ec[3], ec[4])
    end)

    return outerContainer
end

--- 创建颜色选择器
-- @param parent Frame 父帧
-- @param label string 标签文本
-- @param value table 颜色值 {r, g, b, a}
-- @param hasAlpha boolean 是否包含透明度
-- @param onChange function 变更回调 function(r, g, b, a)
-- @return Frame 容器帧
function UI.colorPicker(parent, label, value, hasAlpha, onChange)
    local container = Pool.acquire("VFlowColorPicker", parent)
    container._vf_poolType = "VFlowColorPicker"
    local btn = container.button

    -- 设置标签
    container.label:SetText(label or "")
    local c = UI.style.colors.text
    container.label:SetTextColor(c[1], c[2], c[3], c[4])

    -- 设置颜色
    value = value or {}
    local r, g, b, a = value.r or 1, value.g or 1, value.b or 1, value.a or 1
    local function toHex(v)
        return string.format("%02X", math.floor(math.max(0, math.min(1, v)) * 255 + 0.5))
    end
    local function updateVisual(newR, newG, newB, newA)
        container.swatch:SetColorTexture(newR, newG, newB, newA)
        if hasAlpha then
            container.hexText:SetText("#" .. toHex(newR) .. toHex(newG) .. toHex(newB) .. toHex(newA))
        else
            container.hexText:SetText("#" .. toHex(newR) .. toHex(newG) .. toHex(newB))
        end
    end
    updateVisual(r, g, b, a)

    local ec = UI.style.colors.element
    btn:SetBackdropColor(ec[1], ec[2], ec[3], ec[4])
    local bc = UI.style.colors.border
    btn:SetBackdropBorderColor(bc[1], bc[2], bc[3], bc[4])
    local tc = UI.style.colors.text
    container.hexText:SetTextColor(tc[1], tc[2], tc[3], tc[4])

    btn:SetScript("OnEnter", function(self)
        local hc = UI.style.colors.hover
        self:SetBackdropColor(hc[1], hc[2], hc[3], hc[4])
    end)

    btn:SetScript("OnLeave", function(self)
        local ec2 = UI.style.colors.element
        self:SetBackdropColor(ec2[1], ec2[2], ec2[3], ec2[4])
    end)

    -- 点击回调
    btn:SetScript("OnClick", function()
        local info = {
            r = r,
            g = g,
            b = b,
            opacity = hasAlpha and a or nil,
            hasOpacity = hasAlpha,
            swatchFunc = function()
                local newR, newG, newB = ColorPickerFrame:GetColorRGB()
                local newA = hasAlpha and ColorPickerFrame:GetColorAlpha() or 1
                updateVisual(newR, newG, newB, newA)
                if onChange then onChange(newR, newG, newB, newA) end
                r, g, b, a = newR, newG, newB, newA
            end,
            opacityFunc = hasAlpha and function()
                local newA = ColorPickerFrame:GetColorAlpha()
                updateVisual(r, g, b, newA)
                if onChange then onChange(r, g, b, newA) end
                a = newA
            end or nil,
            cancelFunc = function()
                updateVisual(r, g, b, a)
                if onChange then onChange(r, g, b, a) end
            end,
        }
        ColorPickerFrame:SetupColorPickerAndShow(info)
        if ColorPickerFrame then
            ColorPickerFrame:SetFrameStrata("TOOLTIP")
            ColorPickerFrame:SetFrameLevel(500)
            C_Timer.After(0, function()
                if ColorPickerFrame and ColorPickerFrame:IsShown() then
                    ColorPickerFrame:SetFrameStrata("TOOLTIP")
                    ColorPickerFrame:SetFrameLevel(500)
                end
            end)
        end
    end)

    return container
end

--- 创建材质选择器 (集成LibSharedMedia)
-- @param parent Frame 父帧
-- @param label string 标签文本
-- @param value string 当前材质路径
-- @param onChange function 变更回调 function(path)
-- @return Frame 容器帧
function UI.texturePicker(parent, label, value, onChange)
    local container = Pool.acquire("VFlowResourcePicker", parent)
    container._vf_poolType = "VFlowResourcePicker"

    local btn = container.dropdown
    local menu = container.menu
    local scrollChild = container.scrollChild
    local searchBox = container.searchBox
    local scrollFrame = container.scrollFrame

    -- LibSharedMedia
    local LSM = LibStub("LibSharedMedia-3.0", true)
    menu:SetParent(UIParent)
    menu:SetToplevel(true)
    UI.styleScrollFrame(scrollFrame, {
        anchorParent = menu,
        offsetX = -4,
        topOffset = -30,
        bottomOffset = 2,
        width = 6,
    })

    -- 更新搜索框样式
    local ic = UI.style.colors.input
    searchBox:SetBackdropColor(ic[1], ic[2], ic[3], ic[4])
    local bc = UI.style.colors.border
    searchBox:SetBackdropBorderColor(bc[1], bc[2], bc[3], bc[4])

    -- 设置标签
    container.label:SetText(label or "")
    local c = UI.style.colors.text
    container.label:SetTextColor(c[1], c[2], c[3], c[4])

    -- 更新显示
    local function updateDisplay(value)
        local name = value
        local path = value

        if LSM then
            local textures = LSM:HashTable("statusbar")
            -- 情况1: value 是材质名称 (Key)
            if textures[value] then
                name = value
                path = textures[value]
            else
                -- 情况2: value 是材质路径 (Path)，尝试反查名称
                for k, v in pairs(textures) do
                    if v == value then
                        name = k
                        path = v
                        break
                    end
                end
            end
        end

        btn.text:SetText(name or "Select Texture")
        container.preview:SetTexture(path)
        container.preview:Show()
        -- 调整文本位置以避开预览图
        btn.text:SetPoint("LEFT", 90, 0)
    end

    updateDisplay(value)

    -- 构建菜单
    local function buildMenu(filter)
        if not LSM then return end
        local textures = LSM:HashTable("statusbar")
        local sorted = {}
        for k, v in pairs(textures) do
            if not filter or k:lower():find(filter:lower(), 1, true) then
                table.insert(sorted, { name = k, path = v })
            end
        end
        table.sort(sorted, function(a, b) return a.name < b.name end)

        -- 重用按钮
        if not menu.items then menu.items = {} end
        for _, item in ipairs(menu.items) do item:Hide() end

        local height = 0
        local ITEM_HEIGHT = 28

        for i, data in ipairs(sorted) do
            local itemBtn = menu.items[i]
            if not itemBtn then
                itemBtn = CreateFrame("Button", nil, scrollChild)
                itemBtn:SetSize(230, ITEM_HEIGHT)

                itemBtn.preview = itemBtn:CreateTexture(nil, "ARTWORK")
                itemBtn.preview:SetPoint("LEFT", 4, 0)
                itemBtn.preview:SetSize(80, 18)

                itemBtn.text = itemBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                itemBtn.text:SetPoint("LEFT", 90, 0)
                itemBtn.text:SetJustifyH("LEFT")

                itemBtn.highlight = itemBtn:CreateTexture(nil, "BACKGROUND")
                itemBtn.highlight:SetAllPoints()
                local hc = UI.style.colors.primary
                itemBtn.highlight:SetColorTexture(hc[1], hc[2], hc[3], 0.3)
                itemBtn.highlight:Hide()

                itemBtn:SetScript("OnEnter", function(self) self.highlight:Show() end)
                itemBtn:SetScript("OnLeave", function(self) self.highlight:Hide() end)

                menu.items[i] = itemBtn
            end

            itemBtn:SetPoint("TOPLEFT", 0, -height)
            itemBtn.text:SetText(data.name)
            itemBtn.preview:SetTexture(data.path)
            itemBtn:Show()

            itemBtn:SetScript("OnClick", function()
                updateDisplay(data.name)
                menu:Hide()
                if onChange then onChange(data.name) end
            end)

            height = height + ITEM_HEIGHT
        end

        scrollChild:SetHeight(height)
        local visibleCount = #sorted
        if visibleCount > 8 then
            visibleCount = 8
        end
        if visibleCount < 1 then
            visibleCount = 1
        end
        menu:SetHeight(34 + visibleCount * ITEM_HEIGHT + 6)
        local viewportHeight = visibleCount * ITEM_HEIGHT + 2
        UI.updateScrollFrameState(scrollFrame, height, viewportHeight)
    end

    -- 搜索框逻辑
    searchBox:SetScript("OnTextChanged", function(self)
        buildMenu(self:GetText())
    end)

    -- 按钮交互
    btn:SetScript("OnClick", function()
        if menu:IsShown() then
            menu:Hide()
        else
            buildMenu()
            menu:ClearAllPoints()
            menu:SetPoint("TOPLEFT", btn, "BOTTOMLEFT", 0, -2)
            menu:SetPoint("TOPRIGHT", btn, "BOTTOMRIGHT", 0, -2)
            menu:SetFrameStrata("TOOLTIP")
            menu:SetFrameLevel(btn:GetFrameLevel() + 80)
            menu:Show()
            menu:Raise()
            UI.updateScrollFrameState(scrollFrame)
            UI.bindScrollWheel(menu, scrollFrame, 28)
            searchBox:SetText("")
            searchBox:SetFocus()
        end
        PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
    end)

    return container
end

--- 创建字体选择器 (集成LibSharedMedia)
-- @param parent Frame 父帧
-- @param label string 标签文本
-- @param value string 当前字体名或路径
-- @param onChange function 变更回调 function(fontName)
-- @return Frame 容器帧
function UI.fontPicker(parent, label, value, onChange)
    local container = Pool.acquire("VFlowResourcePicker", parent)
    container._vf_poolType = "VFlowResourcePicker"

    local btn = container.dropdown
    local menu = container.menu
    local scrollChild = container.scrollChild
    local searchBox = container.searchBox
    local scrollFrame = container.scrollFrame

    menu:SetParent(UIParent)
    menu:SetToplevel(true)
    UI.styleScrollFrame(scrollFrame, {
        anchorParent = menu,
        offsetX = -4,
        topOffset = -30,
        bottomOffset = 2,
        width = 6,
    })

    -- 更新搜索框样式
    local ic = UI.style.colors.input
    searchBox:SetBackdropColor(ic[1], ic[2], ic[3], ic[4])
    local bc = UI.style.colors.border
    searchBox:SetBackdropBorderColor(bc[1], bc[2], bc[3], bc[4])

    container.label:SetText(label or "")
    local c = UI.style.colors.text
    container.label:SetTextColor(c[1], c[2], c[3], c[4])

    -- 隐藏不需要的预览图
    container.preview:Hide()
    btn.text:SetPoint("LEFT", 8, 0)

    local function updateDisplay(fontValue)
        local name, path = ResolveFontSelection(fontValue)
        btn.text:SetText(name or "Select Font")
        if path then
            pcall(function() btn.text:SetFont(path, 10) end)
        end
    end

    updateDisplay(value)

    local function buildMenu(filter)
        if not LSM then return end
        local fonts = LSM:HashTable("font")
        local sorted = {}
        for k, v in pairs(fonts) do
            if not filter or k:lower():find(filter:lower(), 1, true) then
                table.insert(sorted, { name = k, path = v })
            end
        end
        table.sort(sorted, function(a, b) return a.name < b.name end)

        if not menu.items then menu.items = {} end
        for _, item in ipairs(menu.items) do item:Hide() end

        local height = 0
        local ITEM_HEIGHT = 24

        for i, data in ipairs(sorted) do
            local itemBtn = menu.items[i]
            if not itemBtn then
                itemBtn = CreateFrame("Button", nil, scrollChild)
                itemBtn:SetSize(230, ITEM_HEIGHT)

                itemBtn.text = itemBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                itemBtn.text:SetPoint("LEFT", 8, 0)
                itemBtn.text:SetJustifyH("LEFT")

                itemBtn.highlight = itemBtn:CreateTexture(nil, "BACKGROUND")
                itemBtn.highlight:SetAllPoints()
                local hc = UI.style.colors.primary
                itemBtn.highlight:SetColorTexture(hc[1], hc[2], hc[3], 0.3)
                itemBtn.highlight:Hide()

                itemBtn:SetScript("OnEnter", function(self) self.highlight:Show() end)
                itemBtn:SetScript("OnLeave", function(self) self.highlight:Hide() end)

                menu.items[i] = itemBtn
            end

            itemBtn:SetPoint("TOPLEFT", 0, -height)
            itemBtn.text:SetText(data.name)
            pcall(function() itemBtn.text:SetFont(data.path, 12) end)
            itemBtn:Show()

            itemBtn:SetScript("OnClick", function()
                updateDisplay(data.name)
                menu:Hide()
                if onChange then onChange(data.name) end
            end)

            height = height + ITEM_HEIGHT
        end

        scrollChild:SetHeight(height)
        local visibleCount = #sorted
        if visibleCount > 10 then
            visibleCount = 10
        end
        if visibleCount < 1 then
            visibleCount = 1
        end
        menu:SetHeight(34 + visibleCount * ITEM_HEIGHT + 6)
        local viewportHeight = visibleCount * ITEM_HEIGHT + 2
        UI.updateScrollFrameState(scrollFrame, height, viewportHeight)
    end

    searchBox:SetScript("OnTextChanged", function(self)
        buildMenu(self:GetText())
    end)

    btn:SetScript("OnClick", function()
        if menu:IsShown() then
            menu:Hide()
        else
            buildMenu()
            menu:ClearAllPoints()
            menu:SetPoint("TOPLEFT", btn, "BOTTOMLEFT", 0, -2)
            menu:SetPoint("TOPRIGHT", btn, "BOTTOMRIGHT", 0, -2)
            menu:SetFrameStrata("TOOLTIP")
            menu:SetFrameLevel(btn:GetFrameLevel() + 80)
            menu:Show()
            menu:Raise()
            UI.updateScrollFrameState(scrollFrame)
            UI.bindScrollWheel(menu, scrollFrame, 24)
            searchBox:SetText("")
            searchBox:SetFocus()
        end
        PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
    end)

    return container
end

-- =========================================================
-- 布局组件
-- =========================================================

--- 创建容器
-- @param parent Frame 父帧
-- @param width number 宽度
-- @param height number 高度
-- @return Frame 容器帧
function UI.container(parent, width, height)
    local container = Pool.acquire("VFlowContainer", parent)
    container._vf_poolType = "VFlowContainer"

    container:SetSize(width or 100, height or 100)
    CreatePanelBackdrop(container)

    return container
end

--- 创建分隔线
-- @param parent Frame 父帧
-- @return Texture 分隔线纹理
function UI.separator(parent)
    local container = Pool.acquire("VFlowSeparator", parent)
    container._vf_poolType = "VFlowSeparator"

    local c = UI.style.colors.border
    container.line:SetColorTexture(c[1], c[2], c[3], c[4])

    return container
end

--- 创建间距
-- @param parent Frame 父帧
-- @param height number 高度
-- @return Frame 间距帧
function UI.spacer(parent, height)
    local spacer = Pool.acquire("VFlowSpacer", parent)
    spacer._vf_poolType = "VFlowSpacer"

    spacer:SetHeight(height or 10)

    return spacer
end

--- 创建图标按钮
-- @param parent Frame 父帧
-- @param iconTexture string|number 图标路径或spellID
-- @param size number 按钮尺寸
-- @param onClick function 点击回调
-- @param tooltipFunc function|string Tooltip函数或文本
-- @return Button 图标按钮
-- @param borderColor table|nil { r,g,b,a } 静止边框颜色，nil 则用默认灰色
function UI.iconButton(parent, iconTexture, size, onClick, tooltipFunc, borderColor)
    local btn = Pool.acquire("VFlowIconButton", parent)
    btn._vf_poolType = "VFlowIconButton"

    btn:SetSize(size or 40, size or 40)

    if type(iconTexture) == "number" then
        btn.icon:SetTexture(iconTexture)
    else
        btn.icon:SetTexture(iconTexture or 134400)
    end
    btn.icon:Show()

    local ec = UI.style.colors.element
    btn:SetBackdropColor(ec[1], ec[2], ec[3], 0.8)

    -- 静止边框颜色（选中/启用时由外部传入，否则用默认灰）
    local bc = UI.style.colors.border
    local restBC = borderColor or bc
    btn:SetBackdropBorderColor(restBC[1], restBC[2], restBC[3], restBC[4] or 1)

    btn:SetScript("OnEnter", function(self)
        self.highlight:Show()
        local pc = UI.style.colors.primary
        self:SetBackdropBorderColor(pc[1], pc[2], pc[3], 1)
        if tooltipFunc then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            if type(tooltipFunc) == "function" then
                tooltipFunc(GameTooltip)
            elseif type(tooltipFunc) == "string" then
                GameTooltip:SetText(tooltipFunc)
            end
            GameTooltip:Show()
        end
    end)

    btn:SetScript("OnLeave", function(self)
        self.highlight:Hide()
        self:SetBackdropBorderColor(restBC[1], restBC[2], restBC[3], restBC[4] or 1)
        GameTooltip:Hide()
    end)

    if onClick then
        btn:SetScript("OnClick", function(self)
            PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
            onClick(self)
        end)
    end

    return btn
end

function UI.dialog(parent, title, message, onConfirm, onCancel, opts)
    opts = opts or {}
    local targetParent = parent or UIParent
    local dialog = Pool.acquire("VFlowDialog", targetParent)
    dialog._vf_poolType = "VFlowDialog"
    dialog:SetParent(targetParent)
    dialog:SetAllPoints(targetParent)

    local panelWidth = opts.width or 420
    local panelHeight = opts.height or 200
    dialog.panel:SetSize(panelWidth, panelHeight)
    dialog.panel:ClearAllPoints()
    dialog.panel:SetPoint("CENTER", 0, opts.offsetY or 40)

    local dimAlpha = opts.dimAlpha or 0.45
    dialog.dim:SetColorTexture(0, 0, 0, dimAlpha)

    local primary = UI.style.colors.primary
    local element = UI.style.colors.element
    local border = UI.style.colors.border
    local hover = UI.style.colors.hover

    local confirmLabel = opts.confirmText or "确认"
    local cancelLabel = opts.cancelText or "取消"

    dialog.titleText:SetText(title or "请确认")
    dialog.messageText:SetText(message or "")
    dialog.confirmText:SetText(confirmLabel)
    dialog.cancelText:SetText(cancelLabel)

    dialog._onConfirm = onConfirm
    dialog._onCancel = onCancel
    dialog._closeOnOutside = (opts.closeOnOutside ~= false)

    if opts.destructive then
        local err = UI.style.colors.error
        dialog.confirmButton:SetBackdropColor(err[1], err[2], err[3], 0.25)
        dialog.confirmButton:SetBackdropBorderColor(err[1], err[2], err[3], 0.95)
    else
        dialog.confirmButton:SetBackdropColor(primary[1], primary[2], primary[3], 0.22)
        dialog.confirmButton:SetBackdropBorderColor(primary[1], primary[2], primary[3], 0.9)
    end

    dialog.cancelButton:SetBackdropColor(element[1], element[2], element[3], element[4])
    dialog.cancelButton:SetBackdropBorderColor(border[1], border[2], border[3], border[4])

    if opts.showCancel == false then
        dialog.cancelButton:Hide()
        dialog.confirmButton:ClearAllPoints()
        dialog.confirmButton:SetPoint("BOTTOM", dialog.panel, "BOTTOM", 0, 14)
    else
        dialog.cancelButton:Show()
        dialog.confirmButton:ClearAllPoints()
        dialog.confirmButton:SetPoint("BOTTOMRIGHT", -14, 14)
        dialog.cancelButton:ClearAllPoints()
        dialog.cancelButton:SetPoint("RIGHT", dialog.confirmButton, "LEFT", -8, 0)
    end

    local function closeAndCall(callback)
        UI.release(dialog)
        if callback then
            callback()
        end
    end

    dialog.blocker:SetScript("OnClick", function()
        if dialog._closeOnOutside then
            closeAndCall(dialog._onCancel)
        end
    end)
    dialog.closeButton:SetScript("OnClick", function()
        closeAndCall(dialog._onCancel)
    end)
    dialog.confirmButton:SetScript("OnClick", function()
        closeAndCall(dialog._onConfirm)
    end)
    dialog.cancelButton:SetScript("OnClick", function()
        closeAndCall(dialog._onCancel)
    end)

    dialog.closeButton:SetScript("OnEnter", function(self)
        self:SetBackdropColor(hover[1], hover[2], hover[3], hover[4])
    end)
    dialog.closeButton:SetScript("OnLeave", function(self)
        self:SetBackdropColor(element[1], element[2], element[3], element[4])
    end)
    dialog.cancelButton:SetScript("OnEnter", function(self)
        self:SetBackdropColor(hover[1], hover[2], hover[3], hover[4])
    end)
    dialog.cancelButton:SetScript("OnLeave", function(self)
        self:SetBackdropColor(element[1], element[2], element[3], element[4])
    end)

    dialog:Show()
    dialog.panel:Show()
    return dialog
end

--- 创建可交互文本组件（富文本链接）
-- @param parent Frame 父帧
-- @param config table 配置: { text="普通文本{链接1}更多文本{链接2}", links={["链接1"]=fn1, ["链接2"]=fn2} }
--   使用 {xxx} 标记可点击的链接文本，links 表提供对应的点击回调
-- @return Frame 容器帧
function UI.interactiveText(parent, config)
    local container = Pool.acquire("VFlowInteractiveText", parent)
    container._vf_poolType = "VFlowInteractiveText"

    if not config or not config.text then
        return container
    end

    local segments = {}
    local text = config.text
    local links = config.links or {}
    local pos = 1

    while pos <= #text do
        local linkStart, linkEnd = text:find("{[^}]+}", pos)

        if linkStart then
            -- 添加链接前的普通文本
            if linkStart > pos then
                local normalText = text:sub(pos, linkStart - 1)
                table.insert(segments, { text = normalText, clickable = false })
            end

            local linkText = text:sub(linkStart + 1, linkEnd - 1)
            local onClick = links[linkText]

            table.insert(segments, {
                text = linkText,
                clickable = true,
                onClick = onClick
            })

            pos = linkEnd + 1
        else
            local remainingText = text:sub(pos)
            if #remainingText > 0 then
                table.insert(segments, { text = remainingText, clickable = false })
            end
            break
        end
    end

    if #segments == 0 then
        return container
    end

    local textColor  = UI.style.colors.textDim
    local linkColor  = UI.style.colors.primary
    local hoverColor = { 0.3, 0.7, 1, 1 }
    local lineHeight = 16
    local lineGap = 4

    local function nextUtf8Char(str, i)
        local c = str:byte(i)
        if not c then return nil, i end
        if c < 0x80 then return str:sub(i, i), i + 1 end
        if c < 0xE0 then return str:sub(i, i + 1), i + 2 end
        if c < 0xF0 then return str:sub(i, i + 2), i + 3 end
        return str:sub(i, i + 3), i + 4
    end

    local function splitTextTokens(str)
        local tokens = {}
        local i = 1
        while i <= #str do
            local ch, nextI = nextUtf8Char(str, i)
            local byte = ch and ch:byte(1) or nil
            if not byte then break end
            if byte <= 0x7F then
                if ch:match("%s") then
                    local startI = i
                    i = nextI
                    while i <= #str do
                        local ch2, n2 = nextUtf8Char(str, i)
                        if not ch2 or not ch2:match("%s") then break end
                        i = n2
                    end
                    table.insert(tokens, str:sub(startI, i - 1))
                else
                    local startI = i
                    i = nextI
                    while i <= #str do
                        local ch2, n2 = nextUtf8Char(str, i)
                        if not ch2 then break end
                        local b2 = ch2:byte(1)
                        if b2 > 0x7F or ch2:match("%s") then break end
                        i = n2
                    end
                    table.insert(tokens, str:sub(startI, i - 1))
                end
            else
                table.insert(tokens, ch)
                i = nextI
            end
        end
        return tokens
    end

    local nodes = {}

    for _, segment in ipairs(segments) do
        if segment.clickable then
            local btn = CreateFrame("Button", nil, container)
            btn:SetHeight(lineHeight)

            local fs = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            fs:SetText(segment.text)
            fs:SetTextColor(linkColor[1], linkColor[2], linkColor[3], linkColor[4])
            fs:SetJustifyH("LEFT")
            fs:SetJustifyV("TOP")
            fs:SetPoint("TOPLEFT", btn, "TOPLEFT", 1, 0)
            fs:SetPoint("TOPRIGHT", btn, "TOPRIGHT", -1, 0)

            local w = fs:GetStringWidth() + 2
            btn:SetWidth(w)

            local underline = btn:CreateTexture(nil, "BACKGROUND")
            underline:SetPoint("BOTTOMLEFT",  fs, "BOTTOMLEFT",  0, -1)
            underline:SetPoint("BOTTOMRIGHT", fs, "BOTTOMRIGHT", 0, -1)
            underline:SetHeight(1)
            underline:SetColorTexture(linkColor[1], linkColor[2], linkColor[3], 0.5)

            btn:SetScript("OnEnter", function(self)
                fs:SetTextColor(hoverColor[1], hoverColor[2], hoverColor[3], hoverColor[4])
                underline:SetColorTexture(hoverColor[1], hoverColor[2], hoverColor[3], 0.8)
            end)
            btn:SetScript("OnLeave", function(self)
                fs:SetTextColor(linkColor[1], linkColor[2], linkColor[3], linkColor[4])
                underline:SetColorTexture(linkColor[1], linkColor[2], linkColor[3], 0.5)
            end)
            if segment.onClick then
                btn:SetScript("OnClick", function(self)
                    PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
                    segment.onClick()
                end)
            end

            table.insert(container.segments, { button = btn, text = fs, underline = underline })
            table.insert(nodes, { frame = btn, width = w, isSpace = false })
        else
            local tokens = splitTextTokens(segment.text)
            for _, token in ipairs(tokens) do
                local fs = container:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                fs:SetText(token)
                fs:SetTextColor(textColor[1], textColor[2], textColor[3], textColor[4])
                fs:SetJustifyH("LEFT")
                fs:SetJustifyV("TOP")
                local w = fs:GetStringWidth()
                table.insert(container.segments, { text = fs })
                table.insert(nodes, { frame = fs, width = w, isSpace = token:match("^%s+$") ~= nil })
            end
        end
    end

    local function layout(availableW)
        if not availableW or availableW <= 0 then return end

        local x, y = 0, 0

        for _, node in ipairs(nodes) do
            if x > 0 and x + node.width > availableW then
                x = 0
                y = y + lineHeight + lineGap
            end

            if x == 0 and node.isSpace then
                node.frame:ClearAllPoints()
                node.frame:Hide()
            else
                node.frame:Show()
                node.frame:ClearAllPoints()
                node.frame:SetPoint("TOPLEFT", container, "TOPLEFT", x, -y)
                x = x + node.width
            end
        end

        local totalH = y + lineHeight
        container:SetHeight(totalH)

        local p = container:GetParent()
        while p do
            if p.UpdateScrollState then p:UpdateScrollState(); break end
            p = p:GetParent()
        end
    end

    container:SetScript("OnSizeChanged", function(self, w)
        layout(w)
    end)

    local initW = parent:GetWidth()
    if initW and initW > 0 then
        layout(initW)
    else
        container:SetHeight(lineHeight)
    end

    return container
end

-- =========================================================
-- 释放函数（归还帧到池）
-- =========================================================

--- 释放组件回池
-- @param frame Frame 要释放的帧
function UI.release(frame)
    if not frame then return end

    local poolType = frame._vf_poolType
    if poolType then
        Pool.release(poolType, frame)
    else
        -- 非池化组件，直接隐藏
        frame:Hide()
        frame:ClearAllPoints()
        frame:SetParent(nil)
    end
end

--- 释放按钮
function UI.releaseButton(frame)
    UI.release(frame)
end

--- 释放复选框
function UI.releaseCheckbox(frame)
    UI.release(frame)
end

--- 释放滑块
function UI.releaseSlider(frame)
    UI.release(frame)
end

--- 释放输入框
function UI.releaseInput(frame)
    UI.release(frame)
end

--- 释放下拉框
function UI.releaseDropdown(frame)
    UI.release(frame)
end

--- 释放容器
function UI.releaseContainer(frame)
    UI.release(frame)
end

--- 释放分隔线
function UI.releaseSeparator(frame)
    UI.release(frame)
end

--- 释放间距
function UI.releaseSpacer(frame)
    UI.release(frame)
end

--- 释放图标按钮
function UI.releaseIconButton(frame)
    UI.release(frame)
end

function UI.releaseDialog(frame)
    UI.release(frame)
end

--- 释放可交互文本
function UI.releaseInteractiveText(frame)
    UI.release(frame)
end
