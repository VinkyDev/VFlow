-- PoolWidgets — UI 组件帧池模板
local VFlow = _G.VFlow
local Pool = VFlow.Pool

-- 减少 backdrop 样板代码
local FLAT_BACKDROP = {
    bgFile = "Interface\\Buttons\\WHITE8x8",
    edgeFile = "Interface\\Buttons\\WHITE8x8",
    edgeSize = 1,
}

local function applyBackdrop(f, bgR, bgG, bgB, bgA, borderR, borderG, borderB, borderA)
    if not f.SetBackdrop then Mixin(f, BackdropTemplateMixin) end
    f:SetBackdrop(FLAT_BACKDROP)
    f:SetBackdropColor(bgR or 0.15, bgG or 0.15, bgB or 0.15, bgA or 1)
    f:SetBackdropBorderColor(borderR or 0.25, borderG or 0.25, borderB or 0.25, borderA or 1)
end

-- =========================================================
-- 1. 菜单按钮
-- =========================================================

Pool.init("VFlowButton", "Button", nil, function(btn)
    btn:SetSize(120, 24)
    applyBackdrop(btn)

    local text = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    text:SetPoint("CENTER", 0, 0)
    btn:SetFontString(text)
    btn:SetNormalFontObject("GameFontHighlight")
    btn:SetHighlightFontObject("GameFontHighlight")
    btn.text = text
end)

-- =========================================================
-- 2. 通用容器
-- =========================================================

Pool.init("VFlowContainer", "Frame", "BackdropTemplate", function(f)
    f:SetSize(100, 100)
end)

-- =========================================================
-- 3. 滑块组件
-- =========================================================

Pool.init("VFlowSlider", "Frame", nil, function(container)
    container:SetHeight(50)

    local label = container:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    label:SetPoint("TOPLEFT", 0, -4)
    container.label = label

    local editBox = CreateFrame("EditBox", nil, container, "BackdropTemplate")
    editBox:SetPoint("TOPRIGHT", 0, -1)
    editBox:SetSize(46, 18)
    applyBackdrop(editBox, 0.1, 0.1, 0.1, 0.8)
    editBox:SetFontObject("GameFontHighlightSmall")
    editBox:SetJustifyH("CENTER")
    editBox:SetAutoFocus(false)
    editBox:SetTextInsets(2, 2, 0, 0)
    container.editBox = editBox

    local track = CreateFrame("Frame", nil, container, "BackdropTemplate")
    track:SetPoint("LEFT", 20, 0)
    track:SetPoint("RIGHT", -20, 0)
    track:SetPoint("TOP", 0, -25)
    track:SetHeight(8)
    applyBackdrop(track)
    container.track = track

    local fill = track:CreateTexture(nil, "ARTWORK")
    fill:SetPoint("LEFT", 1, 0)
    fill:SetHeight(6)
    fill:SetWidth(1)
    fill:SetColorTexture(0.25, 0.52, 0.95, 0.8)
    container.fill = fill

    local slider = CreateFrame("Slider", nil, container)
    slider:SetAllPoints(track)
    slider:SetOrientation("HORIZONTAL")
    slider:SetHitRectInsets(-4, -4, -8, -8)
    container.slider = slider

    local thumb = slider:CreateTexture(nil, "OVERLAY")
    thumb:SetSize(10, 14)
    thumb:SetColorTexture(0.25, 0.52, 0.95, 1)
    slider:SetThumbTexture(thumb)
    container.thumb = thumb

    -- 微调按钮 (减少)
    local minusBtn = CreateFrame("Button", nil, container)
    minusBtn:SetSize(16, 16)
    minusBtn:SetPoint("RIGHT", track, "LEFT", -4, 0)
    local minusIcon = minusBtn:CreateTexture(nil, "ARTWORK")
    minusIcon:SetAllPoints()
    minusIcon:SetTexture("Interface\\AddOns\\VFlow\\Assets\\Icons\\chevron_right")
    minusIcon:SetTexCoord(1, 0, 0, 1)
    minusIcon:SetVertexColor(0.7, 0.7, 0.7, 1)
    minusBtn.icon = minusIcon
    minusBtn:SetScript("OnEnter", function(self) self.icon:SetVertexColor(1, 1, 1, 1) end)
    minusBtn:SetScript("OnLeave", function(self) self.icon:SetVertexColor(0.7, 0.7, 0.7, 1) end)
    container.minusBtn = minusBtn

    -- 微调按钮 (增加)
    local plusBtn = CreateFrame("Button", nil, container)
    plusBtn:SetSize(16, 16)
    plusBtn:SetPoint("LEFT", track, "RIGHT", 4, 0)
    local plusIcon = plusBtn:CreateTexture(nil, "ARTWORK")
    plusIcon:SetAllPoints()
    plusIcon:SetTexture("Interface\\AddOns\\VFlow\\Assets\\Icons\\chevron_right")
    plusIcon:SetVertexColor(0.7, 0.7, 0.7, 1)
    plusBtn.icon = plusIcon
    plusBtn:SetScript("OnEnter", function(self) self.icon:SetVertexColor(1, 1, 1, 1) end)
    plusBtn:SetScript("OnLeave", function(self) self.icon:SetVertexColor(0.7, 0.7, 0.7, 1) end)
    container.plusBtn = plusBtn

    local minText = container:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    minText:SetPoint("TOPLEFT", track, "BOTTOMLEFT", 0, -4)
    minText:SetTextColor(0.5, 0.5, 0.5, 1)
    container.minText = minText

    local maxText = container:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    maxText:SetPoint("TOPRIGHT", track, "BOTTOMRIGHT", 0, -4)
    maxText:SetTextColor(0.5, 0.5, 0.5, 1)
    container.maxText = maxText

    -- 兼容旧版 valueText 引用
    container.valueText = editBox
end)

