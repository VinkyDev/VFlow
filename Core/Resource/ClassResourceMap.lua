-- =========================================================
-- ClassResourceMap — 全职业/专精/德鲁伊形态 主资源与次资源映射（德鲁伊行延迟构建）
-- =========================================================

local VFlow = _G.VFlow
if not VFlow then return end

local CR = {}

---@class ClassResourceRow
---@field specId number
---@field formId number|nil
---@field primary string
---@field secondary string|nil

CR.CUSTOM = {
    STAGGER = true,
    ICICLES = true,
    MAELSTROM_WEAPON = true,
    SOUL_FRAGMENTS_VENGEANCE = true,
    DEVOURER_SOUL = true,
    TIP_OF_THE_SPEAR = true,
}

local function D()
    return {
        CAT = _G.DRUID_CAT_FORM,
        BEAR = _G.DRUID_BEAR_FORM,
        TRAVEL = _G.DRUID_TRAVEL_FORM,
        AQUATIC = _G.DRUID_ACQUATIC_FORM,
        FLIGHT = _G.DRUID_FLIGHT_FORM,
        MOONKIN_1 = _G.DRUID_MOONKIN_FORM_1,
        MOONKIN_2 = _G.DRUID_MOONKIN_FORM_2,
        TREE = _G.DRUID_TREE_FORM,
        TREANT = 36,
    }
end

local function row(specId, formId, primary, secondary)
    return { specId = specId, formId = formId, primary = primary, secondary = secondary }
end

local druidRowsCache

