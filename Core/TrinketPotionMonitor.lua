-- =========================================================
-- 饰品与药水BUFF监控
-- =========================================================

local VFlow = _G.VFlow
if not VFlow then return end

local MODULE_KEY = "VFlow.Buffs"

-- =========================================================
-- 模块状态
-- =========================================================

local _container = nil        -- 容器帧
local _iconPool = {}          -- 图标池 {[spellID] = {frame, icon, cooldown, itemID, duration, isAuto}}
local _autoDetectedItems = {} -- 自动检测的饰品 {itemID = {spellID, icon, duration}}
local _scanTooltip = nil      -- 扫描tooltip
local _scanRetryCount = 0     -- 扫描重试计数
local _scanTimer = nil        -- 扫描定时器

-- =========================================================
-- 持续时间解析（参考CDFlow的ParseDuration）
-- =========================================================

local function ParseDuration(text)
    if not text then return nil end

    -- 支持多语言格式
    -- 中文: "持续 30 秒" / "持续30秒"
    -- 英文: "for 30 sec" / "30 seconds"
    local patterns = {
        "(%d+)%s*秒", -- 中文
        "(%d+)%s*sec", -- 英文缩写
        "(%d+)%s*second", -- 英文完整
        "持续%s*(%d+)", -- 中文"持续"
        "for%s*(%d+)", -- 英文"for"
    }

    for _, pattern in ipairs(patterns) do
        local duration = text:match(pattern)
        if duration then
            return tonumber(duration)
        end
    end

    return nil
end

-- =========================================================
-- 物品法术信息提取（三层策略）
-- =========================================================

local function GetItemSpellInfo(itemID)
    if not itemID then return nil, nil end

    -- 策略1: 使用C_Spell.GetSpellDescription（最快）
    local spellID = select(2, C_Item.GetItemSpell(itemID))
    if spellID then
        local spellInfo = C_Spell.GetSpellInfo(spellID)
        if spellInfo then
            local description = C_Spell.GetSpellDescription(spellID)
            if description then
                local duration = ParseDuration(description)
                if duration then
                    return spellID, duration
                end
            end
        end
    end

    -- 策略2: 使用C_TooltipInfo.GetSpellByID（较准确）
    if spellID then
        local tooltipInfo = C_TooltipInfo.GetSpellByID(spellID)
        if tooltipInfo and tooltipInfo.lines then
            for _, line in ipairs(tooltipInfo.lines) do
                if line.leftText then
                    local duration = ParseDuration(line.leftText)
                    if duration then
                        return spellID, duration
                    end
                end
            end
        end
    end

    -- 策略3: Tooltip扫描（兼容性最好）
    if not _scanTooltip then
        _scanTooltip = CreateFrame("GameTooltip", "VFlowTrinketPotionScanTooltip", UIParent, "GameTooltipTemplate")
        _scanTooltip:SetOwner(UIParent, "ANCHOR_NONE")
    end

    _scanTooltip:ClearLines()
    _scanTooltip:SetItemByID(itemID)

    for i = 1, _scanTooltip:NumLines() do
        local line = _G["VFlowTrinketPotionScanTooltipTextLeft" .. i]
        if line then
            local text = line:GetText()
            if text then
                local duration = ParseDuration(text)
                if duration then
                    return spellID, duration
                end
            end
        end
    end

    return spellID, nil
end

-- =========================================================
-- 容器管理
-- =========================================================

local function InitContainer()
    if _container then return end

    local db = VFlow.getDB(MODULE_KEY)
    local config = db.trinketPotion

    -- 创建容器
    _container = CreateFrame("Frame", "VFlowTrinketPotionContainer", UIParent)
    _container:SetSize(100, 100)
    _container:SetPoint("CENTER", config.x or 0, config.y or -200)
    _container:SetMovable(true)
    _container:SetClampedToScreen(true)

    -- 注册拖拽
    if VFlow.DragFrame then
        VFlow.DragFrame.register(_container, {
            label = "饰品&药水",
            onPositionChanged = function(frame, point, x, y)
                VFlow.Store.set(MODULE_KEY, "trinketPotion.x", x)
                VFlow.Store.set(MODULE_KEY, "trinketPotion.y", y)
            end
        })
    end
end

local function UpdateContainerPosition()
    if not _container then return end

    local db = VFlow.getDB(MODULE_KEY)
    local config = db.trinketPotion

    _container:ClearAllPoints()
    _container:SetPoint("CENTER", UIParent, "CENTER", config.x or 0, config.y or -200)
