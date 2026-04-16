------------------------------------------------------------
-- MapRenderer.lua  —— 地图 NanoVG 渲染（瓦片地图版 + 装饰层）
--
-- 共享模块：Standalone 和 Client 都使用同一套绘制代码
-- 所有坐标均为世界坐标（米），需要在外部已经设置好
-- nvgTranslate/nvgScale 变换后调用
------------------------------------------------------------
local Settings = require("config.Settings")
local TileMap  = require("game.TileMap")

local MapRenderer = {}

------------------------------------------------------------
-- 图片纹理缓存
------------------------------------------------------------
local imageCache = {}

------------------------------------------------------------
-- 初始化（预加载所有瓦片贴图 + 装饰物贴图）
------------------------------------------------------------
function MapRenderer.Init(nvg)
    imageCache = {}

    -- 地面瓦片贴图
    for _, ttype in pairs(TileMap.TileTypes) do
        if ttype.image and ttype.image ~= "" then
            local handle = nvgCreateImage(nvg, ttype.image, 0)
            if handle and handle > 0 then
                imageCache[ttype.image] = handle
            end
        end
    end

    -- 装饰物贴图
    for _, otype in pairs(TileMap.OverlayTypes) do
        if otype.images then
            for _, img in ipairs(otype.images) do
                if not imageCache[img] then
                    local handle = nvgCreateImage(nvg, img, 0)
                    if handle and handle > 0 then
                        imageCache[img] = handle
                    end
                end
            end
        end
    end
end

------------------------------------------------------------
-- 绘制地面瓦片层
------------------------------------------------------------
function MapRenderer.DrawTiles(nvg, mapW, mapH, viewLeft, viewTop, viewRight, viewBottom)
    local S = TileMap.TILE_SIZE

    local colMin, colMax, rowMin, rowMax
    if viewLeft then
        colMin = math.max(1, math.floor(viewLeft / S) + 1 - 1)
        colMax = math.min(TileMap.COLS, math.floor(viewRight / S) + 1 + 1)
        rowMin = math.max(1, math.floor(viewTop / S) + 1 - 1)
        rowMax = math.min(TileMap.ROWS, math.floor(viewBottom / S) + 1 + 1)
    else
        colMin, colMax = 1, TileMap.COLS
        rowMin, rowMax = 1, TileMap.ROWS
    end

    local pad = 0.02  -- 微小重叠消除瓦片缝隙
    for row = rowMin, rowMax do
        local line = TileMap.grid[row]
        if line then
            for col = colMin, colMax do
                local ch = line:sub(col, col)
                local ttype = TileMap.TileTypes[ch] or TileMap.TileTypes["G"]
                local wx = (col - 1) * S - pad
                local wz = (row - 1) * S - pad
                local drawS = S + pad * 2

                local imgHandle = ttype.image and imageCache[ttype.image]
                if imgHandle and imgHandle > 0 then
                    local paint = nvgImagePattern(nvg, wx, wz, drawS, drawS, 0, imgHandle, 1.0)
                    nvgBeginPath(nvg)
                    nvgRect(nvg, wx, wz, drawS, drawS)
                    nvgFillPaint(nvg, paint)
                    nvgFill(nvg)
                else
                    local c = ttype.color
                    nvgBeginPath(nvg)
                    nvgRect(nvg, wx, wz, drawS, drawS)
                    nvgFillColor(nvg, nvgRGBA(c[1], c[2], c[3], c[4] or 255))
                    nvgFill(nvg)
                end
            end
        end
    end
end

