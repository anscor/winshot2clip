# winshot2clip：把 Windows 新截图自动放进剪贴板

## 它解决什么问题

xrdp 的 `cliprdr` 通道只实现了**文本**和**文件列表**两种剪贴板格式，**没有实现位图（CF_DIB）**。所以 Windows 剪贴板里躺着一张图片时，它永远传不到 Nix 侧 —— 这就是"文字能同步、图片不能"的根因。

但文件能传。你在资源管理器里选中文件按 `Ctrl+C`，剪贴板里放的是 `CF_HDROP`（文件路径列表），mstsc 会把它翻译成 CLIPRDR 的文件格式发给 xrdp，Linux 应用就能拿到。

所以这个程序**只做一件事**：把"进资源管理器找文件 + Ctrl+C"这一步自动化。它监听截图目录，一发现新截图就把它以**文件**形式放进剪贴板 —— 和你手动操作产生的剪贴板内容完全一致，粘贴通路一点没变。

## 文件清单

| 文件 | 作用 |
|---|---|
| `winshot2clip.ps1` | 主程序：监听目录 + 把新截图放进剪贴板 + 写日志 |
| `start-hidden.vbs` | 无窗口启动器（避免每次登录黑窗口一闪） |
| `tests/logic-tests.ps1` | 逻辑回归测试（152 项断言，不依赖 Windows，任意平台的 pwsh 都能跑） |

两个脚本都是**纯 ASCII**，这是刻意的：Windows PowerShell 5.1 在没有 UTF-8 BOM 时按系统 ANSI 代码页解析 `.ps1`，非 ASCII 字符会变乱码。纯 ASCII 意味着**你用任何方式传输都不会出问题，包括直接从 RDP 剪贴板粘贴到记事本另存**。中文路径照样能用（命令行参数是 UTF-16）。

## 部署

### 1. 把文件放到 Windows 上

任选一种：

- **git clone**（推荐；`.gitattributes` 会把两个 Windows 脚本 checkout 成 CRLF）：
  ```powershell
  mkdir "$env:USERPROFILE\tools" -Force | Out-Null
  git clone git@github.com:anscor/winshot2clip.git "$env:USERPROFILE\tools\winshot2clip"
  ```
- **直接粘贴**：新建 `%USERPROFILE%\tools\winshot2clip\winshot2clip.ps1`，把源码内容复制进去另存。纯 ASCII 所以编码怎么存都行。

### 2. 先跑自检

```powershell
cd "$env:USERPROFILE\tools\winshot2clip"
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\winshot2clip.ps1 -SelfTest
```

自检在 `%TEMP%` 下建一个临时目录，**两条通路各验一遍**，全程不碰你自己的截图：

| 阶段 | 验什么 |
|---|---|
| 环境 | 监听目录是否存在；**目录里有没有匹配 `Screenshot*` 的文件**（不匹配就把实际文件名打出来）；是否 STA |
| 扫描通路 | 造一张真 PNG → 扫描发现它 → 放进剪贴板 → **读回剪贴板确认** → 再扫一遍确认不重复复制 |
| 事件通路 | 武装一个真 `FileSystemWatcher` → 造第二张 PNG → 等事件队列驱动它 → 放进剪贴板 → **读回剪贴板确认** |

事件通路这一步是关键：它只能在 Windows 上真跑，所以让自检替你跑。末行应该是 `=== SelfTest result: PASS ===`。

末行也可能是 `INCONCLUSIVE`：当 `-Filter` 是自检无法合成出匹配文件名的形式（比如无通配符的 `exact.png`，或者字符集 `[Ss]hot*`）时，自检会明确告诉你"环境检查通过了，但剪贴板往返没有验证"，而不是报一个假的 FAIL。

