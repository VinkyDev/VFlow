-- =========================================================
-- VFlow Pool - 帧池系统
-- 职责：复用帧避免GC压力、重置帧状态
-- =========================================================

local VFlow = _G.VFlow
if not VFlow then
    error("VFlow.Pool: Core模块未加载")
end

local Pool = {}
VFlow.Pool = Pool

-- 池存储 { [poolName] = { pool, customInit, stats } }
local pools = {}

-- 活跃对象追踪表（供调试显示）
-- 结构: { [poolName] = { [frame] = true } }
local activeTracker = {}

-- =========================================================
-- 标准重置函数
-- =========================================================

--- 标准帧重置函数
-- @param pool FramePool 暴雪池对象
-- @param frame Frame 要重置的帧
local function StandardReset(pool, frame)
    -- 基础属性重置
    frame:Hide()
    frame:ClearAllPoints()
    frame:SetParent(UIParent)
    frame:SetAlpha(1)
    frame:SetScale(1)

    -- 清理脚本
    frame:SetScript("OnUpdate", nil)
    frame:SetScript("OnEnter", nil)
    frame:SetScript("OnLeave", nil)
    frame:SetScript("OnMouseDown", nil)
    frame:SetScript("OnMouseUp", nil)
    frame:SetScript("OnSizeChanged", nil)

    -- 按钮特有脚本
    if frame.IsObjectType and frame:IsObjectType("Button") then
        frame:SetScript("OnClick", nil)
    end

    -- 清理文本
    if frame.SetText then
        frame:SetText("")
    end

    -- 清理子元素（复合组件）
    -- 注意：不清除子元素的锚点，因为它们的锚点是固定的（在初始化时设置）
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

    -- VFlowButton特有：重置text和bg
    if frame.text and frame.text.SetText then
        frame.text:SetText("")
        frame.text:SetTextColor(1, 1, 1, 1)
        -- 注意：不清除text的锚点，因为不同用途的按钮锚点不同
        -- 使用方需要在acquire后明确设置锚点
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
            -- 清理菜单项
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
        -- 资源选择器清理逻辑
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

    -- VFlowInteractiveText特有：清理文本片段
    if frame.segments then
        for _, segment in ipairs(frame.segments) do
            if segment.button then
                segment.button:Hide()
                segment.button:ClearAllPoints()
                segment.button:SetScript("OnClick", nil)
                segment.button:SetScript("OnEnter", nil)
                segment.button:SetScript("OnLeave", nil)
            end
            if segment.text then
                segment.text:Hide()
                segment.text:ClearAllPoints()
                segment.text:SetText("")
            end
            if segment.underline then
                segment.underline:Hide()
                segment.underline:ClearAllPoints()
            end
        end
        wipe(frame.segments)
    end

    -- 清理VFlow自定义属性
    frame._vf_w = nil
    frame._vf_h = nil
    frame._vf_stack_size = nil
    frame._vf_stack_x = nil
    frame._vf_stack_y = nil
    frame._vf_poolType = nil
    frame._config = nil
    frame._spellID = nil
    frame._data = nil
end

-- =========================================================
-- 池管理
-- =========================================================

--- 初始化帧池
-- @param poolName string 池名称
-- @param frameType string 帧类型（如"Frame", "Button", "StatusBar"）
-- @param template string|nil 模板名称（可选）
-- @param customInit function|nil 初始化函数 function(frame)
function Pool.init(poolName, frameType, template, customInit)
    if type(poolName) ~= "string" then
        error("Pool.init: poolName必须是字符串", 2)
    end
    if type(frameType) ~= "string" then
        error("Pool.init: frameType必须是字符串", 2)
    end

    if pools[poolName] then
        print("|cffff8800VFlow警告:|r 池", poolName, "已存在，将被覆盖")
    end

    -- 使用暴雪CreateFramePool API
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

