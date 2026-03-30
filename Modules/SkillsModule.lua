--[[ Core 依赖：
  - Core/SkillGroups.lua：重要/效能/自定义技能分组布局与容器
  - Core/CooldownStyle.lua：监听本模块配置并应用冷却管理器样式与布局
  - Core/StyleApply.lua：技能遮罩与 hideBuffCooldownOverlay 时的冷却驱动
  - Core/SkillScanner.lua：维护 State.trackedSkills（本模块技能列表数据源，只读）
]]

-- =========================================================
-- SECTION 1: 模块注册
-- =========================================================

local VFlow = _G.VFlow
if not VFlow then return end
local L = VFlow.L

local MODULE_KEY = "VFlow.Skills"

VFlow.registerModule(MODULE_KEY, {
    name = L["Skill Monitor"],
    description = L["Skill cooldown tracking"],
})

-- =========================================================
-- SECTION 2: 常量
-- =========================================================

local UI_LIMITS = {
    SIZE = { min = 20, max = 100, step = 1 },
    SPACING = { min = 0, max = 20, step = 1 },
    POSITION = { min = -2000, max = 2000, step = 1 },
    MAX_ICONS_PER_ROW = { min = 1, max = 20, step = 1 },
}

local GROW_DIRECTION_OPTIONS = {
    { L["Grow up"], "up" },
    { L["Grow down"], "down" },
}