### 3. 前台跑一次，做端到端验证

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\winshot2clip.ps1
```

窗口留着别关。然后：

1. 按 `PrtScn` 截个图（照你平时的习惯）
2. 在另一个窗口确认剪贴板内容：
   ```powershell
   Get-Clipboard -Format FileDropList
   ```
   应该打印出刚生成的那张截图路径
3. 切到远程桌面里的 Nix 应用，`Ctrl+V`

第 3 步成功 = 整条链路通了。

### 4. 设为开机自启

1. 双击 `start-hidden.vbs`，确认进程起来了、**没有黑窗口一闪**：
   ```powershell
   Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
     Where-Object { $_.CommandLine -like '*winshot2clip.ps1*' } |
     Select-Object ProcessId, CommandLine
   ```
2. `Win+R` → `shell:startup` → 回车
3. 在打开的文件夹里新建 `start-hidden.vbs` 的**快捷方式**（右键 → 新建 → 快捷方式，目标填 `%USERPROFILE%\tools\winshot2clip\start-hidden.vbs`；若向导不展开变量，就填实际路径）

`start-hidden.vbs` 用 `WScript.Shell.Run` 的隐藏窗口模式启动，并且按它自身的所在目录去找 `.ps1`，所以放快捷方式、移动目录都不会坏。

程序内部有一个命名互斥体，重复启动（例如自启了一次你手动又点一次）不会出现两个实例互相抢剪贴板。

## 排查

日志：`%USERPROFILE%\winshot2clip.log`（超过 1MB 自动截断保留最后 200 行）。正常运行时是这样：

```
2026-09-22 21:50:36 watching 'C:\Users\me\Pictures\Screenshots' for 'Screenshot*' (event driven, kernel buffer 65536 bytes, backstop 60s)
2026-09-22 21:50:36 baseline: 137 existing file(s) treated as already handled
2026-09-22 21:50:37 clipboard set: C:\Users\me\Pictures\Screenshots\Screenshot 2026-09-22 215037.png
```

空闲时**不会有任何新行**（事件驱动，不轮询）。日志里可能出现的关键行：

| 日志 | 含义 |
|---|---|
| `clipboard set: <路径>` | 正常，已放进剪贴板 |
| `clipboard set (3 attempts): <路径>` | 剪贴板被短暂占用，重试后成功。正常 |
| `will retry (1/3): <路径> -- ...` | 这次失败了，下轮自动重试 |
| `GAVE UP after 3 attempts: <路径>` | 连续失败 3 次，放弃该文件（重截一张即可） |
| `reconciliation scan picked up N file(s)...` | 兜底扫描补回了 watcher 没报的文件。**出现这行说明有东西被漏过，值得看一眼** |
| `watcher reported a buffer error...` | 内核变更缓冲区溢出，随后会全量扫描补齐 |

| 现象 | 原因 |
|---|---|
| 日志里一直没有 `clipboard set` | 截图文件名不匹配任何 `-Filter` 模式。看自检输出的 "files that are there"，然后加参数，例如 `-Filter '你的命名*'`；要全收就 `-Filter '*'` |
| 日志有 `clipboard set`，但远程粘不出来 | Windows 侧没问题，问题在 xrdp 的文件剪贴板通路（见下文） |
| 日志频繁出现 `reconciliation scan picked up` | FileSystemWatcher 在这台机器上不可靠，加 `-Mode Poll` 切回轮询 |

停止程序：

```powershell
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
  Where-Object { $_.CommandLine -like '*winshot2clip.ps1*' } |
  ForEach-Object { Stop-Process -Id $_.ProcessId }
