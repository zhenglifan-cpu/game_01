------------------------------------------------------------
-- main.lua  —— 牧羊游戏入口文件
--
-- 使用引擎内置 IsServerMode() / IsNetworkMode() 判断运行模式
-- 自动选择: 服务端 / 客户端 / 单机
------------------------------------------------------------

local Module = nil

function Start()
    if IsServerMode() then
        print("[Main] Starting in SERVER mode")
        Module = require("network.Server")
    elseif IsNetworkMode() then
        print("[Main] Starting in CLIENT mode")
        Module = require("network.Client")
    else
        print("[Main] Starting in STANDALONE mode")
        Module = require("network.Standalone")
    end
    Module.Start()
end

function Stop()
    if Module and Module.Stop then
        Module.Stop()
    end
end
