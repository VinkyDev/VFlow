-- =========================================================
-- SECTION 1: 模块入口
-- Keybind — 键位绑定解析
-- =========================================================

local VFlow = _G.VFlow
if not VFlow then return end

local Profiler = VFlow.Profiler

local Keybind = {}
VFlow.Keybind = Keybind

-- =========================================================
-- SECTION 2: 缓存与常量
-- =========================================================

local spellToKeyCache = {}
local refreshPending = false

local BUTTON_ROW_PREFIXES = {
    blizzard = {
        [1] = "ActionButton",
        [2] = "MultiBarBottomLeftButton",
        [3] = "MultiBarBottomRightButton",
        [4] = "MultiBarRightButton",
        [5] = "MultiBarLeftButton",
        [6] = "MultiBar5Button",
        [7] = "MultiBar6Button",
        [8] = "MultiBar7Button",
    },
    elvui = {
        [1] = "ElvUI_Bar1Button",
        [2] = "ElvUI_Bar2Button",
        [3] = "ElvUI_Bar3Button",
        [4] = "ElvUI_Bar4Button",
        [5] = "ElvUI_Bar5Button",
        [6] = "ElvUI_Bar6Button",
        [7] = "ElvUI_Bar7Button",
        [8] = "ElvUI_Bar8Button",
        [9] = "ElvUI_Bar9Button",
        [10] = "ElvUI_Bar10Button",
        [13] = "ElvUI_Bar13Button",
        [14] = "ElvUI_Bar14Button",
        [15] = "ElvUI_Bar15Button",
    },
    dominos = {
        [1] = "DominosActionButton",
        [2] = "DominosActionButton",
        [3] = "MultiBarRightActionButton",
        [4] = "MultiBarLeftActionButton",
        [5] = "MultiBarBottomRightActionButton",
        [6] = "MultiBarBottomLeftActionButton",
        [7] = "DominosActionButton",
        [8] = "DominosActionButton",
        [9] = "DominosActionButton",
        [10] = "DominosActionButton",
        [11] = "DominosActionButton",
        [12] = "MultiBar5ActionButton",
        [13] = "MultiBar6ActionButton",
        [14] = "MultiBar7ActionButton",
    },
}

-- =========================================================
-- SECTION 3: 键位格式化与查询
-- =========================================================

local function FormatKeyForDisplay(key)
    if not key or key == "" then
        return ""
    end

    local bindingText = GetBindingText and GetBindingText(key, "KEY_", true)
    local displayKey = (bindingText and bindingText ~= "") and bindingText or key
    if displayKey:find("|", 1, true) then
        return displayKey
    end

    local upperKey = key:upper()

    upperKey = upperKey:gsub("PADLTRIGGER", "LT")
    upperKey = upperKey:gsub("PADRTRIGGER", "RT")
    upperKey = upperKey:gsub("PADLSHOULDER", "LB")
    upperKey = upperKey:gsub("PADRSHOULDER", "RB")
    upperKey = upperKey:gsub("PADLSTICK", "LS")
    upperKey = upperKey:gsub("PADRSTICK", "RS")
    upperKey = upperKey:gsub("PADDPADUP", "D↑")
    upperKey = upperKey:gsub("PADDPADDOWN", "D↓")
    upperKey = upperKey:gsub("PADDPADLEFT", "D←")
    upperKey = upperKey:gsub("PADDPADRIGHT", "D→")
    upperKey = upperKey:gsub("^PAD", "")

    upperKey = upperKey:gsub("SHIFT%-", "S")
    upperKey = upperKey:gsub("META%-", "M")
    upperKey = upperKey:gsub("CTRL%-", "C")
    upperKey = upperKey:gsub("ALT%-", "A")
    upperKey = upperKey:gsub("STRG%-", "ST")
    upperKey = upperKey:gsub("CONTROL%-", "C")

    upperKey = upperKey:gsub("MOUSE%s?WHEEL%s?UP", "MU")
    upperKey = upperKey:gsub("MOUSE%s?WHEEL%s?DOWN", "MD")
    upperKey = upperKey:gsub("MIDDLE%s?MOUSE", "MM")
    upperKey = upperKey:gsub("MOUSE%s?BUTTON%s?", "M")
    upperKey = upperKey:gsub("BUTTON", "M")

    upperKey = upperKey:gsub("NUMPAD%s?PLUS", "N+")
    upperKey = upperKey:gsub("NUMPAD%s?MINUS", "N-")
    upperKey = upperKey:gsub("NUMPAD%s?MULTIPLY", "N*")
    upperKey = upperKey:gsub("NUMPAD%s?DIVIDE", "N/")
    upperKey = upperKey:gsub("NUMPAD%s?DECIMAL", "N.")
    upperKey = upperKey:gsub("NUMPAD%s?ENTER", "NEnt")
    upperKey = upperKey:gsub("NUMPAD%s?", "N")
    upperKey = upperKey:gsub("NUM%s?", "N")
    upperKey = upperKey:gsub("NPAD%s?", "N")

    upperKey = upperKey:gsub("PAGE%s?UP", "PGU")
    upperKey = upperKey:gsub("PAGE%s?DOWN", "PGD")
    upperKey = upperKey:gsub("INSERT", "INS")
    upperKey = upperKey:gsub("DELETE", "DEL")
    upperKey = upperKey:gsub("SPACEBAR", "Spc")
    upperKey = upperKey:gsub("ENTER", "Ent")
    upperKey = upperKey:gsub("ESCAPE", "Esc")
    upperKey = upperKey:gsub("TAB", "Tab")
    upperKey = upperKey:gsub("CAPS%s?LOCK", "Caps")
    upperKey = upperKey:gsub("HOME", "Hom")
    upperKey = upperKey:gsub("END", "End")

    return upperKey