-- =========================================================
-- 4. 复选框
-- =========================================================

Pool.init("VFlowCheckbox", "Frame", nil, function(container)
    container:SetHeight(40)

    local cb = CreateFrame("CheckButton", nil, container, "BackdropTemplate")
    cb:SetSize(20, 20)
    cb:SetPoint("LEFT", 0, 0)
    applyBackdrop(cb)

    local fill = cb:CreateTexture(nil, "ARTWORK")
    fill:SetColorTexture(0.25, 0.52, 0.95, 1)
    fill:SetPoint("TOPLEFT", 3, -3)
    fill:SetPoint("BOTTOMRIGHT", -3, 3)
    fill:Hide()
    container.fill = fill
    container.checkbox = cb

    local label = container:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    label:SetPoint("LEFT", cb, "RIGHT", 8, 0)
    container.label = label

    function container:SetChecked(checked)
        self.checkbox:SetChecked(checked)
        if checked then self.fill:Show() else self.fill:Hide() end
    end

    function container:GetChecked()
        return self.checkbox:GetChecked()
    end
end)

-- =========================================================
-- 5. 输入框
-- =========================================================

Pool.init("VFlowInput", "Frame", nil, function(outerContainer)
    outerContainer:SetHeight(44)

    local label = outerContainer:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    label:SetPoint("TOPLEFT", 0, 0)
    outerContainer.label = label

    local editBox = CreateFrame("EditBox", nil, outerContainer, "BackdropTemplate")
    editBox:SetPoint("TOPLEFT", 0, -15)
    editBox:SetPoint("TOPRIGHT", 0, -15)
    editBox:SetHeight(24)
    applyBackdrop(editBox, 0.1, 0.1, 0.1, 0.8)
    editBox:SetFontObject("GameFontHighlightSmall")
    editBox:SetTextInsets(5, 5, 0, 0)
    editBox:SetAutoFocus(false)
    outerContainer.editBox = editBox

    function outerContainer:SetText(text)
        self.editBox:SetText(text or "")
    end

    function outerContainer:GetText()
        return self.editBox:GetText()
    end
end)

-- =========================================================
-- 6. 下拉框
-- =========================================================

