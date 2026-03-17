-- =========================================================
-- VFlow Grid - 24列Grid布局引擎
-- 职责：声明式布局渲染、自动换行、条件渲染
-- =========================================================

local VFlow = _G.VFlow
if not VFlow then
    error("VFlow.Grid: Core模块未加载")
end

local Grid = {}
VFlow.Grid = Grid

local UI = VFlow.UI
local Store = VFlow.Store

-- 布局常量
local TOTAL_COLS = 24
local DEFAULT_GAP = 5
local DEFAULT_PADDING = 10

-- 容器缓存 { [container] = { widgets = {}, layout = {} } }
local containerCache = setmetatable({}, { __mode = "k" })
local conditionalListenerRegistered = setmetatable({}, { __mode = "k" })

local function resolveHostContainer(frame)
    if frame and frame._gridHost and frame._gridHost ~= frame then
        return frame._gridHost
    end
    return frame
end

-- =========================================================
-- 预设布局片段
-- =========================================================

-- 位置选项（复用）
local POSITION_ITEMS = {
    { "左上", "TOPLEFT" }, { "上", "TOP" }, { "右上", "TOPRIGHT" },
    { "左", "LEFT" }, { "中", "CENTER" }, { "右", "RIGHT" },
    { "左下", "BOTTOMLEFT" }, { "下", "BOTTOM" }, { "右下", "BOTTOMRIGHT" },
}
local OUTLINE_ITEMS = {
    { "描边", "OUTLINE" },
    { "粗描边", "THICKOUTLINE" },
    { "阴影", "SHADOW" },
    { "无", "NONE" },
}

--- 展开字体设置组为布局项列表
-- @param prefix string 配置前缀，如 "stackFont"
-- @param label string 显示标题，如 "堆叠文字"
-- @return table 布局项列表
function Grid.fontGroup(prefix, label)
    return {
        { type = "subtitle", text = label, cols = 24 },
        { type = "separator", cols = 24 },
        { type = "slider", key = prefix .. ".size", label = "字号", min = 8, max = 32, step = 1, cols = 8 },
        { type = "slider", key = prefix .. ".offsetX", label = "X偏移", min = -50, max = 50, step = 1, cols = 8 },
        { type = "slider", key = prefix .. ".offsetY", label = "Y偏移", min = -50, max = 50, step = 1, cols = 8 },
        { type = "fontPicker", key = prefix .. ".font", label = "字体", cols = 8 },
        { type = "colorPicker", key = prefix .. ".color", label = "颜色", hasAlpha = true, cols = 8 },
        { type = "dropdown", key = prefix .. ".position", label = "位置", cols = 8, items = POSITION_ITEMS },
        { type = "dropdown", key = prefix .. ".outline", label = "描边", cols = 8, items = OUTLINE_ITEMS },
    }
end

-- =========================================================
-- 组件创建
-- =========================================================

-- 辅助函数：获取嵌套属性值
local function getNestedValue(config, key)
    if not key then return nil end

    -- 如果key包含点号，说明是嵌套属性
    if key:find("%.") then
        local keys = {}
        for k in key:gmatch("[^%.]+") do
            table.insert(keys, k)
        end

        local value = config
        for _, k in ipairs(keys) do
            if type(value) ~= "table" then return nil end
            value = value[k]
        end
        return value
    else
        return config[key]
    end
end

