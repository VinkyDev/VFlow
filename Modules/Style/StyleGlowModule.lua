local VFlow = _G.VFlow
if not VFlow then return end

local MODULE_KEY = "VFlow.StyleGlow"

VFlow.registerModule(MODULE_KEY, {
    name = "发光样式",
    description = "发光样式设置",
})

-- 默认配置
local defaults = {
    glowType = "proc",
    useCustomColor = false,
    color = { r = 0.95, g = 0.95, b = 0.32, a = 1 },

    -- Pixel Glow
    pixelLines = 8,
    pixelFrequency = 0.2,
    pixelLength = 0,
    pixelThickness = 2,
    pixelXOffset = 0,
    pixelYOffset = 0,

    -- Autocast Glow
    autocastParticles = 4,
    autocastFrequency = 0.2,
    autocastScale = 1,
    autocastXOffset = 0,
    autocastYOffset = 0,

    -- Button Glow
    buttonFrequency = 0,

    -- Proc Glow
    procDuration = 1,
    procXOffset = 0,
    procYOffset = 0,
}

local db = VFlow.getDB(MODULE_KEY, defaults)

local function renderContent(container, menuKey)
    local layout = {
        { type = "title", text = "发光样式", cols = 24 },
        { type = "separator", cols = 24 },

        -- 发光类型选择
        { type = "dropdown", key = "glowType", label = "发光类型", cols = 12,
            items = {
                { "像素发光", "pixel" },
                { "自动施法发光", "autocast" },
                { "按钮发光", "button" },
                { "触发发光", "proc" },
            }
        },

        { type = "spacer", cols = 24, height = 10 },

        -- 自定义颜色
        { type = "checkbox", key = "useCustomColor", label = "使用自定义颜色", cols = 12 },
        { type = "colorPicker", key = "color", label = "发光颜色", cols = 12 },

        { type = "separator", cols = 24 },

        -- Pixel Glow 配置
        { type = "if", dependsOn = "glowType",
            condition = function(cfg) return cfg.glowType == "pixel" end,
            children = {
                { type = "subtitle", text = "像素发光设置", cols = 24 },
                { type = "slider", key = "pixelLines", label = "线条数", min = 1, max = 20, step = 1, cols = 12 },
                { type = "slider", key = "pixelFrequency", label = "频率", min = -2, max = 2, step = 0.05, cols = 12 },
                { type = "slider", key = "pixelLength", label = "长度 (0=自动)", min = 0, max = 20, step = 1, cols = 12 },
                { type = "slider", key = "pixelThickness", label = "粗细", min = 1, max = 10, step = 1, cols = 12 },
                { type = "slider", key = "pixelXOffset", label = "X偏移", min = -20, max = 20, step = 1, cols = 12 },
                { type = "slider", key = "pixelYOffset", label = "Y偏移", min = -20, max = 20, step = 1, cols = 12 },
            }
        },

        -- Autocast Glow 配置
        { type = "if", dependsOn = "glowType",
            condition = function(cfg) return cfg.glowType == "autocast" end,
            children = {
                { type = "subtitle", text = "自动施法发光设置", cols = 24 },
                { type = "slider", key = "autocastParticles", label = "粒子数", min = 1, max = 16, step = 1, cols = 12 },
                { type = "slider", key = "autocastFrequency", label = "频率", min = -2, max = 2, step = 0.05, cols = 12 },
                { type = "slider", key = "autocastScale", label = "缩放", min = 0.25, max = 3, step = 0.25, cols = 12 },
                { type = "slider", key = "autocastXOffset", label = "X偏移", min = -20, max = 20, step = 1, cols = 12 },
                { type = "slider", key = "autocastYOffset", label = "Y偏移", min = -20, max = 20, step = 1, cols = 12 },
            }
        },

        -- Button Glow 配置
        { type = "if", dependsOn = "glowType",
            condition = function(cfg) return cfg.glowType == "button" end,
            children = {
                { type = "subtitle", text = "按钮发光设置", cols = 24 },
                { type = "slider", key = "buttonFrequency", label = "频率 (0=默认)", min = 0, max = 1, step = 0.01, cols = 12 },
            }
        },

        -- Proc Glow 配置
        { type = "if", dependsOn = "glowType",
            condition = function(cfg) return cfg.glowType == "proc" end,
            children = {
                { type = "subtitle", text = "触发发光设置", cols = 24 },
                { type = "slider", key = "procDuration", label = "持续时间", min = 0.1, max = 5, step = 0.1, cols = 12 },
                { type = "slider", key = "procXOffset", label = "X偏移", min = -20, max = 20, step = 1, cols = 12 },
                { type = "slider", key = "procYOffset", label = "Y偏移", min = -20, max = 20, step = 1, cols = 12 },
            }
        },
    }

    if VFlow.Grid and VFlow.Grid.render then
        VFlow.Grid.render(container, layout, db, MODULE_KEY)
    end
end

if not VFlow.Modules then VFlow.Modules = {} end
VFlow.Modules.StyleGlow = {
    renderContent = renderContent,
}