end

-- =========================================================
-- 图标管理
-- =========================================================

local function CreateIconFrame()
    local frame = CreateFrame("Frame", nil, _container)
    frame:SetSize(40, 40)

    -- 图标
    local icon = frame:CreateTexture(nil, "ARTWORK")
    icon:SetAllPoints()
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    -- 冷却动画
    local cooldown = CreateFrame("Cooldown", nil, frame, "CooldownFrameTemplate")
    cooldown:SetAllPoints()
    cooldown:SetDrawEdge(false)
    cooldown:SetDrawSwipe(true)

    frame.Icon = icon         -- 使用大写 Icon，与 BuffGroups 保持一致
    frame.icon = icon         -- 保留小写兼容
    frame.Cooldown = cooldown -- 使用大写 Cooldown
    frame.cooldown = cooldown -- 保留小写兼容
    frame:Hide()

    return frame
end

local function ActivateIcon(spellID, itemID)
    local poolData = _iconPool[spellID]
    if not poolData then return end

    local frame = poolData.frame
    local duration = poolData.duration

    if not frame or not duration then return end

    -- 获取物品图标
    local _, _, _, _, _, _, _, _, _, itemIcon = C_Item.GetItemInfo(itemID)
    if itemIcon then
        frame.icon:SetTexture(itemIcon)
    end

    -- 启动冷却
    frame.cooldown:SetCooldown(GetTime(), duration)
    frame:Show()

    -- 取消之前的定时器（如果有）
    if frame.hideTimer then
        frame.hideTimer:Cancel()
        frame.hideTimer = nil
    end

    -- 设置定时器，在持续时间结束后隐藏图标
    frame.hideTimer = C_Timer.NewTimer(duration, function()
        frame:Hide()
        frame.hideTimer = nil
        -- 刷新布局
        RefreshLayout()
    end)

    -- 刷新布局
    C_Timer.After(0.1, function()
        RefreshLayout()
    end)
end

-- =========================================================
-- 物品扫描
-- =========================================================

local function ScanItems()
    local db = VFlow.getDB(MODULE_KEY)
    local config = db.trinketPotion

    -- 保存旧池，用于帧复用
    local oldPool = _iconPool
    _iconPool = {}
    _autoDetectedItems = {}

    local unloadedCount = 0

    -- 扫描自动检测的饰品（槽位13/14）
    if config.autoTrinkets then
        for slotID = 13, 14 do
            local itemID = GetInventoryItemID("player", slotID)
            if itemID then
                -- 请求加载物品数据
                C_Item.RequestLoadItemDataByID(itemID)

                local spellID, duration = GetItemSpellInfo(itemID)
                if spellID then
                    -- 获取物品图标
                    local _, _, _, _, _, _, _, _, _, itemIcon = C_Item.GetItemInfo(itemID)

                    -- 注册到池
                    _iconPool[spellID] = {
                        frame = oldPool[spellID] and oldPool[spellID].frame or nil,
                        itemID = itemID,
                        duration = duration,
                        isAuto = true,
                    }

                    -- 记录自动检测的物品
                    _autoDetectedItems[itemID] = {
                        spellID = spellID,
                        icon = itemIcon or 134400,
                        duration = duration or 0,
                    }

                    if not duration then
                        unloadedCount = unloadedCount + 1
                    end
                else
                    unloadedCount = unloadedCount + 1
                end
            end
        end
    end

    -- 扫描手动添加的物品
    for itemID in pairs(config.itemIDs or {}) do
        -- 请求加载物品数据
        C_Item.RequestLoadItemDataByID(itemID)

        local spellID, duration = GetItemSpellInfo(itemID)

        -- 如果没有解析到持续时间，使用手动设置的持续时间
        if not duration and config.itemDurations[itemID] then
            duration = config.itemDurations[itemID]
        end

        if spellID then
            -- 注册到池
            _iconPool[spellID] = {
                frame = oldPool[spellID] and oldPool[spellID].frame or nil,
                itemID = itemID,
                duration = duration,
                isAuto = false,
            }

            if not duration then
                unloadedCount = unloadedCount + 1
            end
        else
            unloadedCount = unloadedCount + 1
        end
    end

    -- 为新的spellID创建图标帧，并设置图标纹理
    for spellID, poolData in pairs(_iconPool) do
        if not poolData.frame then
            poolData.frame = CreateIconFrame()
        end

        -- 设置图标纹理（用于编辑模式预览）
        if poolData.frame and poolData.itemID then
            local _, _, _, _, _, _, _, _, _, itemIcon = C_Item.GetItemInfo(poolData.itemID)
            if itemIcon then
                poolData.frame.icon:SetTexture(itemIcon)
            end
        end
    end

    -- 刷新布局
    RefreshLayout()

    return unloadedCount
