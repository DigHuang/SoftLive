# 系统监控

## 职责与事实来源

[`SystemMonitor`](../../Sources/SoftLive/Monitor/SystemMonitor.swift) 按 2 秒周期采样核心系统指标并维护 60 秒滚动历史队列（30 个样本点：`cpuHistory`、`memoryHistory`、`thermalHistory`），分别发布状态栏轻量快照 `metrics` 与弹窗详情快照 `detailMetrics`（类型均为 [`SystemMetrics`](../../Sources/SoftLive/Monitor/SystemMetrics.swift)），供状态栏 [`MonitorStatusBar`](../../Sources/SoftLive/UI/StatusBar/MonitorStatusBar.swift) 与 Liquid Glass 详情面板 [`MonitorPopoverView`](../../Sources/SoftLive/UI/StatusBar/MonitorPopover.swift) 渲染。全部位于用户态，不需要 root 权限、辅助功能权限或后台 Helper。

| 指标 | 内核 / 系统接口 | 计算方式与过滤规则 | 本机实测（Apple M4 · 10 核 · 24 GB） |
| --- | --- | --- | --- |
| CPU 占用率与单核矩阵 | Mach `host_processor_info(PROCESSOR_CPU_LOAD_INFO)` + `sysctlbyname` + `getloadavg`（[`CPUSampler`](../../Sources/SoftLive/Monitor/Samplers/CPUSampler.swift)） | 汇总全部逻辑核的 `user + system + nice` 与 `idle` tick 做差值；弹窗 `CPU` 页激活时按 `hw.perflevel1.logicalcpu`（6 能效核）与 `hw.perflevel0.logicalcpu`（4 性能核）拆分单核负载、E/P 簇平均占用、用户/系统占比及平均负载 | 前 6 核为 E 核（`E1–E6`），后 4 核为 P 核（`P1–P4`） |
| GPU 渲染负载 | `IOKit` `IOAccelerator` `PerformanceStatistics["Device Utilization %"]`（[`GPUSampler`](../../Sources/SoftLive/Monitor/Samplers/GPUSampler.swift)） | 缓存 `IOAccelerator` 服务句柄，在弹窗 `CPU` 页激活时通过 `IORegistryEntryCreateCFProperty` 单项读取 `"PerformanceStatistics"` 中的硬件利用率百分比并归一化到 `0...1` | 实测单次查询 `0.016 ms`（比 `IORegistryEntryCreateCFProperties` 全字典拷贝快 65 倍） |
| 内存占用率与详情 | Mach `host_statistics64(HOST_VM_INFO64)` + `vm.swapusage` + `kern.memorystatus_vm_pressure_level`（[`MemorySampler`](../../Sources/SoftLive/Monitor/Samplers/MemorySampler.swift)） | 与 macOS「活动监视器 → 已用内存」一致：`(internal_page_count - purgeable_count + wire_count + compressor_page_count) * pageSize / physicalMemory`；常驻采样内存压力等级（供状态栏 RAM 柱动态变色），弹窗 `RAM` 页激活时拆解 App、Wired、Compressed、可用内存与 Swap 交换空间 | 实测 `20.3 GB / 24.0 GB (84%)`，压力偏高时 `pressure == 2`（`.warning`） |
| 进程 Top 10 排行与结束进程 | `libproc` `proc_listallpids` + `proc_pid_rusage(RUSAGE_INFO_V4)` + `sysctl(KERN_PROCARGS2)` + `proc_pidinfo(PROC_PIDVNODEPATHINFO)` + `kill(2)`（[`ProcessSampler`](../../Sources/SoftLive/Monitor/Samplers/ProcessSampler.swift)） | 弹窗 `CPU` / `RAM` 页激活时遍历当前用户可访问进程：按相邻采样的 `(ri_user_time + ri_system_time)` Mach 时间差计算单进程 CPU 百分比（**Top 10**），按 `ri_phys_footprint` 排序物理内存大户（**Top 10**）；对 `node`/`python` 等通用宿主进程读取 `KERN_PROCARGS2` 的 `argv[0]`（识别 `process.title` 如 `next-server`）与 `PROC_PIDVNODEPATHINFO` 工作目录名并缓存至 `metaCache`；支持在列表行直接结束进程（`SIGTERM` + `SIGKILL` 兜底） | 实测准确识别并区分 `next-server (app) 9.1 GB` 与 `next-server (admin) 2.2 GB` |
| SoC 温度与部位热力 | `IOKit.framework` 私有 HID 事件符号 `IOHIDEventSystemClient*`（[`ThermalSampler`](../../Sources/SoftLive/Monitor/Samplers/ThermalSampler.swift)） | 匹配 `PrimaryUsagePage = 0xFF00, PrimaryUsage = 0x0005`，事件类型 `15`；过滤所有含 `tcal` 的固定校准项（`PMU tcal` / `PMU2 tcal` 恒为 `51.8 °C`）与超界值（`10...130 °C` 之外）；弹窗 `TMP` 页激活时分类汇总 SoC 性能核峰值、SoC 核心均值、主板与供电（PMU）、SSD 闪存（`NAND CH0 temp`）与智能电池（`gas gauge battery`） | 本机返回 47 个 HID 服务：`PMU tdie1..14` 读数 `36.6–44.2 °C`，`NAND CH0 temp` 约 `31.0–35.0 °C`，`gas gauge battery` 约 `26.4–29.8 °C` |
| 整机功耗与风扇转速 | `IOKit` `AppleSMC` `IOConnectCallStructMethod(selector: 2)`（[`SMCSampler`](../../Sources/SoftLive/Monitor/Samplers/SMCSampler.swift)） | 弹窗 `TMP` 页激活时通过用户态 `AppleSMC` 连接读取 `PSTR` 整机总功耗（Watts，`flt` 小端浮点）与 `F0Ac` / `F0Mx` 散热风扇实时转速（RPM） | 本机 `PSTR` 实测 `4.6–23.1 W`，风扇 `FNum = 1`，低负载下 `F0Ac = 0 RPM (停转)`，上限 `6550 RPM` |
| 上下行网速 | BSD `getifaddrs()` `AF_LINK` 链路层 `if_data`（[`NetworkSampler`](../../Sources/SoftLive/Monitor/Samplers/NetworkSampler.swift)） | 只统计 `sa_family == AF_LINK`、具备 `IFF_UP \| IFF_RUNNING`、非 `IFF_LOOPBACK` 且名字前缀为物理接口（`en`、`pdp_ip`、`bridge`）的网卡，按接口名去重后汇总 `ifi_ibytes` / `ifi_obytes`，除以 `ContinuousClock` 单调时钟间隔 | 排除 `lo0`、`utun0..6`（VPN 隧道会重复计入物理网卡流量导致翻倍）、`awdl0`、`llw0` |

