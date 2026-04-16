------------------------------------------------------------
-- AudioManager.lua  —— 牧羊游戏音频管理
--
-- 职责:
--   1. 背景音乐循环播放
--   2. 羊群随机咩叫（落单/少伴叫得更频繁更大声）
--   3. 牧羊犬奔跑声（在草地上快速移动时）
--   4. 牧羊犬吠叫声（吠叫时同步播放）
------------------------------------------------------------
local Settings = require("config.Settings")

local AudioManager = {}

------------------------------------------------------------
-- 音频资源路径
------------------------------------------------------------
local BGM_PATH = "audio/music_1776259708794.ogg"

local SHEEP_BAA_PATHS = {
    "audio/sfx/sheep_baa_1.ogg",
    "audio/sfx/sheep_baa_2.ogg",
    "audio/sfx/sheep_baa_3.ogg",
}
local SHEEP_BAA_LONELY_PATH = "audio/sfx/sheep_baa_lonely.ogg"
local DOG_BARK_PATH         = "audio/sfx/dog_bark.ogg"
local DOG_RUN_PATH          = "audio/sfx/dog_run_grass.ogg"

------------------------------------------------------------
-- 配置
------------------------------------------------------------
local BGM_GAIN       = 0.35   -- 背景音乐音量
local SHEEP_BASE_INTERVAL = { min = 20.0, max = 50.0 }  -- 有同伴时的咩叫间隔（降至20%）
local SHEEP_LONELY_INTERVAL = { min = 7.5, max = 20.0 } -- 落单时的咩叫间隔（降至20%）
local SHEEP_LONELY_THRESHOLD = 2   -- 附近同伴 <= 此数视为"落单"
local SHEEP_LONELY_RANGE     = 8.0 -- 计算同伴的范围（米）
local SHEEP_GAIN_NORMAL = 0.3
local SHEEP_GAIN_LONELY = 0.7
local SHEEP_NORMAL_MAX_DIST = 15.0 -- 普通羊：离玩家超过此距离声音消失
local SHEEP_LONELY_MAX_DIST = 20.0 -- 落单羊：离牧羊犬超过此距离声音消失
local DOG_RUN_SPEED_THRESHOLD = 3.0  -- 犬速度超过此值播放跑步声
local DOG_RUN_GAIN   = 0.25
local DOG_BARK_GAIN  = 0.6
local MAX_CONCURRENT_SHEEP_SOUNDS = 3  -- 同时最多几只羊在叫

------------------------------------------------------------
-- 内部状态
------------------------------------------------------------
local bgmNode_       = nil
local bgmSource_     = nil
local dogRunNode_    = nil
local dogRunSource_  = nil
local dogRunPlaying_ = false

-- 每只羊的咩叫计时器 { [sheepId] = nextBaaTime }
local sheepBaaTimers_ = {}

-- 当前正在发声的羊数量
local activeSheepSounds_ = 0

-- 场景引用
---@type Scene
local scene_ = nil

------------------------------------------------------------
-- 初始化（在 Start 中调用一次）
------------------------------------------------------------
function AudioManager.Init(scene)
    scene_ = scene

    -- 创建 SoundListener（必须有才能听到声音）
    local listenerNode = scene_:CreateChild("AudioListener")
    local listener = listenerNode:CreateComponent("SoundListener")
    audio:SetListener(listener)

    -- 背景音乐
    bgmNode_ = scene_:CreateChild("BGM")
    bgmSource_ = bgmNode_:CreateComponent("SoundSource")
    bgmSource_.soundType = "Music"
    bgmSource_.gain = BGM_GAIN

    local bgmSound = cache:GetResource("Sound", BGM_PATH)
    if bgmSound then
        bgmSound.looped = true
        bgmSource_:Play(bgmSound)
    end

    -- 犬奔跑声节点（预创建，循环播放，通过 gain 控制）
    dogRunNode_ = scene_:CreateChild("DogRun")
    dogRunSource_ = dogRunNode_:CreateComponent("SoundSource")
    dogRunSource_.soundType = "Effect"
    dogRunSource_.gain = 0  -- 初始静音

    local runSound = cache:GetResource("Sound", DOG_RUN_PATH)
    if runSound then
        runSound.looped = true
        dogRunSource_:Play(runSound)
    end

    -- 初始化羊叫计时器
    sheepBaaTimers_ = {}
    activeSheepSounds_ = 0
end

------------------------------------------------------------
-- 计算一只羊附近的同伴数量
------------------------------------------------------------
local function countNearbyCompanions(sheep, allSheep)
    local count = 0
    local rangeSq = SHEEP_LONELY_RANGE * SHEEP_LONELY_RANGE
    for _, other in ipairs(allSheep) do
        if other.id ~= sheep.id and not other.penned then
            local dx = other.x - sheep.x
            local dz = other.z - sheep.z
            if dx * dx + dz * dz < rangeSq then
                count = count + 1
            end
        end
    end
    return count
end

