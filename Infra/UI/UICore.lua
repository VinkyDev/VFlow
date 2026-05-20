-- =========================================================
-- VFlow UI Core - 命名空间、样式定义、基础组件工厂
-- =========================================================

local VFlow = _G.VFlow

local UI = {}
VFlow.UI = UI

local Pool = VFlow.Pool
local L = VFlow.L

-- =========================================================
-- 样式定义 (Modern Flat Style)
-- =========================================================

UI.style = {
    colors = {
        primary = { 0.25, 0.52, 0.95, 1 },
        background = { 0.1, 0.1, 0.1, 0.9 },
        panel = { 0.14, 0.14, 0.14, 1 },
        element = { 0.18, 0.18, 0.18, 1 },
        input = { 0.1, 0.1, 0.1, 0.8 },
        border = { 0.3, 0.3, 0.3, 1 },
        hover = { 0.24, 0.24, 0.24, 1 },
        text = { 0.9, 0.9, 0.9, 1 },
        textDim = { 0.6, 0.6, 0.6, 1 },
        success = { 0.2, 0.8, 0.2, 1 },
        warning = { 1, 0.8, 0.2, 1 },
        error = { 1, 0.2, 0.2, 1 },
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

local function GetThemeColor()
    return UI.style.colors.primary
end

-- =========================================================
-- 文本组件
-- =========================================================

local function createPooledText(parent, text, fontObject, color)
    local container = Pool.acquire("VFlowFontString", parent)
    container._vf_poolType = "VFlowFontString"

    local fs = container.fontString
    fs:SetFontObject(fontObject)
    fs:SetText(text or "")
    fs:SetJustifyH("LEFT")
    fs:SetJustifyV("TOP")
    fs:SetWordWrap(true)
    fs:ClearAllPoints()
    fs:SetPoint("TOPLEFT", container, "TOPLEFT", 0, 0)
    fs:SetPoint("TOPRIGHT", container, "TOPRIGHT", 0, 0)
    fs:SetTextColor(color[1], color[2], color[3], color[4] or 1)

    container._vf_text = text or ""
    container.RefreshVisuals = function(self)
        self.fontString:SetText(self._vf_text or "")
        local height = self.fontString:GetStringHeight() or 0
        self:SetHeight(math.max(height, 1))
    end
    container:RefreshVisuals()

    return container
end

function UI.title(parent, text)
    local c = UI.style.colors.primary
    return createPooledText(parent, text, UI.style.fonts.title, c)
end

function UI.subtitle(parent, text)
    local c = UI.style.colors.text
    return createPooledText(parent, text, UI.style.fonts.subtitle, c)
end

function UI.description(parent, text)
    local c = UI.style.colors.textDim
    return createPooledText(parent, text, UI.style.fonts.default, c)
end

-- =========================================================
-- 输入组件
-- =========================================================

function UI.button(parent, text, onClick)
    local btn = Pool.acquire("VFlowButton", parent)
    btn._vf_poolType = "VFlowButton"

    btn:SetText(text or "")

    local ec = UI.style.colors.element
    btn:SetBackdropColor(ec[1], ec[2], ec[3], ec[4])
    local bc = UI.style.colors.border
    btn:SetBackdropBorderColor(bc[1], bc[2], bc[3], bc[4])

    local font = btn:GetFontString()
    if font then
        local tc = UI.style.colors.text
        font:SetTextColor(tc[1], tc[2], tc[3], tc[4])
    end

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

function UI.checkbox(parent, label, value, onChange)
    local container = Pool.acquire("VFlowCheckbox", parent)
    container._vf_poolType = "VFlowCheckbox"

    container.label:SetText(label or "")
    local c = UI.style.colors.text
    container.label:SetTextColor(c[1], c[2], c[3], c[4])

    container.checkbox:SetChecked(value)

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

function UI.slider(parent, label, min, max, value, step, onChange)
    local container = Pool.acquire("VFlowSlider", parent)
    container._vf_poolType = "VFlowSlider"
    step = step or 1
    container.fill:SetColorTexture(0.2, 0.6, 1, 0.8)
    container.fill:Show()
    container.thumb:SetColorTexture(0.2, 0.6, 1, 1)

    container.slider:SetMinMaxValues(min, max)
    container.slider:SetValue(value)
    container.slider:SetValueStep(step)

    local ic = UI.style.colors.input
    container.editBox:SetBackdropColor(ic[1], ic[2], ic[3], ic[4])
    local bc = UI.style.colors.border
    container.editBox:SetBackdropBorderColor(bc[1], bc[2], bc[3], bc[4])

    if label then
        container.label:SetText(label)
        local c = UI.style.colors.text
        container.label:SetTextColor(c[1], c[2], c[3], c[4])
    end

    local function formatValue(val)
        if step >= 1 and math.floor(step) == step then
            return string.format("%d", val)
        elseif step < 0.1 or (step * 10) % 1 > 0.001 then
            return string.format("%.2f", val)
        else
            return string.format("%.1f", val)
        end
    end

    container.minText:SetText(formatValue(min))
    container.maxText:SetText(formatValue(max))

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

    local isDragging = false
    container.slider:SetScript("OnMouseDown", function(self)
        isDragging = true
    end)

    container.slider:SetScript("OnMouseUp", function(self)
        isDragging = false
        local val = math.floor(self:GetValue() / step + 0.5) * step
        updateVisuals(val)
        if onChange then onChange(val) end
    end)

    container.slider:SetScript("OnValueChanged", function(self, val)
        val = math.floor(val / step + 0.5) * step
        updateVisuals(val)
        if not isDragging and onChange then
            onChange(val)
        end
    end)

    if container.minusBtn then
        container.minusBtn:SetScript("OnClick", function()
            local current = container.slider:GetValue()
            local newVal = math.max(min, current - step)
            container.slider:SetValue(newVal)
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

    container.editBox:SetScript("OnEnterPressed", function(self)
        local val = tonumber(self:GetText())
        if val then
            val = math.max(min, math.min(max, val))
            container.slider:SetValue(val)
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

function UI.input(parent, label, value, onChange, options)
    local outerContainer = Pool.acquire("VFlowInput", parent)
    outerContainer._vf_poolType = "VFlowInput"

    options = options or {}

    outerContainer.label:ClearAllPoints()
    outerContainer.editBox:ClearAllPoints()

    if options.labelOnLeft then
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
        outerContainer:SetHeight(44)
        outerContainer.label:SetPoint("TOPLEFT", 0, 0)

        outerContainer.editBox:SetPoint("TOPLEFT", 0, -15)
        outerContainer.editBox:SetPoint("TOPRIGHT", 0, -15)
        outerContainer.editBox:SetHeight(24)
    end

    if label then
        outerContainer.label:SetText(label)
        outerContainer.label:Show()
        local c = UI.style.colors.text
        outerContainer.label:SetTextColor(c[1], c[2], c[3], c[4])
    else
        outerContainer.label:Hide()
    end

    outerContainer.editBox:SetText(value or "")

    local ic = UI.style.colors.input
    outerContainer.editBox:SetBackdropColor(ic[1], ic[2], ic[3], ic[4])
    local bc = UI.style.colors.border
    outerContainer.editBox:SetBackdropBorderColor(bc[1], bc[2], bc[3], bc[4])

    outerContainer.editBox:SetScript("OnEditFocusGained", function(self)
        local ac = UI.style.colors.primary
        self:SetBackdropBorderColor(ac[1], ac[2], ac[3], ac[4])
    end)

    outerContainer.editBox:SetScript("OnEditFocusLost", function(self)
        local bc = UI.style.colors.border
        self:SetBackdropBorderColor(bc[1], bc[2], bc[3], bc[4])
        if onChange then onChange(self:GetText()) end
    end)

    outerContainer.editBox:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
    end)

    outerContainer.editBox:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
    end)

    return outerContainer
end

function UI.dropdown(parent, label, items, value, onChange, options)
    local outerContainer = Pool.acquire("VFlowDropdown", parent)
    outerContainer._vf_poolType = "VFlowDropdown"

    options = options or {}

    local btn = outerContainer.dropdown
    local menu = outerContainer.menu

    outerContainer.label:ClearAllPoints()
    btn:ClearAllPoints()

    if options.labelOnLeft then
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
        outerContainer:SetHeight(50)
        outerContainer.label:SetPoint("TOPLEFT", 0, 0)

        btn:SetPoint("TOPLEFT", 0, -16)
        btn:SetPoint("TOPRIGHT", 0, -16)
        btn:SetHeight(24)
    end

    if label then
        outerContainer.label:SetText(label)
        outerContainer.label:Show()
        local c = UI.style.colors.text
        outerContainer.label:SetTextColor(c[1], c[2], c[3], c[4])
    else
        outerContainer.label:Hide()
    end

    btn._items = items
    btn._value = value
    btn._onChange = onChange

    local function getDisplayText(val)
        for _, item in ipairs(items) do
            if type(item) == "table" then
                if item[2] == val then return item[1] end
            else
                if item == val then return item end
            end
        end
        return L["Please select..."]
    end

    btn.text:SetText(getDisplayText(value))

    local function buildMenu()
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

-- =========================================================
-- 布局组件
-- =========================================================

function UI.container(parent, width, height)
    local container = Pool.acquire("VFlowContainer", parent)
    container._vf_poolType = "VFlowContainer"

    container:SetSize(width or 100, height or 100)
    CreatePanelBackdrop(container)

    return container
end

function UI.separator(parent)
    local container = Pool.acquire("VFlowSeparator", parent)
    container._vf_poolType = "VFlowSeparator"

    local c = UI.style.colors.border
    container.line:SetColorTexture(c[1], c[2], c[3], c[4])

    return container
end

function UI.spacer(parent, height)
    local spacer = Pool.acquire("VFlowSpacer", parent)
    spacer._vf_poolType = "VFlowSpacer"

    spacer:SetHeight(height or 10)

    return spacer
end

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

--- 富文本链接组件
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

    local function acquireSegmentButton()
        container._segmentButtonPool = container._segmentButtonPool or {}
        local btn = table.remove(container._segmentButtonPool)
        if btn then
            btn:SetParent(container)
            return btn, btn._vfText, btn._vfUnderline
        end

        btn = CreateFrame("Button", nil, container)
        btn:SetHeight(lineHeight)

        local fs = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        fs:SetJustifyH("LEFT")
        fs:SetJustifyV("TOP")
        fs:SetPoint("TOPLEFT", btn, "TOPLEFT", 1, 0)
        fs:SetPoint("TOPRIGHT", btn, "TOPRIGHT", -1, 0)
        btn._vfText = fs

        local underline = btn:CreateTexture(nil, "BACKGROUND")
        underline:SetPoint("BOTTOMLEFT",  fs, "BOTTOMLEFT",  0, -1)
        underline:SetPoint("BOTTOMRIGHT", fs, "BOTTOMRIGHT", 0, -1)
        underline:SetHeight(1)
        btn._vfUnderline = underline

        return btn, fs, underline
    end

    local function acquireSegmentText()
        container._segmentTextPool = container._segmentTextPool or {}
        local fs = table.remove(container._segmentTextPool)
        if fs then
            return fs
        end
        fs = container:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        fs:SetJustifyH("LEFT")
        fs:SetJustifyV("TOP")
        return fs
    end

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
            local btn, fs, underline = acquireSegmentButton()
            btn:SetHeight(lineHeight)
            fs:SetText(segment.text)
            fs:SetTextColor(linkColor[1], linkColor[2], linkColor[3], linkColor[4])

            local w = fs:GetStringWidth() + 2
            btn:SetWidth(w)

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
                local fs = acquireSegmentText()
                fs:SetText(token)
                fs:SetTextColor(textColor[1], textColor[2], textColor[3], textColor[4])
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

function UI.release(frame)
    if not frame then return end

    local poolType = frame._vf_poolType
    if poolType then
        Pool.release(poolType, frame)
    else
        frame:Hide()
        frame:ClearAllPoints()
        frame:SetParent(nil)
    end
end

function UI.releaseButton(frame)
    UI.release(frame)
end

function UI.releaseCheckbox(frame)
    UI.release(frame)
end

function UI.releaseSlider(frame)
    UI.release(frame)
end

function UI.releaseInput(frame)
    UI.release(frame)
end

function UI.releaseDropdown(frame)
    UI.release(frame)
end

function UI.releaseContainer(frame)
    UI.release(frame)
end

function UI.releaseSeparator(frame)
    UI.release(frame)
end

function UI.releaseSpacer(frame)
    UI.release(frame)
end

function UI.releaseIconButton(frame)
    UI.release(frame)
end

function UI.releaseDialog(frame)
    UI.release(frame)
end

function UI.releaseInteractiveText(frame)
    UI.release(frame)
end
