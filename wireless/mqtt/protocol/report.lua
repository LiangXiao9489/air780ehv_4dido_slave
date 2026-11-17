--[[
@module  report
@summary MQTT 上行定时上报：real（整点全量）/ change（变化）/ realIndex（首页快速）
@version 1.1
@date    2026.11.17
@usage
require 即启动一个 task，负责三件事：

1. real 全量上报：按 config.upload_interval_min 对齐整分钟（如 15:00:00 / 15:05:00），
   ti 和每个 tag 的 t 都用整点时间，q=1 表示采集正常；
2. change 变化上报：每 config.change_check_sec 秒对比一次快照，只报有变化的 tag；
3. realIndex 快速上报：由 down.lua 的 indexReal 指令调 report.start_index_real(msg)
   → 立刻上行一次，之后按 iv 周期上行，持续 du 秒后自动恢复。

数据源：直接读 di.di_get() / do.do_get()（本机 4DI + 4DO）
上行出口：sender.publish(topics.UP_DATA, payload, 1)

协议要点（沿用 ext 版 /${action}/${sn} 格式）：
- tag 内 q 是质量位 0/1，采集正常必须为 "1"；
- tag 内 t 是 unix 秒字符串；外层 ti 是 "2018-10-10 16:01:47" 格式；
- real 必须整 5 分钟上报（ti 和 t 都要整点）。
]]

local topics = require "topics"
local up     = require "up"
local ack    = require "ack"
local sender = require "sender"
local config = require "config"
local di     = require "di"
local dout   = require "do"
local points = require "point_table"

local report = {}

-- 外部唤醒事件：indexReal 指令到达时 publish 一下，让 task 立刻重算等待时间
local WAKE_TOPIC = "MQTT_REPORT_WAKE"

-- ============================================================
-- 时间有效性门限
-- 上电后系统时钟未被 NTP 校准前，os.time() 停在 2000-01-01，
-- 此时按整点对齐会算出 2000-01-01 08:05:00 这种假时间戳上报，必须先拦住。
-- 1600000000 ≈ 2020-09-13 12:26:40 UTC
-- ============================================================
local TIME_VALID_MIN = 1600000000
local last_time_warn = -1000

local function time_ok(tag)
    local now = os.time()
    if now >= TIME_VALID_MIN then return true end

    -- 每 30 秒最多提示一次，避免刷屏
    if now - last_time_warn >= 30 then
        last_time_warn = now
        log.warn("mqtt.report", "系统时间未同步，暂不上报", tag,
                 os.date("%Y-%m-%d %H:%M:%S", now))
    end
    return false
end

-- indexReal 里 iv 的单位：协议正文写"毫秒"，但示例 iv:"5" 且需求是"5秒一上送"
-- 这里按秒解释；若服务端确实下发毫秒值，把这里改成 false
local IV_IS_SECOND = true

-- ============================================================
-- 实时采集全部点位
-- 返回: { di_a=0/1, di_b=0/1, ..., do_a=0/1, ... }
-- ============================================================
local function read_all_points()
    local values = {}
    for _, p in ipairs(points.POINTS) do
        local v
        if p.reg_type == 2 then
            v = di.di_get(p.ch)
        else
            v = dout.do_get(p.ch)
        end
        values[p.tag] = (v and v ~= 0) and 1 or 0
    end
    return values
end

-- 按 tag 名字读单个点（down.lua call 用）
local function read_point(tag)
    local pt = points.TAG_TO_POINT[tag]
    if not pt then return nil end
    local v
    if pt.reg_type == 2 then
        v = di.di_get(pt.ch)
    else
        v = dout.do_get(pt.ch)
    end
    return (v and v ~= 0) and 1 or 0
end
report.read_point = read_point

-- ============================================================
-- 快速上报状态
-- ============================================================
local fast = {
    active    = false,
    deadline  = 0,     -- 到期时间（unix 秒）
    iv_sec    = 5,     -- 上报周期（秒）
    next_send = 0,     -- 下次上报时间
    targets   = {},    -- { [tag] = true }；nil 或空表 = 全部
}

-- 上次上报快照，用于 change 对比
-- last[tag] = { v = 数字 }
local last = {}

local function now_str(ts)
    return os.date("%Y-%m-%d %H:%M:%S", ts)
end

-- 质量位：EHV 的 DI/DO 只读 GPIO，始终 ok
local function quality_of()
    return "1"
end

