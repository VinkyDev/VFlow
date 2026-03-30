--[[ Core 依赖：
  - Core/CustomTTS.lua：自定义文字转语音/音效播报
  - Core/CooldownStyle.lua：自定义高亮规则与表单协同
  - Core/BuffScanner.lua、SkillScanner.lua：State 图标数据（只读）
  例外：播报/高亮子页内 State.watch 仅用于刷新图标网格列表。
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
    name = L["Other Features"],
    description = L["Announce & highlight extensions"],
})

-- =========================================================
-- SECTION 2: 默认配置
-- =========================================================

local defaults = {
    ttsAliases = {},
    ttsForm = {
        spellId = "",
        mode = "text",
        text = "",
        sound = "",
        soundChannel = "Master",
    },
    highlightRules = {},
    highlightOnlyInCombat = true,
    highlightForm = {
        spellId = "",
        source = "",
        enabled = false,
    },
}

local db = VFlow.getDB(MODULE_KEY, defaults)

local MODE_ITEMS = {
    { L["Text-to-speech"], "text" },
    { L["Custom sound"], "sound" },
}

local CHANNEL_ITEMS = {
    { L["Master"], "Master" },
    { L["SFX"], "SFX" },
    { L["Ambience"], "Ambience" },
    { L["Music"], "Music" },
    { L["Dialog"], "Dialog" },
}

local PRIMARY_COLOR = { 0.2, 0.6, 1, 1 }
local CONFIGURED_COLOR = { 0.2, 0.85, 0.3, 1 }

-- =========================================================
-- SECTION 3: 扫描链接（播报 / 高亮共用）
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

-- =========================================================
-- SECTION 4: 播报 — 工具与表单
-- =========================================================

local function normalizeEntry(entry)
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

local function hasAlias(spellID)
    local a = db.ttsAliases or {}
    return normalizeEntry(a[spellID] or a[tostring(spellID)]) ~= nil
end

local function selectedSpellId(cfg)
    return tonumber(cfg.ttsForm and cfg.ttsForm.spellId)
end

local function applyAliasToForm(spellID)
    local f = db.ttsForm
    f.spellId = tostring(spellID)
    local raw = (db.ttsAliases or {})[spellID] or (db.ttsAliases or {})[tostring(spellID)]
    local norm = normalizeEntry(raw)
    if norm then
        f.mode = norm.mode
        f.text = norm.text
        f.sound = norm.sound
        f.soundChannel = norm.soundChannel
    else
        f.mode = "text"
        f.text = ""
        f.sound = ""
        f.soundChannel = "Master"
    end
    VFlow.Store.set(MODULE_KEY, "ttsForm", f)
end

-- =========================================================
-- SECTION 5: 高亮 — 工具与表单（Core：CooldownStyle + StyleApply）
-- =========================================================

local function hasHighlightRule(spellID)
    local form = db.highlightForm
    local formSid = form and tonumber(form.spellId)
    if formSid == spellID then
        return form.enabled == true
    end
    local raw = (db.highlightRules or {})[spellID] or (db.highlightRules or {})[tostring(spellID)]
    return type(raw) == "table" and raw.enabled == true
end

local function normalizeHighlightSource(src)
    if src == "buff" then return "buff" end
    return "skill"
end

local function selectedHighlightSpellId(cfg)
    return tonumber(cfg.highlightForm and cfg.highlightForm.spellId)
end

local function applyHighlightForm(spellID, source)
    local f = db.highlightForm
    local prevSid = tonumber(f and f.spellId)
    -- 切换选中法术前，把上一行的编辑结果写回持久化规则（避免只靠 Core 在监听里反写 Store）
    if prevSid and prevSid > 0 and prevSid ~= spellID then
        VFlow.Store.set(MODULE_KEY, "highlightRules." .. prevSid, {
            enabled = f.enabled == true,
            source = normalizeHighlightSource(f.source),
        })
    end
    f.spellId = tostring(spellID)
    f.source = source
    local r = (db.highlightRules or {})[spellID] or (db.highlightRules or {})[tostring(spellID)]
    f.enabled = type(r) == "table" and r.enabled == true
    if type(r) == "table" and r.source then
        f.source = normalizeHighlightSource(r.source)
    end
    VFlow.Store.set(MODULE_KEY, "highlightForm", f)