end

local function ScheduleScan()
    -- 取消之前的定时器
    if _scanTimer then
        _scanTimer:Cancel()
        _scanTimer = nil
    end

    _scanRetryCount = 0

    -- 执行扫描
    local unloadedCount = ScanItems()

    -- 如果有未加载的物品，启动重试机制
    if unloadedCount > 0 then
        _scanTimer = C_Timer.NewTicker(0.5, function()
            _scanRetryCount = _scanRetryCount + 1

            local stillUnloaded = ScanItems()

            -- 如果全部加载完成或达到最大重试次数，停止定时器
            if stillUnloaded == 0 or _scanRetryCount >= 10 then
                if _scanTimer then
                    _scanTimer:Cancel()
                    _scanTimer = nil
                end
            end
        end)
    end
end

-- =========================================================
-- 布局刷新
-- =========================================================

function RefreshLayout()
    if not _container then return end

    local db = VFlow.getDB(MODULE_KEY)
    local config = db.trinketPotion
    local isEditMode = VFlow.State.get("isEditMode")

    -- 收集可见的图标
    local visibleIcons = {}
    local orderedPool = {}
    for spellID, poolData in pairs(_iconPool) do
        if poolData.frame then
            table.insert(orderedPool, { spellID = spellID, poolData = poolData })
        end
    end
    table.sort(orderedPool, function(a, b) return a.spellID < b.spellID end)

    for index, entry in ipairs(orderedPool) do
        local poolData = entry.poolData
        if isEditMode then
            if index <= 2 then
                poolData.frame:Show()
                table.insert(visibleIcons, poolData.frame)
            else
                poolData.frame:Hide()
            end
        else
            if poolData.frame.hideTimer then
                poolData.frame:Show()
                table.insert(visibleIcons, poolData.frame)
            else
                poolData.frame:Hide()
            end
        end
    end

    local count = #visibleIcons
    if count == 0 then
        -- 编辑模式下，即使没有图标也要设置一个最小尺寸
        if isEditMode then
            _container:SetSize(100, 100)
        else
            _container:SetSize(1, 1)
        end
        return
    end

    -- 获取配置
    local w = config.width or 40
    local h = config.height or 40
    local spacingX = config.spacingX or 2
    local spacingY = config.spacingY or 2
    local isVertical = (config.vertical == true)
    local growDir = config.growDirection or "center"

    -- 应用样式到图标
    for _, frame in ipairs(visibleIcons) do
        if VFlow.StyleApply then
            VFlow.StyleApply.ApplyIconSize(frame, w, h)
            VFlow.StyleApply.ApplyButtonStyle(frame, config)
        end
        frame:SetAlpha(1)
    end

    -- 布局图标
    if not isVertical then
        -- 水平布局
        if config.dynamicLayout then
            -- 动态布局：根据growDirection决定增长方向
            local totalW = count * w + (count - 1) * spacingX
            _container:SetSize(totalW, h)

            if growDir == "center" then
                -- 居中增长
                local startX = -(totalW / 2) + w / 2
                for i, frame in ipairs(visibleIcons) do
                    local offsetX = startX + (i - 1) * (w + spacingX)
                    frame:ClearAllPoints()
                    frame:SetPoint("CENTER", _container, "CENTER", offsetX, 0)
                    frame:SetSize(w, h)
                end
            elseif growDir == "start" then
                -- 从起点（左边）增长
                for i, frame in ipairs(visibleIcons) do
                    local offsetX = (i - 1) * (w + spacingX)
                    frame:ClearAllPoints()
                    frame:SetPoint("LEFT", _container, "LEFT", offsetX, 0)
                    frame:SetSize(w, h)
                end
            elseif growDir == "end" then
                -- 从终点（右边）增长
                for i, frame in ipairs(visibleIcons) do
                    local offsetX = -((i - 1) * (w + spacingX))
                    frame:ClearAllPoints()
                    frame:SetPoint("RIGHT", _container, "RIGHT", offsetX, 0)
                    frame:SetSize(w, h)
                end
            end
        else
            -- 固定布局：简单的水平排列
            local totalW = count * w + (count - 1) * spacingX
            _container:SetSize(totalW, h)
            for i, frame in ipairs(visibleIcons) do
                local offsetX = (i - 1) * (w + spacingX)
                frame:ClearAllPoints()
                frame:SetPoint("LEFT", _container, "LEFT", offsetX, 0)
                frame:SetSize(w, h)
            end
        end
    else
        -- 垂直布局
        if config.dynamicLayout then
            -- 动态布局：根据growDirection决定增长方向
            local totalH = count * h + (count - 1) * spacingY
            _container:SetSize(w, totalH)

            if growDir == "center" then
                -- 居中增长
                local startY = (totalH / 2) - h / 2
                for i, frame in ipairs(visibleIcons) do
                    local offsetY = startY - (i - 1) * (h + spacingY)
                    frame:ClearAllPoints()
                    frame:SetPoint("CENTER", _container, "CENTER", 0, offsetY)
                    frame:SetSize(w, h)
                end
            elseif growDir == "start" then
                -- 从起点（上边）增长
                for i, frame in ipairs(visibleIcons) do
                    local offsetY = -((i - 1) * (h + spacingY))
                    frame:ClearAllPoints()
                    frame:SetPoint("TOP", _container, "TOP", 0, offsetY)
                    frame:SetSize(w, h)
                end
            elseif growDir == "end" then
                -- 从终点（下边）增长
                for i, frame in ipairs(visibleIcons) do
                    local offsetY = (i - 1) * (h + spacingY)
                    frame:ClearAllPoints()
                    frame:SetPoint("BOTTOM", _container, "BOTTOM", 0, offsetY)
                    frame:SetSize(w, h)
                end
            end
        else
            -- 固定布局：简单的垂直排列
            local totalH = count * h + (count - 1) * spacingY
            _container:SetSize(w, totalH)
            for i, frame in ipairs(visibleIcons) do
                local offsetY = -((i - 1) * (h + spacingY))
                frame:ClearAllPoints()
                frame:SetPoint("TOP", _container, "TOP", 0, offsetY)
                frame:SetSize(w, h)
            end
        end
    end
