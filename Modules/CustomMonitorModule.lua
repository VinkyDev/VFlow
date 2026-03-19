-- =========================================================
-- SECTION 1: 模块注册
-- =========================================================

local VFlow = _G.VFlow
if not VFlow then return end

local MODULE_KEY = "VFlow.CustomMonitor"

VFlow.registerModule(MODULE_KEY, {
    name = "自定义图形监控",
    description = "技能冷却/BUFF持续时间条形监控",
})

-- =========================================================
-- SECTION 2: 常量
-- =========================================================

local UI_LIMITS = {
    POSITION    = { min = -2000, max = 2000, step = 1 },
    BAR_LENGTH  = { min = 20, max = 600, step = 1 },
    BAR_THICK   = { min = 4, max = 100, step = 1 },
    ICON_SIZE   = { min = 8, max = 120, step = 1 },
    ICON_OFFSET = { min = -200, max = 200, step = 1 },
}

local MONITOR_TYPE_SKILL_OPTIONS = {
    { "技能冷却/充能", "cooldown" },
}

local MONITOR_TYPE_BUFF_OPTIONS = {
    { "BUFF持续时间", "duration" },
    { "BUFF堆叠层数", "stacks" },
}

local SHAPE_OPTIONS = {
    { "条形", "bar" },
    { "环形", "ring" },
}

local BAR_DIRECTION_OPTIONS = {
    { "水平", "horizontal" },
    { "垂直", "vertical" },
}

local BAR_FILL_OPTIONS = {
    { "增加", "fill" },
    { "衰减", "drain" },
}

local BORDER_THICKNESS_OPTIONS = {
    { "1px", "1" },
    { "细", "2" },
    { "粗", "3" },
}

local ICON_POSITION_OPTIONS = {
    { "左侧", "LEFT" },
    { "右侧", "RIGHT" },
    { "上方", "TOP" },
    { "下方", "BOTTOM" },
}

local FRAME_STRATA_OPTIONS = {
    { "背景", "BACKGROUND" },
    { "低", "LOW" },
    { "中", "MEDIUM" },
    { "高", "HIGH" },
    { "对话框", "DIALOG" },
    { "全屏", "FULLSCREEN" },
    { "全屏对话框", "FULLSCREEN_DIALOG" },
    { "工具提示", "TOOLTIP" },
}

-- =========================================================
-- SECTION 3: 默认配置
-- =========================================================

local function getDefaultSpellConfig()
    return {
        enabled               = false,
        monitorType           = "cooldown",
        isChargeSpell         = false, -- 是否为充能技能（前置判断）
        shape                 = "bar",
        frameStrata           = "MEDIUM",
        x                     = 0,
        y                     = 0,
        barLength             = 200,
        barThickness          = 20,
        barColor              = { r = 0.2, g = 0.6, b = 1, a = 1 }, -- 充能技能：已充能颜色 / 冷却技能：就绪时颜色
        rechargeColor         = { r = 0.5, g = 0.8, b = 1, a = 1 }, -- 充能技能：充能中颜色 / 冷却技能：冷却中颜色
        barTexture            = "Solid",
        barDirection          = "horizontal",
        barFillMode           = "drain",
        ringSize              = 150,                           -- 环形尺寸
        ringTexture           = "10",                          -- 环形材质：10/20/30/40
        ringColor             = { r = 0.2, g = 0.6, b = 1, a = 1 }, -- 环形颜色
        borderColor           = { r = 0, g = 0, b = 0, a = 1 },
        borderThickness       = "1",
        segmentGap            = 0, -- 分段间距（像素，0=边框重合）
        timerFont             = {
            size     = 14,
            font     = "默认",
            outline  = "OUTLINE",
            color    = { r = 1, g = 1, b = 1, a = 1 },
            position = "CENTER",
            offsetX  = 0,
            offsetY  = 0,
        },
        maxStacks             = 5,
        stackThreshold1       = 0,
        stackColor1           = { r = 1, g = 0.5, b = 0, a = 1 },
        stackThreshold2       = 0,
        stackColor2           = { r = 1, g = 0, b = 0, a = 1 },
        showIcon              = true,
        iconSize              = 20,
        iconPosition          = "LEFT",
        iconOffsetX           = 0,
        iconOffsetY           = 0,
        -- 显示条件
        visibilityMode        = "hide", -- "show" 或 "hide"
        hideInCombat          = false,
        hideOnMount           = false,
        hideOnSkyriding       = false,
        hideInSpecial         = false, -- 载具/宠物对战
        hideNoTarget          = false,
        hideWhenInactive      = false, -- 仅对BUFF监控：BUFF未激活时隐藏
        hideInCooldownManager = false, -- 在冷却管理器中隐藏
    }
