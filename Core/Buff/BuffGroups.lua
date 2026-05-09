-- =========================================================
-- SECTION 1: 模块入口
-- BuffGroups — 自定义 BUFF 分组布局
-- =========================================================

local VFlow = _G.VFlow
if not VFlow then return end

local MODULE_KEY = "VFlow.Buffs"
local Profiler = VFlow.Profiler
local MasqueSupport = VFlow.MasqueSupport
local StyleLayout = VFlow.StyleLayout

-- =========================================================
-- SECTION 2: 模块状态
-- =========================================================

local _groupSpellMap = {}   -- {[spellID] = groupIndex}
local _groupContainers = {} -- {[groupIndex] = frame}
local _spellMapDirty = true

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

    -- 添加需要隐藏的BUFF（映射到特殊组索引-1）
    local customMonitorDB = VFlow.Store.getModuleRef and VFlow.Store.getModuleRef("VFlow.CustomMonitor")
    local hideConfig = customMonitorDB and customMonitorDB.buffs
    if hideConfig then
        for spellID, config in pairs(hideConfig) do
            if config.hideInCooldownManager then
                -- 只隐藏明确配置的spellID，不处理基础法术ID
                -- 避免天赋替换后误隐藏其他BUFF
                _groupSpellMap[spellID] = -1
            end
        end
    end

    return _groupSpellMap
end

-- =========================================================
-- SECTION 4: 图标分类
-- =========================================================

local function LookupSpellInGroupMap(spellID, spellMap)
    if not spellID or spellID <= 0 then return nil end
    local groupIdx = spellMap[spellID]
    if groupIdx then return groupIdx end
    if C_Spell and C_Spell.GetBaseSpell then
        local baseID = C_Spell.GetBaseSpell(spellID)
        if baseID and baseID ~= spellID then
            groupIdx = spellMap[baseID]
            if groupIdx then return groupIdx end
        end
    end
    return nil
end

local function GetGroupIdxForIcon(icon, spellMap)
    local id, groupIdx

    if icon.GetAuraSpellID then
        id = icon:GetAuraSpellID()
        if id and not issecretvalue(id) and type(id) == "number" and id > 0 then
            groupIdx = LookupSpellInGroupMap(id, spellMap)
            if groupIdx then return groupIdx end
        end
    end

    if icon.GetSpellID then
        id = icon:GetSpellID()
        if id and not issecretvalue(id) and type(id) == "number" and id > 0 then
            groupIdx = LookupSpellInGroupMap(id, spellMap)
            if groupIdx then return groupIdx end
        end
    end

    if icon.cooldownID and StyleLayout and StyleLayout.GetCachedCooldownViewerInfo then
        local info = StyleLayout.GetCachedCooldownViewerInfo(icon)
        if info then
            local spellID = info.linkedSpellIDs and info.linkedSpellIDs[1]
            spellID = spellID or info.overrideSpellID or info.spellID
            if spellID and type(spellID) == "number" and (not issecretvalue or not issecretvalue(spellID)) and spellID > 0 then
                groupIdx = LookupSpellInGroupMap(spellID, spellMap)
                if groupIdx then return groupIdx end
            end
        end
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
            -- 特殊组：需要隐藏的BUFF
            if icon.Hide then icon:Hide() end
            if icon.SetAlpha then icon:SetAlpha(0) end
        elseif groupIdx then
            -- BUFF图标：恢复透明度，但不调用Show()（让系统控制）
            if icon.SetAlpha and icon:GetAlpha() < 0.1 then
                icon:SetAlpha(1)
            end
            groupBuckets[groupIdx] = groupBuckets[groupIdx] or {}
            table.insert(groupBuckets[groupIdx], icon)
        else
            -- BUFF图标：恢复透明度，但不调用Show()（让系统控制）
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

