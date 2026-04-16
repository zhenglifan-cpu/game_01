------------------------------------------------------------
-- Standalone.lua  —— 牧羊游戏单机模式
--
-- 合并 Server 逻辑 + Client 渲染，无需网络
-- 直接本地运行羊群 AI，本地处理输入和渲染
------------------------------------------------------------
require "LuaScripts/Utilities/Sample"

local Settings    = require("config.Settings")
local Shared      = require("network.Shared")
local SheepAI     = require("game.SheepAI")
local GameLogic   = require("game.GameLogic")
local MapElements = require("game.MapElements")
local MapRenderer = require("game.MapRenderer")
local TileMap        = require("game.TileMap")
local TouchControls  = require("ui.TouchControls")
local Minimap        = require("ui.Minimap")
local BuildUI        = require("ui.BuildUI")
local WolfAI         = require("game.WolfAI")
local PlatformUtils  = require "urhox-libs.Platform.PlatformUtils"
local AudioManager   = require("game.AudioManager")

local Standalone = {}

-- 平台标识
local isMobile_ = false

------------------------------------------------------------
-- 状态
------------------------------------------------------------
local scene_       = nil
local nvg_         = nil
local fontNormal_  = nil

-- 羊群 & 障碍物
local flock_       = {}
local obstacles_   = {}
local gameState_          = nil
local victoryDismissed_   = false
local sheepImg_    = nil
local sheepOutlineImgs_ = {}
local dogImg_      = nil
local gameClock_   = 0

-- 牧羊犬（单机只有一只）
local dog_ = {
    x          = 8,
    z          = 50,
    vx         = 0,
    vz         = 0,
    speed      = 0,
    angle      = 0,
    barking    = false,
    barkTimer  = 0,
    sprintTimer    = 0,
    sprintCooldown = 0,
    roleIdx    = 1,
}

-- 狼群
local wolves_   = {}
local wolfImg_  = nil
local WOLF_ASPECT = 1264 / 848

-- 吠叫特效
local barkEffects_ = {}
local barkCooldown_ = 0

-- 图片宽高比
local DOG_ASPECT    = 1264 / 848
local BANNER_ASPECT = 1293 / 138

-- 底部装饰
local bannerImg_   = nil

-- 屏幕尺寸
local screenW_ = 0
local screenH_ = 0
local dpr_     = 1

------------------------------------------------------------
-- 初始化
------------------------------------------------------------
function Standalone.Start()
    SampleStart()
    print("[Standalone] Starting sheepherding game (single-player)...")
    print("[Standalone] Map size: " .. Settings.Map.Width .. "x" .. Settings.Map.Height)

    -- 创建场景
    scene_ = Shared.CreateScene()

    -- 创建羊群
    flock_ = SheepAI.CreateFlock(Settings.Sheep.Count)

    -- 创建障碍物（包含地图元素）
    obstacles_ = GameLogic.CreateObstacles()

    -- 初始化游戏状态
    gameState_ = GameLogic.NewState()

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

    -- 创建狼群
    wolves_ = WolfAI.CreatePack(Settings.Wolf.Count)

    -- 订阅事件
    SubscribeToEvent("Update", "HandleUpdate")
    if nvg_ then
        SubscribeToEvent(nvg_, "NanoVGRender", "HandleRender")
    end

    -- 音频系统初始化
    AudioManager.Init(scene_)

    print("[Standalone] Game started. WASD to move, Space to bark, Shift to sprint.")
    print("[Standalone] Map elements: rivers, hills, forests, rocks")
end

------------------------------------------------------------
-- 建造辅助函数
------------------------------------------------------------

--- PC 端：使用当前鼠标预览位置放置
local function tryBuildAtPreview()
    local col, row, canP = BuildUI.GetPreview()
    if col and canP then
        local item = BuildUI.GetSelectedItem()
        if item and GameLogic.CanBuild(gameState_, item.cost) then
            local ok, _ = TileMap.CanPlaceOverlay(item.id, col, row)
            if ok then
                TileMap.AddOverlay(item.id, col, row)
                GameLogic.SpendWool(gameState_, item.cost)
                obstacles_ = GameLogic.CreateObstacles()
                print("[Standalone] Built " .. item.name .. " at (" .. col .. "," .. row .. ")")
            end
        end
    end
end

