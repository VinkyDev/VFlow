-- =========================================================
-- SECTION 1: 模块入口
-- MainUI — 设置主界面（框架创建、内容路由、公共 API）
-- =========================================================

local VFlow = _G.VFlow
if not VFlow then return end
local L = VFlow.L

VFlow._mainUI = VFlow._mainUI or {}
local Shared = VFlow._mainUI

-- =========================================================
-- SECTION 2: 主框架与局部状态
-- =========================================================

local mainFrame
local leftMenu
local rightPanel
local menuScrollFrame
local menuContent
local systemEditBtn
local internalEditBtn

local UI = VFlow.UI
local uiStyle = UI and UI.style or {}
local colors = uiStyle.colors or {}
local icons = uiStyle.icons or {}

local MODULE_CONTROL_MENU_KEY = Shared.MODULE_CONTROL_MENU_KEY

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
-- SECTION 3: 编辑模式按钮视觉
-- =========================================================

local function updateInternalEditButtonVisual()
    if not internalEditBtn then return end
    local isActive = VFlow.DragFrame and VFlow.DragFrame.isInternalEditMode and VFlow.DragFrame.isInternalEditMode()
    local element = getColor("element", { 0.15, 0.15, 0.15, 1 })
    local border = getColor("border", { 0.25, 0.25, 0.25, 1 })
    if isActive then
        local primary = getColor("primary", { 0.2, 0.6, 1, 1 })
        internalEditBtn:SetBackdropColor(primary[1], primary[2], primary[3], 0.35)
        internalEditBtn:SetBackdropBorderColor(primary[1], primary[2], primary[3], 0.95)
        if internalEditBtn.icon then
            internalEditBtn.icon:SetVertexColor(primary[1], primary[2], primary[3], 1)
        end
    else
        internalEditBtn:SetBackdropColor(element[1], element[2], element[3], element[4])
        internalEditBtn:SetBackdropBorderColor(border[1], border[2], border[3], border[4])
        if internalEditBtn.icon then
            internalEditBtn.icon:SetVertexColor(0.85, 0.85, 0.85, 1)
        end
    end
end

local function updateSystemEditButtonVisual()
    if not systemEditBtn then return end
    local isActive = VFlow.State.systemEditMode or false
    local element = getColor("element", { 0.15, 0.15, 0.15, 1 })
    local border = getColor("border", { 0.25, 0.25, 0.25, 1 })
    if isActive then
        local primary = getColor("primary", { 0.2, 0.6, 1, 1 })
        systemEditBtn:SetBackdropColor(primary[1], primary[2], primary[3], 0.35)
        systemEditBtn:SetBackdropBorderColor(primary[1], primary[2], primary[3], 0.95)
        if systemEditBtn.icon then
            systemEditBtn.icon:SetVertexColor(primary[1], primary[2], primary[3], 1)
        end
    else
        systemEditBtn:SetBackdropColor(element[1], element[2], element[3], element[4])
        systemEditBtn:SetBackdropBorderColor(border[1], border[2], border[3], border[4])
        if systemEditBtn.icon then
            systemEditBtn.icon:SetVertexColor(0.85, 0.85, 0.85, 1)
        end
    end
end

-- =========================================================
-- SECTION 4: 框架位置修正
-- =========================================================

local function clampMainFramePartiallyVisible()
    if not mainFrame or not mainFrame:IsShown() then return end
    local left = mainFrame:GetLeft()
    local right = mainFrame:GetRight()
    local top = mainFrame:GetTop()
    local bottom = mainFrame:GetBottom()
    if not (left and right and top and bottom) then return end

    local parentWidth, parentHeight = UIParent:GetSize()
    if not parentWidth or not parentHeight then return end

    local minVisibleX = 120
    local minVisibleY = 40
    local dx = 0
    local dy = 0

    if right < minVisibleX then
        dx = minVisibleX - right
    elseif left > (parentWidth - minVisibleX) then
        dx = (parentWidth - minVisibleX) - left
    end

    if top < minVisibleY then
        dy = minVisibleY - top
    elseif bottom > (parentHeight - minVisibleY) then
        dy = (parentHeight - minVisibleY) - bottom
    end

    if dx == 0 and dy == 0 then return end

    local point, relativeTo, relativePoint, xOfs, yOfs = mainFrame:GetPoint(1)
    mainFrame:ClearAllPoints()
    mainFrame:SetPoint(point or "CENTER", relativeTo or UIParent, relativePoint or "CENTER", (xOfs or 0) + dx, (yOfs or 0) + dy)
