-- =========================================================
-- ManualEntryReorder — 监控列表：先后点击交换顺序，Shift+点击移除
-- =========================================================

local VFlow = _G.VFlow
if not VFlow then return end

local ManualEntryReorder = {}
VFlow.ManualEntryReorder = ManualEntryReorder

local SELECT_BORDER = { 1, 0.82, 0.2, 1 }

function ManualEntryReorder.create()
    local pick

    return {
        clearUnlessPath = function(path)
            if pick and pick.path ~= path then
                pick = nil
            end
        end,

        clear = function()
            pick = nil
        end,

        borderColor = function(path, orderIndex)
            if not orderIndex then
                return nil
            end
            if pick and pick.path == path and pick.orderIndex == orderIndex then
                return SELECT_BORDER
            end
        end,

        --- @param opts table { path, orderIndex, entryOrder, onShiftRemove, onOrderSaved, bumpVersion }
        handleClick = function(opts)
            if not opts or not opts.path then
                return
            end

            if IsShiftKeyDown() then
                if opts.onShiftRemove and opts.onShiftRemove() then
                    pick = nil
                    if opts.onOrderSaved then
                        opts.onOrderSaved()
                    end
                end
                return
            end

            local oi = opts.orderIndex
            if not oi then
                return
            end

            if not pick or pick.path ~= opts.path then
                pick = { path = opts.path, orderIndex = oi }
                if opts.bumpVersion then
                    opts.bumpVersion()
                end
                return
            end

            if pick.orderIndex == oi then
                pick = nil
                if opts.bumpVersion then
                    opts.bumpVersion()
                end
                return
            end

            local order = opts.entryOrder
            local a, b = pick.orderIndex, oi
            if order and order[a] and order[b] then
                order[a], order[b] = order[b], order[a]
            end
            pick = nil
            if opts.onOrderSaved then
                opts.onOrderSaved()
            end
            if opts.bumpVersion then
                opts.bumpVersion()
            end
        end,
    }
end