end

local defaults = {
    skills = {},
    buffs  = {},
}

local db = VFlow.getDB(MODULE_KEY, defaults)

-- =========================================================
-- SECTION 4: 辅助函数
-- =========================================================

-- 检测技能是否为充能技能
local function detectChargeSpell(spellID)
    local chargeInfo = C_Spell.GetSpellCharges(spellID)
    if not chargeInfo then return false end

    local maxCharges = chargeInfo.maxCharges
    if not maxCharges then return false end

    -- 避免secret value
    if issecretvalue and issecretvalue(maxCharges) then return false end

    -- 只有maxCharges >= 2才是真正的充能技能
    return maxCharges >= 2
end

local function getOrCreateConfig(store, spellID)
    if not store[spellID] then
        store[spellID] = getDefaultSpellConfig()
    end
    -- 每次获取配置时检测技能类型（确保最新）
    store[spellID].isChargeSpell = detectChargeSpell(spellID)
    return store[spellID]
end

-- =========================================================
-- SECTION 5: 共享布局构建器（右侧配置面板）
-- =========================================================

local mergeLayouts = VFlow.LayoutUtils.mergeLayouts

local function visibilityGroup(isBuffMonitor)
    local items = {
        { type = "subtitle", text = "显示条件", cols = 24 },
        { type = "separator", cols = 24 },
        {
            type = "dropdown",
            key = "visibilityMode",
            label = "仅以下条件时",
            cols = 12,
            items = {
                { "隐藏", "hide" },
                { "显示", "show" },
            }
        },
        { type = "spacer", height = 1, cols = 24 },
        { type = "checkbox", key = "hideInCombat", label = "战斗中", cols = 6 },
        { type = "checkbox", key = "hideOnMount", label = "骑乘时", cols = 6 },
        { type = "checkbox", key = "hideOnSkyriding", label = "御龙术时", cols = 6 },
        { type = "checkbox", key = "hideInSpecial", label = "特殊场景时", cols = 6 },
        { type = "checkbox", key = "hideNoTarget", label = "无目标时", cols = 6 },
    }

    -- 仅BUFF监控显示"BUFF激活时"选项
    if isBuffMonitor then
        table.insert(items, { type = "checkbox", key = "hideWhenInactive", label = "BUFF未激活时", cols = 6 })
    end

    table.insert(items, { type = "spacer", height = 4, cols = 24 })
    table.insert(items, { type = "description", text = "特殊场景：载具/宠物对战", cols = 24 })
    table.insert(items, { type = "spacer", height = 10, cols = 24 })

    return items
end