local function InitGroupContainers()
    local db = VFlow.getDB(MODULE_KEY)
    local groups = db and db.customGroups

    for i, container in pairs(_groupContainers) do
        VFlow.DragFrame.unregister(container)
        if VFlow.VisibilityControl and VFlow.VisibilityControl.UnregisterFrame then
            VFlow.VisibilityControl.UnregisterFrame(container)
        end
        container:Hide()
        container:SetParent(nil)
        _groupContainers[i] = nil
    end

    if not groups then
        return
    end

    for i, group in ipairs(groups) do
        if group and group.config then
            local container = CreateFrame("Frame", "VFlow_BuffGroup_" .. i, UIParent)
            container:SetFrameStrata("MEDIUM")
            container:SetFrameLevel(10)
            container:SetSize(200, 50)
            container:SetMovable(true)
            container:SetClampedToScreen(true)

            VFlow.ContainerAnchor.ApplyFramePosition(container, group.config, nil)

            VFlow.DragFrame.register(container, {
                label = group.name or ((VFlow.L and VFlow.L["Custom group"] or "Custom group") .. i),
                menuKey = "buff_custom_" .. i,
                getAnchorConfig = function()
                    return group.config
                end,
                onPositionChanged = function(_, kind, x, y)
                    if kind ~= "PLAYER_ANCHOR" and kind ~= "SYMMETRIC" then return end
                    VFlow.Store.set(MODULE_KEY, "customGroups." .. i .. ".config.x", x)
                    VFlow.Store.set(MODULE_KEY, "customGroups." .. i .. ".config.y", y)
                end,
                getAnchorOffset = function(frame)
                    local cfg = group.config
                    if not cfg or not cfg.dynamicLayout then
                        return 0, 0
                    end

                    local growDir = cfg.growDirection or "center"
                    if growDir == "center" then
                        return 0, 0
                    end

                    local w, h = frame:GetSize()
                    local isVertical = (cfg.vertical == true)

                    if not isVertical then
                        if growDir == "start" then
                            return -w / 2, 0
                        elseif growDir == "end" then
                            return w / 2, 0
                        end
                    else
                        if growDir == "start" then
                            return 0, h / 2
                        elseif growDir == "end" then
                            return 0, -h / 2
                        end
                    end

                    return 0, 0
                end,
            })

            if VFlow.DragFrame.applyRegisteredPosition then
                VFlow.DragFrame.applyRegisteredPosition(container)
            end

            -- 自定义组在 UIParent 上，需与 BuffIconCooldownViewer 共用「BUFF」显示条件
            if VFlow.VisibilityControl and VFlow.VisibilityControl.RegisterFrame then
                VFlow.VisibilityControl.RegisterFrame(container, "buffs")
            end

            _groupContainers[i] = container
        end
    end

    if VFlow.VisibilityControl and VFlow.VisibilityControl.EvaluateAll then
        VFlow.VisibilityControl.EvaluateAll()
    end
end

-- =========================================================
-- SECTION 6: 分组布局
-- =========================================================

