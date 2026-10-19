---
name: pc-migrate

display_name:
  zh-CN: Windows 电脑迁移（旧机 → 新机）
  en: Windows PC Migration (Old → New)

description: >
  把一台 Windows 电脑上的个人文件、软件配置、聊天记录、浏览器书签、桌面快捷方式
  整体搬到另一台 Windows 电脑。典型说法是「换电脑怎么把东西搬过去」「旧笔记本的
  文件怎么弄到新电脑」「两台电脑怎么传几十 GB 数据」「迁移微信/QQ 聊天记录」
  「桌面快捷方式全变白块了」「书签没同步过来」。技能用 SMB 共享 + robocopy 拉取
  的方式做局域网直连传输（不依赖网盘、不依赖外网），并提供扫描 / 拷贝 / 分发 /
  补拷 AppData / 修快捷方式 / 合并书签 / 清理 七个阶段的现成脚本。
  当用户提出换电脑迁移、两台 Windows 传数据、软件和设置一起搬、或迁移后出现
  快捷方式失效 / 书签丢失 / 聊天记录没加载等问题时使用。

version: 1.0.0

category:
  - system
  - windows
  - file-transfer
  - migration

capabilities:
  - 局域网 SMB 直连探测与认证（解决 445 不通、认证卡死）
  - robocopy 快速扫描与分批拷贝（跳过缓存、增量续传）
  - 数据分发到桌面/文档/D 盘等真正可用位置
  - AppData 精选补拷（浏览器密码、软件设置、排除垃圾缓存）
  - 快捷方式死链修复 + 图标缓存清理
  - Chromium 系浏览器书签追加合并（Chrome/Edge/夸克）
  - 迁移垃圾扫描与安全清理
---

# Windows 电脑迁移（旧机 → 新机）

## 0. 先确认三件事，再动手

不要一上来就拷。先问清楚，否则会白花几个小时：

| 问题 | 为什么必须问 | 影响 |
|---|---|---|
| 旧电脑还能开机、能联网吗？ | 离线就只能拆硬盘或放弃 | 决定用「网络直连」还是「硬盘对拷」 |
| 数据量多大？主要在哪几个目录？ | 几十 GB 和几百 MB 的策略完全不同 | 决定是否要跳过 AppData、是否分批 |
| 新电脑 C 盘剩余空间够吗？ | 拷完没地方放要重来 | 目标盘至少留数据量 ×1.5 |

**先扫描，再拷贝。** 用户说的「几十 GB」通常不在桌面/文档，而在 `D:\某目录`、
`AppData`、下载目录。跳过扫描直接拷，最常见的结局是「只拷了 0.2 GB」。

---

## 1. 整体流程

```
旧电脑                          新电脑
─────────────────────────────────────────────────────
① 建 SMB 共享 ──────────────► ② 探测 + 扫描（只统计不拷）
   共享整个用户目录 + 各盘          robocopy /L 快速枚举
                                   ↓ 出「占用报告」给用户选
                               ③ 分批 robocopy 拉取到中转盘
                                   ↓
                               ④ 分发到真正能用的位置（桌面/文档/D盘）
                               ⑤ 补拷 AppData 精选（书签/密码/软件设置）
                               ⑥ 修快捷方式 + 合并书签
                               ⑦ 清理垃圾
```

**旧电脑只需要做 ①，其余全部在新电脑上跑。** 这样旧电脑随时可以关机，
中途断了重跑新电脑侧脚本即可（robocopy 增量跳过已拷文件）。

---

## 2. 编码铁律（不遵守必然乱码）

PowerShell 5.1 读文件靠 BOM 判编码，写 .bat 靠 ANSI 代码页：

| 文件类型 | 必须的编码 | 换行 |
|---|---|---|
| `.ps1` | **UTF-8 with BOM** | CRLF 或 LF 均可 |
| `.bat` / `.cmd` | **GBK (代码页 936)** | **CRLF** |
| `.md` / `.txt` / `.json` | UTF-8 无 BOM | 任意 |