local function buildDruidRows()
    if druidRowsCache then
        return druidRowsCache
    end
    local d = D()
    local R = {}
    local function a(e) R[#R + 1] = e end
    a(row(102, nil, "LUNAR_POWER", "MANA"))
    a(row(103, nil, "MANA", nil))
    a(row(104, nil, "MANA", nil))
    a(row(105, nil, "MANA", nil))
    -- 枭兽：主星界、次法力
    if d.MOONKIN_1 then a(row(102, d.MOONKIN_1, "LUNAR_POWER", "MANA")) end
    if d.MOONKIN_2 then a(row(102, d.MOONKIN_2, "LUNAR_POWER", "MANA")) end
    if d.CAT then
        for _, sid in ipairs({ 102, 103, 104, 105 }) do
            a(row(sid, d.CAT, "ENERGY", "COMBO_POINTS"))
        end
    end
    if d.BEAR then
        a(row(102, d.BEAR, "RAGE", nil))
        a(row(103, d.BEAR, "RAGE", nil))
        a(row(104, d.BEAR, "RAGE", nil))
        a(row(105, d.BEAR, "RAGE", nil))
    end
    -- 树形态（恢复）：法力
    if d.TREE then a(row(105, d.TREE, "MANA", nil)) end
    -- 旅行/水栖/飞行：主法力、无次资源
    for _, fid in ipairs({ d.TRAVEL, d.AQUATIC, d.FLIGHT }) do
        if fid then
            for _, sid in ipairs({ 102, 103, 104, 105 }) do
                a(row(sid, fid, "MANA", nil))
            end
        end
    end
    if d.TREANT then
        for _, sid in ipairs({ 102, 103, 104, 105 }) do
            a(row(sid, d.TREANT, "MANA", nil))
        end
    end
    druidRowsCache = R
    return R
end

local ROWS_BY_CLASS = {
    WARRIOR = {
        row(71, nil, "RAGE", nil),
        row(72, nil, "RAGE", nil),
        row(73, nil, "RAGE", nil),
    },
    PALADIN = {
        row(65, nil, "MANA", "HOLY_POWER"),
        row(66, nil, "MANA", "HOLY_POWER"),
        row(70, nil, "MANA", "HOLY_POWER"),
    },
    HUNTER = {
        row(253, nil, "FOCUS", nil),
        row(254, nil, "FOCUS", nil),
        row(255, nil, "FOCUS", "TIP_OF_THE_SPEAR"),
    },
    ROGUE = {
        row(259, nil, "ENERGY", "COMBO_POINTS"),
        row(260, nil, "ENERGY", "COMBO_POINTS"),
        row(261, nil, "ENERGY", "COMBO_POINTS"),
    },
    PRIEST = {
        row(256, nil, "MANA", nil),
        row(257, nil, "MANA", nil),
        row(258, nil, "INSANITY", "MANA"),
    },
    DEATHKNIGHT = {
        row(250, nil, "RUNIC_POWER", "RUNES"),
        row(251, nil, "RUNIC_POWER", "RUNES"),
        row(252, nil, "RUNIC_POWER", "RUNES"),
    },
    SHAMAN = {
        row(262, nil, "MAELSTROM", "MANA"),
        row(263, nil, "MANA", "MAELSTROM_WEAPON"),
        row(264, nil, "MANA", nil),
    },
    MAGE = {
        row(62, nil, "MANA", "ARCANE_CHARGES"),
        row(63, nil, "MANA", nil),
        row(64, nil, "MANA", "ICICLES"),
    },
    WARLOCK = {
        row(265, nil, "MANA", "SOUL_SHARDS"),
        row(266, nil, "MANA", "SOUL_SHARDS"),
        row(267, nil, "MANA", "SOUL_SHARDS"),
    },
    MONK = {
        row(268, nil, "ENERGY", "STAGGER"),
        row(269, nil, "ENERGY", "CHI"),
        row(270, nil, "MANA", nil),
    },
    EVOKER = {
        row(1467, nil, "MANA", "ESSENCE"),
        row(1468, nil, "MANA", "ESSENCE"),
        row(1473, nil, "MANA", "ESSENCE"),
    },
    DEMONHUNTER = {
        row(577, nil, "FURY", nil),
        row(581, nil, "FURY", "SOUL_FRAGMENTS_VENGEANCE"),
        row(1480, nil, "FURY", "DEVOURER_SOUL"),
    },
}

---@param classFile string
---@return ClassResourceRow[]
function CR.GetRowsForClass(classFile)
    if classFile == "DRUID" then
        return buildDruidRows()
    end
    return ROWS_BY_CLASS[classFile] or {}
end

function CR.GetRowsForPlayer()
    local _, classFile = UnitClass("player")
    return CR.GetRowsForClass(classFile)
end

--- 当前职业映射中出现过的资源 token（主、次去重），行序遍历，用于样式页「本职业靠前」
---@param classFile string
---@return string[]
---@return table<string, boolean> seen
function CR.CollectUniqueResourceTokensForClass(classFile)
    local rows = CR.GetRowsForClass(classFile)
    local seen = {}
    local order = {}
    local function push(tok)
        if tok and not seen[tok] then
            seen[tok] = true
            order[#order + 1] = tok
        end
    end
    for _, r in ipairs(rows) do
        push(r.primary)
        push(r.secondary)
    end
    return order, seen
end

--- 当前职业专精 ID 去重、排序（用于 UI 专精开关）
---@param classFile string
---@return number[]
function CR.GetUniqueSpecIdsForClass(classFile)
    local rows = CR.GetRowsForClass(classFile)
    local seen = {}
    local list = {}
    for _, r in ipairs(rows) do
        local id = r.specId
        if id and not seen[id] then
            seen[id] = true
            list[#list + 1] = id
        end
    end
    table.sort(list)
    return list
end

--- specEnabled 使用字符串键 "s"..specId，避免嵌套数字键与 Grid 读写不一致
---@param barConfig table primaryBar / secondaryBar
---@param specId number
---@return boolean
function CR.IsBarEnabledForSpec(barConfig, specId)
    if not barConfig or barConfig.enabled == false then
        return false
    end
    local t = barConfig.specEnabled
    if not t then
        return true
    end
    local k = "s" .. tostring(specId)
    return t[k] ~= false
end

function CR.GetSpecDisplayName(specId)
    if not specId or specId == 0 then
        return "?"
    end
    if _G.GetSpecializationInfoForSpecID then
        local _, name = GetSpecializationInfoForSpecID(specId)
        if name and name ~= "" then
            return name
        end
    end
    if C_SpecializationInfo and C_SpecializationInfo.GetSpecializationInfoForSpecID then
        local info = C_SpecializationInfo.GetSpecializationInfoForSpecID(specId)
        if info and info.name then
            return info.name
        end
    end
    return "Spec " .. tostring(specId)
end

---@param L table
---@param formId number|nil
---@return string
function CR.FormatFormLabel(L, formId)
    if formId == nil then
        return L["Humanoid / caster"]
    end
    local d = D()
    if d.CAT and formId == d.CAT then return L["Druid Cat Form"] end
    if d.BEAR and formId == d.BEAR then return L["Druid Bear Form"] end
    if d.TRAVEL and formId == d.TRAVEL then return L["Druid Travel Form"] end
    if d.AQUATIC and formId == d.AQUATIC then return L["Druid Aquatic Form"] end
    if d.FLIGHT and formId == d.FLIGHT then return L["Druid Flight Form"] end
    if d.MOONKIN_1 and formId == d.MOONKIN_1 then return L["Druid Moonkin Form"] end
    if d.MOONKIN_2 and formId == d.MOONKIN_2 then return L["Druid Moonkin Form"] end
    if d.TREE and formId == d.TREE then return L["Druid Treant Form"] end
    if d.TREANT and formId == d.TREANT then return L["Druid Treant (cosmetic)"] end
    return string.format(L["Shapeshift form #%s"], tostring(formId))
end

---@param L table
---@param token string|nil
---@return string
function CR.FormatResourceToken(L, token)
    if not token then
        return L["(none)"]
    end
    local key = "ResType_" .. token
    if L[key] then
        return L[key]
    end
    return token
end

VFlow.ClassResourceMap = CR
