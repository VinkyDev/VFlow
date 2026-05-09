--[[ Core 依赖：
  - Core/CustomTTS.lua：消费 ttsAliases，自定义文字转语音/音效播报
  - Core/Style/CooldownStyle.lua：消费 highlightRules，自定义高亮
  - Core/Style/StyleApply.lua：消费 skillRules，技能级隐藏增益剩余时间遮罩层
  - Core/Buff/BuffScanner.lua、Core/Skill/SkillScanner.lua：State 图标数据（只读）
  例外：技能/BUFF 子页内 State.watch 仅用于刷新图标网格列表。
]]

-- =========================================================
-- SECTION 1: 模块注册
-- =========================================================

local VFlow = _G.VFlow
if not VFlow then return end
local L = VFlow.L

local MODULE_KEY = "VFlow.OtherFeatures"
local Grid = VFlow.Grid
local Utils = VFlow.Utils
local mergeLayouts = Utils.mergeLayouts

VFlow.registerModule(MODULE_KEY, {
    name = "特殊设置",
    description = "技能与BUFF的自定义播报、高亮和技能遮罩层",
})

-- =========================================================
-- SECTION 2: 默认配置
-- =========================================================

local defaults = {
    ttsAliases = {},
    ttsForm = {
        spellId = "",
        enabled = false,
        mode = "text",
        text = "",
        sound = "",
        soundChannel = "Master",
    },
    highlightRules = {},
    highlightOnlyInCombat = true,
    highlightForm = {
        spellId = "",
        source = "skill",
        enabled = false,
    },
    skillRules = {},
    skillForm = {
        spellId = "",
        hideBuffCooldownOverlay = false,
    },
}

local db = VFlow.getDB(MODULE_KEY, defaults)

local MODE_ITEMS = {
    { L["Text-to-speech"], "text" },
    { L["Custom sound"],   "sound" },
}

local CHANNEL_ITEMS = {
    { L["Master"],   "Master" },
    { L["SFX"],      "SFX" },
    { L["Ambience"], "Ambience" },
    { L["Music"],    "Music" },
    { L["Dialog"],   "Dialog" },
}

local PRIMARY_COLOR = { 0.2, 0.6, 1, 1 }
local CONFIGURED_COLOR = { 0.2, 0.85, 0.3, 1 }

-- =========================================================
-- SECTION 3: 扫描链接与共享工具
-- =========================================================

local function getScanLinks()
    return {
        [L["Scan Skills"]] = function()
            if VFlow.SkillScanner then
                VFlow.SkillScanner.scan()
            end
        end,
        [L["Scan BUFFs"]] = function()
            if VFlow.BuffScanner then
                VFlow.BuffScanner.scan()
            end
        end,
        [L["cooldown manager"]] = function()
            VFlow.openCooldownManager()
        end,
    }
end

local function normalizeSource(source)
    if source == "buff" then
        return "buff"
    end
    return "skill"
end

local function normalizeTtsEntry(entry)
    if type(entry) ~= "table" or not entry.mode then
        return nil
    end

    return {
        mode = entry.mode,
        text = entry.text or "",
        sound = entry.sound or "",
        soundChannel = entry.soundChannel or "Master",
    }
end

local function normalizeHighlightRule(rule)
    if type(rule) ~= "table" then
        return nil
    end

    return {
        enabled = rule.enabled == true,
        source = normalizeSource(rule.source),
    }
end

local function normalizeSkillRule(rule)
    if type(rule) ~= "table" then
        return nil
    end

    return {
        hideBuffCooldownOverlay = rule.hideBuffCooldownOverlay == true,
    }
end

local function getSelectedSpellID(cfg)
    local form = cfg and cfg.ttsForm
    local spellID = tonumber(form and form.spellId)
    if spellID and spellID > 0 then
        return spellID
    end
    return nil
end

local function hasSelectedItem(cfg)
    return getSelectedSpellID(cfg) ~= nil
