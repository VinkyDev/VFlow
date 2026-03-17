-- =========================================================
-- VFlow MasqueSupport - Masque皮肤支持
-- =========================================================

local VFlow = _G.VFlow
if not VFlow then return end

local Masque = LibStub and LibStub("Masque", true)
local masqueGroup = Masque and Masque:Group("VFlow")

local MasqueSupport = {
    registeredButtons = {},
}
VFlow.MasqueSupport = MasqueSupport

---检查 Masque 是否已安装
---@return boolean
function MasqueSupport:IsInstalled()
    return Masque ~= nil
end

---检查 Masque 是否激活(已安装且未禁用)
---@return boolean
function MasqueSupport:IsActive()
    return masqueGroup ~= nil and not masqueGroup.db.Disabled
end

---注册一个按钮到 Masque
---@param button table 按钮帧
---@param icon table 图标纹理
---@param border? table 边框帧(可选)
function MasqueSupport:RegisterButton(button, icon, border)
    if not masqueGroup then
        return
    end

    if self.registeredButtons[button] then
        return
    end

    -- 注册到 Masque
    -- 注意：VFlow接管的图标结构可能因Viewer不同而异，需要调用者传入正确的组件
    local buttonData = {
        Icon = icon,
        Cooldown = button.Cooldown,
        ChargeCooldown = button.ChargeCooldown,
    }

    -- 如果有边框,也注册边框(作为 Normal 纹理)
    if border then
        buttonData.Normal = border
    end

    masqueGroup:AddButton(button, buttonData)
    self.registeredButtons[button] = true
end

---取消注册一个按钮
---@param button table 按钮帧
function MasqueSupport:UnregisterButton(button)
    if not masqueGroup or not self.registeredButtons[button] then
        return
    end

    masqueGroup:RemoveButton(button)
    self.registeredButtons[button] = nil
end

---刷新所有已注册的按钮皮肤
function MasqueSupport:ReSkin()
    if not masqueGroup then
        return
    end
    masqueGroup:ReSkin()
end

-- 注册 Masque 皮肤改变回调
if masqueGroup then
    masqueGroup:RegisterCallback(function()
        -- 延迟刷新,因为 Masque 在回调后才修改按钮区域
        C_Timer.After(0.1, function()
            -- 触发 VFlow 的刷新（如果需要重新布局）
            if VFlow.MainUI and VFlow.MainUI.refresh then
                -- 这里其实应该触发 CooldownStyle 的 RequestRefresh
                -- 但 CooldownStyle 是 Core 模块，MasqueSupport 也是 Core，依赖关系可能要注意
                -- 我们可以通过事件总线或者全局函数调用
            end
            
            -- 也可以直接调用 ReSkin，Masque自己会处理，主要是VFlow的布局可能需要调整
        end)
    end)
end
