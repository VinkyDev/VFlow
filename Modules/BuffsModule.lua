-- =========================================================
-- SECTION 1: 模块注册
-- =========================================================

local VFlow = _G.VFlow
if not VFlow then return end

local MODULE_KEY = "VFlow.Buffs"

VFlow.registerModule(MODULE_KEY, {
    name = "BUFF监控",
    description = "BUFF追踪",
})

-- =========================================================
-- SECTION 2: 常量
-- =========================================================

local UI_LIMITS = {
    SIZE = { min = 20, max = 100, step = 1 },
    SPACING = { min = 0, max = 20, step = 1 },
    POSITION = { min = -2000, max = 2000, step = 1 },
}

local GROW_DIRECTION_OPTIONS = {
    { "从中间增长", "center" },
    { "从起点增长", "start" },
    { "从终点增长", "end" },
}

local DEFAULT_POTIONS = {
    [241308] = 30,
    [241288] = 30,
    [241296] = 30,
    [241292] = 30,
}

-- =========================================================
-- SECTION 3: 默认配置
-- =========================================================

-- 单个BUFF组的默认配置
local function getDefaultGroupConfig()
    return {
        _dataVersion = 0,
        showOnlyValid = false,
        dynamicLayout = true,
        growDirection = "center",
        vertical = false,
        width = 35,
        height = 35,
        spacingX = 2,
        spacingY = 2,
        spellIDs = {},
        x = 0,
        y = 0,
        cooldownMaskColor = { r = 0, g = 0, b = 0, a = 0.7 },
        stackFont = {
            size = 12,
            font = "默认",
            outline = "OUTLINE",
            color = { r = 1, g = 1, b = 1, a = 1 },
            position = "BOTTOM",
            offsetX = 0,
            offsetY = -6,
        },
        cooldownFont = {
            size = 16,
            font = "默认",
            outline = "OUTLINE",
            color = { r = 1, g = 1, b = 1, a = 1 },
            position = "CENTER",
            offsetX = 0,
            offsetY = 0,
        },
    }
end

-- 饰品&药水组的默认配置
local function getTrinketPotionConfig()
    local config = getDefaultGroupConfig()
    config.vertical = true
    config.width = 35
    config.height = 35
    config.x = 100
    config.y = 0
    config.autoTrinkets = true
    config.itemIDs = {}
    config.itemDurations = {}
    config.defaultPotionsInitialized = false

    return config
end

local defaults = {
    buffMonitor = getDefaultGroupConfig(),
    trinketPotion = getTrinketPotionConfig(),
    customGroups = {},
}

local db = VFlow.getDB(MODULE_KEY, defaults)

local function ensureDefaultPotionsInitialized()
    local config = db.trinketPotion
    if config.defaultPotionsInitialized then
        return
    end

    config.itemIDs = config.itemIDs or {}
    config.itemDurations = config.itemDurations or {}

    for itemID, duration in pairs(DEFAULT_POTIONS) do
        if config.itemIDs[itemID] == nil then
            config.itemIDs[itemID] = true
        end
        if config.itemDurations[itemID] == nil then
            config.itemDurations[itemID] = duration
        end
    end

    config.defaultPotionsInitialized = true
    VFlow.Store.set(MODULE_KEY, "trinketPotion.itemIDs", config.itemIDs)
    VFlow.Store.set(MODULE_KEY, "trinketPotion.itemDurations", config.itemDurations)
    VFlow.Store.set(MODULE_KEY, "trinketPotion.defaultPotionsInitialized", true)
end

ensureDefaultPotionsInitialized()

-- =========================================================
-- SECTION 4: 数据源函数
-- =========================================================

local function getAvailableBuffs(groupConfig, groupIndex)
    local trackedBuffs = VFlow.State.get("trackedBuffs") or {}

    if not groupConfig.spellIDs then
        groupConfig.spellIDs = {}
    end

    -- 计算哪些BUFF已被其他组占用
    local usedBuffs = {}
    for i, group in ipairs(db.customGroups) do
        if i ~= groupIndex then
            for spellID in pairs(group.config.spellIDs or {}) do
                usedBuffs[spellID] = i
            end
        end
    end

    -- 可用BUFF列表（未被其他组占用）
    local availableBuffs = {}
    for spellID, buffInfo in pairs(trackedBuffs) do
        if not usedBuffs[spellID] and not groupConfig.spellIDs[spellID] then
            table.insert(availableBuffs, buffInfo)
        end
    end
    table.sort(availableBuffs, function(a, b) return a.name < b.name end)

    return availableBuffs