local function LayoutBuffGroups(groupBuckets)
    local db = VFlow.getDB(MODULE_KEY)
    if not db or not db.customGroups then
        return
    end

    -- PEW 后首次分类进组时，容器可能尚未建好；此处懒初始化避免首帧落在主组默认位
    for groupIdx in pairs(groupBuckets) do
        local g = db.customGroups[groupIdx]
        if g and g.config and not _groupContainers[groupIdx] then
            InitGroupContainers()
            break
        end
    end

    for groupIdx, allIcons in pairs(groupBuckets) do
        local group = db.customGroups[groupIdx]
        local container = _groupContainers[groupIdx]

        if group and group.config and container then
            local cfg = group.config
            local icons = {}
            local hiddenIcons = {}

            -- 根据dynamicLayout决定是否过滤
            if cfg.dynamicLayout then
                -- 动态布局：只保留可见且有纹理的图标
                for _, icon in ipairs(allIcons) do
                    if icon:IsShown() and icon.Icon and icon.Icon:GetTexture() then
                        table.insert(icons, icon)
                    else
                        table.insert(hiddenIcons, icon)
                    end
                end
            else
                -- 固定布局：保留所有图标（包括不可见的）
                icons = allIcons
            end

            local count = #icons

            if count > 0 then
                local w = cfg.width or 40
                local h = cfg.height or 40
                local spacingX = cfg.spacingX or 2
                local spacingY = cfg.spacingY or 2
                local iconScale = 1
                local firstIcon = icons[1]
                if firstIcon and firstIcon.GetScale then
                    local scale = firstIcon:GetScale()
                    if type(scale) == "number" and scale > 0 then
                        iconScale = scale
                    end
                end

                -- 应用样式到自定义组图标（使用自定义组的配置）
                for _, icon in ipairs(icons) do
                    icon._vf_cdmKind = "buff"
                    if VFlow.StyleApply then
                        VFlow.StyleApply.ApplyIconSize(icon, w, h)
                        VFlow.StyleApply.ApplyButtonStyleIfStale(icon, cfg)
                    end
                    if MasqueSupport and MasqueSupport:IsActive() and icon.Icon then
                        MasqueSupport:RegisterButton(icon, icon.Icon)
                    end
                    icon:SetAlpha(1)
                end

                local isVertical = (cfg.vertical == true)
                local growDir = cfg.growDirection or "center"

                if not isVertical then
                    -- 水平布局
                    if cfg.dynamicLayout then
                        -- 动态布局：根据growDirection决定增长方向
                        local totalW = count * w + (count - 1) * spacingX
                        container:SetSize(totalW * iconScale, h * iconScale)

                        -- 根据growDirection设置容器锚点
                        local x = cfg.x or 0
                        local y = cfg.y or (-260 - (groupIdx - 1) * 60)
                        container:ClearAllPoints()

                        if growDir == "center" then
                            -- 居中增长：容器锚点在中心
                            container:SetPoint("CENTER", UIParent, "CENTER", x, y)
                            local startX = -(totalW / 2) + w / 2
                            for i, icon in ipairs(icons) do
                                local offsetX = startX + (i - 1) * (w + spacingX)
                                icon:ClearAllPoints()
                                icon:SetPoint("CENTER", container, "CENTER", offsetX, 0)
                                icon:SetSize(w, h)
                            end
                        elseif growDir == "start" then
                            -- 从起点（左边）增长：容器锚点在左边
                            container:SetPoint("LEFT", UIParent, "CENTER", x, y)
                            for i, icon in ipairs(icons) do
                                local offsetX = (i - 1) * (w + spacingX) + w / 2
                                icon:ClearAllPoints()
                                icon:SetPoint("LEFT", container, "LEFT", offsetX - w / 2, 0)
                                icon:SetSize(w, h)
                            end
                        elseif growDir == "end" then
                            -- 从终点（右边）增长：容器锚点在右边
                            container:SetPoint("RIGHT", UIParent, "CENTER", x, y)
                            for i, icon in ipairs(icons) do
                                local offsetX = -((i - 1) * (w + spacingX) + w / 2)
                                icon:ClearAllPoints()
                                icon:SetPoint("RIGHT", container, "RIGHT", offsetX + w / 2, 0)
                                icon:SetSize(w, h)
                            end
                        end

                        -- 隐藏不可见的图标
                        for _, icon in ipairs(hiddenIcons) do
                            icon:SetAlpha(0)
                        end
                    else
                        -- 固定：保留槽位
                        local totalW = count * w + (count - 1) * spacingX
                        local startX = -(totalW / 2) + w / 2
                        container:SetSize(totalW * iconScale, h * iconScale)

                        for i, icon in ipairs(icons) do
                            local x = startX + (i - 1) * (w + spacingX)
                            icon:ClearAllPoints()
                            icon:SetPoint("CENTER", container, "CENTER", x, 0)
                            icon:SetSize(w, h)

                            -- 固定布局：隐藏没有纹理的图标
                            if icon:IsShown() and icon.Icon and icon.Icon:GetTexture() then
                                icon:SetAlpha(1)
                            else
                                icon:SetAlpha(0)
                            end
                        end
                    end
                else
                    -- 垂直布局
                    if cfg.dynamicLayout then
                        -- 动态布局：根据growDirection决定增长方向
                        local totalH = count * h + (count - 1) * spacingY
                        container:SetSize(w * iconScale, totalH * iconScale)

                        -- 根据growDirection设置容器锚点
                        local x = cfg.x or 0
                        local y = cfg.y or (-260 - (groupIdx - 1) * 60)
                        container:ClearAllPoints()

                        if growDir == "center" then
                            -- 居中增长：容器锚点在中心
                            container:SetPoint("CENTER", UIParent, "CENTER", x, y)
                            local startY = (totalH / 2) - h / 2
                            for i, icon in ipairs(icons) do
                                local offsetY = startY - (i - 1) * (h + spacingY)
                                icon:ClearAllPoints()
                                icon:SetPoint("CENTER", container, "CENTER", 0, offsetY)
                                icon:SetSize(w, h)
                            end
                        elseif growDir == "start" then
                            -- 从起点（顶部）增长：容器锚点在顶部
                            container:SetPoint("TOP", UIParent, "CENTER", x, y)
                            for i, icon in ipairs(icons) do
                                local offsetY = -((i - 1) * (h + spacingY) + h / 2)
                                icon:ClearAllPoints()
                                icon:SetPoint("TOP", container, "TOP", 0, offsetY + h / 2)
                                icon:SetSize(w, h)
                            end
                        elseif growDir == "end" then
                            -- 从终点（底部）增长：容器锚点在底部
                            container:SetPoint("BOTTOM", UIParent, "CENTER", x, y)
                            for i, icon in ipairs(icons) do
                                local offsetY = (i - 1) * (h + spacingY) + h / 2
                                icon:ClearAllPoints()
                                icon:SetPoint("BOTTOM", container, "BOTTOM", 0, offsetY - h / 2)
                                icon:SetSize(w, h)
                            end
                        end

                        -- 隐藏不可见的图标
                        for _, icon in ipairs(hiddenIcons) do
                            icon:SetAlpha(0)
                        end
                    else
                        -- 固定：保留槽位
                        local totalH = count * h + (count - 1) * spacingY
                        local startY = (totalH / 2) - h / 2
                        container:SetSize(w * iconScale, totalH * iconScale)

                        for i, icon in ipairs(icons) do
                            local y = startY - (i - 1) * (h + spacingY)
                            icon:ClearAllPoints()
                            icon:SetPoint("CENTER", container, "CENTER", 0, y)
                            icon:SetSize(w, h)

                            -- 固定布局：隐藏没有纹理的图标
                            if icon:IsShown() and icon.Icon and icon.Icon:GetTexture() then
                                icon:SetAlpha(1)
                            else
                                icon:SetAlpha(0)
                            end
                        end
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

