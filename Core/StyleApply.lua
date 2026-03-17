-- =========================================================
-- VFlow StyleApply - 样式应用
-- =========================================================

local VFlow = _G.VFlow
if not VFlow then return end

local LSM = LibStub and LibStub("LibSharedMedia-3.0", true)
local PixelPerfect = VFlow.PixelPerfect
local StyleApply = {}
VFlow.StyleApply = StyleApply

local abs = math.abs

local function SafeEquals(v, expected)
    if type(v) == "number" and issecretvalue and issecretvalue(v) then
        return false
    end
    return v == expected
end

local function SafeSetShadow(fs, enabled)
    if not fs or not fs.SetShadowColor or not fs.SetShadowOffset then
        return
    end
    if enabled then
        pcall(fs.SetShadowColor, fs, 0, 0, 0, 1)
        pcall(fs.SetShadowOffset, fs, 1, -1)
    else
        pcall(fs.SetShadowColor, fs, 0, 0, 0, 0)
        pcall(fs.SetShadowOffset, fs, 0, 0)
    end
end

-- =========================================================
-- 工具函数
-- =========================================================

-- 获取冷却读秒FontString
function StyleApply.GetCooldownFontString(button)
    if not button or not button.Cooldown then return nil end
    local cd = button.Cooldown
    if cd.GetCountdownFontString then
        local fs = cd:GetCountdownFontString()
        if fs and fs.SetFont then return fs end
    end
    for _, region in ipairs({ cd:GetRegions() }) do
        if region and region.IsObjectType and region:IsObjectType("FontString") then
            return region
        end
    end
    return nil
end

-- 获取堆叠数FontString
function StyleApply.GetStackFontString(button)
    if button.Applications and button.Applications.Applications then
        return button.Applications.Applications
    end
    if button.ChargeCount and button.ChargeCount.Current then
        return button.ChargeCount.Current
    end
    return nil
end

-- =========================================================
-- 样式应用函数（幂等，缓存上次值）
-- =========================================================

-- 应用图标尺寸
function StyleApply.ApplyIconSize(button, w, h)
    if button._vf_w == w and button._vf_h == h then return end
    button:SetSize(w, h)
    button._vf_w = w
    button._vf_h = h
end

-- 应用字体样式到FontString
function StyleApply.ApplyFontStyle(fs, cfg, cachePrefix)
    if not fs or not cfg then return end

    local prefix = cachePrefix or "_vf"

    -- 字体与字号
    local size = cfg.size or 14
    local fontToken = cfg.font
    local outline = cfg.outline or "OUTLINE"
    local requestedFlags = ""
    if outline == "OUTLINE" or outline == "THICKOUTLINE" then
        requestedFlags = outline
    end
    local sizeKey = prefix .. "_size"
    local fontKey = prefix .. "_font"
    local outlineKey = prefix .. "_outline"

    if fs[sizeKey] ~= size or fs[fontKey] ~= fontToken or fs[outlineKey] ~= outline then
        local currentFont, _, flags = fs:GetFont()
        local fontPath = nil
        if type(fontToken) == "string" and fontToken ~= "" then
            if VFlow.UI and VFlow.UI.resolveFontPath then
                fontPath = VFlow.UI.resolveFontPath(fontToken)
            else
                fontPath = fontToken
            end
        end

        local ok = false
        if fontPath then
            ok = pcall(fs.SetFont, fs, fontPath, size, requestedFlags)
        elseif currentFont then
            ok = pcall(fs.SetFont, fs, currentFont, size, requestedFlags)
        end
        if ok then
            fs[sizeKey] = size
            fs[fontKey] = fontToken
            fs[outlineKey] = outline
        end
    end

    local shadowMode = (outline == "SHADOW" or outline == "OUTLINE_SHADOW")
    local shadowKey = prefix .. "_shadow"
    if fs[shadowKey] ~= shadowMode then
        SafeSetShadow(fs, shadowMode)
        fs[shadowKey] = shadowMode
    end

    -- 颜色
    if cfg.color then
        local c = cfg.color
        local r, g, b, a = c.r or 1, c.g or 1, c.b or 1, c.a or 1
        local rKey, gKey, bKey, aKey = prefix .. "_r", prefix .. "_g", prefix .. "_b", prefix .. "_a"

        if fs[rKey] ~= r or fs[gKey] ~= g or fs[bKey] ~= b or fs[aKey] ~= a then
            fs:SetTextColor(r, g, b, a)
            fs[rKey] = r
            fs[gKey] = g
            fs[bKey] = b
            fs[aKey] = a
        end
    end

    -- 位置
    local position = cfg.position or "CENTER"
    local ox = cfg.offsetX or 0
    local oy = cfg.offsetY or 0
    local posKey = prefix .. "_pos"
    local oxKey = prefix .. "_ox"
    local oyKey = prefix .. "_oy"

    if fs[posKey] ~= position or fs[oxKey] ~= ox or fs[oyKey] ~= oy then
        fs:ClearAllPoints()
        local parent = fs:GetParent()
        fs:SetPoint(position, parent, position, ox, oy)
        fs[posKey] = position
        fs[oxKey] = ox
        fs[oyKey] = oy
    end
