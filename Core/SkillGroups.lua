-- =========================================================
-- SECTION 1: 模块入口
-- SkillGroups — 自定义技能分组布局
-- =========================================================

local VFlow = _G.VFlow
if not VFlow then return end

local MODULE_KEY = "VFlow.Skills"
local StyleLayout = VFlow.StyleLayout
local Profiler = VFlow.Profiler
local MasqueSupport = VFlow.MasqueSupport

-- =========================================================
-- SECTION 2: 模块状态
-- =========================================================

local _groupSpellMap = {}   -- {[spellID] = groupIndex}
local _groupContainers = {} -- {[groupIndex] = frame}
local _spellMapDirty = true -- 脏标志：只在配置变更时重建

-- =========================================================
-- SECTION 3: SpellID → 分组映射
-- =========================================================

local function RebuildSpellMap()
    if not _spellMapDirty then return _groupSpellMap end
    _spellMapDirty = false

    wipe(_groupSpellMap)

    local db = VFlow.getDB(MODULE_KEY)
    if not db or not db.customGroups then
        return _groupSpellMap
    end

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
-- SECTION 4: 图标分类
-- =========================================================

local function IsPositiveSpellId(spellID)
    if spellID == nil then return false end
    if issecretvalue and issecretvalue(spellID) then return false end
    return type(spellID) == "number" and spellID > 0
end

local function LookupSpellInGroupMap(spellID, spellMap)
    if not IsPositiveSpellId(spellID) then return nil end
    local groupIdx = spellMap[spellID]
    if groupIdx then return groupIdx end
    if C_Spell and C_Spell.GetBaseSpell then
        local baseID = C_Spell.GetBaseSpell(spellID)
        if IsPositiveSpellId(baseID) and baseID ~= spellID then
            groupIdx = spellMap[baseID]
            if groupIdx then return groupIdx end
        end
    end
    return nil
end

