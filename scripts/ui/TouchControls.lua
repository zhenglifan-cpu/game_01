------------------------------------------------------------
-- TouchControls.lua  —— 手机触屏虚拟摇杆 + 叫吠按钮
--
-- 功能：
--   1. 双层虚拟摇杆（左下角）
--      - 内圈：正常移动
--      - 外圈：加速移动（sprint）
--   2. 圆形"叫吠"按钮（右下角）
--
-- 使用 NanoVG 绘制，使用 Touch 事件接收输入。
-- PC 端不创建任何触控 UI。
------------------------------------------------------------
local PlatformUtils = require "urhox-libs.Platform.PlatformUtils"

local TouchControls = {}

------------------------------------------------------------
-- 状态
------------------------------------------------------------
local isMobile_ = false

-- 摇杆参数（逻辑像素）
local joyBaseX_   = 0      -- 摇杆底盘中心 x
local joyBaseY_   = 0      -- 摇杆底盘中心 y
local joyInnerR_  = 0      -- 内圈半径（正常移动区）
local joyOuterR_  = 0      -- 外圈半径（加速移动区）
local joyThumbR_  = 0      -- 拇指圆半径

local joyTouchId_ = -1     -- 正在操作摇杆的触摸 ID（-1 = 无）
local joyDx_      = 0      -- 拇指相对底盘中心偏移 x
local joyDy_      = 0      -- 拇指相对底盘中心偏移 y

-- 摇杆输出
local joyX_       = 0      -- 归一化 x [-1, 1]
local joyY_       = 0      -- 归一化 y [-1, 1]
local joySprint_  = false  -- 是否在外圈（加速）

-- 叫吠按钮参数
local barkBtnX_   = 0
local barkBtnY_   = 0
local barkBtnR_   = 0
local barkTouchId_ = -1
local barkPressed_ = false  -- 本帧是否刚按下
local barkHeld_    = false  -- 是否持续按住

------------------------------------------------------------
-- 初始化（在 Start 中调用一次）
------------------------------------------------------------
function TouchControls.Init()
    isMobile_ = PlatformUtils.IsTouchSupported()

    if not isMobile_ then return end

    -- 订阅触摸事件
    SubscribeToEvent("TouchBegin", "TC_HandleTouchBegin")
    SubscribeToEvent("TouchMove",  "TC_HandleTouchMove")
    SubscribeToEvent("TouchEnd",   "TC_HandleTouchEnd")
end

------------------------------------------------------------
-- 每帧更新布局（需要在渲染前调用，传入逻辑像素尺寸）
------------------------------------------------------------
function TouchControls.UpdateLayout(logW, logH)
    if not isMobile_ then return end

    -- 摇杆：左下角，外圈半径按屏幕短边 12%
    local shortSide = math.min(logW, logH)
    joyOuterR_ = shortSide * 0.12
    joyInnerR_ = joyOuterR_ * 0.55     -- 内圈约外圈 55%
    joyThumbR_ = joyOuterR_ * 0.22     -- 拇指圆

    local margin = joyOuterR_ * 1.3
    joyBaseX_ = margin
    joyBaseY_ = logH - margin

    -- 叫吠按钮：右下角
    barkBtnR_ = shortSide * 0.07
    local barkMargin = barkBtnR_ * 2.2
    barkBtnX_ = logW - barkMargin
    barkBtnY_ = logH - barkMargin
end

------------------------------------------------------------
-- 查询输入（每帧在 HandleUpdate 中调用）
------------------------------------------------------------

--- 获取摇杆方向 (归一化 -1~1)
function TouchControls.GetJoystickX() return joyX_ end
function TouchControls.GetJoystickY() return joyY_ end

--- 是否在外圈（加速移动）
function TouchControls.IsSprinting()  return joySprint_ end

--- 叫吠按钮是否本帧按下（press，不是 hold）
function TouchControls.IsBarkPressed()
    local v = barkPressed_
    barkPressed_ = false   -- 消费一次
    return v
end

--- 是否为手机模式
function TouchControls.IsMobile() return isMobile_ end

