-- =========================================================
-- VFlow SkillGroups - 自定义技能分组布局
-- =========================================================

local VFlow = _G.VFlow
if not VFlow then return end

local MODULE_KEY = "VFlow.Skills"

-- =========================================================
-- 模块状态
-- =========================================================

local _groupSpellMap = {}   -- {[spellID] = groupIndex}
local _groupContainers = {} -- {[groupIndex] = frame}

-- =========================================================
-- Spell ID映射构建
-- =========================================================

local function RebuildSpellMap()
    wipe(_groupSpellMap)

    local db = VFlow.getDB(MODULE_KEY)
    if not db or not db.customGroups then return _groupSpellMap end

    for groupIdx, group in ipairs(db.customGroups) do
        if group.config then
            -- 确保spellIDs存在
            if not group.config.spellIDs then
                group.config.spellIDs = {}
            end

            for spellID in pairs(group.config.spellIDs) do
                _groupSpellMap[spellID] = groupIdx

                -- 注册基础法术ID（处理天赋替换）
                if C_Spell and C_Spell.GetBaseSpell then
                    local baseID = C_Spell.GetBaseSpell(spellID)
                    if baseID and baseID ~= spellID then
                        _groupSpellMap[baseID] = _groupSpellMap[baseID] or groupIdx
                    end
                end
            end
        end
    end

    -- 添加需要隐藏的技能（映射到特殊组索引-1）
    local customMonitorDB = VFlow.Store.getModuleRef and VFlow.Store.getModuleRef("VFlow.CustomMonitor")
    local hideConfig = customMonitorDB and customMonitorDB.skills
    if hideConfig then
        for spellID, config in pairs(hideConfig) do
            if config.hideInCooldownManager then
                -- 只隐藏明确配置的spellID，不处理基础法术ID
                -- 避免天赋替换后误隐藏其他技能
                _groupSpellMap[spellID] = -1
            end
        end
    end

    return _groupSpellMap
end

-- =========================================================
-- 图标分类
-- =========================================================

local function GetGroupIdxForIcon(icon, spellMap)
    -- 尝试多个spell ID来源
    local candidates = {}

    -- 优先级1: GetSpellID
    if icon.GetSpellID then
        local id = icon:GetSpellID()
        -- 检查是否为SecureValue（战斗中）
        if id and not issecretvalue(id) and type(id) == "number" and id > 0 then
            table.insert(candidates, id)
        end
    end

    -- 优先级2: CooldownInfo
    if icon.cooldownID then
        local info = C_CooldownViewer.GetCooldownViewerCooldownInfo(icon.cooldownID)
        if info then
            local spellID = info.linkedSpellIDs and info.linkedSpellIDs[1]
            spellID = spellID or info.overrideSpellID or info.spellID
            if spellID and spellID > 0 then
                table.insert(candidates, spellID)
            end
        end
    end

    -- 查找匹配
    for _, spellID in ipairs(candidates) do
        local groupIdx = spellMap[spellID]
        if groupIdx then return groupIdx end

        -- 尝试基础法术
        if C_Spell and C_Spell.GetBaseSpell then
            local baseID = C_Spell.GetBaseSpell(spellID)
            if baseID and baseID ~= spellID then
                groupIdx = spellMap[baseID]
                if groupIdx then return groupIdx end
            end
        end
    end

    return nil
end

local function ClassifyIcons(allIcons)
    local spellMap = RebuildSpellMap()
    local mainVisible = {}
    local groupBuckets = {}

    for _, icon in ipairs(allIcons) do
        local groupIdx = GetGroupIdxForIcon(icon, spellMap)

        if groupIdx == -1 then
            -- 特殊组：需要隐藏的技能
            if icon.Hide then icon:Hide() end
            if icon.SetAlpha then icon:SetAlpha(0) end
        elseif groupIdx then
            -- 技能图标：恢复显示状态
            if icon.Show and not icon:IsShown() then
                icon:Show()
            end
            if icon.SetAlpha and icon:GetAlpha() < 0.1 then
                icon:SetAlpha(1)
            end
            groupBuckets[groupIdx] = groupBuckets[groupIdx] or {}
            table.insert(groupBuckets[groupIdx], icon)
        else
            -- 技能图标：恢复显示状态
            if icon.Show and not icon:IsShown() then
                icon:Show()
            end
            if icon.SetAlpha and icon:GetAlpha() < 0.1 then
                icon:SetAlpha(1)
            end
            table.insert(mainVisible, icon)
        end
    end

    return mainVisible, groupBuckets