--- 从池中获取帧
-- @param poolName string 池名称
-- @param parent Frame|nil 父帧（可选）
-- @return Frame, boolean 帧实例, 是否新创建
function Pool.acquire(poolName, parent)
    if type(poolName) ~= "string" then
        error("Pool.acquire: poolName必须是字符串", 2)
    end

    local poolData = pools[poolName]
    if not poolData then
        error("Pool.acquire: 池 " .. poolName .. " 不存在，请先调用Pool.init", 2)
    end

    local frame, isNew = poolData.pool:Acquire()

    -- 标记来源池（防止误释放）
    frame._fromPool = poolName

    -- 如果是第一次创建，执行初始化逻辑
    if isNew and poolData.customInit then
        local ok, err = pcall(poolData.customInit, frame)
        if not ok then
            print(string.format("|cffff0000VFlow错误:|r 池 [%s] 初始化失败: %s", poolName, tostring(err)))
        end
        poolData.stats.totalCreated = poolData.stats.totalCreated + 1
    end

    -- 设置父帧
    if parent then
        frame:SetParent(parent)
    end

    -- 追踪活跃对象
    activeTracker[poolName][frame] = true

    -- 统计
    poolData.stats.totalAcquired = poolData.stats.totalAcquired + 1

    -- 注意：不自动调用Show()，让调用方决定何时显示
    -- 这样可以避免在属性设置完成前就显示帧
    return frame, isNew
end

--- 释放帧回池
-- @param poolName string 池名称
-- @param frame Frame 要释放的帧
function Pool.release(poolName, frame)
    if not frame then
        return -- 安全忽略nil
    end

    -- 检查是否来自池（防止误释放）
    if not frame._fromPool then
        -- 不是从池获取的，直接隐藏
        frame:Hide()
        frame:ClearAllPoints()
        frame:SetParent(nil)
        return
    end

    local framePoolName = frame._fromPool
    local poolData = pools[framePoolName]

    if not poolData then
        -- 池不存在，降级为隐藏
        frame:Hide()
        frame:ClearAllPoints()
        frame:SetParent(nil)
        return
    end

    -- 清除标记
    frame._fromPool = nil

    -- 移除追踪记录
    if activeTracker[framePoolName] then
        activeTracker[framePoolName][frame] = nil
    end

    -- 统计
    poolData.stats.totalReleased = poolData.stats.totalReleased + 1

    -- 归还到暴雪池
    poolData.pool:Release(frame)
end

--- 释放池中所有活跃帧
-- @param poolName string 池名称
function Pool.releaseAll(poolName)
    if type(poolName) ~= "string" then
        error("Pool.releaseAll: poolName必须是字符串", 2)
    end

    local poolData = pools[poolName]
    if not poolData then
        error("Pool.releaseAll: 池 " .. poolName .. " 不存在", 2)
    end

    poolData.pool:ReleaseAll()

    -- 清空追踪记录
    if activeTracker[poolName] then
        wipe(activeTracker[poolName])
    end
end

-- =========================================================
-- 预热与统计
-- =========================================================

--- 预热池（预分配帧）
-- @param poolName string 池名称
-- @param count number 预分配数量
function Pool.prewarm(poolName, count)
    if type(poolName) ~= "string" then
        error("Pool.prewarm: poolName必须是字符串", 2)
    end

    local poolData = pools[poolName]
    if not poolData then
        error("Pool.prewarm: 池 " .. poolName .. " 不存在", 2)
    end

    local frames = {}
    for i = 1, count do
        local frame = Pool.acquire(poolName)
        table.insert(frames, frame)
    end

    -- 立即释放回池
    for _, frame in ipairs(frames) do
        Pool.release(poolName, frame)
    end
end

--- 获取池统计信息
-- @param poolName string 池名称
-- @return table { active, created, acquired, released, hitRate }
function Pool.getStats(poolName)
    if type(poolName) ~= "string" then
        error("Pool.getStats: poolName必须是字符串", 2)
    end

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

