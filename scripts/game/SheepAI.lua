------------------------------------------------------------
-- SheepAI.lua  —— Boids 羊群 AI 系统
--
-- 基于《羊群AI简版》文档实现:
--   四规则: Separation + Alignment + Cohesion + Escape
--   六状态: Idle / Flock / Alert / Panic / Recover / RescuedFlee
--
-- 地形交互:
--   河流: 不可穿越（通过障碍物AABB阻挡）+ 额外河流避让力
--   山丘: 移动减速
--   树林: 缩短犬感知距离（羊更难被发现）
--   石头: 不可穿越（通过障碍物AABB阻挡）+ 圆形推力
--
-- 坐标说明: 使用 2D 平面 (x, z)，y 始终为 0
------------------------------------------------------------
local Settings    = require("config.Settings")
local Shared      = require("network.Shared")
local MapElements = require("game.MapElements")
local TileMap     = require("game.TileMap")
local S = Settings.Sheep

local SheepAI = {}

------------------------------------------------------------
-- 单只羊数据结构
------------------------------------------------------------
function SheepAI.NewSheep(id, x, z)
    return {
        id      = id,
        x       = x,
        z       = z,
        vx      = 0,
        vz      = 0,
        speed   = 0,
        angle   = math.random() * math.pi * 2,

        state       = "idle",      -- idle / flock / alert / panic / recover
        stateTimer  = 0,
        panicCount  = 0,           -- 连续受惊次数（用于触发 panic）
        panicWindow = 0,           -- 受惊窗口计时器

        penned  = false,           -- 是否已入栏
        calmTimer = 0,             -- 脱离犬影响后的稳定计时
        barkBoostTimer = 0,        -- 吠叫加速剩余时间
        barkImpulseTimer = 0,      -- 吠叫冲击力剩余时间
        barkImpulseDx = 0,         -- 冲击方向 x
        barkImpulseDz = 0,         -- 冲击方向 z
    }
end

------------------------------------------------------------
-- 辅助数学
------------------------------------------------------------
local function dist2(ax, az, bx, bz)
    local dx = bx - ax
    local dz = bz - az
    return dx * dx + dz * dz
end

local function dist(ax, az, bx, bz)
    return math.sqrt(dist2(ax, az, bx, bz))
end

local function normalize(x, z)
    local len = math.sqrt(x * x + z * z)
    if len < 0.0001 then return 0, 0 end
    return x / len, z / len
end

local function clampMag(vx, vz, maxSpeed)
    local sp = math.sqrt(vx * vx + vz * vz)
    if sp > maxSpeed then
        local s = maxSpeed / sp
        return vx * s, vz * s
    end
    return vx, vz
end

--- 反射速度：沿法线 (nx,nz) 反射，保持速率
--- 返回反射后的速度 + 反射是否发生
local function reflectVelocity(vx, vz, nx, nz)
    local dot = vx * nx + vz * nz
    if dot >= 0 then
        return vx, vz, false  -- 速度已远离障碍，无需反射
    end
    -- v_ref = v - 2*(v·n)*n
    local rx = vx - 2 * dot * nx
    local rz = vz - 2 * dot * nz
    return rx, rz, true
end

-- 判断点是否在犬吠叫锥形范围内（120°扇形）
local BARK_HALF_ANGLE = math.rad(60)  -- 120° / 2
local function isInBarkCone(dogAngle, dogX, dogZ, sheepX, sheepZ)
    local dx = sheepX - dogX
    local dz = sheepZ - dogZ
    local toSheepAngle = math.atan(dz, dx)
    local diff = toSheepAngle - dogAngle
    diff = diff - math.floor((diff + math.pi) / (2 * math.pi)) * 2 * math.pi
    return math.abs(diff) <= BARK_HALF_ANGLE
end

------------------------------------------------------------
-- Boids 力计算
------------------------------------------------------------

-- 分离力: 避免拥挤
local function calcSeparation(sheep, flock)
    local fx, fz = 0, 0
    for _, other in ipairs(flock) do
        if other.id ~= sheep.id and not other.penned then
            local d = dist(sheep.x, sheep.z, other.x, other.z)
            if d < S.R_Separation and d > 0.001 then
                local nx, nz = normalize(sheep.x - other.x, sheep.z - other.z)
                local strength = 1.0 / (d * d + 0.01)
                fx = fx + nx * strength
                fz = fz + nz * strength
            end
        end
    end
    return fx, fz
end

-- 计算两只羊的方向相似度 [0, 1]
local function dirSimilarity(sheepA, sheepB)
    local spA = sheepA.speed or 0
    local spB = sheepB.speed or 0
    if spA < 0.15 or spB < 0.15 then return 0.5 end
    local nax, naz = normalize(sheepA.vx, sheepA.vz)
    local nbx, nbz = normalize(sheepB.vx, sheepB.vz)
    local dot = nax * nbx + naz * nbz
    return (dot + 1) * 0.5
end