用 `write` / `edit` 工具写出来的文件是 **UTF-8 无 BOM**，写 .ps1 后必须补 BOM：

```powershell
$p = 'C:\path\to\script.ps1'
$t = Get-Content -LiteralPath $p -Raw -Encoding UTF8
[System.IO.File]::WriteAllText($p, $t, (New-Object System.Text.UTF8Encoding($true)))
```

写 .bat 用 GBK：

```powershell
$t = Get-Content -LiteralPath $batPath -Raw -Encoding UTF8
[System.IO.File]::WriteAllText($batPath, $t, [System.Text.Encoding]::GetEncoding(936))
```

**症状对照**：中文变 `鑻辨枃` 之类 → 编码错；`.ps1` 报「字符串缺少终止符」但肉眼看
不出问题 → 缺 BOM；`.bat` 里的 `echo` 中文乱码 → 不是 GBK 或不是 CRLF。

---

## 3. 网络直连（旧机建共享，新机拉取）

### 3.1 探测连通性

```powershell
Test-Port 192.168.1.20 445      # SMB
Test-Port 192.168.1.20 3389     # 远程桌面（能连说明网络通）
nbtstat -A 192.168.1.20         # 从 IP 反查计算机名
```

**445 不通 ≠ 网络不通。** 先用 3389 / ping 确认能通，再查 445。常见原因按概率排序：

1. **旧电脑网络配置文件是「公用」** → 防火墙拦 445。改成「专用」即可：
   `Get-NetConnectionProfile | Set-NetConnectionProfile -NetworkCategory Private`
2. **LanmanServer 服务停了** → `Set-Service LanmanServer -StartupType Automatic; Start-Service LanmanServer`
3. **防火墙没放行「文件和打印机共享」** →
   `Enable-NetFirewallRule -Group '@FirewallAPI.dll,-28502'` 和 `'@FirewallAPI.dll,-32752'`
4. 账号没密码 / 来宾访问被禁 → 用旧机真实账户名 + 密码

### 3.2 认证：用 net.exe，别用 New-SmbMapping

```powershell
# ✅ 正确：PowerShell 直调 net.exe，密码错返回 exit=2，不卡交互
& net use "\\$ip\IPC$" /user:"$user" "$plainPassword" 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { "认证失败" }

# ❌ 错误 1：cmd /c net use —— 会停在交互式密码提示，脚本卡死
# ❌ 错误 2：New-SmbMapping —— 会占用一个盘符，后面 robocopy 用 UNC 路径时冲突
```

用户名依次尝试：`$env:COMPUTERNAME_旧机\用户名` → `$ip\用户名` → `用户名`。
密码从 `Read-Host -AsSecureString` 取，转明文再交给 net.exe（net.exe 不认 SecureString）。

### 3.3 旧电脑侧脚本

运行 `scripts/01-old-share.ps1`（**右键以管理员身份运行**，或用 `launcher-old.bat`）。
它会：改网络为专用 → 启服务 → 放行防火墙 → 共享整个用户目录 + 各非系统盘 →
统计各文件夹占用并输出报告。

---

## 4. 扫描（只统计，不拷贝）

用 `robocopy /L` 批量枚举，**不要用 `Get-ChildItem -Recurse`** —— 走 SMB 时每个
文件一次网络往返，几万个文件能跑几十分钟。

```powershell
robocopy $remotePath "$env:TEMP\_rb_null" /L /E /BYTES /NFL /NDL /NJH /R:0 /W:0 /XJ
```

从汇总表里解析 `字节:` / `Bytes :` 行拿总字节数。

> **坑**：不要加 `/NJS`，否则汇总表里没有字节统计。

运行 `scripts/02-new-scan.ps1`，产出 `笔记本占用报告.txt`，拿给用户勾选要拷哪些。

---

## 5. 拷贝

### 中转盘怎么选

**不要写死盘符。** 新电脑上可能没有 F 盘，或者 F 盘是光驱。脚本默认走这条链：