end

-- 应用键位显示
function StyleApply.ApplyKeybind(button, cfg)
    if not button or not cfg then return end

    local show = cfg.showKeybind
    if not show then
        if button._vf_keybindFrame then
            button._vf_keybindFrame:Hide()
        end
        return
    end

    -- 获取键位文本
    local keyText = ""
    if VFlow.Keybind then
        local spellID = VFlow.Keybind.GetSpellIDFromIcon(button)
        if spellID then
            keyText = VFlow.Keybind.GetKeyForSpell(spellID)
        end
    end

    -- 创建键位显示框架
    if not button._vf_keybindFrame then
        local f = CreateFrame("Frame", nil, button)
        f:SetAllPoints(button)
        f:SetFrameLevel(button:GetFrameLevel() + 3)
        local fs = f:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
        fs:SetTextColor(1, 1, 1, 1)
        fs:SetShadowColor(0, 0, 0, 1)
        fs:SetShadowOffset(1, -1)
        f.text = fs
        button._vf_keybindFrame = f
    end

    local fs = button._vf_keybindFrame.text
    fs:SetText(keyText or "")

    -- 应用字体样式
    if cfg.keybindFont then
        StyleApply.ApplyFontStyle(fs, cfg.keybindFont, "_vf_kb")
    end

    -- 显示/隐藏
    if keyText and keyText ~= "" then
        button._vf_keybindFrame:Show()
    else
        button._vf_keybindFrame:Hide()
    end
end

-- 应用完整样式到单个按钮
function StyleApply.ApplyButtonStyle(button, cfg)
    if not button or not cfg then return end

    -- 堆叠文字
    if cfg.stackFont then
        local stackFS = StyleApply.GetStackFontString(button)
        if stackFS then
            -- 提高堆叠文字父Frame的frameLevel，确保在发光之上（发光是 frameLevel + 5）
            local parent = stackFS:GetParent()
            if parent and parent.SetFrameLevel then
                local targetLevel = button:GetFrameLevel() + 7
                if parent:GetFrameLevel() ~= targetLevel then
                    parent:SetFrameLevel(targetLevel)
                end
            end

            if stackFS.GetDrawLayer and stackFS.SetDrawLayer then
                local layer, subLevel = stackFS:GetDrawLayer()
                if layer ~= "OVERLAY" or (subLevel or 0) < 7 then
                    stackFS:SetDrawLayer("OVERLAY", 7)
                end
            end
            StyleApply.ApplyFontStyle(stackFS, cfg.stackFont, "_vf_stack")
        end
    end

    -- 冷却读秒
    if cfg.cooldownFont then
        local cdFS = StyleApply.GetCooldownFontString(button)
        StyleApply.ApplyFontStyle(cdFS, cfg.cooldownFont, "_vf_cd")
    end

    -- 键位显示
    if cfg.showKeybind ~= nil then
        StyleApply.ApplyKeybind(button, cfg)
    end

    -- 应用全局美化设置
    StyleApply.ApplyBeautify(button)
end

-- =========================================================
-- 美化功能
-- =========================================================