--- 打印池状态
-- @param poolName string 池名称
function Pool.debugPool(poolName)
    if type(poolName) ~= "string" then
        error("Pool.debugPool: poolName必须是字符串", 2)
    end

    local poolData = pools[poolName]
    if not poolData then
        print("|cffff0000VFlow错误:|r 池", poolName, "不存在")
        return
    end

    local stats = Pool.getStats(poolName)

    print("|cff00ff00VFlow调试:|r 池", poolName, "状态:")
    print("  ", "类型:", poolData.frameType)
    print("  ", "模板:", poolData.template or "无")
    print("  ", "活跃:", stats.active)
    print("  ", "已创建:", stats.created)
    print("  ", "已获取:", stats.acquired)
    print("  ", "已释放:", stats.released)
    print("  ", "命中率:", stats.hitRate .. "%")
end

--- 打印所有池状态
function Pool.debugAll()
    print("|cff00ff00VFlow调试:|r 所有帧池:")
    for poolName, _ in pairs(pools) do
        Pool.debugPool(poolName)
    end
end

-- =========================================================
-- 预定义池类型（UI组件专用）
-- =========================================================

-- 1. 菜单按钮（Button + Texture + FontString）
Pool.init("VFlowButton", "Button", nil, function(btn)
    btn:SetSize(120, 24)

    -- Backdrop
    if not btn.SetBackdrop then
        Mixin(btn, BackdropTemplateMixin)
    end
    btn:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    btn:SetBackdropColor(0.15, 0.15, 0.15, 1)
    btn:SetBackdropBorderColor(0.25, 0.25, 0.25, 1)

    -- 文本
    local text = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    text:SetPoint("CENTER", 0, 0)
    btn:SetFontString(text)
    btn:SetNormalFontObject("GameFontHighlight")
    btn:SetHighlightFontObject("GameFontHighlight")
    btn.text = text
end)

-- 2. 通用容器（Frame + BackdropTemplate）
Pool.init("VFlowContainer", "Frame", "BackdropTemplate", function(f)
    f:SetSize(100, 100)
end)

