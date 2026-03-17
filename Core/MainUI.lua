-- =========================================================
-- VFlow MainUI - 主界面入口
-- =========================================================

local VFlow = _G.VFlow
if not VFlow then return end

-- =========================================================
-- 主框架
-- =========================================================

local mainFrame
local leftMenu
local rightPanel
local currentMenuKey
local menuScrollFrame
local menuContent
local systemEditBtn
local internalEditBtn
local collapsedCategories = {}
local clampMainFramePartiallyVisible

-- 菜单按钮缓存
local menuButtons = {}
local UI = VFlow.UI
local uiStyle = UI and UI.style or {}
local colors = uiStyle.colors or {}
local icons = uiStyle.icons or {}

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

clampMainFramePartiallyVisible = function()
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

local function setSingleLineEllipsizedText(fontString, value)
    if not fontString then return end
    local text = tostring(value or "")
    fontString:SetWordWrap(false)
    fontString:SetMaxLines(1)
    fontString:SetText(text)
    local maxWidth = fontString:GetWidth() or 0
    if maxWidth <= 0 then
        return
    end
    if fontString:GetStringWidth() <= maxWidth then
        return
    end
    local chars = {}
    for ch in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        chars[#chars + 1] = ch
    end
    if #chars == 0 then
        return
    end
    local low, high = 1, #chars
    local best = "..."
    while low <= high do
        local mid = math.floor((low + high) / 2)
        local candidate = table.concat(chars, "", 1, mid) .. "..."
        fontString:SetText(candidate)
        if fontString:GetStringWidth() <= maxWidth then
            best = candidate
            low = mid + 1
        else
            high = mid - 1
        end
    end
    fontString:SetText(best)
end

-- 菜单项定义
local menuItems = {
    -- 概览
    {
        type = "category",
        key = "overview",
        label = "概览",
        children = {
            { key = "general_home", label = "首页", module = "GeneralHome" },
            { key = "overview_config", label = "配置", module = "GeneralConfig" },
        }
    },
    -- 样式
    {
        type = "category",
        key = "style",
        label = "样式",
        children = {
            { key = "style_icon", label = "图标", module = "StyleIcon" },
            { key = "style_glow", label = "发光", module = "StyleGlow" },
            { key = "style_display", label = "显示", module = "StyleDisplay" },
        }
    },
    -- 技能组
    {
        type = "category",
        key = "skills",
        label = "技能",
        children = {
            { key = "skill_important", label = "重要技能组", module = "Skills" },
            { key = "skill_efficiency", label = "效能技能组", module = "Skills" },
            -- 自定义技能组会动态添加
        }
    },
    -- BUFF组
    {
        type = "category",
        key = "buffs",
        label = "BUFF",
        children = {
            { key = "buff_monitor", label = "主BUFF组", module = "Buffs" },
            { key = "buff_bar", label = "BUFF条", module = "BuffBar" },
            { key = "buff_trinket_potion", label = "饰品&药水", module = "Buffs" },
            -- 自定义BUFF组会动态添加
        }
    },
    -- 自定义监控
    {
        type = "category",
        key = "custom",
        label = "自定义图形监控",
        children = {
            { key = "custom_spell", label = "技能监控", module = "CustomMonitor" },
            { key = "custom_buff", label = "BUFF监控", module = "CustomMonitor" },
        }
    },
    -- 资源条
    -- {
    --     type = "category",
    --     key = "resources",
    --     label = "资源条",
    --     children = {
    --         { key = "resource_health", label = "生命值", module = "Resources" },
    --         { key = "resource_power", label = "职业资源", module = "Resources" },
    --     }
    -- },
}

-- =========================================================
-- 前置声明函数
-- =========================================================

local renderMenu
local updateMenuSelection
local showContent
local showAddGroupInput
local loadCustomGroups

local STATIC_SKILL_CHILDREN = {
    { key = "skill_important", label = "重要技能组", module = "Skills" },
    { key = "skill_efficiency", label = "效能技能组", module = "Skills" },
}

local STATIC_BUFF_CHILDREN = {
    { key = "buff_monitor", label = "主BUFF组", module = "Buffs" },
    { key = "buff_bar", label = "BUFF条", module = "BuffBar" },
    { key = "buff_trinket_potion", label = "饰品&药水", module = "Buffs" },
}

local function cloneChildren(items)
    local copied = {}
    for i, item in ipairs(items) do
        copied[i] = {
            key = item.key,
            label = item.label,
            module = item.module,
        }
    end
    return copied
end

local function findModuleByMenuKey(menuKey)
    if not menuKey then
        return nil
    end
    for _, category in ipairs(menuItems) do
        for _, item in ipairs(category.children or {}) do
            if item.key == menuKey then
                return item.module
            end
        end
    end
    return nil
end

local function getCustomGroupsForCategory(categoryKey)
    if categoryKey == "skills" and VFlow.Modules.Skills and VFlow.Modules.Skills.getCustomGroups then
        return VFlow.Modules.Skills.getCustomGroups(), "skill_custom_"
    end
    if categoryKey == "buffs" and VFlow.Modules.Buffs and VFlow.Modules.Buffs.getCustomGroups then
        return VFlow.Modules.Buffs.getCustomGroups(), "buff_custom_"
    end
    return nil, nil
end

local function getModuleForCategory(categoryKey)
    if categoryKey == "skills" then
        return VFlow.Modules.Skills
    end
    if categoryKey == "buffs" then
        return VFlow.Modules.Buffs
    end
    return nil
end

-- =========================================================
-- 加载自定义组到菜单
-- =========================================================

loadCustomGroups = function()
    -- 查找索引
    local skillsIndex, buffsIndex
    for i, item in ipairs(menuItems) do
        if item.key == "skills" then skillsIndex = i end
        if item.key == "buffs" then buffsIndex = i end
    end

    if skillsIndex then
        menuItems[skillsIndex].children = cloneChildren(STATIC_SKILL_CHILDREN)
        local skillGroups, skillPrefix = getCustomGroupsForCategory("skills")
        if skillGroups and skillPrefix then
            for i, group in ipairs(skillGroups) do
                table.insert(menuItems[skillsIndex].children, {
                    key = skillPrefix .. i,
                    label = group.name,
                    module = "Skills",
                    isCustom = true,
                    customIndex = i
                })
            end
        end
    end

    if buffsIndex then
        menuItems[buffsIndex].children = cloneChildren(STATIC_BUFF_CHILDREN)
        local buffGroups, buffPrefix = getCustomGroupsForCategory("buffs")
        if buffGroups and buffPrefix then
            for i, group in ipairs(buffGroups) do
                table.insert(menuItems[buffsIndex].children, {
                    key = buffPrefix .. i,
                    label = group.name,
                    module = "Buffs",
                    isCustom = true,
                    customIndex = i
                })
            end
        end
    end
end

-- =========================================================
-- 渲染左侧菜单
-- =========================================================

renderMenu = function()
    loadCustomGroups()

    -- 清空旧按钮
    for _, btn in ipairs(menuButtons) do
        btn:Hide()
        btn:SetParent(nil)
    end
    menuButtons = {}

    local parent = menuContent or leftMenu
    local yOffset = -12

    for _, category in ipairs(menuItems) do
        local categoryBtn = CreateFrame("Button", nil, parent)
        categoryBtn:SetSize(172, 28)
        categoryBtn:SetPoint("TOPLEFT", 4, yOffset)
        categoryBtn.categoryKey = category.key

        categoryBtn.hover = categoryBtn:CreateTexture(nil, "BACKGROUND")
        categoryBtn.hover:SetAllPoints()
        local hover = getColor("hover", { 0.22, 0.22, 0.22, 1 })
        categoryBtn.hover:SetColorTexture(hover[1], hover[2], hover[3], 0)

        categoryBtn.icon = categoryBtn:CreateTexture(nil, "OVERLAY")
        categoryBtn.icon:SetSize(16, 16)
        categoryBtn.icon:SetPoint("LEFT", 4, 0)

        local collapsed = collapsedCategories[category.key] == true
        categoryBtn.icon:SetTexture(collapsed and
        (icons.collapse or "Interface\\AddOns\\VFlow\\Assets\\Icons\\chevron_right") or
        (icons.expand or "Interface\\AddOns\\VFlow\\Assets\\Icons\\expand_more"))

        local categoryLabel = categoryBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        categoryLabel:SetPoint("LEFT", 24, 0)
        categoryLabel:SetJustifyH("LEFT")
        categoryLabel:SetText(category.label)
        local text = getColor("text", { 0.9, 0.9, 0.9, 1 })
        categoryLabel:SetTextColor(text[1], text[2], text[3], 0.95)
        categoryBtn.text = categoryLabel

        categoryBtn:SetScript("OnClick", function(self)
            collapsedCategories[self.categoryKey] = not (collapsedCategories[self.categoryKey] == true)
            renderMenu()
        end)
        categoryBtn:SetScript("OnEnter", function(self)
            local hc = getColor("hover", { 0.22, 0.22, 0.22, 1 })
            self.hover:SetColorTexture(hc[1], hc[2], hc[3], 0.22)
        end)
        categoryBtn:SetScript("OnLeave", function(self)
            local hc = getColor("hover", { 0.22, 0.22, 0.22, 1 })
            self.hover:SetColorTexture(hc[1], hc[2], hc[3], 0)
        end)

        table.insert(menuButtons, categoryBtn)
        yOffset = yOffset - 28

        if collapsedCategories[category.key] ~= true then
            local primary = getColor("primary", { 0.2, 0.6, 1, 1 })
            for _, item in ipairs(category.children) do
                local btn = CreateFrame("Button", nil, parent)
                btn:SetSize(172, 26)
                btn:SetPoint("TOPLEFT", 4, yOffset)

                btn.indicator = btn:CreateTexture(nil, "OVERLAY")
                btn.indicator:SetPoint("TOPLEFT", 0, -2)
                btn.indicator:SetPoint("BOTTOMLEFT", 0, 2)
                btn.indicator:SetWidth(2)
                btn.indicator:SetColorTexture(primary[1], primary[2], primary[3], 1)
                btn.indicator:Hide()

                btn.hover = btn:CreateTexture(nil, "BACKGROUND")
                btn.hover:SetAllPoints()
                btn.hover:SetColorTexture(primary[1], primary[2], primary[3], 0)

                local text = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
                text:SetPoint("LEFT", 34, 0)
                if item.isCustom then
                    text:SetPoint("RIGHT", -40, 0)
                end
                text:SetJustifyH("LEFT")
                text:SetWordWrap(false)
                local textC = getColor("text", { 0.9, 0.9, 0.9, 1 })
                text:SetTextColor(textC[1], textC[2], textC[3], 0.9)
                btn.text = text
                if item.isCustom then
                    setSingleLineEllipsizedText(text, item.label)
                else
                    text:SetText(item.label)
                end

                btn:SetScript("OnClick", function()
                    showContent(item.key, item.module)
                    updateMenuSelection()
                end)

                btn:SetScript("OnEnter", function(self)
                    if currentMenuKey ~= item.key then
                        self.hover:SetColorTexture(primary[1], primary[2], primary[3], 0.12)
                    end
                end)
                btn:SetScript("OnLeave", function(self)
                    if currentMenuKey ~= item.key then
                        self.hover:SetColorTexture(primary[1], primary[2], primary[3], 0)
                    end
                end)

                btn.itemKey = item.key
                table.insert(menuButtons, btn)

                if item.isCustom then
                    local iconColor = getColor("textDim", { 0.7, 0.7, 0.7, 1 })

                    local editBtn = CreateFrame("Button", nil, btn)
                    editBtn:SetSize(14, 14)
                    editBtn:SetPoint("RIGHT", -22, 0)
                    local editIcon = editBtn:CreateTexture(nil, "OVERLAY")
                    editIcon:SetAllPoints()
                    editIcon:SetTexture("Interface\\AddOns\\VFlow\\Assets\\Icons\\edit")
                    editIcon:SetVertexColor(iconColor[1], iconColor[2], iconColor[3], 0.9)
                    editBtn:SetScript("OnClick", function()
                        showAddGroupInput(btn, category.key, {
                            mode = "edit",
                            itemKey = item.key,
                            customIndex = item.customIndex,
                            initialValue = item.label,
                        })
                    end)
                    editBtn:SetScript("OnEnter", function()
                        editIcon:SetVertexColor(1, 1, 1, 1)
                    end)
                    editBtn:SetScript("OnLeave", function()
                        editIcon:SetVertexColor(iconColor[1], iconColor[2], iconColor[3], 0.9)
                    end)

                    local deleteBtn = CreateFrame("Button", nil, btn)
                    deleteBtn:SetSize(14, 14)
                    deleteBtn:SetPoint("RIGHT", -6, 0)
                    local deleteIcon = deleteBtn:CreateTexture(nil, "OVERLAY")
                    deleteIcon:SetAllPoints()
                    deleteIcon:SetTexture("Interface\\AddOns\\VFlow\\Assets\\Icons\\delete")
                    deleteIcon:SetVertexColor(iconColor[1], iconColor[2], iconColor[3], 0.9)
                    deleteBtn:SetScript("OnClick", function()
                        UI.dialog(UIParent, "删除分组", "删除后该分组配置将被移除，是否继续？", function()
                            local groups = getCustomGroupsForCategory(category.key)
                            if groups and item.customIndex and groups[item.customIndex] then
                                table.remove(groups, item.customIndex)
                            end
                            loadCustomGroups()
                            if currentMenuKey == item.key then
                                local fallbackKey = category.key == "skills" and "skill_important" or "buff_monitor"
                                local fallbackModule = category.key == "skills" and "Skills" or "Buffs"
                                showContent(fallbackKey, fallbackModule)
                            end
                            renderMenu()
                        end, nil, {
                            destructive = true,
                            confirmText = "删除",
                            cancelText = "取消",
                            closeOnOutside = false,
                        })
                    end)
                    deleteBtn:SetScript("OnEnter", function()
                        deleteIcon:SetVertexColor(1, 1, 1, 1)
                    end)
                    deleteBtn:SetScript("OnLeave", function()
                        deleteIcon:SetVertexColor(iconColor[1], iconColor[2], iconColor[3], 0.9)
                    end)
                end

                yOffset = yOffset - 28
            end

            if category.key == "skills" or category.key == "buffs" then
                local addBtn = CreateFrame("Button", nil, parent)
                addBtn:SetSize(172, 26)
                addBtn:SetPoint("TOPLEFT", 4, yOffset)

                addBtn.hover = addBtn:CreateTexture(nil, "BACKGROUND")
                addBtn.hover:SetAllPoints()
                local neutral = getColor("text", { 0.9, 0.9, 0.9, 1 })
                addBtn.hover:SetColorTexture(neutral[1], neutral[2], neutral[3], 0)

                local addText = addBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
                addText:SetPoint("LEFT", 46, 0)
                addText:SetText("新建" .. (category.key == "skills" and "技能" or "BUFF") .. "组")
                addText:SetTextColor(neutral[1], neutral[2], neutral[3], 0.6)
                addBtn.text = addText

                local addIcon = addBtn:CreateTexture(nil, "OVERLAY")
                addIcon:SetSize(14, 14)
                addIcon:SetPoint("LEFT", 28, 0)
                addIcon:SetTexture("Interface\\AddOns\\VFlow\\Assets\\Icons\\add")
                addIcon:SetVertexColor(neutral[1], neutral[2], neutral[3], 0.6)

                addBtn:SetScript("OnClick", function()
                    showAddGroupInput(addBtn, category.key)
                end)
                addBtn:SetScript("OnEnter", function(self)
                    self.hover:SetColorTexture(neutral[1], neutral[2], neutral[3], 0.1)
                end)
                addBtn:SetScript("OnLeave", function(self)
                    self.hover:SetColorTexture(neutral[1], neutral[2], neutral[3], 0)
                end)

                table.insert(menuButtons, addBtn)
                yOffset = yOffset - 30
            end

            yOffset = yOffset - 8
        end
    end

    if menuContent and leftMenu then
        local contentHeight = math.max(-yOffset + 8, leftMenu:GetHeight() - 8)
        menuContent:SetHeight(contentHeight)
        if UI and UI.updateScrollFrameState and menuScrollFrame then
            UI.updateScrollFrameState(menuScrollFrame, contentHeight, leftMenu:GetHeight() - 8)
        end
    end

    updateMenuSelection()
end

-- =========================================================
-- 显示添加组的输入框
-- =========================================================

showAddGroupInput = function(btn, categoryKey, opts)
    opts = opts or {}
    local isEdit = opts.mode == "edit"
    -- 隐藏按钮
    btn:Hide()

    -- 创建输入框
    local inputFrame = CreateFrame("Frame", nil, menuContent or leftMenu, "BackdropTemplate")
    inputFrame:SetSize(btn:GetWidth(), btn:GetHeight())
    inputFrame:SetPoint("TOPLEFT", btn, "TOPLEFT")
    applyFlatBackdrop(inputFrame, "element", "primary")

    local editBox = CreateFrame("EditBox", nil, inputFrame)
    editBox:SetPoint("LEFT", 5, 0)
    editBox:SetPoint("RIGHT", -5, 0)
    editBox:SetHeight(20)
    editBox:SetFontObject("GameFontHighlightSmall")
    editBox:SetAutoFocus(false)
    editBox:SetMaxLetters(20)
    editBox:SetTextInsets(2, 2, 0, 0)

    local placeholder = inputFrame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    placeholder:SetPoint("LEFT", editBox, "LEFT", 2, 0)
    placeholder:SetPoint("RIGHT", editBox, "RIGHT", -2, 0)
    placeholder:SetJustifyH("LEFT")
    placeholder:SetText(isEdit and "请输入新组名" or "请输入组名")
    local dim = getColor("textDim", { 0.7, 0.7, 0.7, 1 })
    placeholder:SetTextColor(dim[1], dim[2], dim[3], 0.85)

    local function updatePlaceholder()
        if editBox:GetText() ~= "" then
            placeholder:Hide()
        else
            placeholder:Show()
        end
    end
    updatePlaceholder()

    -- 确认添加
    local function confirmAdd()
        local groupName = editBox:GetText():trim()
        if groupName == "" then
            inputFrame:Hide()
            btn:Show()
            return
        end

        if isEdit then
            local groups = getCustomGroupsForCategory(categoryKey)
            if groups and opts.customIndex and groups[opts.customIndex] then
                groups[opts.customIndex].name = groupName
            end
        else
            local module = getModuleForCategory(categoryKey)
            if module and module.addCustomGroup then
                module.addCustomGroup(groupName)
            end
        end

        loadCustomGroups()
        inputFrame:Hide()
        renderMenu()
        if isEdit and opts.itemKey and currentMenuKey == opts.itemKey then
            updateMenuSelection()
        end

        print("|cff00ff00VFlow:|r " .. (isEdit and "已更新分组:" or "已创建分组:"), groupName)
    end

    editBox:SetScript("OnEnterPressed", confirmAdd)
    editBox:SetScript("OnTextChanged", updatePlaceholder)
    editBox:SetScript("OnEditFocusGained", updatePlaceholder)
    editBox:SetScript("OnEscapePressed", function()
        inputFrame:Hide()
        btn:Show()
    end)
    editBox:SetScript("OnEditFocusLost", function()
        updatePlaceholder()
        C_Timer.After(0.1, function()
            if inputFrame:IsShown() then
                inputFrame:Hide()
                btn:Show()
            end
        end)
    end)
    C_Timer.After(0, function()
        if inputFrame:IsShown() then
            if opts.initialValue then
                editBox:SetText(opts.initialValue)
                editBox:HighlightText()
            end
            editBox:SetFocus()
            updatePlaceholder()
        end
    end)
end

-- =========================================================
-- 更新菜单选中状态
-- =========================================================

updateMenuSelection = function()
    for _, btn in ipairs(menuButtons) do
        if btn.itemKey then
            if btn.itemKey == currentMenuKey then
                local primary = getColor("primary", { 0.2, 0.6, 1, 1 })
                if btn.indicator then
                    btn.indicator:Show()
                end
                if btn.hover then
                    btn.hover:SetColorTexture(primary[1], primary[2], primary[3], 0.14)
                end
                btn.text:SetTextColor(1, 1, 1, 1)
            else
                local dim = getColor("textDim", { 0.7, 0.7, 0.7, 1 })
                if btn.indicator then
                    btn.indicator:Hide()
                end
                if btn.hover then
                    local primary = getColor("primary", { 0.2, 0.6, 1, 1 })
                    btn.hover:SetColorTexture(primary[1], primary[2], primary[3], 0)
                end
                local textC = getColor("text", { 0.9, 0.9, 0.9, 1 })
                btn.text:SetTextColor(textC[1], textC[2], textC[3], 0.9)
            end
        end
    end
end

-- =========================================================
-- 显示右侧内容
-- =========================================================

showContent = function(menuKey, moduleName)
    currentMenuKey = menuKey
    updateMenuSelection()

    -- 清空右侧内容
    if rightPanel.content then
        rightPanel.content:Hide()
        rightPanel.content:SetParent(nil)
    end

    -- 创建内容容器
    local content = CreateFrame("Frame", nil, rightPanel)
    content:SetSize(650, 520)
    content:SetPoint("TOPLEFT", 10, -10)
    rightPanel.content = content

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

    local desc = VFlow.UI.description(content, "模块 " .. (moduleName or "未知") .. "正在紧锣密鼓的开发中...")
    desc:SetPoint("TOPLEFT", 10, -50)


end

-- =========================================================
-- 创建主框架
-- =========================================================

local function createMainFrame()
    if mainFrame then return end

    -- 主框架
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
            GameTooltip:SetText("关闭系统编辑模式")
        else
            GameTooltip:SetText("开启系统编辑模式")
        end
        GameTooltip:Show()
    end)
    systemEditBtn:SetScript("OnLeave", function(self)
        updateSystemEditButtonVisual()
        GameTooltip:Hide()
    end)
    systemEditBtn:SetScript("OnClick", function()
        if EditModeManagerFrame then
            if EditModeManagerFrame:IsShown() then
                HideUIPanel(EditModeManagerFrame)
            else
                ShowUIPanel(EditModeManagerFrame)
            end
        end
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
            GameTooltip:SetText("关闭内部编辑模式")
        else
            GameTooltip:SetText("开启内部编辑模式")
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
        GameTooltip:SetText("冷却管理器")
        GameTooltip:Show()
    end)
    cdManagerBtn:SetScript("OnLeave", function(self)
        local element = getColor("element", { 0.15, 0.15, 0.15, 1 })
        self:SetBackdropColor(element[1], element[2], element[3], element[4])
        GameTooltip:Hide()
    end)
    cdManagerBtn:SetScript("OnClick", function()
        if EditModeManagerFrame and EditModeManagerFrame:IsShown() then
            HideUIPanel(EditModeManagerFrame)
        end
        if CooldownViewerSettings then
            CooldownViewerSettings:ShowUIPanel(false)
        end
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

    -- 加载自定义组
    loadCustomGroups()

    -- 渲染菜单
    renderMenu()

    -- 显示默认内容
    showContent("general_home", "GeneralHome")
end

VFlow.State.watch("internalEditMode", "VFlow.MainUI.InternalEditButton", function()
    updateInternalEditButtonVisual()
end)

VFlow.State.watch("systemEditMode", "VFlow.MainUI.SystemEditButton", function()
    updateSystemEditButtonVisual()
end)

-- =========================================================
-- 暴露给模块使用的API
-- =========================================================

local pendingShowAfterCombat = false

-- 监听战斗状态变化
VFlow.State.watch("inCombat", "VFlow.MainUI", function(inCombat)
    if inCombat then
        -- 进入战斗，关闭主面板
        if mainFrame and mainFrame:IsShown() then
            mainFrame:Hide()
        end
    else
        -- 离开战斗，如果有待打开的请求则打开
        if pendingShowAfterCombat then
            pendingShowAfterCombat = false
            createMainFrame()
            mainFrame:Show()
        end
    end
end)

VFlow.MainUI = {
    show = function()
        if VFlow.State.inCombat then
            pendingShowAfterCombat = true
            print("|cff00ff00VFlow:|r 战斗中无法打开设置，将在战斗结束后自动打开")
            return
        end
        createMainFrame()
        mainFrame:Show()
    end,
    hide = function()
        pendingShowAfterCombat = false
        if mainFrame then
            mainFrame:Hide()
        end
    end,
    toggle = function()
        if VFlow.State.inCombat then
            if pendingShowAfterCombat then
                pendingShowAfterCombat = false
                print("|cff00ff00VFlow:|r 已取消战斗结束后自动打开")
            else
                pendingShowAfterCombat = true
                print("|cff00ff00VFlow:|r 战斗中无法打开设置，将在战斗结束后自动打开")
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
    openMenu = function(menuKey)
        if VFlow.State.inCombat then
            pendingShowAfterCombat = true
            print("|cff00ff00VFlow:|r 战斗中无法打开设置，将在战斗结束后自动打开")
            return
        end
        createMainFrame()
        mainFrame:Show()
        local moduleName = findModuleByMenuKey(menuKey)
        if moduleName then
            showContent(menuKey, moduleName)
        end
    end,
    refresh = function()
        if mainFrame and mainFrame:IsShown() then
            renderMenu()
            if currentMenuKey and rightPanel then
                local moduleName = findModuleByMenuKey(currentMenuKey)
                if moduleName then
                    showContent(currentMenuKey, moduleName)
                end
            end
        end
    end,
    getCurrentContainer = function()
        return rightPanel and rightPanel.content
    end,
    getCurrentMenuKey = function()
        return currentMenuKey
    end,
}

-- =========================================================
-- 斜杠命令
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
        print("|cff00ff00VFlow:|r 已清空所有配置，共", cleared, "个模块")
        print("|cff00ff00VFlow:|r 请输入 /reload 使重置立即生效")
    elseif msg == "pool stats" then
        VFlow.Pool.debugAll()
    elseif msg == "pool reset" then
        print("|cff00ff00VFlow:|r 重置所有帧池...")
        for _, poolName in ipairs({ "VFlowContainer", "VFlowSlider", "VFlowCheckbox", "VFlowInput", "VFlowDropdown", "VFlowSeparator", "VFlowSpacer" }) do
            VFlow.Pool.releaseAll(poolName)
        end
        print("|cff00ff00VFlow:|r 帧池已重置")
    else
        print("|cff00ff00VFlow命令:|r")
        print("  /vflow - 打开主界面")
        print("  /vflow hide - 隐藏主界面")
        print("  /vflow toggle - 切换主界面显示")
        print("  /vflow reset - 清空所有配置")
        print("  /vflow pool stats - 显示帧池统计")
        print("  /vflow pool reset - 重置所有帧池")
    end
end

-- =========================================================
-- 初始化
-- =========================================================

VFlow.on("PLAYER_ENTERING_WORLD", "VFlow.MainUI", function()
    local Pool = VFlow.Pool
    Pool.prewarm("VFlowSlider", 10)
    Pool.prewarm("VFlowCheckbox", 10)
    Pool.prewarm("VFlowDropdown", 10)
    Pool.prewarm("VFlowSeparator", 10)
    Pool.prewarm("VFlowSpacer", 10)

    -- 检查是否启用 /wa 命令
    local enableWa = VFlow.Store.get("VFlow.GeneralHome", "enableWaCommand")
    if enableWa == nil then enableWa = true end
    
    if enableWa then
        if not SlashCmdList["VFLOW_WA"] then
            SLASH_VFLOW_WA1 = "/wa"
            SlashCmdList["VFLOW_WA"] = function(msg)
                VFlow.MainUI.toggle()
            end
            -- print("|cff00ff00VFlow:|r 已启用 /wa 命令")
        end
    end

    print("|cff00ff00VFlow:|r 输入 /vflow 打开主界面")
end)