Pool.init("VFlowDropdown", "Frame", nil, function(outerContainer)
    outerContainer:SetHeight(50)

    local label = outerContainer:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    label:SetPoint("TOPLEFT", 0, 0)
    outerContainer.label = label

    local btn = CreateFrame("Button", nil, outerContainer, "BackdropTemplate")
    btn:SetPoint("TOPLEFT", 0, -16)
    btn:SetPoint("TOPRIGHT", 0, -16)
    btn:SetHeight(24)
    applyBackdrop(btn)
    outerContainer.dropdown = btn

    local text = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    text:SetPoint("LEFT", 8, 0)
    text:SetPoint("RIGHT", -20, 0)
    text:SetJustifyH("LEFT")
    btn.text = text

    local arrow = btn:CreateTexture(nil, "OVERLAY")
    arrow:SetPoint("RIGHT", -8, 0)
    arrow:SetSize(12, 12)
    arrow:SetTexture("Interface\\AddOns\\VFlow\\Assets\\Icons\\expand_more")
    arrow:SetVertexColor(0.6, 0.6, 0.6, 1)
    btn.arrow = arrow

    local menu = CreateFrame("Frame", nil, btn, "BackdropTemplate")
    menu:SetPoint("TOPLEFT", btn, "BOTTOMLEFT", 0, -2)
    menu:SetPoint("TOPRIGHT", btn, "BOTTOMRIGHT", 0, -2)
    menu:SetFrameStrata("FULLSCREEN_DIALOG")
    menu:SetClampedToScreen(true)
    applyBackdrop(menu, 0.12, 0.12, 0.12, 0.98)
    menu:Hide()
    outerContainer.menu = menu

    function btn:SetText(txt)
        self.text:SetText(txt)
    end
end)

-- =========================================================
-- 7. 颜色选择器
-- =========================================================

Pool.init("VFlowColorPicker", "Frame", nil, function(container)
    container:SetHeight(50)

    local label = container:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    label:SetPoint("TOPLEFT", 0, 0)
    container.label = label

    local btn = CreateFrame("Button", nil, container, "BackdropTemplate")
    btn:SetPoint("TOPLEFT", 0, -16)
    btn:SetPoint("TOPRIGHT", 0, -16)
    btn:SetHeight(24)
    applyBackdrop(btn)
    container.button = btn

    local hexText = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hexText:SetPoint("LEFT", 8, 0)
    hexText:SetPoint("RIGHT", -42, 0)
    hexText:SetJustifyH("LEFT")
    container.hexText = hexText

    local swatch = btn:CreateTexture(nil, "OVERLAY")
    swatch:SetSize(28, 14)
    swatch:SetPoint("RIGHT", -8, 0)
    swatch:SetColorTexture(1, 1, 1, 1)
    container.swatch = swatch
end)

-- =========================================================
-- 8. 材质/字体选择器（带搜索和滚动）
-- =========================================================