local ROW_ANCHOR_OPTIONS = {
    { L["Left-aligned"], "left" },
    { L["Center"], "center" },
    { L["Right-aligned"], "right" },
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

-- =========================================================
-- SECTION 3: 默认配置
-- =========================================================

-- 单个技能组的默认配置
local function getDefaultGroupConfig()
    return {
        growDirection = "down",
        maxIconsPerRow = 8,
        fixedRowLengthByLimit = false,
        rowAnchor = "center",
        iconWidth = 35,
        iconHeight = 35,
        secondRowIconWidth = 35,
        secondRowIconHeight = 35,
        spacingX = 2,
        spacingY = 2,
        showKeybind = false,
        vertical = false,
        spellIDs = {},
        anchorFrame = "uiparent",
        relativePoint = "CENTER",
        playerAnchorPosition = "BOTTOMLEFT",
        x = 0,
        y = 0,
        _dataVersion = 0,
        showOnlyValid = false,
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
        keybindFont = {
            size = 8,
            font = "默认",
            outline = "OUTLINE",
            color = { r = 0.8, g = 0.8, b = 0.8, a = 1 },
            position = "TOPRIGHT",
            offsetX = 0,
            offsetY = 0,
        },
        cooldownMaskColor = { r = 0, g = 0, b = 0, a = 0.7 },
        chargeRechargeMaskColor = { r = 0, g = 0, b = 0, a = 0 },
        buffMaskColor = { r = 1, g = 0.95, b = 0.57, a = 0.7 },
        hideBuffCooldownOverlay = false,
    }
end

local defaults = {
    importantSkills = getDefaultGroupConfig(),
    efficiencySkills = (function()
        local config = getDefaultGroupConfig()
        config.iconWidth = 25
        config.iconHeight = 25
        config.secondRowIconWidth = 25
        config.secondRowIconHeight = 25
        config.cooldownFont.size = 12
        config.stackFont.size = 10
        config.stackFont.offsetY = -4
        config.keybindFont.size = 6
        return config
    end)(),
    customGroups = {},
}

local db = VFlow.getDB(MODULE_KEY, defaults)
local Utils = VFlow.Utils

-- =========================================================
-- SECTION 4: 数据源函数
-- =========================================================

local function getAvailableSkills(groupConfig, groupIndex)
    local trackedSkills = VFlow.State.get("trackedSkills") or {}

    if not groupConfig.spellIDs then
        groupConfig.spellIDs = {}
    end

    -- 计算哪些技能已被其他组占用
    local usedSkills = {}
    for i, group in ipairs(db.customGroups) do
        if i ~= groupIndex then
            for spellID in pairs(group.config.spellIDs or {}) do
                usedSkills[spellID] = i
            end
        end
    end

    -- 可用技能列表（未被其他组占用）
    local availableSkills = {}
    for spellID, skillInfo in pairs(trackedSkills) do
        if not usedSkills[spellID] and not groupConfig.spellIDs[spellID] then
            table.insert(availableSkills, skillInfo)
        end
    end
    Utils.sortByName(availableSkills)

    return availableSkills
end

local function getCurrentSkills(groupConfig)
    local trackedSkills = VFlow.State.get("trackedSkills") or {}
    local showOnlyValid = groupConfig.showOnlyValid

    local currentSkills = {}
    for spellID in pairs(groupConfig.spellIDs or {}) do
        if trackedSkills[spellID] then
            table.insert(currentSkills, trackedSkills[spellID])
        elseif not showOnlyValid then
            table.insert(currentSkills, Utils.placeholderSpellEntry(spellID))
        end
    end
    Utils.sortByName(currentSkills)

    return currentSkills
end

-- =========================================================
-- SECTION 5: 布局构建器
-- =========================================================

local mergeLayouts = Utils.mergeLayouts

-- 自定义组：技能选择器
local function buildCustomSkillSelector(groupConfig, options)
    return {
        { type = "subtitle", text = L["Skill Selection"], cols = 24 },
        { type = "separator", cols = 24 },

        {
            type = "interactiveText",
            cols = 24,
            text = L["Only skills tracked in {Important skills} can be used. {Click to rescan}. Preview and drag in {Edit mode}."],
            links = {
                [L["Important skills"]] = function()
                    VFlow.openCooldownManager()
                end,
                [L["Click to rescan"]] = function()
                    if VFlow.SkillScanner then
                        VFlow.SkillScanner.scan()
                    end
                    Utils.bumpCustomGroupsDataVersion(MODULE_KEY, db.customGroups)
                end,
                [L["Edit mode"]] = function()
                    VFlow.toggleSystemEditMode()
                end,
            }
        },
        { type = "spacer", height = 10, cols = 24 },

        { type = "description", text = L["Available skills (click to add):"], cols = 24 },
        { type = "spacer", height = 5, cols = 24 },

        {
            type = "for",
            cols = 2,
            dependsOn = { "spellIDs", "_dataVersion" },
            dataSource = function()
                return getAvailableSkills(groupConfig, options.groupIndex)
            end,
            template = {
                type = "iconButton",
                icon = function(skillInfo) return skillInfo.icon end,
                size = 40,
                tooltip = function(skillInfo)
                    return function(tooltip)
                        tooltip:SetSpellByID(skillInfo.spellID)
                        tooltip:AddLine("|cff00ff00" .. L["Click to add to current group"] .. "|r", 1, 1, 1)
                    end
                end,
                onClick = function(skillInfo)
                    groupConfig.spellIDs[skillInfo.spellID] = true
                    local configPath = "customGroups." .. options.groupIndex .. ".config"
                    VFlow.Store.set(MODULE_KEY, configPath .. ".spellIDs", groupConfig.spellIDs)
                end,
            }
        },

        { type = "spacer", height = 10, cols = 24 },
        { type = "description", text = L["Current group skills (click to remove):"], cols = 24 },
        { type = "checkbox", key = "showOnlyValid", label = L["Show valid only"], cols = 24 },

        {
            type = "for",
            cols = 2,
            dependsOn = { "spellIDs", "_dataVersion", "showOnlyValid" },
            dataSource = function()
                return getCurrentSkills(groupConfig)
            end,
            template = {
                type = "iconButton",
                icon = function(skillInfo) return skillInfo.icon end,
                size = 40,
                tooltip = function(skillInfo)
                    return function(tooltip)
                        tooltip:SetSpellByID(skillInfo.spellID)
                        if skillInfo.isMissing then
                            tooltip:AddLine(" ")
                            tooltip:AddLine("|cffff0000" .. L["[WARNING] Spell not available or not tracked in Cooldown Manager"] .. "|r")
                            tooltip:AddLine(" ")
                        end
                        tooltip:AddLine("|cffff0000" .. L["Click to remove from current group"] .. "|r", 1, 1, 1)
                    end
                end,
                onClick = function(skillInfo)
                    groupConfig.spellIDs[skillInfo.spellID] = nil
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

        -- 自定义组：技能选择器
        options.isCustom and buildCustomSkillSelector(groupConfig, options),

        -- 基础设置
        {
            { type = "subtitle", text = L["Base Settings"], cols = 24 },
            { type = "separator", cols = 24 },
            {
                type = "dropdown",
                key = "growDirection",
                label = L["Layout direction"],
                cols = 12,
                items = GROW_DIRECTION_OPTIONS
            },
        },

        -- 自定义组：垂直布局
        options.isCustom and {
            { type = "checkbox", key = "vertical", label = L["Vertical layout"], cols = 24 },
        },

        -- 布局配置
        {
            { type = "slider", key = "maxIconsPerRow", label = L["Max icons per row"],
              min = UI_LIMITS.MAX_ICONS_PER_ROW.min, max = UI_LIMITS.MAX_ICONS_PER_ROW.max, step = 1, cols = 12 },
            { type = "checkbox", key = "fixedRowLengthByLimit", label = L["Fix row length by max icons"], cols = 12 },
            { type = "dropdown", key = "rowAnchor", label = L["Row anchor"], cols = 12, items = ROW_ANCHOR_OPTIONS },
            { type = "slider", key = "spacingX", label = L["Column spacing"],
              min = UI_LIMITS.SPACING.min, max = UI_LIMITS.SPACING.max, step = 1, cols = 12 },
            { type = "slider", key = "spacingY", label = L["Row spacing"],
              min = UI_LIMITS.SPACING.min, max = UI_LIMITS.SPACING.max, step = 1, cols = 12 },
            { type = "spacer", height = 10, cols = 24 },
        },

        -- 图标尺寸
        {
            { type = "subtitle", text = L["Icon dimensions"], cols = 24 },
            { type = "separator", cols = 24 },
            { type = "slider", key = "iconWidth", label = L["Icon width"],
              min = UI_LIMITS.SIZE.min, max = UI_LIMITS.SIZE.max, step = 1, cols = 12 },
            { type = "slider", key = "iconHeight", label = L["Icon height"],
              min = UI_LIMITS.SIZE.min, max = UI_LIMITS.SIZE.max, step = 1, cols = 12 },
            { type = "slider", key = "secondRowIconWidth", label = L["Second row icon width"],
              min = UI_LIMITS.SIZE.min, max = UI_LIMITS.SIZE.max, step = 1, cols = 12 },
            { type = "slider", key = "secondRowIconHeight", label = L["Second row icon height"],
              min = UI_LIMITS.SIZE.min, max = UI_LIMITS.SIZE.max, step = 1, cols = 12 },
            { type = "spacer", height = 10, cols = 24 },
        },

        -- 遮罩层
        {
            { type = "spacer", height = 10, cols = 24 },
            { type = "subtitle", text = L["Mask Config"], cols = 24 },
            { type = "separator", cols = 24 },
            {
                type = "checkbox",
                key = "hideBuffCooldownOverlay",
                label = L["Show spell cooldown only (hide buff duration on swipe)"],
                cols = 24,
            },
            {
                type = "description",
                text = L["When a spell has a linked buff, the game may show the buff duration on the cooldown swipe. This option keeps the swipe and timer on the spell cooldown instead. Buff mask color below does not apply while this is on."],
                cols = 24,
            },
            { type = "colorPicker", key = "cooldownMaskColor", label = L["Normal cooldown mask color"], hasAlpha = true, cols = 12 },
            {
                type = "if",
                dependsOn = "hideBuffCooldownOverlay",
                condition = function(cfg) return cfg.hideBuffCooldownOverlay == true end,
                children = {
                    { type = "colorPicker", key = "chargeRechargeMaskColor", label = L["Charge recharge mask color"], hasAlpha = true, cols = 12 },
                },
            },
            {
                type = "if",
                dependsOn = "hideBuffCooldownOverlay",
                condition = function(cfg) return cfg.hideBuffCooldownOverlay ~= true end,
                children = {
                    { type = "colorPicker", key = "buffMaskColor", label = L["Buff mask color"], hasAlpha = true, cols = 12 },
                },
            },
        },

        -- 键位显示
        {
            { type = "subtitle", text = L["Keybind display"], cols = 24 },
            { type = "separator", cols = 24 },
            { type = "checkbox", key = "showKeybind", label = L["Show keybind"], cols = 12 },
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
            { type = "description", text = L["Tip: Drag in Edit Mode to change position"], cols = 24 },
        },

        -- 字体设置
        {
            { type = "spacer", height = 10, cols = 24 },
            Grid.fontGroup("stackFont", L["Stack text style"]),
            { type = "spacer", height = 10, cols = 24 },
            Grid.fontGroup("cooldownFont", L["Cooldown text style"]),
            { type = "spacer", height = 10, cols = 24 },
            Grid.fontGroup("keybindFont", L["Keybind text style"]),
        }
    )

    if options.isCustom then
        local configPath = "customGroups." .. options.groupIndex .. ".config"
        Grid.render(container, layout, groupConfig, MODULE_KEY, configPath)
    else
        Grid.render(container, layout, groupConfig, MODULE_KEY)
    end
end

local function renderContent(container, menuKey)
    if menuKey == "skill_important" then
        renderGroupConfig(container, db.importantSkills, L["Important Skill Group"])
    elseif menuKey == "skill_efficiency" then
        renderGroupConfig(container, db.efficiencySkills, L["Efficiency Skill Group"])
    elseif menuKey:find("^skill_custom_") then
        local customIndex = tonumber(menuKey:match("skill_custom_(%d+)"))
        if customIndex and db.customGroups[customIndex] then
            local customGroup = db.customGroups[customIndex]
            renderGroupConfig(container, customGroup.config, customGroup.name, {
                isCustom = true,
                groupIndex = customIndex
            })
        else
            local title = VFlow.UI.title(container, L["Custom skill group not found"])
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

VFlow.Modules.Skills = {
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
