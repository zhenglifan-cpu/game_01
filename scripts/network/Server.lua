------------------------------------------------------------
-- Server.lua  —— 牧羊游戏服务端
--
-- 职责:
--   1. 管理玩家连接/断开
--   2. 运行羊群 AI（权威仿真）
--   3. 读取玩家 Controls 移动牧羊犬
--   4. 检测入栏 / 广播游戏状态
------------------------------------------------------------
require "LuaScripts/Utilities/Sample"

local Settings    = require("config.Settings")
local Shared      = require("network.Shared")
local SheepAI     = require("game.SheepAI")
local GameLogic   = require("game.GameLogic")
local MapElements = require("game.MapElements")
local WolfAI      = require("game.WolfAI")

local TileMap     = require("game.TileMap")

local Server = {}

------------------------------------------------------------
-- 服务端状态
------------------------------------------------------------
local scene_       = nil
local flock_       = {}        -- 羊群数据 (SheepAI)
local obstacles_   = {}        -- 障碍物列表
local gameState_   = nil       -- GameLogic 状态
local dogs_        = {}        -- { [connKey] = {node, x, z, vx, vz, speed, barking, barkTimer, ...} }
local connections_ = {}        -- { [connKey] = Connection }
local nextRoleIdx_ = 0         -- 角色分配索引

-- 角色池节点
local roleNodes_       = {}    -- { [connKey] = Node (REPLICATED) }
local sheepNodes_      = {}    -- { [sheepId] = Node (REPLICATED) }

-- 狼群
local wolves_          = {}    -- WolfAI 数据列表
local wolfNodes_       = {}    -- { [wolfId] = Node (REPLICATED) }
local playerCount_     = 0     -- 当前连接的玩家数

-- 定频广播计时器
local broadcastTimer_  = 0
local BROADCAST_INTERVAL = 0.2  -- 每 0.2 秒广播一次游戏状态

-- 延迟回调
local pendingCallbacks_ = {}

------------------------------------------------------------
-- 辅助
------------------------------------------------------------
local function delayOneFrame(cb)
    table.insert(pendingCallbacks_, cb)
end

local function processPending()
    if #pendingCallbacks_ > 0 then
        local cbs = pendingCallbacks_
        pendingCallbacks_ = {}
        for _, cb in ipairs(cbs) do cb() end
    end
end

local function connKey(conn)
    return tostring(conn)
end

------------------------------------------------------------
-- 狼群管理：动态调整狼数量与玩家数一致
------------------------------------------------------------
local function addWolf()
    local wolfId = #wolves_ + 1
    local x, z = WolfAI.GetSpawnPosition()
    local wolf = WolfAI.NewWolf(wolfId, x, z)
    wolves_[wolfId] = wolf

    -- 创建 REPLICATED 节点
    local node = scene_:CreateChild("Wolf_" .. wolfId, REPLICATED)
    node.position = Vector3(wolf.x, 0, wolf.z)
    node:SetVar(Settings.VARS.IS_WOLF, Variant(true))
    node:SetVar(Settings.VARS.WOLF_IDX, Variant(wolfId))
    node:SetVar(Settings.VARS.WOLF_STATE, Variant(wolf.state))
    wolfNodes_[wolfId] = node

    print("[Server] Wolf " .. wolfId .. " spawned at (" ..
        string.format("%.1f", x) .. ", " .. string.format("%.1f", z) .. ")")
end

local function removeWolf()
    local wolfId = #wolves_
    if wolfId < 1 then return end

    -- 如果该狼抓着羊，先释放
    local wolf = wolves_[wolfId]
    if wolf and wolf.capturedSheep then
        wolf.capturedSheep.captured = false
        wolf.capturedSheep.capturedByWolfId = nil
    end

    -- 移除节点
    if wolfNodes_[wolfId] then
        wolfNodes_[wolfId]:Dispose()
        wolfNodes_[wolfId] = nil
    end
    wolves_[wolfId] = nil

    print("[Server] Wolf " .. wolfId .. " removed.")
end