local function buildSpellConfigLayout(monitorTypeOptions, timerFontLabel, isSkill, isChargeSpell)
    local Grid = VFlow.Grid

    -- 根据技能类型确定颜色配置标签
    local barColorLabel, rechargeColorLabel
    if isSkill then
        if isChargeSpell then
            barColorLabel = "已充能颜色"
            rechargeColorLabel = "充能中颜色"
        else
            barColorLabel = "就绪时颜色"
            rechargeColorLabel = "冷却中颜色"
        end
    else
        barColorLabel = "条颜色"
        rechargeColorLabel = nil -- BUFF不需要第二个颜色
    end

    -- 动态生成形状选项的函数
    local function getShapeItems(cfg)
        -- BUFF持续时间支持条形和环形，其他只支持条形
        if not isSkill and cfg.monitorType == "duration" then
            return SHAPE_OPTIONS
        else
            return { { "条形", "bar" } }
        end
    end

    return mergeLayouts(
        {
            { type = "subtitle", text = "基础设置", cols = 24 },
            { type = "separator", cols = 24 },
            { type = "checkbox", key = "enabled", label = "启用该技能自定义监控", cols = 12 },
            { type = "checkbox", key = "hideInCooldownManager", label = "在冷却管理器中隐藏(需RL)", cols = 12 },
        },
        {
            { type = "dropdown", key = "monitorType", label = "监控类型", cols = 12, items = monitorTypeOptions },
            {
                type = "dropdown",
                key = "shape",
                label = "监控形状",
                cols = 12,
                items = getShapeItems,    -- 传递函数，Grid会在渲染时调用
                dependsOn = "monitorType" -- 依赖monitorType，变化时重新渲染
            },
            {
                type = "dropdown",
                key = "frameStrata",
                label = "图形层级",
                cols = 12,
                items = FRAME_STRATA_OPTIONS
            },
        },
        not isSkill and {
            {
                type      = "if",
                dependsOn = "monitorType",
                condition = function(cfg) return cfg.monitorType == "stacks" end,
                children  = {
                    { type = "spacer", height = 10, cols = 24 },
                    { type = "subtitle", text = "堆叠层数配置", cols = 24 },
                    { type = "separator", cols = 24 },
                    {
                        type = "input",
                        key = "maxStacks",
                        label = "最大层数",
                        cols = 12,
                        numeric = true,
                        labelOnLeft = true
                    },
                    { type = "spacer", height = 4, cols = 24 },
                    { type = "description", text = "阈值染色（达到该层数时条变色，0=禁用）", cols = 24 },
                    {
                        type = "input",
                        key = "stackThreshold1",
                        label = "阈值1层数",
                        cols = 12,
                        numeric = true,
                    },
                    {
                        type = "colorPicker",
                        key = "stackColor1",
                        label = "阈值1颜色",
                        cols = 12,
                        hasAlpha = true
                    },
                    {
                        type = "input",
                        key = "stackThreshold2",
                        label = "阈值2层数",
                        cols = 12,
                        numeric = true,
                    },
                    {
                        type = "colorPicker",
                        key = "stackColor2",
                        label = "阈值2颜色",
                        cols = 12,
                        hasAlpha = true
                    },
                },
            },
        } or {},
        {
            { type = "spacer", height = 10, cols = 24 },
            { type = "subtitle", text = "位置设置", cols = 24 },
            { type = "separator", cols = 24 },
            {
                type = "slider",
                key = "x",
                label = "X坐标",
                min = UI_LIMITS.POSITION.min,
                max = UI_LIMITS.POSITION.max,
                step = 1,
                cols = 12
            },
            {
                type = "slider",
                key = "y",
                label = "Y坐标",
                min = UI_LIMITS.POSITION.min,
                max = UI_LIMITS.POSITION.max,
                step = 1,
                cols = 12
            },
            {
                type  = "interactiveText",
                cols  = 24,
                text  = "可在{编辑模式}中预览和拖拽修改位置",
                links = {
                    ["编辑模式"] = function()
                        VFlow.toggleSystemEditMode()
                    end,
                },
            },
        },
        {
            { type = "spacer", height = 10, cols = 24 },
            {
                type = "if",
                dependsOn = "shape",
                condition = function(cfg) return cfg.shape == "bar" end,
                children = {
                    { type = "subtitle", text = "条形配置", cols = 24 },
                    { type = "separator", cols = 24 },
                    {
                        type = "slider",
                        key = "barLength",
                        label = "条长",
                        min = UI_LIMITS.BAR_LENGTH.min,
                        max = UI_LIMITS.BAR_LENGTH.max,
                        step = 1,
                        cols = 12
                    },
                    {
                        type = "slider",
                        key = "barThickness",
                        label = "条高",
                        min = UI_LIMITS.BAR_THICK.min,
                        max = UI_LIMITS.BAR_THICK.max,
                        step = 1,
                        cols = 12
                    },
                    { type = "colorPicker", key = "barColor", label = barColorLabel, hasAlpha = true, cols = 8 },
                }
            },
            {
                type = "if",
                dependsOn = "shape",
                condition = function(cfg) return cfg.shape == "ring" end,
                children = {
                    { type = "subtitle", text = "环形配置", cols = 24 },
                    { type = "separator", cols = 24 },
                    {
                        type = "slider",
                        key = "ringSize",
                        label = "环形尺寸",
                        min = 20,
                        max = 500,
                        step = 1,
                        cols = 12
                    },
                    {
                        type = "dropdown",
                        key = "ringTexture",
                        label = "环形材质",
                        cols = 12,
                        items = {
                            { "10px", "10" },
                            { "20px", "20" },
                            { "30px", "30" },
                            { "40px", "40" },
                        }
                    },
                    { type = "colorPicker", key = "ringColor", label = "环形颜色", hasAlpha = true, cols = 8 },
                }
            },
        },
        rechargeColorLabel and {
            {
                type = "if",
                dependsOn = "shape",
                condition = function(cfg) return cfg.shape == "bar" end,
                children = {
                    { type = "colorPicker", key = "rechargeColor", label = rechargeColorLabel, hasAlpha = true, cols = 8 },
                }
            },
        } or {},
        {
            {
                type = "if",
                dependsOn = "shape",
                condition = function(cfg) return cfg.shape == "bar" end,
                children = {
                    { type = "texturePicker", key = "barTexture", label = "条材质", cols = 24 },
                    {
                        type = "dropdown",
                        key = "barDirection",
                        label = "方向",
                        cols = 8,
                        items = BAR_DIRECTION_OPTIONS
                    },
                    {
                        type = "dropdown",
                        key = "barFillMode",
                        label = "填充方向",
                        cols = 8,
                        items = BAR_FILL_OPTIONS
                    },
                }
            },
        },
        {
            { type = "spacer", height = 10, cols = 24 },
            { type = "subtitle", text = "边框配置", cols = 24 },
            { type = "separator", cols = 24 },
            { type = "colorPicker", key = "borderColor", label = "边框颜色", hasAlpha = true, cols = 8 },
            {
                type = "dropdown",
                key = "borderThickness",
                label = "边框粗细",
                cols = 8,
                items = BORDER_THICKNESS_OPTIONS
            },
            {
                type = "slider",
                key = "segmentGap",
                label = "分段间距",
                min = 0,
                max = 10,
                step = 1,
                cols = 8
            },
        },
        {
            { type = "spacer", height = 10, cols = 24 },
            Grid.fontGroup("timerFont", timerFontLabel),
        },
        {
            { type = "spacer", height = 10, cols = 24 },
            { type = "subtitle", text = "技能图标", cols = 24 },
            { type = "separator", cols = 24 },
            { type = "checkbox", key = "showIcon", label = "显示图标", cols = 12 },
            {
                type = "if",
                dependsOn = "showIcon",
                condition = function(cfg) return cfg.showIcon end,
                children = {
                    {
                        type = "slider",
                        key = "iconSize",
                        label = "图标大小",
                        min = UI_LIMITS.ICON_SIZE.min,
                        max = UI_LIMITS.ICON_SIZE.max,
                        step = 1,
                        cols = 12
                    },
                    {
                        type = "dropdown",
                        key = "iconPosition",
                        label = "图标位置",
                        cols = 12,
                        items = ICON_POSITION_OPTIONS
                    },
                    {
                        type = "slider",
                        key = "iconOffsetX",
                        label = "X偏移",
                        min = UI_LIMITS.ICON_OFFSET.min,
                        max = UI_LIMITS.ICON_OFFSET.max,
                        step = 1,
                        cols = 12
                    },
                    {
                        type = "slider",
                        key = "iconOffsetY",
                        label = "Y偏移",
                        min = UI_LIMITS.ICON_OFFSET.min,
                        max = UI_LIMITS.ICON_OFFSET.max,
                        step = 1,
                        cols = 12
                    },
                },
            },
        },
        {
            { type = "spacer", height = 10, cols = 24 },
            visibilityGroup(not isSkill), -- BUFF监控传true
        }
    )
