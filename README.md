# RcloneBar

为现有的 rclone bisync 双向同步提供 macOS 菜单栏进度显示与常用设置。Apple Silicon 原生，macOS 14+，Swift + SwiftUI（`MenuBarExtra`），无第三方依赖。

实际文件同步始终由本机 rclone（`/opt/homebrew/bin/rclone`）的 `bisync` 执行，不依赖 OneDrive 桌面客户端。

## 架构

```
┌──────────────────────┐   settings.json / control/*.json   ┌────────────────────────────┐
│ RcloneBar.app        │ ─────────────────────────────────▶ │ rclonebar-agent (LaunchAgent│
│ 菜单栏界面（可随时退出）│ ◀───────────────────────────────── │ com.zhuke.rclonebar.agent)  │
└─────────┬────────────┘   agent-state.json / runs.jsonl     │ 唯一调度者                  │
          │ RC（127.0.0.1，认证）                            └──────────┬─────────────────┘
          ▼                                                       launchctl kickstart
┌──────────────────────────────────────┐                                │
│ rclone bisync（每组独立进程、独立端口）│ ◀── sync.py ◀── 原 LaunchAgent（改为按需执行）
└──────────────────────────────────────┘     com.zhuke.rclone-bisync.{vault,projects}
```

- **唯一调度者**：接管后，原两个 LaunchAgent 去掉 `StartInterval`/`RunAtLoad` 等自动调度键，只作为“执行器”保留，仍运行原 `sync.py`（原有参数、日志位置、冲突与删除保护、以及“完全磁盘访问”等授权都不变）；由 `rclonebar-agent` 按设置的间隔 `launchctl kickstart` 启动。两者不会重复启动同一组任务。
- **界面与后台独立**：退出菜单栏 App 不影响后台服务；后台服务重启也不会中断正在运行的同步（同步属于各自的 LaunchAgent），重启后会自动接续。
- **同一目录最多一个 bisync**：启动前扫描本用户进程（读取完整 argv，中文/空格路径不会误判），发现处理同一目录的 bisync（包括手动在终端启动的）就不再启动，并接续观察它。
- **实时进度**：每组 rclone 进程通过环境变量开启独立 RC（`127.0.0.1:55721` / `55722`），使用 `--rc-htpasswd` 认证——htpasswd 只有 `{SHA}` 哈希；明文口令仅存在 `~/Library/Application Support/RcloneBar/rc/credential.json`（0600），不出现在命令行、plist、环境变量、界面或日志中。App 每次连接先用 `core/pid` 核对进程号，防止两组数据串在一起。
- **RC 不可用时**：结合进程扫描、日志（文本或 JSON）、`status.json` 与 bisync listing 判断是“空闲”“本轮未开启接口（例如接管前启动的进程）”还是“接口暂不可用”。

### 结果判定（不把“进程退出”当作“成功”）

| 依据 | 说明 |
| --- | --- |
| rclone 退出码 | 直接启动 rclone 时使用 |
| bisync listing | `*.path1.lst` / `*.path2.lst` 在本轮内被更新、且没有新的 `-err` 文件（bisync 只在整轮成功后写入） |
| 日志 | `Bisync aborted` / `critical error` / `Must run --resync` / `Safety abort` / 授权与网络错误分类 |
| 脚本退出码 | 来自 launchd 的 `last exit code`，并用 `runs` 计数确认确实运行过 |

只有 rclone 整轮成功才更新“上次成功时间”。网络类错误、`--resilient` 下的可重试中止记为“可重试错误”，与需要人工处理的失败分开；RcloneBar 永远不会自动执行 `--resync` 或 `--force`，也不会删除 bisync 历史。

### 进度显示规则

- 扫描阶段总量未知：显示不确定进度条和“已列出 N 项”，不显示 0%/100%；
- 传输百分比标注为“本轮已知传输量”，总量 5 秒内仍在增长时标注“总量仍在增加”并暂停 ETA；
- ETA 不可用时显示“估算中”；
- 传输量达到 100% 但进程未结束：显示“正在校验或收尾”；
- 活动时约每秒刷新，空闲时每 5 秒；网络请求与日志读取都在后台进行，日志只读末尾（≤256 KB / 400 行），运行记录文件有大小上限。

## 项目结构

```
Package.swift
Sources/
  RcloneBarCore/      共享逻辑（Foundation，可在 Linux 编译测试）
    RCClient.swift        RC 接口（core/stats、core/pid、core/bwlimit、options/get）
    ProcessScanner.swift  sysctl 读取进程 argv、bisync 匹配
    LogAnalysis.swift     日志读取/解析/错误分类/脱敏
    Progress.swift        进度与阶段推断、总体状态
    RunEvaluator.swift    一轮结果判定
    StatusCollector.swift 汇总生成界面快照
    Inspection.swift      接入检查（只读）
    Installer.swift       接管与回退
    Launchd.swift         launchctl / plist
    ...
  RcloneBarAgent/     rclonebar-agent：后台调度服务 + 命令行
  RcloneBar/          SwiftUI 菜单栏 App
Tests/
  RcloneBarCoreTests/ 单元测试
  e2e/e2e.py          端到端测试（真实 rclone + 临时目录）
  e2e/launchd_test.py launchd 接管/回退集成测试（仅 CI）
Resources/Info.plist  LSUIElement=YES（不显示 Dock 图标）
scripts/build-app.sh  构建 .app
docs/接入与回退.md
```

## 构建与运行

需要 Xcode 15 或更新版本（或 Command Line Tools，含 Swift 5.9+）。

```bash
git clone https://github.com/Haxiaoxian/RcloneBar.git && cd RcloneBar
scripts/build-app.sh          # 生成 build/RcloneBar.app 与 build/RcloneBar.zip（ad-hoc 签名，arm64）
cp -R build/RcloneBar.app /Applications/
open /Applications/RcloneBar.app
```

也可以直接下载 GitHub Actions（macOS 14 / Apple Silicon 运行器）构建的 `RcloneBar-app` 产物。由于是 ad-hoc 签名，首次打开如被 Gatekeeper 拦截，请在 Finder 中右键 →“打开”，或执行 `xattr -dr com.apple.quarantine /Applications/RcloneBar.app`。

测试：

```bash
swift test                                                   # 单元测试
brew install rclone   # 若尚未安装
python3 Tests/e2e/e2e.py --agent .build/debug/rclonebar-agent # 只使用临时目录
```

首次启动处于**观察模式**：只读显示现有 LaunchAgent 的状态，可“立即同步”（`launchctl kickstart`）和“安全结束”；暂停、间隔、限速等需要在“设置 → 后台服务”中接管后才作用于后台。接入、回退与本机授权步骤见 [docs/接入与回退.md](docs/接入与回退.md)。

## 命令行

App 包内带有 `rclonebar-agent`，接管后也安装在 `~/Library/Application Support/RcloneBar/bin/`：

```
rclonebar-agent status            # 两组任务状态
rclonebar-agent inspect           # 接入检查（只读）
rclonebar-agent install --dry-run # 演练接管，不改任何文件
rclonebar-agent install / uninstall
rclonebar-agent sync vault|projects|all
rclonebar-agent stop vault|projects|all
rclonebar-agent pause|resume vault|projects|all
```

## 首版未包含（后续扩展）

新增任意同步目录、排除规则编辑、备份清理、冲突内容合并、重新初始化（`--resync`）向导。