1. 命令行 `-DestRoot` 显式指定
2. `.migrate-config.json` 里上次用的路径
3. `Suggest-BackupRoot` 自动挑：优先非系统盘、空间最大的那个，且必须放得下数据量

```powershell
Suggest-BackupRoot                        # → 例如 D:\迁移备份（自动挑的，因机器而异）
Suggest-BackupRoot -NeedBytes 900GB       # 空间不够就返回 $null
```

手动跑脚本时 `Resolve-BackupRoot` 会把自动探测结果作为默认值让你确认，
不会静默选一个盘就开始拷。

### 统一参数

```
robocopy 源 目标 /E /R:1 /W:1 /XJ /J /MT:8 /NP /TEE /LOG:<日志>
```

| 参数 | 作用 | 不加会怎样 |
|---|---|---|
| `/E` | 含空目录 | 空文件夹丢失 |
| `/R:1 /W:1` | 失败重试 1 次等 1 秒 | 遇到被占用文件卡几分钟 |
| `/XJ` | 跳过目录联接 | 递归进 `Application Data` 死循环 |
| `/J` | 无缓冲 I/O | 大文件慢很多 |
| `/MT:8` | 8 线程 | 单线程慢 3-5 倍 |
| `/NP` | 不显示百分比 | 日志被进度刷爆 |

**退出码 < 8 都算成功**（1=有文件被拷，2=有额外文件，3=1+2，4/5/6/7 是警告组合）。
只有 ≥8 才是真失败。

### 必须跳过的目录

```
AppData            ← 几十 GB 全是缓存和程序文件，先整体跳过，后面按需精选补拷
node_modules       ← 依赖可以重装，几百 MB~几 GB
.cache .pnpm-store .m2\repository
$RECYCLE.BIN  System Volume Information
```

> **`node_modules` 这个默认值有风险，跳过前先看一眼。**
> 如果旧机上是**已经装好、直接双击就能跑**的 Electron 应用（`resources\app\node_modules`），
> 或者用户的项目依赖装得很麻烦（私有源、编译过的 native 模块），
> 跳过就等于把软件弄坏。这类目录要显式保留，宁可多拷几百 MB。
> 我在真实迁移里就因为这个默认值，把一台机器上的 DSH Desktop 弄成了启动报
> `Cannot find package '@deepseek-ai/dsh-app-boot'`。

### 分批策略

按「重要性 × 体积」排优先级，先拷用户最在意的，随时可以叫停：

1. 桌面 / 文档 / 图片（个人文件，通常几十 MB~几 GB）
2. 各盘的「用户自建目录」（`D:\项目`、`D:\ai大前端` 这类）
3. 聊天记录（微信/QQ 的 Documents 目录）
4. 软件配置（`.dsh`、`.codex`、`.vscode` 等点目录）
5. 大件（游戏、网盘缓存、下载目录）—— 先问用户要不要

**不要自作主张跳过看起来「不重要」的目录。** 用户自建的 `D:\新建文件夹`、
`D:\美化` 往往正是他要的。拿不准就问。

---

## 6. 分发（中转盘 → 真正的位置）

拷到中转盘只是备份，用户要的是**在原位置能用**。`scripts/04-new-distribute.ps1`
用任务表把文件放回 `Desktop`、`Documents`、`D:\...` 等位置。

任务表字段：`N`(名称) `S`(源) `D`(目标) `XD`(跳过目录) `XF`(跳过文件) `Only`(只拷这些)。

**分发前必须确认目标位置**，用 `Get-KnownFolder` 而不是拼 `%USERPROFILE%`：

```powershell
$DESK = Get-KnownFolder Desktop      # 走 Shell Known Folder，OneDrive 重定向也拿得到
$DOCS = Get-KnownFolder MyDocuments
```

用户的桌面/文档很可能被 OneDrive 重定向到 `C:\Users\x\OneDrive\Desktop`，
此时 `C:\Users\x\Desktop` 可能存在但**是空壳**，往里拷等于没拷。

