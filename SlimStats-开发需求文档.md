# SlimStats 开发需求文档

> 这是历史开发需求，包含早期设想、已被后续澄清替代的规格和未达成的资源目标。当前功能与使用方式请看 [README](README.md)，资源开销与测量边界请看 [PERFORMANCE.md](docs/PERFORMANCE.md)。本文中的预估内存数值不作为产品性能承诺。

> 版本 v1.0 ｜ 2026-10-16 ｜ 目标接手方：开发 / 编码 Agent
> 项目目录：本仓库根目录

---

## 2026-10-16 用户最新澄清（优先于下文原始规格）

1. 最新启动方式见第 15 条：仅菜单栏常驻，无 Dock；设置仍为独立窗口。
2. 顶部菜单栏始终显示两行实时内存数据：`F: 空闲 GB` / `U: 已用 GB`。
3. 点击菜单栏数字，在该位置下方显示原生下拉详情；详情右上角齿轮进入设置窗口。
4. 设置仅保留仪表盘、内存、磁盘、通用设置；刷新频率、菜单栏显示和登录启动开关须可用。仪表盘展示设备概览，与内存页独立。
5. 详情中应用按 RSS 从高到低列出，按最外层 app bundle 合并 helper。点击应用图标显示 ×；点击名称取消，再点图标重新显示 ×。点击 × 后弹窗确认，取消不执行；确认后先正常退出，5 秒未退出则强制退出并核查结果。弹窗提示未保存内容可能丢失。
6. 关闭设置窗口后监测继续运行；再次启动应用重新打开设置。
7. macOS 系统设置「菜单栏 → 允许在菜单栏显示 → SlimStats」必须开启；应用内开关不能覆盖系统禁用。
8. 内存采用 Stats 的 active + inactive + speculative + wired + compressed - purgeable - external 口径；App = used - wired - compressed；F = total - used。下文原始公式已被此次实现取代。
9. 储存容量按显示需求在后台刷新（普通缓存 60 秒，低占用配置 300 秒）；进程仅在详情打开时异步采集，间隔至少 5 秒；历史保留最近 120 点。内存间隔可选 1/3/5/10/30 秒。
10. 磁盘页增加手动只读排行，支持目录汇总、大文件、逐层检查及 Finder 定位，不做删除。
11. 关闭设置或详情释放界面；一键低占用配置为 10 秒内存刷新并关闭应用排行。
12. 用户新增低于 100 MB 的优化诉求；同时保留原始 RSS 门槛，必须分别记录 RSS、physical footprint、活动监视器主进程及关联服务，不混用口径宣称达标。低内存目标继续保留为验收门槛，当前 UI 功能完成不等于 RSS ≤ 50 MB 已达标。可使用 `verify/` 中的脚本进行本机复核。

13. 仪表盘显示与构建机器真实型号对应的彩色立体设备图片，参考用户的 Stats 截图；保持按需加载及低占用。

14. 应用程序使用截图中的蓝底白色内存芯片图标；修复空白占位图。Dock 显示要求已被第 15 条取代。继续以真实 RSS 检查使用过程中的占用，不能只报告冷启动，不能用修改统计口径或系统压缩后的低值宣称通过。

15. 用户最新要求：不常驻 Dock，仅顶部 F/U 常驻。左键 F/U 展开详情，右键（或 Control + 左键）F/U → 设置；普通/登录启动不自动打开设置。设置窗口打开期间也不显示 Dock 图标。

以下为原始需求记录；出现冲突时以以上最新澄清为准。

---

## 0. 一句话需求

写一个 **macOS 菜单栏常驻小工具**，菜单栏显示内存占用（样式与 Stats 一致），点开面板显示内存明细、负载历史、高占用进程和磁盘储存情况；**常驻内存 ≤ 50 MB**（目标 20~30 MB）。

---

## 1. 背景与前期调研结论（为什么不用现成的）

| 方案 | 实测结果 | 结论 |
| --- | --- | --- |
| **Stats.app**（eu.exelban.Stats 3.0.21） | 配置早已精简：CPU / GPU / 传感器 / 网络 / 电池 / 蓝牙 / 时钟模块全部关闭，仅保留 RAM + Disk；**RSS 仍达 160~220 MB** | ❌ 架构底子太重（持续采样进程列表 + 图表历史 + 传感器框架），压不到 50 MB |
| **LiteStats.app**（com.litestats.app 1.0，752 KB） | 稳定后 **RSS ≈ 80 MB**；支持内存/CPU/电池/高占用通知；**无 Stats 式详情面板**（无分色条、无负载曲线、无储存模块） | ❌ 内存不达标且功能不足，不值得二次开发 |
| **自研**（本方案） | 纯 AppKit + 按需采样，预估 **RSS 20~30 MB** | ✅ 采用 |

