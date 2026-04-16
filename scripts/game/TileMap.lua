------------------------------------------------------------
-- TileMap.lua  —— 瓦片地图核心模块
--
-- 地图尺寸 60×60 米，每个瓦片 2×2 米，网格 30×30
--
-- ★ 双层结构 ★
-- 1. grid       : 地面层（草地/土地/泥地等基础地形）
-- 2. overlays   : 装饰层（树木/石头/篝火/栅栏/木桩等）
--    装饰物叠加在地面之上渲染，独立携带碰撞属性。
------------------------------------------------------------

local TileMap = {}

------------------------------------------------------------
-- 基本参数
------------------------------------------------------------
TileMap.TILE_SIZE = 2      -- 每个瓦片 2×2 米
TileMap.COLS     = 30      -- 列数 (60m / 2m)
TileMap.ROWS     = 30      -- 行数 (60m / 2m)

------------------------------------------------------------
-- 地面瓦片类型注册表
------------------------------------------------------------
TileMap.TileTypes = {
    G = {
        char = "G", name = "草地",
        color = {177, 212, 102, 255},
        walkable = true, speedMult = 1.0, vision = 1.0,
    },
    B = {
        char = "B", name = "灌木",
        color = { 55, 120,  40, 255},
        walkable = true, speedMult = 0.8, vision = 0.6,
    },
}

