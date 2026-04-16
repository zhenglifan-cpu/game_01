------------------------------------------------------------
-- WolfAI.lua  —— 狼 AI 系统
--
-- 状态机:
--   spawning  → 初始/重生等待
--   hunting   → 搜索并锁定目标羊
--   chasing   → 追逐已锁定的羊
--   dragging  → 抓住羊并拖向地图边缘
--   scared    → 被牧羊犬吓跑（无猎物时）
--   rescued   → 被牧羊犬解救（放下猎物后逃跑）
--   despawned → 成功叼走羊后等待重生
--
-- 坐标说明: 使用 2D 平面 (x, z)，y 始终为 0
------------------------------------------------------------
local Settings    = require("config.Settings")
local Shared      = require("network.Shared")
local MapElements = require("game.MapElements")
local TileMap     = require("game.TileMap")

local W = Settings.Wolf

local WolfAI = {}

------------------------------------------------------------
-- 辅助数学
------------------------------------------------------------
local function dist(ax, az, bx, bz)
    local dx = bx - ax
    local dz = bz - az
    return math.sqrt(dx * dx + dz * dz)
end

local function normalize(x, z)
    local len = math.sqrt(x * x + z * z)
    if len < 0.0001 then return 0, 0 end
    return x / len, z / len
end

------------------------------------------------------------
-- 障碍物探测与绕行
------------------------------------------------------------
local PROBE_DIST   = 1.2   -- 前方探测距离（米）
local PROBE_SIDE   = 0.8   -- 侧方探测距离
local STEER_ANGLE  = math.pi * 0.4  -- 绕行偏转角度（约72°）

--- 检测前方是否被阻挡，若被阻则用法线采样计算滑行方向
--- 返回修正后的方向角；前方畅通返回 nil
local function steerAroundObstacle(x, z, angle)
    local fx = x + math.cos(angle) * PROBE_DIST
    local fz = z + math.sin(angle) * PROBE_DIST
    if TileMap.IsWalkable(fx, fz) then
        return nil  -- 前方畅通
    end

    -- 采样障碍物法线（障碍物表面朝外方向）
    local probe = 0.6
    local nx, nz = 0, 0
    local sampleDirs = {
        { 1, 0}, {-1, 0}, { 0, 1}, { 0,-1},
        { 0.707, 0.707}, {-0.707, 0.707}, { 0.707,-0.707}, {-0.707,-0.707},
    }
    for _, d in ipairs(sampleDirs) do
        if TileMap.IsWalkable(fx + d[1] * probe, fz + d[2] * probe) then
            nx = nx + d[1]
            nz = nz + d[2]
        end
    end
    nx, nz = normalize(nx, nz)

    if nx ~= 0 or nz ~= 0 then
        -- 镜面折射：沿障碍物表面滑行
        local vx = math.cos(angle)
        local vz = math.sin(angle)
        local dot = vx * nx + vz * nz
        -- 去掉法线分量，保留切线分量
        local tx = vx - dot * nx
        local tz = vz - dot * nz
        local tLen = math.sqrt(tx * tx + tz * tz)
        if tLen > 0.01 then
            return math.atan(tz, tx)
        end
    end

    -- 法线采样失败，用左右探测兜底
    local leftAngle  = angle - STEER_ANGLE
    local rightAngle = angle + STEER_ANGLE
    local lx = x + math.cos(leftAngle) * PROBE_SIDE
    local lz = z + math.sin(leftAngle) * PROBE_SIDE
    local rx = x + math.cos(rightAngle) * PROBE_SIDE
    local rz = z + math.sin(rightAngle) * PROBE_SIDE
    local leftOk  = TileMap.IsWalkable(lx, lz)
    local rightOk = TileMap.IsWalkable(rx, rz)
    if leftOk and not rightOk then return leftAngle
    elseif rightOk and not leftOk then return rightAngle
    elseif leftOk and rightOk then
        return math.random() < 0.5 and leftAngle or rightAngle
    else
        return angle + (math.random() < 0.5 and 1 or -1) * math.pi * 0.75
    end
end

