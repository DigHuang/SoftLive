# 系统监控

## 职责与事实来源

[`SystemMonitor`](../../Sources/SoftLive/Monitor/SystemMonitor.swift) 按 2 秒周期采样核心系统指标并维护 60 秒滚动历史队列（30 个样本点：`cpuHistory`、`memoryHistory`、`thermalHistory`），发布只读快照 [`SystemMetrics`](../../Sources/SoftLive/Monitor/SystemMetrics.swift)，供状态栏 [`MonitorStatusBar`](../../Sources/SoftLive/UI/StatusBar/MonitorStatusBar.swift) 与 Liquid Glass 详情面板 [`MonitorPopoverView`](../../Sources/SoftLive/UI/StatusBar/MonitorPopover.swift) 渲染。全部位于用户态，不需要 root 权限、辅助功能权限或后台 Helper。

| 指标 | 内核 / 系统接口 | 计算方式与过滤规则 | 本机实测（Apple M4 · 10 核 · 24 GB） |
| --- | --- | --- | --- |
| CPU 占用率与单核矩阵 | Mach `host_processor_info(PROCESSOR_CPU_LOAD_INFO)` + `sysctlbyname` + `getloadavg`（[`CPUSampler`](../../Sources/SoftLive/Monitor/SystemSamplers.swift)） | 汇总全部逻辑核的 `user + system + nice` 与 `idle` tick 做差值；弹窗展开时按 `hw.perflevel1.logicalcpu`（6 能效核）与 `hw.perflevel0.logicalcpu`（4 性能核）拆分单核负载、E/P 簇平均占用、用户/系统占比及平均负载 | 前 6 核为 E 核（`E1–E6`），后 4 核为 P 核（`P1–P4`） |
| GPU 渲染负载 | `IOKit` `IOAccelerator` `PerformanceStatistics["Device Utilization %"]`（[`GPUSampler`](../../Sources/SoftLive/Monitor/SystemSamplers.swift)） | 弹窗展开时通过 `IORegistryEntryCreateCFProperty` 读取 Apple Silicon GPU 硬件利用率百分比并归一化到 `0...1` | 实测 `AGXAcceleratorG16G` 直接返回 `Device Utilization %`（0–100 整数） |
| 内存占用率与详情 | Mach `host_statistics64(HOST_VM_INFO64)` + `vm.swapusage` + `kern.memorystatus_vm_pressure_level`（[`MemorySampler`](../../Sources/SoftLive/Monitor/SystemSamplers.swift)） | 与 macOS「活动监视器 → 已用内存」一致：`(internal_page_count - purgeable_count + wire_count + compressor_page_count) * pageSize / physicalMemory`；常驻采样内存压力等级（供状态栏 RAM 柱动态变色），弹窗展开时拆解 App、Wired、Compressed、可用内存与 Swap 交换空间 | 实测 `20.3 GB / 24.0 GB (84%)`，压力偏高时 `pressure == 2`（`.warning`） |
| 进程 Top 10 排行与结束进程 | `libproc` `proc_listallpids` + `proc_pid_rusage(RUSAGE_INFO_V4)` + `sysctl(KERN_PROCARGS2)` + `proc_pidinfo(PROC_PIDVNODEPATHINFO)` + `kill(2)`（[`ProcessSampler`](../../Sources/SoftLive/Monitor/SystemSamplers.swift)） | 弹窗展开时遍历当前用户全部可访问进程（包含 `SoftLive` 自身）：按相邻采样的 `(ri_user_time + ri_system_time)` Mach 时间差计算单进程 CPU 百分比（**Top 10**），按 `ri_phys_footprint` 排序物理内存大户（**Top 10**）；对 `node`/`python` 等通用宿主进程读取 `KERN_PROCARGS2` 的 `argv[0]`（识别 `process.title` 如 `next-server`）与 `PROC_PIDVNODEPATHINFO` 工作目录名（区分多实例，如 `next-server (app)` vs `next-server (admin)`），并精简 `Helper (Renderer)` 后缀；支持在列表行直接结束进程（`SIGTERM` + `SIGKILL` 兜底） | 实测准确识别并区分 `next-server (app) 9.1 GB` 与 `next-server (admin) 2.2 GB` |
| SoC 温度与部位热力 | `IOKit.framework` 私有 HID 事件符号 `IOHIDEventSystemClient*`（[`ThermalSampler`](../../Sources/SoftLive/Monitor/SystemSamplers.swift)） | 匹配 `PrimaryUsagePage = 0xFF00, PrimaryUsage = 0x0005`，事件类型 `15`；过滤所有含 `tcal` 的固定校准项（`PMU tcal` / `PMU2 tcal` 恒为 `51.8 °C`）与超界值（`10...130 °C` 之外）；弹窗展开时分类汇总 SoC 性能核峰值、SoC 核心均值、主板与供电（PMU）、SSD 闪存（`NAND CH0 temp`）与智能电池（`gas gauge battery`） | 本机返回 47 个 HID 服务：`PMU tdie1..14` 读数 `36.6–44.2 °C`，`NAND CH0 temp` 约 `31.0–35.0 °C`，`gas gauge battery` 约 `26.4–29.8 °C` |
| 整机功耗与风扇转速 | `IOKit` `AppleSMC` `IOConnectCallStructMethod(selector: 2)`（[`SMCSampler`](../../Sources/SoftLive/Monitor/SystemSamplers.swift)） | 弹窗展开时通过用户态 `AppleSMC` 连接读取 `PSTR` 整机总功耗（Watts，`flt` 小端浮点）与 `FNum` / `F0Ac` / `F0Mx` 散热风扇实时转速（RPM） | 本机 `PSTR` 实测 `4.6–23.1 W`，风扇 `FNum = 1`，低负载下 `F0Ac = 0 RPM (停转)`，上限 `6550 RPM` |
| 上下行网速 | BSD `getifaddrs()` `AF_LINK` 链路层 `if_data`（[`NetworkSampler`](../../Sources/SoftLive/Monitor/SystemSamplers.swift)） | 只统计 `sa_family == AF_LINK`、具备 `IFF_UP \| IFF_RUNNING`、非 `IFF_LOOPBACK` 且名字前缀为物理接口（`en`、`pdp_ip`、`bridge`）的网卡，按接口名去重后汇总 `ifi_ibytes` / `ifi_obytes`，除以 `ContinuousClock` 单调时钟间隔 | 排除 `lo0`、`utun0..6`（VPN 隧道会重复计入物理网卡流量导致翻倍）、`awdl0`、`llw0` |

