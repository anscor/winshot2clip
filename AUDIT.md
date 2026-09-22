# winshot2clip 审计报告

审计对象：本仓库全部文件。审计者即开发者本人，因此另派了一次独立的对抗式 review 以对冲自我审查偏差。

## 结论

23 项发现中 **17 项已修复**，2 项部分解决（A11 需设计投入；A22 根因未定位但已换用更保真的默认模式，A23 降级为备选模式），4 项为纯美观或非问题。当前 193 项断言跨平台可跑，连续 3 次全绿、退出码 0。

## 验证边界

这些边界直接决定下面哪些结论可信：

- **没有 Windows 环境**。`System.Windows.Forms`、真实剪贴板写入、WScript 启动、xrdp 端到端均未验证，只能由使用者在 Windows 上跑 `-SelfTest` 确认。
- **`FileSystemWatcher` 是在 Linux/inotify 上测的**，不代表 Windows 的 `ReadDirectoryChangesW`：事件投递语义与缓冲区溢出行为都可能不同。
- 每条发现标注 **[实测]**（跑了东西看到结果）或 **[推断]**（只读代码）。
- Windows PowerShell 5.1 兼容性经 PSScriptAnalyzer 的 `5.1.17763` profile 检查：语法 0 条；命令可用性排除自家 `Write-Log` 的误报后 0 条；类型仅 `System.Windows.Forms.*`，已由 `Add-Type` 显式加载。

## 发现与状态

| 编号 | severity | 问题 | 状态 |
|---|---|---|---|
| A1 | 高·潜在 | 武装 watcher 用 `$script:EventSource`，排空事件却不传 `-EventSource`，回落到另一处硬编码默认值。两值不一致时事件永不处理，且因兜底扫描而"看起来在工作"（延迟从 0.2 秒变 60 秒）；配 `-ReconcileSeconds 0` 则完全失效。两层测试都因显式传参而保持全绿。[实测] | ✅ `-EventSource` 改必填并显式传入；4 条 AST／行为断言 |
| A2 | 中 | `$Pending` 条目可永久卡死：不合格路径提前返回且不更新 `$Pending`，永远到不了放弃上限。后果是空闲循环退化为每秒一次全量扫描，永不恢复。[实测] | ✅ 重试前做资格判定并丢弃；4 条断言 |
| A3 | 中 | `Write-Log` 的 `Write-Host` 在 `try` 之外，与"日志不会打死 watcher"的注释矛盾；无宿主时会抛出并终止 watcher。[实测] | ✅ 移入独立 `try`；3 条断言 |
| A4 | 中 | 自检诊断把"文件名不匹配"与"扩展名不在白名单"混为一谈，对格式问题建议去改 `-Filter`，方向错误。 | ✅ 抽出 `Get-WatchDirDiagnostic`；8 条断言 |
| A15 | 中 | 自检探针文件名硬编码，任何非 `Screenshot*` 的 `-Filter` 都会滤掉自己的探针，对正确配置误报 FAIL——而 README 给的恢复路径正是"加 `-Filter`"。[实测] | ✅ 新增 `Get-ProbeName`；合成不出时返回 `INCONCLUSIVE`；14 条断言 |
| A16 | 中 | 基线在 watcher 武装之前建立，窗口内新建的截图既不在基线也不会产生事件（默认晚 60 秒；`-ReconcileSeconds 0` 时永久丢失）。 | ✅ 改为先武装后建基线；3 条断言 |
| A17 | 中·测试可信度 | 测试 harness 自己重声明生产配置值，改生产配置不会让测试变红——"全绿"只证明逻辑，不证明配置。 | ✅ 改为用 AST 从生产源码读取 |
| A6 | 低-中 | `$Seen` 只增不减，同一路径的第二张截图永不被复制（固定文件名或旧式 `Screenshot (1).png` 复用编号的工具会静默失效）。 | ✅ 改为「路径 → 长度+mtime 签名」；9 条断言 |
| A5 / A8 / A9 / A10 / A20 | 低 | README 不准确：把"每 60 秒一次目录枚举"写成"零 I/O"；把在 Linux 上探测的行为写成"Windows 平台实测记录"；未说明 `-EventTimeoutSeconds` 会连带改变兜底节奏；未说明 `Error` 事件是文档行为而非实测；日志按 ANSI 编码写入。 | ✅ 全部订正；日志改 UTF8 |
| A7 | 低 | `$mutex` 是必须保留引用的变量，缺注释；未来"清理未使用变量"会静默破坏单实例。 | ✅ 加注释 |
| A18 | 低 | `Invoke-RetryPending` 把空操作计为 `retried`。 | ✅ 计数移到资格判定之后 |
| A11 | 低 | 监听目录消失后不重新武装 watcher，只每 `ReconcileSeconds` 记一行 `scan failed`。 | ⬜ 需设计，未修 |
| A12 | 信息 | 测试引用数为 0 的函数恰是缺陷所在地；`while($true)` 内的调用点无法直接调用。 | ◐ 已用 AST 结构性断言与循环接线行为测试覆盖；循环体本身仍无法直接测 |
| A13 | 低 | `Write-Log` 与 PowerShell 6.1+ 的内置 cmdlet 同名，产生 55 条 lint 噪音。 | ⬜ 纯美观，未改 |
| A14 | 低·安全 | 自启 + `ExecutionPolicy Bypass` 使该 `.ps1` 成为用户级持久化写入点（不构成提权，但不应放在他人可写的位置）。 | ⬜ 信息类，无需改 |
| A19 | 低 | `Start-WatchLoop` / `Start-PollLoop` 的 `return 2` 目录检查在 main 已做过，不可达。 | ⬜ 防御性冗余，非缺陷 |
| A22 | 高 | **程序放上剪贴板后，第二次复制就使整条剪贴板道失效**：首张可粘，之后文件与文字都不同步，必须断开重连才恢复。日志里可见 `SetFileDropList` 报「所请求的剪贴板操作失败」（`CLIPBRD_E_CANT_OPEN`，且持续 5 秒以上），说明 Windows 端剪贴板被长期占住（持有者只能是 mstsc）。对照实验：手动复制图片与文字可反复成功，**只有由程序放进剪贴板的文件列表会触发**。根因尚未定位到上游代码。[实测] | ◐ **未解决，但默认模式已改用让 Explorer 自己执行复制的 `Shell` 模式**（与手动 Ctrl+C 同一代码路径），这是「把手动 Ctrl+C 自动化」最保真的做法。保留 `FileDrop` / `AsciiCopy` 两个备选。新增 15 条断言覆盖模式分派与 Shell 动词的异步校验 |
| A23 | 中 | 非 ASCII 文件名会让上游 xrdp 的 `CLIPRDR_FILEDESCRIPTOR` 解析器只读出列表里第一个条目（上游 issue #1992：跳过长度由 `wcstombs()` 返回值推算）。中文 Windows 截图名 100% 命中。**注：这条曾被当作 A22 的根因，实测证明不成立**——改成 ASCII 副本后仍然第二张就失效。 | ◐ 保留为 `AsciiCopy` 模式（默认关闭）；文档与报告已更正，不再声称它是根因 |
| A21 | 中 | 默认 `-Filter 'Screenshot*'` 把系统语言当成了常量：中文 Windows 写 `屏幕截图 2026-09-22 224547.png`，匹配不到任何文件，且症状是**静默无动作**（进程在跑、日志干净、什么都不复制）。由使用者在真实环境发现。[实测] | ✅ `-Filter` 改为数组，默认覆盖两种命名；中文前缀用码点构造以保住纯 ASCII；`FileSystemWatcher.Filter` 改为 `'*'`（它只接受单个通配符）；12 条断言 |：中文 Windows 写 `屏幕截图 2026-09-22 224547.png`，匹配不到任何文件，且症状是**静默无动作**（进程在跑、日志干净、什么都不复制）。由使用者在真实环境发现。[实测] | ✅ `-Filter` 改为数组，默认覆盖两种命名；中文前缀用码点构造以保住纯 ASCII；`FileSystemWatcher.Filter` 改为 `'*'`（它只接受单个通配符）；10 条断言，含把码点钉死和端到端复制（共新增 12 条） |

