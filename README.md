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
├── function/                -- 业务模块目录
│   ├── led_blink.lua        -- LED 闪烁任务
│   ├── di.lua               -- 4路 DI 采集模块
│   └── do.lua               -- 4路 DO 继电器控制模块
└── extra/                   -- 官方 Demo (已被 gitignore 忽略)
```

## 模块说明

### led_blink.lua

板载 NET LED (GPIO27) 闪烁，100ms 亮 / 100ms 灭。

### di.lua — 4路 DI 输入采集

- 光耦隔离干接点输入，**COM 与 IN 短接时触发**
- 100ms 轮询一次，串口打印通道状态
- 内部上拉输入模式 (gpio.PULLUP)

**对外接口：**

```lua
local di = require("di")
local val = di.di_get(1)   -- 读取 CH1 状态, 返回 0 或 1
```

**接线方式：**

```
COM ────── CHx  (短接时该通道触发)
```

### do.lua — 4路 DO 继电器控制

- 继电器输出，**GPIO22 使能脚需保持高电平**
- 上电后循环测试：CH1 开 → CH2 开 → CH3 开 → CH4 开，每个保持 2s

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
