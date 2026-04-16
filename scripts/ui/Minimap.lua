------------------------------------------------------------
-- Minimap.lua  —— 圆形小地图
--
-- 绘制圆形小地图，显示：
--   - 地面瓦片（简化色块）
--   - 装饰物障碍（简化图标）
--   - 围栏区域
--   - 羊群位置
--   - 队友/自己的位置
--   - 超出范围的实体方位指示器
------------------------------------------------------------
local Settings = require("config.Settings")
local TileMap  = require("game.TileMap")

local Minimap = {}

------------------------------------------------------------
-- 配置
------------------------------------------------------------
local RADIUS       = 70    -- 小地图屏幕半径（像素）
local MARGIN       = 12    -- 距离屏幕边缘间距
local TOP_OFFSET   = 42    -- 顶部 HUD 栏下方偏移
local WORLD_RANGE  = 22    -- 小地图可见的世界范围半径（米）

-- 实体绘制尺寸
local DOT_SHEEP    = 2.5   -- 羊点半径（像素）
local DOT_DOG      = 3.5   -- 犬点半径（像素）
local DOT_PLAYER   = 4.0   -- 自己点半径（像素）
local ARROW_SIZE   = 5     -- 方位指示器大小（像素）

-- 障碍物颜色
local COLOR_TREE   = {34, 85, 25, 200}
local COLOR_ROCK   = {120, 115, 100, 200}
local COLOR_FENCE  = {140, 100, 50, 200}
local COLOR_FIRE   = {200, 100, 30, 200}
local COLOR_LOGS   = {110, 80, 45, 200}
local COLOR_PATH   = {180, 160, 110, 180}
local COLOR_PEN    = {200, 180, 100, 200}
local COLOR_SHEEP  = {255, 255, 255, 255}
local COLOR_SHEEP_PENNED = {255, 255, 255, 120}
local COLOR_BORDER = {255, 255, 255, 80}
local COLOR_BG     = {20, 30, 15, 180}

-- 装饰物 → 颜色映射
local OVERLAY_COLORS = {
    pine        = COLOR_TREE,
    tree_round  = COLOR_TREE,
    stump       = COLOR_LOGS,
    rocks_big   = COLOR_ROCK,
    rocks_small = COLOR_ROCK,
    rock_single = COLOR_ROCK,
    fence_tall  = COLOR_FENCE,
    fence_gate  = COLOR_FENCE,
    fence_open  = COLOR_FENCE,
    campfire    = COLOR_FIRE,
    logs_small  = COLOR_LOGS,
    logs_big    = COLOR_LOGS,
    path_right  = COLOR_PATH,
    path_mid    = COLOR_PATH,
    path_left   = COLOR_PATH,
}

------------------------------------------------------------
-- 内部：世界坐标 → 小地图局部坐标（相对于圆心）
-- 返回 lx, ly（像素偏移）以及 dist（到中心的像素距离）
------------------------------------------------------------
local function worldToMinimap(wx, wz, centerX, centerZ)
    local dx = wx - centerX
    local dz = wz - centerZ
    local scale = RADIUS / WORLD_RANGE
    local lx = dx * scale
    local ly = dz * scale
    local dist = math.sqrt(lx * lx + ly * ly)
    return lx, ly, dist
end

