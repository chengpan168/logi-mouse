# logi-mouse

这是一个使用 Swift / AppKit 编写的 macOS 鼠标滚动控制程序。项目基于早期对 Logi Options+ 的黑盒曲线研究，在 USB Receiver 模式下独立提供主滚轮和横向滚轮的全局平滑滚动。

当前结论：在已验证的 USB Receiver 模式下，项目已经可以在所有应用中独立复现 Options+ 的滚动手感。Receiver HID++ 主动接管会动态发现主滚轮 `0x2121` 和横向拇指滚轮 `0x2150`，分别启用 Diverted 模式，并在关闭接管或退出应用时恢复各自原生设置。Options+ Agent 停止、模式漂移、Receiver 拔插、睡眠唤醒、全局输出和 Command-Q 恢复均已完成主滚轮真机验证。Bluetooth、SmartShift、按键、手势和 DPI 尚未替代，因此暂时不要卸载 Options+。

## 算法与运行时成果

- 历史研究阶段完成了慢速、快速自然停止、快速硬停止、反向和超慢精细滚动五类样本分析。
- 确认 Options+ 的主要映射不是“慢速/快速”离散状态机，而是带历史衰减的连续 S 形增益曲线。
- 使用一个连续活动量、Logistic 增益、`periods` 展开和小数误差扩散模型复现滚动输出。
- 五组离线回放的总距离误差均低于 2%，其中反向场景为 0.0028%。
- 实现全局原始事件抑制和带 marker 的模型事件注入，不会形成反馈环。
- 横向拇指滚轮通过 HID++ `0x2150` 获取未加速的原始位移，使用与主滚轮相同的 Logistic 增益参数，但独立维护活动量和小数余量；Receiver 接管期间会抑制重复的 macOS 横向事件。
- 历史逐事件闭环和长时间主观体验均已验证，实际体感与 Options+ 无明显差异。
- 实现 Receiver HID++ Root Feature 动态发现、`0x2121` 模式读写、写后校验和原模式恢复。
- 接管后的短期窗口每秒静默核对设备模式，稳定后降为每 15 秒；若出现外部滚动事件会立即触发一次限频核对。Options+ 退出或其他进程把 `0x03` 改回原生模式时，仍会自动重写并校验，而不需要人工切换开关。
- 接管意图与当前 USB 连接解耦；Receiver 断开时进入等待，重新出现后优先以约 0.35 秒超时快速重试上次设备槽位，并周期性执行全槽位兜底扫描。
- 主应用不再包含采集入口、JSONL 写盘、测试滚动区或离线分析 CLI；历史代码归档到 `Diagnostics/LegacyCapture/`，不参与产品编译。
- `IOHIDManager` 只打开 Receiver 的 vendor-defined HID++ 接口，不订阅鼠标/键盘 collection；同时采用自适应模式守护，降低鼠标静止时的进程唤醒与无线轮询。


## 数据链路

开启平滑滚动后：

```text
Receiver Root Feature ─┬→ 0x2121 主滚轮 → Diverted + High Resolution ─┐
                       └→ 0x2150 横向轮 → Diverted ───────────────────┤
                                                                     ↓
                     独立轴状态 → ScrollDynamicsModel → CGScrollInjector
```