end

-- =========================================================
-- SECTION 6: 技能 / BUFF 图标数据源
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
    local tracked = VFlow.State.get("trackedBuffs") or {}
    for spellID, info in pairs(tracked) do
        items[#items + 1] = {
            spellID = spellID,
            name = info.name,
            icon = info.icon,
        }
    end
    Utils.sortByName(items)
    return items
end

local function ttsIconTemplate()
    return {
        type = "iconButton",
        size = 32,
        icon = function(d)
            return d.icon
        end,
        borderColor = function(d)
            local sid = selectedSpellId(db)
            if sid and d.spellID == sid then
                return PRIMARY_COLOR
            elseif hasAlias(d.spellID) then
                return CONFIGURED_COLOR
            end
            return nil
        end,
        tooltip = function(d)
            return function(tip)
                tip:SetSpellByID(d.spellID)
                if hasAlias(d.spellID) then
                    tip:AddLine("|cff33dd55" .. L["Announce configured"] .. "|r", 1, 1, 1, true)
                end
                tip:AddLine("|cff00ff00" .. L["Click to edit"] .. "|r", 1, 1, 1, true)
            end
        end,
        onClick = function(d)
            applyAliasToForm(d.spellID)
        end,
    }
end

local function highlightIconTemplate(sourceKind)
    return {
        type = "iconButton",
        size = 32,
        icon = function(d)
            return d.icon
        end,
        borderColor = function(d)
            local sid = selectedHighlightSpellId(db)
            if sid and d.spellID == sid then
                return PRIMARY_COLOR
            elseif hasHighlightRule(d.spellID) then
                return CONFIGURED_COLOR
            end
            return nil
        end,
        tooltip = function(d)
            return function(tip)
                tip:SetSpellByID(d.spellID)
                if hasHighlightRule(d.spellID) then
                    tip:AddLine("|cff33dd55" .. L["Highlight configured"] .. "|r", 1, 1, 1, true)
                end
                tip:AddLine("|cff00ff00" .. L["Click to edit"] .. "|r", 1, 1, 1, true)
            end
        end,
        onClick = function(d)
            applyHighlightForm(d.spellID, sourceKind)
        end,
    }
end

-- =========================================================
-- SECTION 7: 顶部说明 + 双列表（播报 / 高亮共用结构）
-- =========================================================

local function buildSharedTopAndIconGrid(titleText, introText, legendText, forDependsOn, skillTemplate, buffTemplate)
    return {
        { type = "title", text = titleText, cols = 24 },
        { type = "spacer", height = 6, cols = 24 },
        {
            type = "interactiveText",
            cols = 24,
            text = introText,
            links = getScanLinks(),
        },
        { type = "spacer", height = 6, cols = 24 },
        {
            type = "description",
            cols = 24,
            text = legendText,
        },
        { type = "spacer", height = 8, cols = 24 },
        { type = "subtitle", text = L["Skills"], cols = 24 },
        { type = "separator", cols = 24 },
        {
            type = "for",
            cols = 2,
            dependsOn = forDependsOn,
            dataSource = buildSkillIconRows,
            template = skillTemplate,
        },
        { type = "spacer", height = 8, cols = 24 },
        { type = "subtitle", text = L["BUFF"], cols = 24 },
        { type = "separator", cols = 24 },
        {
            type = "for",
            cols = 2,
            dependsOn = forDependsOn,
            dataSource = buildBuffIconRows,
            template = buffTemplate,
        },
        { type = "spacer", height = 10, cols = 24 },
    }
end

-- =========================================================
-- SECTION 8: 播报 — 底部配置
-- =========================================================

