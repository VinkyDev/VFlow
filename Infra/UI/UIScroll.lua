-- =========================================================
-- VFlow UI Scroll - 滚动帧样式化与状态管理
-- =========================================================

local VFlow = _G.VFlow
local UI = VFlow.UI
local FD = VFlow.FD

local function GetScrollBar(scrollFrame)
    if not scrollFrame then return nil end
    if scrollFrame.ScrollBar then return scrollFrame.ScrollBar end
    local name = scrollFrame.GetName and scrollFrame:GetName()
    if name and _G[name .. "ScrollBar"] then
        return _G[name .. "ScrollBar"]
    end
    return nil
end

local function HideClassicScrollButton(btn)
    if not btn then return end
    btn:Hide()
    btn:SetAlpha(0)
    btn:EnableMouse(false)
    btn:ClearAllPoints()
    btn:SetSize(1, 1)
    local normal = btn.GetNormalTexture and btn:GetNormalTexture()
    if normal and normal.SetTexture then
        normal:SetTexture(nil)
    end
    local pushed = btn.GetPushedTexture and btn:GetPushedTexture()
    if pushed and pushed.SetTexture then
        pushed:SetTexture(nil)
    end
    local highlight = btn.GetHighlightTexture and btn:GetHighlightTexture()
    if highlight and highlight.SetTexture then
        highlight:SetTexture(nil)
    end
    local disabled = btn.GetDisabledTexture and btn:GetDisabledTexture()
    if disabled and disabled.SetTexture then
        disabled:SetTexture(nil)
    end
    if not btn._vf_hideHook then
        btn:HookScript("OnShow", function(self)
            self:Hide()
        end)
        btn._vf_hideHook = true
    end
end

function UI.styleScrollFrame(scrollFrame, opts)
    opts = opts or {}
    local scrollBar = GetScrollBar(scrollFrame)
    if not scrollBar then
        return nil
    end

    local anchorParent = opts.anchorParent or scrollFrame:GetParent() or scrollFrame
    local offsetX = opts.offsetX or -2
    local topOffset = opts.topOffset or -6
    local bottomOffset = opts.bottomOffset or 6
    local width = opts.width or 6

    if opts.reanchor ~= false then
        scrollBar:ClearAllPoints()
        scrollBar:SetPoint("TOPRIGHT", anchorParent, "TOPRIGHT", offsetX, topOffset)
        scrollBar:SetPoint("BOTTOMRIGHT", anchorParent, "BOTTOMRIGHT", offsetX, bottomOffset)
    end
    scrollBar:SetWidth(width)

    HideClassicScrollButton(scrollBar.ScrollUpButton)
    HideClassicScrollButton(scrollBar.ScrollDownButton)
    if scrollBar.Track then scrollBar.Track:Hide() end
    if scrollBar.Top then scrollBar.Top:Hide() end
    if scrollBar.Bottom then scrollBar.Bottom:Hide() end
    if scrollBar.Middle then scrollBar.Middle:Hide() end
    if scrollBar.BG then scrollBar.BG:Hide() end

    local fd = FD(scrollBar)
    if not fd.bg then
        local bg = scrollBar:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(1, 1, 1, 0.06)
        fd.bg = bg
    end

    if not fd.thumb then
        local thumb = scrollBar:CreateTexture(nil, "ARTWORK")
        thumb:SetColorTexture(1, 1, 1, 0.35)
        thumb:SetSize(math.max(4, width - 1), 36)
        scrollBar:SetThumbTexture(thumb)
        fd.thumb = thumb
        scrollBar:SetScript("OnEnter", function(self)
            local sfd = FD(self)
            if sfd.thumb then
                sfd.thumb:SetColorTexture(1, 1, 1, 0.55)
            end
        end)
        scrollBar:SetScript("OnLeave", function(self)
            local sfd = FD(self)
            if sfd.thumb then
                sfd.thumb:SetColorTexture(1, 1, 1, 0.35)
            end
        end)
    end

    return scrollBar
end

function UI.updateScrollFrameState(scrollFrame, contentHeight, viewHeight)
    local scrollBar = GetScrollBar(scrollFrame)
    if not scrollBar then
        return false
    end

    local child = scrollFrame:GetScrollChild()
    local actualContentHeight = contentHeight or (child and child:GetHeight() or 0)
    local actualViewHeight = viewHeight or scrollFrame:GetHeight()
    local overflow = actualContentHeight > actualViewHeight + 0.5

    if overflow then
        local maxScroll = math.max(0, actualContentHeight - actualViewHeight)
        scrollBar:SetMinMaxValues(0, maxScroll)
        local current = scrollFrame:GetVerticalScroll() or 0
        if current < 0 then current = 0 end
        if current > maxScroll then current = maxScroll end
        scrollBar:SetValue(current)
        if FD(scrollBar).thumb then
            local ratio = actualViewHeight / actualContentHeight
            local thumbHeight = math.max(20, scrollBar:GetHeight() * ratio)
            FD(scrollBar).thumb:SetHeight(thumbHeight)
        end
        scrollBar:Show()
    else
        scrollBar:SetMinMaxValues(0, 0)
        scrollBar:SetValue(0)
        scrollFrame:SetVerticalScroll(0)
        scrollBar:Hide()
    end

    return overflow
end

function UI.bindScrollWheel(frame, scrollFrame, step)
    if not frame or not scrollFrame then return end
    local deltaStep = step or 36
    frame:EnableMouseWheel(true)
    frame:SetScript("OnMouseWheel", function(_, delta)
        local scrollBar = GetScrollBar(scrollFrame)
        if not scrollBar or not scrollBar:IsShown() then return end
        local minVal, maxVal = scrollBar:GetMinMaxValues()
        if maxVal <= minVal then return end
        local value = scrollBar:GetValue()
        if delta > 0 then
            value = math.max(minVal, value - deltaStep)
        else
            value = math.min(maxVal, value + deltaStep)
        end
        scrollBar:SetValue(value)
    end)
end
