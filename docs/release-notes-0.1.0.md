# logi-mouse 0.1.0

0.1.0 是 logi-mouse 的首个可用版本，目标是在 macOS 上为 Logitech MX Master 鼠标提供独立、自然且可控的平滑滚动体验。

本版本已在 MX Master 3 Mac 上完成 USB Receiver 与 Bluetooth Low Energy 两种连接方式的核心滚动验证。滚动模型来自对 Logi Options+ 的实际事件曲线分析，兼顾代码阅读时的超慢微调和自由滚轮的快速浏览。

## 主要功能

- 支持 USB Receiver 和 Bluetooth Low Energy 连接。
- 支持主滚轮和横向拇指滚轮。
- 提供“平滑滚动”总开关。
- 支持 macOS 自然滚动和标准滚动方向切换。
- 使用连续衰减活动量和 Logistic 增益曲线，在低速精确滚动与高速浏览之间平滑过渡。
- 展开 Bluetooth 批量报告中的 `periods`，使 USB 和 Bluetooth 使用相同的滚动时序与算法。
- 使用小数误差扩散保留亚像素位移，改善超慢滚动时的连续性。
- 主界面显示当前设备及 USB Receiver/Bluetooth 连接方式。

## 硬件控制与安全恢复

- 通过 HID++ Root Feature 动态发现主滚轮 `0x2121` 和横向轮 `0x2150`，不依赖固定 feature index。
- 接管前读取并保存鼠标原始模式，写入后再次读取校验。
- 关闭平滑滚动、关闭窗口或按 `Command-Q` 退出时，恢复接管前的原生滚动模式。
- 分别验证纵向和横向接管状态；未完成硬件回读的轴不会抑制原生事件。
- 检测到模式被睡眠、重连或其他软件重置后，可重新发现并恢复接管。
- 鼠标断开后停止主动循环扫描，只在 Bluetooth interface、Receiver 链路通知、HID++ 活动或原生滚动事件到达时尝试恢复一次。

## USB 与 Bluetooth

两种连接共享同一套报告解码和滚动模型，但底层 HID 拓扑不同：

- USB Receiver 将 HID++ 暴露为独立 interface，移动指针不会进入 logi-mouse 的控制回调。
- Bluetooth 将键盘、指针和 HID++ 合并在一个复合 interface。logi-mouse 在极小的 C bridge 中过滤高频指针报告，只让 HID++ 和 Receiver 生命周期消息进入 Swift。
- Bluetooth 指针移动仍可能引起少量进程唤醒，这是 macOS 复合 HID interface 的剩余成本，不影响指针或滚动结果。

## 安装与权限

系统要求：macOS 13 或更高版本。

1. 解压正式发布包并打开 `logi-mouse.app`。
2. 在“系统设置 → 隐私与安全性 → 输入监控”中允许 logi-mouse。
3. 在“系统设置 → 隐私与安全性 → 辅助功能”中允许 logi-mouse。
4. 修改权限后，完全退出并重新打开应用。
5. 在主界面确认设备连接后，打开“平滑滚动”。

正式发布包应使用 Developer ID Application 签名并通过 Apple notarization。不要分发本地 `build-app.sh` 生成的 ad-hoc 调试包。

## 验证结果

- 30 项自动化测试通过，覆盖 HID++ 协议、Receiver 连接通知、双轴解码、模式位、路由、事件关联、限频、滚动曲线和误差扩散。
- 五组 Options+ 原始录制的离线总距离误差均低于 2%。
- 已验证超慢滚动、快速自然停止、快速硬停止和方向反转使用同一组模型参数。
- 已完成 USB Receiver 与 Bluetooth 的主滚轮、横向轮、自然/标准方向和退出恢复体验验证。

## 已知限制

- 当前首发验证设备为 MX Master 3 Mac；其他 Logitech 型号尚未形成正式兼容性清单。
- SmartShift、DPI、按键映射和手势尚未替代 Logi Options+。
- 当前是单 App、单进程的前台应用，尚未提供菜单栏模式和登录自动启动。
- Bluetooth 复合 HID interface 会在移动指针时唤醒底层回调，CPU 表现可能略高于 USB Receiver。
- 最新的事件驱动断开/重连实现已通过自动化测试，仍需继续扩充不同睡眠、切换和 Receiver 槽位组合的长期真机验证。

## 升级说明

这是首个版本，没有历史版本迁移要求。安装前无需卸载 Logi Options+；在确认当前鼠标和连接方式工作正常之前，建议保留 Options+，以继续使用本版本尚未覆盖的设备功能。