end

-- =========================================================
-- 构建技能ID到键位的映射
-- =========================================================

local function IsPositiveSpellID(spellID)
    return type(spellID) == "number" and spellID > 0
end

local function AddSpellAlias(map, spellID, key)
    if not IsPositiveSpellID(spellID) or not key or key == "" or key == "●" then
        return
    end
    if not map[spellID] then
        map[spellID] = key
    end
    if C_Spell and C_Spell.GetOverrideSpell then
        local overrideSpellID = C_Spell.GetOverrideSpell(spellID)
        if IsPositiveSpellID(overrideSpellID) and not map[overrideSpellID] then
            map[overrideSpellID] = key
        end
    end
    if C_Spell and C_Spell.GetBaseSpell then
        local baseSpellID = C_Spell.GetBaseSpell(spellID)
        if IsPositiveSpellID(baseSpellID) and not map[baseSpellID] then
            map[baseSpellID] = key
        end
    end
end

local function AssignResultForSlot(map, slot, keyBind)
    if not slot or not keyBind or keyBind == "" or keyBind == "●" then
        return
    end

    local actionType, id, subType = GetActionInfo(slot)
    if not id then
        return
    end

    if actionType == "spell" or (actionType == "macro" and subType == "spell") then
        AddSpellAlias(map, id, keyBind)
        return
    end

    if actionType == "macro" then
        local macroSpellID
        if GetMacroSpell then
            macroSpellID = GetMacroSpell(id)
            if not macroSpellID and GetActionText then
                local macroName = GetActionText(slot)
                if macroName then
                    macroSpellID = GetMacroSpell(macroName)
                end
            end
        end
        AddSpellAlias(map, macroSpellID, keyBind)
        return
    end

    if actionType == "item" and C_Item and C_Item.GetItemSpell then
        local _, itemSpellID = C_Item.GetItemSpell(id)
        AddSpellAlias(map, itemSpellID, keyBind)
    end
end

local function GetActionsTableBySpellID()
    local map = {}

    if _G.DominosActionButton1 then
        for i = 1, 14 do
            local bar = BUTTON_ROW_PREFIXES.dominos[i]
            if bar then
                for j = 1, 12 do
                    local buttonName = bar
                    if bar == "DominosActionButton" then
                        buttonName = bar .. ((i - 1) * 12 + j)
                    else
                        buttonName = bar .. j
                    end
                    local button = _G[buttonName]
                    local slot = button and button.action
                    local keyBind = button and button.HotKey and button.HotKey:GetText()
                    if button and slot and keyBind and keyBind ~= "●" then
                        AssignResultForSlot(map, slot, keyBind)
                    end
                end
            end
        end
    end

    if _G.BT4Button1 then
        for i = 1, 180 do
            local button = _G["BT4Button" .. i]
            local slot = button and button.action
            local keyBind = button and button.HotKey and button.HotKey:GetText()
            if button and slot and keyBind and keyBind ~= "●" then
                AssignResultForSlot(map, slot, keyBind)
            end
        end
    end

    if _G.ElvUI_Bar1Button1 then
        for i = 1, 15 do
            local bar = BUTTON_ROW_PREFIXES.elvui[i]
            if bar then
                for j = 1, 12 do
                    local button = _G[bar .. j]
                    local slot = button and button.action
                    if button and slot and button.config and button.config.keyBoundTarget then
                        local keyBind = GetBindingKey(button.config.keyBoundTarget)
                        if keyBind then
                            AssignResultForSlot(map, slot, keyBind)
                        end
                    end
                end
            end
        end
    end

    for i = 1, 8 do
        local bar = BUTTON_ROW_PREFIXES.blizzard[i]
        if bar then
            for j = 1, 12 do
                local button = _G[bar .. j]
                local slot = button and button.action
                local keyBoundTarget = button and button.commandName
                if button and slot and keyBoundTarget then
                    local keyBind = GetBindingKey(keyBoundTarget)
                    if keyBind then
                        AssignResultForSlot(map, slot, keyBind)
                    end
                end
            end
        end
    end

    return map
