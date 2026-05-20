--[[ Core 依赖：
  - Core/Buff/BuffGroups.lua：主 BUFF 组与自定义组布局
  - Core/Runtime/Refresh/ViewerRefreshQueue.lua：BUFF 图标刷新合并调度（由 StyleEngine 注册）
  - Core/Style/StyleEngine.lua：监听本模块并应用 BUFF 区样式
  - Core/Buff/BuffScanner.lua：维护 State.trackedBuffs（列表数据源，只读）
  - Core/Buff/ItemBuffMonitor.lua：计时BUFF监控、物品/技能持续时间解析与列表数据
  例外：ensureDefaultPotionsInitialized 在缺省配置时补全默认药水并落盘（档案级一次写入）。
]]

-- =========================================================
-- SECTION 1: 模块注册
-- =========================================================

local VFlow = _G.VFlow
if not VFlow then return end
local L = VFlow.L

local MODULE_KEY = "VFlow.Buffs"
local ModuleControlConstants = VFlow.ModuleControlConstants

if not ModuleControlConstants.CORE_ENABLED then return end

VFlow.registerModule(MODULE_KEY, {
    name = L["BUFF Monitor"],
    description = L["BUFF tracking"],
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
    { L["Grow from center"], "center" },
    { L["Grow from start"], "start" },
    { L["Grow from end"], "end" },
}

local STANDALONE_ANCHOR_FRAME_OPTIONS = {
    { L["UI parent"], "uiparent" },
    { L["Player frame"], "player" },
    { L["Important skills bar"], "essential" },
    { L["Efficiency skills bar"], "utility" },
}

local RELATIVE_ANCHOR_POINT_OPTIONS = {
    { L["CENTER"], "CENTER" },
    { L["TOP"], "TOP" },
    { L["BOTTOM"], "BOTTOM" },
    { L["LEFT"], "LEFT" },
    { L["RIGHT"], "RIGHT" },
}

local PLAYER_ANCHOR_CORNER_OPTIONS = {
    { L["Top-left"], "TOPLEFT" },
    { L["Top-right"], "TOPRIGHT" },
    { L["Bottom-left"], "BOTTOMLEFT" },
    { L["Bottom-right"], "BOTTOMRIGHT" },
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
        anchorFrame = "uiparent",
        relativePoint = "CENTER",
        playerAnchorPosition = "BOTTOMLEFT",
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

-- 计时BUFF组的默认配置
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
    config.spellIDs = {}
    config.spellDurations = {}
    config.defaultPotionsInitialized = false
    config.anchorFrame = "uiparent"
    config.relativePoint = "CENTER"
    config.playerAnchorPosition = "BOTTOMLEFT"

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

local Utils = VFlow.Utils

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
    Utils.sortByName(availableBuffs)

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
            table.insert(currentBuffs, Utils.placeholderSpellEntry(spellID))
        end
    end
    Utils.sortByName(currentBuffs)

    return currentBuffs
end

-- =========================================================
-- SECTION 5: 布局构建器
-- =========================================================

local mergeLayouts = Utils.mergeLayouts

-- 自定义组：BUFF 选择器
local function buildCustomBuffSelector(groupConfig, options)
    return {
        { type = "subtitle", text = L["BUFF Selection"], cols = 24 },
        { type = "separator", cols = 24 },

        {
            type = "interactiveText",
            cols = 24,
            text = L["Only tracked BUFFs in {Cooldown Manager} can be used. {Click to rescan}. Preview and drag in {Edit mode}."],
            links = {
                [L["Cooldown Manager"]] = function()
                    VFlow.openCooldownManager()
                end,
                [L["Click to rescan"]] = function()
                    if VFlow.BuffScanner then
                        VFlow.BuffScanner.scan()
                    end
                    Utils.bumpCustomGroupsDataVersion(MODULE_KEY, db.customGroups)
                end,
                [L["Edit mode"]] = function()
                    VFlow.toggleSystemEditMode()
                end,
            }
        },
        { type = "spacer", height = 10, cols = 24 },

        { type = "description", text = L["Available BUFFs (click to add):"], cols = 24 },
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
                        tooltip:AddLine("|cff00ff00" .. L["Click to add to current group"] .. "|r", 1, 1, 1)
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
        { type = "description", text = L["Current group BUFFs (click to remove):"], cols = 24 },
        { type = "checkbox", key = "showOnlyValid", label = L["Show valid only"], cols = 24 },

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
                            tooltip:AddLine("|cffff0000" .. L["[WARNING] BUFF not available or not tracked in Cooldown Manager"] .. "|r")
                            tooltip:AddLine(" ")
                        end
                        tooltip:AddLine("|cffff0000" .. L["Click to remove from current group"] .. "|r", 1, 1, 1)
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
    Utils.applyDefaults(groupConfig, getDefaultGroupConfig())

    local layout = mergeLayouts(
        {
            { type = "title", text = groupName, cols = 24 },
            { type = "separator", cols = 24 },
        },

        -- 自定义组：BUFF选择器
        options.isCustom and buildCustomBuffSelector(groupConfig, options),

        -- 基础设置
        {
            { type = "subtitle", text = L["Base Settings"], cols = 24 },
            { type = "separator", cols = 24 },
            { type = "checkbox", key = "dynamicLayout", label = L["Dynamic layout"], cols = 12 },
        },

        options.showVerticalLayoutOption and {
            { type = "checkbox", key = "vertical", label = L["Vertical layout"], cols = 12 },
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
                        label = L["Grow direction"],
                        cols = 12,
                        items = GROW_DIRECTION_OPTIONS
                    },
                }
            },
        },

        -- 尺寸和间距
        {
            { type = "slider", key = "spacingX", label = L["Column spacing"],
              min = UI_LIMITS.SPACING.min, max = UI_LIMITS.SPACING.max, step = 1, cols = 12 },
            { type = "slider", key = "spacingY", label = L["Row spacing"],
              min = UI_LIMITS.SPACING.min, max = UI_LIMITS.SPACING.max, step = 1, cols = 12 },
            { type = "slider", key = "width", label = L["Width"],
              min = UI_LIMITS.SIZE.min, max = UI_LIMITS.SIZE.max, step = 1, cols = 12 },
            { type = "slider", key = "height", label = L["Height"],
              min = UI_LIMITS.SIZE.min, max = UI_LIMITS.SIZE.max, step = 1, cols = 12 },
        },

        -- 自定义组：依附框体与位置
        options.isCustom and {
            { type = "spacer", height = 10, cols = 24 },
            { type = "subtitle", text = L["Position Settings"], cols = 24 },
            { type = "separator", cols = 24 },
            {
                type = "dropdown",
                key = "anchorFrame",
                label = L["Attached frame"],
                cols = 12,
                items = STANDALONE_ANCHOR_FRAME_OPTIONS,
            },
            {
                type = "if",
                dependsOn = "anchorFrame",
                condition = function(cfg) return cfg.anchorFrame == "player" end,
                children = {
                    {
                        type = "dropdown",
                        key = "playerAnchorPosition",
                        label = L["Anchor point"],
                        cols = 12,
                        items = PLAYER_ANCHOR_CORNER_OPTIONS,
                    },
                },
            },
            {
                type = "if",
                dependsOn = "anchorFrame",
                condition = function(cfg)
                    local af = cfg.anchorFrame
                    return af == "uiparent" or af == "essential" or af == "utility"
                end,
                children = {
                    {
                        type = "dropdown",
                        key = "relativePoint",
                        label = L["Anchor point"],
                        cols = 12,
                        items = RELATIVE_ANCHOR_POINT_OPTIONS,
                    },
                },
            },
            {
                type = "if",
                dependsOn = "anchorFrame",
                condition = function(cfg) return cfg.anchorFrame == "player" end,
                children = {
                    { type = "slider", key = "x", label = L["X offset"],
                      min = UI_LIMITS.POSITION.min, max = UI_LIMITS.POSITION.max, step = 1, cols = 12 },
                    { type = "slider", key = "y", label = L["Y offset"],
                      min = UI_LIMITS.POSITION.min, max = UI_LIMITS.POSITION.max, step = 1, cols = 12 },
                },
            },
            {
                type = "if",
                dependsOn = "anchorFrame",
                condition = function(cfg)
                    local af = cfg.anchorFrame
                    return af == "uiparent" or af == "essential" or af == "utility"
                end,
                children = {
                    { type = "slider", key = "x", label = L["X coordinate"],
                      min = UI_LIMITS.POSITION.min, max = UI_LIMITS.POSITION.max, step = 1, cols = 12 },
                    { type = "slider", key = "y", label = L["Y coordinate"],
                      min = UI_LIMITS.POSITION.min, max = UI_LIMITS.POSITION.max, step = 1, cols = 12 },
                },
            },
            {
                type = "interactiveText",
                cols = 24,
                text = L["Recommended to drag and use arrow keys in {Edit mode} to adjust position"],
                links = {
                    [L["Edit mode"]] = function()
                        VFlow.toggleSystemEditMode()
                    end,
                },
            },
        },

        -- 字体设置
        {
            { type = "spacer", height = 10, cols = 24 },
            Grid.fontGroup("stackFont", L["Stack font"]),
            { type = "spacer", height = 10, cols = 24 },
            Grid.fontGroup("cooldownFont", L["Cooldown countdown font"]),
        },

        -- 遮罩层配置
        {
            { type = "spacer", height = 10, cols = 24 },
            { type = "subtitle", text = L["Mask Config"], cols = 24 },
            { type = "separator", cols = 24 },
            { type = "colorPicker", key = "cooldownMaskColor", label = L["Duration mask color"], hasAlpha = true, cols = 12 },
        }
    )

    if options.isCustom then
        local configPath = "customGroups." .. options.groupIndex .. ".config"
        Grid.render(container, layout, groupConfig, MODULE_KEY, configPath)
    else
        Grid.render(container, layout, groupConfig, MODULE_KEY)
    end