end

-- =========================================================
-- SECTION 6: 渲染函数
-- =========================================================

local UI = VFlow.UI

local function renderContent(container, menuKey)
    local isSkill  = (menuKey == "custom_spell")
    local store    = isSkill and db.skills or db.buffs
    local storeKey = isSkill and "skills" or "buffs"

    local Grid     = VFlow.Grid

    local title    = UI.title(container, isSkill and "技能监控" or "BUFF监控")
    title:SetPoint("TOPLEFT", 0, 0)

    local bodyFrame = CreateFrame("Frame", nil, container)
    bodyFrame:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -10)
    bodyFrame:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT", 0, 0)

    -- 左侧选择器面板（固定宽度，用 Grid 驱动）
    local SELECTOR_W = 200
    local selectorFrame = CreateFrame("Frame", nil, bodyFrame, "BackdropTemplate")
    selectorFrame:SetPoint("TOPLEFT", 0, 0)
    selectorFrame:SetPoint("BOTTOM", bodyFrame, "BOTTOM", 0, 0)
    selectorFrame:SetWidth(SELECTOR_W)
    if selectorFrame.SetBackdrop then
        selectorFrame:SetBackdrop({
            bgFile   = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Buttons\\WHITE8x8",
            edgeSize = 1,
        })
        local panelColor = UI.style.colors.panel or { 0.14, 0.14, 0.14, 1 }
        local borderColor = UI.style.colors.border or { 0.3, 0.3, 0.3, 1 }
        selectorFrame:SetBackdropColor(panelColor[1], panelColor[2], panelColor[3], 0.6)
        selectorFrame:SetBackdropBorderColor(borderColor[1], borderColor[2], borderColor[3], borderColor[4])
    end

    -- 右侧配置面板
    local configFrame = CreateFrame("Frame", nil, bodyFrame)
    configFrame:SetPoint("TOPLEFT", selectorFrame, "TOPRIGHT", 10, 0)
    configFrame:SetPoint("BOTTOMRIGHT", bodyFrame, "BOTTOMRIGHT", 0, 0)

    local selectedID = nil

    -- 无选中提示
    local hintFrame = CreateFrame("Frame", nil, configFrame)
    hintFrame:SetAllPoints(configFrame)
    local hintStr = hintFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    hintStr:SetPoint("TOPLEFT", 10, -10)
    local dimC = UI.style and UI.style.colors and UI.style.colors.textDim or { 0.6, 0.6, 0.6, 1 }
    hintStr:SetTextColor(dimC[1], dimC[2], dimC[3], 1)
    hintStr:SetText("← 从左侧选择一个技能/BUFF开始配置")
    hintFrame:Hide()

    -- 右侧：刷新配置面板
    local function refreshConfigPanel()
        if not selectedID then
            Grid.clear(configFrame)
            hintFrame:Show()
            return
        end
        hintFrame:Hide()

        local spellConfig   = getOrCreateConfig(store, selectedID)
        local configPath    = storeKey .. "." .. selectedID
        local monitorTypes  = isSkill and MONITOR_TYPE_SKILL_OPTIONS or MONITOR_TYPE_BUFF_OPTIONS
        local fontLabel     = isSkill
            and "冷却时间文本样式"
            or ({ duration = "剩余时间文本样式", stacks = "堆叠层数文本样式" })[spellConfig.monitorType]
            or "文本样式"

        local spellInfo     = C_Spell.GetSpellInfo(selectedID)
        local spellName     = spellInfo and spellInfo.name or ("ID: " .. selectedID)

        -- 检测技能类型并显示
        local spellTypeDesc = ""
        if isSkill then
            if spellConfig.isChargeSpell then
                spellTypeDesc = " |cff33dd55[充能技能]|r"
            else
                spellTypeDesc = " |cff3399ff[冷却技能]|r"
            end
        end

        local layout = mergeLayouts(
            {
                { type = "title",     text = spellName .. spellTypeDesc, cols = 24 },
                { type = "separator", cols = 24 },
            },
            buildSpellConfigLayout(monitorTypes, fontLabel, isSkill, spellConfig.isChargeSpell)
        )
        Grid.render(configFrame, layout, spellConfig, MODULE_KEY, configPath)
    end

    -- 已启用ID集合
    local function buildEnabledIDs()
        local t = {}
        for spellID, cfg in pairs(store) do
            if cfg.enabled then t[spellID] = true end
        end
        return t
    end

    -- 左侧：构建选择器 Grid layout 并渲染
    local function refreshSelectorPanel()
        local onSelect       = function(spellID)
            selectedID = spellID
            refreshSelectorPanel()
            refreshConfigPanel()
        end

        local enabledIDs     = buildEnabledIDs()
        local PRIMARY_COLOR  = { 0.2, 0.6, 1, 1 }
        local SUCCESS_COLOR  = { 0.2, 0.85, 0.3, 1 }

        local selectorLayout = {}

        if not isSkill then
            table.insert(selectorLayout, {
                type = "interactiveText",
                cols = 24,
                text = "仅可使用{冷却管理器}中追踪的BUFF，{点我重新扫描}。",
                links = {
                    ["冷却管理器"] = function()
                        VFlow.openCooldownManager()
                    end,
                    ["点我重新扫描"] = function()
                        if VFlow.BuffScanner then VFlow.BuffScanner.scan() end
                    end,
                }
            })
            table.insert(selectorLayout, { type = "spacer", height = 4, cols = 24 })
        end

        table.insert(selectorLayout, {
            type = "description",
            text = "|cff3399ff■|r 当前配置  |cff33dd55■|r 已启用",
            cols = 24
        })
        table.insert(selectorLayout, { type = "spacer", height = 6, cols = 24 })
        table.insert(selectorLayout, {
            type       = "for",
            cols       = 6,
            dependsOn  = "_refresh",
            dataSource = function()
                local items = {}
                local seen  = {}

                if isSkill then
                    -- 1. 已配置且当前角色可用的技能（过滤其他职业历史记录）
                    for spellID in pairs(store) do
                        local isKnown = (IsPlayerSpell and IsPlayerSpell(spellID)) or
                            (IsSpellKnown and IsSpellKnown(spellID))
                        if not seen[spellID] and isKnown then
                            seen[spellID] = true
                            local si = C_Spell.GetSpellInfo(spellID)
                            if si and si.name then
                                table.insert(items, {
                                    spellID = spellID,
                                    name    = si.name,
                                    icon    = si.iconID or 134400,
                                })
                            end
                        end
                    end
                    -- 2. 当前专精重要技能（去重后追加，方便发现可配置的技能）
                    local trackedSkills = VFlow.State.get("trackedSkills") or {}
                    for spellID, info in pairs(trackedSkills) do
                        if not seen[spellID] then
                            seen[spellID] = true
                            table.insert(items, {
                                spellID = spellID,
                                name    = info.name,
                                icon    = info.icon,
                            })
                        end
                    end
                else
                    local trackedBuffs = VFlow.State.get("trackedBuffs") or {}
                    for spellID, info in pairs(trackedBuffs) do
                        table.insert(items, { spellID = spellID, name = info.name, icon = info.icon })
                    end
                end

                table.sort(items, function(a, b) return a.name < b.name end)
                return items
            end,
            template   = {
                type        = "iconButton",
                size        = 36,
                icon        = function(d) return d.icon end,
                borderColor = function(d)
                    if d.spellID == selectedID then
                        return PRIMARY_COLOR
                    elseif enabledIDs[d.spellID] then
                        return SUCCESS_COLOR
                    end
                    return nil
                end,
                tooltip     = function(d)
                    return function(tip)
                        tip:SetSpellByID(d.spellID)
                        tip:AddLine("|cff00ff00点击配置|r", 1, 1, 1)
                    end
                end,
                onClick     = function(d) onSelect(d.spellID) end,
            },
        })

        -- 技能监控：手动输入任意技能ID
        if isSkill then
            table.insert(selectorLayout, { type = "spacer", height = 8, cols = 24 })
            table.insert(selectorLayout, { type = "description", text = "手动输入技能ID：", cols = 24 })
            table.insert(selectorLayout, {
                type        = "input",
                key         = "_manualSpellID",
                label       = "ID",
                cols        = 16,
                numeric     = true,
                labelOnLeft = true,
            })
            table.insert(selectorLayout, {
                type    = "button",
                text    = "添加",
                cols    = 8,
                onClick = function(cfg)
                    local sid = tonumber(cfg._manualSpellID)
                    if not sid or sid <= 0 then
                        print("|cffff0000VFlow:|r 请输入有效的技能ID")
                        return
                    end
                    local isKnown = (IsPlayerSpell and IsPlayerSpell(sid)) or (IsSpellKnown and IsSpellKnown(sid))
                    local trackedSkills = VFlow.State.get("trackedSkills") or {}
                    if not isKnown and not trackedSkills[sid] then
                        local si = C_Spell.GetSpellInfo(sid)
                        local name = si and si.name or ("ID: " .. sid)
                        print("|cffff0000VFlow:|r 技能「" .. name .. "」当前角色不可用，无法添加")
                        return
                    end
                    onSelect(sid)
                    cfg._manualSpellID = nil
                    Grid.refresh(selectorFrame)
                end,
            })
        end

        -- 选中时显示删除按钮：
        -- 只有在 store 有记录，且不在当前数据源里（trackedSkills/trackedBuffs）的才能删除。
        -- trackedSkills 里的技能删后会因扫描重新出现，没有意义。
        local canDelete = false
        if selectedID and store[selectedID] then
            if isSkill then
                local trackedSkills = VFlow.State.get("trackedSkills") or {}
                canDelete = not trackedSkills[selectedID]
            else
                local trackedBuffs = VFlow.State.get("trackedBuffs") or {}
                canDelete = not trackedBuffs[selectedID]
            end
        end
        if canDelete then
            local si = C_Spell.GetSpellInfo(selectedID)
            local delLabel = "删除「" .. (si and si.name or tostring(selectedID)) .. "」的配置"
            table.insert(selectorLayout, { type = "spacer", height = 8, cols = 24 })
            table.insert(selectorLayout, {
                type    = "button",
                text    = delLabel,
                cols    = 24,
                onClick = function()
                    store[selectedID] = nil
                    VFlow.Store.set(MODULE_KEY, storeKey .. "." .. selectedID, nil)
                    selectedID = nil
                    refreshSelectorPanel()
                    refreshConfigPanel()
                end,
            })
        end

        -- 用临时空表作 config（选择器没有需要持久化的配置）
        Grid.render(selectorFrame, selectorLayout, {}, nil, nil)
    end

    refreshSelectorPanel()
    refreshConfigPanel()

    -- 专精/BUFF变更时刷新选择器
    local stateKey = isSkill and "trackedSkills" or "trackedBuffs"
    VFlow.State.watch(stateKey, "CustomMonitor_" .. menuKey, function()
        refreshSelectorPanel()
    end)

    -- enabled 变更时刷新绿框标记
    VFlow.Store.watch(MODULE_KEY, "CustomMonitor_enabled_" .. menuKey, function(key)
        if key:find("^" .. storeKey .. "%.%d+%.enabled$") then
            refreshSelectorPanel()
        end
    end)
end

-- =========================================================
-- SECTION 7: 公共接口
-- =========================================================

if not VFlow.Modules then VFlow.Modules = {} end

VFlow.Modules.CustomMonitor = {
    renderContent = renderContent,
}
