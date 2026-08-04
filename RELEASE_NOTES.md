# OrbitLauncher v0.2.1

本版本重点加入 Microsoft Surface Dial 原生 HID 支持、逐应用直接控制和智能混合模式，并集中修复滚动、窗口恢复、浏览器控制与系统动作问题。

## Surface Dial 与智能控制

- 新增 Microsoft Surface Dial 原生 HID 支持、刻度触觉反馈和实验性主动保活。
- 支持“环形切换”“直接控制”“智能混合”三种操作模式。
- 智能混合模式在普通窗口中使用应用环，在 macOS 原生全屏窗口中自动切换为逐应用直接控制。
- 全屏直接控制时可通过长按或双击强制呼出应用环。
- 支持单击、双击、长按和第二层动作自定义。
- 支持为每个应用单独设置旋转精度。
- 圆环长时间无操作时可自动隐藏，等待时间可自定义。

## 应用模板与直接控制

- 新增系统、浏览器、Finder、VS Code / Cursor、Xcode、Photoshop、视频剪辑、终端、媒体和 PDF 阅读模板。
- 设置页面直接显示当前应用使用的模板；修改模板内容后显示为“自定义”。
- 新增上下、左右滚动动作和独立滚动量设置。
- 滚动方向自动适配 macOS“自然滚动”。
- 浏览器模板支持 Safari、Google Chrome 和 Microsoft Edge 页面内连续平滑缩放。
- 增加 Apple Events 自动化用途说明，首次浏览器控制时可正常请求授权。

## 窗口与系统动作修复

- 应用切换列表恢复显示所有常规应用，包括位于其他 Space 的全屏应用。
- 切换到没有窗口的 Safari、WPS 等应用时发送 macOS 重新打开请求，打开初始页或欢迎窗口，而不是只显示菜单栏。
- 切换到最小化应用时自动恢复窗口并置于前台。
- 修复亮度调整，改为发送 macOS 硬件亮度虚拟键。
- 修复 Mission Control 受自定义快捷键影响而失效的问题，改为直接调用系统 Mission Control。
- 修复首次旋转跳多格、快速旋转漏格、前台为 OrbitLauncher 时无法旋转、滚轮方向相反等问题。

## 安装

1. 下载 `OrbitLauncher-macOS-arm64.zip` 并解压。
2. 将 `OrbitLauncher.app` 移动到“应用程序”文件夹。
3. 首次启动时按住 Control 点击应用并选择“打开”。
4. 在“系统设置 → 隐私与安全性 → 辅助功能”中允许 OrbitLauncher。
5. 使用浏览器平滑缩放时，在“自动化”中允许 OrbitLauncher 控制对应浏览器；浏览器还需允许来自 Apple 事件的 JavaScript。

如果应用仍被 macOS 隔离，可执行：

```bash
xattr -dr com.apple.quarantine /Applications/OrbitLauncher.app
open /Applications/OrbitLauncher.app
```

## 已知限制

- 当前附件仅提供 Apple Silicon（ARM64）版本。
- 应用使用临时签名，没有 Apple Developer ID 公证。
- 亮度控制适用于 Mac 内置屏幕及 macOS 原生支持亮度调节的显示器，不包含通用 DDC 外接显示器控制。
