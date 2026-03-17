local VFlow = _G.VFlow
if not VFlow then return end

local TARGETS = {
    EssentialCooldownViewer = { menuKey = "skill_important" },
    UtilityCooldownViewer = { menuKey = "skill_efficiency" },
    BuffIconCooldownViewer = { menuKey = "buff_monitor" },
    BuffBarCooldownViewer = { menuKey = "buff_bar" },
}

local function ResolveButtonTemplate()
    if _G.EditModeSystemSettingsDialogExtraButtonTemplate then
        return "EditModeSystemSettingsDialogExtraButtonTemplate"
    end
    if _G.EditModeSystemSettingsDialogButtonTemplate then
        return "EditModeSystemSettingsDialogButtonTemplate"
    end
    return "UIPanelButtonTemplate"
end

local function FindSiblingButton(buttonParent)
    if not buttonParent then return nil end
    for _, child in ipairs({ buttonParent:GetChildren() }) do
        if child and child.IsObjectType and child:IsObjectType("Button") then
            return child
        end
    end
    return nil
end

local function GetElvUISkinsModule()
    local elvui = _G.ElvUI
    local E = elvui and elvui[1]
    if not E or not E.initialized or not E.GetModule then
        return nil
    end
    local S = E:GetModule("Skins", true)
    if not S or not S.HandleButton then
        return nil
    end
    return S
end

local function ApplyExternalSkin(button)
    if not button or button._vfElvUISkinned then return end
    local skins = GetElvUISkinsModule()
    if not skins then return end
    local ok = pcall(skins.HandleButton, skins, button)
    if ok then
        button._vfElvUISkinned = true
    end
end

local function ExpandButtonWidth(button, buttonParent)
    if not button or not buttonParent then return end
    local parentWidth = buttonParent.GetWidth and buttonParent:GetWidth() or 0
    if parentWidth and parentWidth > 0 then
        button:SetWidth(math.max(parentWidth - 2, 80))
    end
end

local function ApplyButtonEmphasis(button)
    if not button then return end
    button:SetText("|TInterface\\FriendsFrame\\InformationIcon:14:14:0:0|t 打开VFlow进行详细配置")
    local fs = button.GetFontString and button:GetFontString()
    if fs then
        fs:SetTextColor(1, 0.82, 0.2, 1)
        fs:SetShadowColor(0, 0, 0, 0.9)
        fs:SetShadowOffset(1, -1)
    end
    if not button._vfEmphasisHooks then
        button:HookScript("OnEnter", function(self)
            local fontString = self.GetFontString and self:GetFontString()
            if fontString then
                fontString:SetTextColor(1, 0.92, 0.35, 1)
            end
        end)
        button:HookScript("OnLeave", function(self)
            local fontString = self.GetFontString and self:GetFontString()
            if fontString then
                fontString:SetTextColor(1, 0.82, 0.2, 1)
            end
        end)
        button._vfEmphasisHooks = true
    end
end

local function OpenVFlow(menuKey)
    if VFlow.MainUI and VFlow.MainUI.openMenu then
        VFlow.MainUI.openMenu(menuKey)
    elseif VFlow.MainUI and VFlow.MainUI.show then
        VFlow.MainUI.show()
    end

    if EditModeSystemSettingsDialog and EditModeSystemSettingsDialog:IsShown() then
        HideUIPanel(EditModeSystemSettingsDialog)
    end
end

local function UpdateDialogButton(dialog, systemFrame)
    if not dialog then return end

    local frameName = systemFrame and systemFrame.GetName and systemFrame:GetName()
    local target = frameName and TARGETS[frameName]
    local button = dialog._vfOpenMainUIButton
    local buttonParent = dialog.Buttons or dialog

    if not target then
        if button then
            button:Hide()
        end
        return
    end

    if not button then
        local template = ResolveButtonTemplate()
        button = CreateFrame("Button", nil, buttonParent, template)
        button:SetSize(240, 24)
        local sibling = FindSiblingButton(buttonParent)
        if sibling and sibling ~= button then
            local width, height = sibling:GetSize()
            if width and width > 0 then
                button:SetWidth(width)
            end
            if height and height > 0 then
                button:SetHeight(height)
            end
        end
        ApplyButtonEmphasis(button)
        dialog._vfOpenMainUIButton = button
    end

    button.menuKey = target.menuKey
    if buttonParent ~= button:GetParent() then
        button:SetParent(buttonParent)
    end
    if buttonParent.AddLayoutChildren then
        if not button._vfAddedToLayout then
            button.layoutIndex = 9999
            buttonParent:AddLayoutChildren(button)
            button._vfAddedToLayout = true
        end
        ExpandButtonWidth(button, buttonParent)
    else
        button:ClearAllPoints()
        button:SetPoint("BOTTOMLEFT", dialog, "BOTTOMLEFT", 12, 12)
        button:SetPoint("BOTTOMRIGHT", dialog, "BOTTOMRIGHT", -12, 12)
    end
    button:SetScript("OnClick", function(self)
        OpenVFlow(self.menuKey)
    end)
    ApplyExternalSkin(button)
    ApplyButtonEmphasis(button)
    button:Show()
    C_Timer.After(0, function()
        if button and button:IsShown() then
            ExpandButtonWidth(button, buttonParent)
        end
    end)
end

local TARGET_FRAME_NAMES = {}
for name in pairs(TARGETS) do
    TARGET_FRAME_NAMES[name] = true
end

local function IsCheckboxSetting(frame)
    if frame.Button and frame.Button:IsObjectType("CheckButton") then return true end
    if frame:IsObjectType("CheckButton") then return true end
    for _, child in ipairs({ frame:GetChildren() }) do
        if child:IsObjectType("CheckButton") then return true end
    end
    return false
end

local function HideNonCheckboxSettings(dialog, systemFrame)
    local frameName = systemFrame and systemFrame.GetName and systemFrame:GetName()
    if not TARGET_FRAME_NAMES[frameName] then return end
    local container = dialog.Settings
    if not container then return end
    for _, child in ipairs({ container:GetChildren() }) do
        if child:IsShown() and not IsCheckboxSetting(child) then
            child:Hide()
        end
    end
    if container.Layout then container:Layout() end
    if dialog.Layout then dialog:Layout() end
end

local function HookEditModeDialog()
    local dialog = _G.EditModeSystemSettingsDialog
    if not dialog or dialog._vfOpenMainUIHooked then
        return
    end

    if dialog.UpdateDialog then
        hooksecurefunc(dialog, "UpdateDialog", function(self, systemFrame)
            UpdateDialogButton(self, systemFrame)
            HideNonCheckboxSettings(self, systemFrame)
        end)
    end

    dialog:HookScript("OnHide", function(self)
        if self._vfOpenMainUIButton then
            self._vfOpenMainUIButton:Hide()
        end
    end)

    dialog._vfOpenMainUIHooked = true
end

if EventUtil and EventUtil.ContinueOnAddOnLoaded then
    EventUtil.ContinueOnAddOnLoaded("Blizzard_EditMode", HookEditModeDialog)
end

C_Timer.After(0, HookEditModeDialog)