-- 对齐力
local function calcAlignment(sheep, flock)
    local avgVx, avgVz = 0, 0
    local totalW = 0
    for _, other in ipairs(flock) do
        if other.id ~= sheep.id and not other.penned then
            local d = dist(sheep.x, sheep.z, other.x, other.z)
            if d < S.R_Alignment then
                local w = dirSimilarity(sheep, other)
                avgVx = avgVx + other.vx * w
                avgVz = avgVz + other.vz * w
                totalW = totalW + w
            end
        end
    end
    if totalW < 0.01 then return 0, 0 end
    avgVx = avgVx / totalW
    avgVz = avgVz / totalW
    return avgVx - sheep.vx, avgVz - sheep.vz
end

-- 聚合力
local function calcCohesion(sheep, flock)
    local cx, cz = 0, 0
    local totalW = 0
    for _, other in ipairs(flock) do
        if other.id ~= sheep.id and not other.penned then
            local d = dist(sheep.x, sheep.z, other.x, other.z)
            if d < S.R_Cohesion then
                local sim = dirSimilarity(sheep, other)
                local distFactor = 1.0 - (d / S.R_Cohesion) * 0.5
                local w = sim * distFactor
                cx = cx + other.x * w
                cz = cz + other.z * w
                totalW = totalW + w
            end
        end
    end
    if totalW < 0.01 then return 0, 0 end
    cx = cx / totalW
    cz = cz / totalW
    return cx - sheep.x, cz - sheep.z
end

-- 逃离力: 远离威胁（牧羊犬）—— 考虑树林遮蔽
local function calcFlee(sheep, dogs)
    local fx, fz = 0, 0
    for _, dog in ipairs(dogs) do
        local d = dist(sheep.x, sheep.z, dog.x, dog.z)
        local fleeRadius = S.R_Flee
        local forceMult = 1.0

        -- 树林遮蔽：缩短感知距离
        local alertMult, _ = MapElements.GetPerceptionMultiplier(
            sheep.x, sheep.z, dog.x, dog.z)
        fleeRadius = fleeRadius * alertMult

        -- 吠叫加成：仅在犬头部 120° 锥形范围内生效
        if dog.barking and dog.angle ~= nil
            and isInBarkCone(dog.angle, dog.x, dog.z, sheep.x, sheep.z) then
            fleeRadius = fleeRadius * S.BarkRadiusMult
            forceMult = S.BarkForceMult
        end

        if d < fleeRadius and d > 0.001 then
            local nx, nz = normalize(sheep.x - dog.x, sheep.z - dog.z)
            local strength = forceMult / (d + 0.1)

            if dog.speed then
                local speedFactor = 1.0 + dog.speed * 0.1
                strength = strength * speedFactor
            end

            fx = fx + nx * strength
            fz = fz + nz * strength
        end
    end
    return fx, fz
end

-- 边界力: 远离地图边缘
local function calcBoundary(sheep)
    local fx, fz = 0, 0
    local margin = 1.5
    local mapW = Settings.Map.Width
    local mapH = Settings.Map.Height

    if sheep.x < margin then
        fx = fx + (margin - sheep.x)
    elseif sheep.x > mapW - margin then
        fx = fx - (sheep.x - (mapW - margin))
    end
    if sheep.z < margin then
        fz = fz + (margin - sheep.z)
    elseif sheep.z > mapH - margin then
        fz = fz - (sheep.z - (mapH - margin))
    end
    return fx, fz
end

-- 避障力: 远离固体障碍（AABB），并在接近时引导折射方向
local function calcObstacle(sheep, obstacles)
    local fx, fz = 0, 0
    local detectRange = 2.5  -- 提前感知距离
    for _, obs in ipairs(obstacles) do
        local closestX = math.max(obs[1], math.min(sheep.x, obs[3]))
        local closestZ = math.max(obs[2], math.min(sheep.z, obs[4]))
        local d = dist(sheep.x, sheep.z, closestX, closestZ)
        if d < detectRange and d > 0.001 then
            -- 法线方向（远离障碍物表面）
            local nx, nz = normalize(sheep.x - closestX, sheep.z - closestZ)
            -- 基础推力（距离越近越强）
            local strength = 1.5 / (d * d + 0.01)
            fx = fx + nx * strength
            fz = fz + nz * strength

            -- 折射引导：将运动方向沿障碍物表面切线偏转
            if d < 2.0 and sheep.speed > 0.3 then
                local vdx, vdz = normalize(sheep.vx, sheep.vz)
                local dot = vdx * nx + vdz * nz  -- 速度朝向障碍物的分量
                if dot < -0.1 then
                    -- 正在朝障碍物移动 → 计算切线方向引导
                    -- 切线 = 去掉法线分量后的残余方向
                    local tx = vdx - dot * nx
                    local tz = vdz - dot * nz
                    tx, tz = normalize(tx, tz)
                    -- 切线力：让羊沿障碍物表面滑行而非停下
                    local tangentStrength = math.abs(dot) * 2.0 / (d + 0.1)
                    fx = fx + tx * tangentStrength
                    fz = fz + tz * tangentStrength
                end
            end
        end
    end
    return fx, fz
end

-- 河流避让力: 远离河流边缘（额外补充，防止羊贴着河岸卡住）
local function calcRiverAvoid(sheep)
    local riverDist, nx, nz = MapElements.GetRiverRepulsion(sheep.x, sheep.z)
    if riverDist < 2.0 then
        local strength = 2.0 / (riverDist * riverDist + 0.1)
        return nx * strength, nz * strength
    end
    return 0, 0