------------------------------------------------------------
-- 绘制小地图
--
-- nvg       : NanoVG context
-- params    : {
--   screenW, screenH  : 逻辑屏幕尺寸
--   playerX, playerZ  : 玩家世界坐标（小地图中心）
--   mapW, mapH        : 地图总尺寸
--   dogs              : { {x, z, color={r,g,b}, isMe=bool}, ... }
--   sheep             : { {x, z, penned=bool}, ... }
-- }
------------------------------------------------------------
function Minimap.Draw(nvg, params)
    local screenW = params.screenW
    local screenH = params.screenH
    local playerX = params.playerX
    local playerZ = params.playerZ
    local mapW    = params.mapW or 60
    local mapH    = params.mapH or 60
    local dogs    = params.dogs or {}
    local sheep   = params.sheep or {}
    local wolves  = params.wolves or {}

    -- 小地图圆心（右上角）
    local cx = screenW - MARGIN - RADIUS
    local cy = TOP_OFFSET + MARGIN + RADIUS

    local scale = RADIUS / WORLD_RANGE

    nvgSave(nvg)

    ----------------------------------------------------------------
    -- 1. 背景圆 + 裁剪
    ----------------------------------------------------------------
    nvgBeginPath(nvg)
    nvgCircle(nvg, cx, cy, RADIUS)
    nvgFillColor(nvg, nvgRGBA(COLOR_BG[1], COLOR_BG[2], COLOR_BG[3], COLOR_BG[4]))
    nvgFill(nvg)

    -- NanoVG 没有圆形 clip，用 scissor 做矩形裁剪（后面用遮罩修圆）
    nvgScissor(nvg, cx - RADIUS, cy - RADIUS, RADIUS * 2, RADIUS * 2)

    ----------------------------------------------------------------
    -- 2. 绘制地面瓦片（简化色块）
    ----------------------------------------------------------------
    local S = TileMap.TILE_SIZE
    -- 计算可见瓦片范围
    local viewLeft   = playerX - WORLD_RANGE
    local viewTop    = playerZ - WORLD_RANGE
    local viewRight  = playerX + WORLD_RANGE
    local viewBottom = playerZ + WORLD_RANGE

    local colMin = math.max(1, math.floor(viewLeft / S) + 1)
    local colMax = math.min(TileMap.COLS, math.floor(viewRight / S) + 1)
    local rowMin = math.max(1, math.floor(viewTop / S) + 1)
    local rowMax = math.min(TileMap.ROWS, math.floor(viewBottom / S) + 1)

    for row = rowMin, rowMax do
        local line = TileMap.grid[row]
        if line then
            for col = colMin, colMax do
                local ch = line:sub(col, col)
                local ttype = TileMap.TileTypes[ch] or TileMap.TileTypes["G"]
                local wx = (col - 1) * S + S / 2
                local wz = (row - 1) * S + S / 2
                local lx, ly, dist = worldToMinimap(wx, wz, playerX, playerZ)
                if dist < RADIUS + S * scale then
                    local c = ttype.color
                    local tilePixel = S * scale
                    nvgBeginPath(nvg)
                    nvgRect(nvg, cx + lx - tilePixel / 2, cy + ly - tilePixel / 2, tilePixel, tilePixel)
                    nvgFillColor(nvg, nvgRGBA(c[1], c[2], c[3], 200))
                    nvgFill(nvg)
                end
            end
        end
    end

    ----------------------------------------------------------------
    -- 3. 绘制装饰物障碍（简化色块）
    ----------------------------------------------------------------
    for _, ov in ipairs(TileMap.overlays) do
        local otype = TileMap.OverlayTypes[ov.type]
        if not otype then goto cont_ov end

        local oCols = otype.cols or 1
        local oRows = otype.rows or 1
        -- 装饰物中心世界坐标
        local owx = (ov.col - 1) * S + oCols * S / 2
        local owz = (ov.row - 1) * S + oRows * S / 2
        local lx, ly, dist = worldToMinimap(owx, owz, playerX, playerZ)
        if dist < RADIUS + oCols * S * scale then
            local c = OVERLAY_COLORS[ov.type] or COLOR_ROCK
            local pw = oCols * S * scale
            local ph = oRows * S * scale
            nvgBeginPath(nvg)
            nvgRect(nvg, cx + lx - pw / 2, cy + ly - ph / 2, pw, ph)
            nvgFillColor(nvg, nvgRGBA(c[1], c[2], c[3], c[4] or 200))
            nvgFill(nvg)
        end

        ::cont_ov::
    end

    ----------------------------------------------------------------
    -- 4. 绘制围栏
    ----------------------------------------------------------------
    local P = Settings.Pen
    local penCX = P.X + P.Width / 2
    local penCZ = P.Y + P.Height / 2
    local plx, ply, pdist = worldToMinimap(penCX, penCZ, playerX, playerZ)
    if pdist < RADIUS + P.Width * scale then
        local pw = P.Width * scale
        local ph = P.Height * scale
        nvgBeginPath(nvg)
        nvgRect(nvg, cx + plx - pw / 2, cy + ply - ph / 2, pw, ph)
        nvgStrokeColor(nvg, nvgRGBA(COLOR_PEN[1], COLOR_PEN[2], COLOR_PEN[3], COLOR_PEN[4]))
        nvgStrokeWidth(nvg, 1.5)
        nvgStroke(nvg)
        -- 半透明填充
        nvgBeginPath(nvg)
        nvgRect(nvg, cx + plx - pw / 2, cy + ply - ph / 2, pw, ph)
        nvgFillColor(nvg, nvgRGBA(COLOR_PEN[1], COLOR_PEN[2], COLOR_PEN[3], 60))
        nvgFill(nvg)
    end

    ----------------------------------------------------------------
    -- 5. 绘制羊（白点）
    ----------------------------------------------------------------
    local offscreenSheep = {}  -- 超出范围的羊
    for _, s in ipairs(sheep) do
        local lx, ly, dist = worldToMinimap(s.x, s.z, playerX, playerZ)
        if dist <= RADIUS - DOT_SHEEP then
            local c = s.penned and COLOR_SHEEP_PENNED or COLOR_SHEEP
            nvgBeginPath(nvg)
            nvgCircle(nvg, cx + lx, cy + ly, DOT_SHEEP)
            nvgFillColor(nvg, nvgRGBA(c[1], c[2], c[3], c[4]))
            nvgFill(nvg)
        else
            table.insert(offscreenSheep, {x = s.x, z = s.z})
        end
    end

    ----------------------------------------------------------------
    -- 5b. 绘制狼（红色雷达脉冲信号）
    ----------------------------------------------------------------
    local radarTime = (params.elapsed or 0)
    local offscreenWolves = {}
    for _, w in ipairs(wolves) do
        if w.state == "despawned" then goto cont_wolf end
        local lx, ly, wdist = worldToMinimap(w.x, w.z, playerX, playerZ)
        if wdist <= RADIUS - 3 then
            local wx_ = cx + lx
            local wy_ = cy + ly

            -- 中心实心点
            local coreR = 2.5
            nvgBeginPath(nvg)
            nvgCircle(nvg, wx_, wy_, coreR)
            nvgFillColor(nvg, nvgRGBA(255, 50, 50, 240))
            nvgFill(nvg)

            -- 雷达脉冲波纹（两层同心扩散环，错开相位）
            local PULSE_PERIOD = 1.5  -- 脉冲周期（秒）
            local MAX_RING_R   = 10   -- 最大扩散半径（像素）
            local RING_COUNT   = 2
            for ring = 0, RING_COUNT - 1 do
                local phase = (radarTime / PULSE_PERIOD + ring / RING_COUNT) % 1.0
                local ringR = coreR + phase * (MAX_RING_R - coreR)
                local alpha = math.floor(200 * (1.0 - phase))
                if alpha > 5 then
                    nvgBeginPath(nvg)
                    nvgCircle(nvg, wx_, wy_, ringR)
                    nvgStrokeColor(nvg, nvgRGBA(255, 60, 60, alpha))
                    nvgStrokeWidth(nvg, 1.2)
                    nvgStroke(nvg)
                end
            end

            -- 拖拽状态额外闪烁高亮
            if w.state == "dragging" then
                local blink = math.abs(math.sin(radarTime * 4.0))
                local ba = math.floor(120 * blink)
                nvgBeginPath(nvg)
                nvgCircle(nvg, wx_, wy_, coreR + 1.5)
                nvgFillColor(nvg, nvgRGBA(255, 80, 80, ba))
                nvgFill(nvg)
            end
        else
            table.insert(offscreenWolves, {x = w.x, z = w.z})
        end
        ::cont_wolf::
    end

    ----------------------------------------------------------------
    -- 6. 绘制犬（队友 + 自己）
    ----------------------------------------------------------------
    local offscreenDogs = {}  -- 超出范围的队友
    for _, d in ipairs(dogs) do
        local lx, ly, dist = worldToMinimap(d.x, d.z, playerX, playerZ)
        if dist <= RADIUS - DOT_DOG then
            local r = d.isMe and DOT_PLAYER or DOT_DOG
            local cr = math.floor((d.color[1] or 0.5) * 255)
            local cg = math.floor((d.color[2] or 0.5) * 255)
            local cb = math.floor((d.color[3] or 0.5) * 255)

            if d.isMe then
                -- 自己：实心圆 + 外圈
                nvgBeginPath(nvg)
                nvgCircle(nvg, cx + lx, cy + ly, r)
                nvgFillColor(nvg, nvgRGBA(cr, cg, cb, 255))
                nvgFill(nvg)
                nvgBeginPath(nvg)
                nvgCircle(nvg, cx + lx, cy + ly, r + 2)
                nvgStrokeColor(nvg, nvgRGBA(255, 255, 255, 200))
                nvgStrokeWidth(nvg, 1.5)
                nvgStroke(nvg)
            else
                nvgBeginPath(nvg)
                nvgCircle(nvg, cx + lx, cy + ly, r)
                nvgFillColor(nvg, nvgRGBA(cr, cg, cb, 255))
                nvgFill(nvg)
            end
        elseif not d.isMe then
            table.insert(offscreenDogs, {x = d.x, z = d.z, color = d.color})
        end
    end

    -- 取消 scissor
    nvgResetScissor(nvg)

    ----------------------------------------------------------------
    -- 7. 圆形遮罩（盖住 scissor 矩形溢出的部分）
    ----------------------------------------------------------------
    nvgBeginPath(nvg)
    nvgRect(nvg, cx - RADIUS - 2, cy - RADIUS - 2, RADIUS * 2 + 4, RADIUS * 2 + 4)
    nvgPathWinding(nvg, NVG_CW)
    nvgCircle(nvg, cx, cy, RADIUS)
    nvgPathWinding(nvg, NVG_CCW)
    nvgFillColor(nvg, nvgRGBA(34, 45, 30, 255))
    nvgFill(nvg)

    ----------------------------------------------------------------
    -- 8. 边框环
    ----------------------------------------------------------------
    nvgBeginPath(nvg)
    nvgCircle(nvg, cx, cy, RADIUS)
    nvgStrokeColor(nvg, nvgRGBA(COLOR_BORDER[1], COLOR_BORDER[2], COLOR_BORDER[3], COLOR_BORDER[4]))
    nvgStrokeWidth(nvg, 2)
    nvgStroke(nvg)

    ----------------------------------------------------------------
    -- 9. 方位指示器：超出范围的羊
    ----------------------------------------------------------------
    if #offscreenSheep > 0 then
        -- 聚合附近的羊为一组（按角度扇区分组，避免过多箭头）
        local sectors = {}
        local SECTOR_COUNT = 12
        for _, s in ipairs(offscreenSheep) do
            local dx = s.x - playerX
            local dz = s.z - playerZ
            local angle = math.atan(dz, dx)
            local sector = math.floor((angle + math.pi) / (2 * math.pi) * SECTOR_COUNT) + 1
            sector = math.max(1, math.min(SECTOR_COUNT, sector))
            if not sectors[sector] then
                sectors[sector] = {count = 0, angle = angle}
            end
            sectors[sector].count = sectors[sector].count + 1
            sectors[sector].angle = angle  -- 用最后一个的角度
        end

        for _, sec in pairs(sectors) do
            local angle = sec.angle
            local edgeX = cx + math.cos(angle) * (RADIUS - ARROW_SIZE)
            local edgeY = cy + math.sin(angle) * (RADIUS - ARROW_SIZE)

            -- 三角形箭头
            local ax = math.cos(angle)
            local ay = math.sin(angle)
            -- 垂直方向
            local px = -ay
            local py = ax

            nvgBeginPath(nvg)
            nvgMoveTo(nvg, edgeX + ax * ARROW_SIZE, edgeY + ay * ARROW_SIZE)
            nvgLineTo(nvg, edgeX - ax * 2 + px * ARROW_SIZE * 0.6, edgeY - ay * 2 + py * ARROW_SIZE * 0.6)
            nvgLineTo(nvg, edgeX - ax * 2 - px * ARROW_SIZE * 0.6, edgeY - ay * 2 - py * ARROW_SIZE * 0.6)
            nvgClosePath(nvg)
            nvgFillColor(nvg, nvgRGBA(255, 255, 255, 180))
            nvgFill(nvg)

            -- 数量标注
            if sec.count > 1 then
                nvgFontSize(nvg, 9)
                nvgTextAlign(nvg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
                nvgFillColor(nvg, nvgRGBA(255, 255, 200, 220))
                nvgText(nvg, edgeX - ax * 8, edgeY - ay * 8, tostring(sec.count))
            end
        end
    end

    ----------------------------------------------------------------
    -- 10. 方位指示器：超出范围的队友
    ----------------------------------------------------------------
    for _, d in ipairs(offscreenDogs) do
        local dx = d.x - playerX
        local dz = d.z - playerZ
        local angle = math.atan(dz, dx)
        local edgeX = cx + math.cos(angle) * (RADIUS - ARROW_SIZE)
        local edgeY = cy + math.sin(angle) * (RADIUS - ARROW_SIZE)

        local cr = math.floor((d.color[1] or 0.5) * 255)
        local cg = math.floor((d.color[2] or 0.5) * 255)
        local cb = math.floor((d.color[3] or 0.5) * 255)

        -- 菱形标记
        local s = ARROW_SIZE
        local ax = math.cos(angle)
        local ay = math.sin(angle)
        local px = -ay
        local py = ax

        nvgBeginPath(nvg)
        nvgMoveTo(nvg, edgeX + ax * s, edgeY + ay * s)
        nvgLineTo(nvg, edgeX + px * s * 0.5, edgeY + py * s * 0.5)
        nvgLineTo(nvg, edgeX - ax * s * 0.5, edgeY - ay * s * 0.5)
        nvgLineTo(nvg, edgeX - px * s * 0.5, edgeY - py * s * 0.5)
        nvgClosePath(nvg)
        nvgFillColor(nvg, nvgRGBA(cr, cg, cb, 230))
        nvgFill(nvg)
        nvgStrokeColor(nvg, nvgRGBA(255, 255, 255, 180))
        nvgStrokeWidth(nvg, 1)
        nvgStroke(nvg)
    end

    ----------------------------------------------------------------
    -- 11. 方位指示器：超出范围的狼（红色雷达脉冲箭头）
    ----------------------------------------------------------------
    for _, w in ipairs(offscreenWolves) do
        local dx = w.x - playerX
        local dz = w.z - playerZ
        local angle = math.atan(dz, dx)
        local edgeX = cx + math.cos(angle) * (RADIUS - ARROW_SIZE)
        local edgeY = cy + math.sin(angle) * (RADIUS - ARROW_SIZE)

        -- 红色三角箭头
        local s = ARROW_SIZE
        local ax = math.cos(angle)
        local ay = math.sin(angle)
        local px = -ay
        local py = ax

        -- 脉冲透明度
        local pulse = 0.6 + 0.4 * math.abs(math.sin(radarTime * 3.0))
        local alpha = math.floor(230 * pulse)

        nvgBeginPath(nvg)
        nvgMoveTo(nvg, edgeX + ax * s, edgeY + ay * s)
        nvgLineTo(nvg, edgeX - ax * 2 + px * s * 0.6, edgeY - ay * 2 + py * s * 0.6)
        nvgLineTo(nvg, edgeX - ax * 2 - px * s * 0.6, edgeY - ay * 2 - py * s * 0.6)
        nvgClosePath(nvg)
        nvgFillColor(nvg, nvgRGBA(255, 50, 50, alpha))
        nvgFill(nvg)
    end

    nvgRestore(nvg)
end

return Minimap
