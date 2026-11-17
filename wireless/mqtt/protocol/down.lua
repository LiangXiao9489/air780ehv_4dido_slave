--[[
@module  down
@summary MQTT 下行 JSON 解析 + 按 topic/type 分发（唯一入口：dispatch）
@version 2.0
@date    2026.11.17
@usage
receiver.lua 在 "recv" 事件回调里拿到 topic 和 payload 后，
只需要调一行 down.dispatch(topic, payload)，down 内部会：
  1. 按 topic 找到对应的 handler 表
  2. json.decode payload 得到 msg
  3. 按 msg.t 找到对应的 type handler
  4. handler 回调里 sys.taskInit 独立 task 处理（不阻塞 receiver 回调）

EHV 版本和原版的核心区别：
- 没有 store 缓存层 → call 直接读本机 DI/DO GPIO
- 没有 485 u1 主站 → set 直接调 do.do_set() 写本机 DO 继电器
- 没有 downlink_uart_lock / hardware 依赖
- 只有一台虚拟设备（本机 SN 作为 dev_id）

三个下行 topic：
  /s/${sn}    → call（查 DI/DO 状态）、set（写 DO）
  /scr/${sn}  → indexReal（快速上报）、his/ctr（占位）
  /s2/${sn}   → call/set（本机配置参数）、ota（固件升级）
]]

local topics   = require "topics"
local up       = require "up"
local ack      = require "ack"
local sender   = require "sender"
local report   = require "report"
local cfg      = require "cfg"
local ota      = require "ota"
local config   = require "config"
local di       = require "di"
local dout     = require "do"

local down = {}

-- ============================================================
-- 工具函数
-- ============================================================

local function now_str()
    return os.date("%Y-%m-%d %H:%M:%S")
end

-- EHV 虚拟设备 id（本机 SN）
local DEV_KEY = topics.SN

-- 检查 dev_id 是否是本机（字符串比较，因为 json.decode 后 key 是字符串）
local function is_self(dev_id)
    return tostring(dev_id) == DEV_KEY
end

-- DO tag → GPIO 通道号（和 report.lua 保持一致）
local DO_TAG_TO_CH = {
    do_a = 1, do_b = 2, do_c = 3, do_d = 4,
}

-- DI tag → GPIO 通道号
local DI_TAG_TO_CH = {
    di_a = 1, di_b = 2, di_c = 3, di_d = 4,
}

