# pc-migrate

**Windows 电脑迁移工具包** —— 把旧电脑上的个人文件、软件配置、聊天记录、浏览器书签、
桌面快捷方式，整体搬到新电脑。

局域网 SMB 直连 + robocopy，**不依赖网盘、不依赖外网、不上传任何数据**。
几十 GB 的数据走一根网线或同一个 WiFi 就能搬完。

```
旧电脑                          新电脑
─────────────────────────────────────────────────────
① 建 SMB 共享 ──────────────► ② 探测 + 扫描（只统计不拷）
   共享用户目录 + 各盘              robocopy /L 快速枚举
                                    ↓ 出「占用报告」给你选
                                ③ 分批 robocopy 拉取到中转盘
                                    ↓
                                ④ 分发到真正能用的位置
                                ⑤ 补拷 AppData 精选
                                ⑥ 修快捷方式 + 合并书签
                                ⑦ 清理垃圾
```

旧电脑只需要做 ①，其余全部在新电脑上跑。旧电脑随时可以关机，中途断了重跑即可
（robocopy 增量跳过已拷文件）。

---

## 为什么不用现成方案

| 方案 | 问题 |
|---|---|
| 网盘 | 几十 GB 要传一整天，上传带宽是瓶颈；隐私数据过第三方 |
| 移动硬盘 | 要拆机/找硬盘，系统盘的文件权限（ACL）拷出来常丢 |
| Windows 轻松传送 | Win10 起已废弃 |
| 手动复制粘贴 | 隐藏文件、点目录（`.ssh`、`.dsh`）全丢；AppData 根本拷不动 |
| 各类「一键迁移」商业软件 | 收费，且常带捆绑 |

这个工具包解决的是**真实迁移里会遇到的具体问题**，不是理想流程：白块图标、
书签没同步、聊天记录打不开、快捷方式指向旧用户名、`Get-PSDrive` 返回 0、
robocopy 日志是 GBK……

---

## 快速开始

### 方式一：作为 DSH 技能使用（推荐）

```powershell
# 拷到技能目录
git clone https://github.com/<your-name>/pc-migrate.git "$env:USERPROFILE\.dsh\skills\pc-migrate"
```

之后直接对 AI 说「帮我把旧电脑的东西搬到新电脑」，技能会被自动加载。

### 方式二：直接跑脚本

下载/克隆到任意位置，双击对应的 `.bat` 即可（脚本自己处理 UAC 和编码）。

#### 旧电脑（只需做一次）

双击 **`launcher-old.bat`**，会弹 UAC，点「是」。它会：

1. 把网络配置文件改成「专用」（否则防火墙拦 445）
2. 启动 `LanmanServer` 服务
3. 放行「文件和打印机共享」防火墙规则
4. 共享整个用户目录 + 各非系统盘
5. 统计各文件夹占用，输出 `_共享清单.txt`
6. **显示本机 IPv4 地址**（记下来，新电脑要用）

#### 新电脑（按顺序双击）

| 步骤 | 文件 | 做什么 |
|---|---|---|
| 1 | `launcher-new-1-scan.bat` | 连接旧机 + 扫描占用，出报告 |
| 2 | `launcher-new-2-copy.bat` | 拷贝数据到中转盘 |
| 3 | `launcher-new-3-distribute.bat` | 分发到真正能用的位置 |
| 4 | `launcher-new-4-appdata.bat` | 补拷 AppData 精选（书签/密码/设置） |
| 5 | `launcher-new-5-shortcuts.bat` | 修快捷方式 + 清图标缓存 |
| 6 | `launcher-new-6-bookmarks.bat` | 合并浏览器书签 |
| 7 | `launcher-new-7-cleanup.bat` | 清理垃圾（默认只报告，不删） |

**每步都可以中断后重跑。**

---

## 环境要求

- 两台电脑在**同一个局域网**（同一个路由器，或其中一台开热点）
- 旧电脑能开机、能联网
- 新电脑目标盘剩余空间 ≥ 数据量 × 1.5
- Windows 7 以上（PowerShell 5.1 + robocopy，系统自带，无需安装任何东西）
- 旧电脑账户**必须设了密码**（Windows 默认禁止空密码账户远程访问 SMB）

> 不支持跨平台。macOS/Linux 请用 `rsync`。

---

## 直接用 PowerShell 跑

```powershell
cd scripts

# 旧电脑（管理员）
powershell -NoProfile -ExecutionPolicy Bypass -File .\01-old-share.ps1

# 新电脑
powershell -NoProfile -ExecutionPolicy Bypass -File .\02-new-scan.ps1 -SourceIp 192.168.1.20
powershell -NoProfile -ExecutionPolicy Bypass -File .\03-new-copy.ps1 -Mode core
powershell -NoProfile -ExecutionPolicy Bypass -File .\04-new-distribute.ps1
```

### 参数

**`03-new-copy.ps1`**

| 参数 | 说明 | 默认 |
|---|---|---|
| `-DestRoot` | 中转盘根目录 | 自动挑剩余空间最大的非系统盘 |
| `-Mode` | `core` 跳过 AppData / `all` 全拷 / `custom` 按任务表 | `core` |
| `-SourceIp` | 旧机 IP | 从 `.migrate-config.json` 读 |

