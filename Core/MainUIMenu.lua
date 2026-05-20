-- =========================================================
-- MainUIMenu — 左侧菜单系统（数据、渲染、选中、分组管理）
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

-- =========================================================
-- SECTION 2: 菜单项定义
-- =========================================================

local MODULE_CONTROL_MENU_KEY = "overview_modules"
Shared.MODULE_CONTROL_MENU_KEY = MODULE_CONTROL_MENU_KEY

local menuItems = {
    {
        type = "category",
        key = "overview",
        label = L["Overview"],
        children = {
            { key = "general_home", label = L["Home"], module = "GeneralHome" },
            { key = "overview_config", label = L["Config"], module = "GeneralConfig" },
            { key = MODULE_CONTROL_MENU_KEY, label = L["Modules"], module = nil },
        }
    },
    {
        type = "category",
        key = "style",
        label = L["Style"],
        children = {
            { key = "style_icon", label = L["Icon"], module = "StyleIcon" },
            { key = "style_glow", label = L["Glow"], module = "StyleGlow" },
            { key = "style_display", label = L["Display"], module = "StyleDisplay" },
        }
    },
    {
        type = "category",
        key = "skills",
        label = L["Skills"],
        children = {
            { key = "skill_settings", label = L["Skill Settings"], module = "Skills" },
            { key = "skill_important", label = L["Important Skill Group"], module = "Skills" },
            { key = "skill_efficiency", label = L["Efficiency Skill Group"], module = "Skills" },
        }
    },
    {
        type = "category",
        key = "buffs",
        label = L["BUFF"],
        children = {
            { key = "buff_settings", label = L["BUFF Settings"], module = "Buffs" },
            { key = "buff_monitor", label = L["Main BUFF Group"], module = "Buffs" },
            { key = "buff_bar", label = L["BUFF Bar"], module = "BuffBar" },
            { key = "buff_trinket_potion", label = L["Trinkets & Potions"], module = "Buffs" },
        }
    },
    {
        type = "category",
        key = "custom",
        label = L["Graphic Monitor"],
        children = {
            { key = "custom_spell", label = L["Skill Monitor"], module = "CustomMonitor" },
            { key = "custom_buff", label = L["BUFF Monitor"], module = "CustomMonitor" },
        }
    },
    {
        type = "category",
        key = "resources",
        label = L["Resource bar"],
        children = {
            { key = "resource_styles", label = L["General resource appearance"], module = "Resources" },
            { key = "resource_primary", label = L["Primary resource bar"], module = "Resources" },
            { key = "resource_secondary", label = L["Secondary resource bar"], module = "Resources" },
        }
    },
    {
        type = "category",
        key = "items",
        label = L["Extra CD Monitor"],
        children = {
            { key = "item_monitor", label = L["Main Group"], module = "Items" },
        }
    },
}

-- =========================================================
-- SECTION 3: 菜单辅助函数
-- =========================================================

local ModuleRuntimeEnabled = VFlow.ModuleControlConstants.MODULE_RUNTIME_ENABLED
local collapsedCategories = {}
local menuButtons = {}

local function isModuleVisible(moduleName)
    if not moduleName then
        return true
    end
    return ModuleRuntimeEnabled[moduleName] ~= false
end