end

local function BuildSpellToKeyMap()
    local _pt = Profiler.start("KB:BuildSpellToKeyMap")
    local rawMap = GetActionsTableBySpellID()
    local formattedMap = {}

    for spellID, rawKey in pairs(rawMap) do
        if rawKey and rawKey ~= "" and rawKey ~= "●" and not formattedMap[spellID] then
            local formattedKey = FormatKeyForDisplay(rawKey)
            if formattedKey ~= "" then
                formattedMap[spellID] = formattedKey
            end
        end
    end

    for spellID, keyBind in pairs(spellToKeyCache) do
        if not formattedMap[spellID] then
            formattedMap[spellID] = keyBind
        end
    end

    spellToKeyCache = formattedMap
    Profiler.stop(_pt)
    return formattedMap
end

-- =========================================================
-- 公共API
-- =========================================================

-- 获取技能ID从图标
function Keybind.GetSpellIDFromIcon(icon)
    if icon.cooldownID and C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCooldownInfo then
        local info = C_CooldownViewer.GetCooldownViewerCooldownInfo(icon.cooldownID)
        if info and IsPositiveSpellID(info.spellID) then
            return info.spellID
        end
    end
    if icon.spellID and IsPositiveSpellID(icon.spellID) then
        return icon.spellID
    end
    if icon.GetSpellID then
        local spellID = icon:GetSpellID()
        if IsPositiveSpellID(spellID) then
            return spellID
        end
    end
    return nil
end

-- 查找技能的键位
local function FindKeyForSpell(spellID, map)
    if not spellID or not map then return "" end
    if map[spellID] then return map[spellID] end
    if C_Spell and C_Spell.GetOverrideSpell then
        local ov = C_Spell.GetOverrideSpell(spellID)
        if ov and map[ov] then return map[ov] end
    end
    if C_Spell and C_Spell.GetBaseSpell then
        local base = C_Spell.GetBaseSpell(spellID)
        if base and map[base] then return map[base] end
    end
    return ""
end

-- 获取技能的键位文本
function Keybind.GetKeyForSpell(spellID)
    if not spellID then return "" end

    if next(spellToKeyCache) == nil then
        spellToKeyCache = BuildSpellToKeyMap()
    end

    return FindKeyForSpell(spellID, spellToKeyCache)
end

function Keybind.InvalidateCache()
    spellToKeyCache = {}
end

local function RequestSkillViewerRefresh(delay)
    if refreshPending then
        return
    end
    refreshPending = true
    C_Timer.After(delay or 0.1, function()
        refreshPending = false
        if VFlow.RequestKeybindStyleRefresh then
            VFlow.RequestKeybindStyleRefresh(0)
        elseif VFlow.RequestCooldownStyleRefresh then
            VFlow.RequestCooldownStyleRefresh()
        end
    end)
end

-- =========================================================
-- SECTION 4: 事件监听
-- =========================================================

local function HandleKeybindRelatedChange()
    Keybind.InvalidateCache()
    RequestSkillViewerRefresh(0.1)
end

local KEYBIND_EVENTS = {
    "PLAYER_ENTERING_WORLD",
    "ACTIONBAR_SLOT_CHANGED",
    "UPDATE_BINDINGS",
    "UPDATE_BONUS_ACTIONBAR",
    "PLAYER_TALENT_UPDATE",
    "PLAYER_SPECIALIZATION_CHANGED",
    "TRAIT_CONFIG_UPDATED",
    "EDIT_MODE_LAYOUTS_UPDATED",
    "PLAYER_REGEN_DISABLED",
    "ACTIONBAR_HIDEGRID",
    "ACTIONBAR_PAGE_CHANGED",
    "GAME_PAD_ACTIVE_CHANGED",
}

for _, eventName in ipairs(KEYBIND_EVENTS) do
    VFlow.on(eventName, "VFlow.Keybind." .. eventName, HandleKeybindRelatedChange)
end