用户明确要求：**第一版必须同时包含「内存」与「储存」**。

---

## 2. 目标 / 非目标

### 2.1 必做（Must）
1. 菜单栏常驻显示内存占用文本，**样式与 Stats 菜单栏一致**（示例：`10.52 GB`）。
2. 点击展开面板，内容对齐 Stats「内存」详情页的信息结构（见 §5）。
3. 面板内含**储存（磁盘）**信息。
4. 常驻内存（RSS）≤ 50 MB；稳定运行后应落在 20~30 MB。
5. 开机自启动开关 + 退出按钮。
6. 无 Dock 图标、无主窗口，纯菜单栏属性（`LSUIElement = true`）。

### 2.2 不做（Non-Goals）
CPU、GPU、风扇、温度传感器、网络速率、电池、蓝牙、时钟、天气等一切其他模块 —— **第一版一律不做**，不要预留重型框架。
历史数据不做磁盘持久化（仅内存环形缓冲）。

---

## 3. 技术选型与硬约束

| 项 | 要求 |
| --- | --- |
| 语言 / UI | **Swift + AppKit（NSStatusItem + NSMenu 自定义视图）**。❗禁用 SwiftUI：它会常驻较多内存 |
| 最低系统 | macOS 13（`SMAppService` 需要 13+；开发机为 macOS 27 SDK / Xcode 27，建议部署目标 14.0 更稳） |
| 构建方式 | 单文件 `swiftc` 直编，**无需 Xcode 工程**（也可给 Xcode 工程，但必须能命令行一键编译） |
| 依赖 | 只用系统框架：`AppKit`、`Darwin`、`ServiceManagement`。**禁止第三方依赖** |
| 采样频率 | 内存/磁盘：**3 秒**；进程列表：**仅在面板打开时**采集（这是 Stats 吃内存的主因） |
| 线程 | 进程列表采集放到后台队列（`DispatchQueue.global`），结果回主线程刷新 UI，避免阻塞菜单 |
| 开销 | 禁止起 `ps`/`top` 子进程（fork + 解析开销大）。一律用 libproc / mach API |
| 历史缓冲 | 内存内保留最近 **120 个采样点**（约 6 分钟），超出丢弃最旧的 |

---

## 4. 数据采集口径（**已在目标机验证，字段名可用**）

> 验证脚本：`SlimStats/verify/probe.swift`（已编译通过并跑出正确数值，见 §9 实测输出）。接手方可直接对照实现。

### 4.1 内存（核心）

- 接口：`host_statistics64(mach_host_self(), HOST_VM_INFO64, ...)` → `vm_statistics64_data_t`
- 页大小：`host_page_size()` 动态获取 —— ❗**不要写死 4096**（Apple Silicon 为 16384）
- 关键字段（注意第一个已被踩坑确认）：

| 语义 | 字段 | 说明 |
| --- | --- | --- |
| 空闲 | `free_count` | |
| 非活跃 | `inactive_count` | |
| 可清除 | `purgeable_count` | |
| 推测 | `speculative_count` | |
| 应用内存页 | `internal_page_count` | 需减去压缩部分 |
| 联动内存 | `wire_count` | |
| 压缩内存 | **`compressor_page_count`** | ⚠️ **不是** `compressed_page_count`（该字段不存在，编译会报错） |

- 计算公式（与 Stats 展示口径对齐）：

```
total       = ProcessInfo.processInfo.physicalMemory
available   = (free + inactive + purgeable + speculative) * pageSize
used        = total - available
app         = internal * pageSize - compressor * pageSize
wired       = wire * pageSize
compressed  = compressor * pageSize
```

### 4.2 交换区

```
mib = [CTL_VM, VM_SWAPUSAGE]
sysctl(&mib, 2, &xsu, &size, nil, 0)   // xsu: xsw_usage
swapUsed = xsu.xsu_used                 // 0 → 显示 "0 KB"
```

### 4.3 磁盘储存

```
let url = URL(fileURLWithPath: "/")
url.resourceValues(forKeys: [.volumeTotalCapacityKey,
                             .volumeAvailableCapacityForImportantUsageKey])
used = total - free
```
> 注意：`/` 是只读系统卷，`volumeTotalCapacityKey` 返回的是数据卷容量，与「关于本机」显示一致即可，不要求逐字节吻合。

### 4.4 高占用进程

```
proc_listallpids(nil, 0)                        // 先取数量
proc_listallpids(&buf, n * sizeof(pid_t))       // 再取列表
proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, &ru)  // ru.ri_resident_size = RSS
proc_pidpath(pid, buf, MAXPATHLEN)              // 取可执行文件路径
```