------------------------------------------------------------
-- 装饰物类型注册表
--
-- 字段：
--   id        : 唯一标识
--   name      : 可读名称
--   image     : 贴图路径
--   cols,rows : 占用网格大小（1×1 或 2×2）
--   walkable  : 是否可通行（false = 阻挡移动）
--   speedMult : 经过时速度倍率（仅 walkable=true 时有意义）
--   vision    : 视野遮蔽倍率
------------------------------------------------------------
TileMap.OverlayTypes = {
    campfire = {
        id = "campfire", name = "篝火",
        images = {"image/tiles/campfire1.png", "image/tiles/campfire2.png", "image/tiles/campfire3.png"},
        cols = 1, rows = 1,
        walkable = false, speedMult = 0.0, vision = 1.0,
        contentBounds = { left = 0.009, top = 0.008, right = 0.856, bottom = 0.992 },
    },
    stump = {
        id = "stump", name = "树桩",
        images = {"image/tiles/stump.png"},
        cols = 1, rows = 1,
        walkable = false, speedMult = 0.0, vision = 1.0,
        contentBounds = { left = 0.009, top = 0.152, right = 0.996, bottom = 0.941 },
    },
    tree_round = {
        id = "tree_round", name = "圆树",
        images = {"image/tiles/tree_round.png"},
        cols = 2, rows = 2,
        walkable = false, speedMult = 0.0, vision = 0.5,
        contentBounds = { left = 0.013, top = 0.109, right = 0.996, bottom = 0.941 },
    },
    pine = {
        id = "pine", name = "松树",
        images = {"image/tiles/pine1.png", "image/tiles/pine2.png"},
        cols = 2, rows = 2,
        walkable = false, speedMult = 0.0, vision = 0.5,
        contentBounds = { left = 0.013, top = 0.008, right = 0.996, bottom = 0.992 },
    },
    fence_tall = {
        id = "fence_tall", name = "高栅栏",
        images = {"image/tiles/fence_tall.png"},
        cols = 1, rows = 1,
        walkable = false, speedMult = 0.0, vision = 1.0,
        contentBounds = { left = 0.013, top = 0.223, right = 1.000, bottom = 0.941 },
    },
    fence_gate = {
        id = "fence_gate", name = "栅栏门",
        images = {"image/tiles/fence_gate.png"},
        cols = 1, rows = 1,
        walkable = false, speedMult = 0.0, vision = 1.0,
        contentBounds = { left = 0.013, top = 0.074, right = 1.000, bottom = 0.992 },
    },
    fence_open = {
        id = "fence_open", name = "开放栅栏",
        images = {"image/tiles/fence_open.png"},
        cols = 1, rows = 1,
        walkable = false, speedMult = 0.0, vision = 1.0,
        contentBounds = { left = 0.013, top = 0.008, right = 1.000, bottom = 0.863 },
    },
    rocks_big = {
        id = "rocks_big", name = "大石堆",
        images = {"image/tiles/rocks_big.png"},
        cols = 1, rows = 1,
        walkable = false, speedMult = 0.0, vision = 1.0,
        contentBounds = { left = 0.013, top = 0.203, right = 1.000, bottom = 0.941 },
    },
    rocks_small = {
        id = "rocks_small", name = "小石堆",
        images = {"image/tiles/rocks_small.png"},
        cols = 1, rows = 1,
        walkable = false, speedMult = 0.0, vision = 1.0,
        contentBounds = { left = 0.013, top = 0.137, right = 1.000, bottom = 0.992 },
    },
    rock_single = {
        id = "rock_single", name = "单块岩石",
        images = {"image/tiles/rock_single.png"},
        cols = 1, rows = 1,
        walkable = false, speedMult = 0.0, vision = 1.0,
        contentBounds = { left = 0.013, top = 0.008, right = 1.000, bottom = 0.758 },
    },
    logs_small = {
        id = "logs_small", name = "小木堆",
        images = {"image/tiles/logs_small.png"},
        cols = 1, rows = 1,
        walkable = false, speedMult = 0.0, vision = 1.0,
        contentBounds = { left = 0.009, top = 0.172, right = 0.996, bottom = 0.992 },
    },
    logs_big = {
        id = "logs_big", name = "大木堆",
        images = {"image/tiles/logs_big.png"},
        cols = 1, rows = 1,
        walkable = false, speedMult = 0.0, vision = 1.0,
        contentBounds = { left = 0.009, top = 0.008, right = 0.996, bottom = 0.777 },
    },
    -- ============ 青草（可通行，羊群食物来源）============
    grass_patch = {
        id = "grass_patch", name = "草丛",
        images = {"image/tiles/grass_patch1.png", "image/tiles/grass_patch2.png"},
        cols = 1, rows = 1,
        walkable = true, speedMult = 0.95, vision = 1.0,
        isFood = true, foodType = "grass", foodPriority = 1,
        contentBounds = { left = 0.05, top = 0.30, right = 0.95, bottom = 0.95 },
    },
    grass_strip = {
        id = "grass_strip", name = "草带",
        images = {"image/tiles/grass_strip.png"},
        cols = 2, rows = 1,
        walkable = true, speedMult = 0.95, vision = 1.0,
        isFood = true, foodType = "grass", foodPriority = 1,
        contentBounds = { left = 0.02, top = 0.25, right = 0.98, bottom = 0.90 },
    },
}

