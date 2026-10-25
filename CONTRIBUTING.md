# 参与 SlimStats / Contributing

项目范围是原生 macOS 菜单栏的内存与磁盘监测，优先关注低开销、信息准确、可配置采样及清晰的系统交互。

## 报告问题与建议

在 [Issues](https://github.com/YouFangZeXian/SlimStats/issues) 中使用缺陷或建议模板。内存占用问题请附上 app build、macOS、芯片、刷新间隔、排行开关、页面状态、扫描范围、测量工具和持续时间。截图请隐藏设备序列号、用户名、个人路径和其他敏感信息。

较大的功能、依赖或架构改动建议先讨论。CPU/GPU、温度、风扇、网络等实时监测模块不在当前范围内；设备仪表盘的静态概览不改变这一边界。

## 本地开发

需要 Apple Silicon、macOS 14+ 和 Xcode 命令行工具。构建无需 Xcode 工程或第三方包管理器：

```sh
./build.sh
```

主要源码：`main.swift`（采集、菜单栏、详情和设置）、`AppActions.swift`（退出应用）、`DiskUsageScanner.swift` / `DiskUsageView.swift`（空间检查）、`DeviceInfo.swift`（设备信息）、`LightButton.swift`（轻量控件）。

## 验证与提交

- 文档改动检查链接、命令和当前实现是否一致，无需运行 UI 测试。
- 涉及启动、点击或设置生命周期：`python3 verify/menu-bar-tests.py`。
- 涉及退出应用：`python3 verify/app-actions-tests.py`；脚本会创建并关闭自己的临时测试程序。
- 资源开销变化按 [PERFORMANCE.md](docs/PERFORMANCE.md) 分场景测量，分别报告 RSS 与 footprint，不用单次最低值证明达标。
- 提交时描述问题、最终行为和实际验证结果；不要附带生成的 `.app`、本机日志、截图中的序列号或个人路径。

构建、UI 探针和运行程序的测试需要 macOS 图形会话，部分测试会打开临时窗口。不要把逻辑测试通过当作菜单栏视觉、登录启动或长期内存目标已经验证。

## English

Contributions should keep SlimStats focused on memory and storage monitoring with native macOS UI and low overhead. Discuss major features or dependencies first; additional live monitoring modules are outside the current scope.

Build with `./build.sh` on Apple Silicon/macOS 14+ with Xcode Command Line Tools. Use the relevant scripts above for menu lifecycle and quit-action changes. UI tests require a graphical macOS session and may open temporary windows; the quit-action test creates and closes its own fixtures. Documentation-only changes need link/command checks rather than UI tests.

For memory reports, include build, OS, hardware, interval, rankings, UI/scan state, duration, and metric. Keep RSS and physical footprint separate. Redact serial numbers and personal paths. Pull requests should explain the problem, resulting behavior, and validation. Keep generated bundles and local results out of Git.

Contributions are made under the repository's [MIT License](LICENSE).