end

-- =========================================================
-- 事件监听
-- =========================================================

VFlow.on("PLAYER_ENTERING_WORLD", "TrinketPotionMonitor", function()
    C_Timer.After(1, function()
        InitContainer()
        ScheduleScan()
    end)
end)

VFlow.on("PLAYER_EQUIPMENT_CHANGED", "TrinketPotionMonitor", function(event, slotID)
    if slotID == 13 or slotID == 14 then
        ScheduleScan()
    end
end)

VFlow.on("UNIT_SPELLCAST_SUCCEEDED", "TrinketPotionMonitor", function(event, unit, _, spellID)
    if unit ~= "player" then return end

    for sid, poolData in pairs(_iconPool) do
        if sid == spellID then
            ActivateIcon(spellID, poolData.itemID)
            break
        end
    end
end)

-- =========================================================
-- Store监听
-- =========================================================

VFlow.Store.watch(MODULE_KEY, "TrinketPotionMonitor", function(key, value)
    if not key:find("^trinketPotion%.") then return end

    -- x/y坐标变化: 只更新位置
    if key:find("%.x$") or key:find("%.y$") then
        UpdateContainerPosition()
        return
    end

    -- autoTrinkets/itemIDs/itemDurations变化: 重新扫描
    if key == "trinketPotion.autoTrinkets" or
        key == "trinketPotion.itemIDs" or
        key == "trinketPotion.itemDurations" then
        ScheduleScan()
        return
    end

    -- 其他配置变化: 刷新布局
    RefreshLayout()
end)

-- 监听编辑模式状态变化
VFlow.State.watch("isEditMode", "TrinketPotionMonitor", function(key, value)
    -- 编辑模式切换时刷新布局
    RefreshLayout()
end)

-- =========================================================
-- 公共API
-- =========================================================

VFlow.TrinketPotionMonitor = {
    parseDurationFromItem = function(itemID)
        local _, duration = GetItemSpellInfo(itemID)
        return duration
    end,

    getAutoDetectedItems = function()
        local items = {}
        for itemID, data in pairs(_autoDetectedItems) do
            table.insert(items, {
                itemID = itemID,
                spellID = data.spellID,
                icon = data.icon,
                duration = data.duration,
            })
        end
        table.sort(items, function(a, b) return a.itemID < b.itemID end)
        return items
    end,

    refresh = RefreshLayout,
}