- 名称取路径 `lastPathComponent`。
- ❗**必须做分组聚合**：同一 App 的多个 helper（如 `Microsoft Edge Helper (Renderer)` / `Microsoft Edge Helper` / `Microsoft Edge`）在 Stats 里是合并为一行 `Microsoft Edge` 的。建议按「主 App bundle 名」或名称前缀归并后累加 RSS。
- 过滤阈值 RSS > 20 MB；排序取 **Top 8**。
- 跳过 `pid <= 0`。

---

## 5. UI 规格

### 5.1 菜单栏（必须与 Stats 一致）

- 文本：已用内存，两位小数 + `GB`，例：`10.52 GB`（Stats 默认 memory widget 样式）。
- 字体：**等宽数字**（`monospacedDigitSystemFont(ofSize: 12)`），避免数字变化导致图标宽度抖动。
- 颜色：跟随系统（浅色主题深字、深色主题浅字），不要硬编白色。
- 点击展开面板；不做右键二级菜单以外的额外交互（右键可留空）。

### 5.2 下拉面板（宽约 300 pt，垂直布局，内边距 12~14 pt）

自上而下顺序（对齐 Stats 截图）：

1. **负载历史** —— 分隔标题 + 面积图，高度 64 pt，画最近 120 个点的「已用占比」曲线（0~100%），填充色用强调蓝（`controlAccentColor` 或 `#007AFF`），圆角裁切。
2. **详细信息**
   - `已用` 行：右侧显示总值，加粗（例 `11.02 GB`）
   - **四段分色条**（高 6~8 pt，圆角），按占比从左到右分段：
     | 段 | 颜色 | 值 |
     | --- | --- | --- |
     | App 内存 | 蓝 `#007AFF` | app |
     | 联动内存 | 橙 `#FF9500` | wired |
     | 压缩内存 | 红 `#FF3B30` | compressed |
     | 可用 | 灰 `#B0B0B5` | available |
   - 四行图例：彩色圆点 + 名称 + 右对齐数值（App 内存 / 联动内存 / 压缩内存 / 可用）
   - `交换区` 行：值为 0 时显示 `0 KB`
3. **高占用进程** —— 标题 + Top 8 列表（左：进程名，右：用量，格式 `1.82 GB` / `789.6 MB`，≥1 GB 用 GB 单位）
4. **储存** —— 标题 + 分色条（已用 / 可用）+ 文字：`已用 172 GB / 共 245 GB，剩余 73 GB`
5. **底部操作** —— `开机自启动`（勾选态跟随 `SMAppService.mainApp.status`）、`退出 SlimStats`

### 5.3 刷新策略

- 面板关闭：只更新菜单栏文本 + 历史缓冲（3 s 一次，开销可忽略）。
- 面板打开：同步刷新内存/磁盘区块；进程列表异步刷新。
- 面板打开期间不阻塞主线程，卡片数值就地更新即可。

---

## 6. 打包与交付

### 6.1 产物结构

```
SlimStats.app/
└── Contents/
    ├── Info.plist
    └── MacOS/
        └── SlimStats        # 可执行文件
```

### 6.2 Info.plist 关键键

```xml
<key>CFBundleExecutable</key><string>SlimStats</string>
<key>CFBundleIdentifier</key><string>local.slimstats.app</string>
<key>CFBundleName</key><string>SlimStats</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSUIElement</key><true/>                  <!-- 无 Dock 图标 -->
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
```

### 6.3 编译 & 签名命令

```bash
cd <项目目录>
xcrun swiftc -O -framework AppKit -framework ServiceManagement \
  main.swift -o SlimStats.app/Contents/MacOS/SlimStats
codesign --force --deep -s - SlimStats.app        # ad-hoc 签名，本地自用足够
open SlimStats.app
```

> 编译告警 `could not load macro '_SwiftifyImport'` 属 SDK 头文件噪声，可忽略。

### 6.4 开机自启动

```swift
import ServiceManagement
if #available(macOS 13.0, *) {
    try? SMAppService.mainApp.register()     // 取消：unregister()
}
```
> 建议把 app 放进 `/Applications` 再开启自启，否则移动目录后注册会失效。

---

## 7. 验收标准（可量化，逐条验证）

| # | 验收项 | 方法 | 通过标准 |
| --- | --- | --- | --- |
| 1 | 常驻内存 | 启动 10 分钟后 `ps -o rss= -p $(pgrep SlimStats)` | **≤ 50 MB**（目标 20~30 MB） |
| 2 | 空闲 CPU | `top -l 3 -pid $(pgrep SlimStats)` 观察 | < 0.5% |
| 3 | 数值准确性 | 与 Stats 面板同时对比 | 已用/分项误差 ≤ 0.1 GB 或 ±5% |
| 4 | 菜单栏显示 | 肉眼比对 Stats | 文本格式、字体、位置观感一致 |
| 5 | 面板完整性 | 点开面板 | 历史曲线、4 段分色条、4 项图例、交换区、Top 8 进程、磁盘条齐备 |
| 6 | 进程聚合 | 开 Edge 多进程后查看 | helper 合并为一行，数值为合计 |
| 7 | 稳定性 | 连续运行 2 小时 | 无崩溃、无内存持续增长（RSS 波动 < 5 MB） |
| 8 | 冷启动 | 双击启动 | 菜单栏 1 秒内出现 |

