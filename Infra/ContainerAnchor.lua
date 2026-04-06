-- =========================================================
-- 可拖拽容器 — 依附框体（玩家 / UIParent / 系统技能条）
-- =========================================================

local VFlow = _G.VFlow
if not VFlow then return end

local CA = {}

-- =========================================================
-- 玩家框体
-- =========================================================

local PLAYER_FRAME_CANDIDATES = {
    "ElvUF_Player",
    "SUFUnitplayer",
    "UUF_Player",
    "MSUF_player",
    "EQOLUFPlayerFrame",
    "oUF_Player",
}

local INVERTED_ANCHORS = {
    TOPLEFT = "BOTTOMLEFT",
    TOPRIGHT = "BOTTOMRIGHT",
    BOTTOMLEFT = "TOPLEFT",
    BOTTOMRIGHT = "TOPRIGHT",
}

local anchorCacheVersion = 0
local cachedPlayerFrame = nil
local cachedVersion = -1
local playerFrameSettled = false

local function bumpPlayerFrameCacheVersion()
    anchorCacheVersion = anchorCacheVersion + 1
end

local function resolvePlayerFrame()
    if cachedVersion == anchorCacheVersion and playerFrameSettled then
        if cachedPlayerFrame and cachedPlayerFrame.IsShown and cachedPlayerFrame:IsShown() then
            return cachedPlayerFrame
        end
        playerFrameSettled = false
    end

    for _, name in ipairs(PLAYER_FRAME_CANDIDATES) do
        local frame = _G[name]
        if frame and frame.IsShown and frame:IsShown() then
            cachedPlayerFrame = frame
            cachedVersion = anchorCacheVersion
            playerFrameSettled = true
            return cachedPlayerFrame
        end
    end

    local blizzFrame = _G.PlayerFrame
    if blizzFrame and blizzFrame.IsShown and blizzFrame:IsShown() then
        cachedPlayerFrame = blizzFrame
        cachedVersion = anchorCacheVersion
        local addonFramePending = false
        for _, name in ipairs(PLAYER_FRAME_CANDIDATES) do
            if _G[name] then
                addonFramePending = true
                break
            end
        end
        playerFrameSettled = not addonFramePending
        return cachedPlayerFrame
    end

    cachedPlayerFrame = nil
    cachedVersion = anchorCacheVersion
    return nil
end

local function getPlayerCorner(frame, point)
    if not frame then return nil, nil end
    local l, r, t, b = frame:GetLeft(), frame:GetRight(), frame:GetTop(), frame:GetBottom()
    if not (l and r and t and b) then return nil, nil end
    if point == "TOPLEFT" then
        return l, t
    elseif point == "TOPRIGHT" then
        return r, t
    elseif point == "BOTTOMLEFT" then
        return l, b
    elseif point == "BOTTOMRIGHT" then
        return r, b
    end
    return nil, nil
end

function CA.ResolvePlayerFrame()
    return resolvePlayerFrame()
end

function CA.InvalidatePlayerFrameCache()
    bumpPlayerFrameCacheVersion()
end

function CA.ApplyContainerToPlayer(container, playerPoint, offsetX, offsetY)
    if not container then return false end
    local target = resolvePlayerFrame()
    if not target then
        return false
    end
    local cap = INVERTED_ANCHORS[playerPoint] or "BOTTOMLEFT"
    container:ClearAllPoints()
    container:SetPoint(cap, target, playerPoint, offsetX or 0, offsetY or 0)
    return true
end

function CA.ComputePlayerAnchorOffsets(container, targetFrame, playerPoint)
    if not container or not targetFrame then return 0, 0 end
    local cap = INVERTED_ANCHORS[playerPoint] or "BOTTOMLEFT"
    local cx, cy = getPlayerCorner(container, cap)
    local tx, ty = getPlayerCorner(targetFrame, playerPoint)
    if not (cx and cy and tx and ty) then return 0, 0 end
    return cx - tx, cy - ty
end

-- =========================================================
-- UIParent / 重要条 / 效能条
-- =========================================================

local VALID_SYMMETRIC = {
    CENTER = true,
    TOP = true,
    BOTTOM = true,
    LEFT = true,
    RIGHT = true,
}

function CA.NormalizeAnchorConfig(cfg)
    if not cfg then
        cfg = {}
    end
    local pt = cfg.relativePoint or "CENTER"
    if not VALID_SYMMETRIC[pt] then
        pt = "CENTER"
    end
    return {
        anchorFrame = cfg.anchorFrame or "uiparent",
        relativePoint = pt,
        playerAnchorPosition = cfg.playerAnchorPosition or "BOTTOMLEFT",
        x = cfg.x or 0,
        y = cfg.y or 0,
    }
end

function CA.ResolveSymmetricTarget(cfg)
    local n = CA.NormalizeAnchorConfig(cfg)
    local af = n.anchorFrame
    if af == "essential" then
        return _G.EssentialCooldownViewer or UIParent
    end
    if af == "utility" then
        return _G.UtilityCooldownViewer or UIParent
    end
    return UIParent
end

local function anchorCoords(f, point)
    local l, r, t, b = f:GetLeft(), f:GetRight(), f:GetTop(), f:GetBottom()
    if not (l and r and t and b) then return nil, nil end
    if point == "CENTER" then
        return (l + r) * 0.5, (t + b) * 0.5
    elseif point == "TOP" then
        return (l + r) * 0.5, t
    elseif point == "BOTTOM" then
        return (l + r) * 0.5, b
    elseif point == "LEFT" then
        return l, (t + b) * 0.5
    elseif point == "RIGHT" then
        return r, (t + b) * 0.5
    end
    return nil, nil
end