```

## 可调参数

```powershell
.\winshot2clip.ps1 -WatchDir "D:\somewhere" -Filter '截图*' -ReconcileSeconds 0
```

| 参数 | 默认 | 说明 |
|---|---|---|
| `-WatchDir` | `%USERPROFILE%\Pictures\Screenshots` | 监听目录，中文路径也可以 |
| `-Filter` | `Screenshot*` 与中文 Windows 的 `屏幕截图*` | **一个或多个**文件名通配符（数组）。Windows 按系统语言命名截图，英文安装写 `Screenshot 2026-01-01 120000.png`，中文安装写 `屏幕截图 2026-01-01 120000.png`，所以默认给两个。要全收就传 `'*'`；多个模式就传数组 |
| `-Mode` | `Watch` | `Watch` = 事件驱动；`Poll` = 定时扫描目录（逃生开关） |
| `-ReconcileSeconds` | `60` | Watch 模式下，空等这么久没有事件就扫一次目录兜底。`0` = 关掉周期性兜底，只保留 Error 驱动的恢复 |
| `-SettleTimeoutMs` | `5000` | 等文件停止增长的上限 |
| `-PollMs` | `400` | 仅 `-Mode Poll`：扫描间隔 |
| `-EventTimeoutSeconds` | `0` | 仅 `-Mode Watch`：覆盖单轮等待时长。主要为测试暴露，平时不用动。**注意**：兜底扫描就是由"某一轮没等到任何事件"触发的，所以调小它等于同时把兜底扫描的间隔也调小（它会覆盖 `-ReconcileSeconds`）|
| `-LogPath` | `%USERPROFILE%\winshot2clip.log` | 日志路径 |
| `-Once <路径>` | — | 一次性模式：把指定文件放进剪贴板后退出 |
| `-SelfTest` | — | 自检模式 |

## 设计上几个关键决定（改代码前先看这里）

**为什么用文件而不是位图。** `Clipboard::SetFileDropList()` 等价于 Explorer 的 `Ctrl+C`。**绝对不要**改成 `Clipboard::SetImage()` —— 那会退回到你已验证走不通的位图通路。

**为什么事件驱动能做成单线程，没有作用域陷阱。** 关键是给 `Register-ObjectEvent` **不传 `-Action`**。传了 `-Action` 的话处理脚本在子作用域执行（读不到主循环的状态），而且只在管道空闲时才被触发。不传 `-Action` 时事件只是进 PowerShell 的事件队列，主线程用 `Wait-Event` 阻塞在这个队列上再统一消费 —— 全程单线程，没有子作用域，不空转轮询，空闲时一次文件系统调用都不做。

**两个可能丢截图的地方，以及为什么都不丢。** 一是内核变更缓冲区溢出（`Error` 事件会触发 → 我们立刻全量扫描补齐；注意这是 .NET 的**文档行为**，我没有真的制造出一次溢出，见下面"未验证"）；二是事件压根没送到（`ReadDirectoryChangesW` 的已知边界情况 → 空等满 `-ReconcileSeconds` 就扫一次）。第二道防线用的是"等待超时"而不是"定时器"，所以没有轮询循环。

准确说：**空闲时不是零 I/O**——默认每 60 秒会有一次目录枚举（加上每个匹配文件的一次 `Test-Path`）。比 400ms 轮询小两个数量级，但不是零。想更纯粹可以 `-ReconcileSeconds 0`，代价是只剩第一道防线。

**为什么需要 `Wait-FileSettled`。** 事件在文件**刚被创建**时就会到，那时内容可能还没写完。原轮询版本靠"连续两次扫描看到相同大小和 mtime"来间接推断，这其实是轮询的副产物；改成事件驱动后可以直白地问：等到大小不再变化为止。注意它的判定窗口是 `StepMs`（默认 100ms），所以对一个"写一会儿、停超过 100ms、再接着写"的写入者仍会误判为写完 —— 截图工具不会那样写文件。

**为什么进程退出后剪贴板内容还在。** `SetFileDropList()` 内部调用 `SetDataObject(dataObject, copy: true)`，等于 `OleFlushClipboard()`，把数据真正渲染进系统剪贴板，而不是留一个属于本进程的指针。所以脚本进程即使被关掉，几分钟后 `Ctrl+V` 依然有效。

**为什么要重试。** Windows 上别的程序短暂占用剪贴板（`CLIPBRD_E_CANT_OPEN`）是常态。内层重试 5 次 × 200ms，外层再给每个文件最多 3 轮机会，超过就放弃并记日志。失败的文件进 `$pending`，下一轮循环自动重试。

**为什么需要 STA。** WinForms 剪贴板 API 要求单线程公寓。`powershell.exe` 默认就是 STA，但启动器里显式传了 `-STA`。

**为什么启动时把已有文件标记为"已处理"。** 否则刚开机就会把一张旧截图塞进你的剪贴板，覆盖掉你当时正在用的内容。

**为什么 `-Filter` 是数组，且默认值里那个中文前缀写成码点。** Windows 的截图文件名是**按系统语言**生成的：英文安装写 `Screenshot ...`，中文安装写 `屏幕截图 ...`。单个英文通配符在中文系统上匹配不到任何东西，而且症状是**静默无动作**（进程在跑、日志干净、什么也不复制），看起来像工具坏了。所以默认给两个模式，`-Filter` 也支持数组。

前级不能写成字面量：本文件必须保持纯 ASCII（否则 Windows PowerShell 5.1 会按系统 ANSI 代码页解码，中文字面量变乱码），所以用 `[char]0x5C4F` 这类码点拼出来。测试里有一条专门把这个值钉死在四个具体码点上，防止有人“顺手”改成字面量。

**去重按"文件版本"而不是按"路径"。** `$seen` 存的是 `路径 → (长度+mtime)`，而不是一堆路径。所以：截图工具**覆写同名文件**（固定文件名、或者旧式的 `Screenshot (1).png` 复用编号）时，新内容照样会被复制；而同一个文件因为重复事件被看多次时，不会反复刷剪贴板。签名只在 `Get-FileSignature` 一处构造，两边比对不可能对不上。

## 平台行为探测记录（在 Linux/inotify 上做的，Windows 待验证）

下面这三条是我写代码前后**实际探测**出来的（不是文档抄来的），但探测环境是 **Linux 的 inotify**——我手上没有 Windows。`ReadDirectoryChangesW` 的投递语义、缓冲区溢出行为、名子配对规则都可能不同，所以这三条在 Windows 上都要重新确认。第 3 条与平台无关，可以直接信。

**1. 事件载荷在 `SourceEventArgs` 上，不在 `SourceArgs[0]` 上。**
```
SourceArgs[0]   = System.IO.FileSystemWatcher   ← .Name 是 $null
SourceArgs[1]   = System.IO.FileSystemEventArgs
SourceEventArgs = System.IO.FileSystemEventArgs  ← 正确读取位置
```
读 `SourceArgs[0].Name` 会拿到空字符串，表现是"程序在跑但什么都不复制"。代码里用的是 `$evt.SourceEventArgs.FullPath`。

**2. 在 Linux 上，带 `Filter` 时改名进目录的文件会被报成 `Created` 而不是 `Renamed`。**

观察到的现象是：临时文件名不匹配过滤器时，.NET 配不上"旧名→新名"，就只报新名那一端（且 `ChangeType` 是 `Created`）。

**但这一条在 Windows 上未验证，而且残留一个真实风险**：如果 Windows 上 .NET 在这种情况下干脆**丢掉整条通知**，那么"写临时名再改名"型截图工具就只能靠 60 秒兜底扫描抄到，配 `-ReconcileSeconds 0` 则**永远抄不到**。测试里那条"改名进目录的文件会被复制"（`tests/logic-tests.ps1`）断言的是**结果**，不是事件名——它证明不了 Windows 上的投递行为。

好在代码对两种事件都订阅、都用 `FullPath`，所以只要通知能到就一定处理对；风险只在"通知可能整条不到"。如果 `-SelfTest` 的报告里出现 `reconciliation scan picked up`，就是撞上了这一类。

**3. `NotifyFilter = FileName` 不会报告目录创建事件。**（这条与平台无关，可以直接信：`FileName` 映射到 `FILE_NOTIFY_CHANGE_FILE_NAME`，只覆盖文件，目录要 `DirectoryName`）所以新子目录根本不会产生事件 —— 而且这样更好：内核缓冲区不用为无关事件占位。代码里对目录的防御（`Test-Path -PathType Leaf`）是第二道保险，测试用合成事件单独验证过它有效。

**4. 截图文件名是按系统语言本地化的。**（这条是**实测**，就是在中文 Windows 上发现的：中文安装写 `屏幕截图 2026-09-22 224547.png`）同理，任何依赖英文前缀的假设都是错的。

## 已验证 / 待验证

我在 NixOS 上，**没有 Windows 环境**，所以边界说清楚。

**已实测（152 项断言，连跑三遍全绿、退出码 0，`tests/logic-tests.ps1`）**

其中约 60 项是审计之后补的回归断言，每一条锁一个具体缺陷。测试 harness 现在从生产源码里读配置值（`$script:Extensions` / `MaxAttempts` / `EventSource`），所以改生产配置会真的让测试跟着变——而不是继续默默地测旧值。

另外每条断言都是可失败的真断言：比如 A6 那组会用**不同长度**的内容改写同一路径，然后要求"必须被重新复制"。

环境与兼容性：
- 脚本语法解析无错误；纯 ASCII、无 BOM、不含 PowerShell 7 专有运算符（5.1 兼容性护栏）

资格判定：
- 只认 `Screenshot*.png/jpg/jpeg`；其他文件名、非白名单扩展、无扩展名、目录、不存在的路径、空路径一律拒绝；大写 `.PNG` 正常识别

文件写完判定：
- 完整文件快速通过；0 字节文件永不通过；不存在的文件不通过；**正在被持续追加的文件只在写入停止后才通过**（用真实并发写入者验证，且断言它没有提前通过）

扫描通路与去重：
- 基线只收匹配文件；已见过的文件不重复复制；新文件被发现并落到剪贴板后标记为已见；非匹配文件永不复制；目录不存在时返回 0 不崩溃

重试与放弃：
- 失败的文件不进已见集合、进待重试队列并计 1 次；重试成功则清除并标记已见；扫描通路会跳过已排队重试的文件（不让它双倍消耗重试次数）；第 3 次失败后放弃且不再触碰

**事件通路（真实 `FileSystemWatcher`，非模拟）**：
- watcher 正常武装、内核缓冲区拉满 65536、只订阅 FileName
- 新建匹配文件产生事件并被复制，剪贴板收到**正是那个路径**，然后标记已见、不需要扫描
- 非匹配文件完全不产生事件
- **改名进目录的文件被复制**，用的是最终名字、监听目录内的路径
- `Error` 事件置位 `NeedScan` 且不会被误当成文件（用**合成**的 Error 事件验证的是处理逻辑，不是真实溢出）
- 目录形状的事件被消费但永不复制、剪贴板不受影响
- 空闲一轮能完整阻塞住超时时长（不是空转）且 `Handled=0`

**事件循环接线（`Invoke-WatchIteration`，决定"什么时候该扫、什么时候不该扫"）**：
- 有事件时复制且**不做**多余扫描
- 空等时触发兜底扫描，**并且真的捞回了一个 watcher 从没报告过的文件**（直接造出"事件丢失"的场景）
- `-ReconcileSeconds 0` 时空等**不做**扫描，文件保持未被发现
- `Error` 事件在兜底关闭时**仍然**强制扫描并捞回文件（同上，合成事件）
- 待重试文件在下一轮被自动重试并清除
- 所有测试 watcher 都正确注销，无事件订阅泄漏

**未验证，需要你在 Windows 上确认（就是第 2、3 步做的事）**

- `Add-Type -AssemblyName System.Windows.Forms` 能加载
- `Clipboard::SetFileDropList()` 实际写入成功、且读回一致（自检覆盖）
- STA 公寓检查（自检覆盖）
- `FileSystemWatcher` 真实的 `Created`/`Renamed` 事件在 Windows 上的具体投递行为（自检覆盖）。**特别是**：如果 Windows 上 .NET 在名子配不上时直接丢掉通知，那么"写临时名再改名"型截图工具就只能靠兜底扫到（见上文平台探测记录第 2 条）
- **`Error` 事件在真实缓冲区溢出时到底会不会触发**。我在 Linux 上用最小 8KB 缓冲区灌 600 个文件，**Error 事件 0 次**——那是 inotify，不能代表 Windows 的 `ReadDirectoryChangesW`。代码对 Error 的处理逻辑是验证过的，"它会触发"这件事没有
- `start-hidden.vbs` 无窗口启动；命名互斥体不误判
- **最后也是最重要的一环**：xrdp 把这张图送到 Linux 应用里

## 如果"日志有 clipboard set 但远程粘不出来"

这是本方案唯一剩下的理论风险点：Explorer 的 `Ctrl+C` 除 `CF_HDROP` 外还会附带一个 `Preferred DropEffect`（值为 COPY），而 `SetFileDropList()` 不设置它。理论上不影响（xrdp 的 chansrv 走 `FileGroupDescriptorW` / `FileContents` 请求，不看这个格式），但没法在 Windows 上实测。

万一真遇到，排查顺序：

1. 先确认不是 xrdp 侧的问题：Nix 侧看 `/var/log/xrdp-chansrv.log` 或 `journalctl -u xrdp -f`，粘贴时有没有文件传输相关报错。xrdp 的 C2S 文件剪贴板对某些应用（历史上 Nautilus 3.38）就是不兼容 —— 换个应用（Thunar、浏览器输入框）试试，能区分"程序没复制"和"这个应用粘不了"。
2. 确认不是应用问题：Nix 侧开个能收文件的程序（文件管理器）`Ctrl+V`，看能不能落下一个文件。能落下说明剪贴板是好的，是目标应用不接受文件形式的粘贴。
3. 如果确实缺 `Preferred DropEffect`，补它需要自定义 `IDataObject`（`DataObject::SetData` 传 `MemoryStream` 会被序列化成 `SerializedObject` 包装，不是裸字节，这是经典坑），大概 40 行 C# 通过 `Add-Type` 内联。到时候告诉我，我加。

## 跑逻辑测试

```powershell
pwsh -File .\tests\logic-tests.ps1           # PowerShell 7
powershell.exe -File .\tests\logic-tests.ps1 # Windows PowerShell 5.1
```

测试用 PowerShell 解析器把生产脚本里的**函数定义**抽出来，所以脚本顶层的代码（`Add-Type`、参数分发、互斥体）不会执行；同时把 `Set-ClipboardFile` 覆盖成记录型假函数。因此除了真剪贴板那一步，**其余全部是真实执行的**，包括真的 `FileSystemWatcher` 和真的并发文件写入者。真剪贴板那一步靠 `-SelfTest`。
