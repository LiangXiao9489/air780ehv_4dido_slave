-- 4DI 输入采集
-- DI_CH1~4: GPIO36/37/38/16

-- ============ 管脚定义 ============
local DI_CH1 = 36
local DI_CH2 = 37
local DI_CH3 = 38
local DI_CH4 = 16

-- ============ 初始化 ============

-- DI: 配置为输入模式
gpio.setup(DI_CH1, nil, gpio.PULLUP)
gpio.setup(DI_CH2, nil, gpio.PULLUP)
gpio.setup(DI_CH3, nil, gpio.PULLUP)
gpio.setup(DI_CH4, nil, gpio.PULLUP)

-- ============ 对外接口 ============

-- 读取指定通道 DI 状态
-- ch: 1~4
local function di_get(ch)
    if ch == 1 then return gpio.get(DI_CH1) end
    if ch == 2 then return gpio.get(DI_CH2) end
    if ch == 3 then return gpio.get(DI_CH3) end
    if ch == 4 then return gpio.get(DI_CH4) end
    return nil
end

-- ============ DI 采集任务 ============
local function di_scan_task()
    while true do
        local v1 = gpio.get(DI_CH1)
        local v2 = gpio.get(DI_CH2)
        local v3 = gpio.get(DI_CH3)
        local v4 = gpio.get(DI_CH4)
        log.info("DI", "CH1=" .. v1, "CH2=" .. v2, "CH3=" .. v3, "CH4=" .. v4)
        sys.wait(100)
    end
end

-- sys.taskInit(di_scan_task)

return {
    di_get = di_get,
}
