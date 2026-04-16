------------------------------------------------------------
-- Client.lua  —— 牧羊游戏客户端
--
-- 职责:
--   1. 发送 Controls 输入到服务器
--   2. 渲染游戏画面（NanoVG 俯视角 2D）
--   3. 显示 HUD（羊毛计数/提示）
--   4. 播放吠叫特效
------------------------------------------------------------
require "LuaScripts/Utilities/Sample"

local Settings    = require("config.Settings")
local Shared      = require("network.Shared")
local MapElements = require("game.MapElements")
local MapRenderer = require("game.MapRenderer")
local TileMap     = require("game.TileMap")
local GameLogic   = require("game.GameLogic")

local TouchControls  = require("ui.TouchControls")
local Minimap        = require("ui.Minimap")
local BuildUI        = require("ui.BuildUI")
local PlatformUtils  = require "urhox-libs.Platform.PlatformUtils"
local AudioManager   = require("game.AudioManager")

local Client = {}

------------------------------------------------------------
-- 客户端状态
------------------------------------------------------------
local scene_       = nil
local nvg_         = nil   -- NanoVG context
local fontNormal_  = nil
local sheepImg_    = nil   -- 羊图片句柄
local sheepOutlineImgs_ = {}  -- 状态轮廓图片 { panic=handle, alert=handle, recover=handle }
local dogImg_      = nil   -- 犬图片句柄
local wolfImg_     = nil   -- 狼图片句柄
local gameClock_   = 0     -- 游戏时钟（用于弹跳动画）
local serverConn_  = nil

local myNodeId_    = nil   -- 自己的犬节点 ID
local myRoleIdx_   = 0

-- 游戏状态（从服务器广播接收）
local sheepPenned_ = 0
local totalSheep_  = Settings.Sheep.Count
local woolCount_   = 0
local elapsed_     = 0
local gameComplete_       = false
local completeTime_       = 0
local completeWool_       = 0
local victoryDismissed_   = false

-- 吠叫特效
local barkEffects_ = {}    -- { {x, z, timer, roleIdx}, ... }
local barkCooldown_ = 0

-- 图片原始宽高比（硬编码，避免 nvgImageSize 返回值不可靠）
local DOG_ASPECT    = 1264 / 848   -- dog.png 原始 1264x848
local WOLF_ASPECT   = 1264 / 848   -- wolf.png 原始 1264x848
local BANNER_ASPECT = 1293 / 138   -- banner_1.png 原始 1293x138

-- 被狼叼走的羊数
local sheepLost_   = 0

-- 底部装饰
local bannerImg_   = nil

-- 平台标识
local isMobile_    = false

-- 屏幕尺寸缓存
local screenW_ = 0
local screenH_ = 0
local dpr_     = 1

-- 每帧节点数据缓存（消除重复 GetChildren + GetVar 调用）
local cachedSheep_ = {}   -- { {x,z,state,idx,speed,penned,rotForward}, ... }
local cachedDogs_  = {}   -- { {x,z,idx,speed,rotForward,isMe,color,nodeId}, ... }
local cachedWolves_ = {}  -- { {x,z,idx,speed,state,forwardX}, ... }
local cachedCamX_  = 30   -- 自己犬的位置（相机中心）
local cachedCamZ_  = 30

------------------------------------------------------------
-- 初始化
------------------------------------------------------------
function Client.Start()
    SampleStart()
    print("[Client] Starting sheepherding client...")

    -- 注册远程事件
    Shared.RegisterEvents()

    -- 创建场景
    scene_ = Shared.CreateScene()

    -- 连接到服务器
    serverConn_ = network:GetServerConnection()
    if not serverConn_ then
        print("[Client] ERROR: No server connection available, cannot start client.")
        return
    end
    serverConn_.scene = scene_
    serverConn_:SendRemoteEvent(Settings.EVENTS.CLIENT_READY, true)

    -- 订阅服务器事件
    SubscribeToEvent(Settings.EVENTS.ASSIGN_ROLE, "HandleAssignRole")
    SubscribeToEvent(Settings.EVENTS.BARK, "HandleBarkEffect")
    SubscribeToEvent(Settings.EVENTS.GAME_STATE, "HandleGameState")
    SubscribeToEvent(Settings.EVENTS.GAME_COMPLETE, "HandleGameComplete")
    SubscribeToEvent(Settings.EVENTS.SHEEP_PENNED, "HandleSheepPenned")
    SubscribeToEvent(Settings.EVENTS.BUILD_PLACED, "HandleBuildPlaced")
    SubscribeToEvent(Settings.EVENTS.BUILD_FAILED, "HandleBuildFailed")

    -- NanoVG
    nvg_ = nvgCreate(1)
    if nvg_ then
        fontNormal_ = nvgCreateFont(nvg_, "sans", "Fonts/MiSans-Regular.ttf")
        sheepImg_ = nvgCreateImage(nvg_, "image/sheep.png", 0)
        sheepOutlineImgs_.panic   = nvgCreateImage(nvg_, "image/sheep_panic.png", 0)
        sheepOutlineImgs_.alert   = nvgCreateImage(nvg_, "image/sheep_alert.png", 0)
        sheepOutlineImgs_.recover = nvgCreateImage(nvg_, "image/sheep_recover.png", 0)
        dogImg_ = nvgCreateImage(nvg_, "image/dog.png", 0)
        wolfImg_ = nvgCreateImage(nvg_, "image/wolf.png", 0)
        bannerImg_ = nvgCreateImage(nvg_, "image/banner_1.png", 0)
        MapRenderer.Init(nvg_)
    end

    -- 平台检测 & 触控初始化
    isMobile_ = PlatformUtils.IsTouchSupported()
    TouchControls.Init()

    -- 音频系统初始化
    AudioManager.Init(scene_)

    -- 订阅事件
    SubscribeToEvent("Update", "HandleUpdate")
    if nvg_ then
        SubscribeToEvent(nvg_, "NanoVGRender", "HandleRender")
    end

    print("[Client] Client started. Connecting...")
end