-- 构建上报用的数据表
-- filter_tags: nil / {} = 全部点位；否则 { di_a=true, do_c=true, ... }
-- fixed_ts: 数字时所有 tag 都用这个时间戳（real 整点）；nil 时用当前时间
local function build_data(filter_tags, fixed_ts)
    local d = {}
    local ts = fixed_ts or os.time()

    for _, p in ipairs(points.POINTS) do
        local keep = true
        if filter_tags and next(filter_tags) then
            keep = (filter_tags[p.tag] == true)
        end

        if keep then
            local v = read_point(p.tag)
            d[p.tag] = {
                q = quality_of(),
                t = tostring(ts),
                v = tostring(v or 0),
            }
        end
    end
    return d
end

local function has_any(d)
    for _ in pairs(d) do return true end
    return false
end

-- 把当前所有点位写进快照（real 上报后调用）
local function commit_snapshot()
    for _, p in ipairs(points.POINTS) do
        last[p.tag] = { v = read_point(p.tag) or 0 }
    end
end

-- 对比快照，返回变化的数据表 + 是否有变化
local function diff_data()
    local d = {}
    local any = false
    local now = os.time()

    for _, p in ipairs(points.POINTS) do
        local v = read_point(p.tag) or 0
        local prev = last[p.tag]
        if not prev or prev.v ~= v then
            any = true
            last[p.tag] = { v = v }
            d[p.tag] = {
                q = "1",
                t = tostring(now),
                v = tostring(v),
            }
        end
    end
    return d, any
end

-- ============================================================
-- 三种上报
-- ============================================================

-- EHV 没有"设备 id"，dev_key 固定用 SN（把本机当成一台虚拟设备上报）
local DEV_KEY = topics.SN

local function send_real(boundary_ts)
    if not time_ok("real") then return end

    local d = build_data(nil, boundary_ts)
    if not has_any(d) then return end

    sender.publish(topics.UP_DATA, up.with_time("real", now_str(boundary_ts), { [DEV_KEY] = d }), 1)
    commit_snapshot()
    log.info("mqtt.report", "real 上报完成", "ti=" .. now_str(boundary_ts))
end

-- set 成功后补发一条 real（协议要求：iot 收到 setack 不会改自己的实时数据，
-- 需要控制器再发一条格式与 real 相同的数据；由 down.lua 在确有写入成功时调用）
function report.send_real_after_set()
    if not time_ok("real") then return end

    local now = os.time()
    local d = build_data(nil, nil)
    if not has_any(d) then return end

    sender.publish(topics.UP_DATA, up.with_time("real", now_str(now), { [DEV_KEY] = d }), 1)
    commit_snapshot()
    log.info("mqtt.report", "set 后补发 real", "ti=" .. now_str(now))
end

local function send_change()
    if not time_ok("change") then return end

    local d, any = diff_data()
    if not any then return end

    sender.publish(topics.UP_DATA, up.with_time("change", now_str(), { [DEV_KEY] = d }), 1)
    log.info("mqtt.report", "change 上报完成")
end

local function send_fast()
    if not time_ok("realIndex") then return end

    local d = build_data(fast.targets, nil)
    if not has_any(d) then return end

    sender.publish(topics.UP_DATA, up.with_time("realIndex", now_str(), { [DEV_KEY] = d }), 1)
    log.info("mqtt.report", "realIndex 快速上报")
end

