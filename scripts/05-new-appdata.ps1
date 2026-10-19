<#
  05-new-appdata.ps1 —— 在【新电脑】上运行
  作用：从旧机补拷 AppData 里真正需要的配置（浏览器书签/密码、软件设置），
        并自动排除垃圾（微信小程序缓存、WPS cache 等）

  用法：
    powershell -NoProfile -ExecutionPolicy Bypass -File .\05-new-appdata.ps1
    或双击 launcher-new-appdata.bat

  参数：
    -SourceIp / -SourceUser / -SourcePass  旧机连接信息
    -DestRoot  备份落地目录（默认 <桌面>\AppData补拷）
    -Only      只跑名称含这些关键字的任务
#>

param(
    [string]$SourceIp,
    [string]$SourceUser,
    [string]$SourcePass,
    [string]$DestRoot,
    [string[]]$Only
)

. "$PSScriptRoot\_common.ps1"

$cfgPath = Join-Path $PSScriptRoot '.migrate-config.json'
$cfg = Load-MigrateConfig $cfgPath
if ($cfg) {
    if (-not $SourceIp)   { $SourceIp   = $cfg.SourceIp }
    if (-not $SourceUser) { $SourceUser = $cfg.SourceUser }
}

$U = $env:USERPROFILE
if (-not $DestRoot) {
    if ($cfg -and $cfg.AppDataDest) { $DestRoot = $cfg.AppDataDest }
    else { $DestRoot = Join-Path (Get-KnownFolder Desktop) 'AppData补拷' }
}

Step "补拷 AppData 精选 → $DestRoot"

