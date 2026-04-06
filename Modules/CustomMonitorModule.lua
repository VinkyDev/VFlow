--[[ Core 依赖：
  - Core/CustomMonitorGroups.lua：条形容器创建/销毁与 Store 同步
  - Core/CustomMonitorRuntime.lua：条形态、CD/BUFF 驱动与生命周期
  - Core/BuffScanner.lua、SkillScanner.lua：State 列表（本页左侧数据源，只读）
  例外：renderContent 内 State/Store.watch 仅刷新本页双栏 UI，不替代上述 Core 对业务配置的监听。
]]

-- =========================================================
-- SECTION 1: 模块注册
-- =========================================================

local VFlow = _G.VFlow
if not VFlow then return end
local L = VFlow.L

local MODULE_KEY = "VFlow.CustomMonitor"

VFlow.registerModule(MODULE_KEY, {
    name = L["Graphic Monitor"],
    description = L["Skill cooldown/BUFF duration bar monitor"],
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
    { L["Skill cooldown/Charge"], "cooldown" },
}

local MONITOR_TYPE_BUFF_OPTIONS = {
    { L["BUFF duration"], "duration" },
    { L["BUFF stack count"], "stacks" },
}

local SHAPE_OPTIONS = {
    { L["Bar"], "bar" },
    { L["Ring"], "ring" },
}

local BAR_DIRECTION_OPTIONS = {
    { L["Horizontal"], "horizontal" },
    { L["Vertical"], "vertical" },
}

local BAR_LENGTH_MODE_OPTIONS = {
    { L["Manual width"], "manual" },
    { L["Match important skills bar"], "sync_essential" },
    { L["Match efficiency skills bar"], "sync_utility" },
}

local BAR_FILL_OPTIONS = {
    { L["Fill"], "fill" },
    { L["Drain"], "drain" },
}

local BORDER_THICKNESS_OPTIONS = {
    { "1px", "1" },
    { L["Thin"], "2" },
    { L["Thick"], "3" },
}

local ICON_POSITION_OPTIONS = {
    { L["Left"], "LEFT" },
    { L["Right"], "RIGHT" },
    { L["Top"], "TOP" },
    { L["Bottom"], "BOTTOM" },
}

local FRAME_STRATA_OPTIONS = {
    { L["Background"], "BACKGROUND" },
    { L["Low"], "LOW" },
    { L["Medium"], "MEDIUM" },
    { L["High"], "HIGH" },
    { L["Dialog"], "DIALOG" },
    { L["Fullscreen"], "FULLSCREEN" },
    { L["Fullscreen Dialog"], "FULLSCREEN_DIALOG" },
    { L["Tooltip"], "TOOLTIP" },
}

local MONITOR_ANCHOR_FRAME_OPTIONS = {
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

local function getDefaultSpellConfig()
    return {
        enabled               = false,
        monitorType           = "cooldown",
        isChargeSpell         = false, -- 是否为充能技能（前置判断）
        shape                 = "bar",
        frameStrata           = "MEDIUM",
        anchorFrame           = "uiparent",
        relativePoint         = "CENTER",
        playerAnchorPosition  = "BOTTOMLEFT",
        x                     = 0,
        y                     = 0,
        barLengthMode         = "manual",
        barLength             = 200,
        barThickness          = 20,
        barColor              = { r = 0.2, g = 0.6, b = 1, a = 1 }, -- 充能技能：已充能颜色 / 冷却技能：就绪时颜色
        rechargeColor         = { r = 0.5, g = 0.8, b = 1, a = 1 }, -- 充能技能：充能中颜色 / 冷却技能：冷却中颜色
        barTexture            = "Solid",
        barDirection          = "horizontal",
        barFillMode           = "drain",
        barReverse            = false, -- 反向：StatusBar 沿填充轴镜像（与「增加/衰减」叠加）
        ringSize              = 150,                           -- 环形尺寸
        ringTexture           = "10",                          -- 环形材质：10/20/30/40
        ringColor             = { r = 0.2, g = 0.6, b = 1, a = 1 }, -- 环形颜色
        bgColor               = { r = 0.1, g = 0.1, b = 0.1, a = 0.5 }, -- 背景颜色
        borderColor           = { r = 0, g = 0, b = 0, a = 1 },
        borderThickness       = "1",
        segmentGap            = 0, -- 分段间距（像素，0=边框重合）
        showGraphics          = true,
        showText              = true,
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
        hideInSystemEditMode  = false, -- 不在暴雪系统编辑模式中显示（仅内部编辑模式可预览/拖拽）
    }
end

local defaults = {
    skills = {},
    buffs  = {},
}

local db = VFlow.getDB(MODULE_KEY, defaults)
local Utils = VFlow.Utils

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
    Utils.applyDefaults(store[spellID], getDefaultSpellConfig())
    -- 仅技能监控需要充能判定；BUFF 用同一 spellID 也可能是充能法术，但从不走充能条逻辑，
    -- 误判会隐藏「填充方向/反向」等条形选项。
    if store == db.buffs then
        store[spellID].isChargeSpell = false
    else
        store[spellID].isChargeSpell = detectChargeSpell(spellID)
    end
    return store[spellID]
end

-- =========================================================
-- SECTION 5: 共享布局构建器（右侧配置面板）
-- =========================================================

local mergeLayouts = Utils.mergeLayouts

local function visibilityGroup(isBuffMonitor)
    local items = {
        { type = "subtitle", text = L["Visibility Conditions"], cols = 24 },
        { type = "separator", cols = 24 },
        {
            type = "dropdown",
            key = "visibilityMode",
            label = L["Only when the following conditions"],
            cols = 12,
            items = {
                { L["Hide"], "hide" },
                { L["Show"], "show" },
            }
        },
        { type = "spacer", height = 1, cols = 24 },
        { type = "checkbox", key = "hideInCombat", label = L["In combat"], cols = 6 },
        { type = "checkbox", key = "hideOnMount", label = L["While mounted"], cols = 6 },
        { type = "checkbox", key = "hideOnSkyriding", label = L["While dragonriding"], cols = 6 },
        { type = "checkbox", key = "hideInSpecial", label = L["In special scenarios"], cols = 6 },
        { type = "checkbox", key = "hideNoTarget", label = L["No target"], cols = 6 },
    }

    if isBuffMonitor then
        table.insert(items, { type = "checkbox", key = "hideWhenInactive", label = L["When BUFF inactive"], cols = 6 })
    end

    table.insert(items, { type = "spacer", height = 4, cols = 24 })
    table.insert(items, { type = "description", text = L["Special scenarios: Vehicle/Pet battle"], cols = 24 })
    table.insert(items, { type = "spacer", height = 10, cols = 24 })

    return items
end

local function buildSpellConfigLayout(monitorTypeOptions, timerFontLabel, isSkill, isChargeSpell, spellCfg)
    local Grid = VFlow.Grid

    -- 根据技能类型确定颜色配置标签
    local barColorLabel, rechargeColorLabel
    if isSkill then
        if isChargeSpell then
            barColorLabel = L["Charged color"]
            rechargeColorLabel = L["Charging color"]
        else
            barColorLabel = L["Ready color"]
            rechargeColorLabel = L["Cooldown color"]
        end
    else
        barColorLabel = L["Bar color"]
        rechargeColorLabel = nil -- BUFF不需要第二个颜色
    end

    -- 动态生成形状选项的函数
    local function getShapeItems(cfg)
        -- BUFF持续时间支持条形和环形，其他只支持条形
        if not isSkill and cfg.monitorType == "duration" then
            return SHAPE_OPTIONS
        else
            return { { L["Bar"], "bar" } }
        end
    end

    return mergeLayouts(
        {
            { type = "subtitle", text = L["Base Settings"], cols = 24 },
            { type = "separator", cols = 24 },
            { type = "checkbox", key = "enabled", label = L["Enable custom monitor"], cols = 12 },
            { type = "spacer", height = 1, cols = 24 },
            { type = "dropdown", key = "monitorType", label = L["Monitor Type"], cols = 12, items = monitorTypeOptions },
            {
                type = "dropdown",
                key = "shape",
                label = L["Monitor Shape"],
                cols = 12,
                items = getShapeItems,
                dependsOn = "monitorType"
            },
            { type = "checkbox", key = "hideInCooldownManager", label = L["Hide in CDM (requires RL)"], cols = 12 },
            { type = "checkbox", key = "hideInSystemEditMode", label = L["Hide in Edit Mode"], cols = 12 },
        },
        not isSkill and {
            {
                type      = "if",
                dependsOn = "monitorType",
                condition = function(cfg) return cfg.monitorType == "stacks" end,
                children  = {
                    { type = "spacer", height = 10, cols = 24 },
                    { type = "subtitle", text = L["Stack Config"], cols = 24 },
                    { type = "separator", cols = 24 },
                    {
                        type = "input",
                        key = "maxStacks",
                        label = L["Max stack count"],
                        cols = 12,
                        numeric = true,
                        labelOnLeft = true
                    },
                    { type = "spacer", height = 4, cols = 24 },
                    { type = "description", text = L["Threshold color (bar changes color at this stack, 0=disable)"], cols = 24 },
                    {
                        type = "input",
                        key = "stackThreshold1",
                        label = L["Threshold 1 stack"],
                        cols = 12,
                        numeric = true,
                    },
                    {
                        type = "colorPicker",
                        key = "stackColor1",
                        label = L["Threshold 1 color"],
                        cols = 12,
                        hasAlpha = true
                    },
                    {
                        type = "input",
                        key = "stackThreshold2",
                        label = L["Threshold 2 stack"],
                        cols = 12,
                        numeric = true,
                    },
                    {
                        type = "colorPicker",
                        key = "stackColor2",
                        label = L["Threshold 2 color"],
                        cols = 12,
                        hasAlpha = true
                    },
                },
            },
        } or {},
        {
            { type = "spacer", height = 10, cols = 24 },
            { type = "subtitle", text = L["Display Content"], cols = 24 },
            { type = "separator", cols = 24 },
            { type = "checkbox", key = "showGraphics", label = L["Show graphics"], cols = 8 },
            { type = "checkbox", key = "showText", label = L["Show text"], cols = 8 },
            { type = "checkbox", key = "showIcon", label = L["Show icon"], cols = 8 },
        },
        {
            {
                type = "if",
                dependsOn = "showGraphics",
                condition = function(cfg) return cfg.showGraphics ~= false end,
                children = {
                    { type = "spacer", height = 10, cols = 24 },
                    { type = "subtitle", text = L["Graphics Style"], cols = 24 },
                    { type = "separator", cols = 24 },
                    {
                        type = "dropdown",
                        key = "frameStrata",
                        label = L["Graphics Layer"],
                        cols = 12,
                        items = FRAME_STRATA_OPTIONS
                    },
                    {
                        type = "if",
                        dependsOn = "shape",
                        condition = function(cfg) return cfg.shape == "bar" end,
                        children = {
                            {
                                type = "dropdown",
                                key = "barLengthMode",
                                label = L["Width mode"],
                                cols = 12,
                                items = BAR_LENGTH_MODE_OPTIONS,
                            },
                            {
                                type = "if",
                                dependsOn = "barLengthMode",
                                condition = function(c)
                                    return (c.barLengthMode or "manual") == "manual"
                                end,
                                children = {
                                    {
                                        type = "slider",
                                        key = "barLength",
                                        label = L["Bar length"],
                                        min = UI_LIMITS.BAR_LENGTH.min,
                                        max = UI_LIMITS.BAR_LENGTH.max,
                                        step = 1,
                                        cols = 12
                                    },
                                },
                            },
                            {
                                type = "slider",
                                key = "barThickness",
                                label = L["Bar height"],
                                min = UI_LIMITS.BAR_THICK.min,
                                max = UI_LIMITS.BAR_THICK.max,
                                step = 1,
                                cols = 12
                            },
                            { type = "colorPicker", key = "barColor", label = barColorLabel, hasAlpha = true, cols = 8 },
                            rechargeColorLabel and {
                                type = "colorPicker",
                                key = "rechargeColor",
                                label = rechargeColorLabel,
                                hasAlpha = true,
                                cols = 8
                            } or { type = "spacer", cols = 0 },
                            {
                                type = "texturePicker",
                                key = "barTexture",
                                label = L["Bar texture"],
                                cols = 24
                            },
                            {
                                type = "dropdown",
                                key = "barDirection",
                                label = L["Direction"],
                                cols = 8,
                                items = BAR_DIRECTION_OPTIONS
                            },
                            {
                                type = "if",
                                dependsOn = "shape",
                                condition = function(cfg)
                                    return cfg.shape == "bar" and not isChargeSpell
                                end,
                                children = {
                                    {
                                        type = "dropdown",
                                        key = "barFillMode",
                                        label = L["Fill direction"],
                                        cols = 8,
                                        items = BAR_FILL_OPTIONS
                                    },
                                    {
                                        type = "checkbox",
                                        key = "barReverse",
                                        label = L["Reverse"],
                                        cols = 8,
                                    },
                                }
                            },
                        },
                    },
                    {
                        type = "if",
                        dependsOn = "shape",
                        condition = function(cfg) return cfg.shape == "ring" end,
                        children = {
                            {
                                type = "slider",
                                key = "ringSize",
                                label = L["Ring size"],
                                min = 20,
                                max = 500,
                                step = 1,
                                cols = 12
                            },
                            {
                                type = "dropdown",
                                key = "ringTexture",
                                label = L["Ring texture"],
                                cols = 12,
                                items = {
                                    { "10px", "10" },
                                    { "20px", "20" },
                                    { "30px", "30" },
                                    { "40px", "40" },
                                }
                            },
                            { type = "colorPicker", key = "ringColor", label = L["Ring color"], hasAlpha = true, cols = 8 },
                        }
                    },
                    { type = "colorPicker", key = "bgColor", label = L["Background color"], hasAlpha = true, cols = 8 },
                    { type = "colorPicker", key = "borderColor", label = L["Border color"], hasAlpha = true, cols = 8 },
                    {
                        type = "dropdown",
                        key = "borderThickness",
                        label = L["Border thickness"],
                        cols = 8,
                        items = BORDER_THICKNESS_OPTIONS
                    },
                    {
                        type = "slider",
                        key = "segmentGap",
                        label = L["Segment gap"],
                        min = 0,
                        max = 10,
                        step = 1,
                        cols = 8
                    },
                },
            },
        },
        {
            {
                type = "if",
                dependsOn = "showText",
                condition = function(cfg) return cfg.showText ~= false end,
                children = mergeLayouts({
                    { type = "spacer", height = 10, cols = 24 },
                }, Grid.fontGroup("timerFont", timerFontLabel)),
            },
        },
        {
            {
                type = "if",
                dependsOn = "showGraphics",
                condition = function(cfg) return cfg.showGraphics ~= false end,
                children = {
                    {
                        type = "if",
                        dependsOn = "showIcon",
                        condition = function(cfg) return cfg.showIcon end,
                        children = {
                            { type = "spacer", height = 10, cols = 24 },
                            { type = "subtitle", text = L["Skill Icon"], cols = 24 },
                            { type = "separator", cols = 24 },
                            {
                                type = "slider",
                                key = "iconSize",
                                label = L["Icon size"],
                                min = UI_LIMITS.ICON_SIZE.min,
                                max = UI_LIMITS.ICON_SIZE.max,
                                step = 1,
                                cols = 12
                            },
                            {
                                type = "dropdown",
                                key = "iconPosition",
                                label = L["Icon position"],
                                cols = 12,
                                items = ICON_POSITION_OPTIONS
                            },
                            {
                                type = "slider",
                                key = "iconOffsetX",
                                label = L["X offset"],
                                min = UI_LIMITS.ICON_OFFSET.min,
                                max = UI_LIMITS.ICON_OFFSET.max,
                                step = 1,
                                cols = 12
                            },
                            {
                                type = "slider",
                                key = "iconOffsetY",
                                label = L["Y offset"],
                                min = UI_LIMITS.ICON_OFFSET.min,
                                max = UI_LIMITS.ICON_OFFSET.max,
                                step = 1,
                                cols = 12
                            },
                        },
                    },
                },
            },
        },
        {
            { type = "spacer", height = 10, cols = 24 },
            { type = "subtitle", text = L["Position Settings"], cols = 24 },
            { type = "separator", cols = 24 },
            {
                type = "dropdown",
                key = "anchorFrame",
                label = L["Attached frame"],
                cols = 12,
                items = MONITOR_ANCHOR_FRAME_OPTIONS,
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
                    {
                        type = "slider",
                        key = "x",
                        label = L["X offset"],
                        min = UI_LIMITS.POSITION.min,
                        max = UI_LIMITS.POSITION.max,
                        step = 1,
                        cols = 12,
                    },
                    {
                        type = "slider",
                        key = "y",
                        label = L["Y offset"],
                        min = UI_LIMITS.POSITION.min,
                        max = UI_LIMITS.POSITION.max,
                        step = 1,
                        cols = 12,
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
                        type = "slider",
                        key = "x",
                        label = L["X coordinate"],
                        min = UI_LIMITS.POSITION.min,
                        max = UI_LIMITS.POSITION.max,
                        step = 1,
                        cols = 12,
                    },
                    {
                        type = "slider",
                        key = "y",
                        label = L["Y coordinate"],
                        min = UI_LIMITS.POSITION.min,
                        max = UI_LIMITS.POSITION.max,
                        step = 1,
                        cols = 12
                    },
                },
            },
            {
                type  = "interactiveText",
                cols  = 24,
                text  = L["Preview and drag in {edit mode} to change position"],
                links = {
                    [L["Edit mode"]] = function()
                        if spellCfg and spellCfg.hideInSystemEditMode then
                            if VFlow.toggleInternalEditMode then
                                VFlow.toggleInternalEditMode()
                            elseif VFlow.DragFrame and VFlow.DragFrame.toggleInternalEditMode then
                                VFlow.DragFrame.toggleInternalEditMode()
                            end
                        else
                            VFlow.toggleSystemEditMode()
                        end
                    end,
                },
            },
        },
        {
            { type = "spacer", height = 10, cols = 24 },
            visibilityGroup(not isSkill),
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
    local openContext = VFlow.MainUI and VFlow.MainUI.consumeOpenContext and VFlow.MainUI.consumeOpenContext(menuKey)

    local Grid     = VFlow.Grid

    local title    = UI.title(container, isSkill and L["Skill Monitor"] or L["BUFF Monitor"])
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

    local selectedID = openContext and openContext.selectedID or nil

    -- 无选中提示
    local hintFrame = CreateFrame("Frame", nil, configFrame)
    hintFrame:SetAllPoints(configFrame)
    local hintStr = hintFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    hintStr:SetPoint("TOPLEFT", 10, -10)
    local dimC = UI.style and UI.style.colors and UI.style.colors.textDim or { 0.6, 0.6, 0.6, 1 }
    hintStr:SetTextColor(dimC[1], dimC[2], dimC[3], 1)
    hintStr:SetText(L["← Select a spell/BUFF from the left to configure"])
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
            and L["Cooldown text style"]
            or ({ duration = L["Remaining time text style"], stacks = L["Stack count text style"] })[spellConfig.monitorType]
            or L["Text style"]

        local spellInfo     = C_Spell.GetSpellInfo(selectedID)
        local spellName     = spellInfo and spellInfo.name or ("ID: " .. selectedID)

        -- 检测技能类型并显示
        local spellTypeDesc = ""
        if isSkill then
            if spellConfig.isChargeSpell then
                spellTypeDesc = " |cff33dd55" .. L["[Charge spell]"] .. "|r"
            else
                spellTypeDesc = " |cff3399ff" .. L["[Cooldown spell]"] .. "|r"
            end
        end

        local layout = mergeLayouts(
            {
                { type = "title",     text = spellName .. spellTypeDesc, cols = 24 },
                { type = "separator", cols = 24 },
            },
            buildSpellConfigLayout(monitorTypes, fontLabel, isSkill, spellConfig.isChargeSpell, spellConfig)
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
                text = L["Only tracked BUFFs in {cooldown manager} can be used. {Click to rescan}."],
                links = {
                    [L["Cooldown Manager"]] = function()
                        VFlow.openCooldownManager()
                    end,
                    [L["Click to rescan"]] = function()
                        if VFlow.BuffScanner then VFlow.BuffScanner.scan() end
                    end,
                }
            })
            table.insert(selectorLayout, { type = "spacer", height = 4, cols = 24 })
        end

        table.insert(selectorLayout, {
            type = "description",
            text = "|cff3399ff■|r " .. L["Current"] .. "  |cff33dd55■|r " .. L["Enabled"],
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

                Utils.sortByName(items)
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
                        tip:AddLine("|cff00ff00" .. L["Click to configure"] .. "|r", 1, 1, 1)
                    end
                end,
                onClick     = function(d) onSelect(d.spellID) end,
            },
        })

        -- 技能监控：手动输入任意技能ID
        if isSkill then
            table.insert(selectorLayout, { type = "spacer", height = 8, cols = 24 })
            table.insert(selectorLayout, { type = "description", text = L["Manual spell ID input:"], cols = 24 })
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
                text    = L["Add"],
                cols    = 8,
                onClick = function(cfg)
                    local sid = tonumber(cfg._manualSpellID)
                    if not sid or sid <= 0 then
                        print("|cffff0000VFlow:|r " .. L["Please enter a valid spell ID"])
                        return
                    end
                    local isKnown = (IsPlayerSpell and IsPlayerSpell(sid)) or (IsSpellKnown and IsSpellKnown(sid))
                    local trackedSkills = VFlow.State.get("trackedSkills") or {}
                    if not isKnown and not trackedSkills[sid] then
                        local si = C_Spell.GetSpellInfo(sid)
                        local name = si and si.name or ("ID: " .. sid)
                        print("|cffff0000VFlow:|r " .. string.format(L["Spell \"%s\" is not available on this character, cannot add"], name))
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
            local delLabel = string.format(L["Delete config for \"%s\""], si and si.name or tostring(selectedID))
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