end

-- =========================================================
-- SECTION 5: 右侧内容管理
-- =========================================================

local function disposeRightPanelContent()
    if not rightPanel or not rightPanel.content then
        return
    end

    local content = rightPanel.content
    rightPanel.content = nil

    if content._vfOnDispose then
        local ok, err = pcall(content._vfOnDispose, content)
        if not ok then
            print("|cffff0000VFlow\233\148\153\232\175\175:|r \229\143\179\228\190\167\229\134\133\229\174\185\233\135\138\230\148\190\229\164\177\232\180\165:", err)
        end
    end

    if VFlow.Grid and VFlow.Grid.clear then
        local ok, err = pcall(VFlow.Grid.clear, content)
        if not ok then
            print("|cffff0000VFlow\233\148\153\232\175\175:|r \229\143\179\228\190\167\229\184\131\229\177\128\230\184\133\231\144\134\229\164\177\232\180\165:", err)
        end
    end

    content:Hide()
    content:ClearAllPoints()
    content:SetParent(nil)
end

local function showContent(menuKey, moduleName)
    if not moduleName then
        moduleName = Shared.findModuleByMenuKey(menuKey)
    end
    Shared.currentMenuKey = menuKey
    Shared.updateMenuSelection()

    -- 切页前先完整释放旧页面，避免 Grid / watch 回调残留
    disposeRightPanelContent()

    -- 创建内容容器
    local content = CreateFrame("Frame", nil, rightPanel)
    content:SetSize(650, 520)
    content:SetPoint("TOPLEFT", 10, -10)
    rightPanel.content = content

    if menuKey == MODULE_CONTROL_MENU_KEY then
        Shared.renderModuleControlContent(content)
        return
    end

    -- 尝试调用模块的渲染函数
    if moduleName and VFlow.Modules and VFlow.Modules[moduleName] then
        local module = VFlow.Modules[moduleName]
        if module.renderContent then
            module.renderContent(content, menuKey)
            return
        end
    end

    -- 默认占位内容
    local title = VFlow.UI.title(content, menuKey)
    title:SetPoint("TOPLEFT", 10, -10)

    local desc = VFlow.UI.description(content, string.format(L["Module %s is under development..."], moduleName or L["Unknown"]))
    desc:SetPoint("TOPLEFT", 10, -50)
end

-- 导出 showContent 到共享表，供菜单模块回调使用
Shared.showContent = showContent

-- =========================================================
-- SECTION 6: 创建主框架
-- =========================================================

