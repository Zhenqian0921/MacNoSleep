# MacNoSleep

一个用于控制 macOS 睡眠行为的 Swift 工具，包含菜单栏 app 和命令行版本。

## 重要说明

macOS 上有两类不同的睡眠控制：

- `hold`：使用官方 IOKit power assertion，阻止系统因为空闲而睡眠。这个方式安全、无需管理员权限，但不能可靠覆盖“合盖触发睡眠”。
- `lid on --force`：调用 `sudo pmset -a disablesleep 1`，尝试禁用系统睡眠，从而影响合盖睡眠。这个命令需要管理员权限，并且不同 Mac / macOS 版本支持情况可能不同。

合盖运行会让散热变差。建议只在接电源、通风良好、确实需要时开启，用完立刻恢复。

## 构建

```sh
swift build
```

生成的调试版命令行程序在：

```sh
.build/debug/mac-nosleep
```

生成的调试版菜单栏程序在：

```sh
.build/debug/MacNoSleepBar
```

构建发布版：

```sh
swift build -c release
```

发布版命令行程序在：

```sh
.build/release/mac-nosleep
```

发布版菜单栏程序在：

```sh
.build/release/MacNoSleepBar
```

## 菜单栏用法

推荐用项目脚本启动菜单栏 app，它会把 SwiftPM 产物打包成 `dist/MacNoSleep.app`，并隐藏 Dock 图标：

```sh
./script/build_and_run.sh
```

菜单项：

- `开启空闲不睡眠`：阻止系统因为空闲进入睡眠。
- `开启屏幕常亮`：阻止屏幕因为空闲熄灭。
- `合盖时长`：设置本次合盖不睡眠持续时间，可选 `15 分钟`、`30 分钟`、`1 小时`、`2 小时`、`4 小时`、`手动关闭`。
- `开启合盖不睡眠`：弹出管理员授权窗口，然后调用 `pmset` 修改系统睡眠开关；如果选择了具体时长，到点会自动恢复正常睡眠。
- `恢复合盖睡眠`：弹出管理员授权窗口，然后恢复正常系统睡眠。
- `刷新状态`：重新读取 `pmset` 当前状态。
- `退出 MacNoSleep`：退出菜单栏 app，自动释放 app 持有的 IOKit 断言。

Codex 桌面端的 `Run` 动作已经指向 `./script/build_and_run.sh`。

## 命令行用法

阻止空闲睡眠，直到按 `Ctrl-C`：

```sh
.build/debug/mac-nosleep hold
```

同时保持屏幕不熄灭：

```sh
.build/debug/mac-nosleep hold --display
```

查看当前合盖/系统睡眠开关：

```sh
.build/debug/mac-nosleep lid status
```

开启合盖不睡眠尝试：

```sh
.build/debug/mac-nosleep lid on --force
```

恢复正常睡眠：

```sh
.build/debug/mac-nosleep lid off
```

查看 `pmset` 睡眠断言摘要：

```sh
.build/debug/mac-nosleep status
```