--- 碰到不可通行区域时的回退 + 镜面折射（沿障碍物表面滑行）
local function handleTerrainCollision(wolf, dt)
    if TileMap.IsWalkable(wolf.x, wolf.z) then return end

    -- 回退到上一帧位置
    wolf.x = wolf.x - wolf.vx * dt
    wolf.z = wolf.z - wolf.vz * dt

    -- 多方向采样找障碍物表面法线
    local probe = 0.5
    local nx, nz = 0, 0
    -- 8 方向采样（含对角线），获得更精确的法线
    local dirs = {
        { 1, 0}, {-1, 0}, { 0, 1}, { 0,-1},
        { 0.707, 0.707}, {-0.707, 0.707}, { 0.707,-0.707}, {-0.707,-0.707},
    }
    for _, d in ipairs(dirs) do
        if TileMap.IsWalkable(wolf.x + d[1] * probe, wolf.z + d[2] * probe) then
            nx = nx + d[1]
            nz = nz + d[2]
        end
    end
    nx, nz = normalize(nx, nz)

    if nx ~= 0 or nz ~= 0 then
        -- 镜面折射：去掉法线方向分量，保留切线方向（沿表面滑行）
        local dot = wolf.vx * nx + wolf.vz * nz
        if dot < 0 then  -- 只在朝障碍物移动时才修正
            -- 切线分量 = 原速度 - 法线分量
            wolf.vx = wolf.vx - dot * nx
            wolf.vz = wolf.vz - dot * nz
            -- 保持原速度大小
            local slideLen = math.sqrt(wolf.vx * wolf.vx + wolf.vz * wolf.vz)
            if slideLen > 0.01 then
                local spd = wolf.speed > 0 and wolf.speed or (W.Speed * 0.3)
                wolf.vx = wolf.vx / slideLen * spd
                wolf.vz = wolf.vz / slideLen * spd
                wolf.angle = math.atan(wolf.vz, wolf.vx)
                -- 沿滑行方向前进一小步
                wolf.x = wolf.x + wolf.vx * dt
                wolf.z = wolf.z + wolf.vz * dt
            end
        end
    else
        -- 完全被包围：小幅回退 + 朝地图中心移动
        local cx = Settings.Map.Width * 0.5
        local cz = Settings.Map.Height * 0.5
        local dx, dz = normalize(cx - wolf.x, cz - wolf.z)
        wolf.angle = math.atan(dz, dx)
        local spd = wolf.speed > 0 and wolf.speed or (W.Speed * 0.3)
        wolf.vx = dx * spd
        wolf.vz = dz * spd
    end
end

------------------------------------------------------------
-- 单只狼数据结构
------------------------------------------------------------
function WolfAI.NewWolf(id, x, z)
    return {
        id          = id,
        x           = x,
        z           = z,
        vx          = 0,
        vz          = 0,
        speed       = 0,
        angle       = math.random() * math.pi * 2,

        state       = "hunting",    -- 状态机
        stateTimer  = 0,

        -- 追踪
        targetSheepId = nil,        -- 锁定的羊 ID

        -- 拖拽
        capturedSheep = nil,        -- 抓住的羊引用

        -- 逃跑
        fleeAngle   = 0,            -- 逃跑方向
        fleeDuration = 0,           -- 逃跑剩余时间

        -- 驱赶交互（无猎物时）—— 时间窗口吠叫计数
        scareBarkTimestamps = {},   -- 记录每次有效吠叫的时间戳

        -- 解救交互（有猎物时）
        dogOverlapTime = 0,             -- 犬与狼重叠累计时间
        rescueBarkTimestamps = {},      -- 吠叫时间戳（时间窗口计数）

        -- 重生
        respawnTimer = 0,           -- 重生倒计时

        -- 统计
        sheepStolen  = 0,           -- 成功叼走的羊数
    }
end

------------------------------------------------------------
-- 找到距地图边缘最近的方向向量
------------------------------------------------------------
local function dirToNearestEdge(x, z)
    local mapW = Settings.Map.Width
    local mapH = Settings.Map.Height
    local dLeft   = x
    local dRight  = mapW - x
    local dTop    = z
    local dBottom = mapH - z
    local minD = math.min(dLeft, dRight, dTop, dBottom)
    if minD == dLeft then return -1, 0
    elseif minD == dRight then return 1, 0
    elseif minD == dTop then return 0, -1
    else return 0, 1 end