------------------------------------------------------------
-- 装饰物放置列表
--
-- 每项：{ type = "类型ID", col = 列, row = 行, imgIdx = 图片索引 }
-- col/row 为左上角网格坐标（1-based）
--
-- ★ 地图设计原则 ★
-- - 围栏在右上角（列 26~29, 行 2~5），附近留出通道
-- - 犬出生点：(8,50) (52,50) (8,8) (52,8)，附近不放障碍
-- - 羊随机生成在中部区域，保证可达性
-- - 障碍物形成自然分散的丛林/岩石区域
-- - 土路连接关键区域
------------------------------------------------------------
TileMap.overlays = {
    -- ============ v8 设计：圆树 (2×2, 共 6 棵) ============
    { type = "tree_round",  col = 1,  row = 1,  imgIdx = 1 },  -- 左上角
    { type = "tree_round",  col = 1,  row = 12, imgIdx = 2 },  -- 左侧中部
    { type = "tree_round",  col = 1,  row = 25, imgIdx = 1 },  -- 左下角
    { type = "tree_round",  col = 16, row = 1,  imgIdx = 2 },  -- 上方中部
    { type = "tree_round",  col = 29, row = 25, imgIdx = 1 },  -- 右下角
    { type = "tree_round",  col = 22, row = 20, imgIdx = 2 },  -- 右侧中下

    -- ============ v8 设计：松树 (2×2, 共 3 棵) ============
    { type = "pine",        col = 29, row = 1,  imgIdx = 1 },  -- 右上角
    { type = "pine",        col = 7,  row = 27, imgIdx = 2 },  -- 左下方
    { type = "pine",        col = 29, row = 29, imgIdx = 1 },  -- 右下角

    -- ============ v8 设计：大石堆 (1×1, 共 4 个) ============
    { type = "rocks_big",   col = 6,  row = 10 },  -- 左侧中部
    { type = "rocks_big",   col = 19, row = 8  },  -- 中部偏上
    { type = "rocks_big",   col = 21, row = 15 },  -- 中部偏下
    { type = "rocks_big",   col = 17, row = 22 },  -- 下方中部

    -- ============ v8 设计：草丛/草地（羊群食物来源，共 5 处）============
    { type = "grass_patch", col = 4,  row = 5,  imgIdx = 1 },  -- 左上
    { type = "grass_patch", col = 8,  row = 19, imgIdx = 2 },  -- 左中下
    { type = "grass_patch", col = 17, row = 17, imgIdx = 1 },  -- 中部
    { type = "grass_patch", col = 26, row = 10, imgIdx = 2 },  -- 右上
    { type = "grass_patch", col = 15, row = 27, imgIdx = 1 },  -- 下方

}

------------------------------------------------------------
-- 地图网格（地面层）—— v9 简化设计
--
-- 地形说明：
--   G = 草地 (全部统一为草地)
--
-- 羊圈：右上角 5×5 (由 Settings.Pen 控制栅栏渲染)
-- 装饰物：由 overlays 层控制（树木/石头/草丛等）
------------------------------------------------------------
TileMap.grid = {
    "GGGGGGGGGGGGGGGGGGGGGGGGGGGGGG",  -- 行 1
    "GGGGGGGGGGGGGGGGGGGGGGGGGGGGGG",  -- 行 2
    "GGGGGGGGGGGGGGGGGGGGGGGGGGGGGG",  -- 行 3
    "GGGGGGGGGGGGGGGGGGGGGGGGGGGGGG",  -- 行 4
    "GGGGGGGGGGGGGGGGGGGGGGGGGGGGGG",  -- 行 5
    "GGGGGGGGGGGGGGGGGGGGGGGGGGGGGG",  -- 行 6
    "GGGGGGGGGGGGGGGGGGGGGGGGGGGGGG",  -- 行 7
    "GGGGGGGGGGGGGGGGGGGGGGGGGGGGGG",  -- 行 8
    "GGGGGGGGGGGGGGGGGGGGGGGGGGGGGG",  -- 行 9
    "GGGGGGGGGGGGGGGGGGGGGGGGGGGGGG",  -- 行 10
    "GGGGGGGGGGGGGGGGGGGGGGGGGGGGGG",  -- 行 11
    "GGGGGGGGGGGGGGGGGGGGGGGGGGGGGG",  -- 行 12
    "GGGGGGGGGGGGGGGGGGGGGGGGGGGGGG",  -- 行 13
    "GGGGGGGGGGGGGGGGGGGGGGGGGGGGGG",  -- 行 14
    "GGGGGGGGGGGGGGGGGGGGGGGGGGGGGG",  -- 行 15
    "GGGGGGGGGGGGGGGGGGGGGGGGGGGGGG",  -- 行 16
    "GGGGGGGGGGGGGGGGGGGGGGGGGGGGGG",  -- 行 17
    "GGGGGGGGGGGGGGGGGGGGGGGGGGGGGG",  -- 行 18
    "GGGGGGGGGGGGGGGGGGGGGGGGGGGGGG",  -- 行 19
    "GGGGGGGGGGGGGGGGGGGGGGGGGGGGGG",  -- 行 20
    "GGGGGGGGGGGGGGGGGGGGGGGGGGGGGG",  -- 行 21
    "GGGGGGGGGGGGGGGGGGGGGGGGGGGGGG",  -- 行 22
    "GGGGGGGGGGGGGGGGGGGGGGGGGGGGGG",  -- 行 23
    "GGGGGGGGGGGGGGGGGGGGGGGGGGGGGG",  -- 行 24
    "GGGGGGGGGGGGGGGGGGGGGGGGGGGGGG",  -- 行 25
    "GGGGGGGGGGGGGGGGGGGGGGGGGGGGGG",  -- 行 26
    "GGGGGGGGGGGGGGGGGGGGGGGGGGGGGG",  -- 行 27
    "GGGGGGGGGGGGGGGGGGGGGGGGGGGGGG",  -- 行 28
    "GGGGGGGGGGGGGGGGGGGGGGGGGGGGGG",  -- 行 29
    "GGGGGGGGGGGGGGGGGGGGGGGGGGGGGG",  -- 行 30
}

