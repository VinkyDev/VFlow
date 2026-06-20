--[[ Core 依赖：
  - Core/Buff/BuffGroups.lua：主 BUFF 组与自定义组布局
  - Core/Runtime/Refresh/ViewerRefreshQueue.lua：BUFF 图标刷新合并调度（由 CooldownStyle 注册）
  - Core/Style/CooldownStyle.lua：监听本模块并应用 BUFF 区样式
  - Core/Buff/BuffScanner.lua：维护 State.trackedBuffs（列表数据源，只读）
  - Core/Buff/OtherBuffMonitor.lua：其他BUFF（主动+被动）监控、布局与持续时间解析
  - Core/ManualEntryOrder.lua：主动计时项 entryOrder 归一化（schema: otherBuff）
  例外：ensureDefaultPotionsInitialized 在缺省配置时补全默认药水并落盘（档案级一次写入）。
]]

-- =========================================================
-- SECTION 1: 模块注册
-- =========================================================

local VFlow = _G.VFlow
if not VFlow then return end
local L = VFlow.L

local MODULE_KEY = "VFlow.Buffs"
local ACTIVE_CONFIG_PATH = "trinketPotion"
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

local DEFAULT_PASSIVE_BUFFS = {
    { iconID = 4644003, spellID = 1263318, duration = 10 },
    { iconID = 7636702, spellID = 1266687, duration = 12, hasStacks = true },
}

local BLOODLUST_ICON_PRESETS = {
    { spellID = 2825 },
    { spellID = 32182 },
    { spellID = 80353 },
    { spellID = 90355 },
}

local BLOODLUST_ICON_SELECT_COLOR = { 0.2, 1, 0.2, 1 }

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

-- 其他BUFF：主动部分默认配置（存储键 trinketPotion，含布局与样式）
local function getActiveBuffDefaults()
    local config = getDefaultGroupConfig()
    config.vertical = true
    config.width = 35
    config.height = 35
    config.x = 100
    config.y = 0
    config.autoTrinkets = true
    config.monitorBloodlust = true
    config.bloodlustIconPreset = 2825
    config.bloodlustUseCustomIcon = false
    config.bloodlustCustomIconID = ""
    config.itemIDs = {}
    config.itemDurations = {}
    config.spellIDs = {}
    config.spellDurations = {}
    config.entryOrder = {}
    config.defaultPotionsInitialized = false
    config.anchorFrame = "uiparent"
    config.relativePoint = "CENTER"
    config.playerAnchorPosition = "BOTTOMLEFT"

    return config
end

-- 其他BUFF：被动部分默认配置（存储键 passiveBuff，仅监控数据）
local function getPassiveBuffDataDefaults()
    return {
        spellIDs = {},
        iconIDs = {},
        spellDurations = {},
        hasStacks = {},
        defaultPassiveInitialized = false,
    }
end

local defaults = {
    buffMonitor = getDefaultGroupConfig(),
    trinketPotion = getActiveBuffDefaults(),
    passiveBuff = getPassiveBuffDataDefaults(),
    customGroups = {},
}

local db = VFlow.getDB(MODULE_KEY, defaults)

local timedEntryReorder = VFlow.ManualEntryReorder and VFlow.ManualEntryReorder.create()

local function bumpActiveDataVersion(cfg)
    cfg._dataVersion = (cfg._dataVersion or 0) + 1
    VFlow.Store.set(MODULE_KEY, ACTIVE_CONFIG_PATH .. "._dataVersion", cfg._dataVersion)
end

local function persistActiveEntryOrder(cfg)
    if VFlow.OtherBuffManualOrder and VFlow.OtherBuffManualOrder.Ensure then
        VFlow.OtherBuffManualOrder.Ensure(cfg)
    end
    VFlow.Store.set(MODULE_KEY, ACTIVE_CONFIG_PATH .. ".entryOrder", cfg.entryOrder)