end

------------------------------------------------------------
-- 判断是否到达地图边缘
------------------------------------------------------------
local function isAtMapEdge(x, z)
    local margin = W.DragToEdgeMargin
    local mapW = Settings.Map.Width
    local mapH = Settings.Map.Height
    return x <= margin or x >= mapW - margin
        or z <= margin or z >= mapH - margin
end

------------------------------------------------------------
-- 选择远离羊圈的生成位置
------------------------------------------------------------
function WolfAI.GetSpawnPosition()
    local P = Settings.Pen
    local penCX = P.X + P.Width / 2
    local penCZ = P.Y + P.Height / 2
    local mapW = Settings.Map.Width
    local mapH = Settings.Map.Height
    local margin = W.SpawnMargin

    -- 在地图边缘区域（远离羊圈）随机选择
    for _ = 1, 50 do
        -- 随机选一条边
        local edge = math.random(1, 4)
        local x, z
        if edge == 1 then     -- 左边
            x = margin
            z = margin + math.random() * (mapH - 2 * margin)
        elseif edge == 2 then -- 右边
            x = mapW - margin
            z = margin + math.random() * (mapH - 2 * margin)
        elseif edge == 3 then -- 上边
            x = margin + math.random() * (mapW - 2 * margin)
            z = margin
        else                  -- 下边
            x = margin + math.random() * (mapW - 2 * margin)
            z = mapH - margin
        end
        -- 确保远离羊圈（至少15米）
        local dToPen = dist(x, z, penCX, penCZ)
        if dToPen > 15 and TileMap.IsWalkable(x, z) then
            return x, z
        end
    end
    -- 回退：左下角
    return margin, mapH - margin
end

------------------------------------------------------------
-- 在消失点附近的地图边缘偏移 0-10 网格单位重生
------------------------------------------------------------
function WolfAI.GetSpawnNearPoint(despX, despZ)
    local mapW = Settings.Map.Width
    local mapH = Settings.Map.Height
    local margin = W.SpawnMargin
    local tileSize = Settings.TileMap and Settings.TileMap.TileSize or 2  -- 默认 2 米/格
    local maxOffset = W.RespawnEdgeOffset * tileSize  -- 转换为米

    -- 判断消失在哪条边
    local dLeft   = despX
    local dRight  = mapW - despX
    local dTop    = despZ
    local dBottom = mapH - despZ
    local minD = math.min(dLeft, dRight, dTop, dBottom)

    -- 沿该边偏移
    local offset = (math.random() * 2 - 1) * maxOffset  -- -maxOffset ~ +maxOffset
    local sx, sz

    if minD == dLeft then        -- 左边
        sx = margin
        sz = Shared.Clamp(despZ + offset, margin, mapH - margin)
    elseif minD == dRight then   -- 右边
        sx = mapW - margin
        sz = Shared.Clamp(despZ + offset, margin, mapH - margin)
    elseif minD == dTop then     -- 上边
        sz = margin
        sx = Shared.Clamp(despX + offset, margin, mapW - margin)
    else                         -- 下边
        sz = mapH - margin
        sx = Shared.Clamp(despX + offset, margin, mapW - margin)
    end

    -- 确保可通行
    if TileMap.IsWalkable(sx, sz) then
        return sx, sz
    end

    -- 不可通行则多次小偏移尝试
    for _ = 1, 20 do
        local tryOffset = (math.random() * 2 - 1) * maxOffset
        local tx, tz
        if minD == dLeft or minD == dRight then
            tx = sx
            tz = Shared.Clamp(despZ + tryOffset, margin, mapH - margin)
        else
            tz = sz
            tx = Shared.Clamp(despX + tryOffset, margin, mapW - margin)
        end
        if TileMap.IsWalkable(tx, tz) then
            return tx, tz
        end
    end

    -- 回退到默认生成
    return WolfAI.GetSpawnPosition()
end