------------------------------------------------------------
-- 预处理：构建装饰物碰撞查询网格
-- overlayGrid[row][col] = overlay entry (包含类型信息)
------------------------------------------------------------
TileMap.overlayGrid = {}

local function buildOverlayGrid()
    TileMap.overlayGrid = {}
    for row = 1, TileMap.ROWS do
        TileMap.overlayGrid[row] = {}
    end
    for _, ov in ipairs(TileMap.overlays) do
        local otype = TileMap.OverlayTypes[ov.type]
        if otype then
            local c = ov.col
            local r = ov.row
            local oCols = otype.cols or 1
            local oRows = otype.rows or 1
            for dr = 0, oRows - 1 do
                for dc = 0, oCols - 1 do
                    local gr = r + dr
                    local gc = c + dc
                    if gr >= 1 and gr <= TileMap.ROWS and gc >= 1 and gc <= TileMap.COLS then
                        TileMap.overlayGrid[gr][gc] = {
                            overlay = ov,
                            otype   = otype,
                            isAnchor = (dr == 0 and dc == 0),
                        }
                    end
                end
            end
        end
    end
end

buildOverlayGrid()

------------------------------------------------------------
-- 查询 API
------------------------------------------------------------

--- 世界坐标 → 网格坐标（行列，1-based）
function TileMap.WorldToGrid(wx, wz)
    local col = math.floor(wx / TileMap.TILE_SIZE) + 1
    local row = math.floor(wz / TileMap.TILE_SIZE) + 1
    col = math.max(1, math.min(TileMap.COLS, col))
    row = math.max(1, math.min(TileMap.ROWS, row))
    return col, row
end

--- 网格坐标 → 世界坐标（瓦片左上角）
function TileMap.GridToWorld(col, row)
    return (col - 1) * TileMap.TILE_SIZE, (row - 1) * TileMap.TILE_SIZE
end

--- 获取指定网格位置的地面瓦片类型字符
function TileMap.GetChar(col, row)
    if row < 1 or row > TileMap.ROWS then return "G" end
    local line = TileMap.grid[row]
    if col < 1 or col > TileMap.COLS then return "G" end
    return line:sub(col, col)
end

--- 获取指定世界坐标的地面瓦片类型数据
function TileMap.GetTileAt(wx, wz)
    local col, row = TileMap.WorldToGrid(wx, wz)
    local ch = TileMap.GetChar(col, row)
    return TileMap.TileTypes[ch] or TileMap.TileTypes["G"]
end

