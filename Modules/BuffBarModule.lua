local VFlow = _G.VFlow
if not VFlow then return end

local MODULE_KEY = "VFlow.BuffBar"

VFlow.registerModule(MODULE_KEY, {
    name = "BUFF条",
    description = "BUFF条形配置",
})

local defaults = {
    barWidth = 200,
    barHeight = 20,
    barSpacing = 1,
    barTexture = "Solid",
    barColor = { r = 0.4, g = 0.6, b = 0.9, a = 1 },
    barBackgroundColor = { r = 0.1, g = 0.1, b = 0.1, a = 0.8 },
    dynamicLayout = true,
    growDirection = "top",
    iconPosition = "LEFT",
    iconGap = 1,
    showName = true,
    showDuration = true,
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

local function renderContent(container)
    local Grid = VFlow.Grid

    local layout = {
        { type = "title", text = "BUFF条", cols = 24 },
        { type = "separator", cols = 24 },

        { type = "subtitle", text = "显示", cols = 24 },
        { type = "separator", cols = 24 },
        { type = "checkbox", key = "showName", label = "显示BUFF名称", cols = 12 },
        { type = "checkbox", key = "showDuration", label = "显示持续时间", cols = 12 },
        { type = "spacer", height = 10, cols = 24 },

        { type = "subtitle", text = "布局", cols = 24 },
        { type = "separator", cols = 24 },
        { type = "checkbox", key = "dynamicLayout", label = "动态布局", cols = 12 },
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
                    items = {
                        { "从顶部增长", "top" },
                        { "从底部增长", "bottom" },
                    }
                },
            }
        },
        { type = "spacer", height = 5, cols = 24 },
        {
            type = "dropdown",
            key = "iconPosition",
            label = "图标位置",
            cols = 12,
            items = {
                { "左侧", "LEFT" },
                { "右侧", "RIGHT" },
                { "隐藏", "HIDDEN" },
            }
        },
        {
            type = "if",
            dependsOn = "iconPosition",
            condition = function(cfg) return cfg.iconPosition ~= "HIDDEN" end,
            children = {
                { type = "slider", key = "iconGap", label = "图标间距", min = -1, max = 20, step = 1, cols = 12 },
            }
        },
        { type = "spacer", height = 10, cols = 24 },

        { type = "subtitle", text = "尺寸", cols = 24 },
        { type = "separator", cols = 24 },
        { type = "slider", key = "barWidth", label = "条宽", min = 80, max = 600, step = 1, cols = 8 },
        { type = "slider", key = "barHeight", label = "条高", min = 4, max = 40, step = 1, cols = 8 },
        { type = "slider", key = "barSpacing", label = "条间距", min = -1, max = 20, step = 1, cols = 8 },
        { type = "spacer", height = 10, cols = 24 },

        { type = "subtitle", text = "外观", cols = 24 },
        { type = "separator", cols = 24 },
        { type = "texturePicker", key = "barTexture", label = "条材质", cols = 8 },
        { type = "colorPicker", key = "barColor", label = "条颜色", hasAlpha = true, cols = 8 },
        { type = "colorPicker", key = "barBackgroundColor", label = "背景颜色", hasAlpha = true, cols = 8 },
        { type = "spacer", height = 10, cols = 24 },

        {
            type = "if",
            dependsOn = "showName",
            condition = function(cfg) return cfg.showName == true end,
            children = {
                Grid.fontGroup("nameFont", "名称文本样式"),
            }
        },
        {
            type = "if",
            dependsOn = "showDuration",
            condition = function(cfg) return cfg.showDuration == true end,
            children = {
                Grid.fontGroup("durationFont", "持续时间文本样式"),
            }
        },
    }

    Grid.render(container, layout, db, MODULE_KEY)
end

if not VFlow.Modules then VFlow.Modules = {} end
VFlow.Modules.BuffBar = {
    renderContent = renderContent,
}
