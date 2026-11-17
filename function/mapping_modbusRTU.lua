--[[
@module  mapping_modbusRTU
@summary 4DI / 4DO 与 Modbus RTU 从站的地址映射与业务处理
@version 1.1
@date    2026.11.17
@usage
本板卡作为 Modbus RTU 从机：
  DI_a~d  ->  离散输入 (FC 0x02)        PDU 地址见下方 DI_ADDR 表   只读
  DO_a~d  ->  线圈     (FC 0x01/05/0F)  PDU 地址见下方 DO_ADDR 表   可读写

地址通过显式表定义，允许不连续。
协议编解码全部交给 modbus_core.lua，本文件只做「地址映射 + 业务动作」。

调用方式（由 rs485.lua 的串口接收回调调用）：
  local slave = require("mapping_modbusRTU")
  local resp = slave.feed(chunk)   -- 传入本次收到的字节，返回需要应答的 ADU，无应答返回 nil
]]

local mb   = require("modbus_core")
local di   = require("di")
local dout = require("do")

-- ============================================================
-- 从机参数配置（按需修改）
-- ============================================================
local SLAVE_ADDR = 1        -- 从机地址 1~247

-- 离散输入地址（PDU 地址，可连续可不连续）
-- key 是通道标签，value 是对应的 Modbus PDU 地址
local DI_ADDR = {
    a = 600,   -- DI_CH1
    b = 601,   -- DI_CH2
    c = 605,   -- DI_CH3
    d = 606,   -- DI_CH4
}

-- 线圈地址（PDU 地址，可连续可不连续）
local DO_ADDR = {
    a = 800,   -- DO_CH1
    b = 801,   -- DO_CH2
    c = 805,   -- DO_CH3
    d = 806,   -- DO_CH4
}

local MAX_RX_BUF = 256      -- 接收缓冲区上限，防止异常数据无限堆积

-- key -> GPIO 通道号（1-based）
local KEY_TO_CH = { a = 1, b = 2, c = 3, d = 4 }

local _M = {}

-- ============================================================
-- 由地址表构建反向映射：addr -> key 字符串
-- ============================================================
local di_addr_to_key = {}   -- addr -> "a"/"b"/"c"/"d"
for k, v in pairs(DI_ADDR) do di_addr_to_key[v] = k end

local do_addr_to_key = {}
for k, v in pairs(DO_ADDR) do do_addr_to_key[v] = k end

-- ============================================================
-- 线圈状态缓存（上电默认全 0），与 do.lua 的 GPIO 输出保持同步
-- key 为 "a"/"b"/"c"/"d"
-- ============================================================
local coil_state = { a = 0, b = 0, c = 0, d = 0 }

-- 读取离散输入，key = "a"/"b"/"c"/"d"，返回 0/1
local function read_di(key)
    local v = di.di_get(KEY_TO_CH[key])
    return (v and v ~= 0) and 1 or 0
end

-- 写入线圈，key = "a"/"b"/"c"/"d"，val = 0/1
local function write_coil(key, val)
    val = (val ~= 0) and 1 or 0
    coil_state[key] = val
    dout.do_set(KEY_TO_CH[key], val)
end

-- ============================================================
-- 地址合法性检查：请求的 [addr, addr+qty-1] 范围内
-- 每一个地址都必须在反向映射表中存在
-- ============================================================
local function range_ok(start, qty, addr_to_key)
    if qty < 1 or start < 0 then return false end
    for a = start, start + qty - 1 do
        if not addr_to_key[a] then return false end
    end
    return true
end

-- 按地址范围收集 qty 个位的值
-- getter(key) 返回该位当前 0/1 值
local function collect_bits(start, qty, addr_to_key, getter)
    local data = {}
    local i = 1
    for a = start, start + qty - 1 do
        local key = addr_to_key[a]
        data[i] = key and getter(key) or 0
        i = i + 1
    end
    return data
end