------------------------------------------------------------
-- 角色分配
------------------------------------------------------------
function HandleAssignRole(eventType, eventData)
    myNodeId_  = eventData["NodeId"]:GetUInt()
    myRoleIdx_ = eventData["RoleIdx"]:GetInt()
    print("[Client] Assigned role " .. myRoleIdx_ .. ", nodeId=" .. myNodeId_)
end

------------------------------------------------------------
-- 游戏状态更新
------------------------------------------------------------
function HandleGameState(eventType, eventData)
    sheepPenned_ = eventData["Penned"]:GetInt()
    totalSheep_  = eventData["Total"]:GetInt()
    woolCount_   = eventData["Wool"]:GetInt()
    elapsed_     = eventData["Time"]:GetFloat()
    local lostVar = eventData["Lost"]
    if lostVar then sheepLost_ = lostVar:GetInt() end
end

function HandleGameComplete(eventType, eventData)
    completeWool_ = eventData["Wool"]:GetInt()
    completeTime_ = eventData["Time"]:GetFloat()
    gameComplete_ = true
    print("[Client] Game Complete! Wool: " .. completeWool_ .. " Time: " .. string.format("%.1f", completeTime_) .. "s")
end

function HandleSheepPenned(eventType, eventData)
    -- 可添加入栏音效/特效
end

------------------------------------------------------------
-- 建造事件
------------------------------------------------------------
function HandleBuildPlaced(eventType, eventData)
    local buildType = eventData["BuildType"]:GetString()
    local col = eventData["Col"]:GetInt()
    local row = eventData["Row"]:GetInt()
    -- 在客户端本地也添加 overlay，保持渲染同步
    TileMap.AddOverlay(buildType, col, row)
    print("[Client] Build placed: " .. buildType .. " at (" .. col .. "," .. row .. ")")
end

function HandleBuildFailed(eventType, eventData)
    local reason = eventData["Reason"]:GetString()
    print("[Client] Build failed: " .. reason)
end

------------------------------------------------------------
-- 吠叫特效
------------------------------------------------------------
function HandleBarkEffect(eventType, eventData)
    local roleIdx = eventData["RoleIdx"]:GetInt()
    local x = eventData["X"]:GetFloat()
    local z = eventData["Z"]:GetFloat()
    local angle = eventData["Angle"]:GetFloat()
    table.insert(barkEffects_, {
        x = x, z = z,
        angle = angle,
        timer = 0.35,
        roleIdx = roleIdx,
    })
end

------------------------------------------------------------
-- 建造辅助函数
------------------------------------------------------------

--- PC 端：使用当前预览位置发送建造请求
local function trySendBuildRequest()
    local col, row, canP = BuildUI.GetPreview()
    if col and canP then
        local item = BuildUI.GetSelectedItem()
        if item and woolCount_ >= item.cost then
            local data = VariantMap()
            data["BuildType"] = Variant(item.id)
            data["Col"] = Variant(col)
            data["Row"] = Variant(row)
            serverConn_:SendRemoteEvent(Settings.EVENTS.BUILD_REQUEST, true, data)
            print("[Client] Build request: " .. item.id .. " at (" .. col .. "," .. row .. ")")
        end
    end
end

--- 移动端：根据屏幕坐标计算网格位置并发送建造请求
local function trySendBuildRequestAtScreen(screenX, screenY)
    local logW = screenW_ / dpr_
    local logH = screenH_ / dpr_
    local viewW = 32.0
    local viewH = viewW * (logH / logW)
    local mapW = Settings.Map.Width
    local mapH = Settings.Map.Height
    local halfVW = viewW / 2
    local halfVH = viewH / 2

    local camX, camZ = cachedCamX_, cachedCamZ_
    camX = math.max(halfVW, math.min(mapW - halfVW, camX))
    camZ = math.max(halfVH, math.min(mapH - halfVH, camZ))
    local scale = logW / viewW
    local worldLeft = camX - halfVW
    local worldTop  = camZ - halfVH

    BuildUI.UpdatePreview(screenX, screenY, scale, worldLeft, worldTop, dpr_)
    trySendBuildRequest()
end