Pool.init("VFlowResourcePicker", "Frame", nil, function(outerContainer)
    outerContainer:SetHeight(50)

    local label = outerContainer:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    label:SetPoint("TOPLEFT", 0, 0)
    outerContainer.label = label

    local btn = CreateFrame("Button", nil, outerContainer, "BackdropTemplate")
    btn:SetPoint("TOPLEFT", 0, -16)
    btn:SetPoint("TOPRIGHT", 0, -16)
    btn:SetHeight(24)
    applyBackdrop(btn)
    outerContainer.dropdown = btn

    local preview = btn:CreateTexture(nil, "ARTWORK")
    preview:SetPoint("LEFT", 4, 0)
    preview:SetSize(80, 16)
    preview:Hide()
    outerContainer.preview = preview

    local text = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    text:SetPoint("LEFT", 8, 0)
    text:SetPoint("RIGHT", -20, 0)
    text:SetJustifyH("LEFT")
    btn.text = text

    local arrow = btn:CreateTexture(nil, "OVERLAY")
    arrow:SetPoint("RIGHT", -8, 0)
    arrow:SetSize(12, 12)
    arrow:SetTexture("Interface\\AddOns\\VFlow\\Assets\\Icons\\expand_more")
    arrow:SetVertexColor(0.6, 0.6, 0.6, 1)
    btn.arrow = arrow

    local menu = CreateFrame("Frame", nil, btn, "BackdropTemplate")
    menu:SetPoint("TOPLEFT", btn, "BOTTOMLEFT", 0, -2)
    menu:SetPoint("TOPRIGHT", btn, "BOTTOMRIGHT", 0, -2)
    menu:SetFrameStrata("FULLSCREEN_DIALOG")
    menu:SetClampedToScreen(true)
    applyBackdrop(menu, 0.12, 0.12, 0.12, 0.98)
    menu:Hide()
    outerContainer.menu = menu

    local searchBox = CreateFrame("EditBox", nil, menu, "BackdropTemplate")
    searchBox:SetPoint("TOPLEFT", 4, -4)
    searchBox:SetPoint("TOPRIGHT", -4, -4)
    searchBox:SetHeight(22)
    applyBackdrop(searchBox, 0.1, 0.1, 0.1, 0.8)
    searchBox:SetFontObject("GameFontHighlightSmall")
    searchBox:SetTextInsets(4, 4, 0, 0)
    searchBox:SetAutoFocus(false)
    outerContainer.searchBox = searchBox

    local scrollFrame = CreateFrame("ScrollFrame", nil, menu, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", 2, -30)
    scrollFrame:SetPoint("BOTTOMRIGHT", -22, 2)
    outerContainer.scrollFrame = scrollFrame

    local scrollChild = CreateFrame("Frame", nil, scrollFrame)
    scrollChild:SetWidth(200)
    scrollChild:SetHeight(10)
    scrollFrame:SetScrollChild(scrollChild)
    outerContainer.scrollChild = scrollChild

    -- 美化滚动条
    if scrollFrame.ScrollBar then
        local scrollBar = scrollFrame.ScrollBar
        local thumbTex = scrollBar:GetThumbTexture()
        if thumbTex then
            thumbTex:SetTexture("Interface\\Buttons\\WHITE8x8")
            thumbTex:SetVertexColor(0.25, 0.52, 0.95, 0.95)
            thumbTex:SetSize(8, 32)
        end
        if not scrollBar._vfTrack then
            local trackBg = scrollBar:CreateTexture(nil, "BACKGROUND")
            trackBg:SetAllPoints()
            trackBg:SetColorTexture(0.08, 0.08, 0.08, 0.85)
            scrollBar._vfTrack = trackBg
        end
    end
end)

-- =========================================================
-- 9. 文本（FontString 包装）
-- =========================================================

Pool.init("VFlowFontString", "Frame", nil, function(container)
    container:SetSize(1, 1)

    local fs = container:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    fs:SetAllPoints()
    container.fontString = fs

    function container:SetText(text)
        self.fontString:SetText(text or "")
    end

    function container:SetFontObject(font)
        self.fontString:SetFontObject(font)
    end

    function container:SetTextColor(r, g, b, a)
        self.fontString:SetTextColor(r, g, b, a)
    end

    function container:SetJustifyH(justify)
        self.fontString:SetJustifyH(justify)
    end
end)

-- =========================================================
-- 10. 分隔线
-- =========================================================

Pool.init("VFlowSeparator", "Frame", nil, function(container)
    container:SetHeight(9)

    local line = container:CreateTexture(nil, "ARTWORK")
    line:SetPoint("TOPLEFT", 0, -4)
    line:SetPoint("TOPRIGHT", 0, -4)
    line:SetHeight(1)
    line:SetColorTexture(0.25, 0.25, 0.25, 1)
    container.line = line
end)

-- =========================================================
-- 11. 间距
-- =========================================================

Pool.init("VFlowSpacer", "Frame", nil, function(container)
    container:SetHeight(10)
end)

-- =========================================================
-- 12. 图标按钮
-- =========================================================

Pool.init("VFlowIconButton", "Button", nil, function(btn)
    btn:SetSize(40, 40)

    local icon = btn:CreateTexture(nil, "ARTWORK")
    icon:SetPoint("TOPLEFT", 2, -2)
    icon:SetPoint("BOTTOMRIGHT", -2, 2)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    btn.icon = icon

    applyBackdrop(btn, 0.15, 0.15, 0.15, 0.8)

    local highlight = btn:CreateTexture(nil, "OVERLAY")
    highlight:SetAllPoints()
    highlight:SetColorTexture(1, 1, 1, 0.2)
    highlight:Hide()
    btn.highlight = highlight
end)

-- =========================================================
-- 13. 对话框
-- =========================================================

Pool.init("VFlowDialog", "Frame", nil, function(dialog)
    dialog:SetAllPoints(UIParent)
    dialog:SetFrameStrata("FULLSCREEN_DIALOG")
    dialog:SetFrameLevel(300)

    local blocker = CreateFrame("Button", nil, dialog)
    blocker:SetAllPoints(dialog)
    dialog.blocker = blocker

    local dim = dialog:CreateTexture(nil, "BACKGROUND")
    dim:SetAllPoints(dialog)
    dim:SetColorTexture(0, 0, 0, 0.45)
    dialog.dim = dim

    local panel = CreateFrame("Frame", nil, dialog, "BackdropTemplate")
    panel:SetSize(420, 200)
    panel:SetPoint("CENTER", 0, 40)
    applyBackdrop(panel, 0.12, 0.12, 0.12, 0.96)
    dialog.panel = panel

    local titleText = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    titleText:SetPoint("TOPLEFT", 14, -12)
    titleText:SetPoint("TOPRIGHT", -44, -12)
    titleText:SetJustifyH("LEFT")
    titleText:SetTextColor(0.9, 0.9, 0.9, 1)
    dialog.titleText = titleText

    local closeButton = CreateFrame("Button", nil, panel, "BackdropTemplate")
    closeButton:SetSize(22, 22)
    closeButton:SetPoint("TOPRIGHT", -10, -10)
    applyBackdrop(closeButton)
    local closeIcon = closeButton:CreateTexture(nil, "OVERLAY")
    closeIcon:SetAllPoints()
    closeIcon:SetTexture("Interface\\AddOns\\VFlow\\Assets\\Icons\\close")
    closeIcon:SetVertexColor(0.85, 0.85, 0.85, 1)
    dialog.closeButton = closeButton

    local messageText = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    messageText:SetPoint("TOPLEFT", 14, -50)
    messageText:SetPoint("TOPRIGHT", -14, -50)
    messageText:SetJustifyH("LEFT")
    messageText:SetJustifyV("TOP")
    messageText:SetSpacing(2)
    messageText:SetTextColor(0.74, 0.74, 0.74, 1)
    dialog.messageText = messageText

    local confirmButton = CreateFrame("Button", nil, panel, "BackdropTemplate")
    confirmButton:SetSize(96, 28)
    confirmButton:SetPoint("BOTTOMRIGHT", -14, 14)
    applyBackdrop(confirmButton, 0.25, 0.52, 0.95, 0.22, 0.25, 0.52, 0.95, 0.9)
    dialog.confirmButton = confirmButton

    local confirmText = confirmButton:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    confirmText:SetPoint("CENTER")
    confirmText:SetTextColor(1, 1, 1, 1)
    dialog.confirmText = confirmText

    local cancelButton = CreateFrame("Button", nil, panel, "BackdropTemplate")
    cancelButton:SetSize(96, 28)
    cancelButton:SetPoint("RIGHT", confirmButton, "LEFT", -8, 0)
    applyBackdrop(cancelButton)
    dialog.cancelButton = cancelButton

    local cancelText = cancelButton:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    cancelText:SetPoint("CENTER")
    cancelText:SetTextColor(0.9, 0.9, 0.9, 1)
    dialog.cancelText = cancelText
end)

-- =========================================================
-- 14. 可交互文本（富文本链接）
-- =========================================================

Pool.init("VFlowInteractiveText", "Frame", nil, function(container)
    container:SetHeight(24)
    container.segments = {}
end)
