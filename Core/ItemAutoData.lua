-- =========================================================
-- SECTION 1: 模块入口
-- ItemAutoData — 物品 / 种族自动检测数据
-- =========================================================

local VFlow = _G.VFlow
if not VFlow then return end

-- =========================================================
-- SECTION 2: 静态表与解析 API
-- =========================================================

-- 种族技能
local RACE_RACIALS = {
    Scourge            = { 7744 },
    Tauren             = { 20549 },
    Orc                = { 20572, 33697, 33702 },
    BloodElf           = { 202719, 50613, 25046, 69179, 80483, 155145, 129597, 232633, 28730 },
    Dwarf              = { 20594 },
    Troll              = { 26297 },
    Draenei            = { 28880 },
    NightElf           = { 58984 },
    Human              = { 59752 },
    DarkIronDwarf      = { 265221 },
    Gnome              = { 20589 },
    HighmountainTauren = { 69041 },
    Worgen             = { 68992 },
    Goblin             = { 69070 },
    Pandaren           = { 107079 },
    MagharOrc          = { 274738 },
    LightforgedDraenei = { 255647 },
    VoidElf            = { 256948 },
    KulTiran           = { 287712 },
    ZandalariTroll     = { 291944 },
    Vulpera            = { 312411 },
    Mechagnome         = { 312924 },
    Dracthyr           = { 357214, { 368970, class = "EVOKER" } },
    EarthenDwarf       = { 436344 },
    Haranir            = { 1287685 },
}

-- 手动物品：相邻 ID（±1）在配置 ID 无货时自动尝试（多数药水成对相差 1）
-- 仅「非 ±1」关系写进例外组，例如治疗石
local MANUAL_ITEM_ALTERNATE_EXCEPTION_GROUPS = {
    { 5512, 224464 }, -- 治疗石 / 恶魔治疗石
}

local manualItemAlternateExceptionGroupById = {}
for _, group in ipairs(MANUAL_ITEM_ALTERNATE_EXCEPTION_GROUPS) do
    for _, itemID in ipairs(group) do
        if type(itemID) == "number" and itemID > 0 then
            manualItemAlternateExceptionGroupById[itemID] = group
        end
    end
end

local function collectRacialSpellIDs()
    local out = {}
    local _, race = UnitRace("player")
    local _, class = UnitClass("player")
    local list = race and RACE_RACIALS[race]
    if not list then return out end
    for _, spellEntry in ipairs(list) do
        local spellID = type(spellEntry) == "table" and spellEntry[1] or spellEntry
        local spellClass = type(spellEntry) == "table" and spellEntry.class
        if spellID and (not spellClass or spellClass == class) then
            if C_SpellBook and C_SpellBook.IsSpellInSpellBook and C_SpellBook.IsSpellInSpellBook(spellID) then
                out[#out + 1] = spellID
            end
        end
    end
    return out
end

local function forEachOnUseTrinketSlot(fn)
    if not fn then return end
    for slot = 13, 14 do
        local itemID = GetInventoryItemID("player", slot)
        if itemID and C_Item and C_Item.RequestLoadItemDataByID then
            C_Item.RequestLoadItemDataByID(itemID)
        end
        if itemID then
            local _, spellID = C_Item.GetItemSpell(itemID)
            if spellID and spellID > 0 then
                fn(slot, itemID, spellID)
            end
        end
    end
end

local function tryResolveFromItemGroup(configItemID, group)
    if not group then return nil end
    for _, oid in ipairs(group) do
        if oid ~= configItemID and oid and oid > 0 then
            C_Item.RequestLoadItemDataByID(oid)
            if (C_Item.GetItemCount(oid, false, true) or 0) > 0 then
                return oid
            end
        end
    end
    return nil
end

--- 相邻 ID（±1）且身上数量 > 0；若配置 ID 能取到使用法术，则要求邻居同一法术，减少误匹配
local function tryResolveAdjacentItemId(configItemID)
    local _, refSpell = C_Item.GetItemSpell(configItemID)
    for _, delta in ipairs({ 1, -1 }) do
        local oid = configItemID + delta
        if oid > 0 then
            C_Item.RequestLoadItemDataByID(oid)
            if (C_Item.GetItemCount(oid, false, true) or 0) > 0 then
                if refSpell and refSpell > 0 then
                    local _, sp = C_Item.GetItemSpell(oid)
                    if sp == refSpell then
                        return oid
                    end
                else
                    return oid
                end
            end
        end
    end
    return nil
end

--- @return carriedItemID 身上能数到的实例（主 ID 或备选 ID）
local function resolveManualCarriedItemID(configItemID)
    if not configItemID or configItemID <= 0 then return configItemID end
    C_Item.RequestLoadItemDataByID(configItemID)
    if (C_Item.GetItemCount(configItemID, false, true) or 0) > 0 then
        return configItemID
    end
    local fromException = tryResolveFromItemGroup(configItemID, manualItemAlternateExceptionGroupById[configItemID])
    if fromException then
        return fromException
    end
    local fromAdjacent = tryResolveAdjacentItemId(configItemID)
    if fromAdjacent then
        return fromAdjacent
    end
    return configItemID
end

--- 监控用手动物品：携带实例 ID + 使用法术（与 ItemGroups / 法术映射一致）
local function resolveManualInventoryItem(configItemID)
    local rid = resolveManualCarriedItemID(configItemID)
    local _, sid = C_Item.GetItemSpell(rid)
    if sid and sid > 0 then
        return rid, sid
    end
    C_Item.RequestLoadItemDataByID(configItemID)
    _, sid = C_Item.GetItemSpell(configItemID)
    return rid, sid
end

VFlow.ItemAutoData = {
    forEachOnUseTrinketSlot = forEachOnUseTrinketSlot,
    collectRacialSpellIDs = collectRacialSpellIDs,
    manualItemAlternateExceptionGroups = MANUAL_ITEM_ALTERNATE_EXCEPTION_GROUPS,
    resolveManualCarriedItemID = resolveManualCarriedItemID,
    resolveManualInventoryItem = resolveManualInventoryItem,
}