end

-- 石头圆形推力
local function calcRockAvoid(sheep)
    return MapElements.GetRockRepulsion(sheep.x, sheep.z, 1.5)
end

------------------------------------------------------------
-- 围栏自动吸引力
-- 当羊靠近围栏门口 PenAttractionRange 米内，且没有犬在
-- 警戒范围内时，羊会自觉缓慢走向围栏门口并进入。
------------------------------------------------------------
local penGateX_ = nil   -- 缓存门口坐标
local penGateZ_ = nil

local function getPenGate()
    if penGateX_ then return penGateX_, penGateZ_ end
    local P = Settings.Pen
    -- 门口在围栏左侧中央，目标点稍微在门内（+0.5 米）
    penGateX_ = P.X + 0.5
    penGateZ_ = (P.Y + P.Y + P.Height) / 2
    return penGateX_, penGateZ_
end

local function calcPenAttraction(sheep, dogs)
    local gateX, gateZ = getPenGate()
    local P = Settings.Pen

    -- 已在围栏内的羊不需要吸引（由入栏逻辑处理）
    if sheep.x >= P.X and sheep.x <= P.X + P.Width
       and sheep.z >= P.Y and sheep.z <= P.Y + P.Height then
        return 0, 0
    end

    -- 到门口的距离
    local dToGate = dist(sheep.x, sheep.z, gateX, gateZ)
    if dToGate >= S.PenAttractionRange then
        return 0, 0
    end

    -- 检查是否有犬在警戒范围内（有犬影响则不自动吸引）
    for _, dog in ipairs(dogs) do
        local d = dist(sheep.x, sheep.z, dog.x, dog.z)
        local alertMult, _ = MapElements.GetPerceptionMultiplier(
            sheep.x, sheep.z, dog.x, dog.z)
        local effectiveDist = d / alertMult
        if effectiveDist < S.R_Alert then
            return 0, 0  -- 有犬威胁，不触发自动吸引
        end
    end

    -- 计算向门口的吸引力（越近越坚定）
    local dx = gateX - sheep.x
    local dz = gateZ - sheep.z
    local nx, nz = normalize(dx, dz)
    -- 距离越近，力越强（从 0.5x 到 1.0x）
    local proximity = 1.0 - (dToGate / S.PenAttractionRange)
    local strength = S.PenAttractionForce * (0.5 + 0.5 * proximity)
    return nx * strength, nz * strength
end

------------------------------------------------------------
-- 状态机更新（考虑树林遮蔽效果）
------------------------------------------------------------
local function updateState(sheep, dogs, dt)
    sheep.stateTimer = sheep.stateTimer + dt
    sheep.panicWindow = math.max(0, sheep.panicWindow - dt)
    if sheep.panicWindow <= 0 then
        sheep.panicCount = 0
    end

    local minDogDist = math.huge
    local nearestBark = false
    for _, dog in ipairs(dogs) do
        local d = dist(sheep.x, sheep.z, dog.x, dog.z)

        -- 树林遮蔽修正
        local alertMult, _ = MapElements.GetPerceptionMultiplier(
            sheep.x, sheep.z, dog.x, dog.z)
        local effectiveDist = d / alertMult  -- 遮蔽使"有效距离"变远

        if effectiveDist < minDogDist then
            minDogDist = effectiveDist
        end

        if dog.barking and d < S.R_Flee * S.BarkRadiusMult
            and dog.angle ~= nil
            and isInBarkCone(dog.angle, dog.x, dog.z, sheep.x, sheep.z) then
            nearestBark = true
            -- 设置冲击力方向（远离犬的方向）
            local idx, idz = normalize(sheep.x - dog.x, sheep.z - dog.z)
            sheep.barkImpulseTimer = S.BarkImpulseDuration
            sheep.barkImpulseDx = idx
            sheep.barkImpulseDz = idz
        end
    end

    if sheep.state == "idle" then
        if minDogDist < S.R_Alert then
            sheep.state = "alert"
            sheep.stateTimer = 0
        end

    elseif sheep.state == "flock" then
        if minDogDist < S.R_Alert then
            sheep.state = "alert"
            sheep.stateTimer = 0
        end

    elseif sheep.state == "alert" then
        if minDogDist < S.R_Flee or nearestBark then
            sheep.state = "panic"
            sheep.stateTimer = 0
            sheep.panicCount = sheep.panicCount + 1
            sheep.panicWindow = 10.0
            if nearestBark then
                sheep.barkBoostTimer = S.BarkBoostDuration
            end
        elseif minDogDist > S.R_Alert and sheep.stateTimer > S.AlertToIdle then
            sheep.state = "flock"
            sheep.stateTimer = 0
        end

    elseif sheep.state == "panic" then
        if sheep.stateTimer > S.PanicDuration then
            if minDogDist > S.R_Flee then
                sheep.state = "recover"
                sheep.stateTimer = 0
            end
        end

    elseif sheep.state == "recover" then
        if minDogDist < S.R_Flee or nearestBark then
            sheep.state = "panic"
            sheep.stateTimer = 0
            sheep.panicCount = sheep.panicCount + 1
            sheep.panicWindow = 10.0
            if nearestBark then
                sheep.barkBoostTimer = S.BarkBoostDuration
            end
        elseif sheep.stateTimer > S.RecoverDuration then
            sheep.state = "flock"
            sheep.stateTimer = 0
        end

    elseif sheep.state == "rescued_flee" then
        -- 被解救后奔逃状态：不受犬影响，持续朝羊群冲刺
        -- 由时间到期或汇合羊群退出（在主循环中处理）
    end