function CA.GetSymmetricSetPoints(cfg)
    local n = CA.NormalizeAnchorConfig(cfg)
    local af = n.anchorFrame
    local u = n.relativePoint
    if (af == "essential" or af == "utility") and u ~= "CENTER" then
        if u == "TOP" then
            return "BOTTOM", "TOP"
        elseif u == "BOTTOM" then
            return "TOP", "BOTTOM"
        elseif u == "LEFT" then
            return "RIGHT", "LEFT"
        elseif u == "RIGHT" then
            return "LEFT", "RIGHT"
        end
    end
    return u, u
end

function CA.ComputeStoredOffset(container, target, cfg)
    if not container or not target then return 0, 0 end
    local n = CA.NormalizeAnchorConfig(cfg)
    local myPt, theirPt = CA.GetSymmetricSetPoints(n)
    local cx, cy = anchorCoords(container, myPt)
    local tx, ty = anchorCoords(target, theirPt)
    if not (cx and cy and tx and ty) then return 0, 0 end
    return cx - tx, cy - ty
end

--- 与 DragFrame 拖拽结束写入的语义一致：当前帧相对锚点配置下的「应写入 cfg/Store 的 x,y」。
--- 布局未就绪（尚无有效屏幕坐标）时返回 nil,nil，避免把 0,0 误写入。
function CA.GetCanonicalAnchorOffsets(frame, cfg)
    if not frame or not cfg then
        return nil, nil
    end
    local n = CA.NormalizeAnchorConfig(cfg)
    if n.anchorFrame == "player" then
        local target = CA.ResolvePlayerFrame()
        if target then
            local cap = INVERTED_ANCHORS[n.playerAnchorPosition] or "BOTTOMLEFT"
            local cx, cy = getPlayerCorner(frame, cap)
            if not cx then
                return nil, nil
            end
            return CA.ComputePlayerAnchorOffsets(frame, target, n.playerAnchorPosition)
        end
        local cx, cy = anchorCoords(frame, "CENTER")
        local tx, ty = anchorCoords(UIParent, "CENTER")
        if not (cx and cy and tx and ty) then
            return nil, nil
        end
        return cx - tx, cy - ty
    end

    local symTarget = CA.ResolveSymmetricTarget(n)
    local myPt, theirPt = CA.GetSymmetricSetPoints(n)
    local cx, cy = anchorCoords(frame, myPt)
    local tx, ty = anchorCoords(symTarget, theirPt)
    if not (cx and cy and tx and ty) then
        return nil, nil
    end
    return cx - tx, cy - ty
end

---@param opts table|nil
---  snapToPixelGrid==false 关闭 SnapFrameToPixelGrid（默认开）
---  quantizeAnchorOffsets==false 关闭对 x/y 偏移的 PixelSnap（默认开，与 DragFrame 一致）
---  canonicalSync=function(nx,ny) 在吸附后若与配置不一致则先写 cfg 再回调（用于 Store 持久化）
function CA.ApplyFramePosition(frame, cfg, getAnchorOffset, opts)
    if not frame then return end
    local n = CA.NormalizeAnchorConfig(cfg)
    local doSnap = not opts or opts.snapToPixelGrid ~= false
    local doQuantize = not opts or opts.quantizeAnchorOffsets ~= false
    local PP = VFlow.PixelPerfect

    local ox, oy = n.x, n.y
    if getAnchorOffset then
        local ax, ay = getAnchorOffset(frame)
        if ax and ay then
            ox, oy = ox + ax, oy + ay
        end
    end

    if n.anchorFrame == "player" then
        local ref = CA.ResolvePlayerFrame() or UIParent
        if doQuantize and PP and PP.PixelSnap then
            ox, oy = PP.PixelSnap(ox, ref), PP.PixelSnap(oy, ref)
        end
        local ok = CA.ApplyContainerToPlayer(frame, n.playerAnchorPosition, ox, oy)
        if not ok then
            local fx, fy = n.x or 0, n.y or 0
            if doQuantize and PP and PP.PixelSnap then
                fx, fy = PP.PixelSnap(fx, UIParent), PP.PixelSnap(fy, UIParent)
            end
            frame:ClearAllPoints()
            frame:SetPoint("CENTER", UIParent, "CENTER", fx, fy)
        end
        if doSnap and PP and PP.SnapFrameToPixelGrid then
            PP.SnapFrameToPixelGrid(frame)
        end
    else
        local target = CA.ResolveSymmetricTarget(n)
        if doQuantize and PP and PP.PixelSnap then
            ox, oy = PP.PixelSnap(ox, target), PP.PixelSnap(oy, target)
        end
        local myPt, theirPt = CA.GetSymmetricSetPoints(n)
        frame:ClearAllPoints()
        frame:SetPoint(myPt, target, theirPt, ox, oy)
        if doSnap and PP and PP.SnapFrameToPixelGrid then
            PP.SnapFrameToPixelGrid(frame)
        end
    end

    if doSnap and opts and opts.canonicalSync then
        local nx, ny = CA.GetCanonicalAnchorOffsets(frame, cfg)
        if nx ~= nil and ny ~= nil then
            if math.abs(nx - (n.x or 0)) > 1e-5 or math.abs(ny - (n.y or 0)) > 1e-5 then
                cfg.x = nx
                cfg.y = ny
                opts.canonicalSync(nx, ny)
            end
        end
    end
end

VFlow.ContainerAnchor = CA

local function onPlayerFrameEnvChanged()
    bumpPlayerFrameCacheVersion()
end

VFlow.on("PLAYER_ENTERING_WORLD", "ContainerAnchor", onPlayerFrameEnvChanged)
VFlow.on("LOADING_SCREEN_DISABLED", "ContainerAnchor", onPlayerFrameEnvChanged)