两个轴共享同一组衰减和 S 形增益参数，但不会共享滚动历史，避免快速纵向滚动意外抬高横向增益。`0x2150` 的事件格式与模式控制依据 [OpenLogi thumbwheel 参考](https://openlogi.org/en/hidpp/features/x2150-thumbwheel)。应用注入的事件带有专用 marker，事件监听器会识别并放行，避免反馈环。

## 曲线分析

### 有效录制场景

历史拟合使用的 Options+ 黑盒录制如下；这些文件不再由当前主应用生成：

```text
~/Library/Application Support/logi-mouse/captures/
```

| 场景 | 文件 | 目的 |
| --- | --- | --- |
| 慢速、自然停止、向下 | `20260803-064557-options-on-free-spin-slow-natural-stop-down.jsonl` | 观察低速平台和自然衰减 |
| 快速、自然停止、向下 | `20260803-064735-options-on-free-spin-fast-natural-stop-down.jsonl` | 观察高速平台和长尾 |
| 快速、硬停止、向下 | `20260803-065011-options-on-free-spin-fast-hard-stop-down.jsonl` | 区分软件惯性与硬件输入停止 |
| 向下后反向向上 | `20260803-065149-options-on-reverse-down-up.jsonl` | 验证方向切换和历史状态 |
| 超慢、微小幅度、向下 | `20260803-065515-options-on-free-spin-ultra-slow-controlled-down.jsonl` | 验证代码阅读式精细滚动 |

### 曲线形状

采集数据表现出两个明显平台：

- 低活动量时，单个滚轮单位约映射为 `0.85–1.0 px`，适合缓慢阅读和微调。
- 高活动量时，增益迅速上升并稳定在约 `5.75 px`，适合自由滚轮快速浏览。
- 两个平台之间是较陡的连续 S 形过渡，而不是几个离散挡位。
- 一次完整操作中看到的 `1.42`、`2.0`、`3.0` 等平均增益，主要是低平台和高平台事件混合后的统计结果，并不代表必须增加对应的状态。

只使用当前瞬时速度无法解释相同输入在加速段和减速段的不同输出，数据具有明显历史依赖。因此模型使用一个随时间指数衰减的“近期活动量” `A`。

#### 原始探索性曲线

![Options+ 滚动数据四联曲线分析](docs/scroll-curve-analysis.svg)

这张图保留了算法选择阶段的四组关键证据：极慢动作内部仍会出现增益爬升；只用瞬时速度时同一速度存在明显分叉；加入衰减历史量后数据收束为陡峭 S 形；反向时 HID 与 CG 的符号同步翻转。图中的 `30 ms` 是探索阶段用于识别曲线形状的窗口，最终经过五场景联合回放后将时间常数定为 `80 ms`。

#### 最终参数曲线

![Options+ 观测增益与 Logistic 拟合曲线](docs/scroll-gain-curve.svg)

图中的观测点来自五组有效录制：按衰减后的活动量以 `0.5` 为宽度分箱，每个圆点表示该箱的观测增益中位数，竖线表示 25%–75% 四分位区间。它直观显示了约 `0.85` 的低速平台、`A ≈ 5.3` 附近的快速过渡，以及约 `5.75` 的高速平台；过渡区的离散也说明只依靠单次瞬时输入无法稳定拟合，需要保留近期活动量。

### 数学模型

对第 `i` 个 HID++ 输入，先将之前的活动量按时间衰减：

```text
A_before(i) = exp(-Δt / τ) × A(i-1)
```

然后通过 Logistic 曲线计算增益：

```text
gain(A) = gain_min
        + (gain_max - gain_min)
        / (1 + exp(-steepness × (A / activity_midpoint - 1)))
```

当前输入的每个 period 都使用更新前的 `A_before` 计算输出：

```text
output_per_period = delta × direction_multiplier × gain(A_before)
A(i)              = A_before + abs(delta) × periods
```

最终拟合参数：

| 参数 | 数值 | 含义 |
| --- | ---: | --- |
| `decayTimeConstant` | `0.080 s` | 近期活动量的衰减时间常数 |
| `minimumGain` | `0.85` | 超慢滚动的低速平台 |
| `maximumGain` | `5.75` | 快速自由滚动的高速平台 |
| `activityMidpoint` | `5.3` | S 曲线的中点活动量 |
| `steepness` | `6.0` | 低、高平台之间的过渡陡峭度 |

该曲线在 `A = 0` 附近约为 `0.86`，在 `A = 5.3` 时为 `3.30`，随后快速趋近 `5.75`。因此超慢滚动能保持精确，连续输入又能很快进入高速区。

### `periods` 与量化

HID++ `0x2121` 报告 flags 的低 4 位表示 `periods`：

```text
periods = max(1, flags & 0x0f)
```

例如 `0x11` 表示 1 个 period，`0x12` 表示 2 个 periods。Options+ 会按 period 展开输出，模型也会生成对应数量的事件；这也是 Live 验证中 CGEvent 数量可能多于 HID++ 报告数量的原因。

CGEvent 最终需要整数位移。若每次直接四舍五入，超慢滚动会不断丢失小数并产生明显误差。因此模型保存小数余量，使用误差扩散把它累积到后续事件；方向反转时清除小数余量，但保留连续活动量。

### 自然滚动、停止与反向

- 本轮样本开启了 macOS 自然滚动，录制中 HID++ 与 CGEvent 的方向符号一致率为 `100%`。
- 自然滚动和传统滚动共享同一条幅度曲线，只在最终输出阶段应用 `+1` 或 `-1` 的方向乘数。
- 快速自然停止时的长尾来自仍在到达的硬件滚轮报告，不需要额外的软件惯性定时器。
- 快速硬停止时，HID++ 报告停止后模型也立即停止输出。
- 方向反转不会把速度模型切换成另一个状态，只清理跨方向不应继承的量化余数。

## 离线验证结果

最终参数对五组原始 Options+ 录制进行逐事件回放，结果如下：

| 场景 | Options+ 总位移 | 模型总位移 | 总距离误差 | 方向一致率 |
| --- | ---: | ---: | ---: | ---: |
| 慢速自然停止 | 9,081 | 9,248 | 1.8390% | 100% |
| 快速自然停止 | 153,333 | 153,095 | 0.1552% | 100% |
| 快速硬停止 | 50,505 | 50,624 | 0.2356% | 100% |
| 向下后反向向上 | 178,295 | 178,300 | 0.0028% | 100% |
| 超慢精细滚动 | 1,106 | 1,117 | 0.9946% | 100% |

所有场景的总距离误差都低于 2%。模型在超慢滚动、快速滚动、自然停止、硬停止和反向操作之间使用同一组参数，没有为单独场景增加特判状态。

## Live 闭环验证

第一组正式闭环录制：

```text
20260803-080931-options-on-observation.jsonl
```

| 层级 | 事件数 | 位移和 |
| --- | ---: | ---: |
| HID++ 输入 | 70 | — |
| `model_output` | 70 | -250 |
| 应用注入的 `cg_event` | 70 | -250 |
| 窗口收到的 `ns_event` | 70 | -250 |
| 被抑制的 Options+ 原始事件 | 70 | 不进入页面 |

离线分析器重新回放该文件后，观测位移与预测位移均为 `250`，总距离误差和逐事件误差均为 `0`，方向一致率为 `100%`。页面 offset 记录为 `249`，属于视图 frame 采样时机造成的 1 px 差异，不是注入链路丢事件。

第二组长时间主观体验录制：

```text
20260803-083653-options-on-observation.jsonl
```

- 模型生成 2,753 条逻辑输出；按 `periods` 展开后注入 2,820 条 CGEvent。
- 模型总位移与应用注入总位移均为 `-68,397`，完全一致。
- 同期 Options+ 生成的 2,820 条原始事件全部在测试区域内被抑制。
- 在模型输出附近 2 ms 内，没有 Options+ 事件绕过抑制进入页面。
- 实际体验反馈为滚动正常，手感与 Options+ 无明显差异。

这证明测试区域内的最终页面滚动来自当前模型，而不是模型输出与 Options+ 输出叠加后的结果。Options+ 当前仍负责设备侧状态维护，但它自己的滚动曲线不会影响测试区域内的体验结果。

### Receiver 主动接管验证

在 Options+ Agent 停止状态下完成了以下真机闭环：

- Agent 退出会把设备从 Diverted `0x03` 改回原生 `0x02`；1 秒守护检测到漂移后自动写回并回读 `0x03`，无需人工切换接管开关。
- Agent 停止后，HID++ `0x2121` 输入、模型输出和应用注入持续工作，测试区滚动体验正常，外部 Options+ 事件为零。
- 取消接管时，应用写入并回读 `0x02`，原生系统滚动正常。
- 接管状态下按 `Command-Q`，应用在退出前写入并回读 `0x02`；进程退出后、Options+ Agent 未参与时，原生滚动正常。
- Receiver 拔插后无需切换开关即可自动重建接管；优化后的控制接口出现到完整接管约 `1.01 s`，主观约 `0.5 s` 开始恢复。
- 睡眠期间 HID++ 请求按预期超时；唤醒后检测到默认 `0x00` 并自动恢复 `0x03`，主观约 `1 s` 恢复。
- 全局模式下，Options+ 运行时模型输出 `-2994 px`，应用注入也为 `-2994 px`；Options+ Agent 的 1,726 条原始事件全部被抑制。
- 停止 Options+ Agent 后，浏览器、编辑器等其他应用中的独立全局滚动体验正常。

## 构建与测试

需要 macOS 和 Xcode。构建应用：

```bash
./scripts/build-app.sh
```

运行测试：

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache" \
/usr/bin/xcrun swift test --disable-sandbox
```

应用产物：

```text
.build/logi-mouse.app
```

当前产品测试集包含曲线计算、衰减、低速误差扩散、方向反转、`periods` 展开、连接方式识别、HID++ 报告过滤、横纵轴分类，以及主滚轮/横向轮请求构造、事件解码、响应匹配、动态 feature、模式位解析和原生恢复等 21 项测试。

当前机器的 `xcode-select` 指向 Command Line Tools，而其 SDK 与系统 Swift 小版本不匹配。因此构建脚本和上面的测试命令都显式使用 `/Applications/Xcode.app` 工具链，无需修改全局 `xcode-select`。

## 运行与权限

1. 构建并打开 `.build/logi-mouse.app`。
2. 在“系统设置 → 隐私与安全性 → 输入监控”中允许应用读取 HID 输入。
3. 若要使用平滑滚动，同时在“辅助功能”中允许应用监听和注入事件。
4. 修改权限后完全退出并重新打开应用。
5. 主界面会显示当前设备连接方式；USB Receiver 可以开启平滑滚动，Bluetooth 当前仅显示连接状态，尚未开放接管。
6. 使用“自然滚动 / 标准滚动”分段按钮切换方向，选择会被保存。
7. 打开“平滑滚动”总开关后，应用会依次启用模型、接管并校验 Receiver、开启全局输出，不再需要手工组合多个实验开关。
8. 出现异常时可立即关闭总开关或按 `Command-Q`。关闭或退出应用都会恢复接管前的硬件模式。

应用提供标准的 `Quit logi-mouse` 菜单项；点击菜单或按 `Command-Q` 都会先执行同步模式恢复，再结束进程。

平滑滚动默认关闭。主界面不包含采集或诊断控件。

### 后台进程架构

当前采用单 App、单进程架构：窗口/未来的菜单栏入口、HID++ Receiver 接管、滚动模型、CGEvent 抑制与注入，以及退出前的原生模式恢复，都运行在 `logi-mouse` 进程中。最小化窗口时滚动继续工作；关闭主窗口或退出应用会安全恢复原生模式并结束进程。产品化时可在同一进程增加 `NSStatusItem` 和登录启动。

暂不拆分独立 Agent，原因是滚轮链路对接管所有权和退出恢复顺序敏感。双进程会额外引入 IPC、状态同步、重复接管和异常退出时由谁恢复 `0x02` 的协调成本。只有未来明确要求“UI 完全退出但滚动服务必须继续”、权限/沙箱隔离或独立崩溃拉起时，再拆成后台 Agent 与配置 UI 两个进程。

### 启用与停用 Options+ Agent

确认 logi-mouse 已开启 Receiver takeover 后，可以停用 Options+ 鼠标处理 Agent：

```bash
./scripts/disable-options.sh
```

需要恢复 Options+ 时：

```bash
./scripts/enable-options.sh
```

两个脚本均可重复执行。它们只管理当前用户的 `com.logi.cp-dev-mgr` LaunchAgent，不卸载 Options+，也不停止系统级 Updater。

## 历史采集代码

采集功能已从主应用下线。产品 target 不创建 JSONL、不注册原始 HID value 回调，也不包含测试滚动区和离线分析命令。

历史实现保留在 `Diagnostics/LegacyCapture/`：

- `Sources/`：采集 Coordinator、JSONL Logger、EventRecord、配置解析、测试窗口和离线 Analyzer。
- `Tests/`：采集配置、日志和离线回放测试。

该目录不在 Swift Package target 中，不会进入 `logi-mouse.app`。后续需要重新采集时，可基于这里的快照单独恢复诊断工具，不影响产品运行链路。

## 关键代码

- `Sources/LogiMouse/App/`：应用入口、产品主界面和无落盘的滚动控制编排。
- `Sources/LogiMouse/Input/`：IOHID 输入监听、CGEvent 抑制和像素事件注入。
- `Sources/LogiMouse/HIDPP/`：HID++ 协议、报告解码、Receiver 接管及原模式恢复。
- `Sources/LogiMouse/Scroll/`：连续滚动动力学模型。
- `Diagnostics/LegacyCapture/`：已下线且不参与产品编译的历史采集工具。

## 当前边界与下一步

当前已经验证的是 USB Receiver 下“滚动链路可以全局替代”，不是整个 Options+ 产品已被替代：

- 主界面已能实时显示 USB Receiver、Bluetooth 或未连接；Bluetooth 目前只有被动设备识别能力，还没有完成实际滚轮链路接管。
- Receiver 的 HID++ `0x2121` feature index 已通过 Root Feature 动态发现；尚未覆盖 Bluetooth 传输对应的控制通道。
- `0x2121` Diverted + High Resolution 配置、模式漂移恢复、断线重连、睡眠唤醒和原生恢复均已真机验证；SmartShift 尚未接管。
- USB Receiver 断线重连已支持；USB Receiver 与 Bluetooth 之间的运行时切换尚未实现。
- Live model 已支持显式全局输出，但当前仍以前台 App 形式运行，尚未产品化为登录项或菜单栏后台服务。
- DPI、按键映射、手势等 Options+ 功能不在当前范围内。

下一步是产品化生命周期：菜单栏/登录启动、稳定开发签名和权限引导；设备能力方面再处理 Bluetooth 切换与 SmartShift。算法层不需要重做。