end

local function getSpellDisplayText(spellID)
    if not spellID then
        return ""
    end

    local info = C_Spell.GetSpellInfo(spellID)
    local name = info and info.name or ("?" .. tostring(spellID))
    return "|cff88ccff" .. name .. "|r  |cffaaaaaa#" .. tostring(spellID) .. "|r"
end

local function getTtsEntry(spellID)
    local aliases = db.ttsAliases or {}
    return normalizeTtsEntry(aliases[spellID] or aliases[tostring(spellID)])
end

local function hasTtsConfig(spellID)
    return getTtsEntry(spellID) ~= nil
end

local function getStoredHighlightRule(spellID)
    local rules = db.highlightRules or {}
    return normalizeHighlightRule(rules[spellID] or rules[tostring(spellID)])
end

local function getStoredSkillRule(spellID)
    local rules = db.skillRules or {}
    return normalizeSkillRule(rules[spellID] or rules[tostring(spellID)])
end

local function removeSkillRule(spellID)
    if not spellID then
        return
    end

    local rules = db.skillRules or {}
    if rules[spellID] == nil and rules[tostring(spellID)] == nil then
        return
    end

    rules[spellID] = nil
    rules[tostring(spellID)] = nil
    VFlow.Store.set(MODULE_KEY, "skillRules", rules)
end

local function setSkillRule(spellID, hideBuffCooldownOverlay)
    if not spellID then
        return
    end

    if hideBuffCooldownOverlay ~= true then
        removeSkillRule(spellID)
        return
    end

    local currentRule = getStoredSkillRule(spellID)
    if currentRule and currentRule.hideBuffCooldownOverlay == true then
        return
    end

    VFlow.Store.set(MODULE_KEY, "skillRules." .. spellID, {
        hideBuffCooldownOverlay = true,
    })
end

local function setHighlightRule(spellID, enabled, sourceKind)
    local normalizedSource = normalizeSource(sourceKind)
    local currentRule = getStoredHighlightRule(spellID)
    if currentRule
        and currentRule.enabled == (enabled == true)
        and currentRule.source == normalizedSource then
        return
    end

    VFlow.Store.set(MODULE_KEY, "highlightRules." .. spellID, {
        enabled = enabled == true,
        source = normalizedSource,
    })
end

local function getHighlightRuleForSource(spellID, sourceKind)
    local normalizedSource = normalizeSource(sourceKind)
    local rule = getStoredHighlightRule(spellID)
    if not rule or rule.enabled ~= true then
        return nil
    end
    if rule.source ~= normalizedSource then
        return nil
    end

    return rule
end

local function hasHighlightConfig(spellID, sourceKind)
    return getHighlightRuleForSource(spellID, sourceKind) ~= nil
end

local function hasSkillMaskConfig(spellID)
    local rule = getStoredSkillRule(spellID)
    return rule and rule.hideBuffCooldownOverlay == true or false
end

local function hasAnyConfig(spellID, sourceKind)
    return hasTtsConfig(spellID)
        or hasHighlightConfig(spellID, sourceKind)
        or (normalizeSource(sourceKind) == "skill" and hasSkillMaskConfig(spellID))
end

local function getCurrentTtsFormSpellID()
    return tonumber(db.ttsForm and db.ttsForm.spellId)
end

