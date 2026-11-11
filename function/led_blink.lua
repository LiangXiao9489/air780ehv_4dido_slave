-- LED 闪烁任务
-- 管脚: 27, 高电平亮, 低电平灭

local LED_PIN = 27

local function led_blink_task()
    gpio.setup(LED_PIN, 0, gpio.PULLDOWN)
    while true do
        gpio.set(LED_PIN, 1)
        sys.wait(100)
        gpio.set(LED_PIN, 0)
        sys.wait(100)
    end
end

sys.taskInit(led_blink_task)
