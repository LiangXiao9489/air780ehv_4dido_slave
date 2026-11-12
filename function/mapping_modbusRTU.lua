--[[
@module  mapping_modbusRTU
@summary 4DI / 4DO 与 Modbus RTU 从站的地址映射与业务处理
@version 1.0
@usage
本板卡作为 Modbus RTU 从机：
  DI_CH1~4  ->  离散输入 (FC 0x02)        PDU 地址 600~603   只读
  DO_CH1~4  ->  线圈     (FC 0x01/05/0F)  PDU 地址 800~803   可读写

协议编解码全部交给 modbus_core.lua，本文件只做「地址映射 + 业务动作」。

调用方式（由 rs485.lua 的串口接收回调调用）：
  local slave = require("mapping_modbusRTU")
  local resp = slave.feed(chunk)   -- 传入本次收到的字节，返回需要应答的 ADU，无应答返回 nil
]]

local mb  = require("modbus_core")
local di  = require("di")
local dout = require("do")

-- ============================================================
-- 从机参数配置（按需修改）
-- ============================================================
local SLAVE_ADDR = 1        -- 从机地址 1~247

local DI_BASE    = 600      -- 离散输入起始地址（PDU 地址）
local DI_COUNT   = 4        -- 离散输入数量

local DO_BASE    = 800      -- 线圈起始地址（PDU 地址）
local DO_COUNT   = 4        -- 线圈数量

local MAX_RX_BUF = 256      -- 接收缓冲区上限，防止异常数据无限堆积

local _M = {}

-- ============================================================
-- 线圈状态缓存（上电默认全 0），与 do.lua 的 GPIO 输出保持同步
-- ============================================================
local coil_state = {}
for i = 1, DO_COUNT do
    coil_state[i] = 0
end

-- 读取第 index 路离散输入（1~DI_COUNT），返回 0/1
local function read_di(index)
    local v = di.di_get(index)
    return (v and v ~= 0) and 1 or 0
end

-- 写入第 index 路线圈（1~DO_COUNT）
local function write_coil(index, val)
    val = (val ~= 0) and 1 or 0
    coil_state[index] = val
    dout.do_set(index, val)
end

-- 地址区间合法性检查：请求的 [addr, addr+qty-1] 必须完全落在 [base, base+count-1] 内
local function in_range(addr, qty, base, count)
    return addr >= base and qty >= 1 and (addr + qty - 1) <= (base + count - 1)
end

-- 按偏移量收集 qty 个位，offset = 请求地址 - 起始地址
-- getter(index) 返回第 index 路（1-based）的 0/1 值
local function collect_bits(offset, qty, getter)
    local data = {}
    for i = 1, qty do
        data[i] = getter(offset + i)
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
        -- 0x01 读线圈
        if not in_range(req.addr, req.qty, DO_BASE, DO_COUNT) then
            resp = mb.encode_exception(SLAVE_ADDR, fc, mb.EXCEPTION_ILLEGAL_DATA_ADDRESS)
        else
            local data = collect_bits(req.addr - DO_BASE, req.qty, function(i)
                return coil_state[i] or 0
            end)
            resp = mb.encode_response({ dev_id = SLAVE_ADDR, fc = fc, data = data })
        end

    elseif fc == mb.FC_READ_DISCRETE_INPUTS then
        -- 0x02 读离散输入
        if not in_range(req.addr, req.qty, DI_BASE, DI_COUNT) then
            resp = mb.encode_exception(SLAVE_ADDR, fc, mb.EXCEPTION_ILLEGAL_DATA_ADDRESS)
        else
            local data = collect_bits(req.addr - DI_BASE, req.qty, read_di)
            resp = mb.encode_response({ dev_id = SLAVE_ADDR, fc = fc, data = data })
        end

    elseif fc == mb.FC_WRITE_SINGLE_COIL then
        -- 0x05 写单个线圈
        if not in_range(req.addr, 1, DO_BASE, DO_COUNT) then
            resp = mb.encode_exception(SLAVE_ADDR, fc, mb.EXCEPTION_ILLEGAL_DATA_ADDRESS)
        else
            write_coil(req.addr - DO_BASE + 1, (req.value == 0xFF00) and 1 or 0)
            log.info("MB", "写线圈", req.addr, "=", (req.value == 0xFF00) and 1 or 0)
            resp = mb.encode_response({ dev_id = SLAVE_ADDR, fc = fc,
                                        addr = req.addr, value = req.value })
        end

    elseif fc == mb.FC_WRITE_MULTIPLE_COILS then
        -- 0x0F 写多个线圈
        if not in_range(req.addr, req.qty, DO_BASE, DO_COUNT) then
            resp = mb.encode_exception(SLAVE_ADDR, fc, mb.EXCEPTION_ILLEGAL_DATA_ADDRESS)
        else
            for i = 1, req.qty do
                write_coil(req.addr - DO_BASE + i, req.values[i])
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