--- 获取装饰物的精确世界空间碰撞 AABB
--- 返回 x1, z1, x2, z2（基于 contentBounds）
function TileMap.GetOverlayAABB(ov)
    local otype = TileMap.OverlayTypes[ov.type]
    if not otype then return nil end
    local S = TileMap.TILE_SIZE
    local oCols = otype.cols or 1
    local oRows = otype.rows or 1
    local baseX = (ov.col - 1) * S
    local baseZ = (ov.row - 1) * S
    local totalW = oCols * S
    local totalH = oRows * S
    local cb = otype.contentBounds
    if cb then
        return baseX + totalW * cb.left,
               baseZ + totalH * cb.top,
               baseX + totalW * cb.right,
               baseZ + totalH * cb.bottom
    else
        return baseX, baseZ, baseX + totalW, baseZ + totalH
    end
end

--- 获取指定世界坐标的装饰物数据（nil 表示无装饰物）
--- 使用 contentBounds 做精确点检测
function TileMap.GetOverlayAt(wx, wz)
    -- 先通过网格快速筛选候选装饰物
    local col, row = TileMap.WorldToGrid(wx, wz)
    if not TileMap.overlayGrid[row] then return nil end
    local cell = TileMap.overlayGrid[row][col]
    if not cell then return nil end

    -- 找到该网格对应的装饰物，做精确边界检测
    local ov = cell.overlay
    local x1, z1, x2, z2 = TileMap.GetOverlayAABB(ov)
    if x1 and wx >= x1 and wx <= x2 and wz >= z1 and wz <= z2 then
        return cell
    end
    return nil
end

--- 综合判断是否可通行（地面 + 装饰物）
function TileMap.IsWalkable(wx, wz)
    local tile = TileMap.GetTileAt(wx, wz)
    if not tile.walkable then return false end
    local ov = TileMap.GetOverlayAt(wx, wz)
    if ov and not ov.otype.walkable then return false end
    return true
end

--- 获取速度倍率（取地面和装饰物中较低的）
function TileMap.GetSpeedMult(wx, wz)
    local tile = TileMap.GetTileAt(wx, wz)
    local mult = tile.speedMult
    local ov = TileMap.GetOverlayAt(wx, wz)
    if ov and ov.otype.speedMult < mult then
        mult = ov.otype.speedMult
    end
    return mult
end

--- 获取视觉感知倍率（取地面和装饰物中较低的）
function TileMap.GetVisionMult(wx, wz)
    local tile = TileMap.GetTileAt(wx, wz)
    local vis = tile.vision
    local ov = TileMap.GetOverlayAt(wx, wz)
    if ov and ov.otype.vision < vis then
        vis = ov.otype.vision
    end
    return vis
end

------------------------------------------------------------
-- 食物来源查询 API（供 SheepAI 使用）
------------------------------------------------------------

--- 获取所有食物来源位置（按优先级排序：grass=1, water=2, tree=3）
--- @return table[] 食物列表 { x, z, foodType, priority }
function TileMap.GetFoodSources()
    local foods = {}
    local S = TileMap.TILE_SIZE

    for _, ov in ipairs(TileMap.overlays) do
        local otype = TileMap.OverlayTypes[ov.type]
        if otype and otype.isFood then
            local oCols = otype.cols or 1
            local oRows = otype.rows or 1
            local cx = (ov.col - 1) * S + (oCols * S) / 2
            local cz = (ov.row - 1) * S + (oRows * S) / 2
            table.insert(foods, {
                x = cx,
                z = cz,
                foodType = otype.foodType,
                priority = otype.foodPriority,
                walkable = otype.walkable,
                radius = math.max(oCols, oRows) * S / 2,
            })
        end
    end

    -- 树木也是低优先级食物（树荫处休息）
    for _, ov in ipairs(TileMap.overlays) do
        local otype = TileMap.OverlayTypes[ov.type]
        if otype and (ov.type == "pine" or ov.type == "tree_round") then
            local oCols = otype.cols or 1
            local oRows = otype.rows or 1
            local cx = (ov.col - 1) * S + (oCols * S) / 2
            local cz = (ov.row - 1) * S + (oRows * S) / 2
            table.insert(foods, {
                x = cx,
                z = cz,
                foodType = "tree",
                priority = 3,
                walkable = false,
                radius = math.max(oCols, oRows) * S / 2,
            })
        end
    end

    -- 按优先级排序（数字越小越优先）
    table.sort(foods, function(a, b) return a.priority < b.priority end)

    return foods
