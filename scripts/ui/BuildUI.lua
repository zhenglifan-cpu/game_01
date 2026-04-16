------------------------------------------------------------
-- BuildUI.lua  —— 建造系统 UI 模块
--
-- 职责：
--   1. 建造模式切换（B 键 / 屏幕按钮）
--   2. 物品选择面板绘制
--   3. 放置预览（绿色/红色半透明网格）
--   4. 屏幕坐标 → 网格坐标 转换
------------------------------------------------------------
local Settings = require("config.Settings")
local TileMap  = require("game.TileMap")

local BuildUI = {}

------------------------------------------------------------
-- 状态
------------------------------------------------------------
local active_        = false   -- 建造模式是否开启
local selectedIdx_   = 1       -- 当前选中物品索引（Settings.Build.Items 的 index）
local previewCol_    = -1      -- 预览放置位置
local previewRow_    = -1
local canPlace_      = false
local items_         = Settings.Build.Items

-- 布局缓存
local panelH_        = 70
local itemSize_      = 50
local itemGap_       = 10
local btnR_          = 22      -- 建造按钮半径

------------------------------------------------------------
-- 公共 API
------------------------------------------------------------

function BuildUI.IsActive()
    return active_
end

function BuildUI.Toggle()
    active_ = not active_
    if not active_ then
        previewCol_ = -1
        previewRow_ = -1
    end
end

function BuildUI.SetActive(v)
    active_ = v
    if not active_ then
        previewCol_ = -1
        previewRow_ = -1
    end
end

function BuildUI.GetSelectedItem()
    if not active_ then return nil end
    return items_[selectedIdx_]
end

function BuildUI.GetPreview()
    if not active_ or previewCol_ < 1 then return nil end
    return previewCol_, previewRow_, canPlace_
end

------------------------------------------------------------
-- 屏幕坐标 → 世界坐标 → 网格坐标
-- 参数来自渲染循环的相机数据
------------------------------------------------------------
function BuildUI.UpdatePreview(screenX, screenY, scale, worldLeft, worldTop, dpr)
    if not active_ then return end
    -- 屏幕像素 → 逻辑坐标
    local lx = screenX / dpr
    local ly = screenY / dpr
    -- 逻辑坐标 → 世界坐标
    local wx = worldLeft + lx / scale
    local wz = worldTop  + ly / scale
    -- 世界坐标 → 网格
    local col, row = TileMap.WorldToGrid(wx, wz)

    -- 2×2 物体居中 snap
    local item = items_[selectedIdx_]
    if item and item.cols == 2 then
        -- 让鼠标位于 2×2 区域中央
        local cx = wx / TileMap.TILE_SIZE
        local cz = wz / TileMap.TILE_SIZE
        col = math.floor(cx)      -- 0-based
        row = math.floor(cz)
        -- 转回 1-based 并确保不超范围
        col = math.max(1, math.min(TileMap.COLS - 1, col + 1))
        row = math.max(1, math.min(TileMap.ROWS - 1, row + 1))
    end

    previewCol_ = col
    previewRow_ = row
    canPlace_ = TileMap.CanPlaceOverlay(item.id, col, row)
end

------------------------------------------------------------
-- 触摸/点击处理（返回是否被 UI 消费）
------------------------------------------------------------

--- 检测建造按钮点击
--- @param lx number 逻辑坐标 x
--- @param ly number 逻辑坐标 y
--- @param logW number 屏幕逻辑宽
--- @param logH number 屏幕逻辑高
--- @return boolean consumed
function BuildUI.HandleTouchDown(lx, ly, logW, logH)
    -- 建造模式按钮（右上区域，吠叫按钮上方）
    local btnX = logW - 50
    local btnY = logH - 170
    local dx = lx - btnX
    local dy = ly - btnY
    if dx * dx + dy * dy <= (btnR_ + 8) * (btnR_ + 8) then
        BuildUI.Toggle()
        return true
    end

    -- 如果建造模式开启，检测底部面板
    if active_ then
        local panelTop = logH - panelH_
        if ly >= panelTop then
            -- 点击了面板区域，选择物品
            local totalW = #items_ * (itemSize_ + itemGap_) - itemGap_
            local startX = (logW - totalW) / 2
            for i, _ in ipairs(items_) do
                local ix = startX + (i - 1) * (itemSize_ + itemGap_)
                if lx >= ix and lx <= ix + itemSize_ then
                    selectedIdx_ = i
                    return true
                end
            end
            return true -- 消费面板区域点击
        end
    end

    return false
end

------------------------------------------------------------
-- NanoVG 绘制
------------------------------------------------------------