local function buildTtsSelectedConfigLayout()
    return {
        {
            type = "description",
            cols = 24,
            dependsOn = "ttsForm.spellId",
            text = function(cfg)
                local sid = selectedSpellId(cfg)
                if not sid then
                    return ""
                end
                local si = C_Spell.GetSpellInfo(sid)
                local name = si and si.name or ("?" .. tostring(sid))
                return "|cff88ccff" .. name .. "|r  |cffaaaaaa#" .. tostring(sid) .. "|r"
            end,
        },
        { type = "separator", cols = 24 },
        {
            type = "dropdown",
            key = "ttsForm.mode",
            label = L["Announce method"],
            cols = 8,
            items = MODE_ITEMS,
        },
        {
            type = "if",
            dependsOn = { "ttsForm.mode" },
            condition = function(cfg)
                return (cfg.ttsForm and cfg.ttsForm.mode) == "text"
            end,
            children = {
                { type = "input", key = "ttsForm.text", label = L["Speak content"], cols = 16 },
            },
        },
        {
            type = "if",
            dependsOn = { "ttsForm.mode" },
            condition = function(cfg)
                return (cfg.ttsForm and cfg.ttsForm.mode) == "sound"
            end,
            children = {
                { type = "input", key = "ttsForm.sound", label = L["Sound path"], cols = 16 },
                {
                    type = "description",
                    cols = 24,
                    text = "|cff888888" .. L["Sound path example: Interface\\AddOns\\VFlow\\Sounds\\alert.ogg"] .. "|r",
                },
                {
                    type = "dropdown",
                    key = "ttsForm.soundChannel",
                    label = L["Sound channel"],
                    cols = 14,
                    items = CHANNEL_ITEMS,
                },
            },
        },
        { type = "spacer", height = 6, cols = 24 },
        {
            type = "button",
            text = L["Save"],
            cols = 12,
            onClick = function(cfg)
                local sid = selectedSpellId(cfg)
                if not sid then
                    return
                end
                local f = cfg.ttsForm
                VFlow.Store.set(MODULE_KEY, "ttsAliases." .. sid, {
                    mode = f.mode,
                    text = f.text or "",
                    sound = f.sound or "",
                    soundChannel = f.soundChannel or "Master",
                })
            end,
        },
        {
            type = "button",
            text = L["Clear config"],
            cols = 12,
            onClick = function(cfg)
                local sid = selectedSpellId(cfg)
                if not sid then
                    return
                end
                if cfg.ttsAliases then
                    cfg.ttsAliases[sid] = nil
                    cfg.ttsAliases[tostring(sid)] = nil
                    VFlow.Store.set(MODULE_KEY, "ttsAliases", cfg.ttsAliases)
                end
                applyAliasToForm(sid)
            end,
        },
    }
end

local function buildFullTtsLayout()
    local top = buildSharedTopAndIconGrid(
        L["Custom Announce"],
        L["This feature overrides system TTS alerts. Enable TTS for target spell in {cooldown manager} first. {Scan Skills} or {Scan BUFFs} to update icons."],
        "|cff3399ff■|r " .. L["Current selection"] .. "  |cff33dd55■|r " .. L["Announce configured"],
        { "ttsAliases", "ttsForm.spellId" },
        ttsIconTemplate(),
        ttsIconTemplate()
    )

    local tail = {
        {
            type = "if",
            dependsOn = { "ttsForm.spellId" },
            condition = function(cfg)
                local sid = selectedSpellId(cfg)
                return sid == nil or sid <= 0
            end,
            children = {
                {
                    type = "description",
                    cols = 24,
                    text = "|cff888888" .. L["Click a skill or BUFF icon above, then set speak or sound."] .. "|r",
                },
            },
        },
        {
            type = "if",
            dependsOn = { "ttsForm.spellId", "ttsForm.mode" },
            condition = function(cfg)
                local sid = selectedSpellId(cfg)
                return sid ~= nil and sid > 0
            end,
            children = mergeLayouts({
                { type = "subtitle", text = L["Current spell"], cols = 24 },
                { type = "separator", cols = 24 },
            }, buildTtsSelectedConfigLayout()),
        },
    }

    return mergeLayouts(top, tail)
end

-- =========================================================
-- SECTION 9: 高亮 — 底部配置
-- =========================================================