end

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
    if VFlow.OtherBuffManualOrder and VFlow.OtherBuffManualOrder.Ensure then
        VFlow.OtherBuffManualOrder.Ensure(config)
    end
    VFlow.Store.set(MODULE_KEY, "trinketPotion.itemIDs", config.itemIDs)
    VFlow.Store.set(MODULE_KEY, "trinketPotion.itemDurations", config.itemDurations)
    VFlow.Store.set(MODULE_KEY, "trinketPotion.entryOrder", config.entryOrder)
    VFlow.Store.set(MODULE_KEY, "trinketPotion.defaultPotionsInitialized", true)
end

ensureDefaultPotionsInitialized()

local function ensureDefaultPassiveInitialized()
    local config = db.passiveBuff
    if not config or config.defaultPassiveInitialized then
        return
    end

    config.spellIDs = config.spellIDs or {}
    config.iconIDs = config.iconIDs or {}
    config.spellDurations = config.spellDurations or {}
    config.hasStacks = config.hasStacks or {}

    for _, entry in ipairs(DEFAULT_PASSIVE_BUFFS) do
        if config.spellIDs[entry.spellID] == nil then
            config.spellIDs[entry.spellID] = true
            config.iconIDs[entry.spellID] = entry.iconID
            config.spellDurations[entry.spellID] = entry.duration
            if entry.hasStacks then
                config.hasStacks[entry.spellID] = true
            end
        end
    end

    config.defaultPassiveInitialized = true
    VFlow.Store.set(MODULE_KEY, "passiveBuff.spellIDs", config.spellIDs)
    VFlow.Store.set(MODULE_KEY, "passiveBuff.iconIDs", config.iconIDs)
    VFlow.Store.set(MODULE_KEY, "passiveBuff.spellDurations", config.spellDurations)
    VFlow.Store.set(MODULE_KEY, "passiveBuff.hasStacks", config.hasStacks)
    VFlow.Store.set(MODULE_KEY, "passiveBuff.defaultPassiveInitialized", true)
end

ensureDefaultPassiveInitialized()

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