------------------------------------------------------------
-- 播放一只羊的咩叫声
-- distGain: 0~1 距离衰减系数
-- pan:      -1.0(左) ~ 1.0(右) 声像位置
------------------------------------------------------------
local function playSheepBaa(sheep, isLonely, distGain, pan)
    if not scene_ then return end
    if activeSheepSounds_ >= MAX_CONCURRENT_SHEEP_SOUNDS then return end
    if distGain <= 0 then return end

    local sndPath
    if isLonely then
        sndPath = SHEEP_BAA_LONELY_PATH
    else
        sndPath = SHEEP_BAA_PATHS[math.random(1, #SHEEP_BAA_PATHS)]
    end

    local sound = cache:GetResource("Sound", sndPath)
    if not sound then return end
    sound.looped = false

    -- 创建临时节点播放
    local node = scene_:CreateChild("SheepBaa")
    local source = node:CreateComponent("SoundSource")
    source.soundType = "Effect"
    local baseGain = isLonely and SHEEP_GAIN_LONELY or SHEEP_GAIN_NORMAL
    -- 随机变调 ±15% 让每只羊听起来不同
    local freqVar = 1.0 + (math.random() - 0.5) * 0.3
    source:Play(sound, sound.frequency * freqVar, baseGain * distGain, pan or 0)
    source.autoRemoveMode = REMOVE_NODE  -- 播放完自动删除节点

    activeSheepSounds_ = activeSheepSounds_ + 1
end

------------------------------------------------------------
-- 播放犬吠声
------------------------------------------------------------
function AudioManager.PlayBark()
    if not scene_ then return end

    local sound = cache:GetResource("Sound", DOG_BARK_PATH)
    if not sound then return end
    sound.looped = false

    local node = scene_:CreateChild("DogBark")
    local source = node:CreateComponent("SoundSource")
    source.soundType = "Effect"
    source.gain = DOG_BARK_GAIN
    source:Play(sound)
    source.autoRemoveMode = REMOVE_NODE
end

------------------------------------------------------------
-- 每帧更新（在 HandleUpdate 中调用）
--
-- @param dt        float   帧间隔
-- @param sheepList table   羊群数组 { {id, x, z, penned, state, speed, ...}, ... }
-- @param dogSpeed  float   本地犬的速度标量
-- @param dogX      float   本地犬的 x 坐标
-- @param dogZ      float   本地犬的 z 坐标
------------------------------------------------------------
function AudioManager.Update(dt, sheepList, dogSpeed, dogX, dogZ)
    if not scene_ then return end

    -- === 犬奔跑声 ===
    if dogRunSource_ then
        if dogSpeed > DOG_RUN_SPEED_THRESHOLD then
            -- 速度越快音量越大（线性映射到 0 ~ DOG_RUN_GAIN）
            local t = math.min((dogSpeed - DOG_RUN_SPEED_THRESHOLD) / 5.0, 1.0)
            dogRunSource_.gain = DOG_RUN_GAIN * t
        else
            dogRunSource_.gain = 0
        end
    end

    -- === 统计当前活跃的羊叫声数量 ===
    activeSheepSounds_ = 0
    local sources = audio:GetSoundSources()
    if sources then
        for i = 1, #sources do
            local src = sources[i]
            if src and src:IsPlaying() and src.soundType == "Effect" then
                local node = src:GetNode()
                if node and node.name == "SheepBaa" then
                    activeSheepSounds_ = activeSheepSounds_ + 1
                end
            end
        end
    end

    -- === 羊群随机咩叫 ===
    if not sheepList then return end

    for _, sheep in ipairs(sheepList) do
        if sheep.penned then goto continue end

        local sid = sheep.id
        if not sheepBaaTimers_[sid] then
            -- 初始化：随机错开开始时间
            sheepBaaTimers_[sid] = math.random() * 40.0
        end

        sheepBaaTimers_[sid] = sheepBaaTimers_[sid] - dt

        if sheepBaaTimers_[sid] <= 0 then
            local nearby = countNearbyCompanions(sheep, sheepList)
            local isLonely = nearby <= SHEEP_LONELY_THRESHOLD

            -- 距离衰减 + 左右声像
            local distGain = 1.0
            local pan = 0
            if dogX and dogZ then
                local dx = sheep.x - dogX
                local dz = sheep.z - dogZ
                local d = math.sqrt(dx * dx + dz * dz)
                local maxDist = isLonely and SHEEP_LONELY_MAX_DIST or SHEEP_NORMAL_MAX_DIST
                if d >= maxDist then
                    distGain = 0
                else
                    distGain = 1.0 - d / maxDist
                end
                -- 左右声像：世界X轴偏移映射到 [-1, 1]
                if maxDist > 0 then
                    pan = math.max(-1.0, math.min(1.0, dx / maxDist))
                end
            end

            playSheepBaa(sheep, isLonely, distGain, pan)

            -- 设置下一次咩叫的时间
            local interval
            if isLonely then
                interval = SHEEP_LONELY_INTERVAL.min
                    + math.random() * (SHEEP_LONELY_INTERVAL.max - SHEEP_LONELY_INTERVAL.min)
            else
                interval = SHEEP_BASE_INTERVAL.min
                    + math.random() * (SHEEP_BASE_INTERVAL.max - SHEEP_BASE_INTERVAL.min)
            end
            sheepBaaTimers_[sid] = interval
        end

        ::continue::
    end
end

------------------------------------------------------------
-- 清理
------------------------------------------------------------
function AudioManager.Stop()
    if bgmSource_ then
        bgmSource_:Stop()
    end
    if dogRunSource_ then
        dogRunSource_:Stop()
    end
    sheepBaaTimers_ = {}
    scene_ = nil
end

return AudioManager