任务表里整盘镜像项（`D盘数据 → D:\`）要检查目标盘是否存在 —— 新电脑可能只有 C 盘。

---

## 7. AppData 精选补拷

`AppData` 整体跳过之后，用户会抱怨「书签没了」「软件要重新登录」。这时补拷
**只挑真配置**：

| 目标 | 路径 | 说明 |
|---|---|---|
| Chrome 书签/密码 | `Google\Chrome\User Data\Default\{Bookmarks,Login Data,Web Data,Preferences}` | `Bookmarks` 是 JSON |
| Edge | `Microsoft\Edge\User Data\Default\...` | 同上 |
| 微信设置 | `Tencent\xwechat_files\<wxid>\...` | **数据库是加密的，换机搬不走聊天记录**，只能搬设置 |
| QQ | `Tencent\QQNT\...` | 新版 QQ 数据库是明文 SQLite，能直接用 |
| WPS | `Kingsoft\office6\...` | 排除 `office6\cache` |

**微信聊天记录是加密的，不要承诺能搬。** 真正的办法是手机中转或让旧机上线
用微信自带的「聊天记录迁移」。见 `reference/pitfalls.md`。

垃圾大户（务必排除）：微信的 `radium` `xplugin` `update` `log` `net` `crashinfo`
（小程序缓存+插件+日志，占整个微信目录 95% 以上）、WPS 的 `office6\cache`。

---

## 8. 修快捷方式

旧电脑的 `.lnk` 拷过来后指向 `C:\Users\<旧用户名>\...`，全部变白块。

```powershell
$sh = New-Object -ComObject WScript.Shell
$s = $sh.CreateShortcut($lnkPath)
$s.TargetPath   # 读出来看指向哪
$s.TargetPath = $newPath
$s.IconLocation = "$newPath,0"
$s.Save()
```

**白块图标的两个不同原因，别搞混：**

| 症状 | 原因 | 修法 |
|---|---|---|
| 图标白块，双击能打开 | **图标缓存损坏** | 删 `%LOCALAPPDATA%\IconCache.db` + 重启 explorer |
| 图标白块，双击报错 | .lnk 指向不存在的路径 | 改 TargetPath 或删掉 |

先双击试一下再决定，**不要直接去删注册表里的文件关联**（那是另一个问题，
删了会造成新的问题）。

---

## 9. 合并书签

Chromium 系（Chrome/Edge/夸克/360）的书签是 JSON：

```
%LOCALAPPDATA%\<浏览器>\User Data\Default\Bookmarks
```

结构：`roots.bookmark_bar.children[]`，每个节点 `{id, name, type, url, date_added}`。

**关键点：**
- `id` 必须全文件唯一。合并时先收集已有 id 建 `used` 集合，新 id 递增直到不冲突。
- 顶层文件夹节点的 `id` 不能和它的第一个子项 `id` 相同（否则浏览器解析异常）。
- `date_added` 是 **1601-01-01 起的微秒**：`BigInt(Date.now()) * 10000n + 11644473600000000n`。
- **不要手写 `checksum`**。Chromium 检测到 checksum 缺失/不匹配会重算，删掉反而更安全。
- 改之前**必须关掉浏览器**，否则退出时会被内存里的数据覆盖回去。

> 用户说「书签别覆盖，加进去就行」= **追加合并到独立文件夹**，不是替换。

---

## 10. 清理

清理前先列清单给用户勾选，**不要默认删**。

**绝对要排除 `%LOCALAPPDATA%\Temp\dsh-*`** —— 那是 DSH 沙箱自己的临时目录，
删掉会让沙箱降级成 ConstrainedLanguage（.NET 静态方法全被拦），后续所有脚本都跑不动。

回收站有个坑：`Clear-RecycleBin -DriveLetter F` 可能报
`The system cannot find the file specified` 但**仍然返回成功**。要用删除前后的大小差
算实际释放量：

```powershell
$before = Get-Size $recycleBinPath
Clear-RecycleBin -DriveLetter F -Force -ErrorAction SilentlyContinue
$after  = Get-Size $recycleBinPath
$freed  = [Math]::Max(0, $before - $after)
```

---

## 11. 环境相关的坑（Windows + DSH 沙箱）

| 现象 | 原因 | 解法 |
|---|---|---|
| `Get-PSDrive` 返回的 `Used/Free` 是 0 | 沙箱里 PSDrive 信息不全 | `(New-Object System.IO.DriveInfo('F')).AvailableFreeSpace` |
| robocopy 日志读出来是乱码 | 日志是 GBK | `[System.IO.File]::ReadAllLines($f,[System.Text.Encoding]::GetEncoding(936))` |
| 写 `D:\` 或桌面被拒 | 文件沙箱只允许工作区 | `Start-Process powershell -ArgumentList @('-File',$p) -Verb RunAs -Wait` |
| 提权脚本一退出，它启动的 GUI 程序也死了 | 子进程被作业对象带走 | 提权脚本里 `Start-Process` 后立刻 `exit 0`；或改用 `schtasks /create` + `/run` |
| 正则 `$1` 永远是 null | `$1` 是 PowerShell 自动变量 | 用 `$Matches[1]` |
| 变量莫名被覆盖 | PowerShell **变量名不区分大小写**（`$l` 会覆盖 `$L`） | 循环变量用有意义的名字 |
| 打 JS 补丁后语法错 | PS 双引号里反引号是转义符，会吃掉 JS 模板字面量 | 用**单引号**字符串 + JS 字符串拼接 |
| 文件名带冒号写不进去 | Windows 文件名禁用 `:` | 用 `_` 或 `-` 替代 |

---

## 12. 收尾检查清单

拷完分发完，逐项确认：

- [ ] 桌面文件数量、桌面快捷方式双击能开
- [ ] 文档/图片/下载 目录内容对得上
- [ ] 各盘自建目录都在
- [ ] 浏览器书签三处都有「旧电脑书签」文件夹，条数对得上
- [ ] 聊天软件能登录、能读到历史消息
- [ ] 常用软件能启动（缺的按清单装）
- [ ] 用户明确说「没问题了」再清理中转盘

**中转盘在所有项目确认之前不要删。** 用户经常过两天才想起来
「我某个文件呢」。

---

## 脚本索引

| 脚本 | 在哪台机器跑 | 作用 |
|---|---|---|
| `scripts/01-old-share.ps1` | 旧电脑（管理员） | 建共享 + 统计占用 + 出报告 |
| `scripts/02-new-scan.ps1` | 新电脑 | 连旧机 + 扫描占用 + 出报告 |
| `scripts/03-new-copy.ps1` | 新电脑 | 分批 robocopy 拉取到中转盘 |
| `scripts/04-new-distribute.ps1` | 新电脑 | 分发到真正位置 |
| `scripts/05-new-appdata.ps1` | 新电脑 | 补拷 AppData 精选 |
| `scripts/06-new-fix-shortcuts.ps1` | 新电脑 | 修快捷方式 + 清图标缓存 |
| `scripts/07-new-bookmarks.ps1` | 新电脑 | 合并书签到各浏览器 |
| `scripts/08-new-cleanup.ps1` | 新电脑 | 清理垃圾 |
| `scripts/_common.ps1` | — | 公共函数（其余脚本点源引入） |
| `scripts/_bookmarks.ps1` | — | 书签解析/合并（纯函数，可单独测） |

所有脚本开头都有 `param()` 可覆盖的配置项（旧机 IP、账户、中转盘路径），
不写死任何特定机器。以下环境相关的东西**全部是运行时探测的**，不要改回硬编码：

| 需要什么 | 怎么拿 |
|---|---|
| 中转盘 | `Suggest-BackupRoot` / `Resolve-BackupRoot`（按剩余空间自动挑） |
| 桌面、文档等 | `Get-KnownFolder`（Shell Known Folder，兼容 OneDrive 重定向） |
| 本机盘符 | `Get-DriveLetters`（`DriveInfo` 枚举，不写死 C/D/E/F） |
| 旧机 IP | `.migrate-config.json` 缓存 → 网段扫描 → 交互输入 |
| 旧机计算机名 | `nbtstat -A` 反查 |
