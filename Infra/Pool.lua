-- =========================================================
-- VFlow Pool - 帧池系统
-- =========================================================

local VFlow = _G.VFlow

local Pool = {}
VFlow.Pool = Pool

local pools = {}

-- 供 getStats 统计活跃对象
local activeTracker = {}

-- =========================================================
-- 标准重置：归还帧时清理所有状态，确保下次 acquire 得到干净帧
-- =========================================================

local function StandardReset(pool, frame)
    frame:Hide()
    frame:ClearAllPoints()
    frame:SetParent(UIParent)
    frame:SetAlpha(1)
    frame:SetScale(1)

    frame:SetScript("OnUpdate", nil)
    frame:SetScript("OnEnter", nil)
    frame:SetScript("OnLeave", nil)
    frame:SetScript("OnMouseDown", nil)
    frame:SetScript("OnMouseUp", nil)
    frame:SetScript("OnSizeChanged", nil)

    if frame.IsObjectType and frame:IsObjectType("Button") then
        frame:SetScript("OnClick", nil)
    end

    if frame.SetText then
        frame:SetText("")
    end

    if frame.label and frame.label.SetText then
        frame.label:SetText("")
        frame.label:SetTextColor(1, 1, 1, 1)
    end

    if frame.labelText and frame.labelText.SetText then
        frame.labelText:SetText("")
    end

    if frame.valueText and frame.valueText.SetText then
        frame.valueText:SetText("")
    end

    if frame.text and frame.text.SetText then
        frame.text:SetText("")
        frame.text:SetTextColor(1, 1, 1, 1)
    end

    if frame.bg then
        frame.bg:Hide()
        frame.bg:SetColorTexture(0, 0, 0, 0)
    end

    if frame.icon then
        frame.icon:SetTexture(nil)
        frame.icon:SetDesaturated(false)
        frame.icon:SetAlpha(1)
        frame.icon:Hide()
    end

    if frame.checkbox then
        frame.checkbox:SetChecked(false)
        frame.checkbox:SetScript("OnClick", nil)
    end

    if frame.slider then
        frame.slider:SetScript("OnValueChanged", nil)
        frame.slider:SetScript("OnMouseDown", nil)
        frame.slider:SetScript("OnMouseUp", nil)
        if frame.fill then
            frame.fill:SetColorTexture(0.25, 0.52, 0.95, 0.8)
            frame.fill:Show()
            frame.fill:SetWidth(1)
        end
        if frame.thumb then
            frame.thumb:SetColorTexture(0.25, 0.52, 0.95, 1)
        end
    end

    if frame.editBox then
        frame.editBox:SetText("")
        frame.editBox:SetNumeric(false)
        frame.editBox:SetScript("OnEnterPressed", nil)
        frame.editBox:SetScript("OnEditFocusLost", nil)
        frame.editBox:SetScript("OnEscapePressed", nil)
        frame.editBox:ClearFocus()
    end

    if frame.dropdown then
        frame.dropdown._items = nil
        frame.dropdown._value = nil
        frame.dropdown._onChange = nil
        if frame.dropdown.menu then
            frame.dropdown.menu:Hide()
            if frame.dropdown.menu.items then
                for _, item in ipairs(frame.dropdown.menu.items) do
                    item:Hide()
                    item:ClearAllPoints()
                    item:SetScript("OnClick", nil)
                end
            end
        end
    end

    if frame.swatch then
        frame.swatch:SetColorTexture(1, 1, 1, 1)
        frame.button:SetScript("OnClick", nil)
        frame.button:SetScript("OnEnter", nil)
        frame.button:SetScript("OnLeave", nil)
    end

    if frame.hexText and frame.hexText.SetText then
        frame.hexText:SetText("")
    end

    if frame.preview then
        frame.preview:Hide()
        frame.preview:SetTexture(nil)
        frame.preview:SetColorTexture(0, 0, 0, 0)
        frame.searchBox:SetText("")
        if frame.menu then
            frame.menu:Hide()
            if frame.menu.items then
                for _, item in ipairs(frame.menu.items) do
                    item:Hide()
                    item:ClearAllPoints()
                    item:SetScript("OnClick", nil)
                end
            end
        end
    end

    if frame.blocker then
        frame.blocker:SetScript("OnClick", nil)
    end
    if frame.confirmButton then
        frame.confirmButton:SetScript("OnClick", nil)
        frame.confirmButton:SetScript("OnEnter", nil)
        frame.confirmButton:SetScript("OnLeave", nil)
    end
    if frame.cancelButton then
        frame.cancelButton:SetScript("OnClick", nil)
        frame.cancelButton:SetScript("OnEnter", nil)
        frame.cancelButton:SetScript("OnLeave", nil)
        frame.cancelButton:Show()
    end
    if frame.closeButton then
        frame.closeButton:SetScript("OnClick", nil)
        frame.closeButton:SetScript("OnEnter", nil)
        frame.closeButton:SetScript("OnLeave", nil)
    end
    if frame.titleText and frame.titleText.SetText then
        frame.titleText:SetText("")
    end
    if frame.messageText and frame.messageText.SetText then
        frame.messageText:SetText("")
    end
    if frame.confirmText and frame.confirmText.SetText then
        frame.confirmText:SetText("")
    end
    if frame.cancelText and frame.cancelText.SetText then
        frame.cancelText:SetText("")
    end
    frame._onConfirm = nil
    frame._onCancel = nil
    frame._closeOnOutside = nil

    -- VFlowInteractiveText：回收文本片段到内部池
    if frame.segments then
        frame._segmentButtonPool = frame._segmentButtonPool or {}
        frame._segmentTextPool = frame._segmentTextPool or {}
        for _, segment in ipairs(frame.segments) do
            if segment.button then
                segment.button:Hide()
                segment.button:ClearAllPoints()
                segment.button:SetScript("OnClick", nil)
                segment.button:SetScript("OnEnter", nil)
                segment.button:SetScript("OnLeave", nil)
                table.insert(frame._segmentButtonPool, segment.button)
            elseif segment.text then
                segment.text:Hide()
                segment.text:ClearAllPoints()
                segment.text:SetText("")
                table.insert(frame._segmentTextPool, segment.text)
            end
            if segment.underline then
                segment.underline:Hide()
                segment.underline:ClearAllPoints()
            end
        end
        wipe(frame.segments)
    end

    -- 清理 VFlow 自定义属性
    VFlow.FDClear(frame)
    frame._vf_poolType = nil
    frame._config = nil
    frame._spellID = nil
    frame._data = nil