local function AddSpellCandidate(list, spellID)
    if not IsPositiveSpellId(spellID) then return end
    list[#list + 1] = spellID
end

--- 技能 CDM 在「施法/冷却」与「光环激活」等阶段可能上报不同 spellID；仅取 linked[1] 会在操控时间、隐形等法术上漏匹配。
local function CollectSpellCandidatesForGroup(icon)
    local c = {}
    if icon.GetSpellID then
        AddSpellCandidate(c, icon:GetSpellID())
    end
    if icon.GetAuraSpellID then
        AddSpellCandidate(c, icon:GetAuraSpellID())
    end
    if icon.cooldownID and StyleLayout and StyleLayout.GetCachedCooldownViewerInfo then
        local info = StyleLayout.GetCachedCooldownViewerInfo(icon)
        if info then
            AddSpellCandidate(c, info.overrideSpellID)
            local baseID = info.spellID
            if IsPositiveSpellId(baseID) and C_Spell and C_Spell.GetOverrideSpell then
                AddSpellCandidate(c, C_Spell.GetOverrideSpell(baseID))
            end
            if info.linkedSpellIDs then
                for _, lid in ipairs(info.linkedSpellIDs) do
                    AddSpellCandidate(c, lid)
                end
            end
            AddSpellCandidate(c, info.spellID)
        end
    end
    return c
end

local function GetGroupIdxForIcon(icon, spellMap)
    for _, spellID in ipairs(CollectSpellCandidatesForGroup(icon)) do
        local groupIdx = LookupSpellInGroupMap(spellID, spellMap)
        if groupIdx then return groupIdx end
    end
    return nil
end

local function ClassifyIcons(allIcons)
    local spellMap = RebuildSpellMap()

    if not next(spellMap) then
        local n = #allIcons
        local mainVisible = {}
        for i = 1, n do
            mainVisible[i] = allIcons[i]
        end
        return mainVisible, {}
    end

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
-- SECTION 5: 容器管理
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

    VFlow.ContainerAnchor.ApplyFramePosition(container, group.config, nil)

    VFlow.DragFrame.register(container, {
        label = group.name or ((VFlow.L and VFlow.L["Custom skill group"] or "Custom skill group") .. groupIdx),
        menuKey = "skill_custom_" .. groupIdx,
        getAnchorConfig = function()
            return group.config
        end,
        onPositionChanged = function(_, kind, x, y)
            if kind ~= "PLAYER_ANCHOR" and kind ~= "SYMMETRIC" then return end
            group.config.x = x
            group.config.y = y
            VFlow.Store.set(MODULE_KEY, "customGroups", db.customGroups)
        end,
    })

    if VFlow.DragFrame.applyRegisteredPosition then
        VFlow.DragFrame.applyRegisteredPosition(container)
    end

    _groupContainers[groupIdx] = container
    return container
end

local function ReleaseGroupContainer(groupIdx)
    local container = _groupContainers[groupIdx]
    if not container then return end
    VFlow.DragFrame.unregister(container)
    container:Hide()
    container:SetParent(nil)
    _groupContainers[groupIdx] = nil
end

-- 初始化所有容器（用于配置变更时）
local function InitGroupContainers()
    local db = VFlow.getDB(MODULE_KEY)
    local groups = db and db.customGroups

    for groupIdx in pairs(_groupContainers) do
        ReleaseGroupContainer(groupIdx)
    end

    if not groups then
        return
    end

    for i, group in ipairs(groups) do
        if group and group.config then
            EnsureGroupContainer(i)
        end
    end
end

-- =========================================================
-- SECTION 6: 分组布局
-- =========================================================

local function LayoutSkillGroups(groupBuckets)
    local db = VFlow.getDB(MODULE_KEY)
    if not db or not db.customGroups then
        return
    end

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

                            local PP = VFlow.PixelPerfect
                            local wSnap, strideX = w, w + spacingX
                            local x0 = startX
                            local hSnap = h
                            if PP and PP.NormalizeColumnStride and PP.PixelSnap then
                                wSnap, strideX = PP.NormalizeColumnStride(w, spacingX, container)
                                x0 = PP.PixelSnap(startX, container)
                                hSnap = PP.PixelSnap(h, container)
                            end

                            for colIdx, button in ipairs(rowIcons) do
                                -- 应用样式
                                if VFlow.StyleApply then
                                    VFlow.StyleApply.ApplyIconSize(button, wSnap, hSnap)
                                    VFlow.StyleApply.ApplyButtonStyleIfStale(button, cfg)
                                end
                                if MasqueSupport and MasqueSupport:IsActive() and button.Icon then
                                    MasqueSupport:RegisterButton(button, button.Icon)
                                end

                                local x = x0 + (colIdx - 1) * strideX
                                local y = -yAccum

                                button:ClearAllPoints()
                                button:SetPoint("TOPLEFT", container, "TOPLEFT", x, y)
                                button:SetAlpha(1)
                                button._vf_cdmKind = "skill"
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
                                    VFlow.StyleApply.ApplyButtonStyleIfStale(button, cfg)
                                end
                                if MasqueSupport and MasqueSupport:IsActive() and button.Icon then
                                    MasqueSupport:RegisterButton(button, button.Icon)
                                end

                                local x = xAccum
                                local y = startY - (colIdx - 1) * (h + spacingY)

                                button:ClearAllPoints()
                                button:SetPoint("TOPLEFT", container, "TOPLEFT", x, y)
                                button:SetAlpha(1)
                                button._vf_cdmKind = "skill"
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
-- SECTION 7: 公共 API
-- =========================================================

local function ForEachGroupIcon(callback)
    if not callback then return end
    for _, container in pairs(_groupContainers) do
        if container and container.GetChildren then
            for _, child in ipairs({ container:GetChildren() }) do
                if child and child.Icon then
                    callback(child)
                end
            end
        end
    end
end

VFlow.SkillGroups = {
    classifyIcons = ClassifyIcons,
    layoutSkillGroups = LayoutSkillGroups,
    forEachGroupIcon = ForEachGroupIcon,
}

if Profiler and Profiler.registerScope then
    Profiler.registerScope("SG:RebuildSpellMap", function()
        return RebuildSpellMap
    end, function(fn)
        RebuildSpellMap = fn
    end)
    Profiler.registerScope("SG:InitGroupContainers", function()
        return InitGroupContainers
    end, function(fn)
        InitGroupContainers = fn
    end)
end

if Profiler and Profiler.registerTableScope then
    Profiler.registerTableScope(VFlow.SkillGroups, "classifyIcons", "SG:ClassifyIcons")
    Profiler.registerTableScope(VFlow.SkillGroups, "layoutSkillGroups", "SG:LayoutSkillGroups")
end

-- =========================================================
-- SECTION 8: 初始化与 Store 监听
-- =========================================================

VFlow.on("PLAYER_ENTERING_WORLD", "SkillGroups", function()
    _spellMapDirty = true
end)

-- 监听配置变更
VFlow.Store.watch(MODULE_KEY, "SkillGroups", function(key, value)
    -- 如果是customGroups的变化，重新初始化容器
    if key == "customGroups" or key:find("^customGroups%.%d+$") then
        InitGroupContainers()
    end

    -- 坐标或依附关系变化：只更新容器锚点
    if key:find("customGroups%.%d+%.config%.") then
        local groupIndex = tonumber(key:match("customGroups%.(%d+)%."))
        if groupIndex and (
            key:find("%.x$") or key:find("%.y$")
            or key:find("%.anchorFrame$") or key:find("%.relativePoint$") or key:find("%.playerAnchorPosition$")
        ) then
            local container = _groupContainers[groupIndex]
            local db = VFlow.getDB(MODULE_KEY)
            if container and db and db.customGroups[groupIndex] and db.customGroups[groupIndex].config then
                if VFlow.DragFrame and VFlow.DragFrame.applyRegisteredPosition then
                    VFlow.DragFrame.applyRegisteredPosition(container)
                else
                    VFlow.ContainerAnchor.ApplyFramePosition(container, db.customGroups[groupIndex].config, nil)
                end
            end
            return
        end
    end

    -- 其他配置变化：标记映射表需要重建
    _spellMapDirty = true
end)