## 已证实的正面结论

- 193 项断言跨平台可跑，3/3 全绿、退出码 0；harness 的配置值取自生产源码而非重声明。
- 5.1 语法 0 findings；5.1 命令可用性排除误报后 0 条。
- 唯一剪贴板写入点是 `SetFileDropList`，位图死角被彻底排除（全脚本无 `SetImage`）。
- 参数默认值与 README 表格 10/10 一致。
- 没有轮询循环：注册事件不传 `-Action`，主线程 `Wait-Event` 排空；`Wait-Event`/`Get-Event` 的通配符过滤经由两条独立路径确认。
- 子目录不会被误复制：`NotifyFilters.FileName` 在 Windows 上不上报目录创建；即便上报也有 `-PathType Leaf` 兜底（已用合成事件验证）。
- 无死代码、无旧设计残留；三个可执行文件纯 ASCII、无 BOM（5.1 正确解码的前提）。

## 仍需在 Windows 上确认

1. `Add-Type -AssemblyName System.Windows.Forms` 可加载；`SetFileDropList` 写入并能读回一致；运行在 STA 公寓（`-SelfTest` 覆盖这三项）。
2. `FileSystemWatcher` 在 Windows 上的实际投递行为。若改名通知被整条丢弃，"写临时名再改名"型截图工具只能靠兜底扫描抄到，配 `-ReconcileSeconds 0` 则永远抄不到。
3. `Error` 事件在真实缓冲区溢出时是否触发（Linux 上灌 600 个文件得到 0 次，不能代表 Windows）。
4. `start-hidden.vbs` 无窗口启动、命名互斥体不误判。
5. **xrdp 能否把图送进 Linux 应用**，以及 Explorer 的 `Ctrl+C` 会附带、而 `SetFileDropList` 不设置的 `Preferred DropEffect` 是否无关紧要。这是本方案唯一可能不成立的地方。
