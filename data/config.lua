--[[
@module  config
@summary Air780EHV 运行时配置（JSON 文件持久化，按需 fallback 默认值）
@version 1.1
@date    2026.11.17
@usage
所有"运行时可配置"的参数都在这里集中管理，文件系统落盘，重启不丢失。

文件位置：/gateway_cfg.json
首次启动：文件不存在 → 写入 DEFAULT_CFG 到文件
后续启动：文件存在 → 读入内存；OTA 新增字段时 get() 自动 fallback 默认值

对外 API：
  get(key)              读参数，文件缺这个 key 时 fallback DEFAULT_CFG[key]
  set(key, val)         改内存 + 立刻落盘
  all()                 返回当前内存中的完整 cfg table（只读）
  factory_reset()       删配置文件 + 重启

NOTICE：DEFAULT_CFG 里的 key 是"运行时可配"的全量集合。
硬件焊死的参数（GPIO 端口号、RS485 EN 控制脚、串口波特率等）不要放这里，
继续写死在对应的 hardware 模块里（di.lua / do.lua / rs485.lua）。
]]

local _M = {}

-- ============================================================
-- 文件路径 + 默认参数集合（OTA 新增字段时往这里加，get() 自动兜底）
-- ============================================================
local CONFIG_PATH = "/gateway_cfg.json"

-- 默认参数（按功能分组）
local DEFAULT_CFG = {
    -- ---------- U2 串口参数（RS485 从站传输层，改了需要重启生效） ----------
    u2_baudrate  = 9600,       -- 波特率：1200 / 2400 / 4800 / 9600 / 19200 / 38400 / 57600 / 115200
    u2_databits  = 8,          -- 数据位：5~8
    u2_stopbits  = 1,          -- 停止位：1 / 2
    u2_parity    = "N",        -- 校验位：N=无 / E=偶 / O=奇

    -- ---------- MQTT 业务参数 ----------
    upload_interval_min = 5,   -- MQTT 实时数据上报间隔（分钟，需为整分钟对齐）
    change_check_sec    = 5,   -- 变化数据检测周期（秒）
    mqtt_do_en          = true,-- 是否允许 MQTT 下行控制本机 DO 继电器

    -- ---------- 传输层参数占位 ----------
    -- mqtt_host / mqtt_port / mqtt_username / mqtt_password 后续逐步迁入
}

-- 内存镜像（init() 填充）
local cfg

-- ============================================================
-- 内部：先定义 save，因为 load_or_init 要调它
-- ============================================================
local function save()
    -- 只把当前 cfg 里有定义的 key 写入文件
    -- （set() 时才会有，read-only fallback 不会污染文件）
    local f = io.open(CONFIG_PATH, "w")
    if f then
        f:write(json.encode(cfg))
        f:close()
    else
        log.error("config", "写入失败，磁盘可能满了")
    end
end

-- ============================================================
-- 内部：从文件读或写默认
-- ============================================================
local function load_or_init()
    local f = io.open(CONFIG_PATH, "r")
    if f then
        local raw = f:read("*a")
        f:close()
        cfg = json.decode(raw)
        if type(cfg) ~= "table" then
            log.warn("config", "文件损坏，用默认值覆盖")
            cfg = {}
            save()
        end
    else
        log.info("config", "首次启动，写入默认配置")
        cfg = {}
        -- 把默认值全量写入 cfg，这样文件里有完整快照
        for k, v in pairs(DEFAULT_CFG) do cfg[k] = v end
        save()
    end
end

-- ============================================================
-- 对外 API
-- ============================================================

-- 读参数：文件里有就用文件的，没有就 fallback 默认值
function _M.get(key)
    local v = cfg[key]
    if v == nil then
        return DEFAULT_CFG[key]   -- 文件里没有这个 key（包括 OTA 新增字段的场景）
    end
    return v
end

-- 写参数：改内存 + 立刻落盘
function _M.set(key, val)
    cfg[key] = val
    save()
end

-- 返回完整内存表（调用方只读，别改里面的值，改了不走 save）
function _M.all()
    return cfg
end

-- 读完整默认表（调试用）
function _M.defaults()
    return DEFAULT_CFG
end

-- 恢复出厂：清空内存配置 → 删除文件 → 重启
-- 下次启动 load_or_init 会检测到文件不存在，自动全量写入 DEFAULT_CFG
-- 调用方（比如 MQTT 层的 factoryReset type）不用关心内部细节
function _M.factory_reset()
    log.warn("config", "恢复出厂设置！")
    cfg = {}
    os.remove(CONFIG_PATH)
    log.info("config", "配置文件已删除，即将重启...")
    rtos.reboot()
end

-- ============================================================
-- 模块加载时自动 init（require "config" 即运行）
-- ============================================================
load_or_init()
log.info("config", "初始化完成", "文件=" .. CONFIG_PATH)

return _M
