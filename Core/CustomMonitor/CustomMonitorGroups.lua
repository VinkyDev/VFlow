-- =========================================================
-- SECTION 1: 模块入口
-- CustomMonitorGroups — 条形容器生命周期（通知 Runtime）
-- =========================================================

local VFlow = _G.VFlow
if not VFlow then return end

local Profiler = VFlow.Profiler

local MODULE_KEY = "VFlow.CustomMonitor"
local PP = VFlow.PixelPerfect  -- 完美像素工具
local Utils = VFlow.Utils

-- =========================================================
-- SECTION 2: 常量与模块状态
-- =========================================================

local VALID_STRATA = {
    BACKGROUND = true,
    LOW = true,
    MEDIUM = true,
    HIGH = true,
    DIALOG = true,
    FULLSCREEN = true,
    FULLSCREEN_DIALOG = true,
    TOOLTIP = true,
}

-- { ["skills"|"buffs"] = { [spellID] = frame } }
local _containers = {
    skills = {},
    buffs  = {},
}

local _lastSyncedEssWidth, _lastSyncedUtilWidth

-- =========================================================
-- SECTION 3: 条形容器构建
-- =========================================================

local CMG = {}

local function colKey(c)
    if not c then return "-" end
    return table.concat({ tostring(c.r), tostring(c.g), tostring(c.b), tostring(c.a) }, ";")
end

local function hasVisualOutput(cfg)
    return cfg and (cfg.showGraphics ~= false or cfg.showText ~= false)
end

--- 与 createBarContainer 一致：仅当这些字段变化时才需换外层 Frame
local function outerContainerSignature(cfg)
    local shape = cfg.shape or "bar"
    local borderThickness = tonumber(cfg.borderThickness) or 1
    local showPreviewIcon = cfg.showGraphics ~= false and cfg.showIcon and true or false
    return table.concat({
        shape,
        tostring(cfg.ringSize or 40),
        tostring(cfg.showGraphics ~= false),
        tostring(showPreviewIcon),
        tostring(cfg.iconSize or 20),
        tostring(cfg.iconPosition or "LEFT"),
        tostring(cfg.iconOffsetX or 0),
        tostring(cfg.iconOffsetY or 0),
        tostring(cfg.frameStrata or "MEDIUM"),
        tostring(borderThickness),
        colKey(cfg.borderColor),
        colKey(cfg.barColor or { r = 0.2, g = 0.6, b = 1, a = 1 }),
    }, "\031")
end

local function computeBarContainerDimensions(cfg)
    local direction = cfg.barDirection or "horizontal"
    local length = Utils.ResolveSyncedBarSpan(cfg, {
        manualKey = "barLength",
        modeKey = "barLengthMode",
        defaultMode = "manual",
    })
    local thickness = cfg.barThickness or 20
    local shape = cfg.shape or "bar"

    if shape == "ring" then
        local size = cfg.ringSize or 40
        return size, size
    end
    local w = (direction == "horizontal") and length or thickness
    local h = (direction == "horizontal") and thickness or length
    return w, h
end