end

------------------------------------------------------------
-- 头羊觅食系统
--
-- 设计：
--   1. 第一只未入栏的羊自动成为"头羊"(leader)
--   2. 头羊搜索最近的食物（优先级：草>水>树），缓慢前进
--   3. 到达食物旁后停留一段时间（吃草/喝水），然后寻找下一个
--   4. 其他羊(跟随者)受到朝向头羊的吸引力，自然跟随移动
--   5. 整个羊群持续缓慢移动，不会停在一个地方超过2秒
------------------------------------------------------------
local foodSources_ = nil   -- 缓存食物列表
local leaderState_ = {     -- 头羊觅食状态
    targetIdx    = nil,     -- 当前目标食物索引
    grazeTimer   = 0,       -- 在食物旁的停留计时
    cooldownTimer = 0,      -- 离开后的冷却计时
    lastFoodIdx  = nil,     -- 上一个食物索引（避免反复）
    wanderAngle  = 0,       -- 无目标时的漫游方向
    wanderTimer  = 0,       -- 漫游方向变化计时
}

local function getFoodSources()
    if foodSources_ then return foodSources_ end
    foodSources_ = TileMap.GetFoodSources()
    return foodSources_
end

--- 获取当前头羊（第一只未入栏且未被捕获的羊）
local function getLeader(flock)
    for _, sheep in ipairs(flock) do
        if not sheep.penned and not sheep.captured then
            return sheep
        end
    end
    return nil
end

--- 为头羊寻找最佳食物目标
--- 优先级：距离近 + 食物优先级高（grass=1 > water=2 > tree=3）
local function findBestFood(leaderX, leaderZ)
    local foods = getFoodSources()
    local range = S.FoodSearchRange
    local bestScore = -math.huge
    local bestIdx = nil

    for i, food in ipairs(foods) do
        -- 跳过刚离开的食物
        if i == leaderState_.lastFoodIdx then goto continue end

        local dx = food.x - leaderX
        local dz = food.z - leaderZ
        local d = math.sqrt(dx * dx + dz * dz)

        if d < range then
            -- 对于不可通行的食物（水源），目标距离应计为到边缘的距离
            local effectiveDist = d
            if not food.walkable then
                effectiveDist = math.max(0.1, d - food.radius - 1.0)
            end
            -- 得分 = 优先级权重 - 距离惩罚
            local priorityWeight = (4 - food.priority) * 8.0  -- grass=24, water=16, tree=8
            local distPenalty = effectiveDist * 1.0
            local score = priorityWeight - distPenalty
            if score > bestScore then
                bestScore = score
                bestIdx = i
            end
        end
        ::continue::
    end
    return bestIdx
end

--- 头羊的食物吸引力
local function calcFoodAttraction(sheep, dt)
    local foods = getFoodSources()

    -- 更新冷却计时
    if leaderState_.cooldownTimer > 0 then
        leaderState_.cooldownTimer = leaderState_.cooldownTimer - dt
    end

    -- 如果没有目标或冷却结束，寻找新目标
    if leaderState_.targetIdx == nil and leaderState_.cooldownTimer <= 0 then
        leaderState_.targetIdx = findBestFood(sheep.x, sheep.z)
    end

    local target = leaderState_.targetIdx and foods[leaderState_.targetIdx]
    if not target then
        -- 无食物目标时：缓慢漫游（确保不会停下来）
        leaderState_.wanderTimer = leaderState_.wanderTimer + dt
        if leaderState_.wanderTimer > 3.0 then
            leaderState_.wanderAngle = leaderState_.wanderAngle + (math.random() - 0.5) * 1.5
            leaderState_.wanderTimer = 0
        end
        local wx = math.cos(leaderState_.wanderAngle) * 1.0
        local wz = math.sin(leaderState_.wanderAngle) * 1.0
        return wx, wz
    end

    local dx = target.x - sheep.x
    local dz = target.z - sheep.z
    local d = math.sqrt(dx * dx + dz * dz)

    -- 对不可通行目标（水源），停在外围
    local arriveRadius = S.FoodArriveRadius
    if not target.walkable then
        arriveRadius = target.radius + 1.5  -- 停在水源边缘外
    end

    if d < arriveRadius then
        -- 已到达食物旁：停留并"吃草/喝水"
        leaderState_.grazeTimer = leaderState_.grazeTimer + dt

        if leaderState_.grazeTimer >= S.FoodGrazeTime then
            -- 停留够了，切换下一个目标
            leaderState_.lastFoodIdx = leaderState_.targetIdx
            leaderState_.targetIdx = nil
            leaderState_.grazeTimer = 0
            leaderState_.cooldownTimer = S.FoodCooldownTime
        end

        -- 到达时绕食物走动（不完全静止）
        local grazeAngle = sheep.angle + 0.4
        return math.cos(grazeAngle) * 0.6, math.sin(grazeAngle) * 0.6
    else
        -- 朝食物移动
        leaderState_.grazeTimer = 0
        local nx, nz = normalize(dx, dz)
        return nx * S.FoodAttractionForce, nz * S.FoodAttractionForce
    end