-- 获取美化配置
local function GetBeautifyConfig()
    if VFlow and VFlow.Store and VFlow.Store.getModuleRef then
        return VFlow.Store.getModuleRef("VFlow.StyleIcon")
    end
    return nil
end

-- 保持比例的纹理坐标计算
local function GetAspectPreservingTexCoord(frameW, frameH, zoomPadding)
    if not frameH or frameH <= 0 then return 0, 1, 0, 1 end
    local padding = zoomPadding or 0
    local texWidth = 1 - (padding * 2)

    local aspectRatio = frameW / frameH
    local xRatio = aspectRatio < 1 and aspectRatio or 1
    local yRatio = aspectRatio > 1 and 1 / aspectRatio or 1

    local left   = -0.5 * texWidth * xRatio + 0.5
    local right  =  0.5 * texWidth * xRatio + 0.5
    local top    = -0.5 * texWidth * yRatio + 0.5
    local bottom =  0.5 * texWidth * yRatio + 0.5

    return left, right, top, bottom
end

-- 应用图标缩放
function StyleApply.ApplyIconZoom(button, cfg)
    local tex = button.Icon
    if not tex or not tex.SetTexCoord then return end

    local w, h = button:GetSize()
    local zoomAmount = 0
    if cfg and cfg.zoomIcons then
        zoomAmount = cfg.zoomAmount or 0.08
    end

    local left, right, top, bottom = GetAspectPreservingTexCoord(w, h, zoomAmount)
    tex:SetTexCoord(left, right, top, bottom)

    -- 当启用图标缩放时，需要调整Cooldown
    if button.Cooldown then
        -- 每次尺寸变化时都重新设置Cooldown锚点
        -- 避免首次战斗时尺寸为0导致锚点设置错误
        local w2, h2 = button:GetSize()
        local sizeKey = (w2 or 0) .. "x" .. (h2 or 0)
        if button._vf_cooldownSizeKey ~= sizeKey then
            button.Cooldown:ClearAllPoints()
            button.Cooldown:SetAllPoints(button)
            button._vf_cooldownSizeKey = sizeKey
        end

        -- 当启用缩放时，使用纯白纹理替代默认的Swipe纹理
        if button.Cooldown.SetSwipeTexture then
            local useWhiteTexture = cfg and cfg.zoomIcons
            local targetTexture = useWhiteTexture and "Interface\\Buttons\\WHITE8x8" or "Interface\\HUD\\UI-HUD-CoolDownManager-Icon-Swipe"

            if button._vf_swipeTexture ~= targetTexture then
                button.Cooldown:SetSwipeTexture(targetTexture)
                button._vf_swipeTexture = targetTexture
            end
        end

        -- 禁用边缘绘制
        if button.Cooldown.SetDrawEdge then
            button.Cooldown:SetDrawEdge(false)
        end
    end
end

-- 移除遮罩与覆盖层
function StyleApply.ApplyOverlayHides(button, cfg)
    if not cfg then return end
    
    local hideOverlay = cfg.hideIconOverlay
    local hideTexture = cfg.hideIconOverlayTexture
    
    for _, region in ipairs({ button:GetRegions() }) do
        if region and region.IsObjectType then
            if region:IsObjectType("Texture") then
                local atlas = region.GetAtlas and region:GetAtlas()
                if SafeEquals(atlas, "UI-HUD-CoolDownManager-IconOverlay") then
                    if hideOverlay then region:Hide() else region:Show() end
                end
                
                local texID = region.GetTexture and region:GetTexture()
                if SafeEquals(texID, 6707800) then -- BLIZZARD_ICON_OVERLAY_TEXTURE_FILE_ID
                    if hideTexture then region:Hide() else region:Show() end
                end
            elseif region:IsObjectType("MaskTexture") then
                local atlas = region.GetAtlas and region:GetAtlas()
                if SafeEquals(atlas, "UI-HUD-CoolDownManager-Mask") then
                    if hideTexture and button.Icon and button.Icon.RemoveMaskTexture then
                         pcall(button.Icon.RemoveMaskTexture, button.Icon, region)
                    end
                end
            end
        end
    end
end