**`04-new-distribute.ps1`**

| 参数 | 说明 |
|---|---|
| `-BackupRoot` | 备份源目录（不填则自动探测） |
| `-DryRun` | 只列计划不拷贝 |
| `-Only` | 只跑名称含指定关键字的任务，如 `-Only 桌面,文档` |

**`07-new-bookmarks.ps1`**

| 参数 | 说明 |
|---|---|
| `-Source` | 书签文件（`.html` Netscape 格式 或 `.json` Chromium 格式），也可以是目录 |
| `-Browsers` | 目标浏览器，默认 `chrome,edge,quark`；也支持 `brave` |
| `-DryRun` | 只报告不写入 |

**`08-new-cleanup.ps1`**

| 参数 | 说明 |
|---|---|
| `-Apply` | 真正执行删除（不加则只报告） |
| `-KeepBackup` | 保留中转盘，只清本机垃圾 |

---

## 目录结构

```
pc-migrate/
├── SKILL.md                    完整流程 + 编码铁律 + 各种坑（给 AI 看的）
├── README.md                   本文件
├── launcher-old.bat            旧电脑：建共享
├── launcher-new-1-scan.bat     新电脑：扫描
├── launcher-new-2-copy.bat     新电脑：拷贝
├── launcher-new-3-distribute.bat
├── launcher-new-4-appdata.bat
├── launcher-new-5-shortcuts.bat
├── launcher-new-6-bookmarks.bat
├── launcher-new-7-cleanup.bat
├── scripts/
│   ├── _common.ps1             公共函数（其余脚本点源引入）
│   ├── _bookmarks.ps1          书签解析/合并（纯函数，可单测）
│   ├── 01-old-share.ps1
│   ├── 02-new-scan.ps1
│   ├── 03-new-copy.ps1
│   ├── 04-new-distribute.ps1
│   ├── 05-new-appdata.ps1
│   ├── 06-new-fix-shortcuts.ps1
│   ├── 07-new-bookmarks.ps1
│   └── 08-new-cleanup.ps1
└── reference/
    └── pitfalls.md             踩坑清单（真实事故记录）
```

---

## 已知限制

| 限制 | 说明 | 替代方案 |
|---|---|---|
| **微信聊天记录搬不走** | 数据库用随机 salt 加密，密钥派生算法是微信私有的，且与机器绑定。`key_info.dat` 里没有 DPAPI 材料，本机无法解 | 手机中转：微信 → 我 → 设置 → 聊天 → 聊天记录迁移与备份 → 迁移到另一台设备 |
| QQ 聊天记录可以搬 | 新版 QQNT 的 `nt_msg.db` 是明文 SQLite，拷过去能直接读 | — |
| 浏览器密码可能解不开 | Chrome/Edge 的 `Login Data` 用 DPAPI 加密，**换了用户账户或机器**就解不开（同机换用户也不行） | 让浏览器账号同步，或重新登录 |
| 不处理驱动 | 迁移后可能需要装显卡/网卡驱动 | 各厂商官网 |
| 不处理软件授权 | 部分软件绑定硬件指纹，换机会掉授权 | 联系厂商重新激活 |

---

## 重要警告

1. **不要删 `%LOCALAPPDATA%\Temp\dsh-*`** —— DSH 沙箱自己的临时目录，删了沙箱降级
2. **微信聊天记录搬不走** —— 见上面的限制表
3. **中转盘在所有项目确认前不要删** —— 用户经常过两天才想起某个文件
4. **白块图标先双击试试** —— 能打开是缓存问题，报错才是快捷方式问题；别去删注册表

详见 `reference/pitfalls.md`。

---

## 自定义

任务表都在各脚本里，格式统一：

```powershell
@{ N='名称'; S='源路径'; D='目标路径'; XD=@('跳过目录'); XF=@('跳过文件'); Rec=$true }
```

- `N` 名称（也用作目标子目录名）
- `S` 源路径
- `D` 目标路径
- `XD` 跳过目录
- `XF` 跳过文件
- `Only` 只拷这些文件
- `Rec` 是否默认勾选

改完直接跑对应脚本即可。

---

## 编码约定（改脚本前必读）

这个仓库里的文件编码**不是随便选的**，改错了一定乱码：

| 文件类型 | 必须的编码 | 换行 |
|---|---|---|
| `.ps1` | **UTF-8 with BOM** | CRLF |
| `.bat` / `.cmd` | **GBK (代码页 936)** | **CRLF** |
| `.md` / `.json` | UTF-8 无 BOM | LF |

PowerShell 5.1 靠 BOM 判断文件编码。`.ps1` 缺 BOM 会把中文注释按 GBK 解，
吞掉后面的代码，报一堆假的语法错误。`.bat` 不是 GBK 则 `echo` 中文全是乱码。

`.gitattributes` 已配置好，但**编辑器保存时仍要确认 BOM 没被去掉**。

---

## 致谢

流程和踩坑记录来自一次真实的 100 GB 级迁移：Windows 10 笔记本 → 新台式机，
跨两个不同的用户账户，中途遇到校园网限速、防火墙拦 445、
白块图标、书签丢失、Electron 应用 `node_modules` 漏拷等问题。

---

## License

[MIT](LICENSE)