-- 3. 滑块组件（Frame + Slider + EditBox + Texture）
Pool.init("VFlowSlider", "Frame", nil, function(container)
    container:SetHeight(50)

    -- Label (左上)
    local label = container:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    label:SetPoint("TOPLEFT", 0, -4)
    container.label = label

    -- Input Box (右上)
    local editBox = CreateFrame("EditBox", nil, container, "BackdropTemplate")
    editBox:SetPoint("TOPRIGHT", 0, -1)
    editBox:SetSize(46, 18)
    editBox:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    editBox:SetBackdropColor(0.1, 0.1, 0.1, 0.8)
    editBox:SetBackdropBorderColor(0.25, 0.25, 0.25, 1)
    editBox:SetFontObject("GameFontHighlightSmall")
    editBox:SetJustifyH("CENTER")
    editBox:SetAutoFocus(false)
    editBox:SetTextInsets(2, 2, 0, 0)
    container.editBox = editBox

    -- Track (Background) - 居中
    local track = CreateFrame("Frame", nil, container, "BackdropTemplate")
    -- 初始布局占位，实际在后面调整
    track:SetPoint("LEFT", 0, 0)
    track:SetPoint("RIGHT", 0, 0)
    track:SetPoint("TOP", 0, -25)
    track:SetHeight(8)
    track:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    track:SetBackdropColor(0.15, 0.15, 0.15, 1)
    track:SetBackdropBorderColor(0.25, 0.25, 0.25, 1)
    container.track = track

    -- Fill (Progress)
    local fill = track:CreateTexture(nil, "ARTWORK")
    fill:SetPoint("LEFT", 1, 0)
    fill:SetHeight(6)
    fill:SetWidth(1)
    fill:SetColorTexture(0.25, 0.52, 0.95, 0.8)
    container.fill = fill

    -- Slider Widget
    local slider = CreateFrame("Slider", nil, container)
    slider:SetAllPoints(track)
    slider:SetOrientation("HORIZONTAL")
    slider:SetHitRectInsets(-4, -4, -8, -8)
    container.slider = slider

    -- Thumb
    local thumb = slider:CreateTexture(nil, "OVERLAY")
    thumb:SetSize(10, 14)
    thumb:SetColorTexture(0.25, 0.52, 0.95, 1)
    slider:SetThumbTexture(thumb)
    container.thumb = thumb

    -- 微调按钮 (Minus)
    local minusBtn = CreateFrame("Button", nil, container)
    minusBtn:SetSize(16, 16)
    minusBtn:SetPoint("RIGHT", track, "LEFT", -4, 0)
    
    local minusIcon = minusBtn:CreateTexture(nil, "ARTWORK")
    minusIcon:SetAllPoints()
    minusIcon:SetTexture("Interface\\AddOns\\VFlow\\Assets\\Icons\\chevron_right")
    minusIcon:SetTexCoord(1, 0, 0, 1) -- 镜像翻转，使其变成向左箭头
    minusIcon:SetVertexColor(0.7, 0.7, 0.7, 1)
    minusBtn.icon = minusIcon
    
    minusBtn:SetScript("OnEnter", function(self) self.icon:SetVertexColor(1, 1, 1, 1) end)
    minusBtn:SetScript("OnLeave", function(self) self.icon:SetVertexColor(0.7, 0.7, 0.7, 1) end)
    container.minusBtn = minusBtn

    -- 微调按钮 (Plus)
    local plusBtn = CreateFrame("Button", nil, container)
    plusBtn:SetSize(16, 16)
    plusBtn:SetPoint("LEFT", track, "RIGHT", 4, 0)
    
    local plusIcon = plusBtn:CreateTexture(nil, "ARTWORK")
    plusIcon:SetAllPoints()
    plusIcon:SetTexture("Interface\\AddOns\\VFlow\\Assets\\Icons\\chevron_right")
    plusIcon:SetVertexColor(0.7, 0.7, 0.7, 1)
    plusBtn.icon = plusIcon
    
    plusBtn:SetScript("OnEnter", function(self) self.icon:SetVertexColor(1, 1, 1, 1) end)
    plusBtn:SetScript("OnLeave", function(self) self.icon:SetVertexColor(0.7, 0.7, 0.7, 1) end)
    container.plusBtn = plusBtn

    -- 调整布局
    track:ClearAllPoints()
    track:SetPoint("LEFT", 20, 0) -- 留出左侧按钮空间
    track:SetPoint("RIGHT", -20, 0) -- 留出右侧按钮空间
    track:SetPoint("TOP", 0, -25)
    local minText = container:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    minText:SetPoint("TOPLEFT", track, "BOTTOMLEFT", 0, -4)
    minText:SetTextColor(0.5, 0.5, 0.5, 1)
    container.minText = minText

    -- Max Value Text (右下)
    local maxText = container:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    maxText:SetPoint("TOPRIGHT", track, "BOTTOMRIGHT", 0, -4)
    maxText:SetTextColor(0.5, 0.5, 0.5, 1)
    container.maxText = maxText

    -- 兼容旧版 valueText 引用，防止报错
    container.valueText = editBox
end)

-- 4. 复选框（Frame + CheckButton + FontString）
Pool.init("VFlowCheckbox", "Frame", nil, function(container)
    container:SetHeight(40)

    local cb = CreateFrame("CheckButton", nil, container, "BackdropTemplate")
    cb:SetSize(20, 20)
    cb:SetPoint("LEFT", 0, 0)

    -- Backdrop
    cb:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    cb:SetBackdropColor(0.15, 0.15, 0.15, 1)
    cb:SetBackdropBorderColor(0.25, 0.25, 0.25, 1)

    -- Fill Texture (Instead of Icon)
    local fill = cb:CreateTexture(nil, "ARTWORK")
    fill:SetColorTexture(0.25, 0.52, 0.95, 1)
    fill:SetPoint("TOPLEFT", 3, -3)
    fill:SetPoint("BOTTOMRIGHT", -3, 3)
    fill:Hide()
    container.fill = fill

    container.checkbox = cb

    -- Label (Larger Font)
    local label = container:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    label:SetPoint("LEFT", cb, "RIGHT", 8, 0)
    container.label = label

    -- 便捷方法
    function container:SetChecked(checked)
        self.checkbox:SetChecked(checked)
        if checked then
            self.fill:Show()
        else
            self.fill:Hide()
        end
    end

    function container:GetChecked()
        return self.checkbox:GetChecked()
    end
end)

