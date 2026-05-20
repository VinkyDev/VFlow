-- =========================================================
-- VFlow UI Pickers - 颜色选择器、材质选择器、字体选择器
-- =========================================================

local VFlow = _G.VFlow
local UI = VFlow.UI
local Pool = VFlow.Pool
local L = VFlow.L
local LSM = LibStub and LibStub("LibSharedMedia-3.0", true)

-- =========================================================
-- 颜色选择器
-- =========================================================

function UI.colorPicker(parent, label, value, hasAlpha, onChange)
    local container = Pool.acquire("VFlowColorPicker", parent)
    container._vf_poolType = "VFlowColorPicker"
    local btn = container.button

    container.label:SetText(label or "")
    local c = UI.style.colors.text
    container.label:SetTextColor(c[1], c[2], c[3], c[4])

    value = value or {}
    local r, g, b, a = value.r or 1, value.g or 1, value.b or 1, value.a or 1
    local function toHex(v)
        return string.format("%02X", math.floor(math.max(0, math.min(1, v)) * 255 + 0.5))
    end
    local function updateVisual(newR, newG, newB, newA)
        container.swatch:SetColorTexture(newR, newG, newB, newA)
        if hasAlpha then
            container.hexText:SetText("#" .. toHex(newR) .. toHex(newG) .. toHex(newB) .. toHex(newA))
        else
            container.hexText:SetText("#" .. toHex(newR) .. toHex(newG) .. toHex(newB))
        end
    end
    updateVisual(r, g, b, a)

    local ec = UI.style.colors.element
    btn:SetBackdropColor(ec[1], ec[2], ec[3], ec[4])
    local bc = UI.style.colors.border
    btn:SetBackdropBorderColor(bc[1], bc[2], bc[3], bc[4])
    local tc = UI.style.colors.text
    container.hexText:SetTextColor(tc[1], tc[2], tc[3], tc[4])

    btn:SetScript("OnEnter", function(self)
        local hc = UI.style.colors.hover
        self:SetBackdropColor(hc[1], hc[2], hc[3], hc[4])
    end)

    btn:SetScript("OnLeave", function(self)
        local ec2 = UI.style.colors.element
        self:SetBackdropColor(ec2[1], ec2[2], ec2[3], ec2[4])
    end)

    btn:SetScript("OnClick", function()
        local info = {
            r = r,
            g = g,
            b = b,
            opacity = hasAlpha and a or nil,
            hasOpacity = hasAlpha,
            swatchFunc = function()
                local newR, newG, newB = ColorPickerFrame:GetColorRGB()
                local newA = hasAlpha and ColorPickerFrame:GetColorAlpha() or 1
                updateVisual(newR, newG, newB, newA)
                if onChange then onChange(newR, newG, newB, newA) end
                r, g, b, a = newR, newG, newB, newA
            end,
            opacityFunc = hasAlpha and function()
                local newA = ColorPickerFrame:GetColorAlpha()
                updateVisual(r, g, b, newA)
                if onChange then onChange(r, g, b, newA) end
                a = newA
            end or nil,
            cancelFunc = function()
                updateVisual(r, g, b, a)
                if onChange then onChange(r, g, b, a) end
            end,
        }
        ColorPickerFrame:SetupColorPickerAndShow(info)
        if ColorPickerFrame then
            ColorPickerFrame:SetFrameStrata("TOOLTIP")
            ColorPickerFrame:SetFrameLevel(500)
            C_Timer.After(0, function()
                if ColorPickerFrame and ColorPickerFrame:IsShown() then
                    ColorPickerFrame:SetFrameStrata("TOOLTIP")
                    ColorPickerFrame:SetFrameLevel(500)
                end
            end)
        end
    end)

    return container
end

-- =========================================================
-- 材质选择器 (LibSharedMedia statusbar)
-- =========================================================