------------------------------------------------------------
-- 绘制装饰物层（叠加在地面之上）
--
-- 只绘制 anchor 位置（左上角）的装饰物，
-- 2×2 的树木渲染覆盖 4 格的区域。
------------------------------------------------------------
function MapRenderer.DrawOverlays(nvg, mapW, mapH, viewLeft, viewTop, viewRight, viewBottom)
    local S = TileMap.TILE_SIZE
    -- 内缩裁剪：图案保持原始大小，绘制矩形向内收缩，
    -- 裁掉边缘抗锯齿像素，消除黑色边框
    local inset = 0.04

    for _, ov in ipairs(TileMap.overlays) do
        local otype = TileMap.OverlayTypes[ov.type]
        if not otype then goto continue end

        local oCols = otype.cols or 1
        local oRows = otype.rows or 1

        -- 装饰物世界坐标范围
        local wx = (ov.col - 1) * S
        local wz = (ov.row - 1) * S
        local drawW = oCols * S
        local drawH = oRows * S

        -- 视口剔除
        if viewLeft then
            if wx + drawW < viewLeft or wx > viewRight then goto continue end
            if wz + drawH < viewTop  or wz > viewBottom then goto continue end
        end

        -- 选择图片
        local imgPath = nil
        if otype.images and #otype.images > 0 then
            local idx = ov.imgIdx or 1
            idx = math.max(1, math.min(#otype.images, idx))
            imgPath = otype.images[idx]
        end

        local imgHandle = imgPath and imageCache[imgPath]
        if imgHandle and imgHandle > 0 then
            -- 图案覆盖原始完整区域
            local paint = nvgImagePattern(nvg, wx, wz, drawW, drawH, 0, imgHandle, 1.0)
            nvgBeginPath(nvg)
            -- 绘制矩形向内收缩，裁掉边缘
            nvgRect(nvg, wx + inset, wz + inset, drawW - inset * 2, drawH - inset * 2)
            nvgFillPaint(nvg, paint)
            nvgFill(nvg)
        end

        ::continue::
    end
end

------------------------------------------------------------
-- 绘制瓦片网格线（调试用，默认关闭）
------------------------------------------------------------
MapRenderer.showGrid = false

function MapRenderer.DrawGridLines(nvg, mapW, mapH, viewLeft, viewTop, viewRight, viewBottom)
    if not MapRenderer.showGrid then return end

    local S = TileMap.TILE_SIZE
    local colMin, colMax, rowMin, rowMax

    if viewLeft then
        colMin = math.max(0, math.floor(viewLeft / S))
        colMax = math.min(TileMap.COLS, math.floor(viewRight / S) + 1)
        rowMin = math.max(0, math.floor(viewTop / S))
        rowMax = math.min(TileMap.ROWS, math.floor(viewBottom / S) + 1)
    else
        colMin, colMax = 0, TileMap.COLS
        rowMin, rowMax = 0, TileMap.ROWS
    end

    nvgStrokeColor(nvg, nvgRGBA(0, 0, 0, 30))
    nvgStrokeWidth(nvg, 0.03)

    for col = colMin, colMax do
        local x = col * S
        nvgBeginPath(nvg)
        nvgMoveTo(nvg, x, rowMin * S)
        nvgLineTo(nvg, x, rowMax * S)
        nvgStroke(nvg)
    end
    for row = rowMin, rowMax do
        local z = row * S
        nvgBeginPath(nvg)
        nvgMoveTo(nvg, colMin * S, z)
        nvgLineTo(nvg, colMax * S, z)
        nvgStroke(nvg)
    end


end

------------------------------------------------------------
-- 绘制围栏
------------------------------------------------------------
function MapRenderer.DrawPen(nvg)
    local P = Settings.Pen
    local px1 = P.X
    local pz1 = P.Y
    local px2 = P.X + P.Width
    local pz2 = P.Y + P.Height
    local gateCenter = (pz1 + pz2) / 2
    local halfGate = P.GateWidth / 2

    -- 底色
    nvgBeginPath(nvg)
    nvgRect(nvg, px1, pz1, P.Width, P.Height)
    nvgFillColor(nvg, nvgRGBA(200, 180, 120, 80))
    nvgFill(nvg)

    -- 墙壁
    nvgStrokeColor(nvg, nvgRGBA(140, 100, 50, 255))
    nvgStrokeWidth(nvg, 0.2)

    -- 上
    nvgBeginPath(nvg)
    nvgMoveTo(nvg, px1, pz2)
    nvgLineTo(nvg, px2, pz2)
    nvgStroke(nvg)
    -- 右
    nvgBeginPath(nvg)
    nvgMoveTo(nvg, px2, pz1)
    nvgLineTo(nvg, px2, pz2)
    nvgStroke(nvg)
    -- 下
    nvgBeginPath(nvg)
    nvgMoveTo(nvg, px1, pz1)
    nvgLineTo(nvg, px2, pz1)
    nvgStroke(nvg)
    -- 左（有门）
    nvgBeginPath(nvg)
    nvgMoveTo(nvg, px1, pz1)
    nvgLineTo(nvg, px1, gateCenter - halfGate)
    nvgStroke(nvg)
    nvgBeginPath(nvg)
    nvgMoveTo(nvg, px1, gateCenter + halfGate)
    nvgLineTo(nvg, px1, pz2)
    nvgStroke(nvg)

    -- 门口标记
    nvgStrokeColor(nvg, nvgRGBA(180, 150, 80, 150))
    nvgStrokeWidth(nvg, 0.08)
    nvgBeginPath(nvg)
    nvgMoveTo(nvg, px1 - 0.3, gateCenter - halfGate)
    nvgLineTo(nvg, px1 - 0.3, gateCenter + halfGate)
    nvgStroke(nvg)

    -- 标签
    nvgFontSize(nvg, 1.0)
    nvgTextAlign(nvg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
    nvgFillColor(nvg, nvgRGBA(140, 100, 50, 200))
    nvgText(nvg, (px1 + px2) / 2, (pz1 + pz2) / 2, "Pen")
end

------------------------------------------------------------
-- 绘制地图边框
------------------------------------------------------------
function MapRenderer.DrawBorder(nvg, mapW, mapH)
    nvgBeginPath(nvg)
    nvgRect(nvg, 0, 0, mapW, mapH)
    nvgStrokeColor(nvg, nvgRGBA(120, 90, 60, 255))
    nvgStrokeWidth(nvg, 0.3)
    nvgStroke(nvg)
end

------------------------------------------------------------
-- 一键绘制所有地图元素
------------------------------------------------------------
function MapRenderer.DrawAll(nvg, mapW, mapH, gameClock, viewLeft, viewTop, viewRight, viewBottom)
    MapRenderer.DrawTiles(nvg, mapW, mapH, viewLeft, viewTop, viewRight, viewBottom)
    MapRenderer.DrawOverlays(nvg, mapW, mapH, viewLeft, viewTop, viewRight, viewBottom)
    MapRenderer.DrawGridLines(nvg, mapW, mapH, viewLeft, viewTop, viewRight, viewBottom)
    MapRenderer.DrawPen(nvg)
    MapRenderer.DrawBorder(nvg, mapW, mapH)
end

return MapRenderer