---

## 8. 风险与注意事项

1. **RSS 口径争议**：`ps` 的 RSS 包含共享库，可能比 Xcode 内存图高。验收以 §7 第 1 条的 `ps` 命令为准；若嫌不够低，优先砍掉的是「历史曲线绘制频率」而非功能。
2. **页大小**：Apple Silicon 上必须动态取 `host_page_size()`，写死 4096 会导致数值整体偏小 4 倍。
3. **进程名聚合**：不做聚合会导致面板被 Edge/Chrome 的十几个 helper 刷屏，与 Stats 观感不符。
4. **菜单栏抖动**：数值宽度会随位数变化，务必用等宽数字字体；如仍有抖动，固定为 1 位小数。
5. **不要在定时器里采进程列表**：这是 Stats 220 MB 的元凶之一，务必保持「仅面板打开时采集」。
6. **不引入 SwiftUI / Combine / Charts 框架**：Charts 会显著抬高常驻内存，历史曲线用 `NSBezierPath` 手绘即可。
7. **面板自定义视图**：`NSMenu` + `NSMenuItem.view` 承载自定义 NSStackView；注意视图宽度需显式约束（300 pt），否则可能出现 0 宽。

---

## 9. 附录：已验证的数据采集参考代码与实测输出

参考实现：`SlimStats/verify/probe.swift`（**已编译通过**，可直接复用其中的采集函数，仅需把输出改为返回值）。

关键代码骨架：

```swift
func hostPageSize() -> UInt64 {
    var ps: vm_size_t = 0
    host_page_size(mach_host_self(), &ps)
    return UInt64(ps)
}

func readMemory() -> MemInfo {
    var vmstat = vm_statistics64_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &vmstat) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
        }
    }
    guard kr == KERN_SUCCESS else { return MemInfo() }
    let ps = hostPageSize()
    // ... 按 §4.1 公式计算
}

func topProcesses(_ n: Int) -> [ProcInfo] {
    let count = proc_listallpids(nil, 0)
    var pids = [pid_t](repeating: 0, count: Int(count))
    let got = pids.withUnsafeMutableBufferPointer {
        proc_listallpids($0.baseAddress, Int32($0.count * MemoryLayout<pid_t>.size))
    }
    var out: [ProcInfo] = []
    for pid in pids.prefix(Int(got)) where pid > 0 {
        var ru = rusage_info_current()
        let rc = withUnsafeMutablePointer(to: &ru) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, $0)
            }
        }
        guard rc == 0, ru.ri_resident_size > 20 * 1024 * 1024 else { continue }
        // ... proc_pidpath 取名字，按 §4.4 聚合并排序
    }
    return out
}
```

**目标机实测输出（验证通过，可与 Stats 面板对照）：**

```
physical total : 16.00 GB
used           : 11.02 GB  (69%)
app(internal-c): 2.82 GB
wired          : 2.96 GB
compressed     : 2.98 GB
available      : 4.98 GB
swap used      : 0.00 GB
disk total: 245 GB, free: 73 GB, used: 172 GB
--- top processes ---
Microsoft Edge Helper (Renderer)   1525.7 MB
Electron                            839.4 MB
WorkBuddy Helper (Renderer)         463.6 MB
...
```

> 说明：上图进程列表**未做聚合**，所以 Edge 的 helper 是分开显示的 —— 正式实现必须按 §4.4 聚合。

---

## 10. 交接清单

- [ ] 按 §3 选型，单文件或 Xcode 工程均可，但必须保留 §6.3 的命令行构建能力
- [ ] 实现 §4 四个数据采集函数（可直接复用 `verify/probe.swift`）
- [ ] 按 §5 完成菜单栏 + 面板 UI，配色照 §5.2 表格
- [ ] 按 §6 打包出 `SlimStats.app`，附 `Info.plist`
- [ ] 逐条跑 §7 验收表，输出验收数据（RSS / CPU / 数值对比截图）
- [ ] 交付源码 + 编译好的 .app + 验收记录

---

*附：调研阶段用过的现成应用现状 —— `Stats.app` 与 `LiteStats.app` 目前仍装在 `/Applications`，可保留用于数值比对；确认自研版本稳定后建议卸载 Stats 以释放 220 MB 内存。*