-- 应用边框
function StyleApply.ApplyBorder(button, cfg)
    -- 如果 Masque 激活，则不应用自定义边框
    if VFlow.MasqueSupport and VFlow.MasqueSupport:IsActive() then
        if button._vf_border then button._vf_border:Hide() end
        return
    end

    if not cfg then return end

    local borderFile = cfg.borderFile
    if not borderFile or borderFile == "None" or borderFile == "无" then
        if button._vf_border then button._vf_border:Hide() end
        return
    end

    if not button._vf_border then
        local b = CreateFrame("Frame", nil, button, "BackdropTemplate")
        b:SetFrameLevel(button:GetFrameLevel() + 1)
        b:SetAllPoints(button)
        button._vf_border = b
    end
    
    local b = button._vf_border
    b:Show()
    
    local size = cfg.borderSize or 1
    local offsetX = cfg.borderOffsetX or 0
    local offsetY = cfg.borderOffsetY or 0
    local color = cfg.borderColor or { r = 0, g = 0, b = 0, a = 1 }
    local anchorOffsetX = offsetX
    local anchorOffsetY = offsetY

    if borderFile == "1PX" then
        -- 使用 PixelPerfect 创建 1PX 边框
        -- 清除 Backdrop
        b:SetBackdrop(nil)
        -- 使用 PixelPerfect 创建边框纹理
        if PixelPerfect then
            -- 这里我们直接利用 PixelPerfect 的 CreateBorder 功能
            -- 但是 PixelPerfect.CreateBorder 是直接在 frame 上创建纹理
            -- 我们为了不污染 button，在 b 上创建
            PixelPerfect.CreateBorder(b, size, color, true) -- true = inset (内嵌)
            anchorOffsetX = PixelPerfect.PixelSnap(offsetX, button)
            anchorOffsetY = PixelPerfect.PixelSnap(offsetY, button)
        else
            -- 降级处理
            local edgeFile = "Interface\\Buttons\\WHITE8x8"
            b:SetBackdrop({
                edgeFile = edgeFile,
                edgeSize = 1,
                bgFile = nil,
            })
            b:SetBackdropBorderColor(color.r, color.g, color.b, color.a)
        end
    else
        -- 传统 Backdrop 模式
        -- 清理可能存在的 PixelPerfect 边框
        if b._ppBorders then
            for _, border in ipairs(b._ppBorders) do
                border:Hide()
            end
        end

        -- 获取材质路径
        local edgeFile = borderFile
        if LSM then
            local p = LSM:Fetch("border", borderFile)
            if p then edgeFile = p end
        end
        
        -- 简单的回退机制
        if edgeFile and not edgeFile:find("\\") then
            edgeFile = "Interface\\Buttons\\WHITE8x8"
        end

        b:SetBackdrop({
            edgeFile = edgeFile,
            edgeSize = size,
            bgFile = nil,
        })
        b:SetBackdropBorderColor(color.r, color.g, color.b, color.a)
    end
    
    b:ClearAllPoints()
    -- 注意：Backdrop是向内绘制的，如果要做外边框可能需要调整SetPoint
    -- 这里简单实现为覆盖在图标之上
    b:SetPoint("TOPLEFT", button, "TOPLEFT", -anchorOffsetX, anchorOffsetY)
    b:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", anchorOffsetX, -anchorOffsetY)
end

