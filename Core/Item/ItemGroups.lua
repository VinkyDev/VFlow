-- =========================================================
-- SECTION 1: 模块入口
-- ItemGroups — 物品 / 饰品 / 种族技能分组（数据层 + 容器管理 + 事件）
-- =========================================================

local VFlow = _G.VFlow
if not VFlow then return end

local MODULE_KEY = "VFlow.Items"
local ModuleControlConstants = VFlow.ModuleControlConstants

if not ModuleControlConstants.ITEMS_ENABLED then return end

-- =========================================================
-- SECTION 2: 共享状态与刷新调度
-- =========================================================

local FD = VFlow.FD
local EssentialCooldownViewer = _G.EssentialCooldownViewer
local UtilityCooldownViewer = _G.UtilityCooldownViewer

local _spellToGroupId = {}
local _mapDirty = true
local _containers = {} -- [0] 主组, [n] 自定义

-- 帧列表对外共享：ItemLayout 需要直接操作
local _standaloneFrameLists = {} -- [groupId] = { [1]=frame, ... }
local _appendFrameLists = {} -- [viewerName][groupId] = { frames }

local _standaloneRefreshPending = false

local _standaloneRefreshFrame = CreateFrame("Frame")
_standaloneRefreshFrame:Hide()
_standaloneRefreshFrame:SetScript("OnUpdate", function(self)
    self:Hide()
    if _standaloneRefreshPending then
        _standaloneRefreshPending = false
        -- 布局函数由 ItemLayout 注入
        local IG = VFlow.ItemGroups
        if IG.refreshAllAppendCooldowns then IG.refreshAllAppendCooldowns() end
        if IG.refreshStandaloneLayouts then IG.refreshStandaloneLayouts() end
    end
end)

local function ScheduleStandaloneRefresh()
    _standaloneRefreshPending = true
    _standaloneRefreshFrame:Show()
end

local function MarkMapDirty()
    _mapDirty = true
end

-- =========================================================
-- SECTION 3: 显示条件
-- =========================================================

local function IsHiddenForSystemEditOnly(cfg)
    if not cfg or not cfg.hideInSystemEditMode then return false end
    local sys = VFlow.State.systemEditMode or false
    local internal = VFlow.State.internalEditMode or false
    return sys and not internal
end

local function ShouldShowItemGroup(cfg)
    if not cfg or cfg.enabled == false then return false end
    local mode = cfg.visibilityMode or "hide"
    local conditionMet = false
    if cfg.hideInCombat and VFlow.State.get("inCombat") then
        conditionMet = true
    end
    if cfg.hideOnMount and VFlow.State.get("isMounted") then
        conditionMet = true
    end
    if cfg.hideOnSkyriding and VFlow.State.get("isSkyriding") then
        conditionMet = true
    end
    if cfg.hideInSpecial and (VFlow.State.get("inVehicle") or VFlow.State.get("inPetBattle")) then
        conditionMet = true
    end
    if cfg.hideNoTarget and not VFlow.State.get("hasTarget") then
        conditionMet = true
    end
    local visible
    if mode == "show" then
        visible = conditionMet
    else
        visible = not conditionMet
    end
    if not visible then return false end
    if IsHiddenForSystemEditOnly(cfg) then return false end
    return true
end

local function ScheduleVisibilityDrivenRefresh()
    if VFlow.RefreshBus and VFlow.RefreshBus.requestAllSkillViewers then
        VFlow.RefreshBus.requestPreset("SKILL_LAYOUT")
    elseif VFlow.RequestSkillRefresh then
        VFlow.RequestSkillRefresh(VFlow.RefreshBus.PRESETS.SKILL_LAYOUT)
    end
    ScheduleStandaloneRefresh()
end

-- =========================================================
-- SECTION 4: SpellMap — 法术 → 组映射
-- =========================================================

local function ResolveManualItemForTracking(configItemID)
    local IAD = VFlow.ItemAutoData
    if IAD and IAD.resolveManualInventoryItem then
        return IAD.resolveManualInventoryItem(configItemID)
    end
    if not configItemID or configItemID <= 0 then return configItemID, nil end
    C_Item.RequestLoadItemDataByID(configItemID)
    local _, sid = C_Item.GetItemSpell(configItemID)
    return configItemID, sid
end