function UI.texturePicker(parent, label, value, onChange)
    local container = Pool.acquire("VFlowResourcePicker", parent)
    container._vf_poolType = "VFlowResourcePicker"

    local btn = container.dropdown
    local menu = container.menu
    local scrollChild = container.scrollChild
    local searchBox = container.searchBox
    local scrollFrame = container.scrollFrame

    menu:SetParent(UIParent)
    menu:SetToplevel(true)
    UI.styleScrollFrame(scrollFrame, {
        anchorParent = menu,
        offsetX = -4,
        topOffset = -30,
        bottomOffset = 2,
        width = 6,
    })

    local ic = UI.style.colors.input
    searchBox:SetBackdropColor(ic[1], ic[2], ic[3], ic[4])
    local bc = UI.style.colors.border
    searchBox:SetBackdropBorderColor(bc[1], bc[2], bc[3], bc[4])

    container.label:SetText(label or "")
    local c = UI.style.colors.text
    container.label:SetTextColor(c[1], c[2], c[3], c[4])

    local function updateDisplay(value)
        local name = value
        local path = value

        if LSM then
            local textures = LSM:HashTable("statusbar")
            if textures[value] then
                name = value
                path = textures[value]
            else
                for k, v in pairs(textures) do
                    if v == value then
                        name = k
                        path = v
                        break
                    end
                end
            end
        end

        btn.text:SetText(name or "Select Texture")
        container.preview:SetTexture(path)
        container.preview:Show()
        btn.text:SetPoint("LEFT", 90, 0)
    end

    updateDisplay(value)

    local function buildMenu(filter)
        if not LSM then return end
        local textures = LSM:HashTable("statusbar")
        local sorted = {}
        for k, v in pairs(textures) do
            if not filter or k:lower():find(filter:lower(), 1, true) then
                table.insert(sorted, { name = k, path = v })
            end
        end
        table.sort(sorted, function(a, b) return a.name < b.name end)

        if not menu.items then menu.items = {} end
        for _, item in ipairs(menu.items) do item:Hide() end

        local height = 0
        local ITEM_HEIGHT = 28

        for i, data in ipairs(sorted) do
            local itemBtn = menu.items[i]
            if not itemBtn then
                itemBtn = CreateFrame("Button", nil, scrollChild)
                itemBtn:SetSize(230, ITEM_HEIGHT)

                itemBtn.preview = itemBtn:CreateTexture(nil, "ARTWORK")
                itemBtn.preview:SetPoint("LEFT", 4, 0)
                itemBtn.preview:SetSize(80, 18)

                itemBtn.text = itemBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                itemBtn.text:SetPoint("LEFT", 90, 0)
                itemBtn.text:SetJustifyH("LEFT")

                itemBtn.highlight = itemBtn:CreateTexture(nil, "BACKGROUND")
                itemBtn.highlight:SetAllPoints()
                local hc = UI.style.colors.primary
                itemBtn.highlight:SetColorTexture(hc[1], hc[2], hc[3], 0.3)
                itemBtn.highlight:Hide()

                itemBtn:SetScript("OnEnter", function(self) self.highlight:Show() end)
                itemBtn:SetScript("OnLeave", function(self) self.highlight:Hide() end)

                menu.items[i] = itemBtn
            end

            itemBtn:SetPoint("TOPLEFT", 0, -height)
            itemBtn.text:SetText(data.name)
            itemBtn.preview:SetTexture(data.path)
            itemBtn:Show()

            itemBtn:SetScript("OnClick", function()
                updateDisplay(data.name)
                menu:Hide()
                if onChange then onChange(data.name) end
            end)

            height = height + ITEM_HEIGHT
        end

        scrollChild:SetHeight(height)
        local visibleCount = #sorted
        if visibleCount > 8 then
            visibleCount = 8
        end
        if visibleCount < 1 then
            visibleCount = 1
        end
        menu:SetHeight(34 + visibleCount * ITEM_HEIGHT + 6)
        local viewportHeight = visibleCount * ITEM_HEIGHT + 2
        UI.updateScrollFrameState(scrollFrame, height, viewportHeight)
    end

    searchBox:SetScript("OnTextChanged", function(self)
        buildMenu(self:GetText())
    end)

    btn:SetScript("OnClick", function()
        if menu:IsShown() then
            menu:Hide()
        else
            buildMenu()
            menu:ClearAllPoints()
            menu:SetPoint("TOPLEFT", btn, "BOTTOMLEFT", 0, -2)
            menu:SetPoint("TOPRIGHT", btn, "BOTTOMRIGHT", 0, -2)
            menu:SetFrameStrata("TOOLTIP")
            menu:SetFrameLevel(btn:GetFrameLevel() + 80)
            menu:Show()
            menu:Raise()
            UI.updateScrollFrameState(scrollFrame)
            UI.bindScrollWheel(menu, scrollFrame, 28)
            searchBox:SetText("")
            searchBox:SetFocus()
        end
        PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
    end)

    return container
end

-- =========================================================
-- 字体选择器 (LibSharedMedia font)
-- =========================================================