local function createMainFrame()
    if mainFrame then return end

    mainFrame = CreateFrame("Frame", "VFlowMainFrame", UIParent, "BackdropTemplate")
    mainFrame:SetSize(900, 600)
    mainFrame:SetPoint("CENTER")
    mainFrame:SetFrameStrata("FULLSCREEN_DIALOG")
    mainFrame:SetFrameLevel(50)
    applyFlatBackdrop(mainFrame, "background", "border", 0.92)
    mainFrame:SetMovable(true)
    mainFrame:EnableMouse(true)
    mainFrame:SetClampedToScreen(false)
    mainFrame:RegisterForDrag("LeftButton")
    mainFrame:SetScript("OnDragStart", mainFrame.StartMoving)
    mainFrame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        clampMainFramePartiallyVisible()
    end)
    mainFrame:Hide()

    -- 标题栏
    local titleBar = CreateFrame("Frame", nil, mainFrame, "BackdropTemplate")
    titleBar:SetSize(900, 40)
    titleBar:SetPoint("TOP")
    applyFlatBackdrop(titleBar, "panel", "border")

    local titleText = titleBar:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
    titleText:SetPoint("LEFT", 20, 0)
    local addonVersion = C_AddOns and C_AddOns.GetAddOnMetadata("VFlow", "Version") or GetAddOnMetadata and GetAddOnMetadata("VFlow", "Version") or ""
    titleText:SetText(addonVersion ~= "" and ("VFlow v" .. addonVersion) or "VFlow")
    local primary = getColor("primary", { 0.2, 0.6, 1, 1 })
    titleText:SetTextColor(primary[1], primary[2], primary[3], primary[4])

    -- 关闭按钮
    local closeBtn = CreateFrame("Button", nil, titleBar, "BackdropTemplate")
    closeBtn:SetSize(24, 24)
    closeBtn:SetPoint("RIGHT", -10, 0)
    applyFlatBackdrop(closeBtn, "element", "border")
    local closeIcon = closeBtn:CreateTexture(nil, "OVERLAY")
    closeIcon:SetAllPoints()
    closeIcon:SetTexture(icons.close or "Interface\\AddOns\\VFlow\\Assets\\Icons\\close")
    closeIcon:SetVertexColor(0.85, 0.85, 0.85, 1)
    closeBtn:SetScript("OnEnter", function(self)
        local hover = getColor("hover", { 0.22, 0.22, 0.22, 1 })
        self:SetBackdropColor(hover[1], hover[2], hover[3], hover[4])
    end)
    closeBtn:SetScript("OnLeave", function(self)
        local element = getColor("element", { 0.15, 0.15, 0.15, 1 })
        self:SetBackdropColor(element[1], element[2], element[3], element[4])
    end)
    closeBtn:SetScript("OnClick", function()
        mainFrame:Hide()
    end)

    -- 编辑模式按钮
    systemEditBtn = CreateFrame("Button", nil, titleBar, "BackdropTemplate")
    systemEditBtn:SetSize(24, 24)
    systemEditBtn:SetPoint("RIGHT", closeBtn, "LEFT", -8, 0)
    applyFlatBackdrop(systemEditBtn, "element", "border")
    local editModeIcon = systemEditBtn:CreateTexture(nil, "OVERLAY")
    editModeIcon:SetAllPoints()
    editModeIcon:SetTexture("Interface\\AddOns\\VFlow\\Assets\\Icons\\edit")
    editModeIcon:SetVertexColor(0.85, 0.85, 0.85, 1)
    systemEditBtn.icon = editModeIcon
    systemEditBtn:SetScript("OnEnter", function(self)
        local hover = getColor("hover", { 0.22, 0.22, 0.22, 1 })
        self:SetBackdropColor(hover[1], hover[2], hover[3], hover[4])
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        if VFlow.State.systemEditMode then
            GameTooltip:SetText(L["Close system edit mode"])
        else
            GameTooltip:SetText(L["Open system edit mode"])
        end
        GameTooltip:Show()
    end)
    systemEditBtn:SetScript("OnLeave", function(self)
        updateSystemEditButtonVisual()
        GameTooltip:Hide()
    end)
    systemEditBtn:SetScript("OnClick", function()
        VFlow.toggleSystemEditMode()
    end)
    updateSystemEditButtonVisual()

    internalEditBtn = CreateFrame("Button", nil, titleBar, "BackdropTemplate")
    internalEditBtn:SetSize(24, 24)
    internalEditBtn:SetPoint("RIGHT", systemEditBtn, "LEFT", -8, 0)
    applyFlatBackdrop(internalEditBtn, "element", "border")
    local internalEditIcon = internalEditBtn:CreateTexture(nil, "OVERLAY")
    internalEditIcon:SetAllPoints()
    internalEditIcon:SetTexture("Interface\\AddOns\\VFlow\\Assets\\Icons\\mouse")
    internalEditIcon:SetVertexColor(0.85, 0.85, 0.85, 1)
    internalEditBtn.icon = internalEditIcon
    internalEditBtn:SetScript("OnEnter", function(self)
        local hover = getColor("hover", { 0.22, 0.22, 0.22, 1 })
        self:SetBackdropColor(hover[1], hover[2], hover[3], hover[4])
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        if VFlow.DragFrame and VFlow.DragFrame.isInternalEditMode and VFlow.DragFrame.isInternalEditMode() then
            GameTooltip:SetText(L["Close internal edit mode"])
        else
            GameTooltip:SetText(L["Open internal edit mode"])
        end
        GameTooltip:Show()
    end)
    internalEditBtn:SetScript("OnLeave", function(self)
        updateInternalEditButtonVisual()
        GameTooltip:Hide()
    end)
    internalEditBtn:SetScript("OnClick", function()
        if VFlow.DragFrame and VFlow.DragFrame.toggleInternalEditMode then
            VFlow.DragFrame.toggleInternalEditMode()
        end
        updateInternalEditButtonVisual()
    end)
    updateInternalEditButtonVisual()

    -- 冷却管理器按钮
    local cdManagerBtn = CreateFrame("Button", nil, titleBar, "BackdropTemplate")
    cdManagerBtn:SetSize(24, 24)
    cdManagerBtn:SetPoint("RIGHT", internalEditBtn, "LEFT", -8, 0)
    applyFlatBackdrop(cdManagerBtn, "element", "border")
    local cdManagerIcon = cdManagerBtn:CreateTexture(nil, "OVERLAY")
    cdManagerIcon:SetAllPoints()
    cdManagerIcon:SetTexture("Interface\\AddOns\\VFlow\\Assets\\Icons\\settings")
    cdManagerIcon:SetVertexColor(0.85, 0.85, 0.85, 1)
    cdManagerBtn:SetScript("OnEnter", function(self)
        local hover = getColor("hover", { 0.22, 0.22, 0.22, 1 })
        self:SetBackdropColor(hover[1], hover[2], hover[3], hover[4])
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:SetText(L["Cooldown Manager"])
        GameTooltip:Show()
    end)
    cdManagerBtn:SetScript("OnLeave", function(self)
        local element = getColor("element", { 0.15, 0.15, 0.15, 1 })
        self:SetBackdropColor(element[1], element[2], element[3], element[4])
        GameTooltip:Hide()
    end)
    cdManagerBtn:SetScript("OnClick", function()
        VFlow.openCooldownManager()
    end)

    -- 左侧菜单区域
    leftMenu = CreateFrame("Frame", nil, mainFrame, "BackdropTemplate")
    leftMenu:SetSize(200, 540)
    leftMenu:SetPoint("TOPLEFT", 10, -50)
    applyFlatBackdrop(leftMenu, "panel", "border", 0.8)
    leftMenu:EnableMouseWheel(true)

    menuScrollFrame = CreateFrame("ScrollFrame", nil, leftMenu, "UIPanelScrollFrameTemplate")
    menuScrollFrame:SetPoint("TOPLEFT", 4, -4)
    menuScrollFrame:SetPoint("BOTTOMRIGHT", -4, 4)

    menuContent = CreateFrame("Frame", nil, menuScrollFrame)
    menuContent:SetWidth(176)
    menuContent:SetHeight(1)
    menuScrollFrame:SetScrollChild(menuContent)

    if UI and UI.styleScrollFrame then
        UI.styleScrollFrame(menuScrollFrame, {
            anchorParent = leftMenu,
            offsetX = -2,
            topOffset = -6,
            bottomOffset = 6,
            width = 6,
        })
    end
    if UI and UI.bindScrollWheel then
        UI.bindScrollWheel(leftMenu, menuScrollFrame, 36)
    end

    -- 右侧内容区域
    rightPanel = CreateFrame("Frame", nil, mainFrame, "BackdropTemplate")
    rightPanel:SetSize(670, 540)
    rightPanel:SetPoint("TOPRIGHT", -10, -50)
    applyFlatBackdrop(rightPanel, "background", "border", 0.4)

    -- 将帧引用写入共享表，供菜单模块使用
    Shared.leftMenu = leftMenu
    Shared.menuScrollFrame = menuScrollFrame
    Shared.menuContent = menuContent

    -- 加载自定义组并渲染菜单
    Shared.loadCustomGroups()
    Shared.renderMenu()

    -- 显示默认内容
    local defaultMenuKey, defaultModule = Shared.getFirstAvailableMenuTarget()
    showContent(defaultMenuKey, defaultModule)
