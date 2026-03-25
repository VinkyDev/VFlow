-- =========================================================
-- SECTION 1: 模块入口
-- ItemGroups — 物品 / 饰品 / 种族技能分组（类比 SkillGroups）
-- =========================================================

local VFlow = _G.VFlow
if not VFlow then return end

local MODULE_KEY = "VFlow.Items"

-- =========================================================
-- SECTION 2: 模块状态与刷新调度
-- =========================================================

local Profiler = VFlow.Profiler
local MasqueSupport = VFlow.MasqueSupport
local EssentialCooldownViewer = _G.EssentialCooldownViewer
local UtilityCooldownViewer = _G.UtilityCooldownViewer

local _spellToGroupId = {}
local _mapDirty = true
local _containers = {} -- [0] 主组, [n] 自定义
-- 单独分组：自建图标（与 TrinketPotionMonitor 一致，不复用 CD Viewer 按钮）
local _standaloneFrameLists = {} -- [groupId] = { [1]=frame, ... }
-- 追加模式：父级为 Essential / Utility Viewer
local _appendFrameLists = {} -- [viewerName][groupId] = { frames }

local _standaloneRefreshPending = false
local RefreshAllStandaloneLayouts
local RefreshAllAppendCooldowns

local _standaloneRefreshFrame = CreateFrame("Frame")
_standaloneRefreshFrame:Hide()
_standaloneRefreshFrame:SetScript("OnUpdate", function(self)
    self:Hide()
    if _standaloneRefreshPending then
        local _pt = Profiler.start("IG:DeferredRefresh")
        _standaloneRefreshPending = false
        RefreshAllAppendCooldowns()
        if RefreshAllStandaloneLayouts then
            RefreshAllStandaloneLayouts()
        end
        Profiler.stop(_pt)
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
-- 显示条件
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
    ScheduleStandaloneRefresh()
    if VFlow.RequestCooldownStyleRefresh then
        VFlow.RequestCooldownStyleRefresh()
    end
end

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
    local _pt = Profiler.start("IG:RebuildSpellMap")
    if not _mapDirty then Profiler.stop(_pt) return _spellToGroupId end
    _mapDirty = false

    wipe(_spellToGroupId)

    local db = VFlow.getDBIfReady(MODULE_KEY)
    if not db then Profiler.stop(_pt) return _spellToGroupId end

    if db.mainGroup then
        RegisterConfigSpells(db.mainGroup, 0)
    end

    for idx, group in ipairs(db.customGroups or {}) do
        if group and group.config then
            RegisterConfigSpells(group.config, idx)
        end
    end

    Profiler.stop(_pt)
    return _spellToGroupId
end

local function GetGroupIdForIcon(icon, spellMap)
    local candidates = {}

    if icon.GetSpellID then
        local id = icon:GetSpellID()
        if id and not issecretvalue(id) and type(id) == "number" and id > 0 then
            candidates[#candidates + 1] = id
        end
    end

    if icon.cooldownID then
        local info = C_CooldownViewer.GetCooldownViewerCooldownInfo(icon.cooldownID)
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

--- 在 SkillGroups 之后：单独分组 / 追加模式均在 viewer 中隐藏暴雪按钮，由自建帧展示
local function ProcessSkillViewerIcons(viewer, mainVisible)
    local _pt = Profiler.start("IG:ProcessSkillViewerIcons")
    local spellMap = RebuildSpellMap()
    local newMain = {}

    for _, icon in ipairs(mainVisible) do
        local gid = GetGroupIdForIcon(icon, spellMap)
        local cfg = gid ~= nil and GetConfigForGroupId(gid)
        local hideStandalone = gid ~= nil and cfg and ShouldStandaloneExtract(cfg)
        local hideAppend = gid ~= nil and cfg and ShouldAppendToViewer(cfg, viewer)

        local hideInCDM = cfg and cfg.hideInCooldownManager
        if hideStandalone or hideAppend or hideInCDM then
            if hideStandalone then
                icon._vf_itemStandaloneHidden = true
            end
            if hideAppend then
                icon._vf_itemAppendHidden = true
            end
            if hideInCDM then
                icon._vf_itemHideInCDM = true
            end
            if icon.Hide then icon:Hide() end
            if icon.SetAlpha then icon:SetAlpha(0) end
        else
            if icon._vf_itemStandaloneHidden then
                icon._vf_itemStandaloneHidden = nil
                if icon.Show then icon:Show() end
                if icon.SetAlpha then icon:SetAlpha(1) end
            end
            if icon._vf_itemAppendHidden then
                icon._vf_itemAppendHidden = nil
                if icon.Show then icon:Show() end
                if icon.SetAlpha then icon:SetAlpha(1) end
            end
            if icon._vf_itemHideInCDM then
                icon._vf_itemHideInCDM = nil
                if icon.Show then icon:Show() end
                if icon.SetAlpha then icon:SetAlpha(1) end
            end
            table.insert(newMain, icon)
        end
    end

    Profiler.stop(_pt)
    return newMain, {}
end

local function NeedsStandaloneContainer(cfg)
    return ShouldStandaloneExtract(cfg)
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

local function ApplyContainerAnchor(container, cfg)
    if not container or not cfg then return end
    VFlow.ContainerAnchor.ApplyFramePosition(container, cfg, nil)
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

local function InitGroupContainers()
    local _pt = Profiler.start("IG:InitGroupContainers")
    local db = VFlow.getDBIfReady(MODULE_KEY)
    for gid in pairs(_containers) do
        ReleaseGroupContainer(gid)
    end
    if not db then
        Profiler.stop(_pt)
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
    Profiler.stop(_pt)
end

-- =========================================================
-- SECTION 3: 单独分组 — 自建图标与 StyleApply
-- （与 TrinketPotionMonitor 对齐，不复用 CD Viewer 按钮）
-- =========================================================

--- 物品组内监控条目（单独分组与追加模式共用）
local function BuildTrackedEntries(cfg)
    if not cfg or cfg.enabled == false then return {} end
    local _pt = Profiler.start("IG:BuildTrackedEntries")
    local seen = {}
    local entries = {}
    local function add(e)
        local sid = e.spellID
        if not sid or sid <= 0 then return end
        if seen[sid] then return end
        seen[sid] = true
        entries[#entries + 1] = e
    end

    local ItemsManualOrder = VFlow.ItemsManualOrder
    if ItemsManualOrder and ItemsManualOrder.Ensure then
        ItemsManualOrder.Ensure(cfg)
    end

    local order = cfg.entryOrder
    if order and #order > 0 then
        for _, e in ipairs(order) do
            if e.t == "trinket_slot" and cfg.autoTrinkets and (e.slot == 13 or e.slot == 14) then
                local itemID = GetInventoryItemID("player", e.slot)
                if itemID and itemID > 0 then
                    C_Item.RequestLoadItemDataByID(itemID)
                    local _, sid = C_Item.GetItemSpell(itemID)
                    if sid and sid > 0 then
                        add({ kind = "trinket_slot", slot = e.slot, itemID = itemID, spellID = sid })
                    end
                end
            elseif e.t == "racial" and cfg.autoRacialAbility and type(e.id) == "number" then
                add({ kind = "spell", spellID = e.id })
            elseif e.t == "item" and cfg.itemIDs and cfg.itemIDs[e.id] then
                local rid, sid = ResolveManualItemForTracking(e.id)
                if sid and sid > 0 then
                    add({ kind = "item_inventory", itemID = rid, spellID = sid })
                end
            elseif e.t == "spell" and cfg.spellIDs and cfg.spellIDs[e.id] then
                add({ kind = "spell", spellID = e.id })
            end
        end
    else
        local ItemAutoData = VFlow.ItemAutoData
        if cfg.autoTrinkets and ItemAutoData and ItemAutoData.forEachOnUseTrinketSlot then
            ItemAutoData.forEachOnUseTrinketSlot(function(slot, itemID, spellID)
                add({ kind = "trinket_slot", slot = slot, itemID = itemID, spellID = spellID })
            end)
        end
        if cfg.autoRacialAbility and ItemAutoData and ItemAutoData.collectRacialSpellIDs then
            for _, spellID in ipairs(ItemAutoData.collectRacialSpellIDs()) do
                add({ kind = "spell", spellID = spellID })
            end
        end
        local itemList = {}
        for iid in pairs(cfg.itemIDs or {}) do itemList[#itemList + 1] = iid end
        table.sort(itemList)
        for _, iid in ipairs(itemList) do
            local rid, sid = ResolveManualItemForTracking(iid)
            if sid and sid > 0 then
                add({ kind = "item_inventory", itemID = rid, spellID = sid })
            end
        end
        local spellList = {}
        for sid in pairs(cfg.spellIDs or {}) do spellList[#spellList + 1] = sid end
        table.sort(spellList)
        for _, sid in ipairs(spellList) do
            add({ kind = "spell", spellID = sid })
        end
    end

    Profiler.stop(_pt)
    return entries
end

local function BuildStandaloneEntries(cfg)
    if not ShouldStandaloneExtract(cfg) then return {} end
    if not ShouldShowItemGroup(cfg) then return {} end
    return BuildTrackedEntries(cfg)
end

local function BuildAppendEntries(cfg)
    if not cfg or cfg.enabled == false then return {} end
    if cfg.displayMode ~= "append_important" and cfg.displayMode ~= "append_efficiency" then return {} end
    if not ShouldShowItemGroup(cfg) then return {} end
    return BuildTrackedEntries(cfg)
end

--- 手动物品：背包数量 0；饰品槽：栏位未装备
local function ItemEntryIsUnavailable(entry)
    if not entry then return false end
    if entry.kind == "item_inventory" then
        return (C_Item.GetItemCount(entry.itemID, false, true) or 0) <= 0
    end
    if entry.kind == "trinket_slot" then
        local id = GetInventoryItemID("player", entry.slot)
        return not id or id <= 0
    end
    return false
end

--- 隐藏模式下不可用的物品不参与布局占位（单独分组 / 追加条）
local function ShouldIncludeItemCellInLayout(entry, cfg)
    if not ItemEntryIsUnavailable(entry) then return true end
    if not entry or (entry.kind ~= "trinket_slot" and entry.kind ~= "item_inventory") then return true end
    return ((cfg and cfg.itemZeroCountBehavior) or "gray") ~= "hide"
end

local function AppendVisibleEntryCount(cfg, viewer)
    if not cfg or not ShouldAppendToViewer(cfg, viewer) then return 0 end
    local n = 0
    for _, e in ipairs(BuildAppendEntries(cfg)) do
        if ShouldIncludeItemCellInLayout(e, cfg) then
            n = n + 1
        end
    end
    return n
end

local function ViewerHasAppendEntries(viewer)
    local db = VFlow.getDBIfReady(MODULE_KEY)
    if not db then return false end
    if db.mainGroup and AppendVisibleEntryCount(db.mainGroup, viewer) > 0 then
        return true
    end
    for _, g in ipairs(db.customGroups or {}) do
        if g.config and AppendVisibleEntryCount(g.config, viewer) > 0 then
            return true
        end
    end
    return false
end

local GCD_SPELL_ID = 61304
local CD_MIN_DISPLAY = 1.5
local GetItemCooldownFn = C_Container and C_Container.GetItemCooldown
local Utils = VFlow.Utils

-- 前向引用：OnCooldownDone 里需同步灰度/swipe（CD 自然结束时未必触发 SPELL_UPDATE_COOLDOWNS）
local ApplyEntryCooldown

local function ApplyItemZeroCountPresentation(frame, entry, cfg)
    if not frame then return end
    local mode = (cfg and cfg.itemZeroCountBehavior) or "gray"
    if not entry or (entry.kind ~= "trinket_slot" and entry.kind ~= "item_inventory") then
        frame:Show()
        return
    end
    local bad = ItemEntryIsUnavailable(entry)
    local icon = frame.Icon
    local cd = frame.Cooldown
    if not bad then
        frame:Show()
        return
    end
    if cd then cd:Clear() end
    if mode == "hide" then
        frame:Hide()
        if icon and icon.SetDesaturation then icon:SetDesaturation(0) end
        return
    end
    frame:Show()
    if icon and icon.SetDesaturation then icon:SetDesaturation(1) end
end

local function CreateStandaloneIconFrame(container)
    local frame = CreateFrame("Frame", nil, container)
    frame:SetSize(36, 36)

    local icon = frame:CreateTexture(nil, "ARTWORK")
    icon:SetAllPoints()
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    local cooldown = CreateFrame("Cooldown", nil, frame, "CooldownFrameTemplate")
    cooldown:SetAllPoints()
    cooldown:SetDrawEdge(false)
    if cooldown.SetDrawSwipe then cooldown:SetDrawSwipe(true) end
    if cooldown.SetDrawBling then cooldown:SetDrawBling(false) end

    frame.Icon = icon
    frame.Cooldown = cooldown

    if cooldown.HookScript then
        cooldown:HookScript("OnCooldownDone", function(self)
            local parent = self and self:GetParent()
            local entry = parent and parent._vf_entry
            if parent and entry and ApplyEntryCooldown then
                ApplyEntryCooldown(parent, entry)
                local gid = parent._vf_itemGroupId
                local icfg = gid ~= nil and GetConfigForGroupId(gid)
                ApplyItemZeroCountPresentation(parent, entry, icfg)
            end
        end)
    end

    -- 与 StyleApply.GetStackFontString 约定一致：物品堆叠数量
    -- 必须继承字体模板，否则 SetText（含空串）在 12.x 会报 Font not set
    local stackHolder = CreateFrame("Frame", nil, frame)
    stackHolder:SetAllPoints()
    stackHolder:SetFrameLevel(frame:GetFrameLevel() + 6)
    local stackFS = stackHolder:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
    stackFS:SetDrawLayer("OVERLAY", 7)
    stackHolder.Current = stackFS
    frame.ChargeCount = stackHolder

    -- 运行时图标不显示 GameTooltip，鼠标穿透
    frame:EnableMouse(false)

    frame:Hide()
    return frame
end

local function ApplyEntryTexture(frame, entry)
    if entry.kind == "trinket_slot" or entry.kind == "item_inventory" then
        local _, _, _, _, _, _, _, _, _, tex = C_Item.GetItemInfo(entry.itemID)
        frame.Icon:SetTexture(tex or 134400)
    else
        local si = C_Spell.GetSpellInfo(entry.spellID)
        frame.Icon:SetTexture((si and si.iconID) or 134400)
    end
end

--- 12.0+ 数值可能为 secret，禁止与常量直接比较
local function SafeNum(n)
    if n == nil then return nil end
    if type(n) ~= "number" then return nil end
    if issecretvalue and issecretvalue(n) then return nil end
    return n
end

local function HasMeaningfulItemCooldown(startTime, duration)
    local st = SafeNum(startTime)
    local dur = SafeNum(duration)
    return st and dur and dur >= CD_MIN_DISPLAY and st > 0
end

--- 物品 CD 是否值得画 swipe（普通数值走阈值；仅当起止时间含 secret 无法判定时才交给 Duration 分支）
local function ItemCooldownShouldDisplay(startTime, duration, enable)
    if enable ~= nil and enable ~= 1 and enable ~= true then
        return false
    end
    if startTime == nil or duration == nil then return false end
    if HasMeaningfulItemCooldown(startTime, duration) then return true end
    local st, dur = SafeNum(startTime), SafeNum(duration)
    if st ~= nil and dur ~= nil then
        return false
    end
    return C_DurationUtil ~= nil and C_DurationUtil.CreateDuration ~= nil
end

--- 图标灰度与 Cooldown 子帧绑定：遮罩由 SetCooldownFromDurationObject / Duration 对象驱动（对齐暴雪 12.0+ 安全模型）
local function SyncIconDesatFromCooldown(cd, iconTex)
    if not cd or not iconTex then return end
    local dim = false
    pcall(function()
        if not (cd.IsShown and cd:IsShown()) then
            return
        end
        if cd.GetCooldownDuration then
            local d = cd:GetCooldownDuration()
            if type(d) == "number" then
                if issecretvalue and issecretvalue(d) then
                    dim = true
                else
                    dim = d > 0
                end
                return
            end
        end
        dim = true
    end)
    iconTex:SetDesaturation(dim and 1 or 0)
end

--- 法术：仅负责 swipe（DurationObject + GCD 时清遮罩），灰度由 ApplyEntryCooldown 末尾 SyncIconDesatFromCooldown
local function ApplySpellCooldownSwipe(cd, spellID)
    cd:Clear()

    local gcdInfo
    pcall(function()
        gcdInfo = C_Spell.GetSpellCooldown(GCD_SPELL_ID)
    end)
    local gcdActive = false
    if gcdInfo then
        if gcdInfo.isActive ~= nil then
            gcdActive = gcdInfo.isActive == true
        else
            pcall(function()
                gcdActive = C_Spell.GetSpellCooldownDuration(GCD_SPELL_ID) ~= nil
            end)
        end
    end

    local cdInfo
    pcall(function()
        cdInfo = C_Spell.GetSpellCooldown(spellID)
    end)

    local chargeDurObj, spellDurObj
    pcall(function()
        chargeDurObj = C_Spell.GetSpellChargeDuration(spellID)
        spellDurObj = C_Spell.GetSpellCooldownDuration(spellID)
    end)

    local isOnGCD = false
    if gcdActive and spellDurObj then
        isOnGCD = cdInfo and cdInfo.isOnGCD == true
    end

    local spellCdActive = true
    if cdInfo and cdInfo.isActive ~= nil then
        spellCdActive = cdInfo.isActive == true
    end

    if not isOnGCD then
        local durObj = chargeDurObj or spellDurObj
        if durObj and spellCdActive and cd.SetCooldownFromDurationObject then
            pcall(function()
                cd:SetCooldownFromDurationObject(durObj, true)
            end)
        end
    end
end

local function TryApplyItemCooldownById(cd, hostFrame, itemID)
    if not GetItemCooldownFn or not itemID or not hostFrame then return false end
    local st, duration, en = GetItemCooldownFn(itemID)
    if not ItemCooldownShouldDisplay(st, duration, en) then return false end
    if Utils and Utils.setCooldownFromStartAndDuration(cd, hostFrame, st, duration) then
        return true
    end
    return false
end

ApplyEntryCooldown = function(frame, entry)
    local cd = frame.Cooldown
    local iconTex = frame.Icon
    if not cd or not iconTex then return end
    cd:Clear()

    if entry.kind == "trinket_slot" then
        local start, duration, en = GetInventoryItemCooldown("player", entry.slot)
        if ItemCooldownShouldDisplay(start, duration, en) then
            if not (Utils and Utils.setCooldownFromStartAndDuration(cd, frame, start, duration)) then
                TryApplyItemCooldownById(cd, frame, entry.itemID)
            end
        else
            TryApplyItemCooldownById(cd, frame, entry.itemID)
        end
    elseif entry.kind == "item_inventory" then
        if not TryApplyItemCooldownById(cd, frame, entry.itemID) then
            ApplySpellCooldownSwipe(cd, entry.spellID)
        end
    else
        ApplySpellCooldownSwipe(cd, entry.spellID)
    end

    SyncIconDesatFromCooldown(cd, iconTex)
end

local function UpdateItemStackDisplay(frame, entry, cfg)
    if not frame or not frame.ChargeCount or not frame.ChargeCount.Current then return end
    local fs = frame.ChargeCount.Current
    if not cfg or cfg.showItemCount == false then
        fs:SetText("")
        fs:Hide()
        return
    end
    if not entry or (entry.kind ~= "trinket_slot" and entry.kind ~= "item_inventory") then
        fs:SetText("")
        fs:Hide()
        return
    end
    local cnt = C_Item.GetItemCount(entry.itemID, false, true)
    if cnt and cnt > 1 then
        fs:SetText(tostring(cnt))
        fs:Show()
    else
        fs:SetText("")
        fs:Hide()
    end
end

--- 追加到技能条：堆叠数量显示逻辑（字体/位置由技能组的 ApplyButtonStyle 决定）
local function UpdateAppendItemStackDisplay(frame, entry)
    if not frame or not frame.ChargeCount or not frame.ChargeCount.Current then return end
    local fs = frame.ChargeCount.Current
    if not entry or (entry.kind ~= "trinket_slot" and entry.kind ~= "item_inventory") then
        fs:SetText("")
        fs:Hide()
        return
    end
    local cnt = C_Item.GetItemCount(entry.itemID, false, true)
    if cnt and cnt > 1 then
        fs:SetText(tostring(cnt))
        fs:Show()
    else
        fs:SetText("")
        fs:Hide()
    end
end

local function LayoutStandaloneIconGrid(container, cfg, groupId, icons)
    local count = #icons
    if count == 0 then return end

    local _pt = Profiler.start("IG:LayoutStandaloneIconGrid")
    local iconW = cfg.width or 35
    local iconH = cfg.height or 35
    local spacingX = cfg.spacingX or 2
    local spacingY = cfg.spacingY or 2
    local limit = cfg.maxIconsPerRow or 8
    local rowAnchor = cfg.rowAnchor or "center"

    local rows = VFlow.StyleLayout.BuildRows(limit, icons)

    local maxRowW = 0
    for ri, rIcons in ipairs(rows) do
        local rcw = #rIcons * (iconW + spacingX) - spacingX
        if rcw > maxRowW then maxRowW = rcw end
    end

    local totalH = 0
    for ri, rIcons in ipairs(rows) do
        totalH = totalH + iconH
        if ri < #rows then totalH = totalH + spacingY end
    end

    local yAccum = 0
    for rowIdx, rowIcons in ipairs(rows) do
        local w, h = iconW, iconH
        local rowContentW = #rowIcons * (w + spacingX) - spacingX
        local alignOffset = maxRowW - rowContentW
        local anchorOffset = 0
        if rowAnchor == "right" then
            anchorOffset = alignOffset
        elseif rowAnchor == "center" then
            anchorOffset = alignOffset / 2
        end
        local startX = anchorOffset

        for colIdx, button in ipairs(rowIcons) do
            if VFlow.StyleApply then
                VFlow.StyleApply.ApplyIconSize(button, w, h)
                VFlow.StyleApply.ApplyButtonStyleIfStale(button, cfg)
            end
            if MasqueSupport and MasqueSupport:IsActive() and button.Icon then
                MasqueSupport:RegisterButton(button, button.Icon)
            end

            local x = startX + (colIdx - 1) * (w + spacingX)
            local y = -yAccum

            button:ClearAllPoints()
            button:SetPoint("TOPLEFT", container, "TOPLEFT", x, y)
            button:SetAlpha(1)

            UpdateItemStackDisplay(button, button._vf_entry, cfg)
        end

        yAccum = yAccum + h + spacingY
    end

    local iconScale = 1
    local firstIcon = icons[1]
    if firstIcon and firstIcon.GetScale then
        local sc = firstIcon:GetScale()
        if type(sc) == "number" and sc > 0 then iconScale = sc end
    end
    container:SetSize(maxRowW * iconScale, totalH * iconScale)
    ApplyContainerAnchor(container, cfg)
    Profiler.stop(_pt)
end

local function SkillRowsAsCellRows(skillRows)
    local out = {}
    for ri, r in ipairs(skillRows or {}) do
        out[ri] = {}
        for _, icon in ipairs(r) do
            out[ri][#out[ri] + 1] = { frame = icon, isItem = false }
        end
    end
    return out
end

local function SyncAppendFrameList(viewer, groupId, cfg, entries)
    local _pt = Profiler.start("IG:SyncAppendFrameList")
    local vk = ViewerCacheKey(viewer)
    if not _appendFrameLists[vk] then
        _appendFrameLists[vk] = {}
    end
    local list = _appendFrameLists[vk][groupId]
    if not list then
        list = {}
        _appendFrameLists[vk][groupId] = list
    end

    for i = #entries + 1, #list do
        list[i]:Hide()
    end

    for i = 1, #entries do
        if not list[i] then
            list[i] = CreateStandaloneIconFrame(viewer)
        end
        local frame = list[i]
        frame._vf_itemAppendFrame = true
        frame._vf_itemGroupId = groupId
        frame:SetParent(viewer)
        local entry = entries[i]
        if entry.itemID then
            C_Item.RequestLoadItemDataByID(entry.itemID)
        end
        frame._vf_entry = entry
        ApplyEntryTexture(frame, entry)
        ApplyEntryCooldown(frame, entry)
        UpdateAppendItemStackDisplay(frame, entry)
        ApplyItemZeroCountPresentation(frame, entry, cfg)
    end
    Profiler.stop(_pt)
end

--- 删除自定义组后，大于 #customGroups 的 groupId 槽位上可能仍挂着追加帧；清理并释放引用
local function ReleaseAppendSlotFully(viewerKey, groupId)
    local byGroup = _appendFrameLists[viewerKey]
    if not byGroup then return end
    local list = byGroup[groupId]
    if list then
        for _, f in ipairs(list) do
            if f then
                f:Hide()
                f:SetParent(nil)
            end
        end
        wipe(list)
        byGroup[groupId] = nil
    end
end

local function PruneOrphanItemGroupRuntime()
    local db = VFlow.getDBIfReady(MODULE_KEY)
    local maxCustom = db and db.customGroups and #db.customGroups or 0
    for vk, byGroup in pairs(_appendFrameLists) do
        local remove = {}
        for gid, _ in pairs(byGroup) do
            if type(gid) == "number" and gid > maxCustom then
                remove[#remove + 1] = gid
            end
        end
        for _, gid in ipairs(remove) do
            ReleaseAppendSlotFully(vk, gid)
        end
    end
    local sgRemove = {}
    for gid, _ in pairs(_standaloneFrameLists) do
        if type(gid) == "number" and gid > maxCustom then
            sgRemove[#sgRemove + 1] = gid
        end
    end
    for _, gid in ipairs(sgRemove) do
        ReleaseGroupContainer(gid)
    end
end

local function SyncAllAppendForViewer(viewer)
    local _pt = Profiler.start("IG:SyncAllAppendForViewer")
    PruneOrphanItemGroupRuntime()
    local db = VFlow.getDBIfReady(MODULE_KEY)
    if not db then
        Profiler.stop(_pt)
        return
    end
    local function syncOne(groupId, cfg)
        if cfg and ShouldAppendToViewer(cfg, viewer) then
            SyncAppendFrameList(viewer, groupId, cfg, BuildAppendEntries(cfg))
        else
            ReleaseAppendSlotFully(ViewerCacheKey(viewer), groupId)
        end
    end
    syncOne(0, db.mainGroup)
    for i, g in ipairs(db.customGroups or {}) do
        syncOne(i, g and g.config)
    end
    Profiler.stop(_pt)
end

local function AppendCellsForGroup(viewer, groupId, cfg)
    local vk = ViewerCacheKey(viewer)
    local list = _appendFrameLists[vk] and _appendFrameLists[vk][groupId]
    if not list then return {} end
    local entries = BuildAppendEntries(cfg)
    local cells = {}
    for i = 1, #entries do
        if ShouldIncludeItemCellInLayout(entries[i], cfg) then
            cells[#cells + 1] = {
                frame = list[i],
                isItem = true,
                groupId = groupId,
                entry = entries[i],
            }
        end
    end
    return cells
end

local function MergeSkillRowsWithAppend(viewer, limit, skillRows)
    local _pt = Profiler.start("IG:MergeSkillRowsWithAppend")
    SyncAllAppendForViewer(viewer)

    local db = VFlow.getDBIfReady(MODULE_KEY)
    if not db then
        local out = SkillRowsAsCellRows(skillRows)
        Profiler.stop(_pt)
        return out
    end

    local appendGroups = {}
    if db.mainGroup and ShouldAppendToViewer(db.mainGroup, viewer) then
        appendGroups[#appendGroups + 1] = { id = 0, cfg = db.mainGroup }
    end
    for i, g in ipairs(db.customGroups or {}) do
        if g.config and ShouldAppendToViewer(g.config, viewer) then
            appendGroups[#appendGroups + 1] = { id = i, cfg = g.config }
        end
    end

    if #appendGroups == 0 then
        local out = SkillRowsAsCellRows(skillRows)
        Profiler.stop(_pt)
        return out
    end

    local maxSkillRow = #(skillRows or {})
    local function skillCellsFromRow(ri)
        local row = skillRows and skillRows[ri]
        if not row then return {} end
        local c = {}
        for _, icon in ipairs(row) do
            c[#c + 1] = { frame = icon, isItem = false }
        end
        return c
    end

    local function concat3(a, b, c)
        local out = {}
        for _, t in ipairs({ a, b, c }) do
            if t then
                for _, x in ipairs(t) do
                    out[#out + 1] = x
                end
            end
        end
        return out
    end

    --- 将 L..M..R 排成一行：R 整体固定在该行末尾；不足 limit 时从 L..M 从左取满，右侧多出的技能挤到 overflow（供下一行）
    local function reflowRowRespectingEndTail(L, M, R, rowLimit)
        L = L or {}
        M = M or {}
        R = R or {}
        if rowLimit <= 0 then
            return concat3(L, M, R), {}
        end
        local lm = concat3(L, M, nil)
        local nLm, nR = #lm, #R
        local total = nLm + nR
        if total <= rowLimit then
            return concat3(lm, R, nil), {}
        end
        if nR > rowLimit then
            local row = {}
            for i = nR - rowLimit + 1, nR do
                row[#row + 1] = R[i]
            end
            local ov = concat3(lm, nil, nil)
            for i = 1, nR - rowLimit do
                ov[#ov + 1] = R[i]
            end
            return row, ov
        end
        local prefixBudget = rowLimit - nR
        local row = {}
        for i = 1, math.min(prefixBudget, nLm) do
            row[#row + 1] = lm[i]
        end
        for _, c in ipairs(R) do
            row[#row + 1] = c
        end
        local ov = {}
        for i = prefixBudget + 1, nLm do
            ov[#ov + 1] = lm[i]
        end
        return row, ov
    end

    local function buildSideBlock(targetRow, side)
        local block = {}
        for _, gg in ipairs(appendGroups) do
            local c = gg.cfg
            local tr = (c.appendTargetRow == 2) and 2 or 1
            local sd = (c.appendSide == "start") and "start" or "end"
            if tr == targetRow and sd == side then
                for _, cell in ipairs(AppendCellsForGroup(viewer, gg.id, c)) do
                    block[#block + 1] = cell
                end
            end
        end
        return block
    end

    local maxR = math.max(maxSkillRow, 2)

    if limit <= 0 then
        local sequence = {}
        for ri = 1, maxR do
            local chunk = concat3(buildSideBlock(ri, "start"), skillCellsFromRow(ri), buildSideBlock(ri, "end"))
            for _, cell in ipairs(chunk) do
                sequence[#sequence + 1] = cell
            end
        end
        Profiler.stop(_pt)
        return { sequence }
    end

    local newRows = {}
    local overflow = {}
    for ri = 1, maxR do
        local L = concat3(overflow, buildSideBlock(ri, "start"), nil)
        local M = skillCellsFromRow(ri)
        local R = buildSideBlock(ri, "end")
        local rowOut, ov = reflowRowRespectingEndTail(L, M, R, limit)
        if #rowOut > 0 then
            newRows[#newRows + 1] = rowOut
        end
        overflow = ov
    end
    while #overflow > 0 do
        local rowOut, ov = reflowRowRespectingEndTail({}, overflow, {}, limit)
        if #rowOut > 0 then
            newRows[#newRows + 1] = rowOut
        end
        overflow = ov
    end
    Profiler.stop(_pt)
    return newRows
end

RefreshAllAppendCooldowns = function()
    local _pt = Profiler.start("IG:RefreshAllAppendCooldowns")
    for _, groups in pairs(_appendFrameLists) do
        for groupId, list in pairs(groups) do
            local icfg = GetConfigForGroupId(groupId)
            for _, f in ipairs(list) do
                if f and f._vf_entry and ApplyEntryCooldown then
                    ApplyEntryCooldown(f, f._vf_entry)
                    UpdateAppendItemStackDisplay(f, f._vf_entry)
                    ApplyItemZeroCountPresentation(f, f._vf_entry, icfg)
                end
            end
        end
    end
    Profiler.stop(_pt)
end

local function SyncStandaloneFrameList(container, groupId, cfg, entries)
    local list = _standaloneFrameLists[groupId]
    if not list then
        list = {}
        _standaloneFrameLists[groupId] = list
    end

    for i = #entries + 1, #list do
        list[i]:Hide()
    end

    for i = 1, #entries do
        if not list[i] then
            list[i] = CreateStandaloneIconFrame(container)
        end
        local frame = list[i]
        frame:SetParent(container)
        local entry = entries[i]
        if entry.itemID then
            C_Item.RequestLoadItemDataByID(entry.itemID)
        end
        frame._vf_itemGroupId = groupId
        frame._vf_entry = entry
        ApplyEntryTexture(frame, entry)
        ApplyEntryCooldown(frame, entry)
        ApplyItemZeroCountPresentation(frame, entry, cfg)
    end
end

local function RefreshStandaloneGroup(groupId)
    local cfg = GetConfigForGroupId(groupId)
    if not cfg or not ShouldStandaloneExtract(cfg) then return end

    local container = EnsureGroupContainer(groupId)
    if not container then return end

    local entries = BuildStandaloneEntries(cfg)
    local isEditMode = VFlow.State.get("isEditMode")

    if #entries == 0 then
        local list = _standaloneFrameLists[groupId]
        if list then
            for _, f in ipairs(list) do
                f:Hide()
            end
        end
        if isEditMode then
            container:SetSize(100, 100)
            container:Show()
        else
            container:Hide()
        end
        ApplyContainerAnchor(container, cfg)
        return
    end

    container:Show()
    SyncStandaloneFrameList(container, groupId, cfg, entries)

    local list = _standaloneFrameLists[groupId]
    local icons = {}
    for i = 1, #entries do
        if ShouldIncludeItemCellInLayout(entries[i], cfg) then
            icons[#icons + 1] = list[i]
        end
    end

    if #icons == 0 then
        if isEditMode then
            container:SetSize(100, 100)
            container:Show()
        else
            container:Hide()
        end
        ApplyContainerAnchor(container, cfg)
        return
    end

    LayoutStandaloneIconGrid(container, cfg, groupId, icons)
end

RefreshAllStandaloneLayouts = function()
    local _pt = Profiler.start("IG:RefreshAllStandaloneLayouts")
    local db = VFlow.getDBIfReady(MODULE_KEY)
    if not db then
        Profiler.stop(_pt)
        return
    end
    local hasStandalone = db.mainGroup and ShouldStandaloneExtract(db.mainGroup)
    if not hasStandalone then
        for _, g in ipairs(db.customGroups or {}) do
            if g.config and ShouldStandaloneExtract(g.config) then
                hasStandalone = true
                break
            end
        end
    end
    if not hasStandalone then
        Profiler.stop(_pt)
        return
    end

    if db.mainGroup and ShouldStandaloneExtract(db.mainGroup) then
        RefreshStandaloneGroup(0)
    end
    for i, g in ipairs(db.customGroups or {}) do
        if g.config and ShouldStandaloneExtract(g.config) then
            RefreshStandaloneGroup(i)
        end
    end
    Profiler.stop(_pt)
end

local function LayoutItemGroupsCompat()
    RefreshAllStandaloneLayouts()
end

VFlow.ItemGroups = {
    processSkillViewerIcons = ProcessSkillViewerIcons,
    refreshStandaloneLayouts = RefreshAllStandaloneLayouts,
    layoutItemGroups = LayoutItemGroupsCompat,
    invalidateSpellMap = MarkMapDirty,
    viewerHasAppendEntries = ViewerHasAppendEntries,
    mergeSkillRowsWithAppend = MergeSkillRowsWithAppend,
    syncAppendFramesForViewer = SyncAllAppendForViewer,
    refreshAppendFrameStack = UpdateAppendItemStackDisplay,
}

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
    ScheduleStandaloneRefresh()
end)

VFlow.on("UNIT_SPELLCAST_SUCCEEDED", "ItemGroups_ItemUse", function(_, unitTarget)
    if unitTarget ~= "player" then return end
    ScheduleStandaloneRefresh()
end, "player")

VFlow.on("BAG_UPDATE_DELAYED", "ItemGroups_Bag", function()
    ScheduleStandaloneRefresh()
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
        if VFlow.RequestCooldownStyleRefresh then
            VFlow.RequestCooldownStyleRefresh()
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
        if VFlow.RequestCooldownStyleRefresh then
            VFlow.RequestCooldownStyleRefresh()
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
        local gid
        if key:sub(1, 8) == "mainGroup" then
            gid = 0
        else
            gid = tonumber(key:match("^customGroups%.(%d+)%."))
        end
        if gid ~= nil then
            local container = _containers[gid]
            local cfg = GetConfigForGroupId(gid)
            if container and cfg and NeedsStandaloneContainer(cfg) then
                ApplyContainerAnchor(container, cfg)
                if VFlow.DragFrame and VFlow.DragFrame.applyRegisteredPosition then
                    VFlow.DragFrame.applyRegisteredPosition(container)
                end
            end
        end
        ScheduleStandaloneRefresh()
        return
    end

    if key == "customGroups" or key == "mainGroup" or key:find("^customGroups%.%d+%.config")
        or key:find("^mainGroup%.") then
        if key == "customGroups" or key == "mainGroup" then
            PruneOrphanItemGroupRuntime()
        end
        InitGroupContainers()
    end

    MarkMapDirty()
    ScheduleStandaloneRefresh()
    -- 追加行/位置、displayMode、条目等变化需立刻重排 Essential/Utility（CooldownStyle 只监听 Skills）
    if VFlow.RequestCooldownStyleRefresh then
        VFlow.RequestCooldownStyleRefresh()
    end
end)