------------------------------------------------------------
-- 输入 → Controls
------------------------------------------------------------
function HandleUpdate(eventType, eventData)
    local dt = eventData["TimeStep"]:GetFloat()

    gameClock_ = gameClock_ + dt

    if serverConn_ == nil then return end

    -- 更新吠叫特效计时
    for i = #barkEffects_, 1, -1 do
        barkEffects_[i].timer = barkEffects_[i].timer - dt
        if barkEffects_[i].timer <= 0 then
            table.remove(barkEffects_, i)
        end
    end

    barkCooldown_ = math.max(0, barkCooldown_ - dt)
    elapsed_ = elapsed_ + dt

    -- ── UI 交互（胜利面板 / 建造模式）── 即使 gameComplete 也必须处理 ──

    -- 一键通关作弊器（P 键）— 发送到服务器处理
    if not gameComplete_ and input:GetKeyPress(KEY_P) and serverConn_ then
        print("[Client][Cheat] Sending CheatWin to server")
        serverConn_:SendRemoteEvent(Settings.EVENTS.CHEAT_WIN, true)
    end

    -- 胜利面板点击处理（必须在其他点击检测之前，否则 GetMouseButtonPress 会被消费）
    local victoryPanelActive = gameComplete_ and not victoryDismissed_ and not BuildUI.IsActive()
    if victoryPanelActive then
        if isMobile_ then
            local numTouches = input:GetNumTouches()
            for i = 0, numTouches - 1 do
                local state = input:GetTouch(i)
                if state.delta.x == 0 and state.delta.y == 0 and state.pressure > 0 then
                    local lx = state.position.x / dpr_
                    local ly = state.position.y / dpr_
                    handleVictoryClick(lx, ly)
                end
            end
        else
            if input:GetMouseButtonPress(MOUSEB_LEFT) then
                local mx = input.mousePosition.x / dpr_
                local my = input.mousePosition.y / dpr_
                handleVictoryClick(mx, my)
            end
        end
    end

    -- 触摸/鼠标点击网格按钮检测（胜利面板显示时跳过）
    if not victoryPanelActive then
        checkGridButtonClick()
    end

    -- 建造模式输入处理（PC + 移动端）— 游戏完成且面板已关闭
    if gameComplete_ and victoryDismissed_ then
        local logW = screenW_ / dpr_
        local logH = screenH_ / dpr_

        if isMobile_ then
            local numTouches = input:GetNumTouches()
            for i = 0, numTouches - 1 do
                local state = input:GetTouch(i)
                if state.delta.x == 0 and state.delta.y == 0 and state.pressure > 0 then
                    local lx = state.position.x / dpr_
                    local ly = state.position.y / dpr_
                    if BuildUI.HandleTouchDown(lx, ly, logW, logH) then
                        -- 被建造 UI 消费
                    elseif BuildUI.IsActive() then
                        trySendBuildRequestAtScreen(state.position.x, state.position.y)
                    end
                end
            end
        else
            -- B 键切换建造模式
            if input:GetKeyPress(KEY_B) then
                BuildUI.Toggle()
            end
            -- 鼠标点击放置
            if input:GetMouseButtonPress(MOUSEB_LEFT) then
                local mx = input.mousePosition.x / dpr_
                local my = input.mousePosition.y / dpr_
                if BuildUI.HandleTouchDown(mx, my, logW, logH) then
                    -- 被建造 UI 消费
                elseif BuildUI.IsActive() then
                    trySendBuildRequest()
                end
            end
        end
    end

    -- ── 游戏完成后跳过输入发送 ──
    if gameComplete_ then return end

    -- 读取输入
    local buttons = 0

    if isMobile_ then
        -- 手机：触屏虚拟摇杆
        local jx = TouchControls.GetJoystickX()
        local jy = TouchControls.GetJoystickY()
        local deadZone = 0.15
        if jy < -deadZone then buttons = buttons | Settings.CTRL.UP end
        if jy > deadZone  then buttons = buttons | Settings.CTRL.DOWN end
        if jx < -deadZone then buttons = buttons | Settings.CTRL.LEFT end
        if jx > deadZone  then buttons = buttons | Settings.CTRL.RIGHT end
        if TouchControls.IsSprinting() then
            buttons = buttons | Settings.CTRL.SPRINT
        end
        if TouchControls.IsBarkPressed() and barkCooldown_ <= 0 then
            buttons = buttons | Settings.CTRL.BARK
            barkCooldown_ = Settings.Dog.BarkCooldown
            serverConn_:SendRemoteEvent(Settings.EVENTS.BARK, true)
            AudioManager.PlayBark()
        end
    else
        -- PC：键盘
        if input:GetKeyDown(KEY_W) or input:GetKeyDown(KEY_UP) then
            buttons = buttons | Settings.CTRL.UP
        end
        if input:GetKeyDown(KEY_S) or input:GetKeyDown(KEY_DOWN) then
            buttons = buttons | Settings.CTRL.DOWN
        end
        if input:GetKeyDown(KEY_A) or input:GetKeyDown(KEY_LEFT) then
            buttons = buttons | Settings.CTRL.LEFT
        end
        if input:GetKeyDown(KEY_D) or input:GetKeyDown(KEY_RIGHT) then
            buttons = buttons | Settings.CTRL.RIGHT
        end
        if input:GetKeyDown(KEY_SHIFT) then
            buttons = buttons | Settings.CTRL.SPRINT
        end
        if input:GetKeyPress(KEY_SPACE) and barkCooldown_ <= 0 then
            buttons = buttons | Settings.CTRL.BARK
            barkCooldown_ = Settings.Dog.BarkCooldown
            serverConn_:SendRemoteEvent(Settings.EVENTS.BARK, true)
            AudioManager.PlayBark()
        end
        -- G 键切换网格显示
        if input:GetKeyPress(KEY_G) then
            MapRenderer.showGrid = not MapRenderer.showGrid
        end
    end

    serverConn_.controls.buttons = buttons

    -- === 每帧缓存场景节点数据（一次遍历，所有渲染函数共用）===
    local newSheep = {}
    local newDogs  = {}
    local newWolves = {}
    local myDogSpeed = 0
    local myDogX, myDogZ = 0, 0
    if scene_ then
        local children = scene_:GetChildren(false)
        for ci = 1, #children do
            local nd = children[ci]
            local isSheepVar = nd:GetVar(Settings.VARS.IS_SHEEP)
            if isSheepVar and isSheepVar:GetBool() then
                local pos = nd.position
                local idxVar = nd:GetVar(Settings.VARS.SHEEP_IDX)
                local sid = 1
                if idxVar then sid = idxVar:GetInt() end
                local stateVar = nd:GetVar(Settings.VARS.SHEEP_STATE)
                local state = "idle"
                if stateVar then state = stateVar:GetString() end
                local speedVar = nd:GetVar("SheepSpeed")
                local spd = 0
                if speedVar then spd = speedVar:GetFloat() end
                local pennedVar = nd:GetVar("Penned")
                local penned = false
                if pennedVar then penned = pennedVar:GetBool() end
                local fwd = nd.rotation * Vector3.FORWARD
                newSheep[#newSheep + 1] = {
                    id = sid, x = pos.x, z = pos.z,
                    state = state, idx = sid, speed = spd,
                    penned = penned, forwardX = fwd.x,
                }
            else
                local isDogVar = nd:GetVar(Settings.VARS.IS_DOG)
                if isDogVar and isDogVar:GetBool() then
                    local pos = nd.position
                    local idxVar = nd:GetVar(Settings.VARS.PLAYER_IDX)
                    local pidx = 1
                    if idxVar then pidx = idxVar:GetInt() end
                    local dogSpeedVar = nd:GetVar("DogSpeed")
                    local dSpd = 0
                    if dogSpeedVar then dSpd = dogSpeedVar:GetFloat() end
                    local fwd = nd.rotation * Vector3.FORWARD
                    local isMe = (nd.ID == myNodeId_)
                    local color = Settings.Dog.Colors[((pidx - 1) % #Settings.Dog.Colors) + 1]
                    newDogs[#newDogs + 1] = {
                        x = pos.x, z = pos.z,
                        idx = pidx, speed = dSpd,
                        forwardX = fwd.x, isMe = isMe,
                        color = color, nodeId = nd.ID,
                    }
                    if isMe then
                        myDogSpeed = dSpd
                        myDogX = pos.x
                        myDogZ = pos.z
                    end
                else
                    local isWolfVar = nd:GetVar(Settings.VARS.IS_WOLF)
                    if isWolfVar and isWolfVar:GetBool() then
                        local pos = nd.position
                        local widxVar = nd:GetVar(Settings.VARS.WOLF_IDX)
                        local widx = 1
                        if widxVar then widx = widxVar:GetInt() end
                        local wStateVar = nd:GetVar(Settings.VARS.WOLF_STATE)
                        local wState = "hunting"
                        if wStateVar then wState = wStateVar:GetString() end
                        local wSpeedVar = nd:GetVar("WolfSpeed")
                        local wSpd = 0
                        if wSpeedVar then wSpd = wSpeedVar:GetFloat() end
                        local fwd = nd.rotation * Vector3.FORWARD
                        newWolves[#newWolves + 1] = {
                            id = widx, x = pos.x, z = pos.z,
                            idx = widx, speed = wSpd,
                            state = wState, forwardX = fwd.x,
                        }
                    end
                end
            end
        end
    end
    cachedSheep_ = newSheep
    cachedDogs_  = newDogs
    cachedWolves_ = newWolves
    cachedCamX_  = myDogX > 0 and myDogX or (Settings.Map.Width / 2)
    cachedCamZ_  = myDogZ > 0 and myDogZ or (Settings.Map.Height / 2)

    -- === 音频更新 ===
    local sheepListForAudio = {}
    for i = 1, #cachedSheep_ do
        local s = cachedSheep_[i]
        sheepListForAudio[i] = { id = s.id, x = s.x, z = s.z, penned = s.penned }
    end
    AudioManager.Update(dt, sheepListForAudio, myDogSpeed, myDogX, myDogZ)
end

-- 网格按钮点击检测
local gridBtnRect_ = { x = 0, y = 0, w = 0, h = 0 }  -- 由 drawHUD 更新

function checkGridButtonClick()
    local numTouches = input:GetNumTouches()
    if numTouches > 0 then
        for i = 0, numTouches - 1 do
            local state = input:GetTouch(i)
            if state.delta.x == 0 and state.delta.y == 0 and state.pressure > 0 then
                local tx = state.position.x / dpr_
                local ty = state.position.y / dpr_
                if tx >= gridBtnRect_.x and tx <= gridBtnRect_.x + gridBtnRect_.w
                   and ty >= gridBtnRect_.y and ty <= gridBtnRect_.y + gridBtnRect_.h then
                    MapRenderer.showGrid = not MapRenderer.showGrid
                end
            end
        end
    elseif input:GetMouseButtonPress(MOUSEB_LEFT) then
        local mx = input.mousePosition.x / dpr_
        local my = input.mousePosition.y / dpr_
        if mx >= gridBtnRect_.x and mx <= gridBtnRect_.x + gridBtnRect_.w
           and my >= gridBtnRect_.y and my <= gridBtnRect_.y + gridBtnRect_.h then
            MapRenderer.showGrid = not MapRenderer.showGrid
        end
    end
end

------------------------------------------------------------
-- NanoVG 渲染
------------------------------------------------------------
function HandleRender(eventType, eventData)
    if nvg_ == nil or scene_ == nil then return end

    local gfx = GetGraphics()
    screenW_ = gfx:GetWidth()
    screenH_ = gfx:GetHeight()
    dpr_ = gfx:GetDPR()
    local logW = screenW_ / dpr_
    local logH = screenH_ / dpr_

    nvgBeginFrame(nvg_, screenW_, screenH_, dpr_)

    -- 计算局部相机: 以玩家犬为中心，16:9 画幅显示局部地图
    local mapW = Settings.Map.Width
    local mapH = Settings.Map.Height

    -- 可视区域：固定世界空间宽度，高度按实际屏幕比例推算
    local viewW = 32.0   -- 水平方向可见 32 米（原 20 米的 160%）
    local viewH = viewW * (logH / logW)  -- 垂直方向按实际屏幕比例

    -- 使用缓存的相机位置（HandleUpdate 已遍历）
    local camX, camZ = cachedCamX_, cachedCamZ_

    -- 限制相机不超出地图边界
    local halfVW = viewW / 2
    local halfVH = viewH / 2
    camX = math.max(halfVW, math.min(mapW - halfVW, camX))
    camZ = math.max(halfVH, math.min(mapH - halfVH, camZ))

    -- 缩放: 让 viewW 世界米 映射到 logW 逻辑像素
    local scale = logW / viewW

    -- 偏移: 相机左上角对应的世界坐标
    local worldLeft = camX - halfVW
    local worldTop  = camZ - halfVH
    local offsetX = -worldLeft * scale
    local offsetZ = -worldTop  * scale

    -- 更新建造预览坐标（鼠标位置 → 世界网格）
    if BuildUI.IsActive() then
        local mx = input.mousePosition.x
        local my = input.mousePosition.y
        BuildUI.UpdatePreview(mx, my, scale, worldLeft, worldTop, dpr_)
    end

    -- 绘制背景
    drawBackground(logW, logH)

    -- 应用相机变换
    nvgSave(nvg_)
    nvgTranslate(nvg_, offsetX, offsetZ)
    nvgScale(nvg_, scale, scale)

    -- 设置字体（MapRenderer 文字绘制需要）
    nvgFontFace(nvg_, "sans")

    -- 绘制所有地图元素
    MapRenderer.DrawAll(nvg_, mapW, mapH, gameClock_,
        worldLeft, worldTop, worldLeft + viewW, worldTop + viewH)

    -- 绘制羊
    drawSheep()

    -- 建造预览（世界空间）
    BuildUI.DrawPreview(nvg_)

    -- 绘制狼
    drawWolves()

    -- 绘制吠叫特效
    drawBarkEffects()

    -- 绘制犬（图片部分，在世界变换内）
    drawDogsWorld()

    nvgRestore(nvg_)

    -- 绘制犬标签（屏幕空间，避免极小字号导致黄色雾状伪影）
    drawDogsLabels(scale, offsetX, offsetZ)

    -- 绘制小地图
    drawMinimap(logW, logH)

    -- 绘制HUD
    drawHUD(logW, logH)

    -- 底部装饰（PC 端显示）
    if not isMobile_ then
        drawBottomBanner(logW, logH)
    end

    -- 手机触控 UI（摇杆 + 叫吠按钮）
    TouchControls.UpdateLayout(logW, logH)
    TouchControls.Draw(nvg_)

    -- 建造 HUD（屏幕空间）
    BuildUI.DrawHUD(nvg_, logW, logH, woolCount_, gameComplete_)

    -- 绘制胜利画面（未关闭且非建造模式时显示）
    if gameComplete_ and not victoryDismissed_ and not BuildUI.IsActive() then
        drawVictory(logW, logH)
    end

    nvgEndFrame(nvg_)
end

------------------------------------------------------------
-- 世界坐标到画布坐标 (在 nvg 变换内直接使用 x, z)
------------------------------------------------------------

------------------------------------------------------------
-- 绘制函数
------------------------------------------------------------

function drawBackground(w, h)
    nvgBeginPath(nvg_)
    nvgRect(nvg_, 0, 0, w, h)
    nvgFillColor(nvg_, nvgRGBA(34, 45, 30, 255))
    nvgFill(nvg_)
end

-- drawGrass, drawObstacles, drawPen 已由 MapRenderer.DrawAll 统一替代

function drawSheep()
    if sheepImg_ == nil then return end
    local imgSize = 2.1   -- 世界空间中羊图片的渲染尺寸

    -- 使用缓存数据（HandleUpdate 已遍历）
    for i = 1, #cachedSheep_ do
        local s = cachedSheep_[i]
        local sx = s.x
        local sz = s.z
        local state = s.state
        local sheepIdx = s.idx
        local sheepSpeed = s.speed

        -- 弹跳 + 摇摆动画
        local bouncePhase = sheepIdx * 1.7
        local bounceAmp = math.min(sheepSpeed * 0.15, 0.12)
        local bounceOffset = math.sin(gameClock_ * 8.0 + bouncePhase) * bounceAmp

        local tiltMaxRad = math.rad(10)
        local tiltStrength = math.min(sheepSpeed * 0.5, 1.0)
        local tiltAngle = math.sin(gameClock_ * 6.0 + bouncePhase * 0.7) * tiltMaxRad * tiltStrength

        -- 状态轮廓图片
        local outlineImg = nil
        if state == "panic" then
            outlineImg = sheepOutlineImgs_.panic
        elseif state == "alert" then
            outlineImg = sheepOutlineImgs_.alert
        elseif state == "recover" then
            outlineImg = sheepOutlineImgs_.recover
        end

        -- 入栏羊半透明
        local alpha = s.penned and 0.6 or 1.0

        -- 翻转：根据朝向决定是否水平翻转（图片默认朝左）
        local flipX = s.forwardX > 0

        -- 绘制羊图片
        local half = imgSize / 2
        nvgSave(nvg_)
        nvgTranslate(nvg_, sx, sz + bounceOffset)
        nvgRotate(nvg_, tiltAngle)
        if flipX then
            nvgScale(nvg_, -1, 1)
        end

        -- 先绘制状态轮廓（在羊图片下方）
        if outlineImg then
            local outPaint = nvgImagePattern(nvg_, -half, -half, imgSize, imgSize, 0, outlineImg, alpha)
            nvgBeginPath(nvg_)
            nvgRect(nvg_, -half, -half, imgSize, imgSize)
            nvgFillPaint(nvg_, outPaint)
            nvgFill(nvg_)
        end

        -- 再绘制羊本体图片（覆盖在轮廓上方）
        local paint = nvgImagePattern(nvg_, -half, -half, imgSize, imgSize, 0, sheepImg_, alpha)
        nvgBeginPath(nvg_)
        nvgRect(nvg_, -half, -half, imgSize, imgSize)
        nvgFillPaint(nvg_, paint)
        nvgFill(nvg_)

        nvgRestore(nvg_)
    end
end

function drawWolves()
    if wolfImg_ == nil then return end
    local imgSize = 2.3  -- 狼比犬略大

    for i = 1, #cachedWolves_ do
        local w = cachedWolves_[i]
        if w.state == "despawned" then goto nextWolf end

        local wx = w.x
        local wz = w.z
        local wolfSpeed = w.speed or 0

        local bouncePhase = w.idx * 2.3
        local bounceAmp = math.min(wolfSpeed * 0.15, 0.12)
        local bounceOffset = math.sin(gameClock_ * 8.0 + bouncePhase) * bounceAmp

        local tiltMaxRad = math.rad(10)
        local tiltStrength = math.min(wolfSpeed * 0.5, 1.0)
        local tiltAngle = math.sin(gameClock_ * 6.0 + bouncePhase * 0.7) * tiltMaxRad * tiltStrength

        local flipX = w.forwardX > 0

        local drawH = imgSize
        local drawW = imgSize * WOLF_ASPECT
        local halfW = drawW / 2
        local halfH = drawH / 2

        nvgSave(nvg_)
        nvgTranslate(nvg_, wx, wz + bounceOffset)
        nvgRotate(nvg_, tiltAngle)
        if flipX then
            nvgScale(nvg_, -1, 1)
        end

        -- 拖拽状态显示红色光圈
        if w.state == "dragging" then
            nvgBeginPath(nvg_)
            nvgCircle(nvg_, 0, 0, imgSize * 0.7)
            nvgFillColor(nvg_, nvgRGBA(255, 50, 50, 40))
            nvgFill(nvg_)
            nvgStrokeColor(nvg_, nvgRGBA(255, 80, 80, 120))
            nvgStrokeWidth(nvg_, 0.06)
            nvgStroke(nvg_)
        end

        -- 追逐状态显示黄色警告圈
        if w.state == "chasing" then
            nvgBeginPath(nvg_)
            nvgCircle(nvg_, 0, 0, imgSize * 0.6)
            nvgStrokeColor(nvg_, nvgRGBA(255, 200, 50, 80))
            nvgStrokeWidth(nvg_, 0.04)
            nvgStroke(nvg_)
        end

        local paint = nvgImagePattern(nvg_, -halfW, -halfH, drawW, drawH, 0, wolfImg_, 1.0)
        nvgBeginPath(nvg_)
        nvgRect(nvg_, -halfW, -halfH, drawW, drawH)
        nvgFillPaint(nvg_, paint)
        nvgFill(nvg_)

        nvgRestore(nvg_)

        ::nextWolf::
    end
end

function drawDogsWorld()
    if dogImg_ == nil then return end
    local imgSize = 2.1

    for i = 1, #cachedDogs_ do
        local d = cachedDogs_[i]
        local dx = d.x
        local dz = d.z
        local pidx = d.idx
        local color = d.color
        local dogSpeed = d.speed

        -- 弹跳动画
        local bouncePhase = pidx * 2.3
        local bounceAmp = math.min(dogSpeed * 0.15, 0.12)
        local bounceOffset = math.sin(gameClock_ * 8.0 + bouncePhase) * bounceAmp

        -- 摇摆倾斜
        local tiltMaxRad = math.rad(10)
        local tiltStrength = math.min(dogSpeed * 0.5, 1.0)
        local tiltAngle = math.sin(gameClock_ * 6.0 + bouncePhase * 0.7) * tiltMaxRad * tiltStrength

        -- 翻转：图片默认朝右，向左移动时翻转
        local flipX = d.forwardX < 0

        -- 威压范围
        local presenceR = Settings.Dog.PresenceRadius
        if MapElements.IsInForest(dx, dz) then
            presenceR = presenceR * Settings.MapElements.Forest.PresenceReduction
        end
        nvgBeginPath(nvg_)
        nvgCircle(nvg_, dx, dz, presenceR)
        nvgStrokeColor(nvg_, nvgRGBA(
            math.floor(color[1] * 200),
            math.floor(color[2] * 200),
            math.floor(color[3] * 200),
            40
        ))
        nvgStrokeWidth(nvg_, 0.05)
        nvgStroke(nvg_)

        -- 绘制犬图片
        local drawH = imgSize
        local drawW = imgSize * DOG_ASPECT
        local halfW = drawW / 2
        local halfH = drawH / 2
        nvgSave(nvg_)
        nvgTranslate(nvg_, dx, dz + bounceOffset)
        nvgRotate(nvg_, tiltAngle)
        if flipX then
            nvgScale(nvg_, -1, 1)
        end

        local paint = nvgImagePattern(nvg_, -halfW, -halfH, drawW, drawH, 0, dogImg_, 1.0)
        nvgBeginPath(nvg_)
        nvgRect(nvg_, -halfW, -halfH, drawW, drawH)
        nvgFillPaint(nvg_, paint)
        nvgFill(nvg_)

        nvgRestore(nvg_)
    end
end

-- 在屏幕空间绘制犬标签，避免世界空间极小字号导致渲染伪影
function drawDogsLabels(camScale, camOffsetX, camOffsetZ)
    local imgSize = 2.1
    local halfH = imgSize / 2

    for i = 1, #cachedDogs_ do
        local d = cachedDogs_[i]
        local dx = d.x
        local dz = d.z
        local color = d.color

        -- 世界坐标 → 屏幕坐标
        local labelWorldY = dz - halfH - 0.15
        local screenX = dx * camScale + camOffsetX
        local screenY = labelWorldY * camScale + camOffsetZ

        nvgFontFace(nvg_, "sans")
        nvgTextAlign(nvg_, NVG_ALIGN_CENTER + NVG_ALIGN_BOTTOM)
        if d.isMe then
            -- 网格开启时，在 "You" 上方显示网格坐标
            if MapRenderer.showGrid then
                local S = TileMap.TILE_SIZE
                local col = math.floor(dx / S) + 1
                local row = math.floor(dz / S) + 1
                local coordText = "(" .. col .. "," .. row .. ")"
                nvgFontSize(nvg_, 11)
                nvgFillColor(nvg_, nvgRGBA(200, 255, 200, 220))
                nvgText(nvg_, screenX, screenY - 16, coordText)
            end
            nvgFontSize(nvg_, 14)
            nvgFillColor(nvg_, nvgRGBA(255, 255, 100, 255))
            nvgText(nvg_, screenX, screenY, "You")
        else
            nvgFontSize(nvg_, 12)
            nvgFillColor(nvg_, nvgRGBA(
                math.floor(color[1] * 255),
                math.floor(color[2] * 255),
                math.floor(color[3] * 255),
                255
            ))
            nvgText(nvg_, screenX, screenY, "P" .. d.idx)
        end
    end
end

function drawMinimap(logW, logH)
    if scene_ == nil then return end

    -- 使用缓存数据构建小地图所需的格式
    local dogs = {}
    for i = 1, #cachedDogs_ do
        local d = cachedDogs_[i]
        dogs[i] = { x = d.x, z = d.z, color = d.color, isMe = d.isMe }
    end

    local sheepList = {}
    for i = 1, #cachedSheep_ do
        local s = cachedSheep_[i]
        sheepList[i] = { x = s.x, z = s.z, penned = s.penned }
    end

    -- 收集狼数据
    local wolfList = {}
    for i = 1, #cachedWolves_ do
        local w = cachedWolves_[i]
        if w.state ~= "despawned" then
            wolfList[#wolfList + 1] = { x = w.x, z = w.z, state = w.state }
        end
    end

    Minimap.Draw(nvg_, {
        screenW = logW,
        screenH = logH,
        playerX = cachedCamX_,
        playerZ = cachedCamZ_,
        mapW = Settings.Map.Width,
        mapH = Settings.Map.Height,
        dogs = dogs,
        sheep = sheepList,
        wolves = wolfList,
        elapsed = elapsed_,
    })
end

function drawBarkEffects()
    local halfAngle   = math.rad(60)   -- 120° 扇形
    local arcSegments = 24
    local duration    = 0.35           -- 与 timer 初始值一致
    local maxR        = Settings.Dog.BarkRadius
    local waveCount   = 3              -- 声波层数

    for _, bark in ipairs(barkEffects_) do
        local t = 1.0 - bark.timer / duration        -- 0→1 进度
        local baseAlpha = math.floor((1.0 - t) * 180) -- 整体淡出

        local color = Settings.Dog.Colors[((bark.roleIdx - 1) % #Settings.Dog.Colors) + 1]
        local cr = math.floor(color[1] * 255)
        local cg = math.floor(color[2] * 255)
        local cb = math.floor(color[3] * 255)

        local startAngle = bark.angle - halfAngle
        local endAngle   = bark.angle + halfAngle

        -- 底层：轻微扇形填充（提供方向感）
        local fillR = maxR * t + 0.3
        nvgBeginPath(nvg_)
        nvgMoveTo(nvg_, bark.x, bark.z)
        for s = 0, arcSegments do
            local a = startAngle + (endAngle - startAngle) * s / arcSegments
            nvgLineTo(nvg_, bark.x + math.cos(a) * fillR, bark.z + math.sin(a) * fillR)
        end
        nvgClosePath(nvg_)
        nvgFillColor(nvg_, nvgRGBA(cr, cg, cb, math.floor(baseAlpha * 0.08)))
        nvgFill(nvg_)

        -- 声波弧线：多层同心弧，依次向外扩散
        for w = 1, waveCount do
            local wavePhase = t - (w - 1) * 0.15     -- 每层延迟 0.15
            if wavePhase > 0 and wavePhase <= 1.0 then
                local waveR = maxR * wavePhase + 0.3
                local waveAlpha = (1.0 - wavePhase) * (1.0 - (w - 1) * 0.2) -- 外层更淡
                local a255 = math.floor(waveAlpha * baseAlpha)
                if a255 > 2 then
                    local thick = math.max(0.04, 0.14 - w * 0.03) -- 内层更粗
                    nvgBeginPath(nvg_)
                    for s = 0, arcSegments do
                        local a = startAngle + (endAngle - startAngle) * s / arcSegments
                        local px = bark.x + math.cos(a) * waveR
                        local pz = bark.z + math.sin(a) * waveR
                        if s == 0 then
                            nvgMoveTo(nvg_, px, pz)
                        else
                            nvgLineTo(nvg_, px, pz)
                        end
                    end
                    nvgStrokeColor(nvg_, nvgRGBA(cr, cg, cb, a255))
                    nvgStrokeWidth(nvg_, thick)
                    nvgStroke(nvg_)
                end
            end
        end
    end
end

function drawHUD(w, h)
    -- 顶部信息栏
    nvgSave(nvg_)

    -- 背景条
    nvgBeginPath(nvg_)
    nvgRect(nvg_, 0, 0, w, 36)
    nvgFillColor(nvg_, nvgRGBA(0, 0, 0, 150))
    nvgFill(nvg_)

    nvgFontFace(nvg_, "sans")
    nvgFontSize(nvg_, 16)
    nvgTextAlign(nvg_, NVG_ALIGN_LEFT + NVG_ALIGN_MIDDLE)

    -- 羊毛计数
    nvgFillColor(nvg_, nvgRGBA(255, 220, 100, 255))
    nvgText(nvg_, 12, 18, "Wool: " .. woolCount_)

    -- 入栏进度
    nvgFillColor(nvg_, nvgRGBA(200, 255, 200, 255))
    nvgText(nvg_, 120, 18, "Sheep: " .. sheepPenned_ .. " / " .. totalSheep_)

    -- 丢失计数（被狼叼走）
    if sheepLost_ > 0 then
        nvgFillColor(nvg_, nvgRGBA(255, 100, 100, 255))
        nvgText(nvg_, 300, 18, "Lost: " .. sheepLost_)
    end

    -- 时间
    nvgTextAlign(nvg_, NVG_ALIGN_RIGHT + NVG_ALIGN_MIDDLE)
    nvgFillColor(nvg_, nvgRGBA(200, 200, 255, 255))
    nvgText(nvg_, w - 12, 18, string.format("Time: %.0fs", elapsed_))

    -- 进度条
    local progW = w - 24
    local progH = 4
    local progX = 12
    local progY = 32
    nvgBeginPath(nvg_)
    nvgRect(nvg_, progX, progY, progW, progH)
    nvgFillColor(nvg_, nvgRGBA(50, 50, 50, 200))
    nvgFill(nvg_)

    local prog = totalSheep_ > 0 and (sheepPenned_ / totalSheep_) or 0
    nvgBeginPath(nvg_)
    nvgRect(nvg_, progX, progY, progW * prog, progH)
    nvgFillColor(nvg_, nvgRGBA(100, 220, 80, 255))
    nvgFill(nvg_)

    -- 网格切换按钮（HUD 栏下方右侧）
    local btnW = 56
    local btnH = 24
    local btnX = w - btnW - 10
    local btnY = 42
    gridBtnRect_.x = btnX
    gridBtnRect_.y = btnY
    gridBtnRect_.w = btnW
    gridBtnRect_.h = btnH

    local isOn = MapRenderer.showGrid
    nvgBeginPath(nvg_)
    nvgRoundedRect(nvg_, btnX, btnY, btnW, btnH, 4)
    if isOn then
        nvgFillColor(nvg_, nvgRGBA(80, 180, 80, 200))
    else
        nvgFillColor(nvg_, nvgRGBA(80, 80, 80, 180))
    end
    nvgFill(nvg_)
    nvgStrokeColor(nvg_, nvgRGBA(255, 255, 255, 100))
    nvgStrokeWidth(nvg_, 1)
    nvgStroke(nvg_)

    nvgFontSize(nvg_, 13)
    nvgTextAlign(nvg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
    nvgFillColor(nvg_, nvgRGBA(255, 255, 255, 220))
    nvgText(nvg_, btnX + btnW / 2, btnY + btnH / 2, isOn and "Grid ON" or "Grid OFF")

    nvgRestore(nvg_)
end

------------------------------------------------------------
-- 胜利面板按钮点击检测
------------------------------------------------------------
local victoryBtnRects_ = {}

function handleVictoryClick(lx, ly)
    for _, btn in ipairs(victoryBtnRects_) do
        if lx >= btn.x and lx <= btn.x + btn.w and ly >= btn.y and ly <= btn.y + btn.h then
            if btn.action == "continue" then
                victoryDismissed_ = true
            elseif btn.action == "build" then
                victoryDismissed_ = true
                BuildUI.Toggle()
            end
            return true
        end
    end
    return false
end

function drawVictory(w, h)
    victoryBtnRects_ = {}

    -- 半透明遮罩
    nvgBeginPath(nvg_)
    nvgRect(nvg_, 0, 0, w, h)
    nvgFillColor(nvg_, nvgRGBA(0, 0, 0, 160))
    nvgFill(nvg_)

    local panelW = 300
    local panelH = 230
    local px = (w - panelW) / 2
    local py = (h - panelH) / 2

    -- 面板背景
    nvgBeginPath(nvg_)
    nvgRoundedRect(nvg_, px, py, panelW, panelH, 12)
    nvgFillColor(nvg_, nvgRGBA(40, 60, 30, 240))
    nvgFill(nvg_)
    nvgStrokeColor(nvg_, nvgRGBA(200, 180, 100, 255))
    nvgStrokeWidth(nvg_, 2)
    nvgStroke(nvg_)

    nvgFontFace(nvg_, "sans")
    nvgTextAlign(nvg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)

    -- 标题
    nvgFontSize(nvg_, 28)
    nvgFillColor(nvg_, nvgRGBA(255, 220, 80, 255))
    nvgText(nvg_, w / 2, py + 38, "All Sheep Penned!")

    -- 羊毛
    nvgFontSize(nvg_, 18)
    nvgFillColor(nvg_, nvgRGBA(200, 255, 200, 255))
    nvgText(nvg_, w / 2, py + 74, "Wool Collected: " .. completeWool_)

    -- 时间
    nvgFillColor(nvg_, nvgRGBA(200, 200, 255, 255))
    nvgText(nvg_, w / 2, py + 102, string.format("Time: %.1f seconds", completeTime_))

    -- 按钮参数
    local btnW = 120
    local btnH = 36
    local btnGap = 16
    local btnY = py + panelH - 58
    local btnX1 = w / 2 - btnW - btnGap / 2
    local btnX2 = w / 2 + btnGap / 2

    -- 鼠标位置（hover 效果）
    local mx = input.mousePosition.x / dpr_
    local my = input.mousePosition.y / dpr_

    -- "继续游戏" 按钮
    local hover1 = mx >= btnX1 and mx <= btnX1 + btnW and my >= btnY and my <= btnY + btnH
    nvgBeginPath(nvg_)
    nvgRoundedRect(nvg_, btnX1, btnY, btnW, btnH, 8)
    nvgFillColor(nvg_, hover1 and nvgRGBA(80, 110, 60, 255) or nvgRGBA(60, 90, 45, 255))
    nvgFill(nvg_)
    nvgStrokeColor(nvg_, nvgRGBA(160, 200, 120, 200))
    nvgStrokeWidth(nvg_, 1.5)
    nvgStroke(nvg_)
    nvgFontSize(nvg_, 16)
    nvgFillColor(nvg_, nvgRGBA(220, 255, 220, 255))
    nvgText(nvg_, btnX1 + btnW / 2, btnY + btnH / 2, "继续游戏")
    victoryBtnRects_[#victoryBtnRects_ + 1] = { x = btnX1, y = btnY, w = btnW, h = btnH, action = "continue" }

    -- "建造模式" 按钮
    local hover2 = mx >= btnX2 and mx <= btnX2 + btnW and my >= btnY and my <= btnY + btnH
    nvgBeginPath(nvg_)
    nvgRoundedRect(nvg_, btnX2, btnY, btnW, btnH, 8)
    nvgFillColor(nvg_, hover2 and nvgRGBA(140, 100, 40, 255) or nvgRGBA(120, 85, 30, 255))
    nvgFill(nvg_)
    nvgStrokeColor(nvg_, nvgRGBA(220, 180, 80, 200))
    nvgStrokeWidth(nvg_, 1.5)
    nvgStroke(nvg_)
    nvgFontSize(nvg_, 16)
    nvgFillColor(nvg_, nvgRGBA(255, 230, 160, 255))
    nvgText(nvg_, btnX2 + btnW / 2, btnY + btnH / 2, "建造模式")
    victoryBtnRects_[#victoryBtnRects_ + 1] = { x = btnX2, y = btnY, w = btnW, h = btnH, action = "build" }

    -- 底部提示
    nvgFontSize(nvg_, 13)
    nvgFillColor(nvg_, nvgRGBA(180, 180, 180, 180))
    nvgText(nvg_, w / 2, py + panelH - 14, "Great teamwork!")
end

------------------------------------------------------------
-- 底部装饰 banner
------------------------------------------------------------
function drawBottomBanner(w, h)
    if bannerImg_ == nil or bannerImg_ <= 0 then return end

    -- 计算装饰高度：保持图片宽高比，让高度约占屏幕 12%
    local displayH = h * 0.12
    local displayW = displayH * BANNER_ASPECT

    -- 从屏幕左侧开始平铺，直到覆盖整个底部
    local y = h - displayH
    local x = 0
    while x < w do
        local paint = nvgImagePattern(nvg_, x, y, displayW, displayH, 0, bannerImg_, 1.0)
        nvgBeginPath(nvg_)
        nvgRect(nvg_, x, y, displayW, displayH)
        nvgFillPaint(nvg_, paint)
        nvgFill(nvg_)
        x = x + displayW
    end
end

------------------------------------------------------------
-- 清理
------------------------------------------------------------
function Client.Stop()
    if nvg_ then
        nvgDelete(nvg_)
        nvg_ = nil
    end
end

------------------------------------------------------------
-- 全局入口（引擎要求 entry 文件必须有全局 Start/Stop）
------------------------------------------------------------
function Start()
    Client.Start()
end

function Stop()
    Client.Stop()
end

return Client