end

-- =========================================================
-- SECTION 7: 状态监听
-- =========================================================

VFlow.State.watch("internalEditMode", "VFlow.MainUI.InternalEditButton", function()
    updateInternalEditButtonVisual()
end)

VFlow.State.watch("systemEditMode", "VFlow.MainUI.SystemEditButton", function()
    updateSystemEditButtonVisual()
end)

-- =========================================================
-- SECTION 8: 战斗门控与全局入口
-- =========================================================

local pendingOpenRequest = nil
local pendingOpenContext = nil

local function performOpenRequest(menuKey, context)
    createMainFrame()
    mainFrame:Show()
    pendingOpenContext = nil
    if not menuKey then
        local fallbackKey, fallbackModule = Shared.getFirstAvailableMenuTarget()
        showContent(fallbackKey, fallbackModule)
        return
    end
    local moduleName = Shared.findModuleByMenuKey(menuKey)
    if moduleName or menuKey == MODULE_CONTROL_MENU_KEY then
        pendingOpenContext = {
            menuKey = menuKey,
            context = context,
        }
        showContent(menuKey, moduleName)
        return
    end
    local fallbackKey, fallbackModule = Shared.getFirstAvailableMenuTarget()
    showContent(fallbackKey, fallbackModule)
end

VFlow.State.watch("inCombat", "VFlow.MainUI", function(inCombat)
    if inCombat then
        if mainFrame and mainFrame:IsShown() then
            mainFrame:Hide()
        end
    else
        if pendingOpenRequest then
            local request = pendingOpenRequest
            pendingOpenRequest = nil
            performOpenRequest(request.menuKey, request.context)
        end
    end
end)