end

--- 跟随者朝向头羊的吸引力
local function calcLeaderFollow(sheep, leader)
    if not leader or leader.id == sheep.id then
        return 0, 0
    end

    local dx = leader.x - sheep.x
    local dz = leader.z - sheep.z
    local d = math.sqrt(dx * dx + dz * dz)
    local range = S.LeaderFollowRange

    if d > range or d < 1.5 then
        -- 太远感知不到头羊，或已经足够近
        return 0, 0
    end

    -- 距离越远，跟随力越强（避免掉队）
    local proximity = d / range  -- 0~1，越远越大
    local strength = S.LeaderFollowForce * (0.3 + 0.7 * proximity)
    local nx, nz = normalize(dx, dz)
    return nx * strength, nz * strength
end

--- 保留旧的 calcTreeAttraction 作为兼容（非头羊的后备吸引力）
local treePositions_ = nil

local function getTreePositions()
    if treePositions_ then return treePositions_ end
    treePositions_ = {}
    local TS = TileMap.TILE_SIZE
    for _, ov in ipairs(TileMap.overlays) do
        if ov.type == "pine" or ov.type == "tree_round" then
            local otype = TileMap.OverlayTypes[ov.type]
            local cx = (ov.col - 1) * TS + (otype.cols * TS) / 2
            local cz = (ov.row - 1) * TS + (otype.rows * TS) / 2
            table.insert(treePositions_, { x = cx, z = cz })
        end
    end
    return treePositions_
end

local function calcTreeAttraction(sheep)
    local trees = getTreePositions()
    local range = S.TreeAttractionRange
    local bestDist = range
    local bestDx, bestDz = 0, 0
    for _, tree in ipairs(trees) do
        local dx = tree.x - sheep.x
        local dz = tree.z - sheep.z
        local d = math.sqrt(dx * dx + dz * dz)
        if d < bestDist and d > 1.5 then
            bestDist = d
            bestDx = dx
            bestDz = dz
        end
    end
    if bestDist >= range then
        return 0, 0
    end
    local nx, nz = normalize(bestDx, bestDz)
    return nx * S.TreeAttractionForce, nz * S.TreeAttractionForce
end

------------------------------------------------------------
-- 状态 → 最大速度
------------------------------------------------------------
local stateMaxSpeed = {
    idle          = S.Speed_Idle,
    flock         = S.Speed_Flock,
    alert         = S.Speed_Alert,
    panic         = S.Speed_Panic,
    recover       = S.Speed_Recover,
    rescued_flee  = S.Speed_Panic * S.RescuedFleeSpeedMult,  -- 200% 恐慌速度
}

------------------------------------------------------------
-- 状态 → 逃离力权重倍率
------------------------------------------------------------
local stateFleeWeight = {
    idle          = 0.5,
    flock         = 0.8,
    alert         = 1.5,
    panic         = 2.5,
    recover       = 0.3,
    rescued_flee  = 0.0,  -- 奔逃中不受犬影响
}

------------------------------------------------------------
-- 状态 → 聚合力权重倍率
------------------------------------------------------------
local stateCohesionWeight = {
    idle          = 1.0,
    flock         = 1.0,
    alert         = 0.4,
    panic         = 0.15,
    recover       = 0.6,
    rescued_flee  = 0.0,  -- 奔逃中不受聚合力影响（由专用逻辑驱动）
}