end

local function getCurrentBuffs(groupConfig)
    local trackedBuffs = VFlow.State.get("trackedBuffs") or {}
    local showOnlyValid = groupConfig.showOnlyValid

    local currentBuffs = {}
    for spellID in pairs(groupConfig.spellIDs or {}) do
        if trackedBuffs[spellID] then
            table.insert(currentBuffs, trackedBuffs[spellID])
        elseif not showOnlyValid then
            local spellInfo = C_Spell.GetSpellInfo(spellID)
            local name = spellInfo and spellInfo.name
            local icon = spellInfo and spellInfo.iconID
            table.insert(currentBuffs, {
                spellID = spellID,
                name = name or ("未知技能 " .. spellID),
                icon = icon or 134400,
                isMissing = true
            })
        end
    end
    table.sort(currentBuffs, function(a, b) return a.name < b.name end)

    return currentBuffs
end

-- =========================================================
-- SECTION 5: 布局构建器
-- =========================================================

local mergeLayouts = VFlow.LayoutUtils.mergeLayouts

-- 自定义组的BUFF选择器（大块layout，值得拆分）
local function buildCustomBuffSelector(groupConfig, options)
    return {
        { type = "subtitle", text = "BUFF选择", cols = 24 },
        { type = "separator", cols = 24 },

        {
            type = "interactiveText",
            cols = 24,
            text = "仅可使用{冷却管理器}中追踪的BUFF，{点我重新扫描}。可在{编辑模式}中预览和拖拽修改位置",
            links = {
                ["冷却管理器"] = function()
                    if EditModeManagerFrame and EditModeManagerFrame:IsShown() then
                        HideUIPanel(EditModeManagerFrame)
                    end
                    if CooldownViewerSettings then
                        CooldownViewerSettings:ShowUIPanel(false)
                    end
                end,
                ["点我重新扫描"] = function()
                    if VFlow.BuffScanner then
                        VFlow.BuffScanner.scan()
                    end
                    local newVersion = GetTime()
                    for i = 1, #db.customGroups do
                        VFlow.Store.set(MODULE_KEY, "customGroups." .. i .. ".config._dataVersion", newVersion)
                    end
                end,
                ["编辑模式"] = function()
                    if EditModeManagerFrame then
                        ShowUIPanel(EditModeManagerFrame)
                    end
                end,
            }
        },
        { type = "spacer", height = 10, cols = 24 },

        { type = "description", text = "可用BUFF（点击添加）:", cols = 24 },
        { type = "spacer", height = 5, cols = 24 },

        {
            type = "for",
            cols = 2,
            dependsOn = { "spellIDs", "_dataVersion" },
            dataSource = function()
                return getAvailableBuffs(groupConfig, options.groupIndex)
            end,
            template = {
                type = "iconButton",
                icon = function(buffInfo) return buffInfo.icon end,
                size = 40,
                tooltip = function(buffInfo)
                    return function(tooltip)
                        tooltip:SetSpellByID(buffInfo.spellID)
                        tooltip:AddLine("|cff00ff00点击添加到当前组|r", 1, 1, 1)
                    end
                end,
                onClick = function(buffInfo)
                    groupConfig.spellIDs[buffInfo.spellID] = true
                    local configPath = "customGroups." .. options.groupIndex .. ".config"
                    VFlow.Store.set(MODULE_KEY, configPath .. ".spellIDs", groupConfig.spellIDs)
                end,
            }
        },

        { type = "spacer", height = 10, cols = 24 },
        { type = "description", text = "当前组BUFF（点击移除）:", cols = 24 },
        { type = "checkbox", key = "showOnlyValid", label = "仅显示有效", cols = 24 },

        {
            type = "for",
            cols = 2,
            dependsOn = { "spellIDs", "_dataVersion", "showOnlyValid" },
            dataSource = function()
                return getCurrentBuffs(groupConfig)
            end,
            template = {
                type = "iconButton",
                icon = function(buffInfo) return buffInfo.icon end,
                size = 40,
                tooltip = function(buffInfo)
                    return function(tooltip)
                        tooltip:SetSpellByID(buffInfo.spellID)
                        if buffInfo.isMissing then
                            tooltip:AddLine(" ")
                            tooltip:AddLine("|cffff0000[警告] 该BUFF不可用或未在冷却管理器中追踪|r")
                            tooltip:AddLine(" ")
                        end
                        tooltip:AddLine("|cffff0000点击从当前组移除|r", 1, 1, 1)
                    end
                end,
                onClick = function(buffInfo)
                    groupConfig.spellIDs[buffInfo.spellID] = nil
                    local configPath = "customGroups." .. options.groupIndex .. ".config"
                    VFlow.Store.set(MODULE_KEY, configPath .. ".spellIDs", groupConfig.spellIDs)
                end,
            }
        },

        { type = "spacer", height = 20, cols = 24 },
    }
