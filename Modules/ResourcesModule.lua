--[[ Core 依赖：ClassResourceMap、ResourceStyles、ResourceBars；Infra BarFrameKit、PixelPerfect ]]

-- =========================================================
-- SECTION 1: 模块注册
-- =========================================================

local VFlow = _G.VFlow
if not VFlow then return end
local L = VFlow.L

local MODULE_KEY = "VFlow.Resources"

VFlow.registerModule(MODULE_KEY, {
    name = L["Resource bar"],
    description = L["Resource module description"],
})

local CR = VFlow.ClassResourceMap
local RS = VFlow.ResourceStyles
local Utils = VFlow.Utils
local mergeLayouts = Utils.mergeLayouts

-- =========================================================
-- SECTION 2: 常量（锚点与滑块范围，同 SkillsModule）
-- =========================================================

local UI_LIMITS = {
    BAR_WIDTH = { min = 40, max = 600, step = 1 },
    BAR_HEIGHT = { min = 4, max = 80, step = 1 },
    POSITION = { min = -2000, max = 2000, step = 1 },
}

local STANDALONE_ANCHOR_FRAME_OPTIONS = {
    { L["UI parent"],             "uiparent" },
    { L["Player frame"],          "player" },
    { L["Important skills bar"],  "essential" },
    { L["Efficiency skills bar"], "utility" },
}

local RELATIVE_ANCHOR_POINT_OPTIONS = {
    { L["CENTER"], "CENTER" },
    { L["TOP"],    "TOP" },
    { L["BOTTOM"], "BOTTOM" },
    { L["LEFT"],   "LEFT" },
    { L["RIGHT"],  "RIGHT" },
}

local PLAYER_ANCHOR_CORNER_OPTIONS = {
    { L["Top-left"],     "TOPLEFT" },
    { L["Top-right"],    "TOPRIGHT" },
    { L["Bottom-left"],  "BOTTOMLEFT" },
    { L["Bottom-right"], "BOTTOMRIGHT" },
}

local BAR_DIRECTION_OPTIONS = {
    { L["Horizontal"], "horizontal" },
    { L["Vertical"],   "vertical" },
}

local BAR_WIDTH_MODE_OPTIONS = {
    { L["Manual width"],                "manual" },
    { L["Match important skills bar"],  "sync_essential" },
    { L["Match efficiency skills bar"], "sync_utility" },
}

local BORDER_THICKNESS_OPTIONS = {
    { "1px",      "1" },
    { L["Thin"],  "2" },
    { L["Thick"], "3" },
}

-- =========================================================
-- SECTION 3: 默认配置
-- =========================================================

local RESOURCE_BAR_BG = { r = 0.2, g = 0.2, b = 0.2, a = 0.5 }

local function getDefaultBarConfig()
    return {
        enabled = true,
        specEnabled = {},
        barWidthMode = "sync_essential",
        barWidth = 200,
        barHeight = 9,
        barTexture = "Solid",
        barDirection = "horizontal",
        barReverse = false,
        borderColor = { r = 0, g = 0, b = 0, a = 1 },
        borderThickness = "1",
        segmentGap = 0,
        smoothProgress = true,
        fasterUpdates = false,
        anchorFrame = "essential",
        relativePoint = "TOP",
        playerAnchorPosition = "BOTTOMLEFT",
        x = 0,
        y = 2,
        textFont = {
            size = 14,
            font = "默认",
            outline = "OUTLINE",
            color = { r = 1, g = 1, b = 1, a = 1 },
            position = "CENTER",
            offsetX = 0,
            offsetY = 0,
        },
    }
end

local secondaryBarDefaults
local function getSecondaryBarDefaults()
    if not secondaryBarDefaults then
        local c = getDefaultBarConfig()
        c.y = 10
        c.textFont.size = 12
        c.textFont.offsetY = 4
        c.usePrimaryPositionWhenPrimaryHidden = true
        secondaryBarDefaults = c
    end
    return secondaryBarDefaults
end

local defaults = {
    primaryBar = getDefaultBarConfig(),
    secondaryBar = getSecondaryBarDefaults(),
    resourceStyles = RS.BuildFullResourceStylesDefaults(),
    resourceBarBackground = RESOURCE_BAR_BG,
}

local db = VFlow.getDB(MODULE_KEY, defaults)
local resourceStylesHost = nil
local resourceStyleExpanded = {}
local buildResourceStylesLayout

