------------------------------------------------------------
-- MapElements.lua  —— 地图元素查询（基于瓦片地图）
--
-- 保持原有 API 接口不变，内部全部委托给 TileMap 查询。
-- SheepAI / GameLogic / Server / Client 等调用方无需修改。
------------------------------------------------------------
local Settings = require("config.Settings")
local TileMap  = require("game.TileMap")

local MapElements = {}

------------------------------------------------------------
-- 兼容字段（旧代码可能引用，保留空表）
------------------------------------------------------------
MapElements.Rivers  = {}
MapElements.Bridges = {}
MapElements.Hills   = {}
MapElements.Forests = {}
MapElements.Rocks   = {}
MapElements.GrassPatches = {}

------------------------------------------------------------
-- 不可通行查询（统一走瓦片 walkable 判定）
------------------------------------------------------------

--- 是否在"河流"中（实际：瓦片是否为水）
function MapElements.IsInRiver(px, pz)
    local tile = TileMap.GetTileAt(px, pz)
    return tile.char == "W"
end

--- 是否在"石头"中（实际：瓦片是否为不可通行障碍）
function MapElements.IsInRock(px, pz)
    return not TileMap.IsWalkable(px, pz) and not MapElements.IsInRiver(px, pz)
end

------------------------------------------------------------
-- 推力（瓦片系统不需要精确推力，返回简化结果）
------------------------------------------------------------

function MapElements.GetRiverRepulsion(px, pz)
    if MapElements.IsInRiver(px, pz) then
        return -1, 0, 0  -- 在水里，触发回退
    end
    return math.huge, 0, 0
end

function MapElements.GetRockRepulsion(px, pz, margin)
    return 0, 0
end

------------------------------------------------------------
-- 区域查询
------------------------------------------------------------

function MapElements.IsOnHill(px, pz)
    local tile = TileMap.GetTileAt(px, pz)
    if tile.char == "H" then
        return true, tile
    end
    return false, nil
end

function MapElements.IsInForest(px, pz)
    local tile = TileMap.GetTileAt(px, pz)
    if tile.char == "F" or tile.char == "B" then
        return true, tile
    end
    -- 装饰层树木也算遮蔽区
    local ov = TileMap.GetOverlayAt(px, pz)
    if ov and ov.otype.vision < 1.0 then
        return true, ov.otype
    end
    return false, nil
end

------------------------------------------------------------
-- 障碍物 AABB 列表（扫描不可通行瓦片生成）
------------------------------------------------------------
function MapElements.CreateObstacleAABBs()
    local obstacles = {}
    local S = TileMap.TILE_SIZE

    -- 地面层不可通行瓦片
    for row = 1, TileMap.ROWS do
        for col = 1, TileMap.COLS do
            local tile = TileMap.TileTypes[TileMap.GetChar(col, row)]
            if tile and not tile.walkable then
                local wx, wz = TileMap.GridToWorld(col, row)
                table.insert(obstacles, { wx, wz, wx + S, wz + S })
            end
        end
    end

    -- 装饰层不可通行物体（使用 contentBounds 精确碰撞区域）
    for _, ov in ipairs(TileMap.overlays) do
        local otype = TileMap.OverlayTypes[ov.type]
        if otype and not otype.walkable then
            local x1, z1, x2, z2 = TileMap.GetOverlayAABB(ov)
            if x1 then
                table.insert(obstacles, { x1, z1, x2, z2 })
            end
        end
    end

    return obstacles
end

------------------------------------------------------------
-- 速度修正
------------------------------------------------------------
function MapElements.GetSpeedMultiplier(px, pz, isdog)
    local mult = TileMap.GetSpeedMult(px, pz)
    -- 犬在减速区受影响较小
    if isdog and mult < 1.0 then
        mult = mult + (1.0 - mult) * 0.3
    end
    return mult
end

------------------------------------------------------------
-- 感知修正
------------------------------------------------------------
function MapElements.GetPerceptionMultiplier(sheepX, sheepZ, dogX, dogZ)
    local alertMult = 1.0
    local presenceMult = 1.0

    local sheepVision = TileMap.GetVisionMult(sheepX, sheepZ)
    local dogVision   = TileMap.GetVisionMult(dogX, dogZ)

    if sheepVision < 1.0 then
        alertMult    = alertMult * sheepVision
        presenceMult = presenceMult * sheepVision
    end
    if dogVision < 1.0 then
        presenceMult = presenceMult * 0.7
    end

    return alertMult, presenceMult
end

------------------------------------------------------------
-- 生成合法的随机位置（避开不可通行瓦片和围栏）
------------------------------------------------------------
function MapElements.GetValidPosition(minX, maxX, minZ, maxZ)
    local P = Settings.Pen
    for _ = 1, 100 do
        local x = minX + math.random() * (maxX - minX)
        local z = minZ + math.random() * (maxZ - minZ)
        if TileMap.IsWalkable(x, z)
            and not (x >= P.X and x <= P.X + P.Width
                     and z >= P.Y and z <= P.Y + P.Height) then
            return x, z
        end
    end
    return (minX + maxX) / 2, (minZ + maxZ) / 2
end

return MapElements
