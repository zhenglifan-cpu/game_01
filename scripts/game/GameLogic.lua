------------------------------------------------------------
-- GameLogic.lua  —— 围栏检测 / 羊毛收集 / 胜负判定
------------------------------------------------------------
local Settings    = require("config.Settings")
local Shared      = require("network.Shared")
local MapElements = require("game.MapElements")

local GameLogic = {}

------------------------------------------------------------
-- 初始化游戏状态
------------------------------------------------------------
function GameLogic.NewState()
    return {
        woolCollected = 0,
        sheepPenned   = 0,
        totalSheep    = Settings.Sheep.Count,
        sheepLost     = 0,       -- 被狼叼走的羊数量
        gameOver      = false,
        gameWon       = false,
        elapsed       = 0,
    }
end

------------------------------------------------------------
-- 障碍物列表 (AABB: {x1, z1, x2, z2})
-- 地图边界围墙 + 围栏 + 地图元素（河流/石头）
------------------------------------------------------------
function GameLogic.CreateObstacles()
    local obstacles = {}
    local W = Settings.Map.Width
    local H = Settings.Map.Height
    local T = Settings.Map.FenceThick
    local P = Settings.Pen

    -- 地图四周围墙
    table.insert(obstacles, {-T, -T, W + T, 0})          -- 下墙
    table.insert(obstacles, {-T, H, W + T, H + T})       -- 上墙
    table.insert(obstacles, {-T, -T, 0, H + T})           -- 左墙
    table.insert(obstacles, {W, -T, W + T, H + T})        -- 右墙

    -- 围栏区域围墙（留一个门口）
    local px1 = P.X
    local pz1 = P.Y
    local px2 = P.X + P.Width
    local pz2 = P.Y + P.Height

    -- 围栏上边
    table.insert(obstacles, {px1, pz2, px2, pz2 + T})
    -- 围栏右边
    table.insert(obstacles, {px2, pz1, px2 + T, pz2 + T})
    -- 围栏下边
    table.insert(obstacles, {px1, pz1 - T, px2, pz1})

    -- 围栏左边（有门口）
    local gateCenter = (pz1 + pz2) / 2
    local halfGate   = P.GateWidth / 2
    table.insert(obstacles, {px1 - T, gateCenter + halfGate, px1, pz2})
    table.insert(obstacles, {px1 - T, pz1, px1, gateCenter - halfGate})

    -- 地图元素生成的障碍（河流段 + 石头）
    local mapObstacles = MapElements.CreateObstacleAABBs()
    for _, obs in ipairs(mapObstacles) do
        table.insert(obstacles, obs)
    end

    return obstacles
end

------------------------------------------------------------
-- 检测羊是否进入围栏
------------------------------------------------------------
function GameLogic.CheckPenning(flock, state)
    local P = Settings.Pen
    local px1 = P.X
    local pz1 = P.Y
    local px2 = P.X + P.Width
    local pz2 = P.Y + P.Height
    local newlyPenned = {}

    for _, sheep in ipairs(flock) do
        if not sheep.penned then
            if sheep.x >= px1 and sheep.x <= px2
               and sheep.z >= pz1 and sheep.z <= pz2 then
                sheep.penned = true
                state.sheepPenned = state.sheepPenned + 1
                state.woolCollected = state.woolCollected + Settings.Game.WoolPerSheep
                table.insert(newlyPenned, sheep.id)
            end
        end
    end

    -- 胜利检测
    if state.sheepPenned >= state.totalSheep then
        state.gameOver = true
        state.gameWon  = true
    end

    return newlyPenned
end

------------------------------------------------------------
-- 建造系统资源管理
------------------------------------------------------------

--- 检查是否有足够羊毛建造
function GameLogic.CanBuild(state, cost)
    return state.woolCollected >= cost
end

--- 消耗羊毛
function GameLogic.SpendWool(state, cost)
    if state.woolCollected < cost then return false end
    state.woolCollected = state.woolCollected - cost
    return true
end

------------------------------------------------------------
-- 围栏门位置（用于渲染和碰撞检测）
------------------------------------------------------------
function GameLogic.GetGatePosition()
    local P = Settings.Pen
    local gateCenter = (P.Y + P.Y + P.Height) / 2
    return {
        x = P.X,
        z = gateCenter,
        width = Settings.Map.FenceThick,
        height = P.GateWidth,
    }
end

return GameLogic