-- ============================================================
-- 对外：indexReal 指令入口（由 down.lua 调用）
-- msg: { t="indexReal", sti=..., du=..., iv=..., d={ ${sn}={ts=[...], mid=...} } }
-- 注意：EHV 只有一台"设备"（本机），ts 缺省 = 全部 DI/DO
-- ============================================================
function report.start_index_real(msg)
    if not time_ok("indexReal") then return end

    local du = tonumber(msg.du)
    local iv = tonumber(msg.iv) or 5

    if du == nil or du < 0 or du > 1800 then
        log.warn("mqtt.report", "indexReal du 非法，不执行", tostring(msg.du))
        local mid = nil
        if msg.d and msg.d[DEV_KEY] and msg.d[DEV_KEY].mid ~= nil then
            mid = msg.d[DEV_KEY].mid
        end
        sender.publish(topics.UP_CONTROL_ACK,
            ack.build("indexRealAck", DEV_KEY, { fail = { "param" } }, mid), 1)
        return
    end

    local iv_sec = IV_IS_SECOND and iv or (iv / 1000)
    if iv_sec < 1 then iv_sec = 1 end

    -- 解析目标 tag
    local targets = {}
    local acks = {}
    local not_found = {}

    local body = msg.d and msg.d[DEV_KEY] or {}
    local tags = body.ts
    local mid = body.mid

    if tags and #tags > 0 then
        for _, tag in ipairs(tags) do
            if points.TAG_TO_POINT[tag] then
                targets[tag] = true
            else
                not_found[#not_found + 1] = tag
            end
        end
    else
        -- 缺省 = 全部
        for _, p in ipairs(points.POINTS) do targets[p.tag] = true end
    end

    local r
    if #not_found == 0 then
        r = { success = "all" }
    else
        r = { not_found = not_found }
    end
    acks[#acks + 1] = { dev = DEV_KEY, mid = mid, r = r }

    -- 新指令覆盖旧的快速上报配置
    fast.targets   = targets
    fast.active    = (#targets > 0)
    fast.deadline  = os.time() + du
    fast.iv_sec    = iv_sec
    fast.next_send = os.time()   -- 立即上报一次

    for _, a in ipairs(acks) do
        sender.publish(topics.UP_CONTROL_ACK, ack.build("indexRealAck", a.dev, a.r, a.mid), 1)
    end

    sys.publish(WAKE_TOPIC)
    log.info("mqtt.report", "indexReal 启动", "du=" .. du .. "s", "iv=" .. iv_sec .. "s",
             "tags=" .. #targets)
end

-- ============================================================
-- 上报主 task
-- ============================================================
local function report_task()
    sys.wait(3000)   -- 等 di.lua / do.lua / config.lua 等模块全部就绪

    -- 开机先建快照，避免把"首次采集"整体当成变化上报
    commit_snapshot()

    local last_change_check = os.time()
    local init_period = (tonumber(config.get("upload_interval_min")) or 5) * 60
    if init_period < 60 then init_period = 60 end
    local last_real_ts = os.time() - (os.time() % init_period)

    while true do
        local now = os.time()

        local period_min = tonumber(config.get("upload_interval_min")) or 5
        if period_min < 1 then period_min = 1 end
        local period = period_min * 60

        local change_sec = tonumber(config.get("change_check_sec")) or 5
        if change_sec < 1 then change_sec = 1 end

        -- 下一个整点（对齐到 period 的整数倍）
        local next_boundary = now - (now % period) + period
        -- 下一次变化检测
        local next_change = last_change_check + change_sec
        -- 下一次快速上报
        local next_fast = fast.active and fast.next_send or nil

        local wake_at = next_boundary
        if next_change < wake_at then wake_at = next_change end
        if next_fast and next_fast < wake_at then wake_at = next_fast end

        local wait_ms = (wake_at - now) * 1000
        if wait_ms < 50 then wait_ms = 50 end

        -- 被 indexReal 指令唤醒时会提前返回，下一轮重新计算
        sys.waitUntil(WAKE_TOPIC, wait_ms)

        -- 醒来后用当前时钟重新算整点
        now = os.time()
        local cur_boundary = now - (now % period)

        -- 时钟回退（少见）：重置基准，等下一个整点
        if cur_boundary < last_real_ts then
            log.warn("mqtt.report", "检测到时钟回退，重置整点基准",
                     os.date("%Y-%m-%d %H:%M:%S", now))
            last_real_ts = cur_boundary
        end

        -- 整点全量上报（优先执行，避免和 change 在同一秒重复上报）
        local did_real = false
        if cur_boundary > last_real_ts then
            local gap = cur_boundary - last_real_ts
            last_real_ts = cur_boundary

            if gap <= period * 2 then
                send_real(cur_boundary)
                did_real = true
            else
                -- 时钟跳变（NTP 校准跨年）：只重新对齐，不发这条假整点
                log.warn("mqtt.report", "时钟跳变，跳过本次整点上报",
                         "gap=" .. gap .. "s",
                         "new_boundary=" .. os.date("%Y-%m-%d %H:%M:%S", cur_boundary))
            end
        end

        -- 快速上报
        if fast.active then
            if now >= fast.next_send then
                send_fast()
                fast.next_send = now + fast.iv_sec
            end
            if now >= fast.deadline then
                fast.active = false
                log.info("mqtt.report", "indexReal 到期，恢复常规上报")
            end
        end

        -- 变化上报
        if now >= last_change_check + change_sec then
            if not did_real then send_change() end
            last_change_check = now
        end
    end
end

sys.taskInit(report_task)

return report