function UI.fontPicker(parent, label, value, onChange)
    local container = Pool.acquire("VFlowResourcePicker", parent)
    container._vf_poolType = "VFlowResourcePicker"

    local btn = container.dropdown
    local menu = container.menu
    local scrollChild = container.scrollChild
    local searchBox = container.searchBox
    local scrollFrame = container.scrollFrame

    menu:SetParent(UIParent)
    menu:SetToplevel(true)
    UI.styleScrollFrame(scrollFrame, {
        anchorParent = menu,
        offsetX = -4,
        topOffset = -30,
        bottomOffset = 2,
        width = 6,
    })

    local ic = UI.style.colors.input
    searchBox:SetBackdropColor(ic[1], ic[2], ic[3], ic[4])
    local bc = UI.style.colors.border
    searchBox:SetBackdropBorderColor(bc[1], bc[2], bc[3], bc[4])

    container.label:SetText(label or "")
    local c = UI.style.colors.text
    container.label:SetTextColor(c[1], c[2], c[3], c[4])

    -- 隐藏材质预览图，字体无需预览
    container.preview:Hide()
    btn.text:SetPoint("LEFT", 8, 0)

    local function updateDisplay(fontValue)
        local name, path = UI.resolveFontSelection(fontValue)
        name = UI.localizeFontDisplay(name)
        btn.text:SetText(name or L["Select font"])
        if path then
            pcall(function() btn.text:SetFont(path, 10) end)
        end
    end

    updateDisplay(value)

    local function buildMenu(filter)
        if not LSM then return end
        local fonts = LSM:HashTable("font")
        local sorted = {}
        for k, v in pairs(fonts) do
            if not filter or k:lower():find(filter:lower(), 1, true) then
                table.insert(sorted, { name = k, path = v })
            end
        end
        table.sort(sorted, function(a, b) return a.name < b.name end)

        if not menu.items then menu.items = {} end
        for _, item in ipairs(menu.items) do item:Hide() end

        local height = 0
        local ITEM_HEIGHT = 24

        for i, data in ipairs(sorted) do
            local itemBtn = menu.items[i]
            if not itemBtn then
                itemBtn = CreateFrame("Button", nil, scrollChild)
                itemBtn:SetSize(230, ITEM_HEIGHT)

                itemBtn.text = itemBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                itemBtn.text:SetPoint("LEFT", 8, 0)
                itemBtn.text:SetJustifyH("LEFT")

                itemBtn.highlight = itemBtn:CreateTexture(nil, "BACKGROUND")
                itemBtn.highlight:SetAllPoints()
                local hc = UI.style.colors.primary
                itemBtn.highlight:SetColorTexture(hc[1], hc[2], hc[3], 0.3)
                itemBtn.highlight:Hide()

                itemBtn:SetScript("OnEnter", function(self) self.highlight:Show() end)
                itemBtn:SetScript("OnLeave", function(self) self.highlight:Hide() end)

                menu.items[i] = itemBtn
            end

            itemBtn:SetPoint("TOPLEFT", 0, -height)
            itemBtn.text:SetText(data.name)
            pcall(function() itemBtn.text:SetFont(data.path, 12) end)
            itemBtn:Show()

            itemBtn:SetScript("OnClick", function()
                updateDisplay(data.name)
                menu:Hide()
                if onChange then onChange(data.name) end
            end)

            height = height + ITEM_HEIGHT
        end

        scrollChild:SetHeight(height)
        local visibleCount = #sorted
        if visibleCount > 10 then
            visibleCount = 10
        end
        if visibleCount < 1 then
            visibleCount = 1
        end
        menu:SetHeight(34 + visibleCount * ITEM_HEIGHT + 6)
        local viewportHeight = visibleCount * ITEM_HEIGHT + 2
        UI.updateScrollFrameState(scrollFrame, height, viewportHeight)
    end

    searchBox:SetScript("OnTextChanged", function(self)
        buildMenu(self:GetText())
    end)

    btn:SetScript("OnClick", function()
        if menu:IsShown() then
            menu:Hide()
        else
            buildMenu()
            menu:ClearAllPoints()
            menu:SetPoint("TOPLEFT", btn, "BOTTOMLEFT", 0, -2)
            menu:SetPoint("TOPRIGHT", btn, "BOTTOMRIGHT", 0, -2)
            menu:SetFrameStrata("TOOLTIP")
            menu:SetFrameLevel(btn:GetFrameLevel() + 80)
            menu:Show()
            menu:Raise()
            UI.updateScrollFrameState(scrollFrame)
            UI.bindScrollWheel(menu, scrollFrame, 24)
            searchBox:SetText("")
            searchBox:SetFocus()
        end
        PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
    end)

    return container
end