--- 移动端：根据屏幕触摸坐标计算网格位置并放置
local function tryBuildAtScreen(screenX, screenY)
    local logW = screenW_ / dpr_
    local logH = screenH_ / dpr_
    local viewW = 32.0
    local viewH = viewW * (logH / logW)
    local mapW = Settings.Map.Width
    local mapH = Settings.Map.Height
    local halfVW = viewW / 2
    local halfVH = viewH / 2
    local camX = math.max(halfVW, math.min(mapW - halfVW, dog_.x))
    local camZ = math.max(halfVH, math.min(mapH - halfVH, dog_.z))
    local scale = logW / viewW
    local worldLeft = camX - halfVW
    local worldTop  = camZ - halfVH

    BuildUI.UpdatePreview(screenX, screenY, scale, worldLeft, worldTop, dpr_)
    tryBuildAtPreview()
end

------------------------------------------------------------
-- 主更新
------------------------------------------------------------
---@param eventType string
---@param eventData UpdateEventData
function HandleUpdate(eventType, eventData)
    local dt = eventData["TimeStep"]:GetFloat()

    gameClock_ = gameClock_ + dt

    -- 更新吠叫特效计时
    for i = #barkEffects_, 1, -1 do
        barkEffects_[i].timer = barkEffects_[i].timer - dt
        if barkEffects_[i].timer <= 0 then
            table.remove(barkEffects_, i)
        end
    end

    barkCooldown_ = math.max(0, barkCooldown_ - dt)

    -- ── UI 交互（胜利面板 / 建造模式）── 即使 gameOver 也必须处理 ──

    -- 一键通关作弊器（P 键）
    if not gameState_.gameOver and input:GetKeyPress(KEY_P) then
        cheatWinNow()
    end

    -- 胜利面板点击处理（必须在其他点击检测之前，否则 GetMouseButtonPress 会被消费）
    local victoryPanelActive = gameState_.gameWon and not victoryDismissed_ and not BuildUI.IsActive()
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

    -- 建造模式输入处理（PC + 移动端）— 胜利后且面板已关闭
    if gameState_.gameWon and victoryDismissed_ then
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
                        -- 被建造 UI 消费（按钮/面板）
                    elseif BuildUI.IsActive() then
                        tryBuildAtScreen(state.position.x, state.position.y)
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
                    tryBuildAtPreview()
                end
            end
        end
    end

    -- ── 游戏结束后跳过模拟 ──
    if gameState_.gameOver then return end

    gameState_.elapsed = gameState_.elapsed + dt

    -- 1. 处理输入 → 移动牧羊犬
    updateDogInput(dt)

    -- 2. 构建犬列表
    local dogList = {
        {
            x       = dog_.x,
            z       = dog_.z,
            speed   = dog_.speed,
            angle   = dog_.angle,
            barking = dog_.barking,
        }
    }

    -- 3. 更新狼 AI
    WolfAI.Update(wolves_, flock_, dogList, gameState_, dt)

    -- 4. 更新羊群 AI（将狼作为额外威胁源传入）
    local wolfThreats = WolfAI.GetThreats(wolves_)
    local allThreats = {}
    for _, d in ipairs(dogList) do table.insert(allThreats, d) end
    for _, w in ipairs(wolfThreats) do table.insert(allThreats, w) end
    SheepAI.Update(flock_, allThreats, obstacles_, dt)

    -- 5. 围栏检测
    local newlyPenned = GameLogic.CheckPenning(flock_, gameState_)
    if #newlyPenned > 0 then
        for _, sheepId in ipairs(newlyPenned) do
            print("[Standalone] Sheep " .. sheepId .. " penned! Total: " .. gameState_.sheepPenned .. "/" .. gameState_.totalSheep)
        end
    end

    -- 6. 胜利检测
    if gameState_.gameWon then
        print("[Standalone] All sheep penned! Time: " .. string.format("%.1f", gameState_.elapsed) .. "s")
    end

    -- 7. 音频更新
    AudioManager.Update(dt, flock_, dog_.speed, dog_.x, dog_.z)

    -- 8. 重置吠叫
    dog_.barking = false
end

