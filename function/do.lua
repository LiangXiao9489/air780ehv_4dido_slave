-- 4DO 继电器控制
-- DO_CH1~4: GPIO21/3/35/34
-- DO_EN: GPIO22 (继电器使能, 保持高电平)

-- ============ 管脚定义 ============
local DO_CH1 = 21
local DO_CH2 = 3
local DO_CH3 = 35
local DO_CH4 = 34

local DO_EN  = 22

-- ============ 初始化 ============

-- DO: 配置为输出模式, 默认低电平
gpio.setup(DO_CH1, 0, gpio.PULLDOWN)
gpio.setup(DO_CH2, 0, gpio.PULLDOWN)
gpio.setup(DO_CH3, 0, gpio.PULLDOWN)
gpio.setup(DO_CH4, 0, gpio.PULLDOWN)

-- DO_EN: 继电器使能脚, 保持高电平
gpio.setup(DO_EN, 1, gpio.PULLDOWN)

-- ============ 对外接口 ============

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

-- ============ DO 循环测试任务 ============
local function do_test_task()
    local channels = {
        { DO_CH1, DO_CH2, DO_CH3, DO_CH4 },
    }

    -- 轮询: DO1开234关 → DO2开134关 → DO3开124关 → DO4开123关, 每个保持2s
    while true do
        -- DO1 开
        gpio.set(DO_CH1, 1)
        gpio.set(DO_CH2, 0)
        gpio.set(DO_CH3, 0)
        gpio.set(DO_CH4, 0)
        log.info("DO", "CH1 ON, others OFF")
        sys.wait(2000)

        -- DO2 开
        gpio.set(DO_CH1, 0)
        gpio.set(DO_CH2, 1)
        gpio.set(DO_CH3, 0)
        gpio.set(DO_CH4, 0)
        log.info("DO", "CH2 ON, others OFF")
        sys.wait(2000)

        -- DO3 开
        gpio.set(DO_CH1, 0)
        gpio.set(DO_CH2, 0)
        gpio.set(DO_CH3, 1)
        gpio.set(DO_CH4, 0)
        log.info("DO", "CH3 ON, others OFF")
        sys.wait(2000)

        -- DO4 开
        gpio.set(DO_CH1, 0)
        gpio.set(DO_CH2, 0)
        gpio.set(DO_CH3, 0)
        gpio.set(DO_CH4, 1)
        log.info("DO", "CH4 ON, others OFF")
        sys.wait(2000)
    end
end

sys.taskInit(do_test_task)

return {
    do_set = do_set,
    do_get = do_get,
}