VFlow.BuffGroups = {
    classifyIcons = ClassifyIcons,
    layoutBuffGroups = LayoutBuffGroups,
    forEachGroupIcon = ForEachGroupIcon,
    isGroupFrame = function(icon)
        local spellMap = RebuildSpellMap()
        local idx = GetGroupIdxForIcon(icon, spellMap)
        return idx ~= nil and idx ~= -1
    end,
}

if Profiler and Profiler.registerScope then
    Profiler.registerScope("BG:RebuildSpellMap", function()
        return RebuildSpellMap
    end, function(fn)
        RebuildSpellMap = fn
    end)
    Profiler.registerScope("BG:InitGroupContainers", function()
        return InitGroupContainers
    end, function(fn)
        InitGroupContainers = fn
    end)
end

if Profiler and Profiler.registerTableScope then
    Profiler.registerTableScope(VFlow.BuffGroups, "classifyIcons", "BG:ClassifyIcons")
    Profiler.registerTableScope(VFlow.BuffGroups, "layoutBuffGroups", "BG:LayoutBuffGroups")
end

-- =========================================================
-- SECTION 8: 初始化与 Store 监听
-- =========================================================

VFlow.on("PLAYER_ENTERING_WORLD", "BuffGroups", function()
    C_Timer.After(0, InitGroupContainers)
end)

-- 监听配置变更
VFlow.Store.watch(MODULE_KEY, "BuffGroups", function(key, value)
    -- 如果是customGroups的变化，重新初始化容器
    if key == "customGroups" or key:find("^customGroups%.%d+$") then
        InitGroupContainers()
    end

    if key:find("customGroups%.%d+%.config%.") then
        local groupIndex = tonumber(key:match("customGroups%.(%d+)%."))
        if groupIndex and (
            key:find("%.x$") or key:find("%.y$")
            or key:find("%.anchorFrame$") or key:find("%.relativePoint$") or key:find("%.playerAnchorPosition$")
        ) then
            local container = _groupContainers[groupIndex]
            if container and VFlow.DragFrame and VFlow.DragFrame.applyRegisteredPosition then
                VFlow.DragFrame.applyRegisteredPosition(container)
            elseif container then
                local dbp = VFlow.getDB(MODULE_KEY)
                local gc = dbp and dbp.customGroups and dbp.customGroups[groupIndex] and dbp.customGroups[groupIndex].config
                if gc then
                    VFlow.ContainerAnchor.ApplyFramePosition(container, gc, nil)
                end
            end
            return
        end
    end

    -- 其他配置变化：标记映射表需要重建
    _spellMapDirty = true
end)