local function createBarContainer(storeKey, spellID, cfg)
    local w, h = computeBarContainerDimensions(cfg)
    local shape = cfg.shape or "bar"
    local showGraphics = cfg.showGraphics ~= false

    local name = string.format("VFlow_CM_%s_%d", storeKey, spellID)
    local container = CreateFrame("Frame", name, UIParent)
    local strata = cfg.frameStrata
    if not VALID_STRATA[strata] then
        strata = "MEDIUM"
    end
    container:SetFrameStrata(strata)
    container:SetFrameLevel(10)
    PP.SetSize(container, w, h)
    container:SetMovable(true)
    container:SetClampedToScreen(true)

    VFlow.ContainerAnchor.ApplyFramePosition(container, cfg, nil)

    if showGraphics then
        local bar = container:CreateTexture(nil, "BACKGROUND")
        bar:SetAllPoints()
        local c = cfg.barColor or { r = 0.2, g = 0.6, b = 1, a = 1 }
        if shape == "ring" then
            bar:SetColorTexture(0, 0, 0, 0)
        else
            bar:SetColorTexture(c.r, c.g, c.b, c.a * 0.7)
        end
        container._bar = bar

        local borderThickness = tonumber(cfg.borderThickness) or 1
        local bc = cfg.borderColor or { r = 0.3, g = 0.3, b = 0.3, a = 1 }
        if shape ~= "ring" then
            PP.CreateBorder(container, borderThickness, bc, true)
        end
    end

    -- 技能图标预览
    if showGraphics and cfg.showIcon then
        local iconFrame = CreateFrame("Frame", nil, container)
        local iconSize = cfg.iconSize or 20
        iconFrame:SetSize(iconSize, iconSize)

        local pos = cfg.iconPosition or "LEFT"
        local ox  = cfg.iconOffsetX  or 0
        local oy  = cfg.iconOffsetY  or 0
        local iconAnchor, containerAnchor
        if     pos == "LEFT"  then iconAnchor, containerAnchor = "RIGHT",  "LEFT"
        elseif pos == "RIGHT" then iconAnchor, containerAnchor = "LEFT",   "RIGHT"
        elseif pos == "TOP"   then iconAnchor, containerAnchor = "BOTTOM", "TOP"
        else                       iconAnchor, containerAnchor = "TOP",    "BOTTOM"
        end
        iconFrame:SetPoint(iconAnchor, container, containerAnchor, ox, oy)

        local spellInfo = C_Spell.GetSpellInfo(spellID)
        if spellInfo and spellInfo.iconID then
            local iconTex = iconFrame:CreateTexture(nil, "ARTWORK")
            iconTex:SetAllPoints()
            iconTex:SetTexture(spellInfo.iconID)
            iconTex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        end
        container._iconFrame = iconFrame
    end

    local spellInfo = C_Spell.GetSpellInfo(spellID)
    local labelText = (spellInfo and spellInfo.name) or ("ID:" .. spellID)

    VFlow.DragFrame.register(container, {
        label = labelText,
        menuKey = storeKey == "skills" and "custom_spell" or "custom_buff",
        menuContext = { selectedID = spellID },
        getAnchorConfig = function()
            local db = VFlow.getDB(MODULE_KEY)
            local c = db and db[storeKey] and db[storeKey][spellID]
            return c
        end,
        suppressSystemEditPreview = function()
            local db = VFlow.getDB(MODULE_KEY)
            local c = db and db[storeKey] and db[storeKey][spellID]
            return c and c.hideInSystemEditMode
        end,
        onPositionChanged = function(_, kind, nx, ny)
            if kind ~= "PLAYER_ANCHOR" and kind ~= "SYMMETRIC" then return end
            local db = VFlow.getDB(MODULE_KEY)
            if db and db[storeKey] and db[storeKey][spellID] then
                db[storeKey][spellID].x = nx
                db[storeKey][spellID].y = ny
                VFlow.Store.set(MODULE_KEY, storeKey .. "." .. spellID .. ".x", nx)
                VFlow.Store.set(MODULE_KEY, storeKey .. "." .. spellID .. ".y", ny)
            end
        end,
    })

    if VFlow.DragFrame.applyRegisteredPosition then
        VFlow.DragFrame.applyRegisteredPosition(container)
    end

    container._vf_outerSig = outerContainerSignature(cfg)
    return container
end

-- =========================================================
-- SECTION 4: 容器生命周期
-- =========================================================

local function destroyContainer(storeKey, spellID)
    local container = _containers[storeKey][spellID]
    if not container then return end

    -- 先通知 Runtime 销毁其内容（此时容器帧仍有效）
    if VFlow.CustomMonitorRuntime then
        VFlow.CustomMonitorRuntime.onContainerDestroyed(storeKey, spellID)
    end

    VFlow.DragFrame.unregister(container)
    container:Hide()
    container:SetParent(nil)
    _containers[storeKey][spellID] = nil
end

local function ensureContainer(storeKey, spellID, cfg)
    if _containers[storeKey][spellID] then
        destroyContainer(storeKey, spellID)
    end

    local container = createBarContainer(storeKey, spellID, cfg)
    _containers[storeKey][spellID] = container

    -- 通知 Runtime 在新容器上建立内容
    if VFlow.CustomMonitorRuntime then
        VFlow.CustomMonitorRuntime.onContainerReady(storeKey, spellID, cfg, container)
    end

    return container
end

-- =========================================================
-- SECTION 5: 技能/BUFF 有效性校验
-- =========================================================

local function checkIsValid(storeKey, spellID)
    if storeKey == "skills" then
        local trackedSkills = VFlow.State.get("trackedSkills") or {}
        return (IsPlayerSpell and IsPlayerSpell(spellID)) 
            or (IsSpellKnown and IsSpellKnown(spellID)) 
            or (trackedSkills[spellID] ~= nil)
    elseif storeKey == "buffs" then
        local trackedBuffs = VFlow.State.get("trackedBuffs") or {}
        return trackedBuffs[spellID] ~= nil
    end
    return false
end

-- =========================================================
-- SECTION 6: 与 Store 同步
-- =========================================================