local function renderOtherBuffConfig(container, activeCfg, passiveCfg)
    local Grid = VFlow.Grid
    Utils.applyDefaults(activeCfg, getActiveBuffDefaults())
    Utils.applyDefaults(passiveCfg, getPassiveBuffDataDefaults())

    if timedEntryReorder then
        timedEntryReorder.clearUnlessPath(ACTIVE_CONFIG_PATH)
    end

    if not activeCfg._inputItemID then activeCfg._inputItemID = "" end
    if not activeCfg._inputItemDuration then activeCfg._inputItemDuration = "" end
    if not activeCfg._inputSpellID then activeCfg._inputSpellID = "" end
    if not activeCfg._inputSpellDuration then activeCfg._inputSpellDuration = "" end
    if not activeCfg._passiveInputIconID then activeCfg._passiveInputIconID = "" end
    if not activeCfg._passiveInputBuffID then activeCfg._passiveInputBuffID = "" end
    if not activeCfg._passiveInputDuration then activeCfg._passiveInputDuration = "" end
    if activeCfg._passiveInputHasStacks == nil then activeCfg._passiveInputHasStacks = false end

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

        local resolved = VFlow.OtherBuffMonitor and VFlow.OtherBuffMonitor.resolveItemMonitorEntry
            and VFlow.OtherBuffMonitor.resolveItemMonitorEntry(itemID, manualDuration)
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
        persistActiveEntryOrder(cfg)
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

        local resolved = VFlow.OtherBuffMonitor and VFlow.OtherBuffMonitor.resolveSpellMonitorEntry
            and VFlow.OtherBuffMonitor.resolveSpellMonitorEntry(spellID, manualDuration)
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
        persistActiveEntryOrder(cfg)
        VFlow.Store.set(MODULE_KEY, "trinketPotion.spellIDs", cfg.spellIDs)
        VFlow.Store.set(MODULE_KEY, "trinketPotion.spellDurations", cfg.spellDurations)
        cfg._inputSpellID = ""
        cfg._inputSpellDuration = ""
        VFlow.Store.set(MODULE_KEY, "trinketPotion._inputSpellID", "")
        VFlow.Store.set(MODULE_KEY, "trinketPotion._inputSpellDuration", "")
        print("|cff00ff00VFlow:|r " .. string.format(L["Added spell %d (duration: %d sec)"], spellID, resolved.duration))
    end

    local function addManualPassive()
        local iconIDText = activeCfg._passiveInputIconID or ""
        local buffIDText = activeCfg._passiveInputBuffID or ""
        local durationText = activeCfg._passiveInputDuration or ""

        if iconIDText == "" then
            print("|cffff0000VFlow:|r " .. L["Please enter icon ID"])
            return
        end
        if buffIDText == "" then
            print("|cffff0000VFlow:|r " .. L["Please enter spell ID"])
            return
        end
        if durationText == "" then
            print("|cffff0000VFlow:|r " .. L["Please enter a valid duration"])
            return
        end

        local iconID = tonumber(iconIDText)
        local spellID = tonumber(buffIDText)
        local duration = tonumber(durationText)

        if not iconID or iconID <= 0 then
            print("|cffff0000VFlow:|r " .. L["Invalid icon ID"])
            return
        end
        if not spellID or spellID <= 0 then
            print("|cffff0000VFlow:|r " .. L["Invalid spell ID"])
            return
        end
        if not duration or duration <= 0 then
            print("|cffff0000VFlow:|r " .. L["Please enter a valid duration"])
            return
        end
        if passiveCfg.spellIDs[spellID] then
            print("|cffff0000VFlow:|r " .. L["BUFF already added"])
            return
        end

        passiveCfg.spellIDs[spellID] = true
        passiveCfg.iconIDs[spellID] = iconID
        passiveCfg.spellDurations[spellID] = duration
        passiveCfg.hasStacks = passiveCfg.hasStacks or {}
        if activeCfg._passiveInputHasStacks then
            passiveCfg.hasStacks[spellID] = true
        else
            passiveCfg.hasStacks[spellID] = nil
        end
        VFlow.Store.set(MODULE_KEY, "passiveBuff.spellIDs", passiveCfg.spellIDs)
        VFlow.Store.set(MODULE_KEY, "passiveBuff.iconIDs", passiveCfg.iconIDs)
        VFlow.Store.set(MODULE_KEY, "passiveBuff.spellDurations", passiveCfg.spellDurations)
        VFlow.Store.set(MODULE_KEY, "passiveBuff.hasStacks", passiveCfg.hasStacks)
        activeCfg._passiveInputIconID = ""
        activeCfg._passiveInputBuffID = ""
        activeCfg._passiveInputDuration = ""
        activeCfg._passiveInputHasStacks = false
        VFlow.Store.set(MODULE_KEY, "trinketPotion._passiveInputIconID", "")
        VFlow.Store.set(MODULE_KEY, "trinketPotion._passiveInputBuffID", "")
        VFlow.Store.set(MODULE_KEY, "trinketPotion._passiveInputDuration", "")
        VFlow.Store.set(MODULE_KEY, "trinketPotion._passiveInputHasStacks", false)
        activeCfg._dataVersion = (activeCfg._dataVersion or 0) + 1
        VFlow.Store.set(MODULE_KEY, "trinketPotion._dataVersion", activeCfg._dataVersion)
        local stackNote = passiveCfg.hasStacks[spellID] and (" (" .. L["Has stacks"] .. ")") or ""
        print("|cff00ff00VFlow:|r " .. string.format(L["Added passive BUFF %d (duration: %d sec)"], spellID, duration) .. stackNote)
    end

    local layout = mergeLayouts(
        {
            { type = "title", text = L["Other BUFF"], cols = 24 },
            { type = "separator", cols = 24 },
        },
        {
            {
                type = "interactiveText",
                cols = 24,
                text = L["Other BUFF overview"],
                links = {
                    [L["Edit mode"]] = function()
                        VFlow.toggleSystemEditMode()
                    end,
                },
            },
            { type = "spacer", height = 12, cols = 24 },
        },
        {
            { type = "subtitle", text = L["Active BUFF"], cols = 24 },
            { type = "separator", cols = 24 },
            { type = "checkbox", key = "autoTrinkets", label = L["Auto-detect trinkets (slot 13/14)"], cols = 12, compact = true },
            { type = "checkbox", key = "monitorBloodlust", label = L["Monitor bloodlust"], cols = 12, compact = true },
            {
                type = "if",
                dependsOn = "monitorBloodlust",
                condition = function(cfg) return cfg.monitorBloodlust end,
                children = {
                    {
                        type = "for",
                        cols = 2,
                        dependsOn = { "monitorBloodlust", "bloodlustIconPreset", "bloodlustUseCustomIcon" },
                        dataSource = function()
                            return BLOODLUST_ICON_PRESETS
                        end,
                        template = {
                            type = "iconButton",
                            size = 32,
                            icon = function(data)
                                local spellInfo = C_Spell.GetSpellInfo(data.spellID)
                                return (spellInfo and spellInfo.iconID) or 134400
                            end,
                            borderColor = function(data)
                                if activeCfg.bloodlustUseCustomIcon then
                                    return nil
                                end
                                if (activeCfg.bloodlustIconPreset or 2825) == data.spellID then
                                    return BLOODLUST_ICON_SELECT_COLOR
                                end
                            end,
                            tooltip = function(data)
                                return function(tooltip)
                                    tooltip:SetSpellByID(data.spellID)
                                    tooltip:AddLine(" ")
                                    tooltip:AddLine("|cff00ff00" .. L["Click to select icon"] .. "|r", 1, 1, 1)
                                end
                            end,
                            onClick = function(data)
                                activeCfg.bloodlustUseCustomIcon = false
                                activeCfg.bloodlustIconPreset = data.spellID
                                VFlow.Store.set(MODULE_KEY, "trinketPotion.bloodlustUseCustomIcon", false)
                                VFlow.Store.set(MODULE_KEY, "trinketPotion.bloodlustIconPreset", data.spellID)
                            end,
                        },
                    },
                    { type = "checkbox", key = "bloodlustUseCustomIcon", label = L["Use custom icon ID"], cols = 8, compact = true },
                    {
                        type = "if",
                        dependsOn = { "monitorBloodlust", "bloodlustUseCustomIcon" },
                        condition = function(cfg) return cfg.bloodlustUseCustomIcon end,
                        children = {
                            {
                                type = "input",
                                key = "bloodlustCustomIconID",
                                label = L["Icon ID"],
                                cols = 6,
                                numeric = true,
                                labelOnLeft = true,
                            },
                        },
                    },
                },
            },
            { type = "spacer", height = 8, cols = 24 },
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
            {
                type = "description",
                text = L["Click two in sequence to swap; Shift+click to remove; Toggle auto items to hide."],
                cols = 24,
            },
            { type = "spacer", height = 5, cols = 24 },
            {
                type = "for",
                cols = 2,
                dependsOn = {
                    "autoTrinkets",
                    "monitorBloodlust",
                    "bloodlustIconPreset",
                    "bloodlustUseCustomIcon",
                    "bloodlustCustomIconID",
                    "itemIDs",
                    "itemDurations",
                    "spellIDs",
                    "spellDurations",
                    "entryOrder",
                    "_dataVersion",
                },
                dataSource = function()
                    if VFlow.OtherBuffMonitor and VFlow.OtherBuffMonitor.getTimedEntryListItems then
                        return VFlow.OtherBuffMonitor.getTimedEntryListItems()
                    end
                    return {}
                end,
                template = {
                    type = "iconButton",
                    icon = function(itemData) return itemData.icon end,
                    size = 40,
                    borderColor = function(itemData)
                        if not timedEntryReorder or not itemData.orderIndex then
                            return nil
                        end
                        return timedEntryReorder.borderColor(ACTIVE_CONFIG_PATH, itemData.orderIndex)
                    end,
                    tooltip = function(itemData)
                        return function(tooltip)
                            if itemData.entryType == "spell" then
                                tooltip:SetSpellByID(itemData.spellID)
                            elseif itemData.entryType == "bloodlust" then
                                tooltip:AddLine(itemData.name, 1, 1, 1)
                            else
                                tooltip:SetItemByID(itemData.itemID)
                            end
                            tooltip:AddLine(" ")
                            tooltip:AddLine(string.format(L["Duration: %d sec"], itemData.duration), 1, 1, 1)
                            tooltip:AddLine(" ")
                            tooltip:AddLine("|cffaaaaaa" .. L["Left click: click two icons in sequence to swap order"] .. "|r", 1, 1, 1)
                            if itemData.isAuto then
                                if itemData.entryType == "bloodlust" then
                                    tooltip:AddLine("|cff808080" .. L["Bloodlust monitor (cannot delete)"] .. "|r", 1, 1, 1)
                                else
                                    tooltip:AddLine("|cff808080" .. L["Auto-detected trinket (cannot delete)"] .. "|r", 1, 1, 1)
                                end
                            else
                                tooltip:AddLine("|cffff0000" .. L["Shift+Left click: remove from monitor"] .. "|r", 1, 1, 1)
                            end
                        end
                    end,
                    onClick = function(itemData)
                        if not timedEntryReorder then
                            return
                        end
                        timedEntryReorder.handleClick({
                            path = ACTIVE_CONFIG_PATH,
                            orderIndex = itemData.orderIndex,
                            entryOrder = activeCfg.entryOrder,
                            bumpVersion = function()
                                bumpActiveDataVersion(activeCfg)
                            end,
                            onOrderSaved = function()
                                persistActiveEntryOrder(activeCfg)
                            end,
                            onShiftRemove = function()
                                if itemData.isAuto then
                                    if itemData.entryType == "bloodlust" then
                                        print("|cffff0000VFlow:|r " .. L["Bloodlust monitor cannot be deleted. Disable the option."])
                                    else
                                        print("|cffff0000VFlow:|r " .. L["Auto-detected trinket cannot be deleted. Disable auto-detect."])
                                    end
                                    return false
                                end
                                if itemData.entryType == "spell" then
                                    activeCfg.spellIDs[itemData.spellID] = nil
                                    activeCfg.spellDurations[itemData.spellID] = nil
                                    VFlow.Store.set(MODULE_KEY, "trinketPotion.spellIDs", activeCfg.spellIDs)
                                    VFlow.Store.set(MODULE_KEY, "trinketPotion.spellDurations", activeCfg.spellDurations)
                                else
                                    activeCfg.itemIDs[itemData.itemID] = nil
                                    activeCfg.itemDurations[itemData.itemID] = nil
                                    VFlow.Store.set(MODULE_KEY, "trinketPotion.itemIDs", activeCfg.itemIDs)
                                    VFlow.Store.set(MODULE_KEY, "trinketPotion.itemDurations", activeCfg.itemDurations)
                                end
                                persistActiveEntryOrder(activeCfg)
                                return true
                            end,
                        })
                    end,
                },
            },
            { type = "spacer", height = 15, cols = 24 },
        },
        {
            { type = "subtitle", text = L["Passive BUFF"], cols = 24 },
            { type = "separator", cols = 24 },
            { type = "input", key = "_passiveInputIconID", label = L["Icon ID"], cols = 5, numeric = true, labelOnLeft = true },
            { type = "input", key = "_passiveInputBuffID", label = L["BUFF ID"], cols = 5, numeric = true, labelOnLeft = true },
            { type = "input", key = "_passiveInputDuration", label = L["Duration (sec)"], cols = 5, numeric = true, labelOnLeft = true },
            { type = "checkbox", key = "_passiveInputHasStacks", label = L["Has stacks"], cols = 6, compact = true },
            { type = "button", text = L["Add"], cols = 3, onClick = addManualPassive },
            { type = "description", text = L["Stacked passives increment on each trigger and expire per stack after duration"], cols = 24 },
            { type = "spacer", height = 8, cols = 24 },
            { type = "description", text = L["Monitored passive entries (click to delete):"], cols = 24 },
            { type = "spacer", height = 5, cols = 24 },
            {
                type = "for",
                cols = 2,
                dependsOn = { "_dataVersion", "autoTrinkets", "itemIDs", "spellIDs" },
                dataSource = function()
                    local items = {}
                    for spellID in pairs(passiveCfg.spellIDs or {}) do
                        local iconID = passiveCfg.iconIDs and passiveCfg.iconIDs[spellID]
                        local duration = passiveCfg.spellDurations and passiveCfg.spellDurations[spellID] or 0
                        local hasStacks = passiveCfg.hasStacks and passiveCfg.hasStacks[spellID] == true
                        if iconID then
                            local displayName = spellID
                            if VFlow.OtherBuffMonitor and VFlow.OtherBuffMonitor.getPassiveDisplayName then
                                displayName = VFlow.OtherBuffMonitor.getPassiveDisplayName(iconID, spellID)
                            end
                            table.insert(items, {
                                spellID = spellID,
                                iconID = iconID,
                                name = displayName,
                                icon = iconID,
                                duration = duration,
                                hasStacks = hasStacks,
                            })
                        end
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
                            tooltip:AddLine(itemData.name, 1, 1, 1)
                            tooltip:AddLine(L["BUFF ID"] .. ": " .. itemData.spellID, 0.8, 0.8, 0.8)
                            tooltip:AddLine(L["Icon ID"] .. ": " .. itemData.iconID, 0.8, 0.8, 0.8)
                            tooltip:AddLine(" ")
                            tooltip:AddLine(string.format(L["Duration: %d sec"], itemData.duration), 1, 1, 1)
                            if itemData.hasStacks then
                                tooltip:AddLine("|cff00ff00" .. L["Has stacks"] .. "|r", 1, 1, 1)
                            end
                            tooltip:AddLine(" ")
                            tooltip:AddLine("|cffff0000" .. L["Click to delete"] .. "|r", 1, 1, 1)
                        end
                    end,
                    onClick = function(itemData)
                        passiveCfg.spellIDs[itemData.spellID] = nil
                        passiveCfg.iconIDs[itemData.spellID] = nil
                        passiveCfg.spellDurations[itemData.spellID] = nil
                        if passiveCfg.hasStacks then
                            passiveCfg.hasStacks[itemData.spellID] = nil
                        end
                        VFlow.Store.set(MODULE_KEY, "passiveBuff.spellIDs", passiveCfg.spellIDs)
                        VFlow.Store.set(MODULE_KEY, "passiveBuff.iconIDs", passiveCfg.iconIDs)
                        VFlow.Store.set(MODULE_KEY, "passiveBuff.spellDurations", passiveCfg.spellDurations)
                        VFlow.Store.set(MODULE_KEY, "passiveBuff.hasStacks", passiveCfg.hasStacks)
                        activeCfg._dataVersion = (activeCfg._dataVersion or 0) + 1
                        VFlow.Store.set(MODULE_KEY, "trinketPotion._dataVersion", activeCfg._dataVersion)
                    end,
                },
            },
            { type = "spacer", height = 15, cols = 24 },
        },
        {
            { type = "subtitle", text = L["Display and position"], cols = 24 },
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

        {
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

    Grid.render(container, layout, activeCfg, MODULE_KEY, "trinketPotion")
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
    elseif menuKey == "buff_other" then
        renderOtherBuffConfig(container, db.trinketPotion, db.passiveBuff)
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