-- 辅助函数：设置嵌套属性值
local function setNestedValue(config, key, value)
    if not key then return end

    -- 如果key包含点号，说明是嵌套属性
    if key:find("%.") then
        local keys = {}
        for k in key:gmatch("[^%.]+") do
            table.insert(keys, k)
        end

        local current = config
        for i = 1, #keys - 1 do
            local k = keys[i]
            if type(current[k]) ~= "table" then
                current[k] = {}
            end
            current = current[k]
        end
        current[keys[#keys]] = value
    else
        config[key] = value
    end
end

local function iterateDependsOn(dependsOn, callback)
    if type(dependsOn) == "string" then
        callback(dependsOn)
        return true
    end
    if type(dependsOn) == "table" then
        local hasDependsOn = false
        for _, key in ipairs(dependsOn) do
            if type(key) == "string" then
                hasDependsOn = true
                callback(key)
            end
        end
        return hasDependsOn
    end
    return false
end

local function collectConditionalMeta(items, meta)
    for _, item in ipairs(items) do
        if item.type == "if" then
            meta.hasConditionalRender = true
            local hasDependsOn = iterateDependsOn(item.dependsOn, function(key)
                meta.conditionalWatchKeys[key] = true
            end)
            if not hasDependsOn then
                meta.hasUnknownConditional = true
            end
            if item.children then
                collectConditionalMeta(item.children, meta)
            end
        elseif item.type == "for" then
            -- type="for"也支持dependsOn
            meta.hasConditionalRender = true
            local hasDependsOn = iterateDependsOn(item.dependsOn, function(key)
                meta.conditionalWatchKeys[key] = true
            end)
            if not hasDependsOn then
                meta.hasUnknownConditional = true
            end
        elseif item.children then
            collectConditionalMeta(item.children, meta)
        end
    end
end

local function shouldRenderIf(item, config)
    if type(item.condition) == "function" then
        local ok, visible = pcall(item.condition, config)
        if ok then
            return not not visible
        end
        return true
    end

    local visible = true
    local hasDependsOn = iterateDependsOn(item.dependsOn, function(key)
        if visible and not getNestedValue(config, key) then
            visible = false
        end
    end)
    if hasDependsOn then
        return visible
    end
    return true
end

local function matchWatchKey(changedKey, watchKey, configPath)
    -- 如果有configPath，需要考虑前缀匹配
    -- 例如：changedKey = "customGroups.0.config.dynamicLayout"
    --      watchKey = "dynamicLayout"
    --      configPath = "customGroups.0.config"
    -- 应该匹配成功

    if configPath and configPath ~= "" then
        -- 尝试移除configPath前缀
        local prefix = configPath .. "."
        if changedKey:sub(1, #prefix) == prefix then
            local localKey = changedKey:sub(#prefix + 1)
            -- 使用本地key进行匹配
            if localKey == watchKey then
                return true
            end
            if localKey:sub(1, #watchKey + 1) == watchKey .. "." then
                return true
            end
            if watchKey:sub(1, #localKey + 1) == localKey .. "." then
                return true
            end
        end
    end

    -- 原有的匹配逻辑（无configPath或全局匹配）
    if changedKey == watchKey then
        return true
    end
    if changedKey and watchKey and changedKey:sub(1, #watchKey + 1) == watchKey .. "." then
        return true
    end
    if changedKey and watchKey and watchKey:sub(1, #changedKey + 1) == changedKey .. "." then
        return true
    end
    return false
end

local function shouldRefreshForChange(cache, changedKey)
    if not cache or not cache.hasConditionalRender then
        return false
    end
    if cache.hasUnknownConditional then
        return true
    end
    if not changedKey then
        return false
    end
    local configPath = cache.configPath or ""
    for watchKey, _ in pairs(cache.conditionalWatchKeys or {}) do
        if matchWatchKey(changedKey, watchKey, configPath) then
            return true
        end
    end
    return false
end

--- 根据布局项创建组件
-- @param parent Frame 父帧
-- @param item table 布局项
-- @param config table 配置DB
-- @param moduleKey string 模块标识
-- @param configPath string 配置路径（可选）
-- @return Frame|FontString 创建的组件
local function createWidget(parent, item, config, moduleKey, configPath)
    local widget
    local function onValueChanged(key, val)
        -- 特殊键：强制刷新UI
        if key == "_refresh" then
            Grid.refresh(parent)
            return
        end

        setNestedValue(config, key, val)
        if moduleKey then
            -- 如果有configPath，拼接完整路径
            local fullKey = key
            if configPath and configPath ~= "" then
                fullKey = configPath .. "." .. key
            end
            VFlow.Store.set(moduleKey, fullKey, val)

            -- 检查是否需要增量刷新（条件渲染/循环渲染）
            local cache = containerCache[parent]
            if shouldRefreshForChange(cache, key) then
                Grid.refresh(parent)
            end
        end
        if not moduleKey then
            local cache = containerCache[parent]
            if shouldRefreshForChange(cache, key) then
                Grid.refresh(parent)
            end
        end
    end

    if item.type == "title" then
        widget = UI.title(parent, item.text)
    elseif item.type == "subtitle" then
        widget = UI.subtitle(parent, item.text)
    elseif item.type == "description" then
        widget = UI.description(parent, item.text)
    elseif item.type == "button" then
        widget = UI.button(parent, item.text, function()
            if item.onClick then
                item.onClick(config)
            end
        end)
    elseif item.type == "checkbox" then
        local value = getNestedValue(config, item.key)
        widget = UI.checkbox(parent, item.label, value, function(checked)
            onValueChanged(item.key, checked)
        end)
    elseif item.type == "slider" then
        local value = getNestedValue(config, item.key) or item.min
        widget = UI.slider(parent, item.label, item.min, item.max, value, item.step or 1, function(val)
            onValueChanged(item.key, val)
        end)
    elseif item.type == "input" then
        local value = getNestedValue(config, item.key) or ""
        widget = UI.input(parent, item.label, value, function(text)
            onValueChanged(item.key, text)
        end, item)

        if widget.editBox then
            widget.editBox:SetNumeric(item.numeric == true)
        end
    elseif item.type == "dropdown" then
        local value = getNestedValue(config, item.key)
        local items = item.items
        if type(items) == "function" then
            items = items(config)
        end
        widget = UI.dropdown(parent, item.label, items, value, function(val)
            onValueChanged(item.key, val)
            if item.onChange then
                item.onChange(config, val, item)
            end
        end, item)
    elseif item.type == "separator" then
        widget = UI.separator(parent)
    elseif item.type == "spacer" then
        widget = UI.spacer(parent, item.height or 10)
    elseif item.type == "cooldownBar" then
        widget = UI.cooldownBar(parent, item.spellID, config)
    elseif item.type == "iconGroup" then
        widget = UI.iconGroup(parent, item.spellIDs, config)
    elseif item.type == "colorPicker" then
        local value = getNestedValue(config, item.key)
        widget = UI.colorPicker(parent, item.label, value, item.hasAlpha, function(r, g, b, a)
            onValueChanged(item.key, { r = r, g = g, b = b, a = a })
        end)
    elseif item.type == "texturePicker" then
        local value = getNestedValue(config, item.key)
        widget = UI.texturePicker(parent, item.label, value, function(path)
            onValueChanged(item.key, path)
        end)
    elseif item.type == "fontPicker" then
        local value = getNestedValue(config, item.key)
        widget = UI.fontPicker(parent, item.label, value, function(path)
            onValueChanged(item.key, path)
        end)
    elseif item.type == "iconButton" then
        widget = UI.iconButton(parent, item.icon, item.size or 40, function()
            if item.onClick then
                item.onClick(item)
            end
        end, item.tooltip, item.borderColor)
    elseif item.type == "interactiveText" then
        -- 可交互文本组件: { text = "文本{链接}", links = { ["链接"] = fn } }
        widget = UI.interactiveText(parent, { text = item.text, links = item.links })
    elseif item.type == "customRender" then
        -- 自定义渲染组件
        if item.render then
            widget = CreateFrame("Frame", nil, parent)
            widget:SetSize(parent:GetWidth() - 20, item.height or 100)
            item.render(widget, config, onValueChanged, item)
        else
            error("Grid.createWidget: customRender需要提供render函数", 2)
        end
    else
        error("Grid.createWidget: 未知组件类型 " .. tostring(item.type), 2)
    end

    -- 存储元数据
    widget._gridItem = item
    widget._gridKey = item.key

    return widget
end

-- =========================================================
-- 布局渲染
-- =========================================================

--- 将Frame转换为ScrollFrame
-- @param parent Frame 父容器
function Grid.makeScrollable(parent)
    if parent.scrollChild then return end -- 已经是ScrollFrame

    local scrollFrame = CreateFrame("ScrollFrame", nil, parent, "UIPanelScrollFrameTemplate")
    scrollFrame:SetAllPoints(parent)

    local scrollChild = CreateFrame("Frame", nil, scrollFrame)
    scrollChild:SetSize(parent:GetWidth(), 1)
    scrollFrame:SetScrollChild(scrollChild)
    scrollFrame._gridHost = parent
    scrollChild._gridHost = parent

    parent.scrollFrame = scrollFrame
    parent.scrollChild = scrollChild
    parent.scrollBar = UI.styleScrollFrame(scrollFrame, {
        anchorParent = parent,
        offsetX = 8,
        topOffset = -4,
        bottomOffset = 4,
        width = 6,
    })
    UI.updateScrollFrameState(scrollFrame, 0, parent:GetHeight())

    local function updateScrollState()
        local contentHeight = scrollChild:GetHeight()
        local viewHeight = parent:GetHeight()
        UI.updateScrollFrameState(scrollFrame, contentHeight, viewHeight)
    end
    parent.UpdateScrollState = updateScrollState

    UI.bindScrollWheel(parent, scrollFrame, 40)

    parent:SetScript("OnSizeChanged", function()
        scrollChild:SetWidth(parent:GetWidth())
        updateScrollState()
        if containerCache[scrollChild] then
            Grid.refresh(parent)
        end
    end)
end

--- 渲染布局
-- @param parent Frame 父容器
-- @param layout table 布局定义
-- @param config table 配置DB
-- @param moduleKey string 模块标识
-- @param configPath string 配置路径（可选，如"customGroups.0.config"）
function Grid.render(parent, layout, config, moduleKey, configPath)
    parent = resolveHostContainer(parent)
    if not parent then
        error("Grid.render: parent不能为nil", 2)
    end
    if type(layout) ~= "table" then
        error("Grid.render: layout必须是表", 2)
    end
    if type(config) ~= "table" then
        error("Grid.render: config必须是表", 2)
    end

    -- 自动应用ScrollFrame
    if not parent.scrollChild then
        Grid.makeScrollable(parent)
    end

    -- 如果是ScrollFrame，则在子容器上渲染
    local renderTarget = parent
    if parent.scrollChild then
        renderTarget = parent.scrollChild
    end

    -- 清空旧布局
    Grid.clear(parent)

    -- 展平布局（将嵌套的数组展开为平级列表）
    local function flattenLayout(items)
        local result = {}
        for _, item in ipairs(items) do
            if item[1] then
                -- 这是一个数组（如fontGroup返回的列表），展开它
                for _, subItem in ipairs(item) do
                    table.insert(result, subItem)
                end
            else
                -- 普通布局项，如果有children也需要展平
                if item.children then
                    local flatChildren = flattenLayout(item.children)
                    local copy = {}
                    for k, v in pairs(item) do
                        copy[k] = v
                    end
                    copy.children = flatChildren
                    table.insert(result, copy)
                else
                    table.insert(result, item)
                end
            end
        end
        return result
    end
    layout = flattenLayout(layout)

    local conditionalMeta = {
        hasConditionalRender = false,
        hasUnknownConditional = false,
        conditionalWatchKeys = {},
    }
    collectConditionalMeta(layout, conditionalMeta)

    -- 初始化缓存
    containerCache[renderTarget] = {
        widgets = {},
        layout = layout,
        config = config,
        moduleKey = moduleKey,
        configPath = configPath,
        hasConditionalRender = conditionalMeta.hasConditionalRender,
        hasUnknownConditional = conditionalMeta.hasUnknownConditional,
        conditionalWatchKeys = conditionalMeta.conditionalWatchKeys,
        isRendering = false, -- 防止递归渲染
    }

    if conditionalMeta.hasConditionalRender and moduleKey and Store then
        if not conditionalListenerRegistered[renderTarget] then
            conditionalListenerRegistered[renderTarget] = {}
        end
        if not conditionalListenerRegistered[renderTarget][moduleKey] then
            conditionalListenerRegistered[renderTarget][moduleKey] = true
            Store.watch(moduleKey, "Grid_" .. tostring(renderTarget), function(key, value)
                local cache = containerCache[renderTarget]
                if not cache or cache.moduleKey ~= moduleKey then
                    return
                end
                if shouldRefreshForChange(cache, key) then
                    Grid.refresh(parent)
                end
            end)
        end
    end

    -- 计算布局参数
    local containerWidth = parent:GetWidth()
    local colWidth = (containerWidth - DEFAULT_PADDING * 2) / TOTAL_COLS

    local x = DEFAULT_PADDING
    local y = DEFAULT_PADDING
    local currentRowHeight = 0

    -- 递归渲染函数
    local function renderItems(items)
        for _, item in ipairs(items) do
            if item.type == "if" then
                if shouldRenderIf(item, config) then
                    renderItems(item.children or {})
                end
            elseif item.type == "for" then
                -- 循环渲染：根据dataSource生成多个组件
                local dataSource = item.dataSource
                if type(dataSource) == "function" then
                    dataSource = dataSource(config)
                end

                if type(dataSource) == "table" then
                    for index, dataItem in ipairs(dataSource) do
                        -- 为每个数据项创建布局项的副本
                        local itemCopy = {}
                        for k, v in pairs(item.template) do
                            itemCopy[k] = v
                        end

                        -- 注入数据上下文
                        itemCopy._forIndex = index
                        itemCopy._forData = dataItem

                        -- 如果template有动态属性函数，调用它们
                        if type(itemCopy.icon) == "function" then
                            itemCopy.icon = itemCopy.icon(dataItem, index)
                        end
                        if type(itemCopy.size) == "function" then
                            itemCopy.size = itemCopy.size(dataItem, index)
                        end
                        if type(itemCopy.tooltip) == "function" then
                            itemCopy.tooltip = itemCopy.tooltip(dataItem, index)
                        end
                        if type(itemCopy.borderColor) == "function" then
                            itemCopy.borderColor = itemCopy.borderColor(dataItem, index)
                        end
                        if type(itemCopy.onClick) == "function" then
                            local originalOnClick = itemCopy.onClick
                            itemCopy.onClick = function()
                                originalOnClick(dataItem, index)
                            end
                        end

                        -- 计算组件宽度
                        local cols = itemCopy.cols or item.cols or 24
                        if cols > TOTAL_COLS then cols = TOTAL_COLS end
                        if cols < 1 then cols = 1 end

                        local itemWidth = colWidth * cols - DEFAULT_GAP

                        -- 换行检测
                        if x + itemWidth > containerWidth - DEFAULT_PADDING and x > DEFAULT_PADDING then
                            x = DEFAULT_PADDING
                            y = y + currentRowHeight + DEFAULT_GAP
                            currentRowHeight = 0
                        end

                        -- 创建组件
                        local widget = createWidget(renderTarget, itemCopy, config, moduleKey, configPath)

                        -- 显示组件
                        widget:Show()

                        -- 设置位置和尺寸
                        widget:ClearAllPoints()

                        if itemCopy.type == "iconButton" then
                            local size = itemCopy.size or 40
                            local offsetX = (itemWidth - size) / 2
                            if offsetX < 0 then offsetX = 0 end
                            widget:SetPoint("TOPLEFT", renderTarget, "TOPLEFT", x + offsetX, -y)
                        else
                            widget:SetPoint("TOPLEFT", renderTarget, "TOPLEFT", x, -y)
                            if widget.SetWidth then
                                widget:SetWidth(itemWidth)
                            end
                        end

                        -- 获取组件高度
                        local widgetHeight = widget:GetHeight() or 24

                        -- 更新位置
                        x = x + itemWidth + DEFAULT_GAP
                        currentRowHeight = math.max(currentRowHeight, widgetHeight)

                        -- 缓存组件
                        table.insert(containerCache[renderTarget].widgets, widget)
                    end
                end
            else
                -- 计算组件宽度
                local cols = item.cols or 24
                if cols > TOTAL_COLS then cols = TOTAL_COLS end
                if cols < 1 then cols = 1 end

                local itemWidth = colWidth * cols - DEFAULT_GAP

                -- 换行检测
                if x + itemWidth > containerWidth - DEFAULT_PADDING and x > DEFAULT_PADDING then
                    x = DEFAULT_PADDING
                    y = y + currentRowHeight + DEFAULT_GAP
                    currentRowHeight = 0
                end

                -- 创建组件
                local widget = createWidget(renderTarget, item, config, moduleKey, configPath)

                -- 显示组件（池化组件需要手动显示）
                widget:Show()

                -- 设置位置和尺寸
                widget:ClearAllPoints()

                if item.type == "iconButton" then
                    -- 图标按钮特殊处理：保持原始尺寸并居中
                    local size = item.size or 40
                    local offsetX = (itemWidth - size) / 2
                    if offsetX < 0 then offsetX = 0 end
                    widget:SetPoint("TOPLEFT", renderTarget, "TOPLEFT", x + offsetX, -y)
                    -- 不强制设置宽度
                else
                    widget:SetPoint("TOPLEFT", renderTarget, "TOPLEFT", x, -y)
                    -- 设置宽度（某些组件需要）
                    if widget.SetWidth then
                        widget:SetWidth(itemWidth)
                    end
                    if widget.RefreshVisuals then
                        widget:RefreshVisuals()
                    end
                end

                -- 获取组件高度
                local widgetHeight = widget:GetHeight() or 24

                -- 更新位置
                x = x + itemWidth + DEFAULT_GAP
                currentRowHeight = math.max(currentRowHeight, widgetHeight)

                -- 缓存组件
                table.insert(containerCache[renderTarget].widgets, widget)
            end
        end
    end

    -- 开始渲染
    renderItems(layout)

    -- 设置容器高度
    local totalHeight = y + currentRowHeight + DEFAULT_PADDING

    -- 调整子容器高度
    if parent.scrollChild then
        parent.scrollChild:SetHeight(totalHeight)
        -- 子容器宽度跟随ScrollFrame宽度
        parent.scrollChild:SetWidth(parent:GetWidth())
    else
        parent:SetHeight(totalHeight)
    end

    if parent.UpdateScrollState then
        parent:UpdateScrollState()
    end
end

--- 清空布局
-- @param parent Frame 父容器
function Grid.clear(parent)
    parent = resolveHostContainer(parent)
    if not parent then
        error("Grid.clear: parent不能为nil", 2)
    end

    -- 如果是ScrollFrame，则清理其子容器
    local target = parent.scrollChild or parent

    local cache = containerCache[target]
    if not cache then return end

    local UI = VFlow.UI

    -- 释放所有组件回池
    for _, widget in ipairs(cache.widgets) do
        UI.release(widget)
    end

    -- 清空缓存
    containerCache[target] = nil
end

--- 刷新布局
-- @param parent Frame 父容器
function Grid.refresh(parent)
    parent = resolveHostContainer(parent)
    if not parent then
        error("Grid.refresh: parent不能为nil", 2)
    end

    -- 如果是ScrollFrame，则刷新其子容器
    local target = parent.scrollChild or parent

    local cache = containerCache[target]
    if not cache then
        error("Grid.refresh: 容器未渲染过布局", 2)
    end

    -- 防止递归渲染
    if cache.isRendering then
        return
    end

    cache.isRendering = true

    -- 保存旧的缓存数据
    local layout = cache.layout
    local config = cache.config
    local moduleKey = cache.moduleKey
    local configPath = cache.configPath

    -- 重新渲染
    -- 注意：这里传入的是parent（ScrollFrame），render会自动处理scrollChild
    Grid.render(parent, layout, config, moduleKey, configPath)

    -- 重置渲染标志
    if containerCache[target] then
        containerCache[target].isRendering = false
    end
end

-- =========================================================
-- 调试工具
-- =========================================================

--- 打印布局信息
-- @param parent Frame 父容器
function Grid.debugLayout(parent)
    if not parent then
        error("Grid.debugLayout: parent不能为nil", 2)
    end

    local cache = containerCache[parent]
    if not cache then
        print("|cffff0000VFlow错误:|r 容器未渲染过布局")
        return
    end

    print("|cff00ff00VFlow调试:|r 布局信息:")
    print("  ", "组件数量:", #cache.widgets)
    print("  ", "容器高度:", parent:GetHeight())

    for i, widget in ipairs(cache.widgets) do
        local item = widget._gridItem
        if item then
            print("  ", i, item.type, "cols=" .. (item.cols or 24), "key=" .. tostring(item.key))
        end
    end
end
