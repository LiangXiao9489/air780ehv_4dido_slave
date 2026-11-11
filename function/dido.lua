-- 4DI 采集 + 4DO 控制
-- DI 输入: DI_CH1~4
-- DO 输出: DO_CH1~4

-- ============ 管脚定义 ============
local DI_CH1 = 36
local DI_CH2 = 37
local DI_CH3 = 38
local DI_CH4 = 16

local DO_CH1 = 21
local DO_CH2 = 3
local DO_CH3 = 35
local DO_CH4 = 34

-- ============ 对外接口（必须先定义） ============

-- 读取指定通道 DI 状态
-- ch: 1~4
local function di_get(ch)
    if ch == 1 then return gpio.get(DI_CH1) end
    if ch == 2 then return gpio.get(DI_CH2) end
    if ch == 3 then return gpio.get(DI_CH3) end
    if ch == 4 then return gpio.get(DI_CH4) end
    return nil
end

-- 设置指定通道 DO 状态
-- ch: 1~4, val: 0或1
local function do_set(ch, val)
    if ch == 1 then gpio.set(DO_CH1, val) end
    if ch == 2 then gpio.set(DO_CH2, val) end
    if ch == 3 then gpio.set(DO_CH3, val) end
    if ch == 4 then gpio.set(DO_CH4, val) end
end

-- 读取指定通道 DO 当前状态
local function do_get(ch)
    if ch == 1 then return gpio.get(DO_CH1) end
    if ch == 2 then return gpio.get(DO_CH2) end
    if ch == 3 then return gpio.get(DO_CH3) end
    if ch == 4 then return gpio.get(DO_CH4) end
    return nil
end

-- ============ 初始化 ============

-- DI: 配置为输入模式 (第二个参数 nil = 输入)
gpio.setup(DI_CH1, nil, gpio.PULLUP)
gpio.setup(DI_CH2, nil, gpio.PULLUP)
gpio.setup(DI_CH3, nil, gpio.PULLUP)
gpio.setup(DI_CH4, nil, gpio.PULLUP)

-- DO: 配置为输出模式, 默认低电平
gpio.setup(DO_CH1, 0, gpio.PULLDOWN)
gpio.setup(DO_CH2, 0, gpio.PULLDOWN)
gpio.setup(DO_CH3, 0, gpio.PULLDOWN)
gpio.setup(DO_CH4, 0, gpio.PULLDOWN)

-- ============ DI 采集任务 ============
local function di_scan_task()

    do_set(1, 1)
    do_set(2, 0)
    do_set(3, 1)
    do_set(4, 0)

    while true do
        local v1 = gpio.get(DI_CH1)
        local v2 = gpio.get(DI_CH2)
        local v3 = gpio.get(DI_CH3)
        local v4 = gpio.get(DI_CH4)
        log.info("DI", "CH1=" .. v1, "CH2=" .. v2, "CH3=" .. v3, "CH4=" .. v4)
        sys.wait(100)
    end
end

sys.taskInit(di_scan_task)

return {
    di_get  = di_get,
    do_set  = do_set,
    do_get  = do_get,
}