local function TryAddSpellToGroup(spellID, groupId)
    if type(spellID) ~= "number" or spellID <= 0 or type(groupId) ~= "number" then return end
    if _spellToGroupId[spellID] then return end
    _spellToGroupId[spellID] = groupId
    if C_Spell and C_Spell.GetBaseSpell then
        local baseID = C_Spell.GetBaseSpell(spellID)
        if baseID and baseID ~= spellID and baseID > 0 and not _spellToGroupId[baseID] then
            _spellToGroupId[baseID] = groupId
        end
    end
end

local function RegisterConfigSpells(cfg, groupId)
    if not cfg or cfg.enabled == false then return end

    for sid in pairs(cfg.spellIDs or {}) do
        TryAddSpellToGroup(sid, groupId)
    end

    for iid in pairs(cfg.itemIDs or {}) do
        local _, spellID = ResolveManualItemForTracking(iid)
        if spellID and spellID > 0 then
            TryAddSpellToGroup(spellID, groupId)
        end
    end

    local ItemAutoData = VFlow.ItemAutoData
    if cfg.autoTrinkets and ItemAutoData and ItemAutoData.forEachOnUseTrinketSlot then
        ItemAutoData.forEachOnUseTrinketSlot(function(_, _, spellID)
            TryAddSpellToGroup(spellID, groupId)
        end)
    end

    if cfg.autoRacialAbility and ItemAutoData and ItemAutoData.collectRacialSpellIDs then
        for _, spellID in ipairs(ItemAutoData.collectRacialSpellIDs()) do
            TryAddSpellToGroup(spellID, groupId)
        end
    end
end

local function RebuildSpellMap()
    if not _mapDirty then return _spellToGroupId end
    _mapDirty = false

    wipe(_spellToGroupId)

    local db = VFlow.getDBIfReady(MODULE_KEY)
    if not db then return _spellToGroupId end

    if db.mainGroup then
        RegisterConfigSpells(db.mainGroup, 0)
    end

    for idx, group in ipairs(db.customGroups or {}) do
        if group and group.config then
            RegisterConfigSpells(group.config, idx)
        end
    end

    return _spellToGroupId
end

-- =========================================================
-- SECTION 5: 分组归类
-- =========================================================

