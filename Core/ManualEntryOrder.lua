-- =========================================================
-- ManualEntryOrder — entryOrder 归一化（物品组 / 其他 BUFF 计时项）
-- =========================================================

local VFlow = _G.VFlow
if not VFlow then return end

local ManualEntryOrder = {}
VFlow.ManualEntryOrder = ManualEntryOrder

local Profiler = VFlow.Profiler

local SCHEMAS = {}

local function trinketSlotList(cfg)
    local out = {}
    if cfg.autoTrinkets then
        out[1], out[2] = 13, 14
    end
    return out
end

local function appendDefaultManualFromSets(cfg, order)
    local items = {}
    for iid in pairs(cfg.itemIDs or {}) do
        items[#items + 1] = iid
    end
    table.sort(items)
    for _, iid in ipairs(items) do
        order[#order + 1] = { t = "item", id = iid }
    end

    local spells = {}
    for sid in pairs(cfg.spellIDs or {}) do
        spells[#spells + 1] = sid
    end
    table.sort(spells)
    for _, sid in ipairs(spells) do
        order[#order + 1] = { t = "spell", id = sid }
    end
end

local function rebuildSeen(order, entryKey)
    local seen = {}
    for _, e in ipairs(order) do
        local k = entryKey(e)
        if k then
            seen[k] = true
        end
    end
    return seen
end

local function cleanOrder(cfg, schema, ctx)
    local cleaned = {}
    local seen = {}
    for _, e in ipairs(cfg.entryOrder) do
        if schema.entryValid(cfg, e, ctx) then
            local k = schema.entryKey(e)
            if k and not seen[k] then
                seen[k] = true
                local copy = schema.cloneEntry(e)
                if copy then
                    cleaned[#cleaned + 1] = copy
                end
            end
        end
    end
    cfg.entryOrder = cleaned
    return rebuildSeen(cfg.entryOrder, schema.entryKey)
end

local function appendTrinketSlots(order, seen, cfg)
    for _, slot in ipairs(trinketSlotList(cfg)) do
        local k = "t" .. slot
        if not seen[k] then
            order[#order + 1] = { t = "trinket_slot", slot = slot }
            seen[k] = true
        end
    end
end

local function appendSortedIdEntries(order, seen, ids, prefix, entryType)
    local list = {}
    for id in pairs(ids or {}) do
        list[#list + 1] = id
    end
    table.sort(list)
    for _, id in ipairs(list) do
        local k = prefix .. id
        if not seen[k] then
            order[#order + 1] = { t = entryType, id = id }
            seen[k] = true
        end
    end
end

-- =========================================================
-- Schema: items（物品组）
-- =========================================================

local function itemsEntryKey(e)
    if not e or type(e.t) ~= "string" then
        return nil
    end
    if e.t == "trinket_slot" and type(e.slot) == "number" then
        return "t" .. e.slot
    end
    if e.t == "racial" and type(e.id) == "number" then
        return "r" .. e.id
    end
    if e.t == "item" and type(e.id) == "number" then
        return "i" .. e.id
    end
    if e.t == "spell" and type(e.id) == "number" then
        return "s" .. e.id
    end
    return nil
end

local function itemsRacialSpellList(cfg)
    local out = {}
    if cfg.autoRacialAbility and VFlow.ItemAutoData and VFlow.ItemAutoData.collectRacialSpellIDs then
        for _, sid in ipairs(VFlow.ItemAutoData.collectRacialSpellIDs()) do
            out[#out + 1] = sid
        end
    end
    table.sort(out)
    return out
end

local function itemsBuildContext(cfg)
    local racials = itemsRacialSpellList(cfg)
    local racialSet = {}
    for _, sid in ipairs(racials) do
        racialSet[sid] = true
    end
    return {
        slots = trinketSlotList(cfg),
        racials = racials,
        racialSet = racialSet,
    }
end

SCHEMAS.items = {
    entryKey = itemsEntryKey,
    buildContext = itemsBuildContext,

    entryValid = function(cfg, e, ctx)
        if not e or type(e.t) ~= "string" then
            return false
        end
        if e.t == "trinket_slot" then
            return cfg.autoTrinkets and (e.slot == 13 or e.slot == 14)
        end
        if e.t == "racial" then
            return cfg.autoRacialAbility
                and type(e.id) == "number"
                and ctx.racialSet
                and ctx.racialSet[e.id]
        end
        if e.t == "item" then
            return type(e.id) == "number" and cfg.itemIDs[e.id]
        end
        if e.t == "spell" then
            return type(e.id) == "number" and cfg.spellIDs[e.id]
        end
        return false
    end,

    cloneEntry = function(e)
        if e.t == "trinket_slot" then
            return { t = "trinket_slot", slot = e.slot }
        end
        if e.t == "racial" then
            return { t = "racial", id = e.id }
        end
        if e.t == "item" then
            return { t = "item", id = e.id }
        end
        if e.t == "spell" then
            return { t = "spell", id = e.id }
        end
        return nil
    end,

    buildInitialOrder = function(cfg, ctx)
        local order = {}
        for _, slot in ipairs(ctx.slots or {}) do
            order[#order + 1] = { t = "trinket_slot", slot = slot }
        end
        for _, sid in ipairs(ctx.racials or {}) do
            order[#order + 1] = { t = "racial", id = sid }
        end

        local legacy = cfg.manualEntryOrder
        if type(legacy) == "table" and #legacy > 0 then
            for _, e in ipairs(legacy) do
                if e.t == "item" and cfg.itemIDs[e.id] then
                    order[#order + 1] = { t = "item", id = e.id }
                elseif e.t == "spell" and cfg.spellIDs[e.id] then
                    order[#order + 1] = { t = "spell", id = e.id }
                end
            end
        else
            appendDefaultManualFromSets(cfg, order)
        end
        return order
    end,

    afterInitialBuild = function(cfg)
        cfg.manualEntryOrder = {}
    end,

    appendMissing = function(cfg, ctx, seen)
        appendTrinketSlots(cfg.entryOrder, seen, cfg)
        for _, sid in ipairs(ctx.racials or {}) do
            local k = "r" .. sid
            if not seen[k] then
                cfg.entryOrder[#cfg.entryOrder + 1] = { t = "racial", id = sid }
                seen[k] = true
            end
        end
        appendSortedIdEntries(cfg.entryOrder, seen, cfg.itemIDs, "i", "item")
        appendSortedIdEntries(cfg.entryOrder, seen, cfg.spellIDs, "s", "spell")
    end,
}

-- =========================================================
-- Schema: otherBuff（其他 BUFF 主动计时项）
-- =========================================================

SCHEMAS.otherBuff = {
    entryKey = function(e)
        if not e or type(e.t) ~= "string" then
            return nil
        end
        if e.t == "bloodlust" then
            return "b"
        end
        if e.t == "trinket_slot" and type(e.slot) == "number" then
            return "t" .. e.slot
        end
        if e.t == "item" and type(e.id) == "number" then
            return "i" .. e.id
        end
        if e.t == "spell" and type(e.id) == "number" then
            return "s" .. e.id
        end
        return nil
    end,

    entryValid = function(cfg, e)
        if not e or type(e.t) ~= "string" then
            return false
        end
        if e.t == "bloodlust" then
            return cfg.monitorBloodlust == true
        end
        if e.t == "trinket_slot" then
            return cfg.autoTrinkets and (e.slot == 13 or e.slot == 14)
        end
        if e.t == "item" then
            return type(e.id) == "number" and cfg.itemIDs and cfg.itemIDs[e.id]
        end
        if e.t == "spell" then
            return type(e.id) == "number" and cfg.spellIDs and cfg.spellIDs[e.id]
        end
        return false
    end,

    cloneEntry = function(e)
        if e.t == "bloodlust" then
            return { t = "bloodlust" }
        end
        if e.t == "trinket_slot" then
            return { t = "trinket_slot", slot = e.slot }
        end
        if e.t == "item" then
            return { t = "item", id = e.id }
        end
        if e.t == "spell" then
            return { t = "spell", id = e.id }
        end
        return nil
    end,

    buildInitialOrder = function(cfg)
        local order = {}
        if cfg.monitorBloodlust then
            order[#order + 1] = { t = "bloodlust" }
        end
        appendTrinketSlots(order, {}, cfg)
        appendDefaultManualFromSets(cfg, order)
        return order
    end,

    appendMissing = function(cfg, _, seen)
        if cfg.monitorBloodlust and not seen.b then
            table.insert(cfg.entryOrder, 1, { t = "bloodlust" })
            seen.b = true
        end
        appendTrinketSlots(cfg.entryOrder, seen, cfg)
        appendSortedIdEntries(cfg.entryOrder, seen, cfg.itemIDs, "i", "item")
        appendSortedIdEntries(cfg.entryOrder, seen, cfg.spellIDs, "s", "spell")
    end,
}

function ManualEntryOrder.Ensure(schemaName, cfg)
    if not cfg then
        return
    end

    local schema = SCHEMAS[schemaName]
    if not schema then
        return
    end

    cfg.itemIDs = cfg.itemIDs or {}
    cfg.spellIDs = cfg.spellIDs or {}
    if type(cfg.entryOrder) ~= "table" then
        cfg.entryOrder = {}
    end

    local ctx = schema.buildContext and schema.buildContext(cfg) or {}

    if #cfg.entryOrder == 0 then
        cfg.entryOrder = schema.buildInitialOrder(cfg, ctx) or {}
        if schema.afterInitialBuild then
            schema.afterInitialBuild(cfg, ctx)
        end
    end

    local seen = cleanOrder(cfg, schema, ctx)
    schema.appendMissing(cfg, ctx, seen)
end

VFlow.ItemsManualOrder = {
    Ensure = function(cfg)
        ManualEntryOrder.Ensure("items", cfg)
    end,
}

VFlow.OtherBuffManualOrder = {
    Ensure = function(cfg)
        ManualEntryOrder.Ensure("otherBuff", cfg)
    end,
}

if Profiler and Profiler.registerTableScope then
    Profiler.registerTableScope(VFlow.ItemsManualOrder, "Ensure", "IMO:Ensure")
    Profiler.registerTableScope(VFlow.OtherBuffManualOrder, "Ensure", "OBMO:Ensure")
end
