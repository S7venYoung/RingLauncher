# OrbitLauncher v0.2.0 Surface Dial Preview 1

这是面向 Microsoft Surface Dial 的实验预览版，基于 OrbitLauncher v0.2.0，并包含
main 分支最新的应用切换、窗口恢复和环形启动器功能。

## Surface Dial 新功能

- 通过原始 HID 识别 Microsoft Surface Dial（VID 045E / PID 091B）。
- 圆环隐藏时，第一次旋转直接呼出 OrbitLauncher。
- 圆环显示后继续旋转，可逐格选择应用或快捷操作。
- 按下 Dial 立即确认当前高亮项目。
- 支持读取设备旋转分辨率，并可设置每圈 10–40 个逻辑格位。
- 默认启用 Surface Dial 旋转刻度震动，并按设置的每圈步数配置触觉刻度。
- 设置页面显示 Dial 当前连接状态。

## 休眠与连接优化

- Dial 长时间无输入后，首个 HID 数据包会被识别为设备唤醒。
- 唤醒时清空休眠前残留的旋转余量，避免第一次旋转跳格。
- 设备唤醒后自动重新发送震动刻度配置。
- Mac 从睡眠状态恢复后自动重建 Surface Dial HID 会话。
- Dial 断开、HID 会话打开失败或输入报告异常时自动重连。
- 保留 Dial 自身的省电休眠，不通过持续轮询增加设备耗电。

## 同步的主线功能

- 应用切换器与多套环形应用启动器。
- 可选第二层快捷操作；关闭后确认图标会直接切换或启动应用。
- 自定义辅助按键，可关闭当前窗口或彻底退出应用。
- 切换到最小化应用时自动恢复窗口并置于前台。
- 自定义启动快捷键、滚轮格位、圆环尺寸、图标尺寸及应用名称显示。
- 首次启动自动引导辅助功能权限。

## 安装

1. 下载并解压 `OrbitLauncher-macOS-arm64.zip`。
2. 将 `OrbitLauncher.app` 移动到“应用程序”文件夹。
3. 首次启动时按住 Control 点击应用并选择“打开”。
4. 在“系统设置 → 隐私与安全性 → 辅助功能”中允许 OrbitLauncher。
5. 如系统要求，再允许“输入监控”权限。
6. 打开设置，在“编码器与滚轮”中确认“启用原始 HID 支持”已开启。

如果应用被 macOS 隔离，可执行：

```bash
xattr -dr com.apple.quarantine /Applications/OrbitLauncher.app
open /Applications/OrbitLauncher.app
```

## 已知限制

- 当前附件仅提供 Apple Silicon（ARM64）版本。
- 应用使用临时签名，没有 Apple Developer ID 公证。
- Surface Dial 原始 HID 支持仍为实验功能；不同蓝牙环境下的实际休眠唤醒效果需要硬件测试。