end

-- =========================================================
-- 池管理
-- =========================================================

function Pool.init(poolName, frameType, template, customInit)
    if pools[poolName] then
        print("|cffff8800VFlow警告:|r 池", poolName, "已存在，将被覆盖")
    end

    local blizzardPool = CreateFramePool(frameType, UIParent, template, StandardReset)

    pools[poolName] = {
        pool = blizzardPool,
        customInit = customInit,
        frameType = frameType,
        template = template,
        stats = {
            totalCreated = 0,
            totalAcquired = 0,
            totalReleased = 0,
        }
    }

    activeTracker[poolName] = {}
end

function Pool.acquire(poolName, parent)
    local poolData = pools[poolName]
    if not poolData then
        error("Pool.acquire: 池 " .. poolName .. " 不存在，请先调用Pool.init", 2)
    end

    local frame, isNew = poolData.pool:Acquire()

    frame._fromPool = poolName

    if isNew and poolData.customInit then
        local ok, err = pcall(poolData.customInit, frame)
        if not ok then
            print(string.format("|cffff0000VFlow错误:|r 池 [%s] 初始化失败: %s", poolName, tostring(err)))
        end
        poolData.stats.totalCreated = poolData.stats.totalCreated + 1
    end

    if parent then
        frame:SetParent(parent)
    end

    activeTracker[poolName][frame] = true
    poolData.stats.totalAcquired = poolData.stats.totalAcquired + 1

    return frame, isNew
end

function Pool.release(poolName, frame)
    if not frame then return end

    if not frame._fromPool then
        frame:Hide()
        frame:ClearAllPoints()
        frame:SetParent(nil)
        return
    end

    local framePoolName = frame._fromPool
    local poolData = pools[framePoolName]

    if not poolData then
        frame:Hide()
        frame:ClearAllPoints()
        frame:SetParent(nil)
        return
    end

    frame._fromPool = nil

    if activeTracker[framePoolName] then
        activeTracker[framePoolName][frame] = nil
    end

    poolData.stats.totalReleased = poolData.stats.totalReleased + 1
    poolData.pool:Release(frame)
end

function Pool.releaseAll(poolName)
    local poolData = pools[poolName]
    if not poolData then
        error("Pool.releaseAll: 池 " .. poolName .. " 不存在", 2)
    end

    poolData.pool:ReleaseAll()

    if activeTracker[poolName] then
        wipe(activeTracker[poolName])
    end
end

-- =========================================================
-- 预热与统计
-- =========================================================

function Pool.prewarm(poolName, count)
    local poolData = pools[poolName]
    if not poolData then
        error("Pool.prewarm: 池 " .. poolName .. " 不存在", 2)
    end

    local frames = {}
    for i = 1, count do
        local frame = Pool.acquire(poolName)
        table.insert(frames, frame)
    end

    for _, frame in ipairs(frames) do
        Pool.release(poolName, frame)
    end
end

function Pool.getStats(poolName)
    local poolData = pools[poolName]
    if not poolData then
        return { active = 0, created = 0, acquired = 0, released = 0, hitRate = 0 }
    end

    local active = poolData.pool:GetNumActive()
    local stats = poolData.stats

    local hitRate = 0
    if stats.totalAcquired > 0 then
        hitRate = math.floor((stats.totalAcquired - stats.totalCreated) / stats.totalAcquired * 100)
    end

    return {
        active = active,
        created = stats.totalCreated,
        acquired = stats.totalAcquired,
        released = stats.totalReleased,
        hitRate = hitRate
    }
end