--- 绘制建造 UI（屏幕空间，在 HUD 层）
function BuildUI.DrawHUD(nvg, logW, logH, wool, gameWon)
    -- 建造按钮（仅游戏结束后显示）
    if not gameWon then return end

    local btnX = logW - 50
    local btnY = logH - 170

    -- 按钮背景
    nvgBeginPath(nvg)
    nvgCircle(nvg, btnX, btnY, btnR_)
    if active_ then
        nvgFillColor(nvg, nvgRGBA(80, 200, 80, 200))
    else
        nvgFillColor(nvg, nvgRGBA(180, 140, 60, 160))
    end
    nvgFill(nvg)
    nvgStrokeColor(nvg, nvgRGBA(255, 255, 255, 180))
    nvgStrokeWidth(nvg, 1.5)
    nvgStroke(nvg)

    -- 按钮图标（锤子形状简化为文字）
    nvgFontFace(nvg, "sans")
    nvgFontSize(nvg, 16)
    nvgTextAlign(nvg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
    nvgFillColor(nvg, nvgRGBA(255, 255, 255, 240))
    nvgText(nvg, btnX, btnY, "Build")

    -- 建造面板
    if not active_ then return end

    -- 半透明底部面板
    local panelTop = logH - panelH_
    nvgBeginPath(nvg)
    nvgRect(nvg, 0, panelTop, logW, panelH_)
    nvgFillColor(nvg, nvgRGBA(0, 0, 0, 140))
    nvgFill(nvg)

    -- 绘制物品卡片
    local totalW = #items_ * (itemSize_ + itemGap_) - itemGap_
    local startX = (logW - totalW) / 2
    local cardY = panelTop + (panelH_ - itemSize_) / 2

    for i, item in ipairs(items_) do
        local ix = startX + (i - 1) * (itemSize_ + itemGap_)
        local isSelected = (i == selectedIdx_)
        local canAfford = (wool >= item.cost)

        -- 卡片背景
        nvgBeginPath(nvg)
        nvgRoundedRect(nvg, ix, cardY, itemSize_, itemSize_, 6)
        if isSelected then
            nvgFillColor(nvg, nvgRGBA(80, 180, 80, 200))
        elseif canAfford then
            nvgFillColor(nvg, nvgRGBA(60, 60, 60, 200))
        else
            nvgFillColor(nvg, nvgRGBA(80, 30, 30, 200))
        end
        nvgFill(nvg)

        if isSelected then
            nvgStrokeColor(nvg, nvgRGBA(120, 255, 120, 255))
            nvgStrokeWidth(nvg, 2)
            nvgStroke(nvg)
        end

        -- 物品名称
        nvgFontSize(nvg, 13)
        nvgTextAlign(nvg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        nvgFillColor(nvg, nvgRGBA(255, 255, 255, canAfford and 255 or 120))
        nvgText(nvg, ix + itemSize_ / 2, cardY + itemSize_ / 2 - 8, item.name)

        -- 费用
        nvgFontSize(nvg, 11)
        nvgFillColor(nvg, nvgRGBA(255, 220, 100, canAfford and 255 or 100))
        nvgText(nvg, ix + itemSize_ / 2, cardY + itemSize_ / 2 + 12, item.cost .. " wool")
    end

    -- 羊毛显示
    nvgFontSize(nvg, 14)
    nvgTextAlign(nvg, NVG_ALIGN_CENTER + NVG_ALIGN_TOP)
    nvgFillColor(nvg, nvgRGBA(255, 230, 130, 255))
    nvgText(nvg, logW / 2, panelTop - 20, "Wool: " .. wool)
end

--- 绘制放置预览（世界空间，在 nvgSave/Restore 变换内调用）
function BuildUI.DrawPreview(nvg)
    if not active_ or previewCol_ < 1 then return end

    local item = items_[selectedIdx_]
    if not item then return end

    local S = TileMap.TILE_SIZE
    local cols = item.cols or 1
    local rows = item.rows or 1
    local wx = (previewCol_ - 1) * S
    local wz = (previewRow_ - 1) * S

    nvgBeginPath(nvg)
    nvgRect(nvg, wx, wz, cols * S, rows * S)

    if canPlace_ then
        nvgFillColor(nvg, nvgRGBA(80, 220, 80, 80))
        nvgStrokeColor(nvg, nvgRGBA(80, 255, 80, 200))
    else
        nvgFillColor(nvg, nvgRGBA(220, 60, 60, 80))
        nvgStrokeColor(nvg, nvgRGBA(255, 60, 60, 200))
    end
    nvgFill(nvg)
    nvgStrokeWidth(nvg, 0.1)
    nvgStroke(nvg)
end

return BuildUI