------------------------------------------------------------
-- NanoVG 绘制（在 HUD 层调用，不在世界变换内）
------------------------------------------------------------
function TouchControls.Draw(nvg)
    if not isMobile_ then return end

    -- ===== 摇杆 =====
    -- 外圈（透明圆环）
    nvgBeginPath(nvg)
    nvgCircle(nvg, joyBaseX_, joyBaseY_, joyOuterR_)
    nvgFillColor(nvg, nvgRGBA(255, 255, 255, 20))
    nvgFill(nvg)
    nvgStrokeColor(nvg, nvgRGBA(255, 255, 255, 50))
    nvgStrokeWidth(nvg, 1.5)
    nvgStroke(nvg)

    -- 内圈（正常移动范围）
    nvgBeginPath(nvg)
    nvgCircle(nvg, joyBaseX_, joyBaseY_, joyInnerR_)
    nvgStrokeColor(nvg, nvgRGBA(255, 255, 255, 80))
    nvgStrokeWidth(nvg, 1.0)
    nvgStroke(nvg)

    -- 外圈与内圈之间的加速区域标识（虚线风格用点来表示）
    local dotCount = 12
    for i = 1, dotCount do
        local ang = (i / dotCount) * math.pi * 2
        local midR = (joyInnerR_ + joyOuterR_) / 2
        local dx = math.cos(ang) * midR
        local dy = math.sin(ang) * midR
        nvgBeginPath(nvg)
        nvgCircle(nvg, joyBaseX_ + dx, joyBaseY_ + dy, 1.5)
        nvgFillColor(nvg, nvgRGBA(255, 200, 80, joySprint_ and 160 or 40))
        nvgFill(nvg)
    end

    -- 拇指指示器
    local thumbX = joyBaseX_ + joyDx_
    local thumbY = joyBaseY_ + joyDy_
    local thumbAlpha = (joyTouchId_ >= 0) and 180 or 80

    nvgBeginPath(nvg)
    nvgCircle(nvg, thumbX, thumbY, joyThumbR_)
    nvgFillColor(nvg, nvgRGBA(255, 255, 255, thumbAlpha))
    nvgFill(nvg)

    -- 加速时拇指外加发光
    if joySprint_ then
        local glow = nvgRadialGradient(nvg, thumbX, thumbY,
            joyThumbR_ * 0.5, joyThumbR_ * 1.8,
            nvgRGBA(255, 180, 50, 100), nvgRGBA(255, 180, 50, 0))
        nvgBeginPath(nvg)
        nvgCircle(nvg, thumbX, thumbY, joyThumbR_ * 1.8)
        nvgFillPaint(nvg, glow)
        nvgFill(nvg)
    end

    -- ===== 叫吠按钮 =====
    local barkAlpha = barkHeld_ and 220 or 120

    -- 外圈
    nvgBeginPath(nvg)
    nvgCircle(nvg, barkBtnX_, barkBtnY_, barkBtnR_)
    nvgFillColor(nvg, nvgRGBA(255, 160, 40, barkAlpha))
    nvgFill(nvg)
    nvgStrokeColor(nvg, nvgRGBA(255, 200, 80, 200))
    nvgStrokeWidth(nvg, 2)
    nvgStroke(nvg)

    -- 文字
    nvgFontFace(nvg, "sans")
    nvgFontSize(nvg, barkBtnR_ * 0.7)
    nvgTextAlign(nvg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
    nvgFillColor(nvg, nvgRGBA(255, 255, 255, 240))
    nvgText(nvg, barkBtnX_, barkBtnY_, "Bark")
end

------------------------------------------------------------
-- 触摸事件处理（全局函数，由引擎调用）
------------------------------------------------------------

function TC_HandleTouchBegin(eventType, eventData)
    local touchId = eventData["TouchID"]:GetInt()
    local px = eventData["X"]:GetInt()
    local py = eventData["Y"]:GetInt()

    -- 转换为逻辑像素
    local lx = px / dpr_TC()
    local ly = py / dpr_TC()

    -- 检查是否落在摇杆区域
    if joyTouchId_ < 0 then
        local dx = lx - joyBaseX_
        local dy = ly - joyBaseY_
        local dist = math.sqrt(dx * dx + dy * dy)
        if dist <= joyOuterR_ * 1.3 then  -- 略放大触摸区
            joyTouchId_ = touchId
            updateJoystick(dx, dy)
            return
        end
    end

    -- 检查是否落在叫吠按钮区域
    if barkTouchId_ < 0 then
        local dx = lx - barkBtnX_
        local dy = ly - barkBtnY_
        local dist = math.sqrt(dx * dx + dy * dy)
        if dist <= barkBtnR_ * 1.5 then
            barkTouchId_ = touchId
            barkPressed_ = true
            barkHeld_    = true
            return
        end
    end
end

function TC_HandleTouchMove(eventType, eventData)
    local touchId = eventData["TouchID"]:GetInt()
    local px = eventData["X"]:GetInt()
    local py = eventData["Y"]:GetInt()

    if touchId == joyTouchId_ then
        local lx = px / dpr_TC()
        local ly = py / dpr_TC()
        local dx = lx - joyBaseX_
        local dy = ly - joyBaseY_
        updateJoystick(dx, dy)
    end
end

function TC_HandleTouchEnd(eventType, eventData)
    local touchId = eventData["TouchID"]:GetInt()

    if touchId == joyTouchId_ then
        joyTouchId_ = -1
        joyDx_ = 0
        joyDy_ = 0
        joyX_  = 0
        joyY_  = 0
        joySprint_ = false
    end

    if touchId == barkTouchId_ then
        barkTouchId_ = -1
        barkHeld_ = false
    end
end

------------------------------------------------------------
-- 内部函数
------------------------------------------------------------

function updateJoystick(dx, dy)
    local dist = math.sqrt(dx * dx + dy * dy)

    -- 限制拇指在外圈内
    if dist > joyOuterR_ then
        dx = dx / dist * joyOuterR_
        dy = dy / dist * joyOuterR_
        dist = joyOuterR_
    end

    joyDx_ = dx
    joyDy_ = dy

    -- 归一化到 [-1, 1]
    if dist > 4 then  -- 小死区（4 逻辑像素）
        joyX_ = dx / joyOuterR_
        joyY_ = dy / joyOuterR_
    else
        joyX_ = 0
        joyY_ = 0
    end

    -- 是否在外圈区域（加速）
    joySprint_ = dist > joyInnerR_
end

--- 获取 DPR（缓存）
function dpr_TC()
    return graphics and graphics:GetDPR() or 1
end

return TouchControls
