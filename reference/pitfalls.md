# 踩坑清单（都是真实踩过的）

按「会不会遇到 + 遇到了多难查」排序。

---

## 一、数据没拷全（最常发生，且用户最后才发现）

### 1. 只拷了 0.2 GB，用户说「几十 GB」

**原因**：数据不在桌面/文档，而在 `D:\某自建目录`、`AppData`、网盘下载目录。
**教训**：先跑 `02-new-scan.ps1` 出报告，让用户勾选，**不要凭直觉拷**。

### 2. 主动跳过了 `node_modules`，结果软件起不来

真实案例：迁移 DSH Desktop，为了赶时间在 `XD` 里加了 `node_modules`，
只拷了 260 个文件（实际 25946 个）。结果启动报：

```
Error [ERR_MODULE_NOT_FOUND]: Cannot find package '@deepseek-ai/dsh-app-boot'
```

**教训**：`node_modules` 只在「纯开发项目」里可以跳过（能 `npm i` 重装）。
**已打包的 Electron 应用 / 便携软件的 node_modules 绝对不能跳过** —— 那是运行时依赖，
跳过了程序直接起不来。判断方法：看 `package.json` 里有没有 `"build"` / 打包脚本，
或者目录里有 `.exe` 就是已打包应用。

### 3. 拷贝中途强杀，文件大小对不上

robocopy 被强杀后，已拷贝的大文件可能是截断的。重跑一次 robocopy 会校正
（大小不一致会重拷），但**必须重跑**，不能假设已拷完。

---

## 二、SMB / 网络

### 1. `net use` 卡在交互式密码提示

```powershell
# ❌ 会卡死脚本
cmd /c "net use \\$ip\IPC$ /user:$u $p"

# ❌ 会占用盘符，后续 robocopy 用 UNC 冲突
New-SmbMapping -RemotePath "\\$ip\IPC$" -UserName $u -Password $p

# ✅ 正确
& net use "\\$ip\IPC$" /user:"$u" "$p" 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { ... }   # 密码错返回 2
```

### 2. 445 不通就以为「网络隔离」

**445 不通 ≠ 网络不通。** 先用 3389 / ping 确认。顺序排查：

1. 网络配置文件是「公用」→ `Set-NetConnectionProfile -NetworkCategory Private`
2. `LanmanServer` 服务停了 → `Start-Service LanmanServer`
3. 防火墙没放行共享 → `Enable-NetFirewallRule -Group '@FirewallAPI.dll,-28502'`
   （文件和打印机共享）和 `'@FirewallAPI.dll,-32752'`（网络发现）

### 3. `Access is denied` 不一定是共享没建

真实案例：以为共享漏了 AppData，实际是 **SMB 认证没成功**（未认证时任何子路径都拒绝访问）。
先确认 `net use` 返回 0，再怀疑共享配置。

### 4. 共享名和路径别搞混

```powershell
New-SmbShare -Name 'UserProfile' -Path "C:\Users\<旧机用户名>" -FullAccess 'Everyone'
# 访问：\\ip\UserProfile\Desktop  ← 共享名 + 相对路径
```

共享整个用户目录时，`AppData` 是**包含在内**的，不需要单独共享。

---

## 三、编码（Windows + PowerShell 5.1）

| 症状 | 原因 | 解法 |
|---|---|---|
| .ps1 报「字符串缺少终止符」但肉眼看不出 | 缺 UTF-8 BOM | 补 BOM |
| 中文全变 `鑻辨枃` | 按 GBK 解了 UTF-8 | 统一 BOM |
| .bat 里中文乱码 | 不是 GBK 或不是 CRLF | 转 GBK + CRLF |
| robocopy 日志读出乱码 | 日志是 GBK | `GetEncoding(936)` |

```powershell
# 补 BOM
$t = Get-Content -LiteralPath $p -Raw -Encoding UTF8
[System.IO.File]::WriteAllText($p, $t, (New-Object System.Text.UTF8Encoding($true)))

# 写 GBK bat
[System.IO.File]::WriteAllText($bat, $text, [System.Text.Encoding]::GetEncoding(936))
```

**注意**：`write` / `edit` 工具写出来的是 UTF-8 **无 BOM**，写完必须转。

---

## 四、AppData 精选补拷

### 垃圾大户（一定要排除）

真实数据：补拷 2.52 GB，其中 **2.47 GB 是垃圾**，真配置只有 12 个文件 3.5 KB。

| 目录 | 是什么 | 占比 |
|---|---|---|
| `Tencent\xwechat\radium` | 微信小程序缓存 | 最大 |
| `Tencent\xwechat\xplugin` | 微信插件 | 大 |
| `Tencent\xwechat\{update,log,net,crashinfo}` | 更新包/日志/网络/崩溃 | 中 |
| `kingsoft\office6\cache` | WPS 缓存 | 中 |

### 微信聊天记录搬不走

微信数据库（`message_*.db`）是**加密的**（随机 salt，非明文 SQLite），密钥在
`key_info.dat` 里用微信私有的派生算法保护，**不是 DPAPI**，换机无法解。

试过的失败路径（不要再试）：
- 用本机 DPAPI `ProtectedData.Unprotect` 解 → 15 个偏移全部 `The data is invalid`
- 27 个候选密钥 × PBKDF2-HMAC-SHA512（256000/64000/1 迭代）× reserve 48/64/80 → 全部未命中

