-- FrameData — 帧关联数据的统一存储
-- 使用 weak-key table，帧被GC时数据自动释放

local VFlow = _G.VFlow

local FrameData = setmetatable({}, { __mode = "k" })

function VFlow.FD(frame)
    local d = FrameData[frame]
    if not d then
        d = {}
        FrameData[frame] = d
    end
    return d
end

function VFlow.FDClear(frame)
    FrameData[frame] = nil
end
