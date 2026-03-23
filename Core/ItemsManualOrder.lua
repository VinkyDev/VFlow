-- =========================================================
-- SECTION 1: 模块入口
-- ItemsManualOrder — 物品组 entryOrder 归一化
-- =========================================================

local VFlow = _G.VFlow
VFlow.ItemsManualOrder = VFlow.ItemsManualOrder or {}

-- entryOrder 元素：
--- { t = "trinket_slot", slot = 13|14 }  — autoTrinkets 开启时保留槽位（可空）
--- { t = "racial", id = spellID }
--- { t = "item", id = itemID }
-- { t = "spell", id = spellID }

-- =========================================================
-- SECTION 2: 构建与 Ensure
-- =========================================================

local function trinketSlotList(cfg)
    local out = {}
    if cfg.autoTrinkets then
        out[1], out[2] = 13, 14
    end
    return out
end

local function racialSpellList(cfg)
    local out = {}
    if cfg.autoRacialAbility and VFlow.ItemAutoData and VFlow.ItemAutoData.collectRacialSpellIDs then
        for _, sid in ipairs(VFlow.ItemAutoData.collectRacialSpellIDs()) do
            out[#out + 1] = sid
        end
    end
    table.sort(out)
    return out
end

local function racialSpellSet(cfg)
    local set = {}
    for _, sid in ipairs(racialSpellList(cfg)) do
        set[sid] = true
    end
    return set
end

local function entryKey(e)
    if not e or type(e.t) ~= "string" then return nil end
    if e.t == "trinket_slot" and type(e.slot) == "number" then return "t" .. e.slot end
    if e.t == "racial" and type(e.id) == "number" then return "r" .. e.id end
    if e.t == "item" and type(e.id) == "number" then return "i" .. e.id end
    if e.t == "spell" and type(e.id) == "number" then return "s" .. e.id end
    return nil
end

local function entryValid(cfg, e, racialSet)
    if not e or type(e.t) ~= "string" then return false end
    if e.t == "trinket_slot" then
        return cfg.autoTrinkets and (e.slot == 13 or e.slot == 14)
    end
    if e.t == "racial" then
        return cfg.autoRacialAbility and type(e.id) == "number" and racialSet[e.id]
    end
    if e.t == "item" then
        return type(e.id) == "number" and cfg.itemIDs[e.id]
    end
    if e.t == "spell" then
        return type(e.id) == "number" and cfg.spellIDs[e.id]
    end
    return false
end

local function appendDefaultManualFromSets(cfg, order)
    local items = {}
    for iid in pairs(cfg.itemIDs or {}) do items[#items + 1] = iid end
    table.sort(items)
    for _, iid in ipairs(items) do
        order[#order + 1] = { t = "item", id = iid }
    end
    local spells = {}
    for sid in pairs(cfg.spellIDs or {}) do spells[#spells + 1] = sid end
    table.sort(spells)
    for _, sid in ipairs(spells) do
        order[#order + 1] = { t = "spell", id = sid }
    end
end

function VFlow.ItemsManualOrder.Ensure(cfg)
    if not cfg then return end
    cfg.itemIDs = cfg.itemIDs or {}
    cfg.spellIDs = cfg.spellIDs or {}

    local slots = trinketSlotList(cfg)
    local racials = racialSpellList(cfg)
    local racialSet = racialSpellSet(cfg)

    if type(cfg.entryOrder) ~= "table" then
        cfg.entryOrder = {}
    end

    local legacy = cfg.manualEntryOrder
    local hasLegacyManual = type(legacy) == "table" and #legacy > 0
    local entryOrderEmpty = #cfg.entryOrder == 0

    if entryOrderEmpty then
        cfg.entryOrder = {}
        for _, slot in ipairs(slots) do
            cfg.entryOrder[#cfg.entryOrder + 1] = { t = "trinket_slot", slot = slot }
        end
        for _, sid in ipairs(racials) do
            cfg.entryOrder[#cfg.entryOrder + 1] = { t = "racial", id = sid }
        end
        if hasLegacyManual then
            for _, e in ipairs(legacy) do
                if e.t == "item" and cfg.itemIDs[e.id] then
                    cfg.entryOrder[#cfg.entryOrder + 1] = { t = "item", id = e.id }
                elseif e.t == "spell" and cfg.spellIDs[e.id] then
                    cfg.entryOrder[#cfg.entryOrder + 1] = { t = "spell", id = e.id }
                end
            end
        else
            appendDefaultManualFromSets(cfg, cfg.entryOrder)
        end
        cfg.manualEntryOrder = {}
    end

    local cleaned = {}
    local seen = {}
    for _, e in ipairs(cfg.entryOrder) do
        if entryValid(cfg, e, racialSet) then
            local k = entryKey(e)
            if k and not seen[k] then
                seen[k] = true
                if e.t == "trinket_slot" then
                    cleaned[#cleaned + 1] = { t = "trinket_slot", slot = e.slot }
                elseif e.t == "racial" then
                    cleaned[#cleaned + 1] = { t = "racial", id = e.id }
                elseif e.t == "item" then
                    cleaned[#cleaned + 1] = { t = "item", id = e.id }
                else
                    cleaned[#cleaned + 1] = { t = "spell", id = e.id }
                end
            end
        end
    end
    cfg.entryOrder = cleaned
    seen = {}
    for _, e in ipairs(cfg.entryOrder) do
        seen[entryKey(e)] = true
    end

    for _, slot in ipairs(slots) do
        local k = "t" .. slot
        if not seen[k] then
            cfg.entryOrder[#cfg.entryOrder + 1] = { t = "trinket_slot", slot = slot }
            seen[k] = true
        end
    end
    for _, sid in ipairs(racials) do
        local k = "r" .. sid
        if not seen[k] then
            cfg.entryOrder[#cfg.entryOrder + 1] = { t = "racial", id = sid }
            seen[k] = true
        end
    end
    for iid in pairs(cfg.itemIDs) do
        local k = "i" .. iid
        if not seen[k] then
            cfg.entryOrder[#cfg.entryOrder + 1] = { t = "item", id = iid }
            seen[k] = true
        end
    end
    for sid in pairs(cfg.spellIDs) do
        local k = "s" .. sid
        if not seen[k] then
            cfg.entryOrder[#cfg.entryOrder + 1] = { t = "spell", id = sid }
            seen[k] = true
        end
    end
end
