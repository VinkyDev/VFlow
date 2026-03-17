-- =========================================================
-- VFlow CustomMonitorGroups - 自定义图形监控容器管理
-- 职责：为每个启用的自定义监控项创建可拖拽的条形容器
--
-- 生命周期权威方：所有容器的创建/销毁都经过此模块，
-- 完成后主动通知 CustomMonitorRuntime，消除竞争条件。
-- =========================================================

local VFlow = _G.VFlow
if not VFlow then return end

local MODULE_KEY = "VFlow.CustomMonitor"
local PP = VFlow.PixelPerfect  -- 完美像素工具

-- =========================================================
-- 模块状态
-- =========================================================

-- { ["skills"|"buffs"] = { [spellID] = frame } }
local _containers = {
    skills = {},
    buffs  = {},
}

-- =========================================================
-- 条形容器构建
-- =========================================================

local function createBarContainer(storeKey, spellID, cfg)
    local direction = cfg.barDirection or "horizontal"
    local length    = cfg.barLength    or 200
    local thickness = cfg.barThickness or 20
    local shape     = cfg.shape or "bar"

    local w, h
    if shape == "ring" then
        -- 环形：正方形
        local size = cfg.ringSize or 40
        w, h = size, size
    else
        -- 条形：根据方向
        w = (direction == "horizontal") and length or thickness
        h = (direction == "horizontal") and thickness or length
    end

    local name = string.format("VFlow_CM_%s_%d", storeKey, spellID)
    local container = CreateFrame("Frame", name, UIParent)
    container:SetFrameStrata("MEDIUM")
    container:SetFrameLevel(10)
    PP.SetSize(container, w, h)
    container:SetMovable(true)
    container:SetClampedToScreen(true)

    local x = cfg.x or 0
    local y = cfg.y or 0
    container:ClearAllPoints()
    container:SetPoint("CENTER", UIParent, "CENTER", x, y)

    -- 背景条（预览用，Runtime接管后隐藏）
    local bar = container:CreateTexture(nil, "BACKGROUND")
    bar:SetAllPoints()
    local c = cfg.barColor or { r = 0.2, g = 0.6, b = 1, a = 1 }
    -- 环形模式下不显示矩形背景
    if shape == "ring" then
        bar:SetColorTexture(0, 0, 0, 0)
    else
        bar:SetColorTexture(c.r, c.g, c.b, c.a * 0.7)
    end
    container._bar = bar

    -- 使用完美像素边框（环形模式下不显示边框）
    local borderThickness = tonumber(cfg.borderThickness) or 1
    local bc = cfg.borderColor or { r = 0.3, g = 0.3, b = 0.3, a = 1 }
    if shape ~= "ring" then
        PP.CreateBorder(container, borderThickness, bc, true)
    end

    -- 技能图标预览
    if cfg.showIcon then
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
        onPositionChanged = function(frame, point, nx, ny)
            local db = VFlow.getDB(MODULE_KEY)
            if db and db[storeKey] and db[storeKey][spellID] then
                db[storeKey][spellID].x = nx
                db[storeKey][spellID].y = ny
                VFlow.Store.set(MODULE_KEY, storeKey .. "." .. spellID .. ".x", nx)
                VFlow.Store.set(MODULE_KEY, storeKey .. "." .. spellID .. ".y", ny)
            end
        end,
    })

    return container
end

-- =========================================================
-- 容器生命周期（内部）
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
-- 辅助函数：校验技能/BUFF是否有效
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
-- 同步逻辑
-- =========================================================

-- 同步单个 storeKey（skills 或 buffs）的容器
local function syncStore(storeKey, store)
    if not store then return end

    -- 销毁不再启用的容器，或者虽启用但已失效（如切天赋导致不可用）的容器
    local toDestroy = {}
    for spellID in pairs(_containers[storeKey]) do
        local cfg = store[spellID]
        if not cfg or not cfg.enabled or not checkIsValid(storeKey, spellID) then
            toDestroy[#toDestroy + 1] = spellID
        end
    end
    for _, spellID in ipairs(toDestroy) do
        destroyContainer(storeKey, spellID)
    end

    -- 创建/更新启用且合法的容器
    for spellID, cfg in pairs(store) do
        if cfg.enabled then
            if checkIsValid(storeKey, spellID) then
                ensureContainer(storeKey, spellID, cfg)
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

-- =========================================================
-- 位置快速更新（不重建容器）
-- =========================================================

local function updatePosition(storeKey, spellID)
    local container = _containers[storeKey][spellID]
    if not container then return end

    local db = VFlow.getDB(MODULE_KEY)
    if not db or not db[storeKey] or not db[storeKey][spellID] then return end

    local cfg = db[storeKey][spellID]
    container:ClearAllPoints()
    container:SetPoint("CENTER", UIParent, "CENTER", cfg.x or 0, cfg.y or 0)
end

-- =========================================================
-- Store key 解析
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
-- 初始化与事件响应
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

-- =========================================================
-- 配置变更监听（唯一入口）
-- =========================================================

VFlow.Store.watch(MODULE_KEY, "CustomMonitorGroups", function(key, value)
    local storeKey, spellID = parseStoreKey(key)
    if not storeKey or not spellID then return end

    if key:find("%.x$") or key:find("%.y$") then
        updatePosition(storeKey, spellID)
        return
    end

    local db  = VFlow.getDB(MODULE_KEY)
    local cfg = db and db[storeKey] and db[storeKey][spellID]

    if key:find("%.enabled$") then
        if cfg and cfg.enabled and checkIsValid(storeKey, spellID) then
            ensureContainer(storeKey, spellID, cfg)
        else
            destroyContainer(storeKey, spellID)
        end
        return
    end

    if cfg and cfg.enabled and checkIsValid(storeKey, spellID) then
        ensureContainer(storeKey, spellID, cfg)
    end
end)
