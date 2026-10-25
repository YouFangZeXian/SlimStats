# 资源开销、采集策略与统计边界

[中文主页](../README.md) · [English README](../README.en.md) · [English summary](#english-summary)

## 低占用具体指什么

SlimStats 把低开销作为设计方向：只监测内存与储存空间，以原生 Swift + AppKit 实现，不引入第三方依赖，也不维持后台全盘索引。它不承诺适用于所有设备、所有界面和所有扫描范围的固定 MB 数值。

截至当前 1.3 build 11，**全部使用状态 RSS <100 MB 的目标仍未通过验证，早期 RSS ≤50 MB 的目标也未达成**。这些是优化目标，不是已完成的产品指标。历史开发短测包含纯菜单栏约 75–80 MiB RSS、打开多个页面或扫描后超过 100 MiB 的样本；它们来自不同构建和系统缓存状态，不是本版本统一、长期、可比较的性能基准，因此不作为主页宣传数字。

## 当前设计

| 路径 | 控制开销的方式 |
| --- | --- |
| 菜单栏 | 按所选间隔采集内存；显示内容不变时不重建读数图片 |
| 内存历史 | 仅内存保留 120 点，不写入历史数据库 |
| 应用排行 | 详情可见且排行开启时才采集；至少间隔 5 秒，使用 libproc API，不调用 `ps` / `top` 子进程 |
| 磁盘容量 | 只在需要显示时后台查询，缓存 60 秒；低占用组合下缓存 300 秒 |
| 详情与设置 | 按需创建，关闭后释放自有控制器、视图和扫描结果 |
| 图片与图标 | 使用预生成的小位图，避免运行时加载完整多尺寸图标资源 |
| 目录扫描 | 手动触发，后台遍历文件元数据，不建立持久索引 |

关闭视图后，macOS 框架和绘图缓存仍可能保留页面。系统压缩、换出和回收也会改变 RSS；关闭窗口不保证数值立即恢复到冷启动状态。

## 推荐配置

- 默认使用 5 秒内存间隔；优先减少开销时用「应用低占用设置」（10 秒、关闭排行）。
- 只需大致读数时可选 30 秒；临时排查时再切到 1 或 3 秒。
- 目录扫描从较小范围开始，需要时逐层检查。大范围扫描会临时增加 I/O、CPU 和内存。
- 不再查看结果时关闭设置窗口。历史点数不随运行时长无限增长，减慢刷新不会让占用按比例减少。

## 如何复核内存开销

| 指标 | 解释与限制 |
| --- | --- |
| RSS | 当前驻留页；可能包含共享页，会受系统页回收、压缩和换出影响 |
| physical footprint | 另一种进程内存计量，不能替代 RSS 来判定 RSS 目标 |
| 活动监视器「内存」 | 保留系统显示口径，记录主程序及可见的关联界面服务；不直接等同 RSS |

在项目根目录运行，把 `12345` 替换为实际 SlimStats PID（可从活动监视器查看）：

```sh
xcrun swift verify/measure-process.swift 12345 30
```

脚本按秒采样，输出 RSS 和 footprint 的中位数/最大值及单核心口径平均 CPU。它只测指定进程，**不会自动汇总关联服务**，30 秒也不能代表长期稳定性。

至少分开记录以下场景，避免只选最低值：

1. 刚启动，仅菜单栏，记录刷新间隔及排行开关。
2. 展开详情并等待应用排行加载。
3. 打开仪表盘、内存、磁盘和通用设置各页。
4. 扫描一个注明范围和文件规模的目录，观察扫描中与结束后。
5. 关闭全部页面后继续采样，并进行更长时间的运行观察。

报告需注明 app build、macOS、硬件、时长、UI 状态、扫描范围及是否经历缓存回收。界面探针 `python3 verify/profile-ui.py --full` 使用临时副本并打开测试窗口，可能读取现有偏好；它不证明实际菜单栏位置、登录启动或全盘扫描峰值。

## 磁盘扫描边界

- 按已分配空间 `st_blocks × 512` 计量，不是文件逻辑长度；只检查文件元数据。
- 不跟随符号链接，不跨挂载卷，不主动下载云端占位文件。
- 硬链接去重集合最多 20,000 项；超过上限标记受限，可能出现重复计数。
- 根目录子项最多保留 4,096 个独立汇总桶，超出部分合并；界面最多显示前 100 项。
- 大文件只保留前 30 项。遍历仍需要当前目录的临时内存，结果有上限不代表整个扫描过程有固定内存上限。
- 权限拒绝、读取失败、停止扫描和结果合并都会标记。APFS 克隆共享块、系统快照、系统保留空间及范围差异会使结果与全盘已用容量不同。
- 结果只留在内存；关闭设置取消扫描并释放结果。不包含文件删除功能。

## English summary

Low overhead is a design goal, supported by a narrow feature scope, native AppKit, bounded history, on-demand process collection, and manual directory scans. It is **not** a fixed memory promise. RSS below 100 MB in all states remains unverified; the original ≤50 MB RSS goal has not been achieved. Historical short samples span about 75–80 MiB for menu-only use and over 100 MiB after UI/scan activity across different builds and cache states. These are not a standardized benchmark of build 11.

Measure the actual process with `xcrun swift verify/measure-process.swift 12345 30`, replacing `12345` with its PID. Record app build, OS, hardware, interval, ranking setting, UI state, scan scope, and duration. Measure menu-only, details, each settings page, scanning, and after-close states separately. The script reports RSS, physical footprint, and CPU for one process; record associated UI services separately in Activity Monitor. Do not interchange the metrics or present a short sample as a long-term guarantee.

Directory scans count allocated blocks, skip symlinks, stay on one volume, and do not intentionally download cloud placeholders. They retain at most 100 displayed entries and 30 largest files, with 4,096 separate child buckets and a 20,000-entry hardlink deduplication set. Limits, permission errors, and cancellation produce marked partial/limited results. APFS clones, snapshots, system reservations, and scope prevent equivalence with whole-disk used capacity. Bounded results do not guarantee a fixed traversal memory peak.
