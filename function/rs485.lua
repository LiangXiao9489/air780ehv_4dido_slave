--[[
@module  rs485
@summary RS485 串口2 收发模块（Modbus RTU 从站传输层）
@version 1.1
@usage
参考 extra/demo/uart/485_uart.lua 实现
本板卡: RS4852 -> 串口2, RS4852 EN -> GPIO25

1.开启串口2，配置波特率等参数；
2.设置接收回调函数
3.收到主机帧后交给 mapping_modbusRTU 处理，并回发应答
]]
local modbus_slave = require("mapping_modbusRTU")

local uartid     = 2     -- 本板卡 RS4852 接在串口2
local uart485Pin = 25    -- RS4852 EN，用于控制485接收和发送的使能引脚

-- 循环两秒向串口2发一次数据（调试用，Modbus 从站模式下已关闭）
local function uart_send()
    while true do
        sys.wait(2000)
        uart.write(uartid, "1,2,3,4,5,6")
        log.info("RS485", "send: 1,2,3,4,5,6")
    end
end

local function uart_cb(id, len)
    local s = ""
    repeat
        s = uart.read(id, 128) -- 读取缓冲区中的数据，这里设置的一次读最多128字节
        if #s > 0 then -- #s 是取字符串的长度
            -- 每个字节的hex之间加空格, 用括号截断toHex的第二个返回值
            log.info("RS485", "串口" .. id .. "接收到" .. #s .. "字节", (s:toHex(" ")))

            -- 交给 Modbus 从站业务层处理
            local resp = modbus_slave.feed(s)
            if resp then
                uart.write(uartid, resp)
                log.info("RS485", "应答", (resp:toHex(" ")))
            end
        end
    until s == ""
end

-- 初始化
uart.setup(uartid, 9600, 8, 1, uart.NONE, uart.LSB, 1024, uart485Pin, 0, 20000)

-- 收取数据会触发回调, 这里的"receive" 是固定值
uart.on(uartid, "receive", uart_cb)

-- 调试用定时发送，Modbus 从站模式下必须关闭，否则会干扰总线
-- sys.taskInit(uart_send)

-- 对外接口: 主动发送数据
local function rs485_send(data)
    return uart.write(uartid, data)
end

return {
    send = rs485_send,
}