-- 应用视觉隐藏
function StyleApply.ApplyVisualHides(button, cfg)
    if not cfg then return end

    if button.DebuffBorder then
        if cfg.hideDebuffBorder then
            if not button._vf_hook_debuff then
                hooksecurefunc(button.DebuffBorder, "Show", function(self)
                    local db = GetBeautifyConfig()
                    if db and db.hideDebuffBorder then self:Hide() end
                end)
                if button.DebuffBorder.UpdateFromAuraData then
                     hooksecurefunc(button.DebuffBorder, "UpdateFromAuraData", function(self)
                        local db = GetBeautifyConfig()
                        if db and db.hideDebuffBorder then self:Hide() end
                    end)
                end
                button._vf_hook_debuff = true
            end
            button.DebuffBorder:Hide()
        end
    end

    if button.PandemicIcon then
        if cfg.hidePandemicIndicator then
             if not button._vf_hook_pandemic then
                hooksecurefunc(button, "ShowPandemicStateFrame", function(self)
                    local db = GetBeautifyConfig()
                    if db and db.hidePandemicIndicator and self.PandemicIcon then 
                        self.PandemicIcon:Hide() 
                    end
                end)
                button._vf_hook_pandemic = true
             end
             button.PandemicIcon:Hide()
        end
    end

    if button.CooldownFlash then
        if cfg.hideCooldownBling then
            if not button._vf_hook_bling then
                hooksecurefunc(button.CooldownFlash, "Show", function(self)
                    local db = GetBeautifyConfig()
                    if db and db.hideCooldownBling then 
                        self:Hide()
                        if self.FlashAnim then self.FlashAnim:Stop() end
                    end
                end)
                if button.CooldownFlash.FlashAnim and button.CooldownFlash.FlashAnim.Play then
                    hooksecurefunc(button.CooldownFlash.FlashAnim, "Play", function(self)
                        local db = GetBeautifyConfig()
                        if db and db.hideCooldownBling then 
                            self:Stop()
                            button.CooldownFlash:Hide()
                        end
                    end)
                end
                button._vf_hook_bling = true
            end
            button.CooldownFlash:Hide()
        end
    end
end

-- 主入口：应用美化
function StyleApply.ApplyBeautify(button)
    local cfg = GetBeautifyConfig()

    StyleApply.ApplyIconZoom(button, cfg)
    StyleApply.ApplyOverlayHides(button, cfg)
    StyleApply.ApplyBorder(button, cfg)
    StyleApply.ApplyVisualHides(button, cfg)
end

-- =========================================================
-- 发光效果
-- =========================================================

local LCG = LibStub and LibStub("LibCustomGlow-1.0", true)
local GLOW_KEY = "VFlow_Glow"

-- 发光缓存
local glowCache = {
    type = "proc",
    useCustomColor = false,
    color = nil,

    -- Pixel Glow
    pixelLines = 8,
    pixelFrequency = 0.2,
    pixelLength = 0,
    pixelThickness = 2,
    pixelXOffset = 0,
    pixelYOffset = 0,

    -- Autocast Glow
    autocastParticles = 4,
    autocastFrequency = 0.2,
    autocastScale = 1,
    autocastXOffset = 0,
    autocastYOffset = 0,

    -- Button Glow
    buttonFrequency = 0,

    -- Proc Glow
    procDuration = 1,
    procXOffset = 0,
    procYOffset = 0,
}

-- 活跃发光帧集合
local activeGlowFrames = setmetatable({}, { __mode = "k" })

-- 颜色数组缓存
local glowColorArrayCache = setmetatable({}, { __mode = "k" })

-- 获取缓存的颜色数组
local function GetCachedGlowColorArray(color)
    if type(color) ~= "table" then
        return nil
    end

    local arr = glowColorArrayCache[color]
    if not arr then
        arr = { 1, 1, 1, 1 }
        glowColorArrayCache[color] = arr
    end

    arr[1] = color.r or 1
    arr[2] = color.g or 1
    arr[3] = color.b or 1
    arr[4] = color.a or 1
    return arr
end

-- 获取发光颜色
local function GetGlowColor(overrideColor)
    if overrideColor then
        return GetCachedGlowColorArray(overrideColor)
    end
    if glowCache.useCustomColor and glowCache.color then
        return GetCachedGlowColorArray(glowCache.color)
    end
    return nil
end

-- Proc Glow 选项
local procGlowOpts = {
    color = nil,
    startAnim = false,
    duration = 1,
    xOffset = 0,
    yOffset = 0,
    key = GLOW_KEY,
    frameLevel = 0,
}