-- =========================================================
-- SECTION 9: 系统功能（冷却管理器 / 编辑模式）
-- =========================================================

VFlow.openCooldownManager = function()
    if EditModeManagerFrame and EditModeManagerFrame:IsShown() then
        HideUIPanel(EditModeManagerFrame)
    end
    if CooldownViewerSettings then
        CooldownViewerSettings:ShowUIPanel(false)
    end
end

VFlow.toggleSystemEditMode = function()
    if EditModeManagerFrame then
        if EditModeManagerFrame:IsShown() then
            HideUIPanel(EditModeManagerFrame)
        else
            ShowUIPanel(EditModeManagerFrame)
        end
    end
end

VFlow.openInternalEditMode = function()
    if VFlow.DragFrame and VFlow.DragFrame.setInternalEditMode then
        VFlow.DragFrame.setInternalEditMode(true)
    end
end

VFlow.toggleInternalEditMode = function()
    if VFlow.DragFrame and VFlow.DragFrame.toggleInternalEditMode then
        VFlow.DragFrame.toggleInternalEditMode()
    end
end

-- =========================================================
-- SECTION 10: 公共 API
-- =========================================================

VFlow.MainUI = {
    show = function()
        if VFlow.State.inCombat then
            pendingOpenRequest = {}
            print("|cff00ff00VFlow:|r " .. L["Cannot open settings in combat, will open after combat ends"])
            return
        end
        performOpenRequest()
    end,
    hide = function()
        pendingOpenRequest = nil
        pendingOpenContext = nil
        if mainFrame then
            mainFrame:Hide()
        end
    end,
    toggle = function()
        if VFlow.State.inCombat then
            if pendingOpenRequest then
                pendingOpenRequest = nil
                print("|cff00ff00VFlow:|r " .. L["Cancelled auto open after combat"])
            else
                pendingOpenRequest = {}
                print("|cff00ff00VFlow:|r " .. L["Cannot open settings in combat, will open after combat ends"])
            end
            return
        end
        createMainFrame()
        if mainFrame:IsShown() then
            mainFrame:Hide()
        else
            mainFrame:Show()
        end
    end,
    openMenu = function(menuKey, context)
        if VFlow.State.inCombat then
            pendingOpenRequest = {
                menuKey = menuKey,
                context = context,
            }
            print("|cff00ff00VFlow:|r " .. L["Cannot open settings in combat, will open after combat ends"])
            return
        end
        performOpenRequest(menuKey, context)
    end,
    refresh = function()
        if mainFrame and mainFrame:IsShown() then
            Shared.renderMenu()
            if Shared.currentMenuKey and rightPanel then
                local moduleName = Shared.findModuleByMenuKey(Shared.currentMenuKey)
                if Shared.currentMenuKey == MODULE_CONTROL_MENU_KEY or moduleName then
                    showContent(Shared.currentMenuKey, moduleName)
                else
                    local fallbackKey, fallbackModule = Shared.getFirstAvailableMenuTarget()
                    showContent(fallbackKey, fallbackModule)
                end
            end
        end
    end,
    getCurrentContainer = function()
        return rightPanel and rightPanel.content
    end,
    getCurrentMenuKey = function()
        return Shared.currentMenuKey
    end,
    consumeOpenContext = function(menuKey)
        if pendingOpenContext and pendingOpenContext.menuKey == menuKey then
            local context = pendingOpenContext.context
            pendingOpenContext = nil
            return context
        end
        return nil
    end,
}