end

------------------------------------------------------------
-- 动态建造 API
------------------------------------------------------------

--- 检查指定网格位置是否可以放置装饰物
--- @param typeId string 装饰物类型 ID
--- @param col number 左上角列（1-based）
--- @param row number 左上角行（1-based）
--- @return boolean canPlace
--- @return string? reason 失败原因
function TileMap.CanPlaceOverlay(typeId, col, row)
    local otype = TileMap.OverlayTypes[typeId]
    if not otype then return false, "unknown_type" end

    local oCols = otype.cols or 1
    local oRows = otype.rows or 1

    -- 边界检查
    if col < 1 or row < 1
        or col + oCols - 1 > TileMap.COLS
        or row + oRows - 1 > TileMap.ROWS then
        return false, "out_of_bounds"
    end

    -- 围栏区域排除
    local Settings = require("config.Settings")
    local P = Settings.Pen
    local S = TileMap.TILE_SIZE
    for dr = 0, oRows - 1 do
        for dc = 0, oCols - 1 do
            local gc = col + dc
            local gr = row + dr

            -- 格子已占用
            if TileMap.overlayGrid[gr] and TileMap.overlayGrid[gr][gc] then
                return false, "occupied"
            end

            -- 世界坐标中心
            local cwx = (gc - 1) * S + S * 0.5
            local cwz = (gr - 1) * S + S * 0.5

            -- 围栏区域（含门口缓冲）
            if cwx >= P.X - 1 and cwx <= P.X + P.Width + 1
               and cwz >= P.Y - 1 and cwz <= P.Y + P.Height + 1 then
                return false, "pen_area"
            end

            -- 出生点附近（6m 半径）
            for _, sp in ipairs(Settings.SpawnPoints) do
                local dx = cwx - sp.x
                local dz = cwz - sp.z
                if dx * dx + dz * dz < 36 then
                    return false, "spawn_area"
                end
            end

            -- 地面不可行走
            local tch = TileMap.GetChar(gc, gr)
            local tile = TileMap.TileTypes[tch]
            if tile and not tile.walkable then
                return false, "unwalkable_ground"
            end
        end
    end

    return true
end

--- 动态添加装饰物并更新碰撞网格
--- @param typeId string 装饰物类型 ID
--- @param col number 左上角列（1-based）
--- @param row number 左上角行（1-based）
--- @return table? overlay 新增的 overlay 条目，失败返回 nil
function TileMap.AddOverlay(typeId, col, row)
    local otype = TileMap.OverlayTypes[typeId]
    if not otype then return nil end

    -- 随机选取图片索引
    local imgIdx = 1
    if otype.images and #otype.images > 1 then
        imgIdx = math.random(1, #otype.images)
    end

    local ov = { type = typeId, col = col, row = row, imgIdx = imgIdx }
    table.insert(TileMap.overlays, ov)

    -- 更新 overlayGrid
    local oCols = otype.cols or 1
    local oRows = otype.rows or 1
    for dr = 0, oRows - 1 do
        for dc = 0, oCols - 1 do
            local gr = row + dr
            local gc = col + dc
            if gr >= 1 and gr <= TileMap.ROWS and gc >= 1 and gc <= TileMap.COLS then
                if not TileMap.overlayGrid[gr] then
                    TileMap.overlayGrid[gr] = {}
                end
                TileMap.overlayGrid[gr][gc] = {
                    overlay  = ov,
                    otype    = otype,
                    isAnchor = (dr == 0 and dc == 0),
                }
            end
        end
    end

    return ov
end

return TileMap
