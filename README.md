# SW1104V10_4DIDO

基于 LuatOS 的 4DI + 4DO 工业控制板工程，硬件平台为 Air780EHV（Cat.1 4G 模块）。

## 硬件信息

| 项目 | 说明 |
|------|------|
| 主控模块 | Air780EHV |
| 通信 | 4G 全网通 (Cat.1) |
| 输入 | 4 路光耦隔离干接点 |
| 输出 | 4 路继电器 (250VAC 10A / 28VDC 10A) |
| 串口 | 2 路 RS485 |
| 电源 | 7~36VDC |

### 管脚分配

| 功能 | 标识 | GPIO | 备注 |
|------|------|------|------|
| DI_CH1 | 输入1 | GPIO36 | 干接点, 光耦隔离 |
| DI_CH2 | 输入2 | GPIO37 | 干接点, 光耦隔离 |
| DI_CH3 | 输入3 | GPIO38 | 干接点, 光耦隔离 |
| DI_CH4 | 输入4 | GPIO16 | 干接点, 光耦隔离 |
| DO_CH1 | 继电器1 | GPIO21 | 输出锁存 EN=GPIO22 |
| DO_CH2 | 继电器2 | GPIO3 | 输出锁存 EN=GPIO22 |
| DO_CH3 | 继电器3 | GPIO35 | 输出锁存 EN=GPIO22 |
| DO_CH4 | 继电器4 | GPIO34 | 输出锁存 EN=GPIO22 |
| DO_EN | 继电器使能 | GPIO22 | 保持高电平 |
| NET_LED | 指示灯 | GPIO27 | 高电平亮 |
| RS485_EN1 | 485收发控制 | GPIO23 | 串口1 |
| RS485_EN2 | 485收发控制 | GPIO25 | 串口2 |

## 项目结构

```
SW1104V10_4DIDO/
├── main.lua                 -- 程序入口
├── .gitignore
├── data/                    -- 运行时配置
│   └── config.lua           -- JSON 落盘的可配参数（上报间隔 / DO 控制开关等）
├── device/                  -- 外设驱动
│   └── ext_wdt.lua          -- Air153C 外部硬件看门狗喂狗（GPIO28）
├── function/                -- 本机硬件 + Modbus 从站
│   ├── di.lua               -- 4 路 DI 输入采集
│   ├── do.lua               -- 4 路 DO 继电器控制
│   ├── led_blink.lua        -- LED 闪烁任务
│   ├── mapping_modbusRTU.lua -- Modbus 从站地址映射 + 业务处理
│   ├── modbus_core.lua      -- Modbus RTU 纯编解码引擎
│   └── rs485.lua            -- RS485 串口收发回调
├── wireless/                -- 无线通信 + MQTT 协议栈
│   ├── 4g/
│   │   ├── net_4g.lua       -- SIM/网络/DNS 管理
│   │   ├── sntp.lua         -- NTP 对时（MQTT 上报 ti/t 依赖）
│   │   └── net_watchdog.lua -- 网络看门狗（默认关闭，5 分钟无活动重启）
│   ├── mqtt/
│   │   ├── basic.lua        -- MQTT 连接生命周期（broker 地址/账密在这里写死）
│   │   ├── receiver.lua     -- 下行接收队列
│   │   ├── sender.lua       -- 上行发送队列
│   │   └── protocol/
│   │       ├── topics.lua   -- topic 模板 /${action}/${sn}（SN = UID）
│   │       ├── up.lua       -- 上行 JSON 拼装
│   │       ├── ack.lua      -- ack 应答 JSON 拼装
│   │       ├── cfg.lua      -- /s2/${sn} 本机参数 call/set
│   │       ├── down.lua     -- 下行 call/set/indexReal 分发
│   │       └── report.lua   -- real/change/realIndex 定时上报
│   └── ota.lua              -- HTTP 下载 + CRC32 + fota 远程升级
└── extra/                   -- 官方 Demo (已被 gitignore 忽略)
```

## MQTT 协议

### Topic 格式

沿用 ext 版 /${action}/${sn}，其中 **sn = 芯片 UID**（`mcu.unique_id():toHex()`）：

| 方向 | Topic | 用途 |
|------|-------|------|
| 上行 | `/d/${sn}` | real（整点全量）、change（变化）、callack、setack |
| 上行 | `/d2/${sn}` | 本机参数：callack、setack、change |
| 上行 | `/dr/${sn}` | 断点续传 |
| 上行 | `/dh/${sn}` | 历史数据 |
| 上行 | `/dcr/${sn}` | 控制应答（indexRealAck 等） |
| 下行 | `/s/${sn}` | call（查 DI/DO）、set（写 DO） |
| 下行 | `/scr/${sn}` | indexReal（快速上报）、his、ctr |
| 下行 | `/s2/${sn}` | 本机参数 call/set、ota 固件升级 |

### 默认 DI/DO MQTT tag

