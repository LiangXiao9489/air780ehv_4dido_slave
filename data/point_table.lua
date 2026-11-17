--[[
@module  point_table
@summary 板卡点位定义（唯一权威源，类似 ext 版的 point_table.lua）
@version 1.0
@date    2026.11.17
@usage
一张表驱动三端，所有关系定义在这里：
  1. MQTT 上行/下行 → 用 tag 字段
  2. Modbus RTU 从站 → 用 n_addr（PDU 地址）+ reg_type
  3. 本机硬件驱动 → 用 ch（GPIO 通道号）

字段说明（尽量对齐 ext 版 point_table.lua 的命名）：
- tag         MQTT JSON key（上行上报 + 下行 call/set 统一用）
- reg_type    Modbus 功能码数字：1=线圈 2=离散输入 3=保持寄存器 4=输入寄存器
- n_addr      Modbus PDU 地址（从站应答地址，ext 版叫 n_addr 即上行/响应地址）
- ch          本机 GPIO 通道号（1~4，对应 di.lua / do.lua 的 ch 参数）
- rw          "r" 只读 / "rw" 读写（ext 惯例：reg_type=2/4 强制只读）
- data_type   （预留）本地计算物理量用，不影响协议映射
- scale_factor （预留）原始值 × scale_factor = 实际值

运行时自动生成的索引（report.lua / down.lua / mapping_modbusRTU.lua 都从这里拿）：
  TAG_TO_POINT      [tag]       → point 完整表
  DI_TAG_TO_CH      [tag]       → ch         （MQTT down.lua 校验写入权限）
  DO_TAG_TO_CH      [tag]       → ch         （MQTT down.lua 写 DO）
  DI_ADDR_TO_CH     [n_addr]    → ch         （Modbus 从站 DI 查硬件通道）
  DO_ADDR_TO_CH     [n_addr]    → ch         （Modbus 从站 DO 查硬件通道）
  DI_ADDR_TO_TAG    [n_addr]    → tag        （Modbus 从站 → MQTT tag 透传用）
  DO_ADDR_TO_TAG    [n_addr]    → tag        （同上）

注意：改 tag / n_addr / ch 只改这一个文件，所有引用自动同步。
]]

-- ============================================================
-- 点位定义
-- ============================================================
local POINTS = {
    -- ===== DI：离散输入 (reg_type=2, FC 0x02)，只读 =====
    { tag = "di_a", reg_type = 2, n_addr = 600, ch = 1, rw = "r" },
    { tag = "di_b", reg_type = 2, n_addr = 601, ch = 2, rw = "r" },
    { tag = "di_c", reg_type = 2, n_addr = 605, ch = 3, rw = "r" },
    { tag = "di_d", reg_type = 2, n_addr = 606, ch = 4, rw = "r" },

    -- ===== DO：线圈 (reg_type=1, FC 0x01/05/0F)，可读写 =====
    { tag = "do_a", reg_type = 1, n_addr = 800, ch = 1, rw = "rw" },
    { tag = "do_b", reg_type = 1, n_addr = 801, ch = 2, rw = "rw" },
    { tag = "do_c", reg_type = 1, n_addr = 805, ch = 3, rw = "rw" },
    { tag = "do_d", reg_type = 1, n_addr = 806, ch = 4, rw = "rw" },
}

-- ============================================================
-- 运行时索引构建（模块加载时自动生成，三处共用）
-- ============================================================

-- tag → point（所有类型）
local TAG_TO_POINT = {}

-- MQTT 用：tag → ch（按类型分，down.lua 校验读写权限）
local DI_TAG_TO_CH = {}
local DO_TAG_TO_CH = {}

-- Modbus 从站用：PDU 地址 → ch / tag
local DI_ADDR_TO_CH    = {}
local DO_ADDR_TO_CH    = {}
local DI_ADDR_TO_TAG   = {}
local DO_ADDR_TO_TAG   = {}

for _, p in ipairs(POINTS) do
    TAG_TO_POINT[p.tag] = p

    if p.reg_type == 2 then
        -- 离散输入 → DI
        DI_TAG_TO_CH[p.tag]     = p.ch
        DI_ADDR_TO_CH[p.n_addr] = p.ch
        DI_ADDR_TO_TAG[p.n_addr] = p.tag
    elseif p.reg_type == 1 then
        -- 线圈 → DO
        DO_TAG_TO_CH[p.tag]     = p.ch
        DO_ADDR_TO_CH[p.n_addr] = p.ch
        DO_ADDR_TO_TAG[p.n_addr] = p.tag
    end
end

return {
    -- 顺序遍历
    POINTS          = POINTS,

    -- tag 查 point
    TAG_TO_POINT    = TAG_TO_POINT,

    -- MQTT down.lua 用
    DI_TAG_TO_CH    = DI_TAG_TO_CH,
    DO_TAG_TO_CH    = DO_TAG_TO_CH,

    -- Modbus mapping_modbusRTU.lua 用
    DI_ADDR_TO_CH   = DI_ADDR_TO_CH,
    DO_ADDR_TO_CH   = DO_ADDR_TO_CH,
    DI_ADDR_TO_TAG  = DI_ADDR_TO_TAG,
    DO_ADDR_TO_TAG  = DO_ADDR_TO_TAG,
}