end

-- =========================================================
-- SECTION 6: 渲染函数
-- =========================================================

local function renderGroupConfig(container, groupConfig, groupName, options)
    local Grid = VFlow.Grid
    options = options or {}

    -- 一次性mergeLayouts，使用短路求值处理条件
    local layout = mergeLayouts(
        -- 标题
        {
            { type = "title", text = groupName, cols = 24 },
            { type = "separator", cols = 24 },
        },

        -- 自定义组：BUFF选择器
        options.isCustom and buildCustomBuffSelector(groupConfig, options),

        -- 基础设置
        {
            { type = "subtitle", text = "基础设置", cols = 24 },
            { type = "separator", cols = 24 },
            { type = "checkbox", key = "dynamicLayout", label = "动态布局", cols = 12 },
        },

        -- 可选：垂直布局
        options.showVerticalLayoutOption and {
            { type = "checkbox", key = "vertical", label = "垂直布局", cols = 12 },
        },

        -- 动态布局选项
        {
            {
                type = "if",
                dependsOn = "dynamicLayout",
                condition = function(cfg) return cfg.dynamicLayout end,
                children = {
                    {
                        type = "dropdown",
                        key = "growDirection",
                        label = "生长方向",
                        cols = 12,
                        items = GROW_DIRECTION_OPTIONS
                    },
                }
            },
        },

        -- 尺寸和间距
        {
            { type = "slider", key = "spacingX", label = "列间距",
              min = UI_LIMITS.SPACING.min, max = UI_LIMITS.SPACING.max, step = 1, cols = 12 },
            { type = "slider", key = "spacingY", label = "行间距",
              min = UI_LIMITS.SPACING.min, max = UI_LIMITS.SPACING.max, step = 1, cols = 12 },
            { type = "slider", key = "width", label = "宽度",
              min = UI_LIMITS.SIZE.min, max = UI_LIMITS.SIZE.max, step = 1, cols = 12 },
            { type = "slider", key = "height", label = "高度",
              min = UI_LIMITS.SIZE.min, max = UI_LIMITS.SIZE.max, step = 1, cols = 12 },
        },

        -- 自定义组：位置设置
        options.isCustom and {
            { type = "spacer", height = 10, cols = 24 },
            { type = "subtitle", text = "位置设置", cols = 24 },
            { type = "separator", cols = 24 },
            { type = "slider", key = "x", label = "X坐标",
              min = UI_LIMITS.POSITION.min, max = UI_LIMITS.POSITION.max, step = 1, cols = 12 },
            { type = "slider", key = "y", label = "Y坐标",
              min = UI_LIMITS.POSITION.min, max = UI_LIMITS.POSITION.max, step = 1, cols = 12 },
            { type = "description", text = "提示：也可在编辑模式中拖拽修改位置", cols = 24 },
        },

        -- 字体设置
        {
            { type = "spacer", height = 10, cols = 24 },
            Grid.fontGroup("stackFont", "堆叠文字字体"),
            { type = "spacer", height = 10, cols = 24 },
            Grid.fontGroup("cooldownFont", "冷却读秒字体"),
        },

        -- 遮罩层配置
        {
            { type = "spacer", height = 10, cols = 24 },
            { type = "subtitle", text = "遮罩层配置", cols = 24 },
            { type = "separator", cols = 24 },
            { type = "colorPicker", key = "cooldownMaskColor", label = "持续时间遮罩层颜色", hasAlpha = true, cols = 12 },
        }
    )

    -- 渲染
    if options.isCustom then
        local configPath = "customGroups." .. options.groupIndex .. ".config"
        Grid.render(container, layout, groupConfig, MODULE_KEY, configPath)
    else
        Grid.render(container, layout, groupConfig, MODULE_KEY)
    end