-- 5. 输入框（Frame + EditBox + FontString）
Pool.init("VFlowInput", "Frame", nil, function(outerContainer)
    outerContainer:SetHeight(44)

    -- 标签
    local label = outerContainer:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    label:SetPoint("TOPLEFT", 0, 0)
    outerContainer.label = label

    -- 输入框
    local editBox = CreateFrame("EditBox", nil, outerContainer, "BackdropTemplate")
    editBox:SetPoint("TOPLEFT", 0, -15)
    editBox:SetPoint("TOPRIGHT", 0, -15)
    editBox:SetHeight(24)
    editBox:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    editBox:SetBackdropColor(0.1, 0.1, 0.1, 0.8)
    editBox:SetBackdropBorderColor(0.25, 0.25, 0.25, 1)
    editBox:SetFontObject("GameFontHighlightSmall")
    editBox:SetTextInsets(5, 5, 0, 0)
    editBox:SetAutoFocus(false)
    outerContainer.editBox = editBox

    -- 便捷方法
    function outerContainer:SetText(text)
        self.editBox:SetText(text or "")
    end

    function outerContainer:GetText()
        return self.editBox:GetText()
    end
end)

-- 6. 下拉框（Frame + Button + MenuFrame）
Pool.init("VFlowDropdown", "Frame", nil, function(outerContainer)
    outerContainer:SetHeight(50)

    -- 标签
    local label = outerContainer:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    label:SetPoint("TOPLEFT", 0, 0)
    outerContainer.label = label

    -- 按钮
    local btn = CreateFrame("Button", nil, outerContainer, "BackdropTemplate")
    btn:SetPoint("TOPLEFT", 0, -16)
    btn:SetPoint("TOPRIGHT", 0, -16)
    btn:SetHeight(24)
    btn:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    btn:SetBackdropColor(0.15, 0.15, 0.15, 1)
    btn:SetBackdropBorderColor(0.25, 0.25, 0.25, 1)
    outerContainer.dropdown = btn

    -- 按钮文本
    local text = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    text:SetPoint("LEFT", 8, 0)
    text:SetPoint("RIGHT", -20, 0)
    text:SetJustifyH("LEFT")
    btn.text = text

    -- 箭头
    local arrow = btn:CreateTexture(nil, "OVERLAY")
    arrow:SetPoint("RIGHT", -8, 0)
    arrow:SetSize(12, 12)
    arrow:SetTexture("Interface\\AddOns\\VFlow\\Assets\\Icons\\expand_more")
    arrow:SetVertexColor(0.6, 0.6, 0.6, 1)
    btn.arrow = arrow

    -- 菜单框架 (隐藏)
    local menu = CreateFrame("Frame", nil, btn, "BackdropTemplate")
    menu:SetPoint("TOPLEFT", btn, "BOTTOMLEFT", 0, -2)
    menu:SetPoint("TOPRIGHT", btn, "BOTTOMRIGHT", 0, -2)
    menu:SetFrameStrata("FULLSCREEN_DIALOG")
    menu:SetClampedToScreen(true)
    menu:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    menu:SetBackdropColor(0.12, 0.12, 0.12, 0.98)
    menu:SetBackdropBorderColor(0.25, 0.25, 0.25, 1)
    menu:Hide()
    outerContainer.menu = menu

    -- 兼容旧版 SetText
    function btn:SetText(txt)
        self.text:SetText(txt)
    end
end)

