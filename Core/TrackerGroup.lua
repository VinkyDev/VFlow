-- =========================================================
-- TrackerGroup — 分组追踪器工厂
-- 消除 SkillGroups / BuffGroups 之间的重复逻辑
-- =========================================================

local VFlow = _G.VFlow
if not VFlow then return end
if not VFlow.ModuleControlConstants.CORE_ENABLED then return end

local FD = VFlow.FD
local StyleLayout = VFlow.StyleLayout
local MasqueSupport = VFlow.MasqueSupport
local TrackerGroup = {}
VFlow.TrackerGroup = TrackerGroup

-- =========================================================
-- SECTION 1: 共享工具函数
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

TrackerGroup.IsPositiveSpellId = IsPositiveSpellId
TrackerGroup.LookupSpellInGroupMap = LookupSpellInGroupMap

-- =========================================================
-- SECTION 2: 图标分类策略
-- 技能侧：全面收集候选 spellID（处理覆盖/连锁）
-- =========================================================

local function AddSpellCandidate(list, spellID)
    if not IsPositiveSpellId(spellID) then return end
    list[#list + 1] = spellID
end

--- 技能 CDM 在不同阶段可能上报不同 spellID
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

-- 技能侧：遍历所有候选
local function SkillGetGroupIdxForIcon(icon, spellMap)
    for _, spellID in ipairs(CollectSpellCandidatesForGroup(icon)) do
        local groupIdx = LookupSpellInGroupMap(spellID, spellMap)
        if groupIdx then return groupIdx end
    end
    return nil
end

-- BUFF 侧：优先 AuraSpellID
local function BuffGetGroupIdxForIcon(icon, spellMap)
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

TrackerGroup.SkillGetGroupIdxForIcon = SkillGetGroupIdxForIcon
TrackerGroup.BuffGetGroupIdxForIcon = BuffGetGroupIdxForIcon

-- =========================================================
-- SECTION 3: 布局策略 — Grid（技能多行栅格）
-- =========================================================

local function ResetGroupIconStyleState(icon, groupIdx)
    if not icon then return end
    local fd = FD(icon)
    if fd.skillGroupOwner == groupIdx then return end
    fd.skillGroupOwner = groupIdx
    fd.btnStyleVer = nil
    fd.styleVer = nil
    fd.skillVisualVersion = nil
    fd.skillVisualFingerprint = nil
    fd.spellMaskKey = nil
end

local function LayoutGrid(groupBuckets, moduleKey, groupContainers, ensureContainerFn)
    local db = VFlow.getDB(moduleKey)
    if not db or not db.customGroups then return end

    for groupIdx, allIcons in pairs(groupBuckets) do
        local group = db.customGroups[groupIdx]
        if group and group.config then
            local container = ensureContainerFn(groupIdx)
            if container then

            local cfg = group.config
            local icons = {}
            for _, icon in ipairs(allIcons) do
                if icon:IsShown() then
                    local tex = icon.Icon and icon.Icon:GetTexture()
                    if tex then icons[#icons + 1] = icon end
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
                    if type(scale) == "number" and scale > 0 then iconScale = scale end
                end

                local rows = VFlow.StyleLayout.BuildRows(limit, icons)

                if not isVertical then
                    local maxRowW = 0
                    for ri, rIcons in ipairs(rows) do
                        local rw = (ri == 1) and iconW or row2W
                        local n = fixedRowLengthByLimit and math.max(limit, 1) or #rIcons
                        local rcw = n * (rw + spacingX) - spacingX
                        if rcw > maxRowW then maxRowW = rcw end
                    end

                    local totalH = 0
                    for ri in ipairs(rows) do
                        local rh = (ri == 1) and iconH or row2H
                        totalH = totalH + rh
                        if ri < #rows then totalH = totalH + spacingY end
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
                            if button:GetParent() ~= container then
                                button:SetParent(container)
                            end
                            ResetGroupIconStyleState(button, groupIdx)
                            if VFlow.StyleApply then
                                VFlow.StyleApply.ApplyIconSize(button, wSnap, hSnap)
                            end
                            if MasqueSupport and MasqueSupport:IsActive() and button.Icon then
                                MasqueSupport:RegisterButton(button, button.Icon)
                            end

                            local x = x0 + (colIdx - 1) * strideX
                            local y = -yAccum
                            StyleLayout.SetPointCached(button, "TOPLEFT", container, "TOPLEFT", x, y)
                            button:SetAlpha(1)
                            FD(button).cdmKind = "skill"
                        end

                        yAccum = yAccum + h + spacingY
                    end

                    container:SetSize(maxRowW * iconScale, totalH * iconScale)
                else
                    -- 垂直布局
                    local maxColH = 0
                    for ri, rIcons in ipairs(rows) do
                        local rh = (ri == 1) and iconH or row2H
                        local rch = #rIcons * (rh + spacingY) - spacingY
                        if rch > maxColH then maxColH = rch end
                    end

                    local totalW = 0
                    for ri in ipairs(rows) do
                        local rw = (ri == 1) and iconW or row2W
                        totalW = totalW + rw
                        if ri < #rows then totalW = totalW + spacingX end
                    end

                    local xAccum = 0
                    for rowIdx, rowIcons in ipairs(rows) do
                        local w = (rowIdx == 1) and iconW or row2W
                        local h = (rowIdx == 1) and iconH or row2H

                        local colContentH = #rowIcons * (h + spacingY) - spacingY
                        local startY = -(maxColH - colContentH) / 2

                        for colIdx, button in ipairs(rowIcons) do
                            if button:GetParent() ~= container then
                                button:SetParent(container)
                            end
                            ResetGroupIconStyleState(button, groupIdx)
                            if VFlow.StyleApply then
                                VFlow.StyleApply.ApplyIconSize(button, w, h)
                            end
                            if MasqueSupport and MasqueSupport:IsActive() and button.Icon then
                                MasqueSupport:RegisterButton(button, button.Icon)
                            end

                            local x = xAccum
                            local y = startY - (colIdx - 1) * (h + spacingY)
                            StyleLayout.SetPointCached(button, "TOPLEFT", container, "TOPLEFT", x, y)
                            button:SetAlpha(1)
                            FD(button).cdmKind = "skill"
                        end

                        xAccum = xAccum + w + spacingX
                    end

                    container:SetSize(totalW * iconScale, maxColH * iconScale)
                end
            end
            end
        end
    end
end

-- =========================================================
-- SECTION 4: 布局策略 — Dynamic（BUFF 动态/固定布局）
-- =========================================================

local function LayoutDynamic(groupBuckets, moduleKey, groupContainers, initContainersFn)
    local db = VFlow.getDB(moduleKey)
    if not db or not db.customGroups then return end

    -- 懒初始化：首次分类进组时容器可能未建好
    for groupIdx in pairs(groupBuckets) do
        local g = db.customGroups[groupIdx]
        if g and g.config and not groupContainers[groupIdx] then
            initContainersFn()
            break
        end
    end

    for groupIdx, allIcons in pairs(groupBuckets) do
        local group = db.customGroups[groupIdx]
        local container = groupContainers[groupIdx]

        if group and group.config and container then
        local cfg = group.config
        local icons = {}
        local hiddenIcons = {}

        if cfg.dynamicLayout then
            for _, icon in ipairs(allIcons) do
                if icon:IsShown() and icon.Icon and icon.Icon:GetTexture() then
                    icons[#icons + 1] = icon
                else
                    hiddenIcons[#hiddenIcons + 1] = icon
                end
            end
        else
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
                if type(scale) == "number" and scale > 0 then iconScale = scale end
            end

            -- 应用样式
            for _, icon in ipairs(icons) do
                FD(icon).cdmKind = "buff"
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
                if cfg.dynamicLayout then
                    local totalW = count * w + (count - 1) * spacingX
                    container:SetSize(totalW * iconScale, h * iconScale)
                    local x = cfg.x or 0
                    local y = cfg.y or (-260 - (groupIdx - 1) * 60)
                    container:ClearAllPoints()

                    if growDir == "center" then
                        container:SetPoint("CENTER", UIParent, "CENTER", x, y)
                        local startX = -(totalW / 2) + w / 2
                        for i, icon in ipairs(icons) do
                            local oX = startX + (i - 1) * (w + spacingX)
                            icon:ClearAllPoints()
                            icon:SetPoint("CENTER", container, "CENTER", oX, 0)
                            icon:SetSize(w, h)
                        end
                    elseif growDir == "start" then
                        container:SetPoint("LEFT", UIParent, "CENTER", x, y)
                        for i, icon in ipairs(icons) do
                            local oX = (i - 1) * (w + spacingX) + w / 2
                            icon:ClearAllPoints()
                            icon:SetPoint("LEFT", container, "LEFT", oX - w / 2, 0)
                            icon:SetSize(w, h)
                        end
                    elseif growDir == "end" then
                        container:SetPoint("RIGHT", UIParent, "CENTER", x, y)
                        for i, icon in ipairs(icons) do
                            local oX = -((i - 1) * (w + spacingX) + w / 2)
                            icon:ClearAllPoints()
                            icon:SetPoint("RIGHT", container, "RIGHT", oX + w / 2, 0)
                            icon:SetSize(w, h)
                        end
                    end

                    for _, icon in ipairs(hiddenIcons) do
                        icon:SetAlpha(0)
                    end
                else
                    local totalW = count * w + (count - 1) * spacingX
                    local startX = -(totalW / 2) + w / 2
                    container:SetSize(totalW * iconScale, h * iconScale)

                    for i, icon in ipairs(icons) do
                        local x = startX + (i - 1) * (w + spacingX)
                        icon:ClearAllPoints()
                        icon:SetPoint("CENTER", container, "CENTER", x, 0)
                        icon:SetSize(w, h)
                        if icon:IsShown() and icon.Icon and icon.Icon:GetTexture() then
                            icon:SetAlpha(1)
                        else
                            icon:SetAlpha(0)
                        end
                    end
                end
            else
                if cfg.dynamicLayout then
                    local totalH = count * h + (count - 1) * spacingY
                    container:SetSize(w * iconScale, totalH * iconScale)
                    local x = cfg.x or 0
                    local y = cfg.y or (-260 - (groupIdx - 1) * 60)
                    container:ClearAllPoints()

                    if growDir == "center" then
                        container:SetPoint("CENTER", UIParent, "CENTER", x, y)
                        local startY = (totalH / 2) - h / 2
                        for i, icon in ipairs(icons) do
                            local oY = startY - (i - 1) * (h + spacingY)
                            icon:ClearAllPoints()
                            icon:SetPoint("CENTER", container, "CENTER", 0, oY)
                            icon:SetSize(w, h)
                        end
                    elseif growDir == "start" then
                        container:SetPoint("TOP", UIParent, "CENTER", x, y)
                        for i, icon in ipairs(icons) do
                            local oY = -((i - 1) * (h + spacingY) + h / 2)
                            icon:ClearAllPoints()
                            icon:SetPoint("TOP", container, "TOP", 0, oY + h / 2)
                            icon:SetSize(w, h)
                        end
                    elseif growDir == "end" then
                        container:SetPoint("BOTTOM", UIParent, "CENTER", x, y)
                        for i, icon in ipairs(icons) do
                            local oY = (i - 1) * (h + spacingY) + h / 2
                            icon:ClearAllPoints()
                            icon:SetPoint("BOTTOM", container, "BOTTOM", 0, oY - h / 2)
                            icon:SetSize(w, h)
                        end
                    end

                    for _, icon in ipairs(hiddenIcons) do
                        icon:SetAlpha(0)
                    end
                else
                    local totalH = count * h + (count - 1) * spacingY
                    local startY = (totalH / 2) - h / 2
                    container:SetSize(w * iconScale, totalH * iconScale)

                    for i, icon in ipairs(icons) do
                        local y = startY - (i - 1) * (h + spacingY)
                        icon:ClearAllPoints()
                        icon:SetPoint("CENTER", container, "CENTER", 0, y)
                        icon:SetSize(w, h)
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
-- SECTION 5: 工厂 — TrackerGroup.Create
-- =========================================================

--[[
config 字段：
  moduleKey         : string  — "VFlow.Skills" / "VFlow.Buffs"
  hideConfigKey     : string  — "skills" / "buffs"（CustomMonitor DB 中的键）
  framePrefix       : string  — 容器帧名前缀
  menuKeyPrefix     : string  — DragFrame menuKey 前缀
  defaultLabel      : string  — DragFrame 标签缺省文本
  cdmKind           : string  — "skill" / "buff"
  eventOwner        : string  — 事件/监听标识
  layoutMode        : string  — "grid" / "dynamic"
  showOnRestore     : bool    — 分类时对非隐藏图标是否调用 Show()
  visibilityKey     : string? — 非 nil 则注册 VisibilityControl
  getGroupIdxForIcon: fn(icon, spellMap) → groupIdx|nil
  getDragOptions    : fn(groupIdx, group, db) → extra options table | nil
  onStoreChange     : fn(tracker, key, value)
  onInit            : fn(tracker)
]]

function TrackerGroup.Create(config)
    local moduleKey = config.moduleKey
    local tracker = {}

    -- 闭包状态
    local _groupSpellMap = {}
    local _groupContainers = {}
    local _spellMapDirty = true

    -- ----- SpellMap -----

    local function RebuildSpellMap()
        if not _spellMapDirty then return _groupSpellMap end
        _spellMapDirty = false
        wipe(_groupSpellMap)

        local db = VFlow.getDB(moduleKey)
        if not db or not db.customGroups then return _groupSpellMap end

        for groupIdx, group in ipairs(db.customGroups) do
            if group.config then
                if not group.config.spellIDs then
                    group.config.spellIDs = {}
                end
                for spellID in pairs(group.config.spellIDs) do
                    _groupSpellMap[spellID] = groupIdx
                    if C_Spell and C_Spell.GetBaseSpell then
                        local baseID = C_Spell.GetBaseSpell(spellID)
                        if baseID and baseID ~= spellID then
                            _groupSpellMap[baseID] = _groupSpellMap[baseID] or groupIdx
                        end
                    end
                end
            end
        end

        -- 隐藏列表（映射到 -1）
        local customMonitorDB = VFlow.Store.getModuleRef and VFlow.Store.getModuleRef("VFlow.CustomMonitor")
        local hideConfig = customMonitorDB and customMonitorDB[config.hideConfigKey]
        if hideConfig then
            for spellID, cfg in pairs(hideConfig) do
                if cfg.hideInCooldownManager then
                    _groupSpellMap[spellID] = -1
                end
            end
        end

        return _groupSpellMap
    end

    -- ----- ClassifyIcons -----

    local function ClassifyIcons(allIcons)
        local spellMap = RebuildSpellMap()

        if not next(spellMap) then
            local n = #allIcons
            local mainVisible = {}
            for i = 1, n do mainVisible[i] = allIcons[i] end
            return mainVisible, {}
        end

        local mainVisible = {}
        local groupBuckets = {}
        local getIdx = config.getGroupIdxForIcon
        local showOnRestore = config.showOnRestore

        for _, icon in ipairs(allIcons) do
            local groupIdx = getIdx(icon, spellMap)

            if groupIdx == -1 then
                if icon.Hide then icon:Hide() end
                if icon.SetAlpha then icon:SetAlpha(0) end
            elseif groupIdx then
                if showOnRestore then
                    if icon.Show and not icon:IsShown() then icon:Show() end
                end
                if icon.SetAlpha and icon:GetAlpha() < 0.1 then icon:SetAlpha(1) end
                groupBuckets[groupIdx] = groupBuckets[groupIdx] or {}
                table.insert(groupBuckets[groupIdx], icon)
            else
                if showOnRestore then
                    if icon.Show and not icon:IsShown() then icon:Show() end
                end
                if icon.SetAlpha and icon:GetAlpha() < 0.1 then icon:SetAlpha(1) end
                table.insert(mainVisible, icon)
            end
        end

        return mainVisible, groupBuckets
    end

    -- ----- 容器管理 -----

    local function CreateSingleContainer(groupIdx)
        local db = VFlow.getDB(moduleKey)
        if not db or not db.customGroups then return nil end
        local group = db.customGroups[groupIdx]
        if not group or not group.config then return nil end

        local container = CreateFrame("Frame", config.framePrefix .. groupIdx, UIParent)
        container:SetFrameStrata("MEDIUM")
        container:SetFrameLevel(10)
        container:SetSize(200, 50)
        container:SetMovable(true)
        container:SetClampedToScreen(true)

        VFlow.ContainerAnchor.ApplyFramePosition(container, group.config, nil)

        local dragOpts = {
            label = group.name or ((VFlow.L and VFlow.L[config.defaultLabel] or config.defaultLabel) .. groupIdx),
            menuKey = config.menuKeyPrefix .. groupIdx,
            getAnchorConfig = function() return group.config end,
        }

        -- 合并模块专有 DragFrame 选项
        if config.getDragOptions then
            local extras = config.getDragOptions(groupIdx, group, db)
            if extras then
                for k, v in pairs(extras) do dragOpts[k] = v end
            end
        end

        VFlow.DragFrame.register(container, dragOpts)

        if VFlow.DragFrame.applyRegisteredPosition then
            VFlow.DragFrame.applyRegisteredPosition(container)
        end

        if config.visibilityKey and VFlow.VisibilityControl and VFlow.VisibilityControl.RegisterFrame then
            VFlow.VisibilityControl.RegisterFrame(container, config.visibilityKey)
        end

        _groupContainers[groupIdx] = container
        return container
    end

    local function EnsureContainer(groupIdx)
        if _groupContainers[groupIdx] then return _groupContainers[groupIdx] end
        return CreateSingleContainer(groupIdx)
    end

    local function ReleaseContainer(groupIdx)
        local container = _groupContainers[groupIdx]
        if not container then return end
        VFlow.DragFrame.unregister(container)
        if config.visibilityKey and VFlow.VisibilityControl and VFlow.VisibilityControl.UnregisterFrame then
            VFlow.VisibilityControl.UnregisterFrame(container)
        end
        container:Hide()
        container:SetParent(nil)
        _groupContainers[groupIdx] = nil
    end

    -- 同步式：保留已有、清理失效、补建缺失（Skills 用）
    local function SyncContainers()
        local db = VFlow.getDB(moduleKey)
        local groups = db and db.customGroups

        for idx in pairs(_groupContainers) do
            if not (groups and groups[idx] and groups[idx].config) then
                ReleaseContainer(idx)
            end
        end
        if not groups then return end
        for i, group in ipairs(groups) do
            if group and group.config then EnsureContainer(i) end
        end
    end

    -- 批量重建式：全部销毁后重建（Buffs 用）
    local function ReinitContainers()
        for i in pairs(_groupContainers) do
            ReleaseContainer(i)
        end

        local db = VFlow.getDB(moduleKey)
        local groups = db and db.customGroups
        if not groups then return end

        for i, group in ipairs(groups) do
            if group and group.config then
                CreateSingleContainer(i)
            end
        end

        if config.visibilityKey and VFlow.VisibilityControl and VFlow.VisibilityControl.EvaluateAll then
            VFlow.VisibilityControl.EvaluateAll()
        end
    end

    local function ApplyGroupAnchor(groupIdx)
        local container = EnsureContainer(groupIdx)
        local db = VFlow.getDB(moduleKey)
        local group = db and db.customGroups and db.customGroups[groupIdx]
        local cfg = group and group.config
        if not (container and cfg) then return end
        if VFlow.DragFrame and VFlow.DragFrame.applyRegisteredPosition then
            VFlow.DragFrame.applyRegisteredPosition(container)
        else
            VFlow.ContainerAnchor.ApplyFramePosition(container, cfg, nil)
        end
    end

    -- ----- Layout -----

    local function LayoutGroups(groupBuckets)
        if config.layoutMode == "grid" then
            LayoutGrid(groupBuckets, moduleKey, _groupContainers, EnsureContainer)
        else
            LayoutDynamic(groupBuckets, moduleKey, _groupContainers, ReinitContainers)
        end
    end

    -- ----- ForEachGroupIcon -----

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

    -- ----- 公共 API -----

    tracker.classifyIcons = ClassifyIcons
    tracker.forEachGroupIcon = ForEachGroupIcon
    tracker.buildGroupSpellMap = RebuildSpellMap
    tracker.resolveGroupIndexForIcon = config.getGroupIdxForIcon
    tracker.syncContainers = SyncContainers
    tracker.reinitContainers = ReinitContainers
    tracker.applyGroupAnchor = ApplyGroupAnchor
    tracker.layoutGroups = LayoutGroups
    tracker.getContainer = function(idx) return _groupContainers[idx] end
    tracker.markDirty = function() _spellMapDirty = true end

    -- ----- 事件与 Store 监听 -----

    VFlow.on("PLAYER_ENTERING_WORLD", config.eventOwner, function()
        if config.onInit then
            config.onInit(tracker)
        else
            _spellMapDirty = true
        end
    end)

    VFlow.Store.watch(moduleKey, config.eventOwner, function(key, value)
        if config.onStoreChange then
            config.onStoreChange(tracker, key, value)
        else
            _spellMapDirty = true
        end
    end)

    return tracker
end