------------------------------------------------------------
-- 主更新函数（服务端每帧调用）
------------------------------------------------------------
function SheepAI.Update(flock, dogs, obstacles, dt)
    local P = Settings.Pen
    local penX1 = P.X + 0.5
    local penZ1 = P.Y + 0.5
    local penX2 = P.X + P.Width - 0.5
    local penZ2 = P.Y + P.Height - 0.5

    -- 收集已入栏羊的列表
    local pennedList = {}
    for _, sheep in ipairs(flock) do
        if sheep.penned then
            table.insert(pennedList, sheep)
        end
    end

    -- 围栏中心
    local penCX = P.X + P.Width * 0.5
    local penCZ = P.Y + P.Height * 0.5

    -- 所有入栏羊排列成圆环，绕围栏中心统一旋转
    local pennedCount = #pennedList
    local orbitSpeed = 0.35                                  -- 公转角速度 rad/s
    local maxRadius  = math.min(P.Width, P.Height) * 0.5 - 1.2  -- 围栏内最大半径（留边距）
    local orbitRadius = math.min(2.5, maxRadius)             -- 圆环半径

    -- 全局公转角：使用第一只入栏羊的 orbitAngle 作为基准驱动
    if pennedCount > 0 then
        local lead = pennedList[1]
        if not lead.orbitAngle then lead.orbitAngle = 0 end
        lead.orbitAngle = lead.orbitAngle + orbitSpeed * dt
        local baseAngle = lead.orbitAngle

        for idx, sheep in ipairs(pennedList) do
            sheep.state = "idle"

            -- 均匀分布在圆上
            local slotAngle = baseAngle + (idx - 1) * (2 * math.pi / pennedCount)
            local tx = penCX + math.cos(slotAngle) * orbitRadius
            local tz = penCZ + math.sin(slotAngle) * orbitRadius

            -- 平滑趋近目标点
            local pdx = tx - sheep.x
            local pdz = tz - sheep.z
            local pdist = math.sqrt(pdx * pdx + pdz * pdz)
            if pdist > 0.02 then
                local moveSpeed = math.min(pdist * 3.0, S.Speed_Idle * 0.8)
                sheep.vx = pdx / pdist * moveSpeed
                sheep.vz = pdz / pdist * moveSpeed
            else
                sheep.vx = 0
                sheep.vz = 0
            end

            sheep.x = sheep.x + sheep.vx * dt
            sheep.z = sheep.z + sheep.vz * dt

            sheep.x = Shared.Clamp(sheep.x, penX1, penX2)
            sheep.z = Shared.Clamp(sheep.z, penZ1, penZ2)

            sheep.speed = math.sqrt(sheep.vx * sheep.vx + sheep.vz * sheep.vz)
            -- 朝向沿运动切线方向
            if sheep.speed > 0.05 then
                sheep.angle = math.atan(sheep.vz, sheep.vx)
            end
        end
    end

    -- 确定当前头羊（在循环外只算一次）
    local currentLeader = getLeader(flock)

    for _, sheep in ipairs(flock) do
        if sheep.penned or sheep.captured then
            goto continue
        end

        -- 1. 状态机
        updateState(sheep, dogs, dt)

        -- rescued_flee 专用逻辑：朝最近羊群成员冲刺
        if sheep.state == "rescued_flee" then
            sheep.stateTimer = sheep.stateTimer  -- already incremented in updateState

            -- 超时退出
            if sheep.stateTimer >= S.RescuedFleeDuration then
                sheep.state = "flock"
                sheep.stateTimer = 0
                goto continue
            end

            -- 寻找最近的非入栏、非被捕、非自己的羊群成员
            local nearestD = math.huge
            local nearestX, nearestZ = nil, nil
            for _, other in ipairs(flock) do
                if other.id ~= sheep.id and not other.penned and not other.captured
                   and other.state ~= "rescued_flee" then
                    local d = dist(sheep.x, sheep.z, other.x, other.z)
                    if d < nearestD then
                        nearestD = d
                        nearestX = other.x
                        nearestZ = other.z
                    end
                end
            end

            -- 汇合判定：距离最近羊 < RescuedFlockRadius → 回到正常
            if nearestX and nearestD < S.RescuedFlockRadius then
                sheep.state = "flock"
                sheep.stateTimer = 0
                goto continue
            end

            -- 朝最近的羊冲刺（200% 速度）
            local maxSpd = S.Speed_Panic * S.RescuedFleeSpeedMult
            if nearestX then
                local dx = nearestX - sheep.x
                local dz = nearestZ - sheep.z
                local nx, nz = normalize(dx, dz)
                sheep.vx = nx * maxSpd
                sheep.vz = nz * maxSpd
            else
                -- 没有可汇合的羊群成员，保持当前方向以最大速度
                local dir = sheep.angle
                sheep.vx = math.cos(dir) * maxSpd
                sheep.vz = math.sin(dir) * maxSpd
            end

            -- 更新位置
            sheep.x = sheep.x + sheep.vx * dt
            sheep.z = sheep.z + sheep.vz * dt

            -- 边界钳制
            local r = Settings.Sheep.Radius
            local mapW = Settings.Map.Width
            local mapH = Settings.Map.Height
            sheep.x = Shared.Clamp(sheep.x, r, mapW - r)
            sheep.z = Shared.Clamp(sheep.z, r, mapH - r)

            -- 障碍物碰撞回退
            if not TileMap.IsWalkable(sheep.x, sheep.z) then
                sheep.x = sheep.x - sheep.vx * dt
                sheep.z = sheep.z - sheep.vz * dt
            end

            sheep.speed = math.sqrt(sheep.vx * sheep.vx + sheep.vz * sheep.vz)
            if sheep.speed > 0.1 then
                sheep.angle = math.atan(sheep.vz, sheep.vx)
            end

            goto continue
        end

        -- 吠叫加速倒计时
        if sheep.barkBoostTimer > 0 then
            sheep.barkBoostTimer = sheep.barkBoostTimer - dt
        end

        -- 吠叫冲击力倒计时
        if sheep.barkImpulseTimer > 0 then
            sheep.barkImpulseTimer = sheep.barkImpulseTimer - dt
        end

        -- 追踪脱离犬影响的时间
        if sheep.state == "alert" or sheep.state == "panic" then
            sheep.calmTimer = 0
        else
            sheep.calmTimer = (sheep.calmTimer or 0) + dt
        end

        -- 2. 计算各力
        local sx, sz = calcSeparation(sheep, flock)
        local ax, az = calcAlignment(sheep, flock)
        local cx, cz = calcCohesion(sheep, flock)
        local fleeW = stateFleeWeight[sheep.state] or 1.0
        local cohW  = stateCohesionWeight[sheep.state] or 1.0
        local ex, ez = calcFlee(sheep, dogs)
        local bx, bz = calcBoundary(sheep)
        local ox, oz = calcObstacle(sheep, obstacles)

        -- 地形避让力
        local rvx, rvz = calcRiverAvoid(sheep)
        local rkx, rkz = calcRockAvoid(sheep)

        -- 围栏自动吸引力（仅 idle/flock 状态生效）
        local pax, paz = 0, 0
        if sheep.state == "idle" or sheep.state == "flock" then
            pax, paz = calcPenAttraction(sheep, dogs)
        end

        -- 头羊觅食 / 跟随者跟随（替代旧的树木吸引力）
        local tax, taz = 0, 0
        if sheep.state == "idle" or sheep.state == "flock" then
            if currentLeader and currentLeader.id == sheep.id then
                -- 头羊：朝食物移动
                tax, taz = calcFoodAttraction(sheep, dt)
            elseif currentLeader then
                -- 跟随者：跟随头羊
                tax, taz = calcLeaderFollow(sheep, currentLeader)
            else
                -- 无头羊（全部入栏）：用旧的树木吸引
                tax, taz = calcTreeAttraction(sheep)
            end
        end

        -- 吠叫冲击力
        local bix, biz = 0, 0
        if sheep.barkImpulseTimer > 0 then
            bix = sheep.barkImpulseDx * S.BarkImpulseForce
            biz = sheep.barkImpulseDz * S.BarkImpulseForce
        end

        -- 3. 力叠加
        local forceX = sx * S.W_Separation
                     + ax * S.W_Alignment * cohW
                     + cx * S.W_Cohesion  * cohW
                     + ex * S.W_Flee * fleeW
                     + bx * S.W_Boundary
                     + ox * S.W_Obstacle
                     + rvx * 3.0       -- 河流强力避让
                     + rkx * S.W_Obstacle
                     + pax               -- 围栏吸引力
                     + tax               -- 头羊觅食/跟随力
                     + bix               -- 吠叫冲击力
        local forceZ = sz * S.W_Separation
                     + az * S.W_Alignment * cohW
                     + cz * S.W_Cohesion  * cohW
                     + ez * S.W_Flee * fleeW
                     + bz * S.W_Boundary
                     + oz * S.W_Obstacle
                     + rvz * 3.0
                     + rkz * S.W_Obstacle
                     + paz               -- 围栏吸引力
                     + taz               -- 头羊觅食/跟随力
                     + biz               -- 吠叫冲击力

        -- 障碍物/边界碰撞打破方向锁定
        local obsMag = math.sqrt(ox * ox + oz * oz)
        local bndMag = math.sqrt(bx * bx + bz * bz)
        if (obsMag > 0.3 or bndMag > 0.3) and sheep.calmTimer >= 0.5 then
            sheep.calmTimer = 0
            sheep.wanderTarget = nil
        end

        -- 持续运动驱动（idle/flock/recover 时始终给一个行进方向力）
        if sheep.state == "idle" or sheep.state == "flock" or sheep.state == "recover" then
            if not sheep.wanderTarget then
                sheep.wanderTarget = sheep.angle
            end
            local ct = sheep.calmTimer or 0
            local wanderDrift = 0
            local wanderStrength = 0.8   -- 基础驱动力（大幅增强）
            if ct < 0.5 then
                if sheep.speed > 0.15 then
                    sheep.wanderTarget = math.atan(sheep.vz, sheep.vx)
                end
                wanderStrength = 0.5
            else
                wanderDrift = 0.03
                wanderStrength = 0.8
            end
            sheep.wanderTarget = sheep.wanderTarget + (math.random() - 0.5) * wanderDrift
            forceX = forceX + math.cos(sheep.wanderTarget) * wanderStrength
            forceZ = forceZ + math.sin(sheep.wanderTarget) * wanderStrength
        end

        -- Panic 增加随机扰动
        if sheep.state == "panic" then
            forceX = forceX + (math.random() - 0.5) * 1.5
            forceZ = forceZ + (math.random() - 0.5) * 1.5
        end

        -- 4. 更新速度
        sheep.vx = sheep.vx + forceX * dt * 3.5
        sheep.vz = sheep.vz + forceZ * dt * 3.5

        -- 地形减速 + 吠叫加速
        local speedMult = MapElements.GetSpeedMultiplier(sheep.x, sheep.z, false)
        local maxSpd = (stateMaxSpeed[sheep.state] or S.Speed_Flock) * speedMult
        if sheep.barkBoostTimer > 0 then
            maxSpd = maxSpd * S.BarkSpeedBoost
        end
        sheep.vx, sheep.vz = clampMag(sheep.vx, sheep.vz, maxSpd)

        -- 速度衰减（idle/flock 阻尼大幅降低，让羊保持运动）
        local damping = 0.94
        if sheep.state == "idle" then damping = 0.97 end
        if sheep.state == "flock" then damping = 0.96 end
        sheep.vx = sheep.vx * damping
        sheep.vz = sheep.vz * damping

        -- 最低速度保障：idle/flock 状态下速度过低时沿当前方向补力
        if (sheep.state == "idle" or sheep.state == "flock") then
            local curSpeed = math.sqrt(sheep.vx * sheep.vx + sheep.vz * sheep.vz)
            local minSpeed = maxSpd * 0.3  -- 最低保持最大速度的 30%
            if curSpeed < minSpeed then
                local angle = sheep.wanderTarget or sheep.angle
                sheep.vx = math.cos(angle) * minSpeed
                sheep.vz = math.sin(angle) * minSpeed
            end
        end

        -- 5. 更新位置
        sheep.x = sheep.x + sheep.vx * dt
        sheep.z = sheep.z + sheep.vz * dt

        -- 障碍物折射：碰到不可通行区域时反射速度，保持运动
        if not TileMap.IsWalkable(sheep.x, sheep.z) then
            -- 回退到安全位置
            local prevX = sheep.x - sheep.vx * dt
            local prevZ = sheep.z - sheep.vz * dt
            sheep.x = prevX
            sheep.z = prevZ

            -- 计算碰撞法线：采样四方向找最近可通行方向
            local probe = 0.3
            local nx, nz = 0, 0
            if TileMap.IsWalkable(sheep.x + probe, sheep.z) then nx = nx + 1 end
            if TileMap.IsWalkable(sheep.x - probe, sheep.z) then nx = nx - 1 end
            if TileMap.IsWalkable(sheep.x, sheep.z + probe) then nz = nz + 1 end
            if TileMap.IsWalkable(sheep.x, sheep.z - probe) then nz = nz - 1 end
            nx, nz = normalize(nx, nz)

            if nx ~= 0 or nz ~= 0 then
                -- 沿法线反射速度（折射行为）
                local spd = math.sqrt(sheep.vx * sheep.vx + sheep.vz * sheep.vz)
                sheep.vx, sheep.vz = reflectVelocity(sheep.vx, sheep.vz, nx, nz)
                -- 保持速率不衰减
                local newSpd = math.sqrt(sheep.vx * sheep.vx + sheep.vz * sheep.vz)
                if newSpd > 0.01 and spd > 0.01 then
                    local scale = spd / newSpd
                    sheep.vx = sheep.vx * scale
                    sheep.vz = sheep.vz * scale
                end
                -- 更新 wanderTarget 为反射后方向
                sheep.wanderTarget = math.atan(sheep.vz, sheep.vx)
            else
                -- 四面被堵，给随机方向弹出
                local randAngle = math.random() * math.pi * 2
                local spd = math.max(1.0, math.sqrt(sheep.vx * sheep.vx + sheep.vz * sheep.vz))
                sheep.vx = math.cos(randAngle) * spd
                sheep.vz = math.sin(randAngle) * spd
                sheep.wanderTarget = randAngle
            end
        end

        -- 边界折射：碰到地图边缘时反射速度方向
        local r = Settings.Sheep.Radius
        local mapW = Settings.Map.Width
        local mapH = Settings.Map.Height
        if sheep.x < r then
            sheep.x = r
            if sheep.vx < 0 then sheep.vx = -sheep.vx end
            sheep.wanderTarget = math.atan(sheep.vz, sheep.vx)
        elseif sheep.x > mapW - r then
            sheep.x = mapW - r
            if sheep.vx > 0 then sheep.vx = -sheep.vx end
            sheep.wanderTarget = math.atan(sheep.vz, sheep.vx)
        end
        if sheep.z < r then
            sheep.z = r
            if sheep.vz < 0 then sheep.vz = -sheep.vz end
            sheep.wanderTarget = math.atan(sheep.vz, sheep.vx)
        elseif sheep.z > mapH - r then
            sheep.z = mapH - r
            if sheep.vz > 0 then sheep.vz = -sheep.vz end
            sheep.wanderTarget = math.atan(sheep.vz, sheep.vx)
        end

        -- 更新速度标量
        sheep.speed = math.sqrt(sheep.vx * sheep.vx + sheep.vz * sheep.vz)

        -- 更新朝向（转向速率限制）
        if sheep.speed > 0.1 then
            local targetAngle = math.atan(sheep.vz, sheep.vx)
            local maxTurnRate = 4.0
            if sheep.state == "idle" or sheep.state == "flock" then
                maxTurnRate = 5.0   -- 加快转向以配合折射
            elseif sheep.state == "panic" then
                maxTurnRate = 8.0
            end

            local angleDiff = targetAngle - sheep.angle
            angleDiff = angleDiff - math.floor((angleDiff + math.pi) / (2 * math.pi)) * 2 * math.pi
            local maxDelta = maxTurnRate * dt
            if angleDiff > maxDelta then angleDiff = maxDelta end
            if angleDiff < -maxDelta then angleDiff = -maxDelta end
            sheep.angle = sheep.angle + angleDiff
        end

        ::continue::
    end
end

------------------------------------------------------------
-- 初始化羊群（使用 MapElements 验证合法位置）
------------------------------------------------------------
function SheepAI.CreateFlock(count)
    local flock = {}
    local mapW = Settings.Map.Width
    local mapH = Settings.Map.Height
    -- 羊群初始区域：地图中央偏左下（河流以南区域）
    local cx = mapW * 0.3
    local cz = mapH * 0.7
    local spread = 6.0

    for i = 1, count do
        local x, z = MapElements.GetValidPosition(
            cx - spread, cx + spread,
            cz - spread, cz + spread
        )
        flock[i] = SheepAI.NewSheep(i, x, z)
    end
    return flock
end

return SheepAI