-- 发光启动函数
local glowStartFunctions = {
    pixel = function(frame, frameLevel, overrideColor)
        if not LCG then return end
        local color = GetGlowColor(overrideColor)
        local length = glowCache.pixelLength
        if length == 0 then length = nil end
        LCG.PixelGlow_Start(
            frame,
            color,
            glowCache.pixelLines,
            glowCache.pixelFrequency,
            length,
            glowCache.pixelThickness,
            glowCache.pixelXOffset,
            glowCache.pixelYOffset,
            false, -- pixelBorder
            GLOW_KEY,
            frameLevel
        )
    end,

    autocast = function(frame, frameLevel, overrideColor)
        if not LCG then return end
        local color = GetGlowColor(overrideColor)
        LCG.AutoCastGlow_Start(
            frame,
            color,
            glowCache.autocastParticles,
            glowCache.autocastFrequency,
            glowCache.autocastScale,
            glowCache.autocastXOffset,
            glowCache.autocastYOffset,
            GLOW_KEY,
            frameLevel
        )
    end,

    button = function(frame, frameLevel, overrideColor)
        if not LCG then return end
        local color = GetGlowColor(overrideColor)
        local freq = glowCache.buttonFrequency
        if freq == 0 then freq = nil end
        LCG.ButtonGlow_Start(
            frame,
            color,
            freq,
            frameLevel
        )
    end,

    proc = function(frame, frameLevel, overrideColor)
        if not LCG then return end
        local color = GetGlowColor(overrideColor)
        procGlowOpts.color = color
        procGlowOpts.duration = glowCache.procDuration
        procGlowOpts.xOffset = glowCache.procXOffset
        procGlowOpts.yOffset = glowCache.procYOffset
        procGlowOpts.frameLevel = frameLevel
        LCG.ProcGlow_Start(frame, procGlowOpts)
    end,
}

-- 发光停止函数
local glowStopFunctions = {
    pixel = function(frame)
        if not LCG then return end
        LCG.PixelGlow_Stop(frame, GLOW_KEY)
    end,

    autocast = function(frame)
        if not LCG then return end
        LCG.AutoCastGlow_Stop(frame, GLOW_KEY)
    end,

    button = function(frame)
        if not LCG then return end
        LCG.ButtonGlow_Stop(frame)
    end,

    proc = function(frame)
        if not LCG then return end
        LCG.ProcGlow_Stop(frame, GLOW_KEY)
    end,
}

-- 颜色是否匹配
local function ColorsMatch(a, b)
    if a == b then return true end
    if not a or not b then return false end
    return a.r == b.r and a.g == b.g and a.b == b.b
end

-- 显示发光
function StyleApply.ShowGlow(frame, overrideColor)
    if not LCG or not frame then return end

    -- 检查是否需要更新
    if frame._vf_glowActive and frame._vf_glowType == glowCache.type
       and ColorsMatch(frame._vf_glowColor, overrideColor) then
        return
    end

    -- 停止旧的发光
    if frame._vf_glowActive then
        local stopFn = glowStopFunctions[frame._vf_glowType]
        if stopFn then stopFn(frame) end
        frame._vf_glowActive = false
        frame._vf_glowType = nil
    end

    -- 检查帧尺寸
    if frame:GetWidth() < 1 or frame:GetHeight() < 1 then
        return
    end

    -- 启动新的发光
    local fn = glowStartFunctions[glowCache.type]
    if fn then
        -- 使用 frameLevel + 5，让发光效果在边框之上，但在堆叠文字之下（堆叠文字是 frameLevel + 7）
        local frameLevel = frame:GetFrameLevel() + 5
        fn(frame, frameLevel, overrideColor)
        frame._vf_glowActive = true
        frame._vf_glowType = glowCache.type
        frame._vf_glowColor = overrideColor
        activeGlowFrames[frame] = true
    end
end

-- 隐藏发光
function StyleApply.HideGlow(frame)
    if not LCG or not frame then return end

    if not frame._vf_glowActive then return end

    local fn = glowStopFunctions[frame._vf_glowType]
    if fn then
        fn(frame)
    end

    frame._vf_glowActive = false
    frame._vf_glowType = nil
    frame._vf_glowColor = nil
    activeGlowFrames[frame] = nil
end

-- 刷新所有活跃的发光
function StyleApply.RefreshActiveGlows()
    if not LCG then return end

    local snapshot = {}
    local count = 0
    for frame in pairs(activeGlowFrames) do
        count = count + 1
        snapshot[count] = frame
    end

    for i = 1, count do
        local frame = snapshot[i]
        if frame._vf_glowActive then
            StyleApply.ShowGlow(frame, frame._vf_glowColor)
        else
            activeGlowFrames[frame] = nil
        end
    end