------------------------------------------------------------
-- 犬输入处理（含地形交互）
------------------------------------------------------------
function updateDogInput(dt)
    local moveX, moveZ = 0, 0
    local wantSprint = false
    local wantBark = false

    if isMobile_ then
        -- 手机：触屏虚拟摇杆（模拟量输入）
        local jx = TouchControls.GetJoystickX()
        local jy = TouchControls.GetJoystickY()
        moveX = jx
        moveZ = jy
        wantSprint = TouchControls.IsSprinting()
        wantBark = TouchControls.IsBarkPressed()
    else
        -- PC：键盘
        if input:GetKeyDown(KEY_W) or input:GetKeyDown(KEY_UP) then moveZ = -1 end
        if input:GetKeyDown(KEY_S) or input:GetKeyDown(KEY_DOWN) then moveZ = 1 end
        if input:GetKeyDown(KEY_A) or input:GetKeyDown(KEY_LEFT) then moveX = -1 end
        if input:GetKeyDown(KEY_D) or input:GetKeyDown(KEY_RIGHT) then moveX = 1 end
        wantSprint = input:GetKeyDown(KEY_SHIFT)
        wantBark = input:GetKeyPress(KEY_SPACE)
        -- G 键切换网格显示
        if input:GetKeyPress(KEY_G) then
            MapRenderer.showGrid = not MapRenderer.showGrid
        end
    end

    -- 归一化
    local nx, nz = Shared.Normalize2D(moveX, moveZ)

    dog_.sprintCooldown = math.max(0, dog_.sprintCooldown - dt)
    local isSprinting = false
    if wantSprint and dog_.sprintCooldown <= 0 then
        dog_.sprintTimer = dog_.sprintTimer + dt
        if dog_.sprintTimer <= Settings.Dog.SprintDuration then
            isSprinting = true
        else
            dog_.sprintCooldown = Settings.Dog.SprintCooldown
            dog_.sprintTimer = 0
        end
    else
        if dog_.sprintTimer > 0 then
            dog_.sprintCooldown = Settings.Dog.SprintCooldown
        end
        dog_.sprintTimer = 0
    end

    local spd = isSprinting and Settings.Dog.SprintSpeed or Settings.Dog.Speed

    -- 地形减速
    local speedMult = MapElements.GetSpeedMultiplier(dog_.x, dog_.z, true)
    spd = spd * speedMult

    dog_.vx = nx * spd
    dog_.vz = nz * spd

    local newX = dog_.x + dog_.vx * dt
    local newZ = dog_.z + dog_.vz * dt

    -- 河流阻挡
    if not MapElements.IsInRiver(newX, newZ) and not MapElements.IsInRock(newX, newZ) then
        dog_.x = newX
        dog_.z = newZ
    else
        -- 尝试分轴移动（滑墙）
        if not MapElements.IsInRiver(newX, dog_.z) and not MapElements.IsInRock(newX, dog_.z) then
            dog_.x = newX
        elseif not MapElements.IsInRiver(dog_.x, newZ) and not MapElements.IsInRock(dog_.x, newZ) then
            dog_.z = newZ
        end
    end

    local r = Settings.Dog.Radius
    dog_.x = Shared.Clamp(dog_.x, r, Settings.Map.Width - r)
    dog_.z = Shared.Clamp(dog_.z, r, Settings.Map.Height - r)
    dog_.speed = math.sqrt(dog_.vx * dog_.vx + dog_.vz * dog_.vz)

    -- 更新朝向
    if dog_.speed > 0.1 then
        dog_.angle = math.atan(dog_.vz, dog_.vx)
    end

    -- 吠叫
    dog_.barkTimer = math.max(0, dog_.barkTimer - dt)

    if wantBark and dog_.barkTimer <= 0 then
        dog_.barking = true
        dog_.barkTimer = Settings.Dog.BarkCooldown
        barkCooldown_ = Settings.Dog.BarkCooldown
        table.insert(barkEffects_, {
            x = dog_.x, z = dog_.z,
            angle = dog_.angle,
            timer = 0.35,
            roleIdx = 1,
        })
        -- 播放犬吠声
        AudioManager.PlayBark()
    end
end