end

-- =========================================================
-- 容器管理
-- =========================================================

local function EnsureGroupContainer(groupIdx)
    if _groupContainers[groupIdx] then
        return _groupContainers[groupIdx]
    end

    local db = VFlow.getDB(MODULE_KEY)
    if not db or not db.customGroups then return nil end

    local group = db.customGroups[groupIdx]
    if not group or not group.config then return nil end

    local container = CreateFrame("Frame", "VFlow_SkillGroup_" .. groupIdx, UIParent)
    container:SetFrameStrata("MEDIUM")
    container:SetFrameLevel(10)
    container:SetSize(200, 50)
    container:SetMovable(true)
    container:SetClampedToScreen(true)

    -- 应用保存的位置
    local x = group.config.x or 0
    local y = group.config.y or (-200 - (groupIdx - 1) * 60)
    container:ClearAllPoints()
    container:SetPoint("CENTER", UIParent, "CENTER", x, y)

    -- 注册拖拽
    VFlow.DragFrame.register(container, {
        label = group.name or ("自定义技能组" .. groupIdx),
        onPositionChanged = function(frame, point, x, y)
            group.config.x = x
            group.config.y = y
            VFlow.Store.set(MODULE_KEY, "customGroups", db.customGroups)
        end,
    })

    _groupContainers[groupIdx] = container
    return container
end

-- 初始化所有容器（用于配置变更时）
local function InitGroupContainers()
    local db = VFlow.getDB(MODULE_KEY)
    if not db or not db.customGroups then return end

    for i, group in ipairs(db.customGroups) do
        if group and group.config then
            EnsureGroupContainer(i)
        end
    end
end

-- =========================================================
-- 分组布局
-- =========================================================