采样器按系统接口拆分在 `Monitor/Samplers/`，共享 `Sysctl` 读取封装也留在该目录；`MemorySampler` 不依赖 CPU 采样器。决定详情采样范围的 `MonitorTab` 定义在监控模型 `SystemMetrics.swift` 中，由 UI 消费，监控层不依赖界面文件。

## 运行路径

1. **按偏好启停与动态采样周期（`1s / 2s / 5s`）**：`SystemMonitor` 通过 `Observations` 监听 `Preferences.showsSystemMonitor`、`Preferences.monitorSampleInterval` 与 `Preferences.monitorDefaultTab`。
   - 开启时立即记录一次 `ProcessSampler.captureBaseline()` 并执行 `poll()`，按所选周期（默认 `2.0s`）启动 `Timer`；修改采样间隔时实时重建定时器。
   - 关闭「显示状态栏监控」时，立即 `invalidate()` 定时器并清空历史队列，后台 0 唤醒。
2. **首次基线与差值**：
   - CPU、单进程 CPU 和网速都依赖相邻两次采样的计数器差值，因此第 1 次采样建立基线，后续采样输出真实速率。
3. **温度低频复用与按当前标签页按需详情采样**：
   - 平时弹窗关闭（`isDetailActive == false`）时，每 2 秒只更新 `metrics`（总 CPU、总内存 + 内存压力等级、网卡字节数，以及每 3 拍查 1 次主核心温度传感器），**不更新** `detailMetrics`，也**不执行**单核拆分、进程全表扫描、GPU 利用率查询、SMC 功耗/风扇读取与全量传感器遍历。
   - 当用户打开弹窗或切换标签页（`activeTab`）时，仅采样当前选中标签页（`.cpu` / `.ram` / `.tmp`）所需的详情数据；且在弹窗首帧渲染提交完成（`60ms`）后调用 `processSampler.captureBaseline()` 重置进程 tick 基线（并在 `500ms` 后刷新），避免将开窗渲染的瞬时开销计入 `SoftLive` 自身的 CPU 占比。

## 约束与失败行为

- **内核缓冲区与句柄必须释放**：`host_processor_info` 分配的 Mach OOL 内存必须在 `defer` 中用 `vm_deallocate` 释放；`getifaddrs` 链表必须在 `defer` 中用 `freeifaddrs` 释放；`IOServiceGetMatchingService` 与 `IOServiceOpen` 必须在 `defer` / `deinit` 中对应调用 `IOObjectRelease` / `IOServiceClose`。
- **`AppleSMC` 结构体 80 字节对齐**：`AppleSMC` 内核驱动的 `kSMCUserClientCommand`（selector `2`）要求输入/输出 `SMCKeyData_t` 精确为 80 字节。Swift 中 `keyInfo_t`（`UInt32 + UInt32 + UInt8 = 9` 字节）后必须显式补齐 3 字节填充再接 `result: UInt8`，否则结构体大小变成 76 字节会导致 `IOConnectCallStructMethod` 返回 `kIOReturnBadArgument`。
- **温度不可用时的回退**：在不支持 `PMU tdie` / `MTR Temp Sensor` 的环境（如虚拟机）中，`ThermalSampler.sample()` 返回 `nil`，状态栏 TMP 柱保持为空轨，弹窗显示 `-- °C`。
- **计数器回绕保护**：32 位 `ifi_ibytes` / `ifi_obytes` 在高吞吐下可能回绕，当 `currentSnapshot < previous` 时跳过本次差值并更新基线，不产生巨额假速率。

## 验证

- `swift test --filter "SystemMetricsTests|SystemSamplersTests"`
- 开启状态栏监控后用 `top -l 5 -s 1 -stats pid,cpu,idlew,mem -pid $(pgrep -x SoftLive)` 实测 CPU 与每秒唤醒次数。
