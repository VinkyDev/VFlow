--[[ Core 依赖：
  - Core/ViewerRefreshQueue.lua：BUFF 图标/条刷新合并调度
  - Core/CooldownStyle.lua：BuffBar 配置、条样式与样式版本
]]

-- =========================================================
-- SECTION 1: 模块注册
-- =========================================================

local VFlow = _G.VFlow
if not VFlow then return end
local L = VFlow.L

local MODULE_KEY = "VFlow.BuffBar"

VFlow.registerModule(MODULE_KEY, {
    name = L["BUFF Bar"],
    description = L["BUFF bar configuration"],
})

-- =========================================================
-- SECTION 2: 默认配置
-- =========================================================

local defaults = {
    barWidth = 200,
    barHeight = 20,
    barSpacing = 1,
    barTexture = "Solid",
    barColor = { r = 0.4, g = 0.6, b = 0.9, a = 1 },
    barBackgroundColor = { r = 0.1, g = 0.1, b = 0.1, a = 0.8 },
    growDirection = "DOWN",
    layoutPos = {
        mode = "offset",
        relPoint = "CENTER",
        x = 200,
        y = -70,
        cornerLeft = nil,
        cornerY = nil,
    },
    iconPosition = "LEFT",
    iconGap = 1,
    showName = true,
    showDuration = true,
    showStack = true,
    stackFont = {
        size = 12,
        font = "默认",
        outline = "OUTLINE",
        color = { r = 1, g = 1, b = 1, a = 1 },
        position = "BOTTOMRIGHT",
        offsetX = -2,
        offsetY = 2,
    },
    nameFont = {
        size = 12,
        font = "默认",
        outline = "OUTLINE",
        color = { r = 1, g = 1, b = 1, a = 1 },
        position = "LEFT",
        offsetX = 2,
        offsetY = 0,
    },
    durationFont = {
        size = 12,
        font = "默认",
        outline = "OUTLINE",
        color = { r = 1, g = 1, b = 1, a = 1 },
        position = "RIGHT",
        offsetX = -2,
        offsetY = 0,
    },
}

local db = VFlow.getDB(MODULE_KEY, defaults)

-- =========================================================
-- SECTION 3: 渲染
-- =========================================================

local function renderContent(container, _menuKey)
    local Grid = VFlow.Grid

    local layout = {
        { type = "title", text = L["BUFF Bar"], cols = 24 },
        { type = "separator", cols = 24 },
        {
            type = "interactiveText",
            cols = 24,
            text = L["BUFF bar displays status bar content tracked in {Cooldown Manager} Buff category. For custom bar monitors, use Graphic Monitor."],
            links = {
                [L["Cooldown Manager"]] = function()
                    VFlow.openCooldownManager()
                end,
            }
        },
        { type = "spacer", height = 6, cols = 24 },

        { type = "subtitle", text = L["Display"], cols = 24 },
        { type = "separator", cols = 24 },
        { type = "checkbox", key = "showName", label = L["Show BUFF name"], cols = 12 },
        { type = "checkbox", key = "showDuration", label = L["Show duration"], cols = 12 },
        { type = "checkbox", key = "showStack", label = L["Show stack"], cols = 12 },
        { type = "spacer", height = 10, cols = 24 },

        { type = "subtitle", text = L["Layout"], cols = 24 },
        { type = "separator", cols = 24 },
        {
            type = "dropdown",
            key = "growDirection",
            label = L["Grow direction"],
            cols = 12,
            items = {
                { L["Grow down"], "DOWN" },
                { L["Grow up"], "UP" },
            }
        },
        { type = "spacer", height = 5, cols = 24 },
        {
            type = "dropdown",
            key = "iconPosition",
            label = L["Icon position"],
            cols = 12,
            items = {
                { L["Left"], "LEFT" },
                { L["Right"], "RIGHT" },
                { L["Hide"], "HIDDEN" },
            }
        },
        {
            type = "if",
            dependsOn = "iconPosition",
            condition = function(cfg) return cfg.iconPosition ~= "HIDDEN" end,
            children = {
                { type = "slider", key = "iconGap", label = L["Icon gap"], min = -1, max = 20, step = 1, cols = 12 },
            }
        },
        { type = "spacer", height = 10, cols = 24 },

        { type = "subtitle", text = L["Size"], cols = 24 },
        { type = "separator", cols = 24 },
        { type = "slider", key = "barWidth", label = L["Bar width"], min = 80, max = 600, step = 1, cols = 8 },
        { type = "slider", key = "barHeight", label = L["Bar height"], min = 4, max = 40, step = 1, cols = 8 },
        { type = "slider", key = "barSpacing", label = L["Bar spacing"], min = -1, max = 20, step = 1, cols = 8 },
        { type = "spacer", height = 10, cols = 24 },

        { type = "subtitle", text = L["Appearance"], cols = 24 },
        { type = "separator", cols = 24 },
        { type = "texturePicker", key = "barTexture", label = L["Bar texture"], cols = 8 },
        { type = "colorPicker", key = "barColor", label = L["Bar color"], hasAlpha = true, cols = 8 },
        { type = "colorPicker", key = "barBackgroundColor", label = L["Background color"], hasAlpha = true, cols = 8 },
        { type = "spacer", height = 10, cols = 24 },

        {
            type = "if",
            dependsOn = "showName",
            condition = function(cfg) return cfg.showName == true end,
            children = {
                Grid.fontGroup("nameFont", L["Name text style"]),
            }
        },
        {
            type = "if",
            dependsOn = "showDuration",
            condition = function(cfg) return cfg.showDuration == true end,
            children = {
                Grid.fontGroup("durationFont", L["Duration text style"]),
            }
        },
        {
            type = "if",
            dependsOn = "showStack",
            condition = function(cfg) return cfg.showStack == true end,
            children = {
                Grid.fontGroup("stackFont", L["Stack text style"]),
            }
        },
    }

    Grid.render(container, layout, db, MODULE_KEY)
end

-- =========================================================
-- SECTION 4: 公共接口
-- =========================================================

if not VFlow.Modules then
    VFlow.Modules = {}
end

VFlow.Modules.BuffBar = {
    renderContent = renderContent,
}