-- 网格按钮点击检测
local gridBtnRect_ = { x = 0, y = 0, w = 0, h = 0 }

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
    if nvg_ == nil then return end

    screenW_ = graphics:GetWidth()
    screenH_ = graphics:GetHeight()
    dpr_ = graphics:GetDPR()
    local logW = screenW_ / dpr_
    local logH = screenH_ / dpr_

    nvgBeginFrame(nvg_, screenW_, screenH_, dpr_)

    local mapW = Settings.Map.Width
    local mapH = Settings.Map.Height

    -- 局部相机: 以玩家犬为中心，按实际屏幕比例计算可见范围
    local viewW = 32.0   -- 水平方向可见 32 米（原 20 米的 160%）
    local viewH = viewW * (logH / logW)  -- 垂直方向按实际屏幕比例

    -- 相机跟随犬
    local camX = dog_.x
    local camZ = dog_.z

    -- 限制相机不超出地图边界
    local halfVW = viewW / 2
    local halfVH = viewH / 2
    camX = math.max(halfVW, math.min(mapW - halfVW, camX))
    camZ = math.max(halfVH, math.min(mapH - halfVH, camZ))

    -- 缩放与偏移
    local scale = logW / viewW
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

    -- 背景
    nvgBeginPath(nvg_)
    nvgRect(nvg_, 0, 0, logW, logH)
    nvgFillColor(nvg_, nvgRGBA(34, 45, 30, 255))
    nvgFill(nvg_)

    -- 应用变换
    nvgSave(nvg_)
    nvgTranslate(nvg_, offsetX, offsetZ)
    nvgScale(nvg_, scale, scale)

    -- 设置字体（MapRenderer 的文字绘制需要）
    nvgFontFace(nvg_, "sans")

    -- 绘制所有地图元素
    MapRenderer.DrawAll(nvg_, mapW, mapH, gameClock_,
        worldLeft, worldTop, worldLeft + viewW, worldTop + viewH)

    -- 羊群
    drawSheep()

    -- 建造预览（世界空间）
    BuildUI.DrawPreview(nvg_)

    -- 狼群
    drawWolves()

    -- 吠叫特效
    drawBarkEffects()

    -- 牧羊犬（图片部分，在世界变换内）
    drawDogWorld()

    nvgRestore(nvg_)

    -- 犬标签（屏幕空间，避免极小字号导致黄色雾状伪影）
    drawDogLabel(scale, offsetX, offsetZ)

    -- 小地图
    drawMinimap(logW, logH)

    -- HUD
    drawHUD(logW, logH)

    -- 底部装饰（PC 端显示）
    if not isMobile_ then
        drawBottomBanner(logW, logH)
    end

    -- 手机触控 UI（摇杆 + 叫吠按钮）
    TouchControls.UpdateLayout(logW, logH)
    TouchControls.Draw(nvg_)

    -- 建造 HUD（屏幕空间）
    BuildUI.DrawHUD(nvg_, logW, logH, gameState_.woolCollected, gameState_.gameWon)

    -- 胜利画面（未关闭且非建造模式时显示）
    if gameState_.gameWon and not victoryDismissed_ and not BuildUI.IsActive() then
        drawVictory(logW, logH)
    end

    nvgEndFrame(nvg_)
end

------------------------------------------------------------
-- 绘制羊群
------------------------------------------------------------
function drawSheep()
    if sheepImg_ == nil then return end
    local imgSize = 2.1

    for _, sheep in ipairs(flock_) do
        local sx = sheep.x
        local sz = sheep.z

        local bouncePhase = sheep.id * 1.7
        local sheepSpeed = sheep.speed or 0

        local bounceAmp = math.min(sheepSpeed * 0.15, 0.12)
        local bounceOffset = math.sin(gameClock_ * 8.0 + bouncePhase) * bounceAmp

        local tiltMaxRad = math.rad(10)
        local tiltStrength = math.min(sheepSpeed * 0.5, 1.0)
        local tiltAngle = math.sin(gameClock_ * 6.0 + bouncePhase * 0.7) * tiltMaxRad * tiltStrength

        local outlineImg = nil
        if sheep.state == "panic" then
            outlineImg = sheepOutlineImgs_.panic
        elseif sheep.state == "alert" then
            outlineImg = sheepOutlineImgs_.alert
        elseif sheep.state == "recover" then
            outlineImg = sheepOutlineImgs_.recover
        end

        local alpha = 1.0
        if sheep.penned then
            alpha = 0.6
        end

        local flipX = math.cos(sheep.angle) > 0

        local half = imgSize / 2
        nvgSave(nvg_)
        nvgTranslate(nvg_, sx, sz + bounceOffset)
        nvgRotate(nvg_, tiltAngle)
        if flipX then
            nvgScale(nvg_, -1, 1)
        end

        if outlineImg then
            local outPaint = nvgImagePattern(nvg_, -half, -half, imgSize, imgSize, 0, outlineImg, alpha)
            nvgBeginPath(nvg_)
            nvgRect(nvg_, -half, -half, imgSize, imgSize)
            nvgFillPaint(nvg_, outPaint)
            nvgFill(nvg_)
        end

        local paint = nvgImagePattern(nvg_, -half, -half, imgSize, imgSize, 0, sheepImg_, alpha)
        nvgBeginPath(nvg_)
        nvgRect(nvg_, -half, -half, imgSize, imgSize)
        nvgFillPaint(nvg_, paint)
        nvgFill(nvg_)

        nvgRestore(nvg_)
    end
