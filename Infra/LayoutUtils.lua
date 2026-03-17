-- =========================================================
-- VFlow Layout Utils
-- 提供布局构建的工具函数
-- =========================================================

local VFlow = _G.VFlow
if not VFlow then return end

VFlow.LayoutUtils = {
    -- 合并多个layout数组（支持nil和false，用于条件性添加）
    -- 用法: mergeLayouts(layout1, condition and layout2, layout3)
    -- 当condition为false时，layout2会被跳过
    mergeLayouts = function(...)
        local result = {}
        for i = 1, select("#", ...) do
            local layout = select(i, ...)
            if type(layout) == "table" then
                for _, item in ipairs(layout) do
                    table.insert(result, item)
                end
            end
            -- nil和false会被自动跳过
        end
        return result
    end,
}