local function sameTtsForm(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then
        return false
    end
    return tostring(a.spellId or "") == tostring(b.spellId or "")
        and (a.enabled == true) == (b.enabled == true)
        and tostring(a.mode or "") == tostring(b.mode or "")
        and tostring(a.text or "") == tostring(b.text or "")
        and tostring(a.sound or "") == tostring(b.sound or "")
        and tostring(a.soundChannel or "") == tostring(b.soundChannel or "")
end

local function loadTtsForm(spellID)
    local entry = getTtsEntry(spellID)
    local nextForm = {
        spellId = tostring(spellID or ""),
        enabled = entry ~= nil,
        mode = entry and entry.mode or "text",
        text = entry and entry.text or "",
        sound = entry and entry.sound or "",
        soundChannel = entry and entry.soundChannel or "Master",
    }
    if sameTtsForm(db.ttsForm, nextForm) then
        return
    end
    VFlow.Store.set(MODULE_KEY, "ttsForm", nextForm)
end

local function sameHighlightForm(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then
        return false
    end
    return tostring(a.spellId or "") == tostring(b.spellId or "")
        and normalizeSource(a.source) == normalizeSource(b.source)
        and (a.enabled == true) == (b.enabled == true)
end

local function sameSkillForm(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then
        return false
    end
    return tostring(a.spellId or "") == tostring(b.spellId or "")
        and (a.hideBuffCooldownOverlay == true) == (b.hideBuffCooldownOverlay == true)
end

local function loadHighlightForm(spellID, sourceKind)
    local normalizedSource = normalizeSource(sourceKind)
    local storedRule = getStoredHighlightRule(spellID)
    local nextForm = {
        spellId = tostring(spellID or ""),
        source = normalizedSource,
        enabled = storedRule
            and storedRule.enabled == true
            and storedRule.source == normalizedSource
            or false,
    }
    if sameHighlightForm(db.highlightForm, nextForm) then
        return
    end
    VFlow.Store.set(MODULE_KEY, "highlightForm", nextForm)
end

local function loadSkillForm(spellID)
    local rule = getStoredSkillRule(spellID)
    local nextForm = {
        spellId = tostring(spellID or ""),
        hideBuffCooldownOverlay = rule and rule.hideBuffCooldownOverlay == true or false,
    }
    if sameSkillForm(db.skillForm, nextForm) then
        return
    end
    VFlow.Store.set(MODULE_KEY, "skillForm", nextForm)
end

local function selectItem(spellID, sourceKind)
    local normalizedSource = normalizeSource(sourceKind)
    if getCurrentTtsFormSpellID() == spellID
        and normalizeSource(db.highlightForm and db.highlightForm.source) == normalizedSource then
        return
    end
    loadTtsForm(spellID)
    loadHighlightForm(spellID, normalizedSource)
    if normalizedSource == "skill" then
        loadSkillForm(spellID)
    end
end

local function removeTtsAlias(spellID)
    if not spellID then
        return
    end

    local aliases = db.ttsAliases or {}
    if aliases[spellID] == nil and aliases[tostring(spellID)] == nil then
        return
    end
    aliases[spellID] = nil
    aliases[tostring(spellID)] = nil
    VFlow.Store.set(MODULE_KEY, "ttsAliases", aliases)
end

local function syncSelectedTtsAlias()
    local spellID = getCurrentTtsFormSpellID()
    if not spellID or spellID <= 0 then
        return
    end

    local form = db.ttsForm or {}
    if form.enabled == true then
        VFlow.Store.set(MODULE_KEY, "ttsAliases." .. spellID, {
            mode = form.mode,
            text = form.text or "",
            sound = form.sound or "",
            soundChannel = form.soundChannel or "Master",
        })
    else
        removeTtsAlias(spellID)
    end
end

local function syncSelectedHighlightRule()
    local spellID = getCurrentTtsFormSpellID()
    if not spellID or spellID <= 0 then
        return
    end

    local form = db.highlightForm or {}
    setHighlightRule(spellID, form.enabled == true, form.source)
end

local function syncSelectedSkillRule()
    local spellID = getCurrentTtsFormSpellID()
    if not spellID or spellID <= 0 then
        return
    end

    local form = db.skillForm or {}
    setSkillRule(spellID, form.hideBuffCooldownOverlay == true)
end

-- =========================================================
-- SECTION 4: 技能 / BUFF 图标数据源
-- =========================================================

local function buildSkillIconRows()
    local merged = {}
    local trackedImportant = VFlow.State.get("trackedSkills") or {}
    local trackedUtility = VFlow.State.get("trackedUtilitySkills") or {}

    for spellID, info in pairs(trackedImportant) do
        merged[spellID] = info
    end
    for spellID, info in pairs(trackedUtility) do
        if not merged[spellID] then
            merged[spellID] = info
        end
    end

    local items = {}
    for spellID, info in pairs(merged) do
        items[#items + 1] = {
            spellID = spellID,
            name = info.name,
            icon = info.icon,
        }
    end

    Utils.sortByName(items)
    return items
end

local function buildBuffIconRows()
    local items = {}
    local trackedBuffs = VFlow.State.get("trackedBuffs") or {}

    for spellID, info in pairs(trackedBuffs) do
        items[#items + 1] = {
            spellID = spellID,
            name = info.name,
            icon = info.icon,
        }
    end

    Utils.sortByName(items)
    return items
end

local SOURCE_SPECS = {
    skill = {
        menuKey = "other_skill",
        title = L["Skills"],
        introText = L
        ["Tracked spell or BUFF must be shown in {cooldown manager} first. {Scan Skills} or {Scan BUFFs} to refresh the list."],
        emptyHint = "|cff888888点击上方技能图标后，可在下方同时配置该技能的自定义播报和自定义高亮。|r",
        highlightLabel = L["Highlight when skill ready"],
        dataSource = buildSkillIconRows,
        stateKeys = { "trackedSkills", "trackedUtilitySkills" },
    },
    buff = {
        menuKey = "other_buff",
        title = L["BUFF"],
        introText = L
        ["Tracked spell or BUFF must be shown in {cooldown manager} first. {Scan Skills} or {Scan BUFFs} to refresh the list."],
        emptyHint = "|cff888888点击上方BUFF图标后，可在下方同时配置该BUFF的自定义播报和自定义高亮。|r",
        highlightLabel = L["Highlight when BUFF active"],
        dataSource = buildBuffIconRows,
        stateKeys = { "trackedBuffs" },
    },
}

local function getSourceSpec(sourceKind)
    return SOURCE_SPECS[normalizeSource(sourceKind)]
end

-- =========================================================
-- SECTION 5: 页面布局
-- =========================================================

local function buildIconTemplate(sourceKind)
    return {
        type = "iconButton",
        size = 32,
        icon = function(data)
            return data.icon
        end,
        borderColor = function(data)
            local selectedSpellID = getSelectedSpellID(db)
            if selectedSpellID and data.spellID == selectedSpellID then
                return PRIMARY_COLOR
            end
            if hasAnyConfig(data.spellID, sourceKind) then
                return CONFIGURED_COLOR
            end
            return nil
        end,
        tooltip = function(data)
            return function(tip)
                tip:SetSpellByID(data.spellID)
                if hasTtsConfig(data.spellID) then
                    tip:AddLine("|cff33dd55已配置自定义播报|r", 1, 1, 1, true)
                end
                if hasHighlightConfig(data.spellID, sourceKind) then
                    tip:AddLine("|cff33dd55已配置自定义高亮|r", 1, 1, 1, true)
                end
                if normalizeSource(sourceKind) == "skill" and hasSkillMaskConfig(data.spellID) then
                    tip:AddLine("|cff33dd55已配置隐藏增益剩余时间遮罩层|r", 1, 1, 1, true)
                end
                tip:AddLine("|cff00ff00点击进行设置|r", 1, 1, 1, true)
            end
        end,
        onClick = function(data)
            selectItem(data.spellID, sourceKind)
        end,
    }
end

local function buildSelectedItemLayout(sourceKind)
    return {
        {
            type = "description",
            cols = 24,
            dependsOn = { "ttsForm.spellId" },
            text = function(cfg)
                local spellID = getSelectedSpellID(cfg)
                return getSpellDisplayText(spellID)
            end,
        },
        { type = "spacer", height = 6, cols = 24 },
    }
end

local function buildTtsSectionLayout()
    return {
        { type = "subtitle",  text = L["Custom Announce"], cols = 24 },
        { type = "separator", cols = 24 },
        {
            type = "interactiveText",
            cols = 24,
            text = L["Custom announce requires the spell to enable text-to-speech alert in {cooldown manager} first."],
            links = getScanLinks(),
        },
        {
            type = "checkbox",
            key = "ttsForm.enabled",
            label = L["Enable custom announce"],
            cols = 24,
            onChange = function()
                syncSelectedTtsAlias()
            end,
        },
        {
            type = "if",
            dependsOn = { "ttsForm.enabled" },
            condition = function(cfg)
                return cfg.ttsForm and cfg.ttsForm.enabled == true
            end,
            children = {
                {
                    type = "dropdown",
                    key = "ttsForm.mode",
                    label = L["Announce method"],
                    cols = 8,
                    items = MODE_ITEMS,
                    onChange = function()
                        syncSelectedTtsAlias()
                    end,
                },
                {
                    type = "if",
                    dependsOn = { "ttsForm.mode" },
                    condition = function(subCfg)
                        return (subCfg.ttsForm and subCfg.ttsForm.mode) == "text"
                    end,
                    children = {
                        {
                            type = "input",
                            key = "ttsForm.text",
                            label = L["Speak content"],
                            cols = 16,
                            onChange = function()
                                syncSelectedTtsAlias()
                            end,
                        },
                    },
                },
                {
                    type = "if",
                    dependsOn = { "ttsForm.mode" },
                    condition = function(subCfg)
                        return (subCfg.ttsForm and subCfg.ttsForm.mode) == "sound"
                    end,
                    children = {
                        {
                            type = "input",
                            key = "ttsForm.sound",
                            label = L["Sound path"],
                            cols = 16,
                            onChange = function()
                                syncSelectedTtsAlias()
                            end,
                        },
                        {
                            type = "description",
                            cols = 24,
                            text = "|cff888888" ..
                            L["Sound path example: Interface\\AddOns\\VFlow\\Sounds\\alert.ogg"] .. "|r",
                        },
                        {
                            type = "dropdown",
                            key = "ttsForm.soundChannel",
                            label = L["Sound channel"],
                            cols = 14,
                            items = CHANNEL_ITEMS,
                            onChange = function()
                                syncSelectedTtsAlias()
                            end,
                        },
                    },
                },
            },
        },
        { type = "spacer", height = 10, cols = 24 },
    }
end

local function buildHighlightSectionLayout(sourceKind)
    local spec = getSourceSpec(sourceKind)

    return {
        { type = "subtitle",  text = L["Custom Highlight"], cols = 24 },
        { type = "separator", cols = 24 },
        {
            type = "checkbox",
            key = "highlightForm.enabled",
            label = spec.highlightLabel,
            cols = 12,
            onChange = function()
                syncSelectedHighlightRule()
            end,
        },
        {
            type = "checkbox",
            key = "highlightOnlyInCombat",
            label = L["Highlight only in combat"],
            cols = 12,
        },
        {
            type = "description",
            cols = 24,
            text = "|cff888888" .. L["Highlight style matches Style → Glow"] .. "|r",
        },
    }
end

local function buildSkillMaskSectionLayout()
    return {
        { type = "subtitle",  text = L["Buff overlay behavior"], cols = 24 },
        { type = "separator", cols = 24 },
        {
            type = "checkbox",
            key = "skillForm.hideBuffCooldownOverlay",
            label = L["Hide buff remaining time overlay"],
            cols = 24,
            onChange = function()
                syncSelectedSkillRule()
            end,
        },
        {
            type = "description",
            cols = 24,
            text = "|cff888888" ..
            L["When enabled, this skill always keeps the cooldown swipe and timer on the spell itself."] .. "|r",
        },
        { type = "spacer", height = 10, cols = 24 },
    }
end

local function buildEntityPageLayout(sourceKind)
    local spec = getSourceSpec(sourceKind)

    local top = {
        { type = "title",  text = spec.title, cols = 24 },
        { type = "spacer", height = 6,        cols = 24 },
        {
            type = "interactiveText",
            cols = 24,
            text = spec.introText,
            links = getScanLinks(),
        },
        { type = "spacer",    height = 6, cols = 24 },
        {
            type = "description",
            cols = 24,
            text = "|cff3399ff■|r 当前选中  |cff33dd55■|r 已有播报或高亮配置",
        },
        { type = "spacer",    height = 8, cols = 24 },
        { type = "separator", cols = 24 },
        {
            type = "for",
            cols = 2,
            dependsOn = {
                "ttsAliases",
                "ttsForm.spellId",
                "highlightRules",
                "skillRules",
            },
            dataSource = spec.dataSource,
            template = buildIconTemplate(sourceKind),
        },
        { type = "spacer", height = 10, cols = 24 },
    }

    local tail = {
        {
            type = "if",
            dependsOn = { "ttsForm.spellId" },
            condition = function(cfg)
                return not hasSelectedItem(cfg)
            end,
            children = {
                {
                    type = "description",
                    cols = 24,
                    text = spec.emptyHint,
                },
            },
        },
        {
            type = "if",
            dependsOn = {
                "ttsAliases",
                "ttsForm.spellId",
                "ttsForm.mode",
                "highlightRules",
                "highlightForm.spellId",
                "highlightForm.source",
                "highlightForm.enabled",
                "skillRules",
                "skillForm.spellId",
                "skillForm.hideBuffCooldownOverlay",
                "highlightOnlyInCombat",
            },
            condition = function(cfg)
                return hasSelectedItem(cfg)
            end,
            children = mergeLayouts(
                buildSelectedItemLayout(sourceKind),
                buildTtsSectionLayout(),
                normalizeSource(sourceKind) == "skill" and buildSkillMaskSectionLayout(),
                buildHighlightSectionLayout(sourceKind)
            ),
        },
    }

    return mergeLayouts(top, tail)
end

-- =========================================================
-- SECTION 6: 渲染入口
-- =========================================================

local function bindStateRefresh(container, sourceKind)
    local spec = getSourceSpec(sourceKind)
    local ownerPrefix = "OtherFeatures." .. sourceKind .. "." .. tostring(container)
    local watchEntries = {}

    local pendingInitialCallbacks = #spec.stateKeys
    local function refreshAll()
        if pendingInitialCallbacks > 0 then
            pendingInitialCallbacks = pendingInitialCallbacks - 1
            return
        end
        if container and container:GetParent() then
            Grid.refresh(container)
        end
    end

    for _, stateKey in ipairs(spec.stateKeys) do
        local owner = ownerPrefix .. "." .. stateKey
        watchEntries[#watchEntries + 1] = {
            stateKey = stateKey,
            owner = owner,
        }
        VFlow.State.watch(stateKey, owner, refreshAll)
    end

    local previousDispose = container._vfOnDispose
    container._vfOnDispose = function(self)
        for _, entry in ipairs(watchEntries) do
            VFlow.State.unwatch(entry.stateKey, entry.owner)
        end
        if previousDispose then
            previousDispose(self)
        end
    end
end

local function renderEntityPage(container, sourceKind)
    Grid.render(container, buildEntityPageLayout(sourceKind), db, MODULE_KEY)
    bindStateRefresh(container, sourceKind)
end

local function renderContent(container, menuKey)
    if menuKey == "other_skill" then
        renderEntityPage(container, "skill")
    elseif menuKey == "other_buff" then
        renderEntityPage(container, "buff")
    end
end

-- =========================================================
-- SECTION 7: 公共接口
-- =========================================================

if not VFlow.Modules then
    VFlow.Modules = {}
end

VFlow.Modules.OtherFeatures = {
    renderContent = renderContent,
}