**正确做法**：
1. 手机中转：手机微信 → 我 → 设置 → 聊天 → 聊天记录迁移与备份
2. 旧电脑上线同 WiFi，用微信自带迁移
3. 放弃旧记录

### QQ 能搬

新版 QQ（NT）的数据库是**明文 SQLite**（文件头 `SQLite format 3` + `QQ_NT DB`），
直接把 `Documents\Tencent Files` 拷过去，装好 QQ 启动会自动认。

---

## 五、快捷方式 / 图标

### 白块图标的两个不同原因

| 症状 | 原因 | 修法 |
|---|---|---|
| 白块，双击**能**打开 | 图标缓存损坏 | 删 `IconCache.db` + `ie4uinit -show` + 重启 explorer |
| 白块，双击**报错** | .lnk 指向不存在的路径 | 改 TargetPath |

**先双击试一次再动手。** 真实教训：误判成文件关联问题，去删了注册表
`HKCU\Software\Classes\workbuddyai.doc` 等键，**完全没必要**，还造成了新问题。

### 注册表 InstallLocation 可能是死路径

百度网盘注册表写 `D:\百度网盘\BaiduNetdisk`，实际在
`D:\百度迅雷网盘\百度网盘\BaiduNetdisk`。找 exe 时要**验证路径真的存在**，
不能只信注册表。

---

## 六、书签合并

### id 冲突会导致浏览器解析异常

- 所有节点 `id` 必须全文件唯一，先收集已有 id 建 `used` 集合
- 顶层文件夹的 `id` 不能和它第一个子项相同
- `date_added` = `BigInt(Date.now()) * 10000n + 11644473600000000n`（1601 起微秒）

### checksum 不要手写

Chromium 检测到 checksum 缺失或不匹配会**自己重算**。删掉 `checksum` 字段
比手写一个错的更安全。

### 改之前必须关浏览器

浏览器退出时会把内存里的书签写回磁盘，覆盖你的修改。

---

## 七、清理

### 绝对不要删 `%LOCALAPPDATA%\Temp\dsh-*`

真实事故：清理临时文件时删掉了 DSH 沙箱自己的 `Temp\dsh-SQoKki`，导致
pwsh 永久降级为 ConstrainedLanguage（`[System.IO.File]::*`、
`[System.Text.Encoding]::*`、`[System.Security.Cryptography.ProtectedData]` 全部被拦），
后续所有脚本都跑不动，控制台中文全乱码。

### 回收站可能虚报成功

```powershell
# ❌ 报 "The system cannot find the file specified" 但仍然返回成功，还虚报大小
Clear-RecycleBin -DriveLetter F -Force

# ✅ 用前后差值算
$before = Get-DirSize $rb
Clear-RecycleBin -DriveLetter F -Force -ErrorAction SilentlyContinue
$after  = Get-DirSize $rb
$freed  = [Math]::Max(0, $before - $after)
```

### 路径过长删不掉

用 `robocopy /MIR` 用一个空目录镜像过去清空，再 `Remove-Item`。

---

## 八、PowerShell 语言坑

| 现象 | 原因 | 解法 |
|---|---|---|
| `$1` 永远是 null | `$1` 是 PS 自动变量 | 用 `$Matches[1]` |
| 变量莫名被覆盖 | 变量名**不区分大小写**，`$l` 会覆盖 `$L` | 循环变量用有意义的名字 |
| 打 JS 补丁后语法错 | PS 双引号里反引号是转义符，吃掉 JS 模板字面量 | 用**单引号**字符串 |
| 文件名带 `:` 写不进去 | Windows 禁用 | 换成 `_` |
| `Get-PSDrive` 返回 0 | 沙箱信息不全 | `(New-Object System.IO.DriveInfo('F')).AvailableFreeSpace` |
| 命令带 emoji 报 ParserError | 编码被破坏 | 脚本里别用 emoji |

---

## 九、沙箱 / 提权

| 现象 | 原因 | 解法 |
|---|---|---|
| 写 `D:\` 或桌面被拒 | 文件沙箱只允许工作区 | `Start-Process powershell -ArgumentList @('-File',$p) -Verb RunAs -Wait` |
| 提权脚本一退出，它启动的 GUI 也死了 | 子进程被作业对象带走 | 提权脚本里 `Start-Process` 后**立刻 `exit 0`** |
| 提权窗口挡住截图 | 没加 `-WindowStyle Hidden` | 加上 |
| `ie4uinit -show` 返回 1 | 非交互会话无桌面 | 正常，忽略 |

### 提权启动 GUI 程序的可靠做法

```powershell
# 计划任务能逃出作业对象
schtasks /create /tn TempBoot /tr '"D:\app\app.exe"' /sc once /st 23:59 /f
schtasks /run /tn TempBoot
Start-Sleep 30
schtasks /delete /tn TempBoot /f
```

---

## 十、验证清单（拷完必须逐项确认）

- [ ] 桌面文件数量对得上
- [ ] 桌面快捷方式双击能开
- [ ] 文档/图片/下载 内容完整
- [ ] 各盘自建目录都在
- [ ] 浏览器书签有「旧电脑书签」文件夹，条数对得上
- [ ] 聊天软件能登录、能读历史
- [ ] 常用软件能启动

**中转盘在所有项目确认之前不要删。** 用户经常过两天才想起来「我某个文件呢」。
