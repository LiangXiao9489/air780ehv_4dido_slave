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
local config       = require("config")

-- ============================================================
-- RS485 从机参数（config 落盘，改了需要重启生效）
-- ============================================================
local uartid     = 2     -- 本板卡 RS4852 接在串口2（硬件焊死）
local uart485Pin = 25    -- RS4852 EN，用于控制485接收和发送的使能引脚（硬件焊死）

-- 校验位映射（config 存字符串 "N"/"E"/"O" → 转 uart 常量）
local PARITY_MAP = {
    N = uart.NONE,
    E = uart.EVEN,
    O = uart.ODD,
}

local u2_baudrate = config.get("u2_baudrate") or 9600
local u2_databits = config.get("u2_databits") or 8
local u2_stopbits = config.get("u2_stopbits") or 1
local u2_parity   = PARITY_MAP[config.get("u2_parity") or "N"] or uart.NONE

log.info("RS485", "串口参数",
    "baud=" .. u2_baudrate,
    "data=" .. u2_databits,
    "stop=" .. u2_stopbits,
    "parity=" .. (config.get("u2_parity") or "N"))

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

-- 初始化（参数从 config 读，改了需要重启）
uart.setup(uartid, u2_baudrate, u2_databits, u2_stopbits, u2_parity, uart.LSB, 1024, uart485Pin, 0, 20000)

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