-- 7. 颜色选择器（Frame + Button + Texture）
Pool.init("VFlowColorPicker", "Frame", nil, function(container)
    container:SetHeight(50)

    -- Label（左上）
    local label = container:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    label:SetPoint("TOPLEFT", 0, 0)
    container.label = label

    -- Button（内容区域）
    local btn = CreateFrame("Button", nil, container, "BackdropTemplate")
    btn:SetPoint("TOPLEFT", 0, -16)
    btn:SetPoint("TOPRIGHT", 0, -16)
    btn:SetHeight(24)
    btn:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    btn:SetBackdropColor(0.15, 0.15, 0.15, 1)
    btn:SetBackdropBorderColor(0.25, 0.25, 0.25, 1)
    container.button = btn

    -- Hex Text（内容左侧）
    local hexText = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hexText:SetPoint("LEFT", 8, 0)
    hexText:SetPoint("RIGHT", -42, 0)
    hexText:SetJustifyH("LEFT")
    container.hexText = hexText

    -- Color Swatch（内容右侧）
    local swatch = btn:CreateTexture(nil, "OVERLAY")
    swatch:SetSize(28, 14)
    swatch:SetPoint("RIGHT", -8, 0)
    swatch:SetColorTexture(1, 1, 1, 1)
    container.swatch = swatch
end)