end

local function renderTrinketPotionConfig(container, groupConfig)
    local Grid = VFlow.Grid

    -- 初始化临时字段
    if not groupConfig._inputItemID then groupConfig._inputItemID = "" end
    if not groupConfig._inputDuration then groupConfig._inputDuration = "" end
    if not groupConfig._showDurationInput then groupConfig._showDurationInput = false end

    local layout = mergeLayouts(
        -- 标题
        {
            { type = "title", text = "饰品&药水", cols = 24 },
            { type = "separator", cols = 24 },
        },

        -- 提示文本
        {
            {
                type = "interactiveText",
                cols = 24,
                text = "可在{编辑模式}中预览和拖拽修改位置",
                links = {
                    ["编辑模式"] = function()
                        if EditModeManagerFrame then
                            ShowUIPanel(EditModeManagerFrame)
                        end
                    end,
                }
            },
            { type = "spacer", height = 10, cols = 24 },
        },

        -- 物品监控
        {
            { type = "subtitle", text = "物品监控", cols = 24 },
            { type = "separator", cols = 24 },
            { type = "checkbox", key = "autoTrinkets", label = "自动识别主动饰品（槽位13/14）", cols = 24 },
            { type = "spacer", height = 10, cols = 24 },
        },

        -- 物品ID输入区
        {
            { type = "description", text = "手动添加物品:", cols = 24 },
            { type = "spacer", height = 5, cols = 24 },
            { type = "input", key = "_inputItemID", label = "物品ID", cols = 6, numeric = true, labelOnLeft = true },
        },

        -- 添加按钮（当不显示持续时间输入框时显示）
        {
            {
                type = "if",
                dependsOn = "_showDurationInput",
                condition = function(cfg) return not cfg._showDurationInput end,
                children = {
                    {
                        type = "button",
                        text = "添加",
                        cols = 3,
                        onClick = function(cfg)
                            local itemIDText = cfg._inputItemID or ""
                            if itemIDText == "" then
                                print("|cffff0000VFlow:|r 请输入物品ID")
                                return
                            end

                            local itemID = tonumber(itemIDText)
                            if not itemID then
                                print("|cffff0000VFlow:|r 无效的物品ID")
                                return
                            end

                            if cfg.itemIDs[itemID] then
                                print("|cffff0000VFlow:|r 该物品已添加")
                                return
                            end

                            -- 尝试解析持续时间
                            local duration = nil
                            if VFlow.TrinketPotionMonitor then
                                duration = VFlow.TrinketPotionMonitor.parseDurationFromItem(itemID)
                            end

                            if duration then
                                cfg.itemIDs[itemID] = true
                                cfg.itemDurations[itemID] = duration
                                VFlow.Store.set(MODULE_KEY, "trinketPotion.itemIDs", cfg.itemIDs)
                                VFlow.Store.set(MODULE_KEY, "trinketPotion.itemDurations", cfg.itemDurations)
                                cfg._inputItemID = ""
                                VFlow.Store.set(MODULE_KEY, "trinketPotion._inputItemID", "")
                                print("|cff00ff00VFlow:|r 已添加物品 " .. itemID .. "（持续时间: " .. duration .. "秒）")
                            else
                                cfg._showDurationInput = true
                                VFlow.Store.set(MODULE_KEY, "trinketPotion._showDurationInput", true)
                                print("|cffff9900VFlow:|r 无法自动解析持续时间，请手动输入")
                            end
                        end,
                    },
                }
            },
        },

        -- 持续时间输入框和确认按钮
        {
            {
                type = "if",
                dependsOn = "_showDurationInput",
                condition = function(cfg) return cfg._showDurationInput end,
                children = {
                    { type = "input", key = "_inputDuration", label = "持续时间(秒)", cols = 6, numeric = true },
                    {
                        type = "button",
                        text = "确认",
                        cols = 3,
                        onClick = function(cfg)
                            local itemIDText = cfg._inputItemID or ""
                            local durationText = cfg._inputDuration or ""

                            if itemIDText == "" or durationText == "" then
                                print("|cffff0000VFlow:|r 请输入物品ID和持续时间")
                                return
                            end

                            local itemID = tonumber(itemIDText)
                            local duration = tonumber(durationText)

                            if not itemID or not duration or duration <= 0 then
                                print("|cffff0000VFlow:|r 无效的输入")
                                return
                            end

                            cfg.itemIDs[itemID] = true
                            cfg.itemDurations[itemID] = duration
                            VFlow.Store.set(MODULE_KEY, "trinketPotion.itemIDs", cfg.itemIDs)
                            VFlow.Store.set(MODULE_KEY, "trinketPotion.itemDurations", cfg.itemDurations)

                            cfg._inputItemID = ""
                            cfg._inputDuration = ""
                            cfg._showDurationInput = false
                            VFlow.Store.set(MODULE_KEY, "trinketPotion._inputItemID", "")
                            VFlow.Store.set(MODULE_KEY, "trinketPotion._inputDuration", "")
                            VFlow.Store.set(MODULE_KEY, "trinketPotion._showDurationInput", false)

                            print("|cff00ff00VFlow:|r 已添加物品 " .. itemID .. "（持续时间: " .. duration .. "秒）")
                        end,
                    },
                    {
                        type = "button",
                        text = "取消",
                        cols = 3,
                        onClick = function(cfg)
                            cfg._inputItemID = ""
                            cfg._inputDuration = ""
                            cfg._showDurationInput = false
                            VFlow.Store.set(MODULE_KEY, "trinketPotion._inputItemID", "")
                            VFlow.Store.set(MODULE_KEY, "trinketPotion._inputDuration", "")
                            VFlow.Store.set(MODULE_KEY, "trinketPotion._showDurationInput", false)
                        end,
                    },
                }
            },
        },

        -- 已监控的物品列表
        {
            { type = "spacer", height = 10, cols = 24 },
            { type = "description", text = "已监控的物品（点击删除）:", cols = 24 },
            { type = "spacer", height = 5, cols = 24 },
            {
                type = "for",
                cols = 2,
                dependsOn = { "autoTrinkets", "itemIDs", "_dataVersion" },
                dataSource = function()
                    local items = {}

                    -- 添加自动检测的饰品
                    if groupConfig.autoTrinkets and VFlow.TrinketPotionMonitor then
                        local autoItems = VFlow.TrinketPotionMonitor.getAutoDetectedItems()
                        for _, itemData in ipairs(autoItems) do
                            local itemName, _, _, _, _, _, _, _, _, itemIcon = C_Item.GetItemInfo(itemData.itemID)
                            table.insert(items, {
                                itemID = itemData.itemID,
                                name = itemName or ("物品 " .. itemData.itemID),
                                icon = itemIcon or itemData.icon or 134400,
                                duration = itemData.duration or 0,
                                isAuto = true,
                            })
                        end
                    end

                    -- 添加手动添加的物品
                    for itemID in pairs(groupConfig.itemIDs or {}) do
                        local itemName, _, _, _, _, _, _, _, _, itemIcon = C_Item.GetItemInfo(itemID)
                        table.insert(items, {
                            itemID = itemID,
                            name = itemName or ("物品 " .. itemID),
                            icon = itemIcon or 134400,
                            duration = groupConfig.itemDurations[itemID] or 0,
                            isAuto = false,
                        })
                    end

                    table.sort(items, function(a, b) return a.name < b.name end)
                    return items
                end,
                template = {
                    type = "iconButton",
                    icon = function(itemData) return itemData.icon end,
                    size = 40,
                    tooltip = function(itemData)
                        return function(tooltip)
                            tooltip:SetItemByID(itemData.itemID)
                            tooltip:AddLine(" ")
                            tooltip:AddLine("持续时间: " .. itemData.duration .. "秒", 1, 1, 1)
                            tooltip:AddLine(" ")
                            if itemData.isAuto then
                                tooltip:AddLine("|cff808080自动检测的饰品（不可删除）|r", 1, 1, 1)
                            else
                                tooltip:AddLine("|cffff0000点击删除|r", 1, 1, 1)
                            end
                        end
                    end,
                    onClick = function(itemData)
                        if itemData.isAuto then
                            print("|cffff0000VFlow:|r 自动检测的饰品不可删除，请关闭自动识别开关")
                            return
                        end

                        groupConfig.itemIDs[itemData.itemID] = nil
                        groupConfig.itemDurations[itemData.itemID] = nil
                        VFlow.Store.set(MODULE_KEY, "trinketPotion.itemIDs", groupConfig.itemIDs)
                        VFlow.Store.set(MODULE_KEY, "trinketPotion.itemDurations", groupConfig.itemDurations)
                    end,
                }
            },
            { type = "spacer", height = 20, cols = 24 },
        },

        -- 基础设置
        {
            { type = "subtitle", text = "基础设置", cols = 24 },
            { type = "separator", cols = 24 },
            { type = "checkbox", key = "dynamicLayout", label = "动态布局", cols = 12 },
            { type = "checkbox", key = "vertical", label = "垂直布局", cols = 12 },
        },

        -- 动态布局选项
        {
            {
                type = "if",
                dependsOn = "dynamicLayout",
                condition = function(cfg) return cfg.dynamicLayout end,
                children = {
                    {
                        type = "dropdown",
                        key = "growDirection",
                        label = "生长方向",
                        cols = 12,
                        items = GROW_DIRECTION_OPTIONS
                    },
                }
            },
        },

        -- 尺寸和间距
        {
            { type = "slider", key = "spacingX", label = "列间距",
              min = UI_LIMITS.SPACING.min, max = UI_LIMITS.SPACING.max, step = 1, cols = 12 },
            { type = "slider", key = "spacingY", label = "行间距",
              min = UI_LIMITS.SPACING.min, max = UI_LIMITS.SPACING.max, step = 1, cols = 12 },
            { type = "slider", key = "width", label = "宽度",
              min = UI_LIMITS.SIZE.min, max = UI_LIMITS.SIZE.max, step = 1, cols = 12 },
            { type = "slider", key = "height", label = "高度",
              min = UI_LIMITS.SIZE.min, max = UI_LIMITS.SIZE.max, step = 1, cols = 12 },
            { type = "spacer", height = 10, cols = 24 },
        },

        -- 位置设置
        {
            { type = "subtitle", text = "位置设置", cols = 24 },
            { type = "separator", cols = 24 },
            { type = "slider", key = "x", label = "X坐标",
              min = UI_LIMITS.POSITION.min, max = UI_LIMITS.POSITION.max, step = 1, cols = 12 },
            { type = "slider", key = "y", label = "Y坐标",
              min = UI_LIMITS.POSITION.min, max = UI_LIMITS.POSITION.max, step = 1, cols = 12 },
            { type = "description", text = "提示：也可在编辑模式中拖拽修改位置", cols = 24 },
            { type = "spacer", height = 10, cols = 24 },
        },

        -- 字体设置
        {
            Grid.fontGroup("cooldownFont", "冷却读秒字体"),
        },

        -- 遮罩层配置
        {
            { type = "spacer", height = 10, cols = 24 },
            { type = "subtitle", text = "遮罩层配置", cols = 24 },
            { type = "separator", cols = 24 },
            { type = "colorPicker", key = "cooldownMaskColor", label = "持续时间遮罩层颜色", hasAlpha = true, cols = 12 },
        }
    )

    Grid.render(container, layout, groupConfig, MODULE_KEY, "trinketPotion")