end

------------------------------------------------------------
-- 绘制吠叫特效
------------------------------------------------------------
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

------------------------------------------------------------
-- 绘制牧羊犬
------------------------------------------------------------
function drawDogWorld()
    if dogImg_ == nil then return end

    local dx = dog_.x
    local dz = dog_.z
    local color = Settings.Dog.Colors[1]
    local imgSize = 2.1

    local bounceAmp = math.min(dog_.speed * 0.15, 0.12)
    local bounceOffset = math.sin(gameClock_ * 8.0) * bounceAmp

    local tiltMaxRad = math.rad(10)
    local tiltStrength = math.min(dog_.speed * 0.5, 1.0)
    local tiltAngle = math.sin(gameClock_ * 6.0) * tiltMaxRad * tiltStrength

    local flipX = dog_.vx < 0

    -- 威压范围圈
    local presenceR = Settings.Dog.PresenceRadius
    local inForest = MapElements.IsInForest(dx, dz)
    if inForest then
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

    -- 犬图片
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

------------------------------------------------------------
-- 绘制狼群
------------------------------------------------------------
function drawWolves()
    if wolfImg_ == nil then return end
    local imgSize = 2.3  -- 狼比犬略大

    for _, wolf in ipairs(wolves_) do
        if wolf.state == "despawned" then goto nextWolf end

        local wx = wolf.x
        local wz = wolf.z

        local bouncePhase = wolf.id * 2.3
        local wolfSpeed = wolf.speed or 0

        local bounceAmp = math.min(wolfSpeed * 0.15, 0.12)
        local bounceOffset = math.sin(gameClock_ * 8.0 + bouncePhase) * bounceAmp

        local tiltMaxRad = math.rad(10)
        local tiltStrength = math.min(wolfSpeed * 0.5, 1.0)
        local tiltAngle = math.sin(gameClock_ * 6.0 + bouncePhase * 0.7) * tiltMaxRad * tiltStrength

        local flipX = math.cos(wolf.angle) > 0

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

        -- 拖拽状态时显示红色光圈
        if wolf.state == "dragging" then
            nvgBeginPath(nvg_)
            nvgCircle(nvg_, 0, 0, imgSize * 0.7)
            nvgFillColor(nvg_, nvgRGBA(255, 50, 50, 40))
            nvgFill(nvg_)
            nvgStrokeColor(nvg_, nvgRGBA(255, 80, 80, 120))
            nvgStrokeWidth(nvg_, 0.06)
            nvgStroke(nvg_)
        end

        -- 追逐状态时显示黄色警告圈
        if wolf.state == "chasing" then
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

-- 在屏幕空间绘制 "You" 标签，避免世界空间极小字号导致渲染伪影
function drawDogLabel(camScale, camOffsetX, camOffsetZ)
    local dx = dog_.x
    local dz = dog_.z
    local imgSize = 2.1
    local halfH = imgSize / 2

    -- 世界坐标 → 屏幕坐标
    local labelWorldY = dz - halfH - 0.15
    local screenX = dx * camScale + camOffsetX
    local screenY = labelWorldY * camScale + camOffsetZ

    nvgFontFace(nvg_, "sans")
    nvgTextAlign(nvg_, NVG_ALIGN_CENTER + NVG_ALIGN_BOTTOM)

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
end

------------------------------------------------------------
-- 小地图
------------------------------------------------------------
function drawMinimap(logW, logH)
    -- 收集犬数据（单机只有一只犬）
    local dogs = {
        {
            x = dog_.x,
            z = dog_.z,
            color = Settings.Dog.Colors[1],
            isMe = true,
        }
    }

    -- 收集羊数据
    local sheepList = {}
    for _, sheep in ipairs(flock_) do
        table.insert(sheepList, {
            x = sheep.x,
            z = sheep.z,
            penned = sheep.penned or false,
        })
    end

    -- 收集狼数据
    local wolfList = {}
    for _, wolf in ipairs(wolves_) do
        if wolf.state ~= "despawned" then
            table.insert(wolfList, {
                x = wolf.x,
                z = wolf.z,
                state = wolf.state,
            })
        end
    end

    Minimap.Draw(nvg_, {
        screenW = logW,
        screenH = logH,
        playerX = dog_.x,
        playerZ = dog_.z,
        mapW = Settings.Map.Width,
        mapH = Settings.Map.Height,
        dogs = dogs,
        sheep = sheepList,
        wolves = wolfList,
    })