-- =========================================================
-- SECTION 11: 斜杠命令
-- =========================================================

SLASH_VFLOWUI1 = "/vflow"
SLASH_VFLOWUI2 = "/vf"
SlashCmdList["VFLOWUI"] = function(msg)
    msg = msg:lower():trim()

    if msg == "" or msg == "show" then
        VFlow.MainUI.show()
    elseif msg == "hide" then
        VFlow.MainUI.hide()
    elseif msg == "toggle" then
        VFlow.MainUI.toggle()
    elseif msg == "reset" then
        local cleared = 0
        if VFlow.Store and VFlow.Store.resetAll then
            cleared = VFlow.Store.resetAll()
        end
        print("|cff00ff00VFlow:|r " .. string.format(L["Cleared all config, %d modules"], cleared))
        print("|cff00ff00VFlow:|r " .. L["Enter /reload for reset to take effect"])
    elseif msg == "pool stats" then
        for _, poolName in ipairs({ "VFlowButton", "VFlowContainer", "VFlowSlider", "VFlowCheckbox", "VFlowInput", "VFlowDropdown", "VFlowIconButton" }) do
            local s = VFlow.Pool.getStats(poolName)
            if s.acquired > 0 then
                print(string.format("  %s: active=%d hit=%d%%", poolName, s.active, s.hitRate))
            end
        end
    elseif msg == "pool reset" then
        print("|cff00ff00VFlow:|r " .. L["Resetting all frame pools..."])
        for _, poolName in ipairs({ "VFlowContainer", "VFlowSlider", "VFlowCheckbox", "VFlowInput", "VFlowDropdown", "VFlowSeparator", "VFlowSpacer" }) do
            VFlow.Pool.releaseAll(poolName)
        end
        print("|cff00ff00VFlow:|r " .. L["Frame pools reset"])
    else
        print("|cff00ff00VFlow:|r")
        print("  /vflow - " .. L["Open main UI"])
        print("  /vflow hide - " .. L["Hide main UI"])
        print("  /vflow toggle - " .. L["Toggle main UI"])
        print("  /vflow reset - " .. L["Clear all config"])
        print("  /vflow pool stats - " .. L["Show frame pool stats"])
        print("  /vflow pool reset - " .. L["Reset frame pools"])
    end
end

-- =========================================================
-- SECTION 12: 初始化
-- =========================================================

VFlow.on("PLAYER_ENTERING_WORLD", "VFlow.MainUI", function()
    local Pool = VFlow.Pool
    Pool.prewarm("VFlowSlider", 10)
    Pool.prewarm("VFlowCheckbox", 10)
    Pool.prewarm("VFlowDropdown", 10)
    Pool.prewarm("VFlowSeparator", 10)
    Pool.prewarm("VFlowSpacer", 10)

    -- 检查是否启用 /wa 命令
    local enableWa = false
    local isModuleVisible = Shared.isModuleVisible
    if isModuleVisible("GeneralHome") and VFlow.getDBIfReady then
        local homeDB = VFlow.getDBIfReady("VFlow.GeneralHome")
        enableWa = homeDB and homeDB.enableWaCommand
    end
    if enableWa == nil then enableWa = isModuleVisible("GeneralHome") end

    if enableWa then
        if not SlashCmdList["VFLOW_WA"] then
            SLASH_VFLOW_WA1 = "/wa"
            SlashCmdList["VFLOW_WA"] = function(msg)
                VFlow.MainUI.toggle()
            end
        end
    end
end)