end

local function renderContent(container, menuKey)
    if menuKey == "buff_monitor" then
        renderGroupConfig(container, db.buffMonitor, "主BUFF组", {
            showVerticalLayoutOption = false
        })
    elseif menuKey == "buff_trinket_potion" then
        renderTrinketPotionConfig(container, db.trinketPotion)
    elseif menuKey:find("^buff_custom_") then
        local customIndex = tonumber(menuKey:match("buff_custom_(%d+)"))
        if customIndex and db.customGroups[customIndex] then
            local customGroup = db.customGroups[customIndex]
            renderGroupConfig(container, customGroup.config, customGroup.name, {
                isCustom = true,
                groupIndex = customIndex,
                showVerticalLayoutOption = true
            })
        else
            local title = VFlow.UI.title(container, "自定义BUFF组未找到")
            title:SetPoint("TOPLEFT", 10, -10)
        end
    end
end

-- =========================================================
-- SECTION 7: 公共接口
-- =========================================================

if not VFlow.Modules then
    VFlow.Modules = {}
end

VFlow.Modules.Buffs = {
    renderContent = renderContent,

    addCustomGroup = function(groupName)
        table.insert(db.customGroups, {
            name = groupName,
            config = getDefaultGroupConfig()
        })
        VFlow.Store.set(MODULE_KEY, "customGroups", db.customGroups)
        return #db.customGroups
    end,

    getCustomGroups = function()
        return db.customGroups
    end,
}