end

------------------------------------------------------------
-- HUD
------------------------------------------------------------
function drawHUD(w, h)
    nvgSave(nvg_)

    nvgBeginPath(nvg_)
    nvgRect(nvg_, 0, 0, w, 36)
    nvgFillColor(nvg_, nvgRGBA(0, 0, 0, 150))
    nvgFill(nvg_)

    nvgFontFace(nvg_, "sans")
    nvgFontSize(nvg_, 16)
    nvgTextAlign(nvg_, NVG_ALIGN_LEFT + NVG_ALIGN_MIDDLE)

    nvgFillColor(nvg_, nvgRGBA(255, 220, 100, 255))
    nvgText(nvg_, 12, 18, "Wool: " .. gameState_.woolCollected)

    nvgFillColor(nvg_, nvgRGBA(200, 255, 200, 255))
    nvgText(nvg_, 120, 18, "Sheep: " .. gameState_.sheepPenned .. " / " .. gameState_.totalSheep)

    -- 显示被狼叼走的羊数量
    local sheepLost = gameState_.sheepLost or 0
    if sheepLost > 0 then
        nvgFillColor(nvg_, nvgRGBA(255, 100, 100, 255))
        nvgText(nvg_, 280, 18, "Lost: " .. sheepLost)
    end

    nvgTextAlign(nvg_, NVG_ALIGN_RIGHT + NVG_ALIGN_MIDDLE)
    nvgFillColor(nvg_, nvgRGBA(200, 200, 255, 255))
    nvgText(nvg_, w - 12, 18, string.format("Time: %.0fs", gameState_.elapsed))

    local progW = w - 24
    local progX = 12
    local progY = 32
    nvgBeginPath(nvg_)
    nvgRect(nvg_, progX, progY, progW, 4)
    nvgFillColor(nvg_, nvgRGBA(50, 50, 50, 200))
    nvgFill(nvg_)

    local prog = gameState_.totalSheep > 0 and (gameState_.sheepPenned / gameState_.totalSheep) or 0
    nvgBeginPath(nvg_)
    nvgRect(nvg_, progX, progY, progW * prog, 4)
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
-- 一键通关作弊器（P 键）
------------------------------------------------------------
function cheatWinNow()
    print("[Cheat] Win now activated!")
    local P = Settings.Pen
    local penCX = P.X + P.Width / 2
    local penCZ = P.Y + P.Height / 2
    local maxR = math.min(P.Width, P.Height) * 0.5 - 1.0
    local count = 0
    for _, sheep in ipairs(flock_) do
        if not sheep.penned then
            sheep.penned = true
            count = count + 1
            -- 放置在围栏内环形排列
            local angle = (count - 1) * (2 * math.pi / Settings.Sheep.Count)
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
    print("[Cheat] " .. count .. " sheep teleported to pen. Total wool: " .. gameState_.woolCollected)
end

------------------------------------------------------------
-- 胜利画面（带按钮）
------------------------------------------------------------
local victoryBtnRects_ = {}  -- { {x,y,w,h,action}, ... }

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
    nvgText(nvg_, w / 2, py + 74, "Wool: " .. gameState_.woolCollected)

    -- 时间
    nvgFillColor(nvg_, nvgRGBA(200, 200, 255, 255))
    nvgText(nvg_, w / 2, py + 102, string.format("Time: %.1f seconds", gameState_.elapsed))

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
    nvgText(nvg_, w / 2, py + panelH - 14, "Great shepherding!")
end

------------------------------------------------------------
-- 底部装饰 banner
------------------------------------------------------------
function drawBottomBanner(w, h)
    if bannerImg_ == nil or bannerImg_ <= 0 then return end

    local displayH = h * 0.12
    local displayW = displayH * BANNER_ASPECT

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
-- 全局入口
------------------------------------------------------------
function Start()
    Standalone.Start()
end

function Stop()
end

return Standalone