local function LayoutSkillGroups(groupBuckets)
    local db = VFlow.getDB(MODULE_KEY)
    if not db or not db.customGroups then return end

    for groupIdx, allIcons in pairs(groupBuckets) do
        local group = db.customGroups[groupIdx]

        if group and group.config then
            local container = EnsureGroupContainer(groupIdx)

            if container then
                local cfg = group.config

                -- 过滤可见图标
                local icons = {}
                for _, icon in ipairs(allIcons) do
                    if icon:IsShown() then
                        local tex = icon.Icon and icon.Icon:GetTexture()
                        if tex then
                            table.insert(icons, icon)
                        end
                    end
                end

                local count = #icons

                if count > 0 then
                    local iconW = cfg.iconWidth or 40
                    local iconH = cfg.iconHeight or 40
                    local row2W = cfg.secondRowIconWidth or iconW
                    local row2H = cfg.secondRowIconHeight or iconH
                    local spacingX = cfg.spacingX or 2
                    local spacingY = cfg.spacingY or 2
                    local limit = cfg.maxIconsPerRow or 8
                    local isVertical = (cfg.vertical == true)
                    local fixedRowLengthByLimit = (cfg.fixedRowLengthByLimit == true)
                    local rowAnchor = cfg.rowAnchor or "center"
                    local iconScale = 1
                    local firstIcon = icons[1]
                    if firstIcon and firstIcon.GetScale then
                        local scale = firstIcon:GetScale()
                        if type(scale) == "number" and scale > 0 then
                            iconScale = scale
                        end
                    end

                    -- 分行
                    local rows = VFlow.StyleLayout.BuildRows(limit, icons)

                    if not isVertical then
                        -- 水平布局
                        -- 计算最宽行宽度（用于居中对齐）
                        local maxRowW = 0
                        for ri, rIcons in ipairs(rows) do
                            local rw = (ri == 1) and iconW or row2W
                            local iconCountForWidth = fixedRowLengthByLimit and math.max(limit, 1) or #rIcons
                            local rcw = iconCountForWidth * (rw + spacingX) - spacingX
                            if rcw > maxRowW then maxRowW = rcw end
                        end

                        -- 计算总高度
                        local totalH = 0
                        for ri, rIcons in ipairs(rows) do
                            local rh = (ri == 1) and iconH or row2H
                            totalH = totalH + rh
                            if ri < #rows then
                                totalH = totalH + spacingY
                            end
                        end

                        local yAccum = 0

                        for rowIdx, rowIcons in ipairs(rows) do
                            local w = (rowIdx == 1) and iconW or row2W
                            local h = (rowIdx == 1) and iconH or row2H

                            local rowContentW = #rowIcons * (w + spacingX) - spacingX
                            local rowBaseW = fixedRowLengthByLimit and (math.max(limit, 1) * (w + spacingX) - spacingX) or maxRowW
                            local alignOffset = rowBaseW - rowContentW
                            local anchorOffset = 0
                            if rowAnchor == "right" then
                                anchorOffset = alignOffset
                            elseif rowAnchor == "center" then
                                anchorOffset = alignOffset / 2
                            end
                            local startX = (maxRowW - rowBaseW) / 2 + anchorOffset

                            for colIdx, button in ipairs(rowIcons) do
                                -- 应用样式
                                if VFlow.StyleApply then
                                    VFlow.StyleApply.ApplyIconSize(button, w, h)
                                    VFlow.StyleApply.ApplyButtonStyle(button, cfg)
                                end

                                local x = startX + (colIdx - 1) * (w + spacingX)
                                local y = -yAccum

                                button:ClearAllPoints()
                                button:SetPoint("TOPLEFT", container, "TOPLEFT", x, y)
                                button:SetAlpha(1)
                            end

                            yAccum = yAccum + h + spacingY
                        end

                        -- 更新容器大小
                        container:SetSize(maxRowW * iconScale, totalH * iconScale)
                    else
                        -- 垂直布局
                        -- 计算最高列高度（用于居中对齐）
                        local maxColH = 0
                        for ri, rIcons in ipairs(rows) do
                            local rh = (ri == 1) and iconH or row2H
                            local rch = #rIcons * (rh + spacingY) - spacingY
                            if rch > maxColH then maxColH = rch end
                        end

                        -- 计算总宽度
                        local totalW = 0
                        for ri, rIcons in ipairs(rows) do
                            local rw = (ri == 1) and iconW or row2W
                            totalW = totalW + rw
                            if ri < #rows then
                                totalW = totalW + spacingX
                            end
                        end

                        local xAccum = 0

                        for rowIdx, rowIcons in ipairs(rows) do
                            local w = (rowIdx == 1) and iconW or row2W
                            local h = (rowIdx == 1) and iconH or row2H

                            local colContentH = #rowIcons * (h + spacingY) - spacingY
                            local startY = -(maxColH - colContentH) / 2

                            for colIdx, button in ipairs(rowIcons) do
                                -- 应用样式
                                if VFlow.StyleApply then
                                    VFlow.StyleApply.ApplyIconSize(button, w, h)
                                    VFlow.StyleApply.ApplyButtonStyle(button, cfg)
                                end

                                local x = xAccum
                                local y = startY - (colIdx - 1) * (h + spacingY)

                                button:ClearAllPoints()
                                button:SetPoint("TOPLEFT", container, "TOPLEFT", x, y)
                                button:SetAlpha(1)
                            end

                            xAccum = xAccum + w + spacingX
                        end

                        -- 更新容器大小
                        container:SetSize(totalW * iconScale, maxColH * iconScale)
                    end
                end
            end
        end
    end
end

-- =========================================================
-- 公共API
-- =========================================================

VFlow.SkillGroups = {
    classifyIcons = ClassifyIcons,
    layoutSkillGroups = LayoutSkillGroups,
}

-- =========================================================
-- 初始化
-- =========================================================

VFlow.on("PLAYER_ENTERING_WORLD", "SkillGroups", function()
    C_Timer.After(1, RebuildSpellMap)
end)

-- 监听配置变更
VFlow.Store.watch(MODULE_KEY, "SkillGroups", function(key, value)
    -- 如果是customGroups的变化，重新初始化容器
    if key == "customGroups" or key:find("^customGroups%.%d+$") then
        InitGroupContainers()
    end

    -- 如果是x或y坐标变化，更新容器位置（不重新初始化）
    if key:find("%.x$") or key:find("%.y$") then
        local groupIndex = tonumber(key:match("customGroups%.(%d+)%."))
        if groupIndex then
            local container = _groupContainers[groupIndex]
            local db = VFlow.getDB(MODULE_KEY)
            if container and db and db.customGroups[groupIndex] then
                local group = db.customGroups[groupIndex]
                local x = group.config.x or 0
                local y = group.config.y or (-200 - (groupIndex - 1) * 60)
                container:ClearAllPoints()
                container:SetPoint("CENTER", UIParent, "CENTER", x, y)
            end
        end
        -- x/y变化不需要触发其他刷新，直接返回
        return
    end

    -- 其他配置变化：重新构建映射表
    RebuildSpellMap()
end)
