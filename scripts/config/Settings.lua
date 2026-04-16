------------------------------------------------------------
-- Settings.lua  —— 牧羊游戏全局配置
------------------------------------------------------------
local Settings = {}

------------------------------------------------------------
-- 地图（扩大为 60×60 正方形，便于后期添加 tile 素材）
------------------------------------------------------------
Settings.Map = {
    Width       = 60,       -- 米
    Height      = 60,       -- 米
    FenceThick  = 0.3,      -- 围墙粗细（渲染用）
}

------------------------------------------------------------
-- 围栏（目标区域）—— 移至右上角
------------------------------------------------------------
Settings.Pen = {
    X      = 46,      -- 围栏左上角 (col24 → (24-1)*2=46)
    Y      = 0,       -- (row1 → (1-1)*2=0)
    Width  = 10,      -- 5格×2m=10m
    Height = 10,      -- 5格×2m=10m
    GateWidth = 3.5,  -- 栅栏门宽度
}

------------------------------------------------------------
-- 牧羊犬
------------------------------------------------------------
Settings.Dog = {
    Radius       = 0.4,     -- 碰撞/渲染半径
    Speed        = 5.0,     -- 正常移动速度 m/s
    SprintSpeed  = 8.0,     -- 冲刺速度 m/s
    SprintDuration = 1.5,   -- 冲刺持续时间 s
    SprintCooldown = 3.0,   -- 冲刺冷却 s
    BarkRadius   = 4.5,     -- 吠叫影响半径
    BarkCooldown = 0.1,     -- 吠叫冷却 s
    PresenceRadius = 3.0,   -- 存在威压半径
    Colors = {
        {0.2, 0.6, 1.0},    -- 玩家1 蓝色
        {1.0, 0.4, 0.2},    -- 玩家2 橙色
        {0.3, 0.9, 0.3},    -- 玩家3 绿色
        {0.9, 0.3, 0.8},    -- 玩家4 紫色
    },
}

------------------------------------------------------------
-- 羊
------------------------------------------------------------
Settings.Sheep = {
    Count           = 15,       -- 扩大地图后增加羊数量
    Radius          = 0.525,    -- 碰撞/渲染半径（0.35 × 1.5）

    -- Boids 力权重
    W_Separation    = 1.8,
    W_Alignment     = 0.8,
    W_Cohesion      = 0.6,
    W_Flee          = 2.5,
    W_Obstacle      = 4.0,
    W_Boundary      = 3.0,

    -- 感知半径
    R_Separation    = 1.5,     -- 分离半径（随体积增大）
    R_Alignment     = 4.0,     -- 对齐半径
    R_Cohesion      = 6.0,     -- 聚合半径
    R_Alert         = 8.0,     -- 警觉距离
    R_Flee          = 5.0,     -- 逃跑距离

    -- 状态速度（idle/flock 提升 5 倍，让羊持续活跃移动）
    Speed_Idle      = 3.0,
    Speed_Flock     = 4.5,
    Speed_Alert     = 3.0,
    Speed_Panic     = 5.25,
    Speed_Recover   = 1.2,

    -- 吠叫加成
    BarkForceMult   = 3.0,
    BarkRadiusMult  = 1.5,
    BarkSpeedBoost  = 1.5,       -- 被吠叫后速度额外 ×1.5
    BarkBoostDuration = 4.0,     -- 吠叫加速持续时间（秒）
    BarkImpulseForce  = 12.0,    -- 吠叫冲击力强度
    BarkImpulseDuration = 0.5,   -- 吠叫冲击力持续时间（秒）

    -- 食物吸引（idle/flock 时头羊带领觅食）
    FoodSearchRange     = 20.0,  -- 头羊搜索食物的范围（米）
    FoodAttractionForce = 1.8,   -- 头羊向食物移动的力强度
    FoodArriveRadius    = 2.5,   -- 到达食物后停留的半径
    FoodGrazeTime       = 4.0,   -- 在食物旁停留的时间（秒）
    FoodCooldownTime    = 2.0,   -- 离开食物后冷却时间（秒）
    LeaderFollowForce   = 1.5,   -- 跟随者跟随头羊的力强度
    LeaderFollowRange   = 20.0,  -- 跟随者感知头羊的范围（米）

    -- 树木吸引（idle/flock 时缓慢向树移动，已被食物系统替代但保留兼容）
    TreeAttractionRange = 12.0,  -- 搜索最近树木的范围（米）
    TreeAttractionForce = 1.2,   -- 吸引力强度

    -- 被解救后奔逃（挣脱狼后朝最近羊群冲刺）
    RescuedFleeSpeedMult = 2.0, -- 解救后速度倍率（200%）
    RescuedFleeDuration  = 5.0, -- 解救后奔逃持续时间（秒）
    RescuedFlockRadius   = 4.0, -- 与羊群汇合判定距离（米）

    -- 围栏自动吸引（羊靠近围栏门口时自觉走入）
    PenAttractionRange = 3.0,   -- 吸引生效距离（米）
    PenAttractionForce = 0.35,  -- 吸引力强度（缓慢移动）

    -- 状态计时
    AlertToIdle     = 2.5,     -- 威胁消失后回到Idle的秒数
    PanicDuration   = 3.0,     -- 恐慌持续时间
    RecoverDuration = 2.0,     -- 恢复持续时间
}

