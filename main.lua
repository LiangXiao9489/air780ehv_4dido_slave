

PROJECT = "Air780EHV_4DI4DO"
VERSION = "1.0.0"
pm.ioVol(pm.IOVOL_ALL_GPIO, 3300)


log.info("=========== Air780EHV 固件启动 =============")
log.info("=========== 版本: " .. VERSION .. " =============")
log.info("=========== UID: " .. mcu.unique_id():toHex() .. " =============")

-- ============================================================
-- 运行时配置（JSON 文件持久化）：必须最先加载
-- report / down / cfg 都要读它
-- ============================================================
require("config")

-- 外部硬件看门狗（Air153C，WTDOG=GPIO28）：require 即启动喂狗 task
require("ext_wdt")

-- LED 闪烁
require("led_blink")

-- 本机 4DI / 4DO 硬件驱动
require("di")
require("do")

-- RS485 从站：上位机 Modbus 请求 → 直接操作本机 DI/DO
require("rs485")

-- ============================================================
-- 4G 蜂窝网络
-- ============================================================
require("net_4g")

-- NTP 网络对时：IP_READY 后同步系统时钟
require("sntp")

-- 网络看门狗（默认注释，需要时取消）：5 分钟无网络活动自动重启
-- require("net_watchdog")

-- ============================================================
-- MQTT 协议栈（require 即启动整条链路：
-- basic → sender + receiver + topics + down + report + cfg + ota）
-- ============================================================
require("basic")


sys.run()

