-- =========================================================
-- MainUIModuleControl — 模块启停控制页
-- =========================================================

local VFlow = _G.VFlow
if not VFlow then return end
local L = VFlow.L

VFlow._mainUI = VFlow._mainUI or {}
local Shared = VFlow._mainUI

-- =========================================================
-- SECTION 1: 局部工具函数
-- =========================================================

local UI = VFlow.UI
local uiStyle = UI and UI.style or {}
local colors = uiStyle.colors or {}

local function getColor(name, fallback)
    return colors[name] or fallback
end

local function applyFlatBackdrop(frame, bgName, borderName, alpha)
    if not frame or not frame.SetBackdrop then return end
    frame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    local bg = getColor(bgName, { 0.12, 0.12, 0.12, 1 })
    local border = getColor(borderName, { 0.25, 0.25, 0.25, 1 })
    frame:SetBackdropColor(bg[1], bg[2], bg[3], alpha or bg[4])
    frame:SetBackdropBorderColor(border[1], border[2], border[3], border[4])
end

-- =========================================================
-- SECTION 2: 辅助函数
-- =========================================================

local function formatControlNames(controlKeys)
    local names = {}
    for _, controlKey in ipairs(controlKeys or {}) do
        local info = VFlow.getModuleControlInfo and VFlow.getModuleControlInfo(controlKey)
        names[#names + 1] = info and info.label or tostring(controlKey)
    end
    return table.concat(names, "\227\128\129") -- 、
end

local function collectModuleControls()
    local items = {}
    local catalog = VFlow.getModuleControlCatalog and VFlow.getModuleControlCatalog() or {}
    for _, info in ipairs(catalog) do
        items[#items + 1] = info
    end
    table.sort(items, function(a, b)
        return (a.order or 0) < (b.order or 0)
    end)
    return items
end

local function getUnavailableSavedDependencies(controlInfo)
    local missing = {}
    for _, depKey in ipairs(controlInfo and controlInfo.dependencies or {}) do
        local depState = VFlow.getModuleControlSavedState and VFlow.getModuleControlSavedState(depKey) or nil
        if not depState or not depState.requested then
            missing[#missing + 1] = depKey
        end
    end
    return missing
end

-- =========================================================
-- SECTION 3: 渲染模块控制页
-- =========================================================

local function renderModuleControlContent(container)
    if not VFlow.Grid or not VFlow.Grid.render then
        return
    end

    local controls = collectModuleControls()
    local layout = {
        { type = "title", text = L["Module Controls"], cols = 24 },
        { type = "separator", cols = 24 },
        {
            type = "description",
            text = function()
                if VFlow.hasModuleStateChangesPendingReload and VFlow.hasModuleStateChangesPendingReload() then
                    return L["Pending module changes detected. Click below or use /reload to apply."]
                end
                return L["No pending module changes."]
            end,
            cols = 24
        },
        {
            type = "button",
            text = L["Reload UI Now"],
            cols = 8,
            onClick = function()
                ReloadUI()
            end
        },
        { type = "spacer", height = 10, cols = 24 },
    }

    layout[#layout + 1] = {
        type = "customRender",
        cols = 24,
        height = 132,
        render = function(parent)
            local columns = 3
            local buttonWidth = 180
            local buttonHeight = 32
            local gapX = 10
            local gapY = 12
            local startX = 8
            local startY = -4

            for index, info in ipairs(controls) do
                local runtimeState = VFlow.getModuleControlRuntimeState and VFlow.getModuleControlRuntimeState(info.controlKey) or nil
                local savedState = VFlow.getModuleControlSavedState and VFlow.getModuleControlSavedState(info.controlKey) or nil
                local requested = savedState and savedState.requested == true
                local effectiveNext = savedState and savedState.effective == true
                local unavailableDependencies = getUnavailableSavedDependencies(info)
                local lockedByDependency = (not requested) and unavailableDependencies[1] ~= nil
                local row = math.floor((index - 1) / columns)
                local col = (index - 1) % columns

                local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
                btn:SetSize(buttonWidth, buttonHeight)
                btn:SetPoint("TOPLEFT", startX + col * (buttonWidth + gapX), startY - row * (buttonHeight + gapY))
                applyFlatBackdrop(btn, requested and "element" or "panel", requested and "primary" or "border")

                local borderColor
                if lockedByDependency then
                    borderColor = { 0.9, 0.72, 0.28, 1 }
                else
                    borderColor = requested and getColor("primary", { 0.2, 0.6, 1, 1 }) or getColor("border", { 0.25, 0.25, 0.25, 1 })
                end
                btn:SetBackdropBorderColor(borderColor[1], borderColor[2], borderColor[3], requested and 0.95 or borderColor[4])

                local dot = btn:CreateTexture(nil, "OVERLAY")
                dot:SetSize(8, 8)
                dot:SetPoint("LEFT", 10, 0)
                if lockedByDependency then
                    dot:SetColorTexture(0.9, 0.72, 0.28, 1)
                elseif requested then
                    dot:SetColorTexture(0.2, 0.8, 0.35, 1)
                else
                    dot:SetColorTexture(0.45, 0.45, 0.45, 1)
                end

                if lockedByDependency then
                    local lockIcon = btn:CreateTexture(nil, "OVERLAY")
                    lockIcon:SetSize(14, 14)
                    lockIcon:SetPoint("RIGHT", -8, 0)
                    lockIcon:SetTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Up")
                    lockIcon:SetTexCoord(0.25, 0.75, 0.25, 0.75)
                    lockIcon:SetVertexColor(0.95, 0.82, 0.32, 1)
                end

                local label = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
                label:SetPoint("LEFT", 24, 0)
                label:SetPoint("RIGHT", lockedByDependency and -28 or -8, 0)
                label:SetJustifyH("LEFT")
                label:SetWordWrap(false)
                label:SetText(info.label)
                if requested then
                    label:SetTextColor(1, 1, 1, 1)
                elseif lockedByDependency then
                    label:SetTextColor(1, 0.9, 0.55, 1)
                else
                    local dim = getColor("textDim", { 0.7, 0.7, 0.7, 1 })
                    label:SetTextColor(dim[1], dim[2], dim[3], 1)
                end

                btn:SetScript("OnEnter", function(self)
                    local hover = getColor("hover", { 0.22, 0.22, 0.22, 1 })
                    self:SetBackdropColor(hover[1], hover[2], hover[3], requested and 0.4 or 0.22)
                    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
                    GameTooltip:SetText(info.label)
                    GameTooltip:AddLine((runtimeState and runtimeState.effective) and L["Currently loaded"] or L["Currently unloaded"], 1, 1, 1)
                    if lockedByDependency then
                        GameTooltip:AddLine(string.format(L["Enable first: %s"], formatControlNames(unavailableDependencies)), 1, 0.82, 0.35)
                    elseif requested then
                        if effectiveNext then
                            GameTooltip:AddLine(L["Remains enabled after reload"], 0.6, 1, 0.6)
                        else
                            GameTooltip:AddLine(string.format(L["Disabled after reload due to unmet dependency: %s"], formatControlNames(savedState.missingDependencies)), 1, 0.82, 0.35)
                        end
                    else
                        GameTooltip:AddLine(L["Disabled after reload"], 1, 0.4, 0.4)
                    end
                    if info.dependencies and info.dependencies[1] then
                        GameTooltip:AddLine(string.format(L["Dependencies: %s"], formatControlNames(info.dependencies)), 0.7, 0.82, 1)
                    end
                    GameTooltip:Show()
                end)
                btn:SetScript("OnLeave", function(self)
                    local bgName = requested and "element" or "panel"
                    local bg = getColor(bgName, { 0.15, 0.15, 0.15, 1 })
                    self:SetBackdropColor(bg[1], bg[2], bg[3], bg[4])
                    GameTooltip:Hide()
                end)
                btn:SetScript("OnClick", function()
                    if lockedByDependency then
                        print("|cffffff00VFlow:|r " .. string.format(L["Please enable %s first, then enable %s."], formatControlNames(unavailableDependencies), info.label))
                        return
                    end
                    VFlow.setSavedModuleControlEnabled(info.controlKey, not requested)
                    if VFlow.MainUI and VFlow.MainUI.refresh then
                        VFlow.MainUI.refresh()
                    end
                end)
            end
        end
    }

    VFlow.Grid.render(container, layout, {}, nil)
end

-- =========================================================
-- SECTION 4: 导出到共享表
-- =========================================================

Shared.renderModuleControlContent = renderModuleControlContent