-- ============================================================
-- 内部：处理 /s/${sn} 的 call（查询 DI/DO 状态）
-- ============================================================
local function handle_call(dev_id, body)
    local ts = body.ts or {}
    local mid = body.mid
    local result = {}

    if #ts == 0 then
        -- 空 ts → 返回全部 DI/DO
        ts = { "di_a", "di_b", "di_c", "di_d",
               "do_a", "do_b", "do_c", "do_d" }
    end

    local all_ok = true

    for _, tag in ipairs(ts) do
        local v = report.read_point(tag)
        if v == nil then
            -- tag 不存在
            log.warn("mqtt.down", "call tag 不存在", tag)
            result[tag] = { q = "0", t = tostring(os.time()), v = "0" }
            all_ok = false
        else
            result[tag] = {
                q = "1",
                t = tostring(os.time()),
                v = tostring(v),
            }
        end
    end

    if mid ~= nil then result.mid = mid end

    local payload = up.with_time("callack", now_str(), { [dev_id] = result })
    sender.publish(topics.UP_DATA, payload, 1)
    log.info("mqtt.down", "callack 已发送", "dev=" .. dev_id,
             "count=" .. #ts, "all_ok=" .. tostring(all_ok))
end

-- ============================================================
-- 内部：处理 /s/${sn} 的 set（写本机 DO 继电器）
-- ============================================================
local function handle_set(dev_id, body)
    -- 检查 mqtt_do_en 开关
    local do_en = config.get("mqtt_do_en")
    if do_en ~= true then
        log.warn("mqtt.down", "set 被禁止：mqtt_do_en = false")
        local result = { fail = { "disabled" } }
        sender.publish(topics.UP_DATA,
            ack.build("setack", dev_id, result, body.mid), 1)
        return
    end

    local fail_tags = {}
    local not_found_tags = {}
    local all_ok = true
    local any_written = false

    for tag, val in pairs(body) do
        if tag == "mid" then goto continue end

        -- 不允许写 DI（只读）
        if DI_TAG_TO_CH[tag] then
            all_ok = false
            fail_tags[#fail_tags + 1] = tag
            log.warn("mqtt.down", "set 不可写 DI", tag)

        elseif DO_TAG_TO_CH[tag] then
            local num_val = tonumber(val)
            if num_val == nil then
                all_ok = false
                fail_tags[#fail_tags + 1] = tag
                log.warn("mqtt.down", "set 值非法", tag, tostring(val))
            else
                local ch = DO_TAG_TO_CH[tag]
                local bin_val = (num_val ~= 0) and 1 or 0
                dout.do_set(ch, bin_val)
                any_written = true
                log.info("mqtt.down", "set DO 成功", tag, "ch=" .. ch, "val=" .. bin_val)
            end

        else
            all_ok = false
            not_found_tags[#not_found_tags + 1] = tag
            log.warn("mqtt.down", "set 未知 tag", tag)
        end

        ::continue::
    end

    -- 先回 setack
    local r
    if all_ok and #fail_tags == 0 and #not_found_tags == 0 then
        r = { success = "all" }
    else
        r = {}
        if #fail_tags > 0 then r.fail = fail_tags end
        if #not_found_tags > 0 then r.not_found = not_found_tags end
    end
    sender.publish(topics.UP_DATA, ack.build("setack", dev_id, r, body.mid), 1)

    -- set 成功后补发一条 real（协议要求）
    if any_written then
        report.send_real_after_set()
    end
end

-- ============================================================
-- handler 注册表
-- ============================================================
local TOPIC_HANDLERS = {
    -- /s/${sn}：主业务下行（DI/DO）
    [topics.SUB_DATA] = {
        call = function(msg)
            sys.taskInit(function()
                for dev_id, body in pairs(msg.d or {}) do
                    if is_self(dev_id) then
                        handle_call(dev_id, body)
                    else
                        log.warn("mqtt.down", "call dev_id 不匹配", dev_id, "expect=" .. DEV_KEY)
                    end
                end
            end)
        end,

        set = function(msg)
            sys.taskInit(function()
                for dev_id, body in pairs(msg.d or {}) do
                    if is_self(dev_id) then
                        handle_set(dev_id, body)
                    else
                        log.warn("mqtt.down", "set dev_id 不匹配", dev_id, "expect=" .. DEV_KEY)
                    end
                end
            end)
        end,
    },

    -- /scr/${sn}：控制下行
    [topics.SUB_CONTROL] = {
        indexReal = function(msg)
            report.start_index_real(msg)
        end,

        his = function(msg)
            log.info("mqtt.down", "his 历史召回（占位，暂未实现）", json.encode(msg.d or {}))
        end,

        ctr = function(msg)
            log.info("mqtt.down", "ctr 控制（占位，暂未实现）", json.encode(msg.d or {}))
        end,
    },

    -- /s2/${sn}：网关自身参数（本机作为虚拟设备）
    [topics.SUB_CFG] = {
        call = function(msg)
            sys.taskInit(function()
                for dev_id, body in pairs(msg.d or {}) do
                    if is_self(dev_id) then
                        cfg.on_call(dev_id, body)
                    else
                        log.warn("mqtt.down", "cfg call dev_id 不匹配", dev_id)
                    end
                end
            end)
        end,

        set = function(msg)
            sys.taskInit(function()
                for dev_id, body in pairs(msg.d or {}) do
                    if not is_self(dev_id) then
                        log.warn("mqtt.down", "cfg set dev_id 不匹配", dev_id)
                    elseif ota.is_busy() and body.sys_action then
                        -- OTA 升级中拦截 reboot/factoryReset
                        log.warn("mqtt.down", "OTA 升级中，拦截 sys_action")
                        local mid = body.mid
                        sender.publish(topics.UP_CFG,
                            ack.build("setack", topics.SN, { fail = { "busy" } }, mid), 1)
                        cfg.set_last_error("ota_busy")
                    else
                        cfg.on_set(dev_id, body)
                    end
                end
            end)
        end,

        ota = function(msg)
            sys.taskInit(function()
                for dev_id, body in pairs(msg.d or {}) do
                    if is_self(dev_id) then
                        ota.on_ota(body)
                    else
                        log.warn("mqtt.down", "ota dev_id 不匹配", dev_id)
                        cfg.set_last_error("ota_param")
                        sender.publish(topics.UP_CFG,
                            ack.build("otaDownloadAck", topics.SN,
                                      { fail = { "param" } }, body and body.mid), 1)
                    end
                end
            end)
        end,
    },
}

-- ============================================================
-- 对外唯一入口
-- ============================================================
function down.dispatch(topic, payload)
    -- 1. 按 topic 找 handler 表
    local handlers = TOPIC_HANDLERS[topic]
    if not handlers then
        log.warn("mqtt.down", "无 handler 的 topic", topic)
        return false
    end

    -- 2. json.decode
    local ok, msg = pcall(json.decode, payload)
    if not ok or type(msg) ~= "table" then
        log.warn("mqtt.down", "json decode 失败", payload)
        return false
    end

    -- 3. 按 type 找 handler
    local handler = handlers[msg.t]
    if not handler then
        log.warn("mqtt.down", "未知 type", msg.t, "topic=", topic)
        return false
    end

    -- 4. 执行 handler（handler 里自己起独立 task，这里同步调用完就返回）
    handler(msg)
    return true
end

return down