------------------------------------------------------------
-- 选择目标羊：优先落单、小群
------------------------------------------------------------
local function selectTarget(wolf, flock, wolves)
    local bestScore = -math.huge
    local bestSheep = nil

    for _, sheep in ipairs(flock) do
        if sheep.penned then goto continue end
        if sheep.captured then goto continue end  -- 已被其他狼抓住

        local d = dist(wolf.x, wolf.z, sheep.x, sheep.z)
        if d > W.DetectRange then goto continue end

        -- 计算该羊附近的同伴数量（越少越容易被盯上）
        local nearbyCount = 0
        for _, other in ipairs(flock) do
            if other.id ~= sheep.id and not other.penned and not other.captured then
                local od = dist(sheep.x, sheep.z, other.x, other.z)
                if od < 5.0 then
                    nearbyCount = nearbyCount + 1
                end
            end
        end

        -- 检查是否已被其他狼锁定
        local alreadyTargeted = false
        for _, ow in ipairs(wolves) do
            if ow.id ~= wolf.id and ow.targetSheepId == sheep.id
               and (ow.state == "chasing" or ow.state == "dragging") then
                alreadyTargeted = true
                break
            end
        end

        -- 得分：距离越近越好，落单加分
        local distScore = (W.DetectRange - d) * 1.0
        local isolationScore = math.max(0, W.IsolationBonus - nearbyCount * 1.5)
        local targetPenalty = alreadyTargeted and -10 or 0
        local score = distScore + isolationScore + targetPenalty

        if score > bestScore then
            bestScore = score
            bestSheep = sheep
        end
        ::continue::
    end

    return bestSheep
end

------------------------------------------------------------
-- 通过 ID 在 flock 中查找羊
------------------------------------------------------------
local function findSheepById(flock, sheepId)
    if not sheepId then return nil end
    for _, sheep in ipairs(flock) do
        if sheep.id == sheepId then return sheep end
    end
    return nil
end