------------------------------------------------------------
-- 地图元素配置（纯草地，无地形障碍）
------------------------------------------------------------
Settings.MapElements = {
    Forest = {
        PresenceReduction = 0.5,  -- 保留供旧代码引用，实际不生效
    },
}

------------------------------------------------------------
-- 狼
------------------------------------------------------------
Settings.Wolf = {
    Count            = 1,       -- 狼的数量（与玩家数量一致，单机1只）
    Radius           = 0.45,    -- 碰撞/渲染半径
    Speed            = 5.0,     -- 移动速度（与牧羊犬相同）
    DragSpeedMult    = 0.3,     -- 拖拽羊时速度倍率（30%）
    FleeSpeedMult    = 0.5,     -- 逃跑时速度倍率（减半）

    -- 追踪参数
    DetectRange      = 25.0,    -- 锁定羊的探测范围（米）
    CatchRadius      = 0.8,     -- 抓住羊的距离
    IsolationBonus   = 5.0,     -- 落单羊的优先级加分

    -- 拖拽参数
    DragToEdgeMargin = 2.0,     -- 拖到距地图边缘多远算"到达"（1个网格=2米）
    DragEdgeClamp    = 2.0,     -- 拖拽状态时的边界限制（不进入最外圈网格）
    EdgeDragTime     = 5.0,     -- 到达边缘后需持续拖拽的时间（秒）

    -- 驱赶参数（未抓到羊时）
    ScareBarkCount   = 8,       -- 在时间窗口内吠叫此次数可驱赶
    ScareBarkWindow  = 6.0,     -- 吠叫计数的时间窗口（秒）
    ScaredFleeDuration = 5.0,   -- 被驱赶后向地图边缘奔跑的持续时间（秒）
    EdgeFleeDespawnTime = 15.0, -- 消失后等待重生时间（秒）
    RespawnEdgeOffset = 10,     -- 重生位置距消失点的最大偏移（网格单位）

    -- 解救参数（已抓到羊时被解救，任一条件满足即可）
    RescueOverlapTime = 2.0,    -- 条件A：牧羊犬与狼重叠的时间（秒）
    RescueBarkCount   = 3,      -- 条件B：时间窗口内吠叫次数
    RescueBarkWindow  = 3.0,    -- 条件B：吠叫计数的时间窗口（秒）
    RescueFleeDuration = 2.0,   -- 被解救后逃跑持续时间（秒）

    -- 重生参数
    RespawnTime      = 15.0,    -- 成功叼走羊后重生等待时间（秒）

    -- 生成位置：远离羊圈的方向
    SpawnMargin      = 5.0,     -- 距地图边缘生成范围
}

------------------------------------------------------------
-- 网络控制位
------------------------------------------------------------
Settings.CTRL = {
    UP      = 1,
    DOWN    = 2,
    LEFT    = 4,
    RIGHT   = 8,
    SPRINT  = 16,
    BARK    = 32,
}

------------------------------------------------------------
-- 网络事件
------------------------------------------------------------
Settings.EVENTS = {
    CLIENT_READY    = "ClientReady",
    ASSIGN_ROLE     = "AssignRole",
    BARK            = "Bark",
    SHEEP_PENNED    = "SheepPenned",
    GAME_COMPLETE   = "GameComplete",
    GAME_STATE      = "GameState",
    BUILD_REQUEST   = "BuildRequest",
    BUILD_PLACED    = "BuildPlaced",
    BUILD_FAILED    = "BuildFailed",
    CHEAT_WIN       = "CheatWin",
}

------------------------------------------------------------
-- 节点变量
------------------------------------------------------------
Settings.VARS = {
    IS_DOG      = "IsDog",
    PLAYER_IDX  = "PlayerIdx",
    IS_SHEEP    = "IsSheep",
    SHEEP_IDX   = "SheepIdx",
    SHEEP_STATE = "SheepState",
    IS_WOLF     = "IsWolf",
    WOLF_IDX    = "WolfIdx",
    WOLF_STATE  = "WolfState",
}

------------------------------------------------------------
-- 游戏规则
------------------------------------------------------------
Settings.Game = {
    WoolPerSheep = 1,           -- 每只羊入栏得到的羊毛
    TargetWool   = 0,           -- 0 = 全部入栏即胜利
}

------------------------------------------------------------
-- 建造系统
------------------------------------------------------------
Settings.Build = {
    Items = {
        { id = "fence_tall",   name = "栅栏", cost = 2, cols = 1, rows = 1 },
        { id = "pine",         name = "松树", cost = 3, cols = 2, rows = 2 },
        { id = "rocks_small",  name = "石堆", cost = 1, cols = 1, rows = 1 },
    },
}

------------------------------------------------------------
-- 出生点（适配 60×60 地图）
------------------------------------------------------------
Settings.SpawnPoints = {
    Vector3(8, 0, 50),
    Vector3(52, 0, 50),
    Vector3(8, 0, 8),
    Vector3(52, 0, 8),
}

return Settings