| 通道 | DI tag | DO tag | Modbus PDU 地址 |
|------|--------|--------|----------------|
| CH1 (a) | `di_a` | `do_a` | 600 / 800 |
| CH2 (b) | `di_b` | `do_b` | 601 / 801 |
| CH3 (c) | `di_c` | `do_c` | 605 / 805 |
| CH4 (d) | `di_d` | `do_d` | 606 / 806 |

### ⚠️ 改 tag 名注意事项

DI/DO 的 MQTT tag 定义**分散在两个文件里，必须同步改**：

1. **上报 tag** — [wireless/mqtt/protocol/report.lua](wireless/mqtt/protocol/report.lua) 的 `DI_POINTS` / `DO_POINTS` 表
2. **下行控制 tag** — [wireless/mqtt/protocol/down.lua](wireless/mqtt/protocol/down.lua) 的 `DI_TAG_TO_CH` / `DO_TAG_TO_CH` 表

**额外风险点**：`report.lua` 的 `read_point()` 用 tag 前缀 `pt.tag:sub(1, 2) == "di"` 判断读 DI 还是 DO。

如果新 tag 前缀不再是 `di_` / `do_`（比如改成 `DI1`、`DO1`），需要同步修改这个判断逻辑。如果 tag 完全不带类型前缀（比如 `CH1`、`CH2`），建议把前缀判断改成**用 `report.lua` 里的 ALL_POINTS 表查类型**，而不是靠字符串匹配。

### 遗留 TODO

- `basic.lua` broker 地址和账密现在写的是 EMQX 公共测试服务器，**部署前必须替换**
- `config.lua` 的 `/gateway_cfg.json` 如果是从 ext 工程遗留的旧文件，手动删除让它重建（或 MQTT 下发 `sys_action: factoryReset`）
- `net_watchdog` 默认注释，调试稳定后再开启

## 硬件注意事项

### DI 默认读 1 的原因（非 Bug）

`di.lua` 配置了 `gpio.PULLUP` 内部上拉。**DI 通道悬空未接信号时被上拉到 1**，只有外部短接才拉低到 0。工业干接点 + 上拉是标准做法。

如果希望未接时读 0，改成 `gpio.PULLDOWN`（但接线时要注意外部触点逻辑会反转）。

### DO_CH2 (GPIO3) 与 UART0 TX 冲突

DO_CH2 用的 GPIO3 同时是 Air780EHV 的 UART0 TX（USB 调试串口）。LuatOS 内核可能在初始化后重新配置此引脚，导致 `gpio.get(3)` 读值不受 DO 控制。

**风险表现**：上电后只有 DO_CH2 读数异常（应为 0 却读成 1），其余 3 路正常。

**解决办法**：
1. 在 `do.lua` 最后或 `main.lua` 所有 `require` 完成后，再次 `gpio.setup(3, 0, gpio.PULLDOWN)` 强占
2. 或在硬件上换一个 GPIO 给 DO_CH2

## 模块说明

### led_blink.lua

板载 NET LED (GPIO27) 闪烁，100ms 亮 / 100ms 灭。

### di.lua — 4路 DI 输入采集

- 光耦隔离干接点输入，**COM 与 IN 短接时触发**
- 内部上拉输入模式 (gpio.PULLUP)
- 仅提供 `di_get(ch)` 接口，不主动打印日志；状态变化通过 MQTT change 上报

**对外接口：**

```lua
local di = require("di")
local val = di.di_get(1)   -- 读取 CH1 状态, 返回 0 或 1
```

**接线方式：**

```
COM ────── CHx  (短接时该通道触发 → 读 0；悬空被上拉 → 读 1)
```

### do.lua — 4路 DO 继电器控制

- 继电器输出，**GPIO22 使能脚需保持高电平**
- 上电默认全关（初始值 0），不自动循环测试

**对外接口：**

```lua
local do_ctrl = require("do")
do_ctrl.do_set(1, 1)      -- CH1 继电器吸合
do_ctrl.do_set(2, 0)      -- CH2 继电器断开
local v = do_ctrl.do_get(1) -- 读取 CH1 当前状态
```

## 开发规范

- 所有业务代码放在 `function/` 目录下
- `require` 调用不带路径前缀，开发工具已配置好搜索路径
- Lua local 函数必须先定义后使用
- `gpio.setup(pin, nil, pull)` — 输入模式
- `gpio.setup(pin, val, pull)` — 输出模式 (val 为初始值)

## 烧录

1. 合宙 LuatOS 开发板连接 USB
2. 打开 LuatOS Studio / 合宙 IDE
3. 选择对应 COM 口和 Air780EHV 固件
4. 将 `main.lua` 和 `function/` 目录烧录到设备

## 版本历史

| 日期 | 说明 |
|------|------|
| 2026-11-11 | 初始化工程：LED 闪烁 + DI 采集 + DO 继电器 |
| 2026-11-17 | 从 ext (Air780EPM 热泵网关) 移植 4G/NTP/MQTT/OTA 协议栈；目录重组为 data/ device/ wireless/ function/；DI/DO 直接驱动 GPIO，去掉 Modbus 主站轮询和 store 缓存层 |