-- 同步单个 storeKey（skills 或 buffs）的容器
local function syncStore(storeKey, store)
    if not store then return end
    -- 销毁不再启用的容器，或者虽启用但已失效（如切天赋导致不可用）的容器
    local toDestroy = {}
    for spellID in pairs(_containers[storeKey]) do
        local cfg = store[spellID]
        if not cfg or not cfg.enabled or not hasVisualOutput(cfg) or not checkIsValid(storeKey, spellID) then
            toDestroy[#toDestroy + 1] = spellID
        end
    end
    for _, spellID in ipairs(toDestroy) do
        destroyContainer(storeKey, spellID)
    end

    -- 创建/更新启用且合法的容器
    for spellID, cfg in pairs(store) do
        if cfg.enabled and hasVisualOutput(cfg) then
            if checkIsValid(storeKey, spellID) then
                local cont = _containers[storeKey][spellID]
                if cont then
                    local sig = outerContainerSignature(cfg)
                    if cont._vf_outerSig ~= sig then
                        ensureContainer(storeKey, spellID, cfg)
                    elseif VFlow.CustomMonitorRuntime and VFlow.CustomMonitorRuntime.syncBarConfig then
                        VFlow.CustomMonitorRuntime.syncBarConfig(storeKey, spellID, cfg)
                    end
                else
                    ensureContainer(storeKey, spellID, cfg)
                end
            end
        end
    end
end

-- 全量同步（skills + buffs）
local function syncAll()
    if not VFlow.hasModule(MODULE_KEY) then return end
    local db = VFlow.getDB(MODULE_KEY)
    if not db then return end
    for _, storeKey in ipairs({ "skills", "buffs" }) do
        syncStore(storeKey, db[storeKey] or {})
    end
end

if Profiler and Profiler.registerScope then
    Profiler.registerScope(function(storeKey)
        return "CMG:syncStore:" .. tostring(storeKey)
    end, function()
        return syncStore
    end, function(fn)
        syncStore = fn
    end)
    Profiler.registerScope("CMG:syncAll", function()
        return syncAll
    end, function(fn)
        syncAll = fn
    end)
end

-- =========================================================
-- SECTION 7: 位置快速更新
-- =========================================================

local function updatePosition(storeKey, spellID)
    local container = _containers[storeKey][spellID]
    if not container then return end

    local db = VFlow.getDB(MODULE_KEY)
    if not db or not db[storeKey] or not db[storeKey][spellID] then return end

    local cfg = db[storeKey][spellID]
    VFlow.ContainerAnchor.ApplyFramePosition(container, cfg, nil)
    if VFlow.DragFrame and VFlow.DragFrame.applyRegisteredPosition then
        VFlow.DragFrame.applyRegisteredPosition(container)
    end
end

local function refreshContainerGeometry(storeKey, spellID, cfg)
    local container = _containers[storeKey][spellID]
    if not container or not cfg then return end

    local w, h = computeBarContainerDimensions(cfg)
    local cw, ch = container:GetSize()
    if (not cw or math.abs(cw - w) > 0.5) or (not ch or math.abs(ch - h) > 0.5) then
        PP.SetSize(container, w, h)
        if VFlow.CustomMonitorRuntime and VFlow.CustomMonitorRuntime.notifyContainerGeometryChanged then
            VFlow.CustomMonitorRuntime.notifyContainerGeometryChanged(storeKey, spellID)
        end
    end
    VFlow.ContainerAnchor.ApplyFramePosition(container, cfg, nil)
    if VFlow.DragFrame and VFlow.DragFrame.applyRegisteredPosition then
        VFlow.DragFrame.applyRegisteredPosition(container)
    end
end

function CMG.OnSkillViewerLayoutChanged()
    if not VFlow.hasModule(MODULE_KEY) then return end
    local db = VFlow.getDB(MODULE_KEY)
    if not db then return end
    local ew = _G.EssentialCooldownViewer and _G.EssentialCooldownViewer:GetWidth() or 0
    local uw = _G.UtilityCooldownViewer and _G.UtilityCooldownViewer:GetWidth() or 0
    if _lastSyncedEssWidth ~= nil and _lastSyncedUtilWidth ~= nil
        and math.abs(ew - _lastSyncedEssWidth) < 0.5
        and math.abs(uw - _lastSyncedUtilWidth) < 0.5 then
        return
    end
    _lastSyncedEssWidth = ew
    _lastSyncedUtilWidth = uw

    for _, storeKey in ipairs({ "skills", "buffs" }) do
        local store = db[storeKey]
        if store then
            for spellID, cfg in pairs(store) do
                if cfg.enabled and cfg.shape == "bar"
                    and (cfg.barLengthMode == "sync_essential" or cfg.barLengthMode == "sync_utility")
                    and checkIsValid(storeKey, spellID) then
                    refreshContainerGeometry(storeKey, spellID, cfg)
                end
            end
        end
    end
end

-- =========================================================
-- SECTION 8: Store key 解析
-- =========================================================

local function parseStoreKey(key)
    local sk, sid = key:match("^(skills)%.(%d+)")
    if not sk then
        sk, sid = key:match("^(buffs)%.(%d+)")
    end
    if sk and sid then return sk, tonumber(sid) end
    return nil, nil
end

-- =========================================================
-- SECTION 9: 初始化与事件
-- =========================================================

-- trackedSkills 变化：Scanner 扫描完成，同步技能容器
VFlow.State.watch("trackedSkills", "CustomMonitorGroups", function()
    if not VFlow.hasModule(MODULE_KEY) then return end
    local db = VFlow.getDB(MODULE_KEY)
    if not db or not db.skills then return end
    syncStore("skills", db.skills)
end)

-- trackedBuffs 变化：Scanner 扫描完成，同步 BUFF 容器
VFlow.State.watch("trackedBuffs", "CustomMonitorGroups", function()
    if not VFlow.hasModule(MODULE_KEY) then return end
    local db = VFlow.getDB(MODULE_KEY)
    if not db or not db.buffs then return end
    syncStore("buffs", db.buffs)
end)

-- 进入游戏/专精变更：容器同步完全由 Scanner 驱动（监听 State 变化），
-- 不再需要在此处手动设置 Timer，Scanner 完成扫描会自动触发同步。

-- 天赋变更：除了 Scanner 驱动外，还需要立即重新校验手动添加的技能（IsPlayerSpell 可能变化）
-- 使用 debounce 避免短时间内多次触发
local _traitUpdateTimer = nil
VFlow.on("TRAIT_CONFIG_UPDATED", "CustomMonitorGroups", function()
    if _traitUpdateTimer then _traitUpdateTimer:Cancel() end
    _traitUpdateTimer = C_Timer.NewTimer(0.2, function()
        syncAll()
        _traitUpdateTimer = nil
    end)
end)

-- Store.watch：细粒度配置变更（与 SECTION 9 中全量同步互补）
VFlow.Store.watch(MODULE_KEY, "CustomMonitorGroups", function(key, value)
    if key == "skills" or key == "buffs" then
        syncStore(key, value or {})
        return
    end

    local storeKey, spellID = parseStoreKey(key)
    if not storeKey or not spellID then return end

    if key:find("%.x$") or key:find("%.y$")
        or key:find("%.anchorFrame$") or key:find("%.relativePoint$") or key:find("%.playerAnchorPosition$") then
        updatePosition(storeKey, spellID)
        return
    end

    local db  = VFlow.getDB(MODULE_KEY)
    local cfg = db and db[storeKey] and db[storeKey][spellID]

    if key:find("%.barLength$") or key:find("%.barLengthMode$")
        or key:find("%.barThickness$") or key:find("%.barDirection$") then
        if cfg and cfg.enabled and hasVisualOutput(cfg) and checkIsValid(storeKey, spellID) then
            if _containers[storeKey][spellID] then
                refreshContainerGeometry(storeKey, spellID, cfg)
            else
                ensureContainer(storeKey, spellID, cfg)
            end
            return
        end
    end

    if key:find("%.enabled$") then
        if cfg and cfg.enabled and hasVisualOutput(cfg) and checkIsValid(storeKey, spellID) then
            local cont = _containers[storeKey][spellID]
            local sig = outerContainerSignature(cfg)
            if not cont then
                ensureContainer(storeKey, spellID, cfg)
            elseif cont._vf_outerSig ~= sig then
                ensureContainer(storeKey, spellID, cfg)
            elseif VFlow.CustomMonitorRuntime and VFlow.CustomMonitorRuntime.syncBarConfig then
                VFlow.CustomMonitorRuntime.syncBarConfig(storeKey, spellID, cfg)
            end
        else
            destroyContainer(storeKey, spellID)
        end
        return
    end

    if cfg and cfg.enabled and hasVisualOutput(cfg) and checkIsValid(storeKey, spellID) then
        local cont = _containers[storeKey][spellID]
        local sig = outerContainerSignature(cfg)
        if not cont then
            ensureContainer(storeKey, spellID, cfg)
        elseif cont._vf_outerSig ~= sig then
            ensureContainer(storeKey, spellID, cfg)
        elseif VFlow.CustomMonitorRuntime and VFlow.CustomMonitorRuntime.syncBarConfig then
            VFlow.CustomMonitorRuntime.syncBarConfig(storeKey, spellID, cfg)
        end
    else
        destroyContainer(storeKey, spellID)
    end
end)

VFlow.CustomMonitorGroups = CMG