-- specEnabled 键 "s"..专精ID；缺省视为显示，首次打开写入 true 以便复选框状态一致
local function seedSpecEnabled(bar, storePathPrefix)
    local _, classFile = UnitClass("player")
    local ids = CR.GetUniqueSpecIdsForClass(classFile)
    bar.specEnabled = bar.specEnabled or {}
    for _, sid in ipairs(ids) do
        local k = "s" .. tostring(sid)
        if bar.specEnabled[k] == nil then
            bar.specEnabled[k] = true
            if VFlow.Store and VFlow.Store.set then
                VFlow.Store.set(MODULE_KEY, storePathPrefix .. ".specEnabled." .. k, true)
            end
        end
    end
end

-- =========================================================
-- SECTION 4: 布局
-- =========================================================

local function buildOverviewLayout(menuKey)
    local rows = CR and CR.GetRowsForPlayer and CR.GetRowsForPlayer() or {}
    local useSecondary = menuKey == "resource_secondary"
    local _, classFile = UnitClass("player")
    local totalSpecs = #(CR.GetUniqueSpecIdsForClass(classFile) or {})
    local layout = {
        { type = "subtitle",  text = useSecondary and L["Secondary values by spec / form"] or L["Primary values by spec / form"], cols = 24 },
        { type = "separator", cols = 24 },
    }
    if #rows == 0 then
        layout[#layout + 1] = { type = "description", text = L["No resource map rows"], cols = 24 }
        return layout
    end
    local grouped = {}
    local ordered = {}
    local any = false
    for _, r in ipairs(rows) do
        local token
        if useSecondary then
            token = r.secondary
        else
            token = r.primary
        end
        if token then
            any = true
            local groupKey = (r.formId and ("form:" .. tostring(r.formId)) or "spec") .. "|" .. tostring(token)
            local entry = grouped[groupKey]
            if not entry then
                entry = {
                    formId = r.formId,
                    token = token,
                    specIds = {},
                    specSeen = {},
                }
                grouped[groupKey] = entry
                ordered[#ordered + 1] = entry
            end
            local specKey = tostring(r.specId)
            if not entry.specSeen[specKey] then
                entry.specSeen[specKey] = true
                entry.specIds[#entry.specIds + 1] = r.specId
            end
        end
    end
    if useSecondary and not any then
        layout[#layout + 1] = { type = "description", text = L["No secondary resource for class"], cols = 24 }
        return layout
    end
    for _, entry in ipairs(ordered) do
        local specNames = {}
        for _, specId in ipairs(entry.specIds) do
            specNames[#specNames + 1] = CR.GetSpecDisplayName(specId)
        end
        local left = table.concat(specNames, " / ")
        if entry.formId then
            local formLabel = CR.FormatFormLabel(L, entry.formId)
            if #entry.specIds == totalSpecs then
                left = formLabel
            else
                left = formLabel .. " · " .. left
            end
        end
        layout[#layout + 1] = {
            type = "description",
            text = string.format(L["Resource map compact line"], left, CR.FormatResourceToken(L, entry.token)),
            cols = 12,
        }
    end
    return layout
end

local function buildSpecVisibilityLayout()
    local _, classFile = UnitClass("player")
    local ids = CR.GetUniqueSpecIdsForClass(classFile)
    local block = {
        { type = "subtitle",  text = L["Per-spec visibility"], cols = 24 },
        { type = "separator", cols = 24 },
    }
    for _, sid in ipairs(ids) do
        local k = "specEnabled.s" .. tostring(sid)
        block[#block + 1] = {
            type = "checkbox",
            key = k,
            label = CR.GetSpecDisplayName(sid),
            cols = 6,
        }
    end
    block[#block + 1] = { type = "spacer", height = 10, cols = 24 }
    return block
end

local function buildBarLayout(pageTitle, menuKey)
    local Grid = VFlow.Grid
    return mergeLayouts({
            { type = "title",     text = pageTitle, cols = 24 },
            { type = "separator", cols = 24 },
        },
        buildOverviewLayout(menuKey),
        {
            { type = "spacer",    height = 8,      cols = 24 },

            {
                type = "subtitle",
                text = L["Base Settings"],
                cols = 24,
            },
            { type = "separator", cols = 24 },
            { type = "checkbox",  key = "enabled", label = L["Enable"], cols = 12 },
        },
        menuKey == "resource_secondary" and {
            {
                type = "checkbox",
                key = "usePrimaryPositionWhenPrimaryHidden",
                label = L["Use primary bar position when primary hidden"],
                cols = 24,
            },
        } or nil,
        buildSpecVisibilityLayout(),
        {
            {
                type = "dropdown",
                key = "barWidthMode",
                label = L["Width mode"],
                cols = 12,
                items = BAR_WIDTH_MODE_OPTIONS,
            },
            {
                type = "if",
                dependsOn = "barWidthMode",
                condition = function(cfg)
                    return (cfg.barWidthMode or "sync_essential") == "manual"
                end,
                children = {
                    {
                        type = "slider",
                        key = "barWidth",
                        label = L["Bar width"],
                        min = UI_LIMITS.BAR_WIDTH.min,
                        max = UI_LIMITS.BAR_WIDTH.max,
                        step = 1,
                        cols = 12,
                    },
                },
            },
            {
                type = "slider",
                key = "barHeight",
                label = L["Bar height"],
                min = UI_LIMITS.BAR_HEIGHT.min,
                max = UI_LIMITS.BAR_HEIGHT.max,
                step = 1,
                cols = 12,
            },
            {
                type = "subtitle",
                text = L["Style Config"],
                cols = 24,
            },
            { type = "separator", cols = 24 },
            {
                type = "texturePicker",
                key = "barTexture",
                label = L["Bar texture"],
                cols = 24,
            },
            {
                type = "dropdown",
                key = "barDirection",
                label = L["Direction"],
                cols = 8,
                items = BAR_DIRECTION_OPTIONS,
            },
            {
                type = "checkbox",
                key = "barReverse",
                label = L["Reverse"],
                cols = 16,
            },
            {
                type = "colorPicker",
                key = "borderColor",
                label = L["Border color"],
                hasAlpha = true,
                cols = 8,
            },
            {
                type = "dropdown",
                key = "borderThickness",
                label = L["Border thickness"],
                cols = 8,
                items = BORDER_THICKNESS_OPTIONS,
            },
            {
                type = "slider",
                key = "segmentGap",
                label = L["Segment gap"],
                min = 0,
                max = 10,
                step = 1,
                cols = 8,
            },
            { type = "checkbox",  key = "smoothProgress", label = L["Smooth bar fill"],    cols = 12 },
            { type = "checkbox",  key = "fasterUpdates",  label = L["Faster bar refresh"], cols = 12 },
            { type = "spacer",    height = 10,            cols = 24 },

            {
                type = "subtitle",
                text = L["Position Settings"],
                cols = 24,
            },
            { type = "separator",   cols = 24 },
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
                condition = function(cfg)
                    return cfg.anchorFrame == "player"
                end,
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
                condition = function(cfg)
                    return cfg.anchorFrame == "player"
                end,
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
                        cols = 12,
                    },
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

            { type = "spacer",      height = 10,                                           cols = 24 },
            Grid.fontGroup("textFont", L["Bar text style"]),
        })
end

local function isResourceStyleExpanded(token, isCurrentClass)
    if isCurrentClass then
        return true
    end
    return resourceStyleExpanded[token] == true
end

local function refreshResourceStylesLayout()
    if resourceStylesHost and VFlow.Grid and VFlow.Grid.render then
        VFlow.Grid.render(resourceStylesHost, buildResourceStylesLayout(), db, MODULE_KEY, nil)
    end
end

local function appendResourceStyleDetailRows(layout, token)
    local base = "resourceStyles." .. token
    if RS.StyleKeyHasRechargeColorOption(token) then
        layout[#layout + 1] = {
            type = "checkbox",
            key = base .. ".rechargeColorCustom",
            label = L["Custom recharging color"],
            cols = 12,
        }
        layout[#layout + 1] = {
            type = "if",
            dependsOn = base .. ".rechargeColorCustom",
            condition = function(cfg)
                local e = cfg.resourceStyles and cfg.resourceStyles[token]
                return e and e.rechargeColorCustom == true
            end,
            children = {
                {
                    type = "colorPicker",
                    key = base .. ".rechargeBarColor",
                    label = L["Recharging state color"],
                    hasAlpha = true,
                    cols = 12,
                },
            },
        }
    end
    layout[#layout + 1] = {
        type = "checkbox",
        key = base .. ".thresholdColorsEnabled",
        label = L["Threshold fill colors"],
        cols = 24,
    }
    layout[#layout + 1] = {
        type = "if",
        dependsOn = base .. ".thresholdColorsEnabled",
        condition = function(cfg)
            local e = cfg.resourceStyles and cfg.resourceStyles[token]
            return e and e.thresholdColorsEnabled == true
        end,
        children = {
            {
                type = "if",
                dependsOn = { base .. ".thresholdColorsEnabled", base .. ".showPercent" },
                condition = function(cfg)
                    local e = cfg.resourceStyles and cfg.resourceStyles[token]
                    return e and e.thresholdColorsEnabled == true and e.showPercent == true
                end,
                children = {
                    {
                        type = "slider",
                        key = base .. ".threshold1",
                        label = L["Threshold boundary 1 (percent)"],
                        min = 0,
                        max = 100,
                        step = 1,
                        cols = 12,
                    },
                    {
                        type = "colorPicker",
                        key = base .. ".thresholdColor1",
                        label = L["Color above threshold 1"],
                        hasAlpha = true,
                        cols = 12,
                    },
                    {
                        type = "if",
                        dependsOn = { base .. ".thresholdColorsEnabled", base .. ".threshold1", base .. ".showPercent" },
                        condition = function(cfg)
                            local e = cfg.resourceStyles and cfg.resourceStyles[token]
                            if not e or e.thresholdColorsEnabled ~= true or e.showPercent ~= true then
                                return false
                            end
                            local t1 = tonumber(e.threshold1)
                            return t1 ~= nil and t1 > 0
                        end,
                        children = {
                            {
                                type = "slider",
                                key = base .. ".threshold2",
                                label = L["Threshold boundary 2 (percent)"],
                                min = 0,
                                max = 100,
                                step = 1,
                                cols = 12,
                            },
                            {
                                type = "colorPicker",
                                key = base .. ".thresholdColor2",
                                label = L["Color above threshold 2"],
                                hasAlpha = true,
                                cols = 12,
                            },
                        },
                    },
                },
            },
            {
                type = "if",
                dependsOn = { base .. ".thresholdColorsEnabled", base .. ".showPercent" },
                condition = function(cfg)
                    local e = cfg.resourceStyles and cfg.resourceStyles[token]
                    return e and e.thresholdColorsEnabled == true and e.showPercent ~= true
                end,
                children = {
                    {
                        type = "input",
                        key = base .. ".threshold1",
                        label = L["Threshold boundary 1 (value)"],
                        numeric = true,
                        cols = 12,
                    },
                    {
                        type = "colorPicker",
                        key = base .. ".thresholdColor1",
                        label = L["Color above threshold 1"],
                        hasAlpha = true,
                        cols = 12,
                    },
                    {
                        type = "if",
                        dependsOn = { base .. ".thresholdColorsEnabled", base .. ".threshold1", base .. ".showPercent" },
                        condition = function(cfg)
                            local e = cfg.resourceStyles and cfg.resourceStyles[token]
                            if not e or e.thresholdColorsEnabled ~= true or e.showPercent == true then
                                return false
                            end
                            local t1 = tonumber(e.threshold1)
                            return t1 ~= nil and t1 > 0
                        end,
                        children = {
                            {
                                type = "input",
                                key = base .. ".threshold2",
                                label = L["Threshold boundary 2 (value)"],
                                numeric = true,
                                cols = 12,
                            },
                            {
                                type = "colorPicker",
                                key = base .. ".thresholdColor2",
                                label = L["Color above threshold 2"],
                                hasAlpha = true,
                                cols = 12,
                            },
                        },
                    },
                },
            },
        },
    }
end

local function appendResourceStyleRows(layout, token, options)
    options = options or {}
    local isCurrentClass = options.isCurrentClass == true
    local base = "resourceStyles." .. token
    local expanded = isResourceStyleExpanded(token, isCurrentClass)

    layout[#layout + 1] = {
        type = "colorPicker",
        key = base .. ".barColor",
        label = CR.FormatResourceToken(L, token),
        hasAlpha = true,
        cols = 12,
    }
    layout[#layout + 1] = { type = "spacer", height = 1, cols = 24 }

    if isCurrentClass then
        layout[#layout + 1] = {
            type = "checkbox",
            key = base .. ".showText",
            label = L["Show resource text"],
            cols = 6,
        }
        layout[#layout + 1] = {
            type = "checkbox",
            key = base .. ".showPercent",
            label = L["Show as percent"],
            cols = 6,
        }
        appendResourceStyleDetailRows(layout, token)
    else
        layout[#layout + 1] = {
            type = "interactiveText",
            cols = 24,
            text = string.format("{%s}", expanded and L["Collapse settings"] or L["Expand settings"]),
            links = {
                [expanded and L["Collapse settings"] or L["Expand settings"]] = function()
                    resourceStyleExpanded[token] = not expanded
                    refreshResourceStylesLayout()
                end,
            },
        }
        if expanded then
            layout[#layout + 1] = {
                type = "checkbox",
                key = base .. ".showText",
                label = L["Show resource text"],
                cols = 12,
            }
            layout[#layout + 1] = {
                type = "checkbox",
                key = base .. ".showPercent",
                label = L["Show as percent"],
                cols = 12,
            }
            appendResourceStyleDetailRows(layout, token)
        end
    end

    layout[#layout + 1] = { type = "spacer", height = 6, cols = 24 }
end

buildResourceStylesLayout = function()
    local _, classFile = UnitClass("player")
    local classOrder, classSeen = CR.CollectUniqueResourceTokensForClass(classFile)
    local order = RS.GetDisplayKeyOrderForPlayer()
    local layout = {
        { type = "title",     text = L["General resource appearance"], cols = 24 },
        { type = "separator", cols = 24 },
        {
            type = "colorPicker",
            key = "resourceBarBackground",
            label = L["Resource bar background section"],
            hasAlpha = true,
            cols = 12,
        },
        { type = "separator", cols = 24 },
    }
    if #classOrder > 0 then
        layout[#layout + 1] = { type = "subtitle", text = L["This class resources"], cols = 24 }
        layout[#layout + 1] = { type = "separator", cols = 24 }
    end
    local insertedOtherHeader = false
    for _, token in ipairs(order) do
        if not classSeen[token] and not insertedOtherHeader then
            layout[#layout + 1] = { type = "spacer", height = 6, cols = 24 }
            layout[#layout + 1] = {
                type = "subtitle",
                text = L["Other resource types"],
                cols = 24,
            }
            layout[#layout + 1] = { type = "separator", cols = 24 }
            insertedOtherHeader = true
        end
        appendResourceStyleRows(layout, token, { isCurrentClass = classSeen[token] == true })
    end
    return layout
end

-- =========================================================
-- SECTION 5: 渲染入口
-- =========================================================

local function syncModuleDefaults()
    Utils.applyDefaults(db, { resourceBarBackground = RESOURCE_BAR_BG })
    Utils.applyDefaults(db.primaryBar, getDefaultBarConfig())
    Utils.applyDefaults(db.secondaryBar, getSecondaryBarDefaults())
    db.resourceStyles = db.resourceStyles or {}
    Utils.applyDefaults(db.resourceStyles, RS.BuildFullResourceStylesDefaults())
end

local function renderContent(container, menuKey)
    local Grid = VFlow.Grid
    syncModuleDefaults()

    local panel = CreateFrame("Frame", nil, container)
    panel:SetPoint("TOPLEFT", 8, -6)
    panel:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT", -8, 8)

    if menuKey == "resource_styles" then
        resourceStylesHost = panel
        Grid.render(panel, buildResourceStylesLayout(), db, MODULE_KEY, nil)
        return
    end

    resourceStylesHost = nil

    local isSecondary = menuKey == "resource_secondary"
    local pageTitle = isSecondary and L["Secondary resource bar"] or L["Primary resource bar"]
    local barConfig = isSecondary and db.secondaryBar or db.primaryBar
    local configPath = isSecondary and "secondaryBar" or "primaryBar"

    seedSpecEnabled(barConfig, configPath)

    Grid.render(panel, buildBarLayout(pageTitle, menuKey), barConfig, MODULE_KEY, configPath)
end

-- =========================================================
-- SECTION 6: 公共接口
-- =========================================================

if not VFlow.Modules then
    VFlow.Modules = {}
end

VFlow.Modules.Resources = {
    renderContent = renderContent,
}

C_Timer.After(0, function()
    if VFlow.ResourceBars and VFlow.ResourceBars.OnModuleReady then
        VFlow.ResourceBars.OnModuleReady()
    end
end)
