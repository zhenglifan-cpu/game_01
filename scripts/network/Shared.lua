------------------------------------------------------------
-- Shared.lua  —— 客户端/服务端共享代码
------------------------------------------------------------
local Shared = {}
local Settings = require("config.Settings")

Shared.Settings = Settings
Shared.CTRL    = Settings.CTRL
Shared.EVENTS  = Settings.EVENTS
Shared.VARS    = Settings.VARS

------------------------------------------------------------
-- 工具函数
------------------------------------------------------------
function Shared.Clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

function Shared.LerpValue(a, b, t)
    return a + (b - a) * t
end

function Shared.Distance2D(x1, y1, x2, y2)
    local dx = x2 - x1
    local dy = y2 - y1
    return math.sqrt(dx * dx + dy * dy)
end

function Shared.Normalize2D(x, y)
    local len = math.sqrt(x * x + y * y)
    if len < 0.0001 then return 0, 0 end
    return x / len, y / len
end

------------------------------------------------------------
-- 注册远程事件
------------------------------------------------------------
function Shared.RegisterEvents()
    for _, eventName in pairs(Settings.EVENTS) do
        network:RegisterRemoteEvent(eventName)
    end
end

------------------------------------------------------------
-- 创建2D场景（俯视角，正交相机）
------------------------------------------------------------
function Shared.CreateScene()
    local scene = Scene()
    scene:CreateComponent("Octree")
    scene:CreateComponent("DebugRenderer")
    return scene
end

------------------------------------------------------------
-- 获取出生点
------------------------------------------------------------
function Shared.GetSpawnPoint(index)
    local pts = Settings.SpawnPoints
    local i = ((index - 1) % #pts) + 1
    return pts[i]
end

return Shared