end

local function renderTrinketPotionConfig(container, groupConfig)
    local Grid = VFlow.Grid
    Utils.applyDefaults(groupConfig, getTrinketPotionConfig())

    -- 初始化临时字段
    if not groupConfig._inputItemID then groupConfig._inputItemID = "" end
    if not groupConfig._inputItemDuration then groupConfig._inputItemDuration = "" end
    if not groupConfig._inputSpellID then groupConfig._inputSpellID = "" end
    if not groupConfig._inputSpellDuration then groupConfig._inputSpellDuration = "" end

    local function addManualItem(cfg)
        local itemIDText = cfg._inputItemID or ""
        local durationText = cfg._inputItemDuration or ""
        if itemIDText == "" then
            print("|cffff0000VFlow:|r " .. L["Please enter item ID"])
            return
        end

        local itemID = tonumber(itemIDText)
        if not itemID then
            print("|cffff0000VFlow:|r " .. L["Invalid item ID"])
            return
        end
        if cfg.itemIDs[itemID] then
            print("|cffff0000VFlow:|r " .. L["Item already added"])
            return
        end

        local manualDuration = nil
        if durationText ~= "" then
            manualDuration = tonumber(durationText)
            if not manualDuration or manualDuration <= 0 then
                print("|cffff0000VFlow:|r " .. L["Please enter a valid duration"])
                return
            end
        end

        local resolved = VFlow.ItemBuffMonitor and VFlow.ItemBuffMonitor.resolveItemMonitorEntry
            and VFlow.ItemBuffMonitor.resolveItemMonitorEntry(itemID, manualDuration)
        if not resolved then
            print("|cffff0000VFlow:|r " .. L["Invalid item ID"])
            return
        end
        if not resolved.duration or resolved.duration <= 0 then
            print("|cffff9900VFlow:|r " .. L["Cannot parse duration automatically, please enter duration"])
            return
        end

        cfg.itemIDs[itemID] = true
        cfg.itemDurations[itemID] = resolved.duration
        VFlow.Store.set(MODULE_KEY, "trinketPotion.itemIDs", cfg.itemIDs)
        VFlow.Store.set(MODULE_KEY, "trinketPotion.itemDurations", cfg.itemDurations)
        cfg._inputItemID = ""
        cfg._inputItemDuration = ""
        VFlow.Store.set(MODULE_KEY, "trinketPotion._inputItemID", "")
        VFlow.Store.set(MODULE_KEY, "trinketPotion._inputItemDuration", "")
        print("|cff00ff00VFlow:|r " .. string.format(L["Added item %d (duration: %d sec)"], itemID, resolved.duration))
    end

    local function addManualSpell(cfg)
        local spellIDText = cfg._inputSpellID or ""
        local durationText = cfg._inputSpellDuration or ""
        if spellIDText == "" then
            print("|cffff0000VFlow:|r " .. L["Please enter spell ID"])
            return
        end

        local spellID = tonumber(spellIDText)
        if not spellID then
            print("|cffff0000VFlow:|r " .. L["Invalid spell ID"])
            return
        end
        if cfg.spellIDs[spellID] then
            print("|cffff0000VFlow:|r " .. L["Spell already added"])
            return
        end

        local manualDuration = nil
        if durationText ~= "" then
            manualDuration = tonumber(durationText)
            if not manualDuration or manualDuration <= 0 then
                print("|cffff0000VFlow:|r " .. L["Please enter a valid duration"])
                return
            end
        end

        local resolved = VFlow.ItemBuffMonitor and VFlow.ItemBuffMonitor.resolveSpellMonitorEntry
            and VFlow.ItemBuffMonitor.resolveSpellMonitorEntry(spellID, manualDuration)
        if not resolved then
            print("|cffff0000VFlow:|r " .. L["Invalid spell ID"])
            return
        end
        if not resolved.duration or resolved.duration <= 0 then
            print("|cffff9900VFlow:|r " .. L["Cannot parse duration automatically, please enter duration"])
            return
        end

        cfg.spellIDs[spellID] = true
        cfg.spellDurations[spellID] = resolved.duration
        VFlow.Store.set(MODULE_KEY, "trinketPotion.spellIDs", cfg.spellIDs)
        VFlow.Store.set(MODULE_KEY, "trinketPotion.spellDurations", cfg.spellDurations)
        cfg._inputSpellID = ""
        cfg._inputSpellDuration = ""
        VFlow.Store.set(MODULE_KEY, "trinketPotion._inputSpellID", "")
        VFlow.Store.set(MODULE_KEY, "trinketPotion._inputSpellDuration", "")
        print("|cff00ff00VFlow:|r " .. string.format(L["Added spell %d (duration: %d sec)"], spellID, resolved.duration))
    end

    local layout = mergeLayouts(
        -- 标题
        {
            { type = "title", text = L["Trinkets & Potions"], cols = 24 },
            { type = "separator", cols = 24 },
        },

        -- 提示文本
        {
            {
                type = "interactiveText",
                cols = 24,
                text = L["Preview and drag in {Edit mode} to change position"],
                links = {
                    [L["Edit mode"]] = function()
                        VFlow.toggleSystemEditMode()
                    end,
                }
            },
            { type = "spacer", height = 10, cols = 24 },
        },

        -- 计时来源
        {
            { type = "subtitle", text = L["Item monitor"], cols = 24 },
            { type = "separator", cols = 24 },
            { type = "checkbox", key = "autoTrinkets", label = L["Auto-detect trinkets (slot 13/14)"], cols = 24 },
            { type = "spacer", height = 10, cols = 24 },
        },

        -- 手动物品
        {
            { type = "description", text = L["Manual add item:"], cols = 24 },
            { type = "spacer", height = 5, cols = 24 },
            { type = "input", key = "_inputItemID", label = L["Item ID"], cols = 6, numeric = true, labelOnLeft = true },
            { type = "input", key = "_inputItemDuration", label = L["Duration (sec)"], cols = 6, numeric = true, labelOnLeft = true },
            { type = "button", text = L["Add"], cols = 3, onClick = addManualItem },
            { type = "description", text = L["Optional duration (auto-detect if empty)"], cols = 24 },
            { type = "spacer", height = 10, cols = 24 },
        },

        -- 手动技能
        {
            { type = "description", text = L["Manual add spell:"], cols = 24 },
            { type = "spacer", height = 5, cols = 24 },
            { type = "input", key = "_inputSpellID", label = L["Spell ID"], cols = 6, numeric = true, labelOnLeft = true },
            { type = "input", key = "_inputSpellDuration", label = L["Duration (sec)"], cols = 6, numeric = true, labelOnLeft = true },
            { type = "button", text = L["Add"], cols = 3, onClick = addManualSpell },
            { type = "description", text = L["Optional duration (auto-detect if empty)"], cols = 24 },
        },

        -- 已监控的计时项列表
        {
            { type = "spacer", height = 10, cols = 24 },
            { type = "description", text = L["Monitored timed entries (click to delete):"], cols = 24 },
            { type = "spacer", height = 5, cols = 24 },
            {
                type = "for",
                cols = 2,
                dependsOn = { "autoTrinkets", "itemIDs", "itemDurations", "spellIDs", "spellDurations", "_dataVersion" },
                dataSource = function()
                    local items = {}

                    -- 添加自动检测的饰品
                    if groupConfig.autoTrinkets and VFlow.ItemBuffMonitor then
                        local autoItems = VFlow.ItemBuffMonitor.getAutoDetectedItems()
                        for _, itemData in ipairs(autoItems) do
                            local itemName, _, _, _, _, _, _, _, _, itemIcon = C_Item.GetItemInfo(itemData.itemID)
                            table.insert(items, {
                                itemID = itemData.itemID,
                                name = itemName or string.format(L["Item %s"], itemData.itemID),
                                icon = itemIcon or itemData.icon or 134400,
                                duration = itemData.duration or 0,
                                isAuto = true,
                            entryType = "item",
                            })
                        end
                    end

                    -- 添加手动添加的物品
                    for itemID in pairs(groupConfig.itemIDs or {}) do
                        local itemName, _, _, _, _, _, _, _, _, itemIcon = C_Item.GetItemInfo(itemID)
                        table.insert(items, {
                            itemID = itemID,
                            name = itemName or string.format(L["Item %s"], itemID),
                            icon = itemIcon or 134400,
                            duration = groupConfig.itemDurations[itemID] or 0,
                            isAuto = false,
                            entryType = "item",
                        })
                    end

                    -- 添加手动添加的技能
                    for spellID in pairs(groupConfig.spellIDs or {}) do
                        local spellInfo = C_Spell.GetSpellInfo(spellID)
                        table.insert(items, {
                            spellID = spellID,
                            name = (spellInfo and spellInfo.name) or string.format(L["Spell %s"], spellID),
                            icon = (spellInfo and spellInfo.iconID) or 134400,
                            duration = groupConfig.spellDurations[spellID] or 0,
                            isAuto = false,
                            entryType = "spell",
                        })
                    end

                    Utils.sortByName(items)
                    return items
                end,
                template = {
                    type = "iconButton",
                    icon = function(itemData) return itemData.icon end,
                    size = 40,
                    tooltip = function(itemData)
                        return function(tooltip)
                            if itemData.entryType == "spell" then
                                tooltip:SetSpellByID(itemData.spellID)
                            else
                                tooltip:SetItemByID(itemData.itemID)
                            end
                            tooltip:AddLine(" ")
                            tooltip:AddLine(string.format(L["Duration: %d sec"], itemData.duration), 1, 1, 1)
                            tooltip:AddLine(" ")
                            if itemData.isAuto then
                                tooltip:AddLine("|cff808080" .. L["Auto-detected trinket (cannot delete)"] .. "|r", 1, 1, 1)
                            else
                                tooltip:AddLine("|cffff0000" .. L["Click to delete"] .. "|r", 1, 1, 1)
                            end
                        end
                    end,
                    onClick = function(itemData)
                        if itemData.isAuto then
                            print("|cffff0000VFlow:|r " .. L["Auto-detected trinket cannot be deleted. Disable auto-detect."])
                            return
                        end

                        if itemData.entryType == "spell" then
                            groupConfig.spellIDs[itemData.spellID] = nil
                            groupConfig.spellDurations[itemData.spellID] = nil
                            VFlow.Store.set(MODULE_KEY, "trinketPotion.spellIDs", groupConfig.spellIDs)
                            VFlow.Store.set(MODULE_KEY, "trinketPotion.spellDurations", groupConfig.spellDurations)
                        else
                            groupConfig.itemIDs[itemData.itemID] = nil
                            groupConfig.itemDurations[itemData.itemID] = nil
                            VFlow.Store.set(MODULE_KEY, "trinketPotion.itemIDs", groupConfig.itemIDs)
                            VFlow.Store.set(MODULE_KEY, "trinketPotion.itemDurations", groupConfig.itemDurations)
                        end
                    end,
                }
            },
            { type = "spacer", height = 5, cols = 24 },
        },

        -- 基础设置
        {
            { type = "subtitle", text = L["Base Settings"], cols = 24 },
            { type = "separator", cols = 24 },
            { type = "checkbox", key = "dynamicLayout", label = L["Dynamic layout"], cols = 12 },
            { type = "checkbox", key = "vertical", label = L["Vertical layout"], cols = 12 },
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
                        label = L["Grow direction"],
                        cols = 12,
                        items = GROW_DIRECTION_OPTIONS
                    },
                }
            },
        },

        -- 尺寸和间距
        {
            { type = "slider", key = "spacingX", label = L["Column spacing"],
              min = UI_LIMITS.SPACING.min, max = UI_LIMITS.SPACING.max, step = 1, cols = 12 },
            { type = "slider", key = "spacingY", label = L["Row spacing"],
              min = UI_LIMITS.SPACING.min, max = UI_LIMITS.SPACING.max, step = 1, cols = 12 },
            { type = "slider", key = "width", label = L["Width"],
              min = UI_LIMITS.SIZE.min, max = UI_LIMITS.SIZE.max, step = 1, cols = 12 },
            { type = "slider", key = "height", label = L["Height"],
              min = UI_LIMITS.SIZE.min, max = UI_LIMITS.SIZE.max, step = 1, cols = 12 },
            { type = "spacer", height = 10, cols = 24 },
        },

        -- 依附框体与位置
        {
            { type = "subtitle", text = L["Position Settings"], cols = 24 },
            { type = "separator", cols = 24 },
            {
                type = "dropdown",
                key = "anchorFrame",
                label = L["Attached frame"],
                cols = 12,
                items = STANDALONE_ANCHOR_FRAME_OPTIONS,
            },
            {
                type = "if",
                dependsOn = "anchorFrame",
                condition = function(cfg) return cfg.anchorFrame == "player" end,
                children = {
                    {
                        type = "dropdown",
                        key = "playerAnchorPosition",
                        label = L["Anchor point"],
                        cols = 12,
                        items = PLAYER_ANCHOR_CORNER_OPTIONS,
                    },
                },
            },
            {
                type = "if",
                dependsOn = "anchorFrame",
                condition = function(cfg)
                    local af = cfg.anchorFrame
                    return af == "uiparent" or af == "essential" or af == "utility"
                end,
                children = {
                    {
                        type = "dropdown",
                        key = "relativePoint",
                        label = L["Anchor point"],
                        cols = 12,
                        items = RELATIVE_ANCHOR_POINT_OPTIONS,
                    },
                },
            },
            {
                type = "if",
                dependsOn = "anchorFrame",
                condition = function(cfg) return cfg.anchorFrame == "player" end,
                children = {
                    { type = "slider", key = "x", label = L["X offset"],
                      min = UI_LIMITS.POSITION.min, max = UI_LIMITS.POSITION.max, step = 1, cols = 12 },
                    { type = "slider", key = "y", label = L["Y offset"],
                      min = UI_LIMITS.POSITION.min, max = UI_LIMITS.POSITION.max, step = 1, cols = 12 },
                },
            },
            {
                type = "if",
                dependsOn = "anchorFrame",
                condition = function(cfg)
                    local af = cfg.anchorFrame
                    return af == "uiparent" or af == "essential" or af == "utility"
                end,
                children = {
                    { type = "slider", key = "x", label = L["X coordinate"],
                      min = UI_LIMITS.POSITION.min, max = UI_LIMITS.POSITION.max, step = 1, cols = 12 },
                    { type = "slider", key = "y", label = L["Y coordinate"],
                      min = UI_LIMITS.POSITION.min, max = UI_LIMITS.POSITION.max, step = 1, cols = 12 },
                },
            },
            {
                type = "interactiveText",
                cols = 24,
                text = L["Recommended to drag and use arrow keys in {Edit mode} to adjust position"],
                links = {
                    [L["Edit mode"]] = function()
                        VFlow.toggleSystemEditMode()
                    end,
                },
            },
            { type = "spacer", height = 10, cols = 24 },
        },

        -- 字体设置
        {
            Grid.fontGroup("cooldownFont", L["Cooldown countdown font"]),
        },

        -- 遮罩层配置
        {
            { type = "spacer", height = 10, cols = 24 },
            { type = "subtitle", text = L["Mask Config"], cols = 24 },
            { type = "separator", cols = 24 },
            { type = "colorPicker", key = "cooldownMaskColor", label = L["Duration mask color"], hasAlpha = true, cols = 12 },
        }
    )

    Grid.render(container, layout, groupConfig, MODULE_KEY, "trinketPotion")
end

local function renderContent(container, menuKey)
    if menuKey == "buff_settings" then
        local sharedSettings = VFlow.Modules and VFlow.Modules.SharedSettings
        if sharedSettings and sharedSettings.renderBuffSettings then
            sharedSettings.renderBuffSettings(container)
        else
            local title = VFlow.UI.title(container, L["BUFF Settings"])
            title:SetPoint("TOPLEFT", 10, -10)
        end
    elseif menuKey == "buff_monitor" then
        renderGroupConfig(container, db.buffMonitor, L["Main BUFF Group"], {
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
            local title = VFlow.UI.title(container, L["Custom BUFF group not found"])
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
