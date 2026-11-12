

PROJECT = "4DI_4DO"
VERSION = "1234567890"
pm.ioVol(pm.IOVOL_ALL_GPIO, 3300)


log.info("main", "project name is ", PROJECT, "version is ", VERSION)

-- 加载 LED 闪烁模块
require("led_blink")
-- 加载 DI 采集模块
require("di")
-- 加载 DO 继电器模块
require("do")
-- 加载 RS485 串口2模块
require("rs485")

sys.run()

