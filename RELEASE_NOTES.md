# OrbitLauncher v0.2.0

本版本新增可配置的环形应用启动器和应用管理操作，并继续改善鼠标滚轮与旋钮编码器的逐格体验。

## 新功能

- 新增 OrbitLauncher 应用图标。
- 新增“应用切换器”和“环形启动器”两种工作模式。
- 环形启动器支持建立多套应用组，并可添加、移除、重命名或切换应用组。
- 应用切换器新增辅助操作按键：高亮应用时可关闭当前窗口或彻底退出应用。
- 辅助操作按键可设置为 Space、A–Z、F1–F12 或 Delete。
- 首次启动且尚未授权时，自动打开 macOS 辅助功能授权入口。
- 支持关闭第二层快捷操作；关闭后确认应用图标会直接切换或打开应用。
- 开启第二层时，默认操作固定为“切换当前窗口”。
- 应用与操作名称可选择显示或隐藏。

## 修复与优化

- 将滚轮步进语义修正为“转动几格切换一次”，不再一格跨越多个应用。
- 反向旋转时重新累计格位，减少误切换。
- 关闭窗口改为优先通过 macOS 辅助功能接口直接操作窗口关闭按钮，失败时回退到 ⌘W。
- 修复辅助关闭操作只切换到目标应用、但没有关闭窗口的问题。
- 保留此前对冷启动首格跳动、重复事件监听、快速旋转漏格、前台应用滚轮失效和第二层默认操作随机等问题的修复。

## 安装

1. 下载 `OrbitLauncher-macOS-arm64.zip` 并解压。
2. 将 `OrbitLauncher.app` 移动到“应用程序”文件夹。
3. 首次启动时按住 Control 点击应用并选择“打开”。
4. 根据首次启动提示，在“系统设置 → 隐私与安全性 → 辅助功能”中允许 OrbitLauncher。
5. 如系统要求，再在“输入监控”中允许 OrbitLauncher。

如果应用仍被 macOS 隔离，可执行：

```bash
xattr -dr com.apple.quarantine /Applications/OrbitLauncher.app
open /Applications/OrbitLauncher.app
```

## 已知限制

- 当前附件仅提供 Apple Silicon（ARM64）版本。
- 应用使用临时签名，没有 Apple Developer ID 公证。
- Microsoft Surface Dial 原始 HID 支持仍位于 `agent/surface-dial` 实验分支，本次 main
  Release 不包含该功能。
