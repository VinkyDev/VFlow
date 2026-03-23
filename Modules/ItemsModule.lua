--[[ Core 依赖：
  - Core/ItemGroups.lua：主组/自定义组/追加到技能条等布局与图标
  - Core/ItemAutoData.lua：手动物品与种族等自动数据（查询）
  - Core/ItemsManualOrder.lua：entryOrder 归一化（查询/整理）
  - Core/CooldownStyle.lua：监听 Items 配置并应用样式
  例外：新档主组无物品时写入示例物品并落盘（applyMainGroupStarterItemsOnce）。
]]

-- =========================================================
-- SECTION 1: 模块注册
-- =========================================================

local VFlow = _G.VFlow
if not VFlow then return end

local MODULE_KEY = "VFlow.Items"

VFlow.registerModule(MODULE_KEY, {
    name = "额外CD监控",
    description = "物品与额外冷却追踪",
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

local DISPLAY_MODE_OPTIONS = {
    { "单独分组", "standalone" },
    { "追加到重要技能", "append_important" },
    { "追加到效能技能", "append_efficiency" },
}

local ANCHOR_FRAME_OPTIONS = {
    { "玩家框体", "player" },
    { "UI父框体", "uiparent" },
}

local PLAYER_ANCHOR_POSITION_OPTIONS = {
    { "左上", "TOPLEFT" },
    { "右上", "TOPRIGHT" },
    { "左下", "BOTTOMLEFT" },
    { "右下", "BOTTOMRIGHT" },
}

local APPEND_ROW_OPTIONS = {
    { "第一行", 1 },
    { "第二行", 2 },
}

local APPEND_SIDE_OPTIONS = {
    { "起点", "start" },
    { "终点", "end" },
}

--- 物品在背包/装备位上不可用时（数量为 0 或未装备）
local ITEM_ZERO_COUNT_OPTIONS = {
    { "变灰", "gray" },
    { "隐藏", "hide" },
}

-- =========================================================
-- SECTION 3: 默认配置
-- =========================================================

-- 主组首次空物品列表时写入的示例物品
local MAIN_GROUP_STARTER_ITEM_IDS = {
    5512, -- 治疗石
    241308, -- 圣光潜力药水
    241304, -- 治疗药水
}

-- anchorFrame: "player" 主组默认；新建自定义组用 "uiparent"
-- forCustomGroup: 自定义组默认关闭「自动识别主动饰品 / 种族技能」，主组仍为开启
local function getDefaultGroupConfig(anchorFrame, forCustomGroup)
    local autoDetect = forCustomGroup ~= true
    return {
        _dataVersion = 0,
        groupName = "主组",
        enabled = true,
        displayMode = "standalone",
        anchorFrame = anchorFrame or "player",
        playerAnchorPosition = "BOTTOMLEFT",
        x = 0,
        y = 0,
        width = 25,
        height = 25,
        maxIconsPerRow = 8,
        spacingX = 1,
        spacingY = 1,
        itemIDs = {},
        spellIDs = {},
        entryOrder = {},
        autoTrinkets = autoDetect,
        autoRacialAbility = autoDetect,
        appendTargetRow = 1,
        appendSide = "end",
        itemZeroCountBehavior = "hide",
        showItemCount = true,
        cooldownMaskColor = { r = 0, g = 0, b = 0, a = 0.7 },
        stackFont = {
            size = 8,
            font = "默认",
            outline = "OUTLINE",
            color = { r = 1, g = 1, b = 1, a = 1 },
            position = "BOTTOMRIGHT",
            offsetX = 0,
            offsetY = 0,
        },
        cooldownFont = {
            size = 12,
            font = "默认",
            outline = "OUTLINE",
            color = { r = 1, g = 1, b = 1, a = 1 },
            position = "CENTER",
            offsetX = 0,
            offsetY = 0,
        },
    }
end

local defaults = {
    mainGroup = getDefaultGroupConfig("player"),
    customGroups = {},
}

local db = VFlow.getDB(MODULE_KEY, defaults)
local Utils = VFlow.Utils

--- 仅运行一次：新档 itemIDs 为空时写入示例物品
local function applyMainGroupStarterItemsOnce(profileDb)
    if not profileDb or not profileDb.mainGroup then return end
    local mg = profileDb.mainGroup
    if mg._mainGroupStarterItemsSeeded then return end

    local hadAnyItem = mg.itemIDs and next(mg.itemIDs) ~= nil
    mg._mainGroupStarterItemsSeeded = true

    if not hadAnyItem then
        mg.itemIDs = mg.itemIDs or {}
        for _, itemID in ipairs(MAIN_GROUP_STARTER_ITEM_IDS) do
            mg.itemIDs[itemID] = true
        end
        if VFlow.ItemsManualOrder and VFlow.ItemsManualOrder.Ensure then
            VFlow.ItemsManualOrder.Ensure(mg)
        end
        VFlow.Store.set(MODULE_KEY, "mainGroup.itemIDs", mg.itemIDs)
        VFlow.Store.set(MODULE_KEY, "mainGroup.entryOrder", mg.entryOrder)
    end

    VFlow.Store.set(MODULE_KEY, "mainGroup._mainGroupStarterItemsSeeded", true)
end

applyMainGroupStarterItemsOnce(db)

-- 两次点击交换顺序：{ path = configPath, orderIndex = entryOrder 下标 }
local manualReorderPick

local function bumpGroupDataVersion(groupConfig, configPath)
    groupConfig._dataVersion = (groupConfig._dataVersion or 0) + 1
    VFlow.Store.set(MODULE_KEY, configPath .. "._dataVersion", groupConfig._dataVersion)
end

-- =========================================================
-- SECTION 4: 数据源函数
-- =========================================================

local function getCurrentItems(groupConfig)
    local ItemsManualOrder = VFlow.ItemsManualOrder
    if ItemsManualOrder and ItemsManualOrder.Ensure then
        ItemsManualOrder.Ensure(groupConfig)
    end

    local items = {}
    for idx, e in ipairs(groupConfig.entryOrder or {}) do
        if e.t == "trinket_slot" and groupConfig.autoTrinkets then
            -- 与 ItemAutoData.forEachOnUseTrinketSlot 一致：仅有「使用法术」的饰品才算主动类
            local itemID = GetInventoryItemID("player", e.slot)
            local useSpellID
            if itemID and itemID > 0 then
                _, useSpellID = C_Item.GetItemSpell(itemID)
            end
            if itemID and itemID > 0 and useSpellID and useSpellID > 0 then
                local itemName, _, _, _, _, _, _, _, _, itemIcon = C_Item.GetItemInfo(itemID)
                table.insert(items, {
                    type = "item",
                    id = itemID,
                    spellID = useSpellID,
                    slot = e.slot,
                    name = itemName or ("饰品槽 " .. e.slot),
                    icon = itemIcon or 134400,
                    isAuto = true,
                    orderIndex = idx,
                })
            end
            -- 空槽或非主动饰品：不占用设置列表（与旧版「仅显示可监控主动饰品」一致）
        elseif e.t == "racial" and groupConfig.autoRacialAbility then
            local spellInfo = C_Spell.GetSpellInfo(e.id)
            local name = spellInfo and spellInfo.name
            local icon = spellInfo and spellInfo.iconID
            table.insert(items, {
                type = "spell",
                id = e.id,
                name = name or ("技能 " .. e.id),
                icon = icon or 134400,
                isAuto = true,
                orderIndex = idx,
            })
        elseif e.t == "item" and groupConfig.itemIDs[e.id] then
            local configId = e.id
            local displayId = configId
            local IAD = VFlow.ItemAutoData
            if IAD and IAD.resolveManualCarriedItemID then
                displayId = IAD.resolveManualCarriedItemID(configId)
            end
            C_Item.RequestLoadItemDataByID(configId)
            C_Item.RequestLoadItemDataByID(displayId)
            local itemName, _, _, _, _, _, _, _, _, itemIcon = C_Item.GetItemInfo(displayId)
            if not itemName or itemName == "" then
                itemName, _, _, _, _, _, _, _, _, itemIcon = C_Item.GetItemInfo(configId)
            end
            table.insert(items, {
                type = "item",
                id = configId,
                displayItemId = (displayId ~= configId) and displayId or nil,
                name = itemName or ("物品 " .. configId),
                icon = itemIcon or 134400,
                isAuto = false,
                orderIndex = idx,
            })
        elseif e.t == "spell" and groupConfig.spellIDs[e.id] then
            local spellInfo = C_Spell.GetSpellInfo(e.id)
            local name = spellInfo and spellInfo.name
            local icon = spellInfo and spellInfo.iconID
            table.insert(items, {
                type = "spell",
                id = e.id,
                name = name or ("技能 " .. e.id),
                icon = icon or 134400,
                isAuto = false,
                orderIndex = idx,
            })
        end
    end

    return items
end

-- =========================================================
-- SECTION 5: 布局构建器
-- =========================================================

local mergeLayouts = Utils.mergeLayouts

-- 物品/技能选择器
local function buildItemSpellSelector(groupConfig, options)
    local configPath = options.isCustom and ("customGroups." .. options.groupIndex .. ".config") or "mainGroup"
    return {
        { type = "subtitle", text = "物品/技能选择", cols = 24 },
        { type = "separator", cols = 24 },

        {
            type = "interactiveText",
            cols = 24,
            text = "可在{编辑模式}中预览和拖拽修改位置",
            links = {
                ["编辑模式"] = function()
                    VFlow.toggleSystemEditMode()
                end,
            }
        },
        { type = "spacer", height = 2, cols = 24 },

        { type = "checkbox", key = "autoTrinkets", label = "自动识别主动饰品（槽位13/14）", cols = 12 },
        { type = "checkbox", key = "autoRacialAbility", label = "自动识别种族技能", cols = 12 },
        { type = "spacer", height = 10, cols = 24 },

        { type = "description", text = "手动添加物品或技能:", cols = 24 },
        { type = "spacer", height = 5, cols = 24 },
        { type = "input", key = "_inputItemID", label = "物品ID", cols = 6, numeric = true, labelOnLeft = true },
        {
            type = "button",
            text = "添加物品",
            cols = 3,
            onClick = function(cfg)
                local itemIDText = cfg._inputItemID or ""
                if itemIDText == "" then
                    print("|cffff0000VFlow:|r 请输入物品ID")
                    return
                end

                local itemID = tonumber(itemIDText)
                if not itemID then
                    print("|cffff0000VFlow:|r 无效的物品ID")
                    return
                end

                if cfg.itemIDs[itemID] then
                    print("|cffff0000VFlow:|r 该物品已添加")
                    return
                end

                cfg.itemIDs[itemID] = true
                if VFlow.ItemsManualOrder and VFlow.ItemsManualOrder.Ensure then
                    VFlow.ItemsManualOrder.Ensure(cfg)
                end
                VFlow.Store.set(MODULE_KEY, configPath .. ".itemIDs", cfg.itemIDs)
                VFlow.Store.set(MODULE_KEY, configPath .. ".entryOrder", cfg.entryOrder)
                cfg._inputItemID = ""
                VFlow.Store.set(MODULE_KEY, configPath .. "._inputItemID", "")
                print("|cff00ff00VFlow:|r 已添加物品 " .. itemID)
            end,
        },
        { type = "spacer", cols = 2 },
        { type = "input", key = "_inputSpellID", label = "技能ID", cols = 6, numeric = true, labelOnLeft = true },
        {
            type = "button",
            text = "添加技能",
            cols = 3,
            onClick = function(cfg)
                local spellIDText = cfg._inputSpellID or ""
                if spellIDText == "" then
                    print("|cffff0000VFlow:|r 请输入技能ID")
                    return
                end

                local spellID = tonumber(spellIDText)
                if not spellID then
                    print("|cffff0000VFlow:|r 无效的技能ID")
                    return
                end

                if cfg.spellIDs[spellID] then
                    print("|cffff0000VFlow:|r 该技能已添加")
                    return
                end

                cfg.spellIDs[spellID] = true
                if VFlow.ItemsManualOrder and VFlow.ItemsManualOrder.Ensure then
                    VFlow.ItemsManualOrder.Ensure(cfg)
                end
                VFlow.Store.set(MODULE_KEY, configPath .. ".spellIDs", cfg.spellIDs)
                VFlow.Store.set(MODULE_KEY, configPath .. ".entryOrder", cfg.entryOrder)
                cfg._inputSpellID = ""
                VFlow.Store.set(MODULE_KEY, configPath .. "._inputSpellID", "")
                print("|cff00ff00VFlow:|r 已添加技能 " .. spellID)
            end,
        },

        { type = "spacer", height = 10, cols = 24 },
        {
            type = "description",
            text = "先后点两个交换顺序，shift+点击可移除；自动项关闭开关可隐藏。",
            cols = 24,
        },
        { type = "spacer", height = 5, cols = 24 },

        {
            type = "for",
            cols = 2,
            dependsOn = {
                "autoTrinkets",
                "autoRacialAbility",
                "itemIDs",
                "spellIDs",
                "entryOrder",
                "_dataVersion",
            },
            dataSource = function()
                return getCurrentItems(groupConfig)
            end,
            template = {
                type = "iconButton",
                icon = function(itemData) return itemData.icon end,
                size = 40,
                borderColor = function(itemData)
                    if not itemData.orderIndex then
                        return nil
                    end
                    if
                        manualReorderPick
                        and manualReorderPick.path == configPath
                        and manualReorderPick.orderIndex == itemData.orderIndex
                    then
                        return { 1, 0.82, 0.2, 1 }
                    end
                    return nil
                end,
                tooltip = function(itemData)
                    return function(tooltip)
                        if itemData.type == "item" then
                            local tid = (itemData.displayItemId and itemData.displayItemId > 0)
                                and itemData.displayItemId
                                or itemData.id
                            if tid and tid > 0 then
                                tooltip:SetItemByID(tid)
                            else
                                tooltip:SetText(itemData.name or "", 1, 1, 1)
                            end
                        elseif itemData.type == "spell" and itemData.id then
                            tooltip:SetSpellByID(itemData.id)
                        else
                            tooltip:SetText(itemData.name or "", 1, 1, 1)
                        end
                        tooltip:AddLine(" ")
                        tooltip:AddLine("|cffaaaaaa左键：先后点两个图标交换顺序|r", 1, 1, 1)
                        if itemData.isAuto then
                            tooltip:AddLine("|cff808080自动项：关闭对应开关可隐藏；不可 Shift 删除|r", 1, 1, 1)
                        else
                            tooltip:AddLine("|cffff0000Shift+左键：从监控中移除|r", 1, 1, 1)
                        end
                    end
                end,
                onClick = function(itemData)
                    if IsShiftKeyDown() then
                        if itemData.isAuto then
                            print("|cffff0000VFlow:|r 自动项请关闭「自动识别」开关；不可在此删除")
                            return
                        end
                        if itemData.type == "item" then
                            groupConfig.itemIDs[itemData.id] = nil
                        else
                            groupConfig.spellIDs[itemData.id] = nil
                        end
                        if VFlow.ItemsManualOrder and VFlow.ItemsManualOrder.Ensure then
                            VFlow.ItemsManualOrder.Ensure(groupConfig)
                        end
                        manualReorderPick = nil
                        VFlow.Store.set(MODULE_KEY, configPath .. ".itemIDs", groupConfig.itemIDs)
                        VFlow.Store.set(MODULE_KEY, configPath .. ".spellIDs", groupConfig.spellIDs)
                        VFlow.Store.set(MODULE_KEY, configPath .. ".entryOrder", groupConfig.entryOrder)
                        return
                    end

                    if not itemData.orderIndex then
                        return
                    end
                    local oi = itemData.orderIndex
                    if not manualReorderPick or manualReorderPick.path ~= configPath then
                        manualReorderPick = { path = configPath, orderIndex = oi }
                        bumpGroupDataVersion(groupConfig, configPath)
                        return
                    end
                    if manualReorderPick.orderIndex == oi then
                        manualReorderPick = nil
                        bumpGroupDataVersion(groupConfig, configPath)
                        return
                    end
                    local order = groupConfig.entryOrder
                    local a, b = manualReorderPick.orderIndex, oi
                    if order and order[a] and order[b] then
                        order[a], order[b] = order[b], order[a]
                    end
                    manualReorderPick = nil
                    VFlow.Store.set(MODULE_KEY, configPath .. ".entryOrder", groupConfig.entryOrder)
                    bumpGroupDataVersion(groupConfig, configPath)
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

    local configPath = options.isCustom and ("customGroups." .. options.groupIndex .. ".config") or "mainGroup"
    if manualReorderPick and manualReorderPick.path ~= configPath then
        manualReorderPick = nil
    end

    -- 初始化临时字段
    if not groupConfig._inputItemID then groupConfig._inputItemID = "" end
    if not groupConfig._inputSpellID then groupConfig._inputSpellID = "" end

    local layout = mergeLayouts(
        -- 标题
        {
            { type = "title", text = groupName, cols = 24 },
            { type = "separator", cols = 24 },
        },

        -- 基础设置
        {
            { type = "subtitle", text = "基础设置", cols = 24 },
            { type = "separator", cols = 24 },
            { type = "checkbox", key = "enabled", label = "启用", cols = 12 },
            {
                type = "dropdown",
                key = "itemZeroCountBehavior",
                label = "物品不可用（数量0或未装备）时",
                cols = 12,
                items = ITEM_ZERO_COUNT_OPTIONS,
            }
        },

        -- 物品/技能选择器（主组和自定义组都有）
        buildItemSpellSelector(groupConfig, options),

        -- 显示模式
        {
            { type = "spacer", height = 10, cols = 24 },
            { type = "subtitle", text = "显示模式", cols = 24 },
            { type = "separator", cols = 24 },
            {
                type = "dropdown",
                key = "displayMode",
                label = "显示模式",
                cols = 12,
                items = DISPLAY_MODE_OPTIONS
            },
        },

        -- 追加到重要/效能时的行与位置
        {
            {
                type = "if",
                dependsOn = "displayMode",
                condition = function(cfg)
                    return cfg.displayMode == "append_important" or cfg.displayMode == "append_efficiency"
                end,
                children = {
                    { type = "spacer", height = 8, cols = 24 },
                    {
                        type = "dropdown",
                        key = "appendTargetRow",
                        label = "追加到第几行",
                        cols = 12,
                        items = APPEND_ROW_OPTIONS,
                    },
                    {
                        type = "dropdown",
                        key = "appendSide",
                        label = "追加位置",
                        cols = 12,
                        items = APPEND_SIDE_OPTIONS,
                    },
                    {
                        type = "description",
                        text = "追加到技能条时，图标尺寸/层数/冷却读秒/遮罩等样式与对应技能组（重要技能或效能技能）一致，请在「技能监控」中调整。",
                        cols = 24,
                    },
                }
            },
        },

        -- 依附框体设置（仅在单独分组模式下显示）
        {
            {
                type = "if",
                dependsOn = "displayMode",
                condition = function(cfg) return cfg.displayMode == "standalone" end,
                children = {
                    { type = "spacer", height = 10, cols = 24 },
                    { type = "subtitle", text = "依附框体", cols = 24 },
                    { type = "separator", cols = 24 },
                    {
                        type = "dropdown",
                        key = "anchorFrame",
                        label = "依附框体",
                        cols = 12,
                        items = ANCHOR_FRAME_OPTIONS
                    },
                }
            },
        },

        -- 玩家框体位置选项（仅在单独分组且依附玩家框体时显示）
        {
            {
                type = "if",
                dependsOn = { "displayMode", "anchorFrame" },
                condition = function(cfg) return cfg.displayMode == "standalone" and cfg.anchorFrame == "player" end,
                children = {
                    {
                        type = "dropdown",
                        key = "playerAnchorPosition",
                        label = "位置",
                        cols = 12,
                        items = PLAYER_ANCHOR_POSITION_OPTIONS
                    },
                    { type = "slider", key = "x", label = "X偏移",
                      min = UI_LIMITS.POSITION.min, max = UI_LIMITS.POSITION.max, step = 1, cols = 12 },
                    { type = "slider", key = "y", label = "Y偏移",
                      min = UI_LIMITS.POSITION.min, max = UI_LIMITS.POSITION.max, step = 1, cols = 12 },
                }
            },
        },

        -- UI父框体坐标选项（仅在单独分组且依附UI父框体时显示）
        {
            {
                type = "if",
                dependsOn = { "displayMode", "anchorFrame" },
                condition = function(cfg) return cfg.displayMode == "standalone" and cfg.anchorFrame == "uiparent" end,
                children = {
                    { type = "slider", key = "x", label = "X坐标",
                      min = UI_LIMITS.POSITION.min, max = UI_LIMITS.POSITION.max, step = 1, cols = 12 },
                    { type = "slider", key = "y", label = "Y坐标",
                      min = UI_LIMITS.POSITION.min, max = UI_LIMITS.POSITION.max, step = 1, cols = 12 },
                }
            },
        },

        -- 样式设置（仅单独分组；追加模式跟随技能监控里对应技能组）
        {
            {
                type = "if",
                dependsOn = "displayMode",
                condition = function(cfg)
                    return cfg.displayMode == "standalone"
                end,
                children = {
                    { type = "spacer", height = 10, cols = 24 },
                    { type = "subtitle", text = "样式设置", cols = 24 },
                    { type = "separator", cols = 24 },
                    { type = "slider", key = "width", label = "图标宽度",
                      min = UI_LIMITS.SIZE.min, max = UI_LIMITS.SIZE.max, step = 1, cols = 12 },
                    { type = "slider", key = "height", label = "图标高度",
                      min = UI_LIMITS.SIZE.min, max = UI_LIMITS.SIZE.max, step = 1, cols = 12 },
                    { type = "slider", key = "maxIconsPerRow", label = "每行最大图标数",
                      min = UI_LIMITS.MAX_ICONS_PER_ROW.min, max = UI_LIMITS.MAX_ICONS_PER_ROW.max, step = 1, cols = 12 },
                    { type = "slider", key = "spacingX", label = "列间距",
                      min = UI_LIMITS.SPACING.min, max = UI_LIMITS.SPACING.max, step = 1, cols = 12 },
                    { type = "slider", key = "spacingY", label = "行间距",
                      min = UI_LIMITS.SPACING.min, max = UI_LIMITS.SPACING.max, step = 1, cols = 12 },
                }
            },
        },

        -- 字体设置（仅单独分组）
        {
            {
                type = "if",
                dependsOn = "displayMode",
                condition = function(cfg)
                    return cfg.displayMode == "standalone"
                end,
                children = mergeLayouts(
                    {
                        { type = "spacer", height = 10, cols = 24 },
                        { type = "description", text = "层数文字用于物品堆叠数量（大于 1 时显示）", cols = 24 },
                        { type = "checkbox", key = "showItemCount", label = "显示物品堆叠数量", cols = 12 },
                        { type = "spacer", height = 6, cols = 24 },
                    },
                    Grid.fontGroup("stackFont", "层数文字字体"),
                    {
                        { type = "spacer", height = 10, cols = 24 },
                    },
                    Grid.fontGroup("cooldownFont", "冷却读秒字体")
                )
            },
        },

        -- 遮罩层配置（仅单独分组）
        {
            {
                type = "if",
                dependsOn = "displayMode",
                condition = function(cfg)
                    return cfg.displayMode == "standalone"
                end,
                children = {
                    { type = "spacer", height = 10, cols = 24 },
                    { type = "subtitle", text = "遮罩层配置", cols = 24 },
                    { type = "separator", cols = 24 },
                    { type = "colorPicker", key = "cooldownMaskColor", label = "冷却遮罩层颜色", hasAlpha = true, cols = 12 },
                }
            },
        }
    )

    Grid.render(container, layout, groupConfig, MODULE_KEY, configPath)
end

local function renderContent(container, menuKey)
    -- reset 后同会话内需再跑一遍；已 seeded 则立即返回
    applyMainGroupStarterItemsOnce(db)
    if menuKey == "item_monitor" then
        renderGroupConfig(container, db.mainGroup, db.mainGroup.groupName or "主组", {
            isCustom = false
        })
    elseif menuKey:find("^item_custom_") then
        local customIndex = tonumber(menuKey:match("item_custom_(%d+)"))
        if customIndex and db.customGroups[customIndex] then
            local customGroup = db.customGroups[customIndex]
            renderGroupConfig(container, customGroup.config, customGroup.name, {
                isCustom = true,
                groupIndex = customIndex,
            })
        else
            local title = VFlow.UI.title(container, "自定义物品组未找到")
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

VFlow.Modules.Items = {
    renderContent = renderContent,

    addCustomGroup = function(groupName)
        table.insert(db.customGroups, {
            name = groupName,
            config = getDefaultGroupConfig("uiparent", true)
        })
        VFlow.Store.set(MODULE_KEY, "customGroups", db.customGroups)
        return #db.customGroups
    end,

    getCustomGroups = function()
        return db.customGroups
    end,
}