## 运行路径

1. **按偏好启停（2 秒周期）**：`SystemMonitor` 通过 `Observations` 监听 `Preferences.showsSystemMonitor`。
   - 开启时立即执行一次 `poll()`，并启动间隔 `2.0s`（`tolerance = 0.25s`）的 `Timer`。
   - 在菜单中关闭「显示状态栏监控」时，立即 `invalidate()` 定时器并清空 60 秒历史队列，后台 0 唤醒。
2. **首次基线与差值**：
   - CPU、单进程 CPU 和网速都依赖相邻两次采样的计数器差值，因此第 1 次采样建立基线，后续采样输出真实速率。
3. **温度低频复用与按需详情采样**：
   - 平时弹窗关闭（`isDetailActive == false`）时，每 2 秒只采样总 CPU、总内存 + 内存压力等级、网卡字节数，以及主核心温度传感器，**不执行**单核拆分、进程全表扫描、GPU 利用率查询、SMC 功耗/风扇读取与全量传感器遍历。
   - 当用户点击状态栏监控打开弹窗时，`MonitorStatusBar` 先展示窗口再调用 `monitor.setDetailActive(true)` 立即触发详情采样（并在 `320ms` 后补采一次进程 CPU 差值），在弹窗打开期间每 2 秒刷新全量遥测数据；弹窗关闭后立即恢复低开销模式。

## 约束与失败行为

- **内核缓冲区与句柄必须释放**：`host_processor_info` 分配的 Mach OOL 内存必须在 `defer` 中用 `vm_deallocate` 释放；`getifaddrs` 链表必须在 `defer` 中用 `freeifaddrs` 释放；`IOServiceGetMatchingService` 与 `IOServiceOpen` 必须在 `defer` / `deinit` 中对应调用 `IOObjectRelease` / `IOServiceClose`。
- **`AppleSMC` 结构体 80 字节对齐**：`AppleSMC` 内核驱动的 `kSMCUserClientCommand`（selector `2`）要求输入/输出 `SMCKeyData_t` 精确为 80 字节。Swift 中 `keyInfo_t`（`UInt32 + UInt32 + UInt8 = 9` 字节）后必须显式补齐 3 字节填充再接 `result: UInt8`，否则结构体大小变成 76 字节会导致 `IOConnectCallStructMethod` 返回 `kIOReturnBadArgument`。
- **温度不可用时的回退**：在不支持 `PMU tdie` / `MTR Temp Sensor` 的环境（如虚拟机）中，`ThermalSampler.sample()` 返回 `nil`，状态栏 TMP 柱保持为空轨，弹窗显示 `-- °C`。
- **计数器回绕保护**：32 位 `ifi_ibytes` / `ifi_obytes` 在高吞吐下可能回绕，当 `currentSnapshot < previous` 时跳过本次差值并更新基线，不产生巨额假速率。

## 验证

- `swift test --filter "SystemMetricsTests|SystemSamplersTests"`
- 开启状态栏监控后用 `top -l 5 -s 1 -stats pid,cpu,idlew,mem -pid $(pgrep -x SoftLive)` 实测 CPU 与每秒唤醒次数。