-- 8. 材质/字体选择器（基于Dropdown扩展，带预览）
Pool.init("VFlowResourcePicker", "Frame", nil, function(outerContainer)
    outerContainer:SetHeight(50)

    -- Label
    local label = outerContainer:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    label:SetPoint("TOPLEFT", 0, 0)
    outerContainer.label = label

    -- Button
    local btn = CreateFrame("Button", nil, outerContainer, "BackdropTemplate")
    btn:SetPoint("TOPLEFT", 0, -16)
    btn:SetPoint("TOPRIGHT", 0, -16)
    btn:SetHeight(24)
    btn:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    btn:SetBackdropColor(0.15, 0.15, 0.15, 1)
    btn:SetBackdropBorderColor(0.25, 0.25, 0.25, 1)
    outerContainer.dropdown = btn

    -- Preview Texture (For textures)
    local preview = btn:CreateTexture(nil, "ARTWORK")
    preview:SetPoint("LEFT", 4, 0)
    preview:SetSize(80, 16)
    preview:Hide()
    outerContainer.preview = preview

    -- Text
    local text = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    text:SetPoint("LEFT", 8, 0) -- Will be adjusted dynamically
    text:SetPoint("RIGHT", -20, 0)
    text:SetJustifyH("LEFT")
    btn.text = text

    -- Arrow
    local arrow = btn:CreateTexture(nil, "OVERLAY")
    arrow:SetPoint("RIGHT", -8, 0)
    arrow:SetSize(12, 12)
    arrow:SetTexture("Interface\\AddOns\\VFlow\\Assets\\Icons\\expand_more")
    arrow:SetVertexColor(0.6, 0.6, 0.6, 1)
    btn.arrow = arrow

    -- Menu Frame
    local menu = CreateFrame("Frame", nil, btn, "BackdropTemplate")
    menu:SetPoint("TOPLEFT", btn, "BOTTOMLEFT", 0, -2)
    menu:SetPoint("TOPRIGHT", btn, "BOTTOMRIGHT", 0, -2)
    menu:SetFrameStrata("FULLSCREEN_DIALOG")
    menu:SetClampedToScreen(true)
    menu:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    menu:SetBackdropColor(0.12, 0.12, 0.12, 0.98)
    menu:SetBackdropBorderColor(0.25, 0.25, 0.25, 1)
    menu:Hide()
    outerContainer.menu = menu

    -- Search Box
    local searchBox = CreateFrame("EditBox", nil, menu, "BackdropTemplate")
    searchBox:SetPoint("TOPLEFT", 4, -4)
    searchBox:SetPoint("TOPRIGHT", -4, -4)
    searchBox:SetHeight(22)
    searchBox:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    searchBox:SetBackdropColor(0.1, 0.1, 0.1, 0.8)
    searchBox:SetFontObject("GameFontHighlightSmall")
    searchBox:SetTextInsets(4, 4, 0, 0)
    searchBox:SetAutoFocus(false)
    outerContainer.searchBox = searchBox

    -- Scroll Frame
    local scrollFrame = CreateFrame("ScrollFrame", nil, menu, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", 2, -30)
    scrollFrame:SetPoint("BOTTOMRIGHT", -22, 2)
    outerContainer.scrollFrame = scrollFrame

    local scrollChild = CreateFrame("Frame", nil, scrollFrame)
    scrollChild:SetWidth(200)
    scrollChild:SetHeight(10)
    scrollFrame:SetScrollChild(scrollChild)
    outerContainer.scrollChild = scrollChild

    -- Hide default scrollbar art
    if scrollFrame.ScrollBar then
        local scrollBar = scrollFrame.ScrollBar
        local thumb = scrollBar:GetThumbTexture()
        if thumb then
            thumb:SetTexture("Interface\\Buttons\\WHITE8x8")
            thumb:SetVertexColor(0.25, 0.52, 0.95, 0.95)
            thumb:SetSize(8, 32)
        end
        if not scrollBar._vfTrack then
            local track = scrollBar:CreateTexture(nil, "BACKGROUND")
            track:SetAllPoints()
            track:SetColorTexture(0.08, 0.08, 0.08, 0.85)
            scrollBar._vfTrack = track
        end
    end
end)

-- 9. 文本（FontString）- 特殊处理，使用Frame包装
Pool.init("VFlowFontString", "Frame", nil, function(container)
    container:SetSize(1, 1) -- 最小尺寸

    local fs = container:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    fs:SetAllPoints()
    container.fontString = fs

    -- 便捷方法
    function container:SetText(text)
        self.fontString:SetText(text or "")
    end

    function container:SetFontObject(font)
        self.fontString:SetFontObject(font)
    end

    function container:SetTextColor(r, g, b, a)
        self.fontString:SetTextColor(r, g, b, a)
    end

    function container:SetJustifyH(justify)
        self.fontString:SetJustifyH(justify)
    end
end)

-- 8. 分隔线（Frame + Texture）
Pool.init("VFlowSeparator", "Frame", nil, function(container)
    container:SetHeight(9)

    local line = container:CreateTexture(nil, "ARTWORK")
    line:SetPoint("TOPLEFT", 0, -4)
    line:SetPoint("TOPRIGHT", 0, -4)
    line:SetHeight(1)
    line:SetColorTexture(0.25, 0.25, 0.25, 1)
    container.line = line
end)

-- 9. 间距（Frame）
Pool.init("VFlowSpacer", "Frame", nil, function(container)
    container:SetHeight(10)
end)

-- 10. 图标按钮（Button + Texture + Border）
Pool.init("VFlowIconButton", "Button", nil, function(btn)
    btn:SetSize(40, 40)

    -- 图标纹理
    local icon = btn:CreateTexture(nil, "ARTWORK")
    icon:SetPoint("TOPLEFT", 2, -2)
    icon:SetPoint("BOTTOMRIGHT", -2, 2)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    btn.icon = icon

    -- 边框
    if not btn.SetBackdrop then
        Mixin(btn, BackdropTemplateMixin)
    end
    btn:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    btn:SetBackdropColor(0.15, 0.15, 0.15, 0.8)
    btn:SetBackdropBorderColor(0.25, 0.25, 0.25, 1)

    -- 高亮边框（隐藏）
    local highlight = btn:CreateTexture(nil, "OVERLAY")
    highlight:SetAllPoints()
    highlight:SetColorTexture(1, 1, 1, 0.2)
    highlight:Hide()
    btn.highlight = highlight
end)

Pool.init("VFlowDialog", "Frame", nil, function(dialog)
    dialog:SetAllPoints(UIParent)
    dialog:SetFrameStrata("FULLSCREEN_DIALOG")
    dialog:SetFrameLevel(300)

    local blocker = CreateFrame("Button", nil, dialog)
    blocker:SetAllPoints(dialog)
    dialog.blocker = blocker

    local dim = dialog:CreateTexture(nil, "BACKGROUND")
    dim:SetAllPoints(dialog)
    dim:SetColorTexture(0, 0, 0, 0.45)
    dialog.dim = dim

    local panel = CreateFrame("Frame", nil, dialog, "BackdropTemplate")
    panel:SetSize(420, 200)
    panel:SetPoint("CENTER", 0, 40)
    panel:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    panel:SetBackdropColor(0.12, 0.12, 0.12, 0.96)
    panel:SetBackdropBorderColor(0.25, 0.25, 0.25, 1)
    dialog.panel = panel

    local titleText = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    titleText:SetPoint("TOPLEFT", 14, -12)
    titleText:SetPoint("TOPRIGHT", -44, -12)
    titleText:SetJustifyH("LEFT")
    titleText:SetTextColor(0.9, 0.9, 0.9, 1)
    dialog.titleText = titleText

    local closeButton = CreateFrame("Button", nil, panel, "BackdropTemplate")
    closeButton:SetSize(22, 22)
    closeButton:SetPoint("TOPRIGHT", -10, -10)
    closeButton:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    closeButton:SetBackdropColor(0.15, 0.15, 0.15, 1)
    closeButton:SetBackdropBorderColor(0.25, 0.25, 0.25, 1)
    local closeIcon = closeButton:CreateTexture(nil, "OVERLAY")
    closeIcon:SetAllPoints()
    closeIcon:SetTexture("Interface\\AddOns\\VFlow\\Assets\\Icons\\close")
    closeIcon:SetVertexColor(0.85, 0.85, 0.85, 1)
    dialog.closeButton = closeButton

    local messageText = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    messageText:SetPoint("TOPLEFT", 14, -50)
    messageText:SetPoint("TOPRIGHT", -14, -50)
    messageText:SetJustifyH("LEFT")
    messageText:SetJustifyV("TOP")
    messageText:SetSpacing(2)
    messageText:SetTextColor(0.74, 0.74, 0.74, 1)
    dialog.messageText = messageText

    local confirmButton = CreateFrame("Button", nil, panel, "BackdropTemplate")
    confirmButton:SetSize(96, 28)
    confirmButton:SetPoint("BOTTOMRIGHT", -14, 14)
    confirmButton:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    confirmButton:SetBackdropColor(0.25, 0.52, 0.95, 0.22)
    confirmButton:SetBackdropBorderColor(0.25, 0.52, 0.95, 0.9)
    dialog.confirmButton = confirmButton

    local confirmText = confirmButton:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    confirmText:SetPoint("CENTER")
    confirmText:SetTextColor(1, 1, 1, 1)
    dialog.confirmText = confirmText

    local cancelButton = CreateFrame("Button", nil, panel, "BackdropTemplate")
    cancelButton:SetSize(96, 28)
    cancelButton:SetPoint("RIGHT", confirmButton, "LEFT", -8, 0)
    cancelButton:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    cancelButton:SetBackdropColor(0.15, 0.15, 0.15, 1)
    cancelButton:SetBackdropBorderColor(0.25, 0.25, 0.25, 1)
    dialog.cancelButton = cancelButton

    local cancelText = cancelButton:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    cancelText:SetPoint("CENTER")
    cancelText:SetTextColor(0.9, 0.9, 0.9, 1)
    dialog.cancelText = cancelText
end)

-- 可交互文本组件（富文本链接）
Pool.init("VFlowInteractiveText", "Frame", nil, function(container)
    container:SetHeight(24)
    container.segments = {} -- 存储文本片段
end)