if (-not $SourceIp)   { Err '缺少 -SourceIp，先跑 02-new-scan.ps1'; Pause-Exit 1 }
if (-not $SourceUser) { $SourceUser = Read-Default '旧机账户名' }
if (-not $SourcePass) {
    $sec  = Read-Host '旧机密码' -AsSecureString
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try   { $SourcePass = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

if (-not (Connect-Smb -Ip $SourceIp -User $SourceUser -Password $SourcePass)) { Pause-Exit 1 }

$ad    = "\\$SourceIp\UserProfile\AppData"
$logDir = Join-Path $DestRoot '_日志'
New-Item -ItemType Directory -Path $logDir -Force -ErrorAction SilentlyContinue | Out-Null

# ============================================================
#  任务表
#  只挑「真配置」，不拷缓存。体积估算都是实测值。
# ============================================================
$tasks = @(
    # ---------- 浏览器 ----------
    @{
        N = 'Chrome'; S = "$ad\Local\Google\Chrome\User Data"; D = (Join-Path $DestRoot 'Chrome')
        XD = @('Default\Cache', 'Default\Code Cache', 'Default\GPUCache', 'Default\Service Worker',
               'Default\DawnCache', 'Default\ShaderCache', 'ShaderCache', 'GrShaderCache',
               'component_crx_cache', 'Crashpad', 'OptimizationHints', 'Safe Browsing',
               'CertificateRevocation', 'Media Cache', 'GraphiteDawnCache')
        XF = @('*.tmp', '*.log')
        Rec = $true
    }
    @{
        N = 'Edge'; S = "$ad\Local\Microsoft\Edge\User Data"; D = (Join-Path $DestRoot 'Edge')
        XD = @('Default\Cache', 'Default\Code Cache', 'Default\GPUCache', 'Default\Service Worker',
               'Default\DawnCache', 'Default\ShaderCache', 'ShaderCache', 'GrShaderCache',
               'component_crx_cache', 'Crashpad', 'OptimizationHints', 'Safe Browsing',
               'CertificateRevocation', 'Media Cache', 'GraphiteDawnCache')
        XF = @('*.tmp', '*.log')
        Rec = $true
    }
    @{
        N = 'Quark'; S = "$ad\Local\Quark\User Data"; D = (Join-Path $DestRoot 'Quark')
        XD = @('Default\Cache', 'Default\Code Cache', 'Default\GPUCache', 'Default\Service Worker',
               'Crashpad', 'component_crx_cache')
        XF = @('*.tmp', '*.log')
        Rec = $false
    }

    # ---------- 微信 ----------
    # 微信目录 95% 以上是垃圾：小程序缓存(radium)、插件(xplugin)、更新包、日志、网络缓存、崩溃上报
    @{
        N = 'WeChat'; S = "$ad\Roaming\Tencent\xwechat"; D = (Join-Path $DestRoot 'WeChat')
        XD = @('radium', 'xplugin', 'update', 'log', 'net', 'crashinfo',
               'all_users', 'applet', 'Backup', 'Cache', 'Temp')
        XF = @('*.log', '*.tmp', '*.dmp')
        Rec = $true
        Note = '聊天记录数据库是加密的，换机搬不走；这里只搬设置'
    }
    @{
        N = 'WeChat-Old'; S = "$ad\Roaming\Tencent\WeChat"; D = (Join-Path $DestRoot 'WeChat-Old')
        XD = @('All Users', 'Applet', 'Backup', 'Cache', 'Temp', 'crashinfo')
        XF = @('*.log', '*.tmp', '*.dmp')
        Rec = $false
        Note = '旧版微信（3.x）目录，装了新版可以跳过'
    }

    # ---------- QQ ----------
    # 新版 QQ(NT) 数据库是明文 SQLite，能直接搬
    @{
        N = 'QQ'; S = "$ad\Roaming\Tencent\QQ"; D = (Join-Path $DestRoot 'QQ')
        XD = @('Temp', 'Crashpad', 'logs', 'Logs')
        XF = @('*.log', '*.tmp', '*.dmp')
        Rec = $true
    }

    # ---------- 办公 ----------
    @{
        N = 'WPS'; S = "$ad\Roaming\kingsoft\office6"; D = (Join-Path $DestRoot 'WPS')
        XD = @('cache', 'Cache', 'temp', 'Temp', 'log', 'Log', 'backup', 'Backup')
        XF = @('*.log', '*.tmp')
        Rec = $true
        Note = 'backup 里是文档历史版本，需要的话单独拷'
    }
    @{
        N = 'WPS-backup'; S = "$ad\Roaming\kingsoft\office6\backup"; D = (Join-Path $DestRoot 'WPS-backup')
        XD = @(); XF = @()
        Rec = $false
        Note = '文档历史版本，用户要才拷'
    }

    # ---------- 开发工具 ----------
    @{ N = 'VSCode';  S = "$ad\Roaming\Code";        D = (Join-Path $DestRoot 'VSCode');  XD = @('Cache','CachedData','logs','Crashpad','User\workspaceStorage'); XF = @('*.log'); Rec = $false }
    @{ N = 'Cursor';  S = "$ad\Roaming\Cursor";      D = (Join-Path $DestRoot 'Cursor');  XD = @('Cache','CachedData','logs','Crashpad','User\workspaceStorage'); XF = @('*.log'); Rec = $false }
    @{ N = 'Trae';    S = "$ad\Roaming\Trae CN";     D = (Join-Path $DestRoot 'Trae');    XD = @('Cache','CachedData','logs','Crashpad','User\workspaceStorage'); XF = @('*.log'); Rec = $false }
    @{ N = 'JetBrains'; S = "$ad\Roaming\JetBrains"; D = (Join-Path $DestRoot 'JetBrains'); XD = @('*\\caches', '*\\log', '*\\tmp'); XF = @('*.log'); Rec = $false }

    # ---------- 输入法 / 系统 ----------
    @{ N = 'Sogou';   S = "$ad\Roaming\SogouInput";  D = (Join-Path $DestRoot 'Sogou');   XD = @('Cache','log'); XF = @('*.log'); Rec = $false }
    @{ N = 'Microsoft-Input'; S = "$ad\Roaming\Microsoft\InputMethod"; D = (Join-Path $DestRoot 'MS-Input'); XD = @(); XF = @(); Rec = $false }

    # ---------- 其他常见软件 ----------
    @{ N = 'NetEase-Music'; S = "$ad\Local\NetEase\CloudMusic"; D = (Join-Path $DestRoot 'NetEase'); XD = @('Cache','Temp','webdata'); XF = @('*.log'); Rec = $false }
    @{ N = 'PotPlayer';     S = "$ad\Roaming\PotPlayerMini64"; D = (Join-Path $DestRoot 'PotPlayer'); XD = @(); XF = @(); Rec = $false }
    @{ N = 'BaiduNetdisk';  S = "$ad\Roaming\baidu\BaiduNetdisk"; D = (Join-Path $DestRoot 'BaiduNetdisk'); XD = @('Cache','temp'); XF = @('*.log'); Rec = $false }
)

# 过滤
$todo = @()
foreach ($t in $tasks) {
    if ($Only -and $Only.Count -gt 0) {
        $hit = $false
        foreach ($k in $Only) { if ($t.N -like "*$k*") { $hit = $true; break } }
        if (-not $hit) { continue }
    }
    if (-not (Test-PathSafe -Path $t.S)) {
        Say ("  跳过（源不存在）: {0}" -f $t.N) DarkGray
        continue
    }
    $todo += $t
}

if ($todo.Count -eq 0) { Err '没有可补拷的任务'; Pause-Exit 1 }

Say ''
Say '  ── 补拷计划 ────────────────────────────────────────────' Cyan
foreach ($t in $todo) {
    $mark = if ($t.Rec) { '*' } else { ' ' }
    Say ("  {0} {1,-16} → {2}" -f $mark, $t.N, $t.D) Gray
    if ($t.Note) { Hint $t.Note }
}
Write-Host ''
Say '  * = 默认勾选（重点项）' DarkGray
Write-Host ''
$go = Read-Default '开始补拷？(y/n)' 'y'
if ($go -notmatch '^[Yy]') { Pause-Exit 0 }

# ============================================================
#  执行
# ============================================================
$results = @()
$idx = 0
foreach ($t in $todo) {
    $idx++
    Step ("[{0}/{1}] {2}" -f $idx, $todo.Count, $t.N)
    New-Item -ItemType Directory -Path $t.D -Force -ErrorAction SilentlyContinue | Out-Null

    $log = Join-Path $logDir ("{0}_{1}.log" -f $t.N, (Get-Date -Format 'yyyyMMdd_HHmmss'))
    $t0  = Get-Date
    $ok  = Invoke-Robocopy -Source $t.S -Dest $t.D -ExcludeDirs $t.XD -ExcludeFiles $t.XF -LogFile $log
    $sec = [math]::Round(((Get-Date) - $t0).TotalSeconds, 1)

    $sz = Get-DirSize $t.D
    if ($ok) {
        Ok ("{0}   {1}  {2} 个文件  {3}s" -f $t.N, (Format-Size $sz.Bytes), $sz.Files, $sec)
    } else {
        Err ("{0} 有错误，见 {1}" -f $t.N, $log)
    }
    $results += [pscustomobject]@{ Name = $t.N; Ok = $ok; Bytes = $sz.Bytes; Files = $sz.Files }
}

# ============================================================
#  汇总
# ============================================================
$totalBytes = [long](($results | Measure-Object -Property Bytes -Sum).Sum)
$totalFiles = [int](($results | Measure-Object -Property Files -Sum).Sum)
$failCount  = @($results | Where-Object { -not $_.Ok }).Count

Step '补拷完成'
Say ("  合计 {0}  {1:N0} 个文件  失败 {2} 项" -f (Format-Size $totalBytes), $totalFiles, $failCount) Cyan

if ($totalBytes -gt 500MB) {
    Warn "体积偏大（>500 MB），可能有垃圾没排除干净。检查各任务日志里的目录明细。"
}

Save-MigrateConfig -Path $cfgPath -Config @{
    SourceIp    = $SourceIp
    SourceUser  = $SourceUser
    AppDataDest = $DestRoot
    # 不要在这里编一个中转盘默认值，否则会覆盖掉用户真正用过的路径
    DestRoot    = $(if ($cfg -and $cfg.DestRoot) { $cfg.DestRoot } else { '' })
}

Write-Host ''
Say '  ── 下一步 ──────────────────────────────────────────────' Cyan
Say '  运行 06-new-fix-shortcuts.ps1 修快捷方式' White
Write-Host ''

Disconnect-Smb $SourceIp
Pause-Exit $(if ($failCount -gt 0) { 2 } else { 0 })
