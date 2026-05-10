--[[ Core 依赖：
  - Core/Style/StyleApply.lua：发光参数缓存、监听本模块并驱动 LibCustomGlow
  - Core/Style/CooldownStyle.lua：与自定义高亮及 CDM 视觉效果协同
]]

-- =========================================================
-- SECTION 1: 模块注册
-- =========================================================

local VFlow = _G.VFlow
if not VFlow then return end
local L = VFlow.L

local MODULE_KEY = "VFlow.StyleGlow"
local ModuleControlConstants = VFlow.ModuleControlConstants

if not ModuleControlConstants.CORE_ENABLED then return end

VFlow.registerModule(MODULE_KEY, {
    name = L["Glow Style"],
    description = L["Glow style settings"],
})

-- =========================================================
-- SECTION 2: 默认配置
-- =========================================================

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

-- =========================================================
-- SECTION 3: 渲染
-- =========================================================

local function renderContent(container, _menuKey)
    local layout = {
        { type = "title", text = L["Glow Style"], cols = 24 },
        { type = "separator", cols = 24 },

        { type = "dropdown", key = "glowType", label = L["Glow type"], cols = 12,
            items = {
                { L["Pixel glow"], "pixel" },
                { L["Autocast glow"], "autocast" },
                { L["Button glow"], "button" },
                { L["Proc glow"], "proc" },
            }
        },

        { type = "spacer", cols = 24, height = 10 },

        { type = "checkbox", key = "useCustomColor", label = L["Use custom color"], cols = 12 },
        { type = "colorPicker", key = "color", label = L["Glow color"], cols = 12 },

        { type = "separator", cols = 24 },

        { type = "if", dependsOn = "glowType",
            condition = function(cfg) return cfg.glowType == "pixel" end,
            children = {
                { type = "subtitle", text = L["Pixel glow settings"], cols = 24 },
                { type = "slider", key = "pixelLines", label = L["Line count"], min = 1, max = 20, step = 1, cols = 12 },
                { type = "slider", key = "pixelFrequency", label = L["Frequency"], min = -2, max = 2, step = 0.05, cols = 12 },
                { type = "slider", key = "pixelLength", label = L["Length (0=auto)"], min = 0, max = 20, step = 1, cols = 12 },
                { type = "slider", key = "pixelThickness", label = L["Thickness"], min = 1, max = 10, step = 1, cols = 12 },
                { type = "slider", key = "pixelXOffset", label = L["X offset"], min = -20, max = 20, step = 1, cols = 12 },
                { type = "slider", key = "pixelYOffset", label = L["Y offset"], min = -20, max = 20, step = 1, cols = 12 },
            }
        },

        { type = "if", dependsOn = "glowType",
            condition = function(cfg) return cfg.glowType == "autocast" end,
            children = {
                { type = "subtitle", text = L["Autocast glow settings"], cols = 24 },
                { type = "slider", key = "autocastParticles", label = L["Particle count"], min = 1, max = 16, step = 1, cols = 12 },
                { type = "slider", key = "autocastFrequency", label = L["Frequency"], min = -2, max = 2, step = 0.05, cols = 12 },
                { type = "slider", key = "autocastScale", label = L["Scale"], min = 0.25, max = 3, step = 0.25, cols = 12 },
                { type = "slider", key = "autocastXOffset", label = L["X offset"], min = -20, max = 20, step = 1, cols = 12 },
                { type = "slider", key = "autocastYOffset", label = L["Y offset"], min = -20, max = 20, step = 1, cols = 12 },
            }
        },

        { type = "if", dependsOn = "glowType",
            condition = function(cfg) return cfg.glowType == "button" end,
            children = {
                { type = "subtitle", text = L["Button glow settings"], cols = 24 },
                { type = "slider", key = "buttonFrequency", label = L["Frequency (0=default)"], min = 0, max = 1, step = 0.01, cols = 12 },
            }
        },

        { type = "if", dependsOn = "glowType",
            condition = function(cfg) return cfg.glowType == "proc" end,
            children = {
                { type = "subtitle", text = L["Proc glow settings"], cols = 24 },
                { type = "slider", key = "procDuration", label = L["Duration"], min = 0.1, max = 5, step = 0.1, cols = 12 },
                { type = "slider", key = "procXOffset", label = L["X offset"], min = -20, max = 20, step = 1, cols = 12 },
                { type = "slider", key = "procYOffset", label = L["Y offset"], min = -20, max = 20, step = 1, cols = 12 },
            }
        },
    }

    VFlow.Grid.render(container, layout, db, MODULE_KEY)
end

-- =========================================================
-- SECTION 4: 公共接口
-- =========================================================

if not VFlow.Modules then
    VFlow.Modules = {}
end

VFlow.Modules.StyleGlow = {
    renderContent = renderContent,
}