local function GetGroupIdForIcon(icon, spellMap)
    local candidates = {}

    if icon.GetSpellID then
        local id = icon:GetSpellID()
        if id and not issecretvalue(id) and type(id) == "number" and id > 0 then
            candidates[#candidates + 1] = id
        end
    end

    if icon.cooldownID and VFlow.StyleLayout and VFlow.StyleLayout.GetCachedCooldownViewerInfo then
        local info = VFlow.StyleLayout.GetCachedCooldownViewerInfo(icon)
        if info then
            local spellID = info.linkedSpellIDs and info.linkedSpellIDs[1]
            spellID = spellID or info.overrideSpellID or info.spellID
            if spellID and spellID > 0 then
                candidates[#candidates + 1] = spellID
            end
        end
    end

    for _, spellID in ipairs(candidates) do
        local gid = spellMap[spellID]
        if gid ~= nil then return gid end

        if C_Spell and C_Spell.GetBaseSpell then
            local baseID = C_Spell.GetBaseSpell(spellID)
            if baseID and baseID ~= spellID then
                gid = spellMap[baseID]
                if gid ~= nil then return gid end
            end
        end
    end

    return nil
end

-- =========================================================
-- SECTION 6: 配置访问与显示模式
-- =========================================================

local function GetConfigForGroupId(groupId)
    local db = VFlow.getDBIfReady(MODULE_KEY)
    if not db then return nil end
    if groupId == 0 then return db.mainGroup end
    local g = db.customGroups and db.customGroups[groupId]
    return g and g.config
end

local function GetGroupLabel(groupId)
    if groupId == 0 then
        local db = VFlow.getDBIfReady(MODULE_KEY)
        return (db and db.mainGroup and db.mainGroup.groupName) or (VFlow.L and VFlow.L["Main Group"] or "Main Group")
    end
    local db = VFlow.getDBIfReady(MODULE_KEY)
    local g = db and db.customGroups and db.customGroups[groupId]
    return (g and g.name) or ((VFlow.L and VFlow.L["Item group"] or "Item group") .. groupId)
end

local function ShouldStandaloneExtract(cfg)
    return cfg and cfg.enabled ~= false and cfg.displayMode == "standalone"
end

local function ShouldAppendToViewer(cfg, viewer)
    if not cfg or cfg.enabled == false then return false end
    if viewer == EssentialCooldownViewer and cfg.displayMode == "append_important" then return true end
    if viewer == UtilityCooldownViewer and cfg.displayMode == "append_efficiency" then return true end
    return false
end

local function ViewerCacheKey(viewer)
    if viewer and viewer.GetName then
        return viewer:GetName() or "?"
    end
    return "?"
end

-- =========================================================
-- SECTION 7: ProcessSkillViewerIcons — Viewer 过滤
-- =========================================================

--- 在 SkillGroups 之后：单独分组 / 追加模式均在 viewer 中隐藏暴雪按钮，由自建帧展示
local function ProcessSkillViewerIcons(viewer, mainVisible)
    local spellMap = RebuildSpellMap()
    local newMain = {}

    for _, icon in ipairs(mainVisible) do
        local gid = GetGroupIdForIcon(icon, spellMap)
        local cfg = gid ~= nil and GetConfigForGroupId(gid)
        local hideStandalone = gid ~= nil and cfg and ShouldStandaloneExtract(cfg)
        local hideAppend = gid ~= nil and cfg and ShouldAppendToViewer(cfg, viewer)

        local hideInCDM = cfg and cfg.hideInCooldownManager
        if hideStandalone or hideAppend or hideInCDM then
            local fd = FD(icon)
            if hideStandalone then
                fd.itemStandaloneHidden = true
            end
            if hideAppend then
                fd.itemAppendHidden = true
            end
            if hideInCDM then
                fd.itemHideInCDM = true
            end
            if icon.Hide then icon:Hide() end
            if icon.SetAlpha then icon:SetAlpha(0) end
        else
            local fd = FD(icon)
            if fd.itemStandaloneHidden then
                fd.itemStandaloneHidden = nil
                if icon.Show then icon:Show() end
                if icon.SetAlpha then icon:SetAlpha(1) end
            end
            if fd.itemAppendHidden then
                fd.itemAppendHidden = nil
                if icon.Show then icon:Show() end
                if icon.SetAlpha then icon:SetAlpha(1) end
            end
            if fd.itemHideInCDM then
                fd.itemHideInCDM = nil
                if icon.Show then icon:Show() end
                if icon.SetAlpha then icon:SetAlpha(1) end
            end
            table.insert(newMain, icon)
        end
    end

    return newMain, {}
end

-- =========================================================
-- SECTION 8: 容器管理（CRUD）
-- =========================================================

local function NeedsStandaloneContainer(cfg)
    return ShouldStandaloneExtract(cfg)
end

local function ApplyContainerAnchor(container, cfg)
    if not container or not cfg then return end
    VFlow.ContainerAnchor.ApplyFramePosition(container, cfg, nil)
end

local function ReleaseGroupContainer(groupId)
    local list = _standaloneFrameLists[groupId]
    if list then
        for _, f in ipairs(list) do
            f:SetParent(nil)
            f:Hide()
        end
        wipe(list)
    end
    _standaloneFrameLists[groupId] = nil

    local container = _containers[groupId]
    if not container then return end
    VFlow.DragFrame.unregister(container)
    container:Hide()
    container:SetParent(nil)
    _containers[groupId] = nil
end

local function EnsureGroupContainer(groupId)
    if _containers[groupId] then
        return _containers[groupId]
    end

    local cfg = GetConfigForGroupId(groupId)
    if not cfg or not NeedsStandaloneContainer(cfg) then return nil end

    local container = CreateFrame("Frame", "VFlow_ItemGroup_" .. groupId, UIParent)
    container:SetFrameStrata("MEDIUM")
    container:SetFrameLevel(10)
    container:SetSize(200, 50)
    container:SetMovable(true)
    container:SetClampedToScreen(true)

    ApplyContainerAnchor(container, cfg)

    local pathPrefix = groupId == 0 and "mainGroup" or ("customGroups." .. groupId .. ".config")
    local label = GetGroupLabel(groupId)

    VFlow.DragFrame.register(container, {
        label = label,
        menuKey = groupId == 0 and "item_monitor" or ("item_custom_" .. groupId),
        getAnchorConfig = function()
            return GetConfigForGroupId(groupId)
        end,
        onPositionChanged = function(_, kind, a, b)
            if kind ~= "PLAYER_ANCHOR" and kind ~= "SYMMETRIC" then return end
            local c = GetConfigForGroupId(groupId)
            if not c then return end
            c.x, c.y = a, b
            VFlow.Store.set(MODULE_KEY, pathPrefix .. ".x", a)
            VFlow.Store.set(MODULE_KEY, pathPrefix .. ".y", b)
        end,
    })

    if VFlow.DragFrame.applyRegisteredPosition then
        VFlow.DragFrame.applyRegisteredPosition(container)
    end

    _containers[groupId] = container
    return container
end

local function ApplyGroupAnchor(groupId)
    local cfg = GetConfigForGroupId(groupId)
    local container = EnsureGroupContainer(groupId)
    if not (cfg and container) then
        return
    end
    ApplyContainerAnchor(container, cfg)
    if VFlow.DragFrame and VFlow.DragFrame.applyRegisteredPosition then
        VFlow.DragFrame.applyRegisteredPosition(container)
    end
end

local function InitGroupContainers()
    local db = VFlow.getDBIfReady(MODULE_KEY)
    for gid in pairs(_containers) do
        ReleaseGroupContainer(gid)
    end
    if not db then
        return
    end

    if db.mainGroup and NeedsStandaloneContainer(db.mainGroup) then
        EnsureGroupContainer(0)
    end
    for i, group in ipairs(db.customGroups or {}) do
        if group and group.config and NeedsStandaloneContainer(group.config) then
            EnsureGroupContainer(i)
        end
    end
end

-- =========================================================
-- SECTION 9: 公开 API（布局函数由 ItemLayout 注入）
-- =========================================================

VFlow.ItemGroups = {
    -- 数据层
    processSkillViewerIcons = ProcessSkillViewerIcons,
    invalidateSpellMap = MarkMapDirty,
    buildSpellMap = RebuildSpellMap,
    resolveGroupIdForIcon = GetGroupIdForIcon,
    getConfigForGroupId = GetConfigForGroupId,
    shouldStandaloneExtract = ShouldStandaloneExtract,
    shouldAppendToViewer = ShouldAppendToViewer,
    applyGroupAnchor = ApplyGroupAnchor,

    -- 共享状态：ItemLayout 通过此表直接操作帧列表
    _standaloneFrameLists = _standaloneFrameLists,
    _appendFrameLists = _appendFrameLists,

    -- 内部函数：供 ItemLayout 调用
    _MODULE_KEY = MODULE_KEY,
    _shouldShowItemGroup = ShouldShowItemGroup,
    _ensureGroupContainer = EnsureGroupContainer,
    _applyContainerAnchor = ApplyContainerAnchor,
    _viewerCacheKey = ViewerCacheKey,
    _resolveManualItemForTracking = ResolveManualItemForTracking,
    _releaseGroupContainer = ReleaseGroupContainer,
}

-- =========================================================
-- SECTION 10: 事件注册
-- =========================================================

VFlow.on("PLAYER_ENTERING_WORLD", "ItemGroups", function()
    MarkMapDirty()
    VFlow.ContainerAnchor.InvalidatePlayerFrameCache()
    InitGroupContainers()
    for gid, c in pairs(_containers) do
        if c and VFlow.DragFrame and VFlow.DragFrame.applyRegisteredPosition then
            VFlow.DragFrame.applyRegisteredPosition(c)
        end
    end
    ScheduleStandaloneRefresh()
end)

VFlow.on("SPELL_UPDATE_COOLDOWNS", "ItemGroups", function()
    if VFlow.RefreshBus and VFlow.RefreshBus.request then
        VFlow.RefreshBus.request(VFlow.RefreshBus.SCOPES.SKILL_COOLDOWN, { allSkillViewers = true })
    else
        ScheduleStandaloneRefresh()
    end
end)

VFlow.on("UNIT_SPELLCAST_SUCCEEDED", "ItemGroups_ItemUse", function(_, unitTarget)
    if unitTarget ~= "player" then return end
    if VFlow.RefreshBus and VFlow.RefreshBus.request then
        VFlow.RefreshBus.request(VFlow.RefreshBus.SCOPES.SKILL_COOLDOWN, { allSkillViewers = true })
    else
        ScheduleStandaloneRefresh()
    end
end, "player")

VFlow.on("BAG_UPDATE_DELAYED", "ItemGroups_Bag", function()
    if VFlow.RefreshBus and VFlow.RefreshBus.request then
        VFlow.RefreshBus.request(VFlow.RefreshBus.SCOPES.SKILL_COOLDOWN, { allSkillViewers = true })
    else
        ScheduleStandaloneRefresh()
    end
end)

VFlow.State.watch("isEditMode", "ItemGroups_StandalonePreview", function()
    ScheduleStandaloneRefresh()
end)

do
    local visKeys = {
        "inCombat",
        "isMounted",
        "isSkyriding",
        "inVehicle",
        "inPetBattle",
        "hasTarget",
        "systemEditMode",
        "internalEditMode",
    }
    for _, k in ipairs(visKeys) do
        VFlow.State.watch(k, "ItemGroups_Vis", function()
            ScheduleVisibilityDrivenRefresh()
        end)
    end
end

VFlow.on("PLAYER_EQUIPMENT_CHANGED", "ItemGroups", function(_, slotID)
    if slotID ~= nil and slotID ~= 13 and slotID ~= 14 then return end
    local db = VFlow.getDBIfReady(MODULE_KEY)
    local needMap = db and db.mainGroup and db.mainGroup.autoTrinkets
    if not needMap and db and db.customGroups then
        for _, g in ipairs(db.customGroups) do
            if g.config and g.config.autoTrinkets then
                needMap = true
                break
            end
        end
    end
    if needMap then
        MarkMapDirty()
        if VFlow.RefreshBus and VFlow.RefreshBus.requestAllSkillViewers then
            VFlow.RefreshBus.requestPreset("SKILL_GROUP_MAP")
        elseif VFlow.RequestSkillRefresh then
            VFlow.RequestSkillRefresh(VFlow.RefreshBus.PRESETS.SKILL_GROUP_MAP)
        end
    end
    ScheduleStandaloneRefresh()
end)

VFlow.on("SPELLS_CHANGED", "ItemGroups", function()
    local db = VFlow.getDBIfReady(MODULE_KEY)
    local need = db and db.mainGroup and db.mainGroup.autoRacialAbility
    if not need and db and db.customGroups then
        for _, g in ipairs(db.customGroups) do
            if g.config and g.config.autoRacialAbility then
                need = true
                break
            end
        end
    end
    if need then
        MarkMapDirty()
        if VFlow.RefreshBus and VFlow.RefreshBus.requestAllSkillViewers then
            VFlow.RefreshBus.requestPreset("SKILL_GROUP_MAP")
        elseif VFlow.RequestSkillRefresh then
            VFlow.RequestSkillRefresh(VFlow.RefreshBus.PRESETS.SKILL_GROUP_MAP)
        end
        ScheduleStandaloneRefresh()
    end
end)

VFlow.Store.watch(MODULE_KEY, "ItemGroups", function(key, value)
    -- 仅坐标变化：只更新锚点，避免整组重建（与 SkillGroups 一致）
    local anchorFine = (key == "mainGroup.anchorFrame" or key == "mainGroup.relativePoint" or key == "mainGroup.playerAnchorPosition")
        or (key:match("^customGroups%.%d+%.config%.(anchorFrame|relativePoint|playerAnchorPosition)$") ~= nil)
    local xyOnly = (key == "mainGroup.x" or key == "mainGroup.y")
        or (key:match("^customGroups%.%d+%.config%.[xy]$") ~= nil)
        or anchorFine
    if xyOnly then
        if VFlow.RefreshBus and VFlow.RefreshBus.request then
            local gid
            if key:sub(1, 8) == "mainGroup" then
                gid = 0
            else
                gid = tonumber(key:match("^customGroups%.(%d+)%."))
            end
            VFlow.RefreshBus.request(VFlow.RefreshBus.SCOPES.SKILL_GROUP_LAYOUT, {
                allSkillViewers = true,
                groupIndex = gid,
                flags = { reanchorOnly = true },
            })
        else
            ScheduleStandaloneRefresh()
        end
        return
    end

    if key == "customGroups" or key == "mainGroup" or key:find("^customGroups%.%d+%.config")
        or key:find("^mainGroup%.") then
        if key == "customGroups" or key == "mainGroup" then
            -- 清理可能残留的孤立帧
            local IG = VFlow.ItemGroups
            if IG._pruneOrphanRuntime then IG._pruneOrphanRuntime() end
        end
        InitGroupContainers()
    end

    MarkMapDirty()
    ScheduleStandaloneRefresh()
    if VFlow.RefreshBus and VFlow.RefreshBus.requestAllSkillViewers then
        VFlow.RefreshBus.requestPreset("SKILL_FULL")
    elseif VFlow.RequestSkillRefresh then
        VFlow.RequestSkillRefresh(VFlow.RefreshBus.PRESETS.SKILL_FULL)
    end
end)
