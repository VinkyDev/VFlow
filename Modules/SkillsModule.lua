-- =========================================================
-- SECTION 1: 模块注册
-- =========================================================

local VFlow = _G.VFlow
if not VFlow then return end

local MODULE_KEY = "VFlow.Skills"

VFlow.registerModule(MODULE_KEY, {
    name = "技能监控",
    description = "技能冷却追踪",
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
    { "向上增长", "up" },
    { "向下增长", "down" },
}

local ROW_ANCHOR_OPTIONS = {
    { "左对齐", "left" },
    { "居中", "center" },
    { "右对齐", "right" },
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
        buffMaskColor = { r = 1, g = 0.95, b = 0.57, a = 0.7 },
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
    table.sort(availableSkills, function(a, b) return a.name < b.name end)

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
            local spellInfo = C_Spell.GetSpellInfo(spellID)
            local name = spellInfo and spellInfo.name
            local icon = spellInfo and spellInfo.iconID
            table.insert(currentSkills, {
                spellID = spellID,
                name = name or ("未知技能 " .. spellID),
                icon = icon or 134400,
                isMissing = true
            })
        end
    end
    table.sort(currentSkills, function(a, b) return a.name < b.name end)

    return currentSkills
end

-- =========================================================
-- SECTION 5: 布局构建器
-- =========================================================

local mergeLayouts = VFlow.LayoutUtils.mergeLayouts

-- 自定义组的技能选择器（大块layout，值得拆分）
local function buildCustomSkillSelector(groupConfig, options)
    return {
        { type = "subtitle", text = "技能选择", cols = 24 },
        { type = "separator", cols = 24 },

        {
            type = "interactiveText",
            cols = 24,
            text = "仅可使用{重要技能冷却}中追踪的技能，{点我重新扫描}。可在{编辑模式}中预览和拖拽修改位置",
            links = {
                ["重要技能冷却"] = function()
                    if EditModeManagerFrame and EditModeManagerFrame:IsShown() then
                        HideUIPanel(EditModeManagerFrame)
                    end
                    if CooldownViewerSettings then
                        CooldownViewerSettings:ShowUIPanel(false)
                    end
                end,
                ["点我重新扫描"] = function()
                    if VFlow.SkillScanner then
                        VFlow.SkillScanner.scan()
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

        { type = "description", text = "可用技能（点击添加）:", cols = 24 },
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
                        tooltip:AddLine("|cff00ff00点击添加到当前组|r", 1, 1, 1)
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
        { type = "description", text = "当前组技能（点击移除）:", cols = 24 },
        { type = "checkbox", key = "showOnlyValid", label = "仅显示有效", cols = 24 },

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
                            tooltip:AddLine("|cffff0000[警告] 该技能不可用或未在冷却管理器中追踪|r")
                            tooltip:AddLine(" ")
                        end
                        tooltip:AddLine("|cffff0000点击从当前组移除|r", 1, 1, 1)
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

    -- 一次性mergeLayouts，使用短路求值处理条件
    local layout = mergeLayouts(
        -- 标题
        {
            { type = "title", text = groupName, cols = 24 },
            { type = "separator", cols = 24 },
        },

        -- 自定义组：技能选择器
        options.isCustom and buildCustomSkillSelector(groupConfig, options),

        -- 基础设置
        {
            { type = "subtitle", text = "基础设置", cols = 24 },
            { type = "separator", cols = 24 },
            {
                type = "dropdown",
                key = "growDirection",
                label = "布局方向",
                cols = 12,
                items = GROW_DIRECTION_OPTIONS
            },
        },

        -- 自定义组：垂直布局
        options.isCustom and {
            { type = "checkbox", key = "vertical", label = "垂直布局", cols = 24 },
        },

        -- 布局配置
        {
            { type = "slider", key = "maxIconsPerRow", label = "每行最大图标数",
              min = UI_LIMITS.MAX_ICONS_PER_ROW.min, max = UI_LIMITS.MAX_ICONS_PER_ROW.max, step = 1, cols = 12 },
            { type = "checkbox", key = "fixedRowLengthByLimit", label = "按最大图标数固定行长", cols = 12 },
            { type = "dropdown", key = "rowAnchor", label = "行内锚点", cols = 12, items = ROW_ANCHOR_OPTIONS },
            { type = "slider", key = "spacingX", label = "列间距",
              min = UI_LIMITS.SPACING.min, max = UI_LIMITS.SPACING.max, step = 1, cols = 12 },
            { type = "slider", key = "spacingY", label = "行间距",
              min = UI_LIMITS.SPACING.min, max = UI_LIMITS.SPACING.max, step = 1, cols = 12 },
            { type = "spacer", height = 10, cols = 24 },
        },

        -- 图标尺寸
        {
            { type = "subtitle", text = "图标尺寸", cols = 24 },
            { type = "separator", cols = 24 },
            { type = "slider", key = "iconWidth", label = "图标宽度",
              min = UI_LIMITS.SIZE.min, max = UI_LIMITS.SIZE.max, step = 1, cols = 12 },
            { type = "slider", key = "iconHeight", label = "图标高度",
              min = UI_LIMITS.SIZE.min, max = UI_LIMITS.SIZE.max, step = 1, cols = 12 },
            { type = "slider", key = "secondRowIconWidth", label = "第二行图标宽度",
              min = UI_LIMITS.SIZE.min, max = UI_LIMITS.SIZE.max, step = 1, cols = 12 },
            { type = "slider", key = "secondRowIconHeight", label = "第二行图标高度",
              min = UI_LIMITS.SIZE.min, max = UI_LIMITS.SIZE.max, step = 1, cols = 12 },
            { type = "spacer", height = 10, cols = 24 },
        },

        -- 键位显示
        {
            { type = "subtitle", text = "键位显示", cols = 24 },
            { type = "separator", cols = 24 },
            { type = "checkbox", key = "showKeybind", label = "显示键位", cols = 12 },
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
            Grid.fontGroup("stackFont", "堆叠文本样式"),
            { type = "spacer", height = 10, cols = 24 },
            Grid.fontGroup("cooldownFont", "冷却文本样式"),
            { type = "spacer", height = 10, cols = 24 },
            Grid.fontGroup("keybindFont", "键位文本样式"),
        },

        {
            { type = "spacer", height = 10, cols = 24 },
            { type = "subtitle", text = "遮罩层配置", cols = 24 },
            { type = "separator", cols = 24 },
            { type = "colorPicker", key = "cooldownMaskColor", label = "常规冷却遮罩层颜色", hasAlpha = true, cols = 12 },
            { type = "colorPicker", key = "buffMaskColor", label = "增益遮罩层颜色", hasAlpha = true, cols = 12 },
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

local function renderContent(container, menuKey)
    if menuKey == "skill_important" then
        renderGroupConfig(container, db.importantSkills, "重要技能组")
    elseif menuKey == "skill_efficiency" then
        renderGroupConfig(container, db.efficiencySkills, "效能技能组")
    elseif menuKey:find("^skill_custom_") then
        local customIndex = tonumber(menuKey:match("skill_custom_(%d+)"))
        if customIndex and db.customGroups[customIndex] then
            local customGroup = db.customGroups[customIndex]
            renderGroupConfig(container, customGroup.config, customGroup.name, {
                isCustom = true,
                groupIndex = customIndex
            })
        else
            local title = VFlow.UI.title(container, "自定义技能组未找到")
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
        return #db.customGroups
    end,

    getCustomGroups = function()
        return db.customGroups
    end,
}
