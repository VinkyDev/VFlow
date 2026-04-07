-- =========================================================
-- SECTION 1: 模块入口
-- CustomTTS — Hook CooldownViewerAlert_PlayAlert
-- =========================================================

local VFlow = _G.VFlow
if not VFlow then return end

local Profiler = VFlow.Profiler

local MODULE_KEY = "VFlow.OtherFeatures"
local onCooldownViewerAlert

-- =========================================================
-- SECTION 2: Hook 与解析
-- =========================================================

local hookInstalled = false

local function resolveEntry(entry)
    if type(entry) ~= "table" or not entry.mode then
        return nil
    end
    return entry.mode,
        entry.text or "",
        entry.sound or "",
        entry.soundChannel or "Master"
end

--- 与 BuffScanner.ResolveSpellID 一致：BUFF 条目的主键常在 linkedSpellIDs[1]，spellID 可能为 0 或与配置不一致。
local function resolveBuffViewerSpellID(info)
    if not info then
        return nil
    end
    if info.linkedSpellIDs and info.linkedSpellIDs[1] then
        local lid = info.linkedSpellIDs[1]
        if type(lid) == "number" and lid > 0 then
            return lid
        end
    end
    local sid = info.overrideSpellID or info.spellID
    if type(sid) == "number" and sid > 0 then
        return sid
    end
    return nil
end

local function aliasRaw(aliases, spellID)
    if type(spellID) ~= "number" or spellID <= 0 then
        return nil
    end
    return aliases[spellID] or aliases[tostring(spellID)]
end

local function findAliasEntry(aliases, info)
    if type(aliases) ~= "table" or not info then
        return nil
    end

    local entry = aliasRaw(aliases, resolveBuffViewerSpellID(info))
    if entry then
        return entry
    end

    entry = aliasRaw(aliases, info.spellID)
    if entry then
        return entry
    end

    entry = aliasRaw(aliases, info.overrideSpellID)
    if entry then
        return entry
    end

    if info.linkedSpellIDs then
        for i = 1, #info.linkedSpellIDs do
            entry = aliasRaw(aliases, info.linkedSpellIDs[i])
            if entry then
                return entry
            end
        end
    end

    local function tryBase(sid)
        if type(sid) ~= "number" or sid <= 0 or not (C_Spell and C_Spell.GetBaseSpell) then
            return nil
        end
        local base = C_Spell.GetBaseSpell(sid)
        if base and base ~= sid then
            return aliasRaw(aliases, base)
        end
        return nil
    end

    return tryBase(resolveBuffViewerSpellID(info))
        or tryBase(info.spellID)
        or tryBase(info.overrideSpellID)
end

local function tryInstallHook()
    if hookInstalled then
        return
    end
    if type(CooldownViewerAlert_PlayAlert) ~= "function" then
        return
    end

    hookInstalled = true

    hooksecurefunc("CooldownViewerAlert_PlayAlert", function(cooldownItem, _spellName, alert)
        onCooldownViewerAlert(cooldownItem, _spellName, alert)
    end)
end

onCooldownViewerAlert = function(cooldownItem, _spellName, alert)
        local db = VFlow.getDBIfReady(MODULE_KEY)
        if not db then
            return
        end

        local aliases = db.ttsAliases
        if type(aliases) ~= "table" then
            return
        end

        if not (CooldownViewerAlert_GetPayload and CooldownViewerSound) then
            return
        end
        if CooldownViewerAlert_GetPayload(alert) ~= CooldownViewerSound.TextToSpeech then
            return
        end

        local info = cooldownItem and cooldownItem.cooldownInfo
        if not info and cooldownItem and cooldownItem.cooldownID
            and C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCooldownInfo then
            pcall(function()
                info = C_CooldownViewer.GetCooldownViewerCooldownInfo(cooldownItem.cooldownID)
            end)
        end
        if not info then
            return
        end

        local entry = findAliasEntry(aliases, info)
        if not entry then
            return
        end

        local mode, text, sound, channel = resolveEntry(entry)
        if not mode then
            return
        end

        C_VoiceChat.StopSpeakingText()

        if mode == "text" and text ~= "" then
            if TextToSpeechFrame_PlayCooldownAlertMessage then
                TextToSpeechFrame_PlayCooldownAlertMessage(alert, text, false)
            end
        elseif mode == "sound" and sound ~= "" then
            PlaySoundFile(sound, channel or "Master")
        end
end

if Profiler and Profiler.registerCount then
    Profiler.registerCount("CTT:CooldownViewerAlert_PlayAlert", function()
        return onCooldownViewerAlert
    end, function(fn)
        onCooldownViewerAlert = fn
    end)
end

-- =========================================================
-- SECTION 3: 延迟安装（CooldownViewer 加载后）
-- =========================================================

if EventUtil and EventUtil.ContinueOnAddOnLoaded then
    EventUtil.ContinueOnAddOnLoaded("Blizzard_CooldownViewer", tryInstallHook)
end

if _G.IsAddOnLoaded and IsAddOnLoaded("Blizzard_CooldownViewer") then
    tryInstallHook()
end