end

-- 从Store刷新发光缓存
function StyleApply.RefreshGlowCache()
    local db = VFlow and VFlow.Store and VFlow.Store.getModuleRef and VFlow.Store.getModuleRef("VFlow.StyleGlow")
    if not db then return end

    glowCache.type = db.glowType or "proc"
    glowCache.useCustomColor = db.useCustomColor or false
    glowCache.color = db.color

    glowCache.pixelLines = db.pixelLines or 8
    glowCache.pixelFrequency = db.pixelFrequency or 0.2
    glowCache.pixelLength = db.pixelLength or 0
    glowCache.pixelThickness = db.pixelThickness or 2
    glowCache.pixelXOffset = db.pixelXOffset or 0
    glowCache.pixelYOffset = db.pixelYOffset or 0

    glowCache.autocastParticles = db.autocastParticles or 4
    glowCache.autocastFrequency = db.autocastFrequency or 0.2
    glowCache.autocastScale = db.autocastScale or 1
    glowCache.autocastXOffset = db.autocastXOffset or 0
    glowCache.autocastYOffset = db.autocastYOffset or 0

    glowCache.buttonFrequency = db.buttonFrequency or 0

    glowCache.procDuration = db.procDuration or 1
    glowCache.procXOffset = db.procXOffset or 0
    glowCache.procYOffset = db.procYOffset or 0

    -- 验证发光类型
    if not glowStartFunctions[glowCache.type] then
        glowCache.type = "proc"
    end

    -- 刷新所有活跃的发光
    StyleApply.RefreshActiveGlows()
end

-- 隐藏暴雪原生发光
local function HideBlizzardGlow(frame)
    if not frame then return end
    local alert = frame.SpellActivationAlert
    if not alert then return end
    alert:SetAlpha(0)
    alert:Hide()
end

-- 检查是否是支持的发光帧
local function IsSupportedGlowFrame(frame)
    if not frame then return false end

    -- 检查父容器
    local parent = frame:GetParent()
    if not parent then return false end

    local parentName = parent:GetName()
    if not parentName then return false end

    -- 支持暴雪的Essential/Utility/Buff Viewer
    local supported = parentName == "EssentialCooldownViewer"
                   or parentName == "UtilityCooldownViewer"
                   or parentName == "BuffIconCooldownViewer"

    return supported
end

-- Hook暴雪的发光管理器
local alertManagerHooked = false
function StyleApply.HookAlertManager()
    if alertManagerHooked then return end
    if not LCG then return end

    local alertManager = _G.ActionButtonSpellAlertManager
    if not alertManager then return end

    -- Hook ShowAlert - 当暴雪想显示发光时
    hooksecurefunc(alertManager, "ShowAlert", function(_, frame)
        if not IsSupportedGlowFrame(frame) then return end

        -- 隐藏暴雪的发光
        HideBlizzardGlow(frame)

        -- 如果已经有相同类型的发光，不重复应用
        if frame._vf_glowActive and frame._vf_glowType == glowCache.type then
            return
        end

        -- 显示自定义发光
        StyleApply.ShowGlow(frame)
    end)

    -- Hook HideAlert - 当暴雪想隐藏发光时
    hooksecurefunc(alertManager, "HideAlert", function(_, frame)
        if not IsSupportedGlowFrame(frame) then return end

        -- 隐藏暴雪的发光
        HideBlizzardGlow(frame)

        -- 隐藏自定义发光
        StyleApply.HideGlow(frame)
    end)

    alertManagerHooked = true
end

-- 初始化发光系统
function StyleApply.InitializeGlow()
    StyleApply.RefreshGlowCache()
    StyleApply.HookAlertManager()
end

-- 监听Store变化
VFlow.Store.watch("VFlow.StyleGlow", "StyleApply_Glow", function(key, value)
    StyleApply.RefreshGlowCache()
end)

-- 在PLAYER_LOGIN时初始化
VFlow.on("PLAYER_LOGIN", "StyleApply_Glow", function()
    C_Timer.After(1, function()
        StyleApply.InitializeGlow()
    end)
end)
