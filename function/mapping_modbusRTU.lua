--[[
@module  mapping_modbusRTU
@summary 4DI / 4DO 与 Modbus RTU 从站的地址映射与业务处理
@version 1.2
@date    2026.11.17
@usage
本板卡作为 Modbus RTU 从机：
  DI_a~d  ->  离散输入 (FC 0x02)        只读
  DO_a~d  ->  线圈     (FC 0x01/05/0F)  可读写

地址 / tag / ch 全部定义在 data/point_table.lua（唯一权威点表）。
本文件只做「从站协议编解码 + 根据地址找点 + 调硬件驱动」。

调用方式（由 rs485.lua 的串口接收回调调用）：
  local slave = require("mapping_modbusRTU")
  local resp = slave.feed(chunk)   -- 传入本次收到的字节，返回需要应答的 ADU
]]

local mb   = require("modbus_core")
local di   = require("di")
local dout = require("do")
local pt   = require("point_table")

-- ============================================================
-- 从机参数
-- ============================================================
local SLAVE_ADDR = 1        -- 从机地址 1~247
local MAX_RX_BUF = 256      -- 接收缓冲区上限

-- 反向映射：PDU 地址 → ch（从 point_table 自动生成）
local di_addr_to_ch = pt.DI_ADDR_TO_CH     -- 原硬编码 DI_ADDR + KEY_TO_CH 合并
local do_addr_to_ch = pt.DO_ADDR_TO_CH     -- 原硬编码 DO_ADDR + KEY_TO_CH 合并

-- ============================================================
-- 线圈状态缓存（上电默认全 0，与 do.lua 的 GPIO 输出保持同步）
-- key = PDU 地址（方便按地址读写）
-- ============================================================
local coil_state = {}
for addr, _ in pairs(do_addr_to_ch) do coil_state[addr] = 0 end

-- 读取离散输入，addr = PDU 地址，返回 0/1
local function read_di(addr)
    local ch = di_addr_to_ch[addr]
    if not ch then return 0 end
    local v = di.di_get(ch)
    return (v and v ~= 0) and 1 or 0
end

-- 写入线圈，addr = PDU 地址，val = 0/1
local function write_coil(addr, val)
    local ch = do_addr_to_ch[addr]
    if not ch then return end
    val = (val ~= 0) and 1 or 0
    coil_state[addr] = val
    dout.do_set(ch, val)
end

-- ============================================================
-- 地址合法性检查：请求的 [addr, addr+qty-1] 范围内
-- 每一个地址都必须在反向映射表中存在
-- ============================================================
local function range_ok(start, qty, addr_map)
    if qty < 1 or start < 0 then return false end
    for a = start, start + qty - 1 do
        if not addr_map[a] then return false end
    end
    return true
end

-- 按地址范围收集 qty 个位的值
-- getter(addr) 返回该位当前 0/1 值
local function collect_bits(start, qty, addr_map, getter)
    local data = {}
    local i = 1
    for a = start, start + qty - 1 do
        data[i] = addr_map[a] and getter(a) or 0
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
        if not range_ok(req.addr, req.qty, do_addr_to_ch) then
            resp = mb.encode_exception(SLAVE_ADDR, fc, mb.EXCEPTION_ILLEGAL_DATA_ADDRESS)
        else
            local data = collect_bits(req.addr, req.qty, do_addr_to_ch, function(addr)
                return coil_state[addr] or 0
            end)
            resp = mb.encode_response({ dev_id = SLAVE_ADDR, fc = fc, data = data })
        end

    elseif fc == mb.FC_READ_DISCRETE_INPUTS then
        -- 0x02 读离散输入（DI）
        if not range_ok(req.addr, req.qty, di_addr_to_ch) then
            resp = mb.encode_exception(SLAVE_ADDR, fc, mb.EXCEPTION_ILLEGAL_DATA_ADDRESS)
        else
            local data = collect_bits(req.addr, req.qty, di_addr_to_ch, read_di)
            resp = mb.encode_response({ dev_id = SLAVE_ADDR, fc = fc, data = data })
        end

    elseif fc == mb.FC_WRITE_SINGLE_COIL then
        -- 0x05 写单个线圈
        if not do_addr_to_ch[req.addr] then
            resp = mb.encode_exception(SLAVE_ADDR, fc, mb.EXCEPTION_ILLEGAL_DATA_ADDRESS)
        else
            write_coil(req.addr, (req.value == 0xFF00) and 1 or 0)
            log.info("MB", "写线圈 addr=" .. req.addr, "ch=" .. do_addr_to_ch[req.addr],
                     "val=" .. ((req.value == 0xFF00) and 1 or 0))
            resp = mb.encode_response({ dev_id = SLAVE_ADDR, fc = fc,
                                        addr = req.addr, value = req.value })
        end

    elseif fc == mb.FC_WRITE_MULTIPLE_COILS then
        -- 0x0F 写多个线圈
        if not range_ok(req.addr, req.qty, do_addr_to_ch) then
            resp = mb.encode_exception(SLAVE_ADDR, fc, mb.EXCEPTION_ILLEGAL_DATA_ADDRESS)
        else
            local i = 1
            for a = req.addr, req.addr + req.qty - 1 do
                write_coil(a, req.values[i] or 0)
                i = i + 1
            end
            log.info("MB", "写多个线圈, 起始 addr=" .. req.addr, "数量=" .. req.qty)
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
-- ============================================================
local rx_buf = ""

local function frame_length(buf)
    if #buf < 2 then
        return nil
    end
    local fc = buf:byte(2)
    if fc == 0x0F or fc == 0x10 then
        if #buf < 7 then
            return nil
        end
        return 9 + buf:byte(7)
    end
    return 8
end

-- ============================================================
-- 对外接口
-- ============================================================
local _M = {}

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

    if #rx_buf > MAX_RX_BUF then
        rx_buf = ""
    end

    return out
end

return _M