local function buildHighlightSelectedConfigLayout()
    return {
        {
            type = "description",
            cols = 24,
            dependsOn = "highlightForm.spellId",
            text = function(cfg)
                local sid = selectedHighlightSpellId(cfg)
                if not sid then
                    return ""
                end
                local si = C_Spell.GetSpellInfo(sid)
                local name = si and si.name or ("?" .. tostring(sid))
                return "|cff88ccff" .. name .. "|r  |cffaaaaaa#" .. tostring(sid) .. "|r"
            end,
        },
        { type = "separator", cols = 24 },
        {
            type = "if",
            dependsOn = { "highlightForm.source" },
            condition = function(cfg)
                return (cfg.highlightForm and cfg.highlightForm.source) == "skill"
            end,
            children = {
                {
                    type = "checkbox",
                    key = "highlightForm.enabled",
                    label = L["Highlight when skill ready"],
                    cols = 24,
                },
            },
        },
        {
            type = "if",
            dependsOn = { "highlightForm.source" },
            condition = function(cfg)
                return (cfg.highlightForm and cfg.highlightForm.source) == "buff"
            end,
            children = {
                {
                    type = "checkbox",
                    key = "highlightForm.enabled",
                    label = L["Highlight when BUFF active"],
                    cols = 24,
                },
            },
        },
        {
            type = "description",
            cols = 24,
            text = "|cff888888" .. L["Highlight style matches Style → Glow"] .. "|r",
        },
    }
end

local function buildFullHighlightLayout()
    local top = buildSharedTopAndIconGrid(
        L["Custom Highlight"],
        L["Highlight icons when skill ready or BUFF active. Show spell/BUFF in cooldown manager first; list matches announce page. {Scan Skills} or {Scan BUFFs} to update."],
        "|cff3399ff■|r " .. L["Current selection"] .. "  |cff33dd55■|r " .. L["Highlight configured"],
        {
            "highlightRules",
            "highlightForm.spellId",
            "highlightForm.source",
            "highlightForm.enabled",
            "highlightOnlyInCombat",
        },
        highlightIconTemplate("skill"),
        highlightIconTemplate("buff")
    )

    local tail = {
        {
            type = "checkbox",
            key = "highlightOnlyInCombat",
            label = L["Highlight only in combat"],
            cols = 24,
        },
        {
            type = "if",
            dependsOn = { "highlightForm.spellId" },
            condition = function(cfg)
                local sid = selectedHighlightSpellId(cfg)
                return sid == nil or sid <= 0
            end,
            children = {
                {
                    type = "description",
                    cols = 24,
                    text = "|cff888888" .. L["Click a skill or BUFF icon above, then set highlight condition."] .. "|r",
                },
            },
        },
        {
            type = "if",
            dependsOn = { "highlightForm.spellId", "highlightForm.source", "highlightForm.enabled" },
            condition = function(cfg)
                local sid = selectedHighlightSpellId(cfg)
                return sid ~= nil and sid > 0 and cfg.highlightForm and (cfg.highlightForm.source == "skill" or cfg.highlightForm.source == "buff")
            end,
            children = mergeLayouts({
                { type = "subtitle", text = L["Current spell"], cols = 24 },
                { type = "separator", cols = 24 },
            }, buildHighlightSelectedConfigLayout()),
        },
    }

    return mergeLayouts(top, tail)
end

-- =========================================================
-- SECTION 10: 渲染入口
-- =========================================================

local function renderTtsPage(container)
    Grid.render(container, buildFullTtsLayout(), db, MODULE_KEY)

    local function refreshAll()
        Grid.refresh(container)
    end

    VFlow.State.watch("trackedSkills", "OtherFeatures.TTS.Skills", refreshAll)
    VFlow.State.watch("trackedUtilitySkills", "OtherFeatures.TTS.UtilitySkills", refreshAll)
    VFlow.State.watch("trackedBuffs", "OtherFeatures.TTS.Buffs", refreshAll)
end

local function renderHighlightPage(container)
    Grid.render(container, buildFullHighlightLayout(), db, MODULE_KEY)

    local function refreshAll()
        Grid.refresh(container)
    end

    VFlow.State.watch("trackedSkills", "OtherFeatures.Highlight.Skills", refreshAll)
    VFlow.State.watch("trackedUtilitySkills", "OtherFeatures.Highlight.UtilitySkills", refreshAll)
    VFlow.State.watch("trackedBuffs", "OtherFeatures.Highlight.Buffs", refreshAll)
end

local function renderContent(container, menuKey)
    if menuKey == "other_tts" then
        renderTtsPage(container)
    elseif menuKey == "other_highlight" then
        renderHighlightPage(container)
    end
end

-- =========================================================
-- SECTION 11: 公共接口
-- =========================================================

if not VFlow.Modules then
    VFlow.Modules = {}
end

VFlow.Modules.OtherFeatures = {
    renderContent = renderContent,
}