------------------------------------------------------------
-- 主更新函数
------------------------------------------------------------
---@param wolves table   狼列表
---@param flock table    羊群
---@param dogs table     犬列表 {x, z, speed, angle, barking}
---@param gameState table 游戏状态
---@param dt number      帧间隔
function WolfAI.Update(wolves, flock, dogs, gameState, dt)
    for _, wolf in ipairs(wolves) do
        wolf.stateTimer = wolf.stateTimer + dt

        -- ── despawned: 等待重生 ──
        if wolf.state == "despawned" then
            wolf.respawnTimer = wolf.respawnTimer - dt
            if wolf.respawnTimer <= 0 then
                local sx, sz
                if wolf.despawnX and wolf.despawnZ then
                    -- 从消失点沿边缘偏移 0-10 网格单位重生
                    sx, sz = WolfAI.GetSpawnNearPoint(wolf.despawnX, wolf.despawnZ)
                    wolf.despawnX = nil
                    wolf.despawnZ = nil
                else
                    sx, sz = WolfAI.GetSpawnPosition()
                end
                wolf.x = sx
                wolf.z = sz
                wolf.vx = 0
                wolf.vz = 0
                wolf.speed = 0
                wolf.state = "hunting"
                wolf.stateTimer = 0
                wolf.targetSheepId = nil
                wolf.capturedSheep = nil
                wolf.dogOverlapTime = 0
                wolf.rescueBarkTimestamps = {}
                print("[WolfAI] Wolf " .. wolf.id .. " respawned at (" ..
                    string.format("%.1f", sx) .. ", " .. string.format("%.1f", sz) .. ")")
            end
            goto nextWolf
        end

        -- ── scared: 无猎物被吓跑 → 向最近边缘奔跑 ──
        if wolf.state == "scared" then
            wolf.fleeDuration = wolf.fleeDuration - dt
            -- 向最近地图边缘全速奔跑
            local edgeDx, edgeDz = dirToNearestEdge(wolf.x, wolf.z)
            wolf.fleeAngle = math.atan(edgeDz, edgeDx)
            local spd = W.Speed
            wolf.vx = edgeDx * spd
            wolf.vz = edgeDz * spd

            wolf.x = wolf.x + wolf.vx * dt
            wolf.z = wolf.z + wolf.vz * dt

            -- 到达地图边缘 → 消失并等待重生
            if isAtMapEdge(wolf.x, wolf.z) then
                wolf.despawnX = wolf.x
                wolf.despawnZ = wolf.z
                wolf.x = Shared.Clamp(wolf.x, W.Radius, Settings.Map.Width - W.Radius)
                wolf.z = Shared.Clamp(wolf.z, W.Radius, Settings.Map.Height - W.Radius)
                wolf.state = "despawned"
                wolf.stateTimer = 0
                wolf.respawnTimer = W.EdgeFleeDespawnTime
                wolf.vx = 0
                wolf.vz = 0
                wolf.speed = 0
                print("[WolfAI] Wolf " .. wolf.id .. " fled to edge, despawned. Respawn in " .. W.EdgeFleeDespawnTime .. "s")
                goto nextWolf
            end

            -- 边界限制
            local r = W.Radius
            wolf.x = Shared.Clamp(wolf.x, r, Settings.Map.Width - r)
            wolf.z = Shared.Clamp(wolf.z, r, Settings.Map.Height - r)
            wolf.speed = spd
            wolf.angle = wolf.fleeAngle

            if wolf.fleeDuration <= 0 then
                -- 5秒跑完未到边缘，重新进入 hunting
                wolf.state = "hunting"
                wolf.stateTimer = 0
                wolf.targetSheepId = nil
            end
            goto nextWolf
        end

        -- ── rescued: 放下猎物后逃向边缘 ──
        if wolf.state == "rescued" then
            wolf.fleeDuration = wolf.fleeDuration - dt
            local spd = W.Speed * W.FleeSpeedMult
            wolf.vx = math.cos(wolf.fleeAngle) * spd
            wolf.vz = math.sin(wolf.fleeAngle) * spd

            wolf.x = wolf.x + wolf.vx * dt
            wolf.z = wolf.z + wolf.vz * dt

            -- 到达地图边缘 → 消失并等待重生
            if isAtMapEdge(wolf.x, wolf.z) then
                wolf.despawnX = wolf.x
                wolf.despawnZ = wolf.z
                wolf.x = Shared.Clamp(wolf.x, W.Radius, Settings.Map.Width - W.Radius)
                wolf.z = Shared.Clamp(wolf.z, W.Radius, Settings.Map.Height - W.Radius)
                wolf.state = "despawned"
                wolf.stateTimer = 0
                wolf.respawnTimer = W.EdgeFleeDespawnTime
                wolf.vx = 0
                wolf.vz = 0
                wolf.speed = 0
                wolf.dogOverlapTime = 0
                wolf.rescueBarkTimestamps = {}
                print("[WolfAI] Wolf " .. wolf.id .. " rescued & fled to edge, despawned. Respawn in " .. W.EdgeFleeDespawnTime .. "s")
                goto nextWolf
            end

            local r = W.Radius
            wolf.x = Shared.Clamp(wolf.x, r, Settings.Map.Width - r)
            wolf.z = Shared.Clamp(wolf.z, r, Settings.Map.Height - r)
            wolf.speed = spd
            wolf.angle = wolf.fleeAngle

            if wolf.fleeDuration <= 0 then
                wolf.state = "hunting"
                wolf.stateTimer = 0
                wolf.targetSheepId = nil
                wolf.dogOverlapTime = 0
                wolf.rescueBarkTimestamps = {}
            end
            goto nextWolf
        end

        -- ── hunting: 搜索目标 ──
        if wolf.state == "hunting" then
            local target = selectTarget(wolf, flock, wolves)
            if target then
                wolf.targetSheepId = target.id
                wolf.state = "chasing"
                wolf.stateTimer = 0
            else
                -- 无目标：优先向地图中心区域移动，加随机扰动
                local mapCX = Settings.Map.Width * 0.5
                local mapCZ = Settings.Map.Height * 0.5
                local toCenterDx = mapCX - wolf.x
                local toCenterDz = mapCZ - wolf.z
                local toCenterDist = math.sqrt(toCenterDx * toCenterDx + toCenterDz * toCenterDz)

                if toCenterDist > 10.0 then
                    -- 距中心较远：朝中心方向移动，加少量随机偏转
                    local centerAngle = math.atan(toCenterDz, toCenterDx)
                    -- 每帧平滑转向中心（加±15°随机扰动避免直线）
                    local jitter = (math.random() - 0.5) * 0.5  -- ±~15°
                    local targetAngle = centerAngle + jitter
                    -- 平滑插值当前角度到目标角度
                    local diff = targetAngle - wolf.angle
                    -- 规范化角度差到 [-π, π]
                    diff = (diff + math.pi) % (2 * math.pi) - math.pi
                    wolf.angle = wolf.angle + diff * math.min(1.0, 2.0 * dt)
                else
                    -- 已在中心附近：小范围随机游荡
                    wolf.stateTimer = wolf.stateTimer + dt
                    if wolf.stateTimer > 2.0 then
                        wolf.angle = wolf.angle + (math.random() - 0.5) * 1.2
                        wolf.stateTimer = 0
                    end
                end

                -- 前方障碍物探测 → 沿障碍物滑行
                local steer = steerAroundObstacle(wolf.x, wolf.z, wolf.angle)
                if steer then
                    wolf.angle = steer
                end
                local wanderSpd = W.Speed * 0.5
                wolf.vx = math.cos(wolf.angle) * wanderSpd
                wolf.vz = math.sin(wolf.angle) * wanderSpd
                wolf.x = wolf.x + wolf.vx * dt
                wolf.z = wolf.z + wolf.vz * dt
                local r = W.Radius
                wolf.x = Shared.Clamp(wolf.x, r, Settings.Map.Width - r)
                wolf.z = Shared.Clamp(wolf.z, r, Settings.Map.Height - r)
                wolf.speed = wanderSpd
            end
        end

        -- ── chasing: 追逐锁定的羊 ──
        if wolf.state == "chasing" then
            local target = findSheepById(flock, wolf.targetSheepId)
            if not target or target.penned or target.captured then
                -- 目标丢失，重新搜索
                wolf.state = "hunting"
                wolf.stateTimer = 0
                wolf.targetSheepId = nil
                goto checkDogInteraction
            end

            -- 朝目标移动
            local dx = target.x - wolf.x
            local dz = target.z - wolf.z
            local d = dist(wolf.x, wolf.z, target.x, target.z)
            local nx, nz = normalize(dx, dz)
            local chaseAngle = math.atan(dz, dx)
            -- 前方障碍物探测 → 绕行
            local steer = steerAroundObstacle(wolf.x, wolf.z, chaseAngle)
            if steer then
                nx = math.cos(steer)
                nz = math.sin(steer)
            end
            local spd = W.Speed
            wolf.vx = nx * spd
            wolf.vz = nz * spd
            wolf.x = wolf.x + wolf.vx * dt
            wolf.z = wolf.z + wolf.vz * dt
            wolf.speed = spd
            if d > 0.1 then
                wolf.angle = math.atan(dz, dx)
            end

            -- 边界限制
            local r = W.Radius
            wolf.x = Shared.Clamp(wolf.x, r, Settings.Map.Width - r)
            wolf.z = Shared.Clamp(wolf.z, r, Settings.Map.Height - r)

            -- 抓住判定
            if d < W.CatchRadius then
                wolf.state = "dragging"
                wolf.stateTimer = 0
                wolf.capturedSheep = target
                target.captured = true
                target.capturedByWolfId = wolf.id
                wolf.dogOverlapTime = 0
                wolf.rescueBarkTimestamps = {}
                print("[WolfAI] Wolf " .. wolf.id .. " captured sheep " .. target.id .. "!")
            end
        end

        -- ── dragging: 拖拽羊向地图边缘 ──
        if wolf.state == "dragging" then
            local captSheep = wolf.capturedSheep
            if not captSheep then
                wolf.state = "hunting"
                wolf.stateTimer = 0
                goto checkDogInteraction
            end

            -- 朝最近的地图边缘移动
            local edgeDx, edgeDz = dirToNearestEdge(wolf.x, wolf.z)
            local dragAngle = math.atan(edgeDz, edgeDx)
            -- 前方障碍物探测 → 绕行
            local steer = steerAroundObstacle(wolf.x, wolf.z, dragAngle)
            if steer then
                dragAngle = steer
                edgeDx = math.cos(dragAngle)
                edgeDz = math.sin(dragAngle)
            end
            local spd = W.Speed * W.DragSpeedMult
            wolf.vx = edgeDx * spd
            wolf.vz = edgeDz * spd
            wolf.x = wolf.x + wolf.vx * dt
            wolf.z = wolf.z + wolf.vz * dt
            wolf.speed = spd
            if math.abs(edgeDx) + math.abs(edgeDz) > 0.01 then
                wolf.angle = dragAngle
            end

            -- 拖拽状态：不能进入最外圈网格
            local edgeClamp = W.DragEdgeClamp
            wolf.x = Shared.Clamp(wolf.x, edgeClamp, Settings.Map.Width - edgeClamp)
            wolf.z = Shared.Clamp(wolf.z, edgeClamp, Settings.Map.Height - edgeClamp)

            -- 拖拽羊跟随狼的位置（偏移一点）
            local offsetDist = 0.8
            captSheep.x = wolf.x - math.cos(wolf.angle) * offsetDist
            captSheep.z = wolf.z - math.sin(wolf.angle) * offsetDist
            captSheep.vx = wolf.vx
            captSheep.vz = wolf.vz
            captSheep.speed = spd
            captSheep.angle = wolf.angle

            -- 检查是否到达地图边缘
            if isAtMapEdge(wolf.x, wolf.z) then
                -- 到达边缘后需要持续拖拽 EdgeDragTime 秒才能叼走
                wolf.edgeDragTimer = (wolf.edgeDragTimer or 0) + dt

                -- 到达边缘后停在原地拖拽
                wolf.vx = 0
                wolf.vz = 0
                wolf.speed = 0
                captSheep.vx = 0
                captSheep.vz = 0
                captSheep.speed = 0

                if wolf.edgeDragTimer >= W.EdgeDragTime then
                    -- 成功叼走！
                    captSheep.captured = false
                    captSheep.penned = true  -- 标记为已移除（借用 penned 标记）
                    captSheep.stolen = true  -- 特殊标记：被狼叼走
                    captSheep.x = -100       -- 移出视野
                    captSheep.z = -100
                    captSheep.vx = 0
                    captSheep.vz = 0
                    captSheep.speed = 0
                    wolf.sheepStolen = wolf.sheepStolen + 1
                    wolf.capturedSheep = nil
                    wolf.targetSheepId = nil
                    wolf.edgeDragTimer = nil

                    -- 更新游戏状态
                    gameState.sheepLost = (gameState.sheepLost or 0) + 1
                    gameState.totalSheep = gameState.totalSheep - 1

                    print("[WolfAI] Wolf " .. wolf.id .. " stole sheep! Lost: " .. gameState.sheepLost)

                    -- 记录消失位置（用于偏移重生）
                    wolf.despawnX = wolf.x
                    wolf.despawnZ = wolf.z

                    -- 进入重生等待
                    wolf.state = "despawned"
                    wolf.stateTimer = 0
                    wolf.respawnTimer = W.RespawnTime
                    wolf.vx = 0
                    wolf.vz = 0
                    wolf.speed = 0
                    goto nextWolf
                end
            else
                -- 还没到边缘，重置计时器
                wolf.edgeDragTimer = nil
            end
        end

        -- ── 犬交互检测（chasing/dragging 状态共用）──
        ::checkDogInteraction::
        if wolf.state == "chasing" or wolf.state == "hunting" then
            -- 无猎物：6秒窗口内吠叫8次可驱赶
            local now = wolf.stateTimer  -- 用全局累加的 stateTimer 作为时间基准不可靠，改用 gameTime
            local gameTime = gameState.elapsed or 0

            for _, dog in ipairs(dogs) do
                local d = dist(wolf.x, wolf.z, dog.x, dog.z)
                -- 在吠叫影响范围内计数
                if dog.barking and d < Settings.Dog.BarkRadius then
                    table.insert(wolf.scareBarkTimestamps, gameTime)
                end
            end

            -- 清除超出时间窗口的旧吠叫记录
            local window = W.ScareBarkWindow
            local freshBarks = {}
            for _, t in ipairs(wolf.scareBarkTimestamps) do
                if gameTime - t <= window then
                    table.insert(freshBarks, t)
                end
            end
            wolf.scareBarkTimestamps = freshBarks

            -- 判定是否达到驱赶条件
            if #wolf.scareBarkTimestamps >= W.ScareBarkCount then
                -- 向最近边缘方向逃跑
                local edgeDx, edgeDz = dirToNearestEdge(wolf.x, wolf.z)
                wolf.fleeAngle = math.atan(edgeDz, edgeDx)
                wolf.fleeDuration = W.ScaredFleeDuration
                wolf.state = "scared"
                wolf.stateTimer = 0
                wolf.targetSheepId = nil
                wolf.scareBarkTimestamps = {}
                print("[WolfAI] Wolf " .. wolf.id .. " scared by " .. #freshBarks .. " barks in " .. window .. "s window!")
            end
        elseif wolf.state == "dragging" then
            -- 有猎物：犬重叠2秒 或 3秒内吠叫3次 即可解救
            local gameTime = gameState.elapsed or 0
            local anyDogOverlapping = false
            for _, dog in ipairs(dogs) do
                local d = dist(wolf.x, wolf.z, dog.x, dog.z)
                if d < W.CatchRadius + Settings.Dog.Radius + 0.5 then
                    anyDogOverlapping = true
                    -- 记录吠叫时间戳
                    if dog.barking then
                        table.insert(wolf.rescueBarkTimestamps, gameTime)
                    end
                end
            end

            if anyDogOverlapping then
                wolf.dogOverlapTime = wolf.dogOverlapTime + dt
            else
                -- 犬离开后缓慢重置（不完全归零，给玩家宽限）
                wolf.dogOverlapTime = math.max(0, wolf.dogOverlapTime - dt * 0.5)
            end

            -- 清除超出时间窗口的旧吠叫记录
            local barkWindow = W.RescueBarkWindow
            local freshBarks = {}
            for _, t in ipairs(wolf.rescueBarkTimestamps) do
                if gameTime - t <= barkWindow then
                    table.insert(freshBarks, t)
                end
            end
            wolf.rescueBarkTimestamps = freshBarks

            -- 解救判定（任一条件满足即可）
            local overlapOk = wolf.dogOverlapTime >= W.RescueOverlapTime
            local barkOk    = #wolf.rescueBarkTimestamps >= W.RescueBarkCount
            if overlapOk or barkOk then
                -- 成功解救！
                local captSheep = wolf.capturedSheep
                if captSheep then
                    captSheep.captured = false
                    captSheep.capturedByWolfId = nil
                    captSheep.state = "rescued_flee"
                    captSheep.stateTimer = 0
                    print("[WolfAI] Sheep " .. captSheep.id .. " rescued from wolf " .. wolf.id .. "! (rescued_flee)")
                end

                wolf.capturedSheep = nil
                wolf.targetSheepId = nil
                wolf.dogOverlapTime = 0
                wolf.rescueBarkTimestamps = {}
                wolf.edgeDragTimer = nil

                -- 逃向地图边缘
                local edgeDx, edgeDz = dirToNearestEdge(wolf.x, wolf.z)
                wolf.fleeAngle = math.atan(edgeDz, edgeDx)
                wolf.fleeDuration = W.RescueFleeDuration
                wolf.state = "rescued"
                wolf.stateTimer = 0
            end
        end

        -- 避开不可通行区域（回退 + 反射）
        handleTerrainCollision(wolf, dt)

        ::nextWolf::
    end
end

------------------------------------------------------------
-- 创建狼群
------------------------------------------------------------
function WolfAI.CreatePack(count)
    local pack = {}
    for i = 1, count do
        local x, z = WolfAI.GetSpawnPosition()
        pack[i] = WolfAI.NewWolf(i, x, z)
        print("[WolfAI] Wolf " .. i .. " spawned at (" ..
            string.format("%.1f", x) .. ", " .. string.format("%.1f", z) .. ")")
    end
    return pack
end

------------------------------------------------------------
-- 获取狼对羊群的威胁信息（供 SheepAI 使用）
-- 返回 dogs 格式的列表，使羊把狼当作威胁源逃跑
------------------------------------------------------------
function WolfAI.GetThreats(wolves)
    local threats = {}
    for _, wolf in ipairs(wolves) do
        if wolf.state ~= "despawned" and wolf.state ~= "scared"
           and wolf.state ~= "rescued" then
            table.insert(threats, {
                x       = wolf.x,
                z       = wolf.z,
                speed   = wolf.speed,
                angle   = wolf.angle,
                barking = false,  -- 狼不吠叫，但作为威胁源存在
            })
        end
    end
    return threats
end

return WolfAI
