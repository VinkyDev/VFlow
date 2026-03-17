-- =========================================================
-- VFlow Keybind - 键位绑定处理
-- =========================================================

local VFlow = _G.VFlow
if not VFlow then return end

local Keybind = {}
VFlow.Keybind = Keybind

-- =========================================================
-- 缓存和常量
-- =========================================================

local spellToKeyCache = {}

local KEYBIND_BAR_PREFIXES = {
    "ActionButton",
    "MultiBarBottomLeftButton",
    "MultiBarBottomRightButton",
    "MultiBarRightButton",
    "MultiBarLeftButton",
}

local KEYBIND_BINDING_NAMES = {
    "ACTIONBUTTON",
    "MULTIACTIONBAR1BUTTON",
    "MULTIACTIONBAR2BUTTON",
    "MULTIACTIONBAR4BUTTON",
    "MULTIACTIONBAR3BUTTON",
}

-- =========================================================
-- 键位格式化
-- =========================================================

local function FormatCompact(raw)
    local s = raw:upper()
    s = s:gsub("STRG%-", "CTRL-")
    s = s:gsub("CONTROL%-", "CTRL-")
    s = s:gsub("%s+", "")

    local mods = ""
    if s:find("CTRL-", 1, true) then mods = mods .. "C" end
    if s:find("ALT-", 1, true) then mods = mods .. "A" end
    if s:find("SHIFT-", 1, true) then mods = mods .. "S" end
    if s:find("META-", 1, true) then mods = mods .. "M" end

    s = s:gsub("CTRL%-", "")
    s = s:gsub("ALT%-", "")
    s = s:gsub("SHIFT%-", "")
    s = s:gsub("META%-", "")

    s = s:gsub("MOUSEWHEELUP", "MU")
    s = s:gsub("MOUSEWHEELDOWN", "MD")
    s = s:gsub("MOUSEBUTTON(%d+)", "M%1")
    s = s:gsub("BUTTON(%d+)", "M%1")
    s = s:gsub("NUMPAD(%d+)", "N%1")
    s = s:gsub("NUMPADPLUS", "N+")
    s = s:gsub("NUMPADMINUS", "N-")
    s = s:gsub("NUMPADMULTIPLY", "N*")
    s = s:gsub("NUMPADDIVIDE", "N/")
    s = s:gsub("HOME", "HM")
    s = s:gsub("END", "ED")
    s = s:gsub("INSERT", "INS")
    s = s:gsub("DELETE", "DEL")
    s = s:gsub("PAGEUP", "PU")
    s = s:gsub("PAGEDOWN", "PD")
    s = s:gsub("SPACEBAR", "SP")
    s = s:gsub("BACKSPACE", "BS")
    s = s:gsub("CAPSLOCK", "CL")
    s = s:gsub("ESCAPE", "ESC")
    s = s:gsub("RETURN", "RT")
    s = s:gsub("ENTER", "RT")
    s = s:gsub("TAB", "TB")
    s = s:gsub("%+", "")
    return mods .. s
end

local function FormatKeyForDisplay(raw)
    if not raw or raw == "" then return "" end
    return FormatCompact(raw)
end

-- =========================================================
-- 构建技能ID到键位的映射
-- =========================================================

local function BuildSpellToKeyMap()
    local map = {}

    local function add(spellID, key)
        if spellID and spellID > 0 and key and key ~= "" then
            map[spellID] = key
        end
    end

    local function ProcessSlot(slot, key)
        if not key then return end
        local kind, id, subType = GetActionInfo(slot)
        if kind == "spell" and id then
            add(id, key)
            local override = C_Spell and C_Spell.GetOverrideSpell and C_Spell.GetOverrideSpell(id)
            if override then add(override, key) end
        elseif kind == "macro" and id then
            if subType == "spell" then
                add(id, key)
                local override = C_Spell and C_Spell.GetOverrideSpell and C_Spell.GetOverrideSpell(id)
                if override then add(override, key) end
            else
                local macroSpell = GetMacroSpell and GetMacroSpell(id)
                if macroSpell then
                    add(macroSpell, key)
                    local override = C_Spell and C_Spell.GetOverrideSpell and C_Spell.GetOverrideSpell(macroSpell)
                    if override then add(override, key) end
                end
            end
        end
    end

    -- 标准动作条
    for barIdx, prefix in ipairs(KEYBIND_BAR_PREFIXES) do
        local bindPrefix = KEYBIND_BINDING_NAMES[barIdx]
        for i = 1, 12 do
            local btn = _G[prefix .. i]
            if btn and btn.action then
                local slot = btn.action
                local cmd = bindPrefix .. i
                local key = GetBindingKey(cmd)
                ProcessSlot(slot, key)
            end
        end
    end

    -- ElvUI支持
    if _G["ElvUI_Bar1Button1"] then
        for i = 1, 15 do
            local barName = "ElvUI_Bar" .. i .. "Button"
            for j = 1, 12 do
                local btn = _G[barName .. j]
                if btn and btn.action and btn.config and btn.config.keyBoundTarget then
                    local slot = btn.action
                    local key = GetBindingKey(btn.config.keyBoundTarget)
                    ProcessSlot(slot, key)
                end
            end
        end
    end

    return map
end

-- =========================================================
-- 公共API
-- =========================================================

-- 获取技能ID从图标
function Keybind.GetSpellIDFromIcon(icon)
    if icon.cooldownID and C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCooldownInfo then
        local info = C_CooldownViewer.GetCooldownViewerCooldownInfo(icon.cooldownID)
        if info and info.spellID then
            return info.spellID
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

    -- 重建缓存（如果需要）
    if next(spellToKeyCache) == nil then
        spellToKeyCache = BuildSpellToKeyMap()
    end

    local rawKey = FindKeyForSpell(spellID, spellToKeyCache)
    return FormatKeyForDisplay(rawKey)
end

-- 使缓存失效
function Keybind.InvalidateCache()
    spellToKeyCache = {}
end

-- =========================================================
-- 事件监听：动作条变化时刷新缓存
-- =========================================================

VFlow.on("ACTIONBAR_SLOT_CHANGED", "VFlow.Keybind", function()
    Keybind.InvalidateCache()
end)

VFlow.on("UPDATE_BINDINGS", "VFlow.Keybind", function()
    Keybind.InvalidateCache()
end)