-- ============================================================
-- 处理单帧请求，返回需要发送的 ADU；不应答返回 nil
-- ============================================================
local function process_frame(adu)
    local req, err = mb.decode_request(adu)
    if not req then
        -- 帧层错误（长度不足 / CRC 失败 / 参数非法），从站不应答
        log.info("MB", "丢弃非法帧, err=0x" .. string.format("%02X", err or 0))
        return nil
    end

    -- 非本机地址且非广播（0），直接忽略
    if req.dev_id ~= SLAVE_ADDR and req.dev_id ~= 0 then
        return nil
    end

    local is_broadcast = (req.dev_id == 0)
    local fc = req.fc
    local resp

    if fc == mb.FC_READ_COILS then
        -- 0x01 读线圈（DO）
        if not range_ok(req.addr, req.qty, do_addr_to_key) then
            resp = mb.encode_exception(SLAVE_ADDR, fc, mb.EXCEPTION_ILLEGAL_DATA_ADDRESS)
        else
            local data = collect_bits(req.addr, req.qty, do_addr_to_key, function(key)
                return coil_state[key] or 0
            end)
            resp = mb.encode_response({ dev_id = SLAVE_ADDR, fc = fc, data = data })
        end

    elseif fc == mb.FC_READ_DISCRETE_INPUTS then
        -- 0x02 读离散输入（DI）
        if not range_ok(req.addr, req.qty, di_addr_to_key) then
            resp = mb.encode_exception(SLAVE_ADDR, fc, mb.EXCEPTION_ILLEGAL_DATA_ADDRESS)
        else
            local data = collect_bits(req.addr, req.qty, di_addr_to_key, read_di)
            resp = mb.encode_response({ dev_id = SLAVE_ADDR, fc = fc, data = data })
        end

    elseif fc == mb.FC_WRITE_SINGLE_COIL then
        -- 0x05 写单个线圈
        local key = do_addr_to_key[req.addr]
        if not key then
            resp = mb.encode_exception(SLAVE_ADDR, fc, mb.EXCEPTION_ILLEGAL_DATA_ADDRESS)
        else
            write_coil(key, (req.value == 0xFF00) and 1 or 0)
            log.info("MB", "写线圈", req.addr, "(", key, ")=",
                     (req.value == 0xFF00) and 1 or 0)
            resp = mb.encode_response({ dev_id = SLAVE_ADDR, fc = fc,
                                        addr = req.addr, value = req.value })
        end

    elseif fc == mb.FC_WRITE_MULTIPLE_COILS then
        -- 0x0F 写多个线圈
        if not range_ok(req.addr, req.qty, do_addr_to_key) then
            resp = mb.encode_exception(SLAVE_ADDR, fc, mb.EXCEPTION_ILLEGAL_DATA_ADDRESS)
        else
            local i = 1
            for a = req.addr, req.addr + req.qty - 1 do
                local key = do_addr_to_key[a]
                write_coil(key, req.values[i] or 0)
                i = i + 1
            end
            log.info("MB", "写多个线圈, 起始", req.addr, "数量", req.qty)
            resp = mb.encode_response({ dev_id = SLAVE_ADDR, fc = fc,
                                        addr = req.addr, qty = req.qty })
        end

    else
        -- 不支持的功能码
        resp = mb.encode_exception(SLAVE_ADDR, fc, mb.EXCEPTION_ILLEGAL_FUNCTION)
    end

    -- 广播只执行，不应答
    if is_broadcast then
        return nil
    end

    return resp
end

-- ============================================================
-- 接收缓冲：解决串口数据分片到达的问题
-- 根据功能码推算整帧长度，凑够一帧才处理，剩余半帧留到下次
-- ============================================================
local rx_buf = ""

local function frame_length(buf)
    if #buf < 2 then
        return nil
    end
    local fc = buf:byte(2)
    if fc == 0x0F or fc == 0x10 then
        -- 写多个：地址2 + 数量2 + 字节数1 + 数据N + CRC2 = 9 + N
        if #buf < 7 then
            return nil
        end
        return 9 + buf:byte(7)
    end
    -- 其余功能码（含不支持的功能码）统一按 8 字节处理
    return 8
end

-- ============================================================
-- 对外接口：喂入串口收到的字节，返回需要应答的数据（可能为 nil）
-- ============================================================
function _M.feed(chunk)
    if type(chunk) ~= "string" or #chunk == 0 then
        return nil
    end

    rx_buf = rx_buf .. chunk

    local out
    while true do
        local n = frame_length(rx_buf)
        if not n or #rx_buf < n then
            break
        end
        local adu = rx_buf:sub(1, n)
        rx_buf = rx_buf:sub(n + 1)

        local resp = process_frame(adu)
        if resp then
            out = (out or "") .. resp
        end
    end

    -- 缓冲区异常堆积时清空，避免吞掉后续正常帧
    if #rx_buf > MAX_RX_BUF then
        rx_buf = ""
    end

    return out
end

return _M