local function getVisibleChildren(category)
    local visible = {}
    for _, item in ipairs(category.children or {}) do
        if item.key == MODULE_CONTROL_MENU_KEY or isModuleVisible(item.module) then
            visible[#visible + 1] = item
        end
    end
    return visible
end

local function getFirstAvailableMenuTarget()
    for _, category in ipairs(menuItems) do
        local visibleChildren = getVisibleChildren(category)
        if visibleChildren[1] then
            return visibleChildren[1].key, visibleChildren[1].module
        end
    end
    return MODULE_CONTROL_MENU_KEY, nil
end

local function findModuleByMenuKey(menuKey)
    if not menuKey then
        return nil
    end
    if menuKey == MODULE_CONTROL_MENU_KEY then
        return nil
    end
    for _, category in ipairs(menuItems) do
        for _, item in ipairs(getVisibleChildren(category)) do
            if item.key == menuKey then
                return item.module
            end
        end
    end
    return nil
end

local function getCustomGroupsForCategory(categoryKey)
    if categoryKey == "skills" and isModuleVisible("Skills") and VFlow.Modules.Skills and VFlow.Modules.Skills.getCustomGroups then
        return VFlow.Modules.Skills.getCustomGroups(), "skill_custom_"
    end
    if categoryKey == "buffs" and isModuleVisible("Buffs") and VFlow.Modules.Buffs and VFlow.Modules.Buffs.getCustomGroups then
        return VFlow.Modules.Buffs.getCustomGroups(), "buff_custom_"
    end
    if categoryKey == "items" and isModuleVisible("Items") and VFlow.Modules.Items and VFlow.Modules.Items.getCustomGroups then
        return VFlow.Modules.Items.getCustomGroups(), "item_custom_"
    end
    return nil, nil
end

local function getModuleForCategory(categoryKey)
    if categoryKey == "skills" and isModuleVisible("Skills") then
        return VFlow.Modules.Skills
    end
    if categoryKey == "buffs" and isModuleVisible("Buffs") then
        return VFlow.Modules.Buffs
    end
    if categoryKey == "items" and isModuleVisible("Items") then
        return VFlow.Modules.Items
    end
    return nil
end

local STATIC_SKILL_CHILDREN = {
    { key = "skill_settings", label = L["Skill Settings"], module = "Skills" },
    { key = "skill_important", label = L["Important Skill Group"], module = "Skills" },
    { key = "skill_efficiency", label = L["Efficiency Skill Group"], module = "Skills" },
}

local STATIC_BUFF_CHILDREN = {
    { key = "buff_settings", label = L["BUFF Settings"], module = "Buffs" },
    { key = "buff_monitor", label = L["Main BUFF Group"], module = "Buffs" },
    { key = "buff_bar", label = L["BUFF Bar"], module = "BuffBar" },
    { key = "buff_trinket_potion", label = L["Trinkets & Potions"], module = "Buffs" },
}

local STATIC_ITEM_CHILDREN = {
    { key = "item_monitor", label = L["Main Group"], module = "Items" },
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

-- =========================================================
-- SECTION 4: 加载自定义组到菜单
-- =========================================================

local function loadCustomGroups()
    local skillsIndex, buffsIndex, itemsIndex
    for i, item in ipairs(menuItems) do
        if item.key == "skills" then skillsIndex = i end
        if item.key == "buffs" then buffsIndex = i end
        if item.key == "items" then itemsIndex = i end
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

    if itemsIndex then
        menuItems[itemsIndex].children = {}
        local mainLabel = L["Main Group"]
        if VFlow.getDBIfReady then
            local idb = VFlow.getDBIfReady("VFlow.Items")
            if idb and idb.mainGroup and type(idb.mainGroup.groupName) == "string" and idb.mainGroup.groupName ~= "" then
                mainLabel = idb.mainGroup.groupName
            end
        end
        menuItems[itemsIndex].children[1] = {
            key = "item_monitor",
            label = mainLabel,
            module = "Items",
            mainGroupRename = true,
        }
        local itemGroups, itemPrefix = getCustomGroupsForCategory("items")
        if itemGroups and itemPrefix then
            for i, group in ipairs(itemGroups) do
                table.insert(menuItems[itemsIndex].children, {
                    key = itemPrefix .. i,
                    label = group.name,
                    module = "Items",
                    isCustom = true,
                    customIndex = i,
                })
            end
        end
    end
end

-- =========================================================
-- SECTION 5: 更新菜单选中状态
-- =========================================================

local function updateMenuSelection()
    local currentMenuKey = Shared.currentMenuKey
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
-- SECTION 6: 添加/重命名分组输入
-- =========================================================

local showAddGroupInput
showAddGroupInput = function(btn, categoryKey, opts)
    opts = opts or {}
    local isEdit = opts.mode == "edit"
    btn:Hide()

    local menuContent = Shared.menuContent
    local leftMenu = Shared.leftMenu

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
    placeholder:SetText(isEdit and L["Please enter new group name"] or L["Please enter group name"])
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

    local function confirmAdd()
        local groupName = editBox:GetText():trim()
        if groupName == "" then
            inputFrame:Hide()
            btn:Show()
            return
        end

        if isEdit then
            if opts.mainGroupRename and categoryKey == "items" then
                if groupName ~= "" and VFlow.Store and VFlow.Store.set then
                    VFlow.Store.set("VFlow.Items", "mainGroup.groupName", groupName)
                end
            else
                local groups = getCustomGroupsForCategory(categoryKey)
                if groups and opts.customIndex and groups[opts.customIndex] then
                    groups[opts.customIndex].name = groupName
                end
            end
        else
            local module = getModuleForCategory(categoryKey)
            if module and module.addCustomGroup then
                module.addCustomGroup(groupName)
            end
        end

        loadCustomGroups()
        inputFrame:Hide()
        Shared.renderMenu()
        if isEdit and opts.mainGroupRename and Shared.currentMenuKey == "item_monitor" then
            Shared.showContent("item_monitor", "Items")
        end
        if isEdit and opts.itemKey and Shared.currentMenuKey == opts.itemKey then
            updateMenuSelection()
        end

        print("|cff00ff00VFlow:|r " .. (isEdit and L["Group updated:"] or L["Group created:"]), groupName)
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
-- SECTION 7: 渲染左侧菜单
-- =========================================================

local function renderMenu()
    loadCustomGroups()

    for _, btn in ipairs(menuButtons) do
        btn:Hide()
        btn:SetParent(nil)
    end
    menuButtons = {}

    local menuContent = Shared.menuContent
    local leftMenu = Shared.leftMenu
    local parent = menuContent or leftMenu
    local yOffset = -12

    for _, category in ipairs(menuItems) do
        local visibleChildren = getVisibleChildren(category)
        local canAddCustomGroup = (category.key == "skills" or category.key == "buffs" or category.key == "items")
            and getModuleForCategory(category.key) ~= nil
        if #visibleChildren > 0 or canAddCustomGroup then
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
                for _, item in ipairs(visibleChildren) do
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
                elseif item.mainGroupRename then
                    text:SetPoint("RIGHT", -22, 0)
                end
                text:SetJustifyH("LEFT")
                text:SetWordWrap(false)
                local textC = getColor("text", { 0.9, 0.9, 0.9, 1 })
                text:SetTextColor(textC[1], textC[2], textC[3], 0.9)
                btn.text = text
                if item.isCustom or item.mainGroupRename then
                    setSingleLineEllipsizedText(text, item.label)
                else
                    text:SetText(item.label)
                end

                btn:SetScript("OnClick", function()
                    Shared.showContent(item.key, item.module)
                    updateMenuSelection()
                end)

                btn:SetScript("OnEnter", function(self)
                    if Shared.currentMenuKey ~= item.key then
                        self.hover:SetColorTexture(primary[1], primary[2], primary[3], 0.12)
                    end
                end)
                btn:SetScript("OnLeave", function(self)
                    if Shared.currentMenuKey ~= item.key then
                        self.hover:SetColorTexture(primary[1], primary[2], primary[3], 0)
                    end
                end)

                btn.itemKey = item.key
                table.insert(menuButtons, btn)

                if item.isCustom or item.mainGroupRename then
                    local iconColor = getColor("textDim", { 0.7, 0.7, 0.7, 1 })

                    local editBtn = CreateFrame("Button", nil, btn)
                    editBtn:SetSize(14, 14)
                    editBtn:SetPoint("RIGHT", item.mainGroupRename and -6 or -22, 0)
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
                            mainGroupRename = item.mainGroupRename == true,
                        })
                    end)
                    editBtn:SetScript("OnEnter", function()
                        editIcon:SetVertexColor(1, 1, 1, 1)
                    end)
                    editBtn:SetScript("OnLeave", function()
                        editIcon:SetVertexColor(iconColor[1], iconColor[2], iconColor[3], 0.9)
                    end)
                end

                if item.isCustom then
                    local iconColor = getColor("textDim", { 0.7, 0.7, 0.7, 1 })

                    local deleteBtn = CreateFrame("Button", nil, btn)
                    deleteBtn:SetSize(14, 14)
                    deleteBtn:SetPoint("RIGHT", -6, 0)
                    local deleteIcon = deleteBtn:CreateTexture(nil, "OVERLAY")
                    deleteIcon:SetAllPoints()
                    deleteIcon:SetTexture("Interface\\AddOns\\VFlow\\Assets\\Icons\\delete")
                    deleteIcon:SetVertexColor(iconColor[1], iconColor[2], iconColor[3], 0.9)
                    deleteBtn:SetScript("OnClick", function()
                        UI.dialog(UIParent, L["Delete group"], L["Delete group confirm"], function()
                            local groups = getCustomGroupsForCategory(category.key)
                            local moduleKey = nil
                            if category.key == "skills" then
                                moduleKey = "VFlow.Skills"
                            elseif category.key == "buffs" then
                                moduleKey = "VFlow.Buffs"
                            elseif category.key == "items" then
                                moduleKey = "VFlow.Items"
                            end
                            if groups and item.customIndex and groups[item.customIndex] then
                                table.remove(groups, item.customIndex)
                                if moduleKey and VFlow.Store and VFlow.Store.set then
                                    VFlow.Store.set(moduleKey, "customGroups", groups)
                                end
                            end
                            if category.key == "items" then
                                if VFlow.ItemGroups and VFlow.ItemGroups.invalidateSpellMap then
                                    VFlow.ItemGroups.invalidateSpellMap()
                                end
                                if VFlow.RequestSkillRefresh and VFlow.RefreshBus and VFlow.RefreshBus.PRESETS then
                                    VFlow.RequestSkillRefresh(VFlow.RefreshBus.PRESETS.SKILL_GROUP_MAP)
                                end
                            end
                            loadCustomGroups()
                            if Shared.currentMenuKey == item.key then
                                local fallbackKey = "general_home"
                                local fallbackModule = "GeneralHome"
                                if category.key == "skills" then
                                    fallbackKey = "skill_important"
                                    fallbackModule = "Skills"
                                elseif category.key == "buffs" then
                                    fallbackKey = "buff_monitor"
                                    fallbackModule = "Buffs"
                                elseif category.key == "items" then
                                    fallbackKey = "item_monitor"
                                    fallbackModule = "Items"
                                end
                                Shared.showContent(fallbackKey, fallbackModule)
                            end
                            renderMenu()
                        end, nil, {
                            destructive = true,
                            confirmText = L["Delete"],
                            cancelText = L["Cancel"],
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

                if canAddCustomGroup then
                    local addBtn = CreateFrame("Button", nil, parent)
                    addBtn:SetSize(172, 26)
                    addBtn:SetPoint("TOPLEFT", 4, yOffset)

                addBtn.hover = addBtn:CreateTexture(nil, "BACKGROUND")
                addBtn.hover:SetAllPoints()
                local neutral = getColor("text", { 0.9, 0.9, 0.9, 1 })
                addBtn.hover:SetColorTexture(neutral[1], neutral[2], neutral[3], 0)

                local addText = addBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
                addText:SetPoint("LEFT", 46, 0)
                local labelText = L["New"]
                if category.key == "skills" then
                    labelText = labelText .. L["Skill group"]
                elseif category.key == "buffs" then
                    labelText = labelText .. L["BUFF group"]
                elseif category.key == "items" then
                    labelText = labelText .. L["Sub group"]
                end
                addText:SetText(labelText)
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
    end

    local menuScrollFrame = Shared.menuScrollFrame
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
-- SECTION 8: 导出到共享表
-- =========================================================

Shared.renderMenu = renderMenu
Shared.updateMenuSelection = updateMenuSelection
Shared.loadCustomGroups = loadCustomGroups
Shared.findModuleByMenuKey = findModuleByMenuKey
Shared.getFirstAvailableMenuTarget = getFirstAvailableMenuTarget
Shared.isModuleVisible = isModuleVisible
