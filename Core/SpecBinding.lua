--[[ Core 依赖：
  - Infra/Store.lua：listProfiles、setCurrentProfile（切换专精时自动切换档案）
]]

-- =========================================================
-- SECTION 1: 模块定义
-- =========================================================

local VFlow = _G.VFlow
if not VFlow then return end

local SpecBinding = {}
VFlow.SpecBinding = SpecBinding

local L = VFlow.L

-- =========================================================
-- SECTION 2: 存储帮助函数
-- =========================================================

local function getCharacterKey()
    local name = UnitName and UnitName("player")
    local realm = GetRealmName and GetRealmName()
    if type(name) ~= "string" or name == "" then return nil end
    if type(realm) ~= "string" or realm == "" then return nil end
    return name .. " - " .. realm
end

local function getBindingsTable(createIfMissing)
    if type(VFlowDB) ~= "table" then return nil end
    local meta = VFlowDB["__meta"]
    if type(meta) ~= "table" then return nil end
    if type(meta.specBindings) ~= "table" then
        if not createIfMissing then return nil end
        meta.specBindings = {}
    end
    local charKey = getCharacterKey()
    if not charKey then return nil end
    if type(meta.specBindings[charKey]) ~= "table" then
        if not createIfMissing then return nil end
        meta.specBindings[charKey] = {}
    end
    return meta.specBindings[charKey]
end

-- =========================================================
-- SECTION 3: 公开接口
-- =========================================================

--- 绑定专精到档案，profileName 为 nil 则解除绑定
function SpecBinding.set(specIndex, profileName)
    local bindings = getBindingsTable(true)
    if not bindings then return end
    bindings[specIndex] = profileName
end

--- 获取专精绑定的档案名，无绑定返回 nil
function SpecBinding.get(specIndex)
    local bindings = getBindingsTable(false)
    if not bindings then return nil end
    return bindings[specIndex]
end

--- 返回当前角色所有绑定 { [specIndex] = profileName }
function SpecBinding.getAll()
    local bindings = getBindingsTable(false)
    if not bindings then return {} end
    local result = {}
    for k, v in pairs(bindings) do
        result[k] = v
    end
    return result
end

-- =========================================================
-- SECTION 4: 自动切换
-- =========================================================

VFlow.on("PLAYER_SPECIALIZATION_CHANGED", "VFlow.SpecBinding", function()
    local specIndex = GetSpecialization()
    if not specIndex then return end

    local profileName = SpecBinding.get(specIndex)
    if not profileName then return end

    local profiles = VFlow.Store.listProfiles()
    local exists = false
    for _, name in ipairs(profiles) do
        if name == profileName then
            exists = true
            break
        end
    end

    if not exists then
        print("|cffff8800VFlow:|r " .. string.format(L["Spec binding profile not found: %s"], profileName))
        return
    end

    local ok, err = VFlow.Store.setCurrentProfile(profileName)
    if ok then
        print("|cff00ff00VFlow:|r " .. string.format(L["Switched to config: %s"], profileName))
    else
        print("|cffff0000VFlow:|r " .. string.format(L["Switch config failed: %s"], tostring(err)))
    end
end)
