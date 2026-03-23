-- =========================================================
-- SECTION 1: 模块入口
-- CustomTTS — Hook CooldownViewerAlert_PlayAlert
-- =========================================================

local VFlow = _G.VFlow
if not VFlow then return end

local Profiler = VFlow.Profiler

local MODULE_KEY = "VFlow.OtherFeatures"

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

local function tryInstallHook()
    if hookInstalled then
        return
    end
    if type(CooldownViewerAlert_PlayAlert) ~= "function" then
        return
    end

    hookInstalled = true

    hooksecurefunc("CooldownViewerAlert_PlayAlert", function(cooldownItem, _spellName, alert)
        Profiler.count("CTT:CooldownViewerAlert_PlayAlert")
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
        if not info then
            return
        end

        local spellID
        pcall(function()
            spellID = info.spellID
        end)
        if not spellID then
            return
        end

        local entry = aliases[spellID]
        if not entry then
            pcall(function()
                if info.overrideSpellID then
                    entry = aliases[info.overrideSpellID]
                end
            end)
        end
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
