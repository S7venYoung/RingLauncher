# Orbit Launcher

一个 macOS 原生圆环应用启动器原型：

- 按 `⌥Space` 在鼠标当前位置呼出圆环。
- 第一层列出当前正在运行的普通应用（最多 10 个，当前应用优先）。
- 点击应用进入第二层，显示“切换到、所有窗口、隐藏、退出、返回”。
- 鼠标滚轮或映射成滚轮的编码器旋转可循环选择，方向键同样可用。
- 同时监听应用内与全局滚轮事件，并兼容纵向、横向和离散滚轮步进。
- 圆环显示时会成为 key window，确保 OrbitLauncher 自己在前台时也能接收滚轮。
- 设置页可自定义启动快捷键、每格切换项目数和最快连续切换间隔。
- 扇区式高亮、出现动画、径向拖动选择以及松开执行。
- 可调圆环尺寸、图标尺寸、深浅外观、切换音效和登录时启动。
- 可选择显示或隐藏圆环中的应用与操作名称。
- 编码器按下若映射为 `Return`/小键盘回车即可执行当前高亮项。
- 点击中心、按 `Esc` 或再次按 `⌥Space` 返回/关闭。
- 菜单栏显示圆环图标，可用于显示圆环或退出；Dock 中不显示常驻图标。

## 在 Xcode 中运行

1. 安装 Xcode 15 或更高版本。
2. 在 Xcode 中打开本目录的 `Package.swift`。
3. 选择 `OrbitLauncher` scheme 和 `My Mac`，点击 Run。

首次运行时，全局读取滚轮和编码器按键通常需要输入监控权限，可在：

`系统设置 → 隐私与安全性 → 输入监控`

中允许 OrbitLauncher。当前原型的全局热键使用 Carbon Hot Key，通常不依赖辅助功能权限。

可用以下命令实时检查滚轮是否到达应用：

```bash
log stream --style compact --predicate 'subsystem == "com.s7venyoung.orbitlauncher"'
```

## GitHub Actions 构建

每次推送到 `main` 都会在 `macos-15` ARM64 runner 上：

1. 使用 SwiftPM 编译 Release 版本。
2. 组装并临时签名 `OrbitLauncher.app`。
3. 校验 plist、签名与二进制架构。
4. 上传 `OrbitLauncher-macOS-arm64.zip` 构建产物。

在仓库的 **Actions → Build macOS App → 最新运行 → Artifacts** 下载。

下载后如果 macOS 提示无法验证开发者：

1. 解压 ZIP。
2. 在 Finder 中按住 Control 点击 `OrbitLauncher.app`，选择“打开”。
3. 在再次出现的提示中选择“打开”。

这是因为 Actions 产物使用临时签名而非付费的 Apple Developer ID 签名。若仍被隔离，可在终端执行：

```bash
xattr -dr com.apple.quarantine /Applications/OrbitLauncher.app
open /Applications/OrbitLauncher.app
```

## 下一步适合补充

- 为 Safari、访达、邮件等应用定义真正的专属动作。
- 鼠标滑动/扇区选择，松开快捷键即执行。
- 设置界面：修改热键、圆环半径、应用数量和动作。
- 登录时启动、菜单栏入口、签名与 `.app` 打包。