local function syncWolfCount(targetCount)
    targetCount = math.max(1, targetCount)  -- 至少1只
    while #wolves_ < targetCount do
        addWolf()
    end
    while #wolves_ > targetCount do
        removeWolf()
    end
    print("[Server] Wolf count synced to " .. #wolves_ .. " (players: " .. targetCount .. ")")
end

------------------------------------------------------------
-- 初始化
------------------------------------------------------------
function Server.Start()
    SampleStart()
    print("[Server] Starting sheepherding server...")

    -- 注册远程事件
    Shared.RegisterEvents()

    -- 创建场景
    scene_ = Shared.CreateScene()

    -- 创建羊群节点（REPLICATED → 客户端自动同步位置）
    flock_ = SheepAI.CreateFlock(Settings.Sheep.Count)
    for _, sheep in ipairs(flock_) do
        local node = scene_:CreateChild("Sheep_" .. sheep.id, REPLICATED)
        node.position = Vector3(sheep.x, 0, sheep.z)
        node:SetVar(Settings.VARS.IS_SHEEP, Variant(true))
        node:SetVar(Settings.VARS.SHEEP_IDX, Variant(sheep.id))
        node:SetVar(Settings.VARS.SHEEP_STATE, Variant(sheep.state))
        sheepNodes_[sheep.id] = node
    end

    -- 创建障碍物
    obstacles_ = GameLogic.CreateObstacles()

    -- 初始化游戏状态
    gameState_ = GameLogic.NewState()

    -- 订阅连接事件
    SubscribeToEvent("ClientConnected", "HandleClientConnected")
    SubscribeToEvent(Settings.EVENTS.CLIENT_READY, "HandleClientReady")
    SubscribeToEvent("ClientDisconnected", "HandleClientDisconnected")

    -- 订阅吠叫事件
    SubscribeToEvent(Settings.EVENTS.BARK, "HandleBark")

    -- 订阅建造事件
    SubscribeToEvent(Settings.EVENTS.BUILD_REQUEST, "HandleBuildRequest")

    -- 订阅作弊事件
    SubscribeToEvent(Settings.EVENTS.CHEAT_WIN, "HandleCheatWin")

    -- 创建初始狼群（1只，等玩家连接后会动态增加）
    syncWolfCount(1)

    -- 订阅 Update
    SubscribeToEvent("Update", "HandleUpdate")

    print("[Server] Server started. Waiting for players...")
end

------------------------------------------------------------
-- 玩家连接
------------------------------------------------------------
function HandleClientConnected(eventType, eventData)
    local conn = eventData["Connection"]:GetPtr("Connection")
    print("[Server] Client connected: " .. connKey(conn))
end

function HandleClientReady(eventType, eventData)
    local conn = eventData["Connection"]:GetPtr("Connection")
    local key = connKey(conn)
    print("[Server] Client ready: " .. key)

    -- 绑定场景（触发全量同步）
    conn.scene = scene_

    -- 分配角色
    nextRoleIdx_ = nextRoleIdx_ + 1
    local roleIdx = nextRoleIdx_
    connections_[key] = conn

    -- 创建犬节点（REPLICATED）
    local spawnPos = Shared.GetSpawnPoint(roleIdx)
    local dogNode = scene_:CreateChild("Dog_" .. roleIdx, REPLICATED)
    dogNode.position = spawnPos
    dogNode:SetVar(Settings.VARS.IS_DOG, Variant(true))
    dogNode:SetVar(Settings.VARS.PLAYER_IDX, Variant(roleIdx))
    dogNode:SetOwner(conn)

    roleNodes_[key] = dogNode

    -- 初始化犬数据
    dogs_[key] = {
        node       = dogNode,
        roleIdx    = roleIdx,
        x          = spawnPos.x,
        z          = spawnPos.z,
        vx         = 0,
        vz         = 0,
        speed      = 0,
        angle      = 0,    -- 犬朝向弧度（用于吠叫锥形）
        barking    = false,
        barkTimer  = 0,
        sprintTimer    = 0,
        sprintCooldown = 0,
    }

    -- 更新玩家计数，动态调整狼数量
    playerCount_ = playerCount_ + 1
    syncWolfCount(playerCount_)

    -- 延迟一帧通知客户端（等场景同步完成）
    delayOneFrame(function()
        local data = VariantMap()
        data["NodeId"] = Variant(dogNode.ID)
        data["RoleIdx"] = Variant(roleIdx)
        conn:SendRemoteEvent(Settings.EVENTS.ASSIGN_ROLE, true, data)
        print("[Server] Assigned role " .. roleIdx .. " to " .. key)
    end)
end

function HandleClientDisconnected(eventType, eventData)
    local conn = eventData:GetPtr("Connection", "Connection")
    local key = connKey(conn)
    print("[Server] Client disconnected: " .. key)

    -- 移除犬节点
    if roleNodes_[key] then
        roleNodes_[key]:Dispose()
        roleNodes_[key] = nil
    end
    dogs_[key] = nil
    connections_[key] = nil

    -- 更新玩家计数，动态调整狼数量
    playerCount_ = math.max(0, playerCount_ - 1)
    syncWolfCount(math.max(1, playerCount_))
end

------------------------------------------------------------
-- 吠叫事件
------------------------------------------------------------
function HandleBark(eventType, eventData)
    local conn = eventData["Connection"]:GetPtr("Connection")
    local key = connKey(conn)
    local dog = dogs_[key]
    if dog and dog.barkTimer <= 0 then
        dog.barking = true
        dog.barkTimer = Settings.Dog.BarkCooldown
        print("[Server] Dog " .. dog.roleIdx .. " barked!")

        -- 广播吠叫给所有客户端（含朝向角度）
        local data = VariantMap()
        data["RoleIdx"] = Variant(dog.roleIdx)
        data["X"] = Variant(dog.x)
        data["Z"] = Variant(dog.z)
        data["Angle"] = Variant(dog.angle)
        for _, c in pairs(connections_) do
            c:SendRemoteEvent(Settings.EVENTS.BARK, true, data)
        end
    end
end

------------------------------------------------------------
-- 一键通关作弊处理
------------------------------------------------------------
function HandleCheatWin(eventType, eventData)
    if gameState_.gameOver then return end
    print("[Server][Cheat] Win now activated!")

    local P = Settings.Pen
    local penCX = P.X + P.Width / 2
    local penCZ = P.Y + P.Height / 2
    local maxR = math.min(P.Width, P.Height) * 0.5 - 1.0
    local count = 0
    for _, sheep in ipairs(flock_) do
        if not sheep.penned then
            sheep.penned = true
            count = count + 1
            local angle = (count - 1) * (2 * math.pi / #flock_)
            local r = math.min(2.5, maxR)
            sheep.x = penCX + math.cos(angle) * r
            sheep.z = penCZ + math.sin(angle) * r
            sheep.vx = 0
            sheep.vz = 0
            sheep.speed = 0
        end
    end
    gameState_.sheepPenned = gameState_.totalSheep
    gameState_.woolCollected = gameState_.woolCollected + count * Settings.Game.WoolPerSheep
    gameState_.gameOver = true
    gameState_.gameWon = true

    -- 广播游戏完成
    local data = VariantMap()
    data["Wool"] = Variant(gameState_.woolCollected)
    data["Time"] = Variant(gameState_.elapsed)
    for _, c in pairs(connections_) do
        c:SendRemoteEvent(Settings.EVENTS.GAME_COMPLETE, true, data)
    end
    print("[Server][Cheat] " .. count .. " sheep teleported. Wool: " .. gameState_.woolCollected)
end

------------------------------------------------------------
-- 建造请求处理
------------------------------------------------------------
function HandleBuildRequest(eventType, eventData)
    local conn = eventData["Connection"]:GetPtr("Connection")
    local key = connKey(conn)
    local buildType = eventData["BuildType"]:GetString()
    local col = eventData["Col"]:GetInt()
    local row = eventData["Row"]:GetInt()

    print("[Server] Build request from " .. key .. ": " .. buildType .. " at (" .. col .. "," .. row .. ")")

    -- 查找物品配置
    local itemCfg = nil
    for _, item in ipairs(Settings.Build.Items) do
        if item.id == buildType then
            itemCfg = item
            break
        end
    end

    if not itemCfg then
        local fd = VariantMap()
        fd["Reason"] = Variant("invalid_type")
        conn:SendRemoteEvent(Settings.EVENTS.BUILD_FAILED, true, fd)
        return
    end

    -- 验证资源
    if not GameLogic.CanBuild(gameState_, itemCfg.cost) then
        local fd = VariantMap()
        fd["Reason"] = Variant("not_enough_wool")
        conn:SendRemoteEvent(Settings.EVENTS.BUILD_FAILED, true, fd)
        return
    end

    -- 验证位置
    local canPlace, reason = TileMap.CanPlaceOverlay(buildType, col, row)
    if not canPlace then
        local fd = VariantMap()
        fd["Reason"] = Variant(reason or "invalid_position")
        conn:SendRemoteEvent(Settings.EVENTS.BUILD_FAILED, true, fd)
        return
    end

    -- 扣除资源
    GameLogic.SpendWool(gameState_, itemCfg.cost)

    -- 放置
    TileMap.AddOverlay(buildType, col, row)

    -- 重建障碍物列表（新增的 overlay 自动参与碰撞）
    obstacles_ = GameLogic.CreateObstacles()

    print("[Server] Built " .. buildType .. " at (" .. col .. "," .. row .. "). Wool remaining: " .. gameState_.woolCollected)

    -- 广播建造成功
    local data = VariantMap()
    data["BuildType"] = Variant(buildType)
    data["Col"] = Variant(col)
    data["Row"] = Variant(row)
    for _, c in pairs(connections_) do
        c:SendRemoteEvent(Settings.EVENTS.BUILD_PLACED, true, data)
    end

    -- 广播更新后的游戏状态（羊毛数量变化）
    broadcastGameState()
end

------------------------------------------------------------
-- 主更新
------------------------------------------------------------
function HandleUpdate(eventType, eventData)
    local dt = eventData["TimeStep"]:GetFloat()
    processPending()

    if gameState_.gameOver then return end

    gameState_.elapsed = gameState_.elapsed + dt

    -- 1. 更新犬位置（读取 Controls）
    updateDogs(dt)

    -- 2. 构建犬数据列表（给 SheepAI）
    local dogList = {}
    for _, dog in pairs(dogs_) do
        table.insert(dogList, {
            x       = dog.x,
            z       = dog.z,
            speed   = dog.speed,
            angle   = dog.angle,
            barking = dog.barking,
        })
    end

    -- 3. 更新狼 AI
    WolfAI.Update(wolves_, flock_, dogList, gameState_, dt)

    -- 4. 将狼作为额外威胁源传给羊群 AI
    local wolfThreats = WolfAI.GetThreats(wolves_)
    local allThreats = {}
    for _, d in ipairs(dogList) do table.insert(allThreats, d) end
    for _, w in ipairs(wolfThreats) do table.insert(allThreats, w) end

    -- 5. 更新羊群 AI
    SheepAI.Update(flock_, allThreats, obstacles_, dt)

    -- 6. 同步狼节点位置
    for _, wolf in ipairs(wolves_) do
        local node = wolfNodes_[wolf.id]
        if node then
            node.position = Vector3(wolf.x, 0, wolf.z)
            if wolf.speed > 0.1 then
                node.rotation = Quaternion(math.deg(-wolf.angle) + 90, Vector3.UP)
            end
            node:SetVar(Settings.VARS.WOLF_STATE, Variant(wolf.state))
            node:SetVar("WolfSpeed", Variant(wolf.speed))
        end
    end

    -- 7. 同步羊节点位置
    for _, sheep in ipairs(flock_) do
        local node = sheepNodes_[sheep.id]
        if node then
            node.position = Vector3(sheep.x, 0, sheep.z)
            -- 朝向
            if sheep.speed > 0.1 then
                node.rotation = Quaternion(math.deg(-sheep.angle) + 90, Vector3.UP)
            end
            -- 同步状态变量
            node:SetVar(Settings.VARS.SHEEP_STATE, Variant(sheep.state))
            node:SetVar("SheepSpeed", Variant(sheep.speed))
            node:SetVar("Penned", Variant(sheep.penned or false))
        end
    end

    -- 8. 围栏检测
    local newlyPenned = GameLogic.CheckPenning(flock_, gameState_)
    if #newlyPenned > 0 then
        for _, sheepId in ipairs(newlyPenned) do
            print("[Server] Sheep " .. sheepId .. " penned! Total: " .. gameState_.sheepPenned .. "/" .. gameState_.totalSheep)
        end
        -- 广播入栏事件
        broadcastGameState()
    end

    -- 9. 胜利检测
    if gameState_.gameWon then
        print("[Server] All sheep penned! Game complete in " .. string.format("%.1f", gameState_.elapsed) .. "s")
        local data = VariantMap()
        data["Wool"] = Variant(gameState_.woolCollected)
        data["Time"] = Variant(gameState_.elapsed)
        for _, c in pairs(connections_) do
            c:SendRemoteEvent(Settings.EVENTS.GAME_COMPLETE, true, data)
        end
    end

    -- 10. 定频广播游戏状态（时间/羊毛/入栏数）
    broadcastTimer_ = broadcastTimer_ + dt
    if broadcastTimer_ >= BROADCAST_INTERVAL then
        broadcastTimer_ = broadcastTimer_ - BROADCAST_INTERVAL
        broadcastGameState()
    end

    -- 11. 重置吠叫标记（只持续一帧）
    for _, dog in pairs(dogs_) do
        dog.barking = false
    end
end

------------------------------------------------------------
-- 更新犬位置
------------------------------------------------------------
function updateDogs(dt)
    for key, dog in pairs(dogs_) do
        local conn = connections_[key]
        if conn == nil then goto nextDog end

        local controls = conn.controls
        local buttons = controls.buttons

        -- 读取方向输入
        local moveX, moveZ = 0, 0
        if (buttons & Settings.CTRL.UP) ~= 0 then moveZ = -1 end
        if (buttons & Settings.CTRL.DOWN) ~= 0 then moveZ = 1 end
        if (buttons & Settings.CTRL.LEFT) ~= 0 then moveX = -1 end
        if (buttons & Settings.CTRL.RIGHT) ~= 0 then moveX = 1 end

        -- 归一化方向
        local nx, nz = Shared.Normalize2D(moveX, moveZ)

        -- 冲刺处理
        dog.sprintCooldown = math.max(0, dog.sprintCooldown - dt)
        local isSprinting = false
        if (buttons & Settings.CTRL.SPRINT) ~= 0 and dog.sprintCooldown <= 0 then
            dog.sprintTimer = dog.sprintTimer + dt
            if dog.sprintTimer <= Settings.Dog.SprintDuration then
                isSprinting = true
            else
                -- 冲刺耗尽，进入冷却
                dog.sprintCooldown = Settings.Dog.SprintCooldown
                dog.sprintTimer = 0
            end
        else
            if dog.sprintTimer > 0 then
                dog.sprintCooldown = Settings.Dog.SprintCooldown
            end
            dog.sprintTimer = 0
        end

        local spd = isSprinting and Settings.Dog.SprintSpeed or Settings.Dog.Speed

        -- 地形减速
        local speedMult = MapElements.GetSpeedMultiplier(dog.x, dog.z, true)
        spd = spd * speedMult

        -- 移动
        dog.vx = nx * spd
        dog.vz = nz * spd

        local newX = dog.x + dog.vx * dt
        local newZ = dog.z + dog.vz * dt

        -- 河流/石头阻挡（分轴滑墙）
        if not MapElements.IsInRiver(newX, newZ) and not MapElements.IsInRock(newX, newZ) then
            dog.x = newX
            dog.z = newZ
        else
            if not MapElements.IsInRiver(newX, dog.z) and not MapElements.IsInRock(newX, dog.z) then
                dog.x = newX
            elseif not MapElements.IsInRiver(dog.x, newZ) and not MapElements.IsInRock(dog.x, newZ) then
                dog.z = newZ
            end
        end

        -- 边界
        local r = Settings.Dog.Radius
        dog.x = Shared.Clamp(dog.x, r, Settings.Map.Width - r)
        dog.z = Shared.Clamp(dog.z, r, Settings.Map.Height - r)

        dog.speed = math.sqrt(dog.vx * dog.vx + dog.vz * dog.vz)

        -- 吠叫冷却
        dog.barkTimer = math.max(0, dog.barkTimer - dt)

        -- 更新朝向
        if dog.speed > 0.1 then
            dog.angle = math.atan(dog.vz, dog.vx)
        end

        -- 同步节点
        dog.node.position = Vector3(dog.x, 0, dog.z)
        dog.node:SetVar("DogSpeed", Variant(dog.speed))
        if dog.speed > 0.1 then
            dog.node.rotation = Quaternion(math.deg(-dog.angle) + 90, Vector3.UP)
        end

        ::nextDog::
    end
end

------------------------------------------------------------
-- 广播游戏状态
------------------------------------------------------------
function broadcastGameState()
    local data = VariantMap()
    data["Penned"] = Variant(gameState_.sheepPenned)
    data["Total"] = Variant(gameState_.totalSheep)
    data["Wool"] = Variant(gameState_.woolCollected)
    data["Time"] = Variant(gameState_.elapsed)
    data["Lost"] = Variant(gameState_.sheepLost or 0)
    for _, c in pairs(connections_) do
        c:SendRemoteEvent(Settings.EVENTS.GAME_STATE, true, data)
    end
end

------------------------------------------------------------
-- 清理
------------------------------------------------------------
function Server.Stop()
    print("[Server] Shutting down...")
end

------------------------------------------------------------
-- 全局入口（引擎要求 entry 文件必须有全局 Start/Stop）
------------------------------------------------------------
function Start()
    Server.Start()
end

function Stop()
    Server.Stop()
end

return Server
