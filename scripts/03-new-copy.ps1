<#
  03-new-copy.ps1 —— 在【新电脑】上运行（不需要管理员）
  作用：按任务表把旧机数据 robocopy 到中转盘

  用法：
    powershell -NoProfile -ExecutionPolicy Bypass -File .\03-new-copy.ps1
    或双击 launcher-new-copy.bat

  参数：
    -DestRoot   中转盘根目录（不填则从配置读，再不行自动挑一个空间足够的盘）
    -Mode       core  = 核心数据（跳过 AppData，约等于个人文件+配置，快）
                all   = 全部（含 AppData，慢但全）
                custom= 只拷 $Plan 里 Enable=$true 的项
    -SourceIp / -SourceUser / -SourcePass  同 02
#>

param(
    [string]$DestRoot,
    [ValidateSet('core', 'all', 'custom')]
    [string]$Mode = 'core',
    [string]$SourceIp,
    [string]$SourceUser,
    [string]$SourcePass
)

. "$PSScriptRoot\_common.ps1"

$cfgPath = Join-Path $PSScriptRoot '.migrate-config.json'
$cfg = Load-MigrateConfig $cfgPath
if ($cfg) {
    if (-not $SourceIp)   { $SourceIp   = $cfg.SourceIp }
    if (-not $SourceUser) { $SourceUser = $cfg.SourceUser }
}

if (-not $DestRoot) {
    if ($cfg -and $cfg.DestRoot) { $DestRoot = $cfg.DestRoot }
}
if (-not $DestRoot) {
    $DestRoot = Resolve-BackupRoot -Current '' -Leaf '迁移备份'
    if (-not $DestRoot) { Pause-Exit 1 }
}

Step "拷贝数据 → $DestRoot   (模式: $Mode)"

# ============================================================
#  前置检查
# ============================================================
if (-not $SourceIp) {
    Err '缺少 -SourceIp，先跑 02-new-scan.ps1'
    Pause-Exit 1
}
if (-not $SourceUser) {
    $SourceUser = Read-Default '旧机账户名'
}
if (-not $SourcePass) {
    $sec = Read-Host '旧机密码' -AsSecureString
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try   { $SourcePass = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

# 中转盘空间
$destDrive = ($DestRoot -split ':')[0] + ':'
$free = Get-FreeSpace $destDrive
Say ("  中转盘 {0} 可用: {1}" -f $destDrive, (Format-Size $free)) Cyan
if ($free -lt 5GB) {
    Err '中转盘可用空间不足 5 GB'
    Pause-Exit 1
}

if (-not (Test-PathSafe -Path $DestRoot)) {
    New-Item -ItemType Directory -Path $DestRoot -Force | Out-Null
    Ok "已创建 $DestRoot"
}

$logDir = Join-Path $DestRoot '_日志'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null

if (-not (Connect-Smb -Ip $SourceIp -User $SourceUser -Password $SourcePass)) {
    Pause-Exit 1
}

# ============================================================
#  任务表
#  字段：
#    N     名称（也是目标子目录名）
#    S     源路径（可含 $src 变量）
#    Enable 是否启用（custom 模式只看这个）
#    XD    跳过目录（相对或绝对）
#    XF    跳过文件
#    Group 分组（用于显示）
# ============================================================
$src  = "\\$SourceIp"
$upro = "$src\UserProfile"

# 核心模式统一跳过的（AppData 是大头，缓存类全跳过）
$coreXD = @('AppData', '.cache', '.pnpm-store', '.m2\repository', 'node_modules',
            '$RECYCLE.BIN', 'System Volume Information')

$Plan = @(
    # ---------- 一、个人文件（最重要） ----------
    @{ N = 'Desktop';        S = "$upro\Desktop";      Group = '个人文件'; Enable = $true;  XD = @(); XF = @('desktop.ini', '~$*') }
    @{ N = 'Documents';      S = "$upro\Documents";    Group = '个人文件'; Enable = $true;  XD = @(); XF = @('desktop.ini', 'Default.rdp') }
    @{ N = 'Downloads';      S = "$upro\Downloads";    Group = '个人文件'; Enable = $true;  XD = @(); XF = @('desktop.ini') }
    @{ N = 'Pictures';       S = "$upro\Pictures";     Group = '个人文件'; Enable = $true;  XD = @(); XF = @('desktop.ini') }
    @{ N = 'Videos';         S = "$upro\Videos";       Group = '个人文件'; Enable = $true;  XD = @(); XF = @('desktop.ini') }
    @{ N = 'Music';          S = "$upro\Music";        Group = '个人文件'; Enable = $true;  XD = @(); XF = @('desktop.ini') }
    @{ N = 'Favorites';      S = "$upro\Favorites";    Group = '个人文件'; Enable = $true;  XD = @(); XF = @() }

    # ---------- 二、软件配置（用户目录下的点目录） ----------
    @{ N = '.ssh';           S = "$upro\.ssh";         Group = '软件配置'; Enable = $true;  XD = @(); XF = @() }
    @{ N = '.gitconfig';     S = "$upro\.gitconfig";   Group = '软件配置'; Enable = $true;  XD = @(); XF = @() }
    @{ N = '.vscode';        S = "$upro\.vscode";      Group = '软件配置'; Enable = $true;  XD = @(); XF = @() }
    @{ N = '.codex';         S = "$upro\.codex";       Group = '软件配置'; Enable = $true;  XD = @(); XF = @() }
    @{ N = '.claude';        S = "$upro\.claude";      Group = '软件配置'; Enable = $true;  XD = @(); XF = @() }
    @{ N = '.dsh';           S = "$upro\.dsh";         Group = '软件配置'; Enable = $true;  XD = @('node_modules', '.cache'); XF = @() }
    @{ N = '.jdks';          S = "$upro\.jdks";        Group = '软件配置'; Enable = $true;  XD = @(); XF = @() }
    @{ N = '.m2';            S = "$upro\.m2";          Group = '软件配置'; Enable = $true;  XD = @('repository'); XF = @() }
    @{ N = '.gradle';        S = "$upro\.gradle";      Group = '软件配置'; Enable = $true;  XD = @('caches', 'daemon'); XF = @() }
    @{ N = 'scoop';          S = "$upro\scoop";        Group = '软件配置'; Enable = $false; XD = @('apps', 'cache'); XF = @() }

    # ---------- 三、聊天记录 ----------
    @{ N = 'Tencent-Files';  S = "$upro\Documents\Tencent Files"; Group = '聊天记录'; Enable = $true; XD = @(); XF = @() }
    @{ N = 'WeChat-Files';   S = "$upro\Documents\WeChat Files";  Group = '聊天记录'; Enable = $true; XD = @(); XF = @() }

    # ---------- 四、用户目录其他子目录（含 AppData 的话在 all 模式） ----------
    @{ N = 'AppData';        S = "$upro\AppData";      Group = '系统数据'; Enable = $false; XD = @('Local\Temp', 'Local\Microsoft\Windows\INetCache', 'Local\Packages'); XF = @() }

    # ---------- 五、其他盘（下面按旧机实际存在的共享动态追加，不写死盘符） ----------
)

# 动态发现旧机的盘共享：01-old-share.ps1 会建 Drive<字母>，
# 这里把实际存在的都加进计划表（all / custom 模式才启用）。
$remoteDrives = @()
foreach ($L in [char[]](65..90)) {
    $rp = "$src\Drive$L"
    if (Test-PathSafe -Path $rp) { $remoteDrives += $L }
}
foreach ($L in $remoteDrives) {
    $Plan += @{
        N = "Drive$L"; S = "$src\Drive$L"; Group = '其他盘'; Enable = $false
        XD = @('$RECYCLE.BIN', 'System Volume Information'); XF = @()
    }
}
if ($remoteDrives.Count -gt 0) {
    Say ("  旧机盘共享: {0}" -f (($remoteDrives | ForEach-Object { "${_}:" }) -join ' ')) DarkGray
}

# 按模式调整
switch ($Mode) {
    'core' {
        foreach ($p in $Plan) {
            if ($p.Group -eq '系统数据') { $p.Enable = $false }
        }
    }
    'all' {
        foreach ($p in $Plan) {
            # 不写死盘符：凡是「其他盘」组和 AppData 都启用
            if ($p.N -eq 'AppData' -or $p.Group -eq '其他盘') { $p.Enable = $true }
        }
    }
    'custom' { }
}

# 过滤出不存在的源
# 旧机如果开了 OneDrive 备份，桌面/文档的真实位置是
#   \\旧机\UserProfile\OneDrive\Desktop
# 而 \\旧机\UserProfile\Desktop 可能是个空壳（或根本不存在）。
# 这里对用户目录下的标准文件夹做一次 OneDrive 兜底。
$oneDriveFallback = @{
    'Desktop'   = 'Desktop'
    'Documents' = 'Documents'
    'Pictures'  = 'Pictures'
    'Videos'    = 'Videos'
    'Music'     = 'Music'
    'Favorites' = 'Favorites'
}

$todo = @()
foreach ($p in $Plan) {
    if (-not $p.Enable) { continue }
    if (-not (Test-PathSafe -Path $p.S)) {
        $alt = $null
        if ($oneDriveFallback.ContainsKey($p.N)) {
            $cand = "$upro\OneDrive\$($oneDriveFallback[$p.N])"
            if (Test-PathSafe -Path $cand) { $alt = $cand }
            # 中文系统 OneDrive 文件夹可能是「桌面」「文档」
            if (-not $alt) {
                $zh = @{ 'Desktop'='桌面'; 'Documents'='文档'; 'Pictures'='图片'; 'Videos'='视频'; 'Music'='音乐' }[$p.N]
                if ($zh) {
                    $cand2 = "$upro\OneDrive\$zh"
                    if (Test-PathSafe -Path $cand2) { $alt = $cand2 }
                }
            }
        }
        if ($alt) {
            Say ("  源改走 OneDrive: {0}  ->  {1}" -f $p.N, $alt) Yellow
            $p.S = $alt
        } else {
            Say ("  跳过（源不存在）: {0}" -f $p.N) DarkGray
            continue
        }
    }
    $todo += $p
}

if ($todo.Count -eq 0) {
    Err '没有可拷贝的任务'
    Pause-Exit 1
}

Say ''
Say '  ── 拷贝计划 ────────────────────────────────────────────' Cyan
foreach ($g in ($todo | Group-Object Group)) {
    Say "  [$($g.Name)]" Yellow
    foreach ($p in $g.Group) {
        Say ("    {0,-20} {1}" -f $p.N, $p.S) Gray
    }
}
Write-Host ''
Say ("  共 {0} 项。已拷过的文件会自动跳过（robocopy 增量），可随时 Ctrl+C 中断后重跑。" -f $todo.Count) Cyan
Write-Host ''
$go = Read-Default '开始拷贝？(y/n)' 'y'
if ($go -notmatch '^[Yy]') { Pause-Exit 0 }

# ============================================================
#  执行
# ============================================================
$results  = @()
$startAll = Get-Date
$idx = 0

foreach ($p in $todo) {
    $idx++
    $dest   = Join-Path $DestRoot $p.N
    $stamp  = Get-Date -Format 'yyyyMMdd_HHmmss'
    $log    = Join-Path $logDir ("{0}_{1}.log" -f $p.N, $stamp)

    Step ("[{0}/{1}] {2}" -f $idx, $todo.Count, $p.N)
    Say "  源:   $($p.S)" DarkGray
    Say "  目标: $dest" DarkGray
    Say "  日志: $log" DarkGray

    # 展开 XD 里的相对路径
    $xd = @()
    foreach ($x in $p.XD) {
        if ($x -match '\\') { $xd += (Join-Path $p.S $x) } else { $xd += $x }
    }

    New-Item -ItemType Directory -Path $dest -Force -ErrorAction SilentlyContinue | Out-Null

    $t0 = Get-Date
    $okFlag = Invoke-Robocopy -Source $p.S -Dest $dest -ExcludeDirs $xd -ExcludeFiles $p.XF -LogFile $log
    $t1 = Get-Date
    $sec = [math]::Round(($t1 - $t0).TotalSeconds, 1)

    $sz = Get-DirSize $dest
    $speed = if ($sec -gt 0) { $sz.Bytes / $sec } else { 0 }

    if ($okFlag) {
        Ok ("完成 {0}   {1}  {2} 个文件  耗时 {3}s   均速 {4}/s" -f $p.N, (Format-Size $sz.Bytes), $sz.Files, $sec, (Format-Size $speed))
    } else {
        Err ("{0} 有错误，见日志 {1}" -f $p.N, $log)
    }

    $results += [pscustomobject]@{
        Name   = $p.N
        Group  = $p.Group
        Ok     = $okFlag
        Bytes  = $sz.Bytes
        Files  = $sz.Files
        Seconds= $sec
        Log    = $log
    }
}

# ============================================================
#  汇总
# ============================================================
$totalSec = [math]::Round(((Get-Date) - $startAll).TotalSeconds, 1)
$totalBytes = [long](($results | Measure-Object -Property Bytes -Sum).Sum)
$totalFiles = [int](($results | Measure-Object -Property Files -Sum).Sum)
$failCount  = @($results | Where-Object { -not $_.Ok }).Count

Step '拷贝完成'

foreach ($r in $results) {
    $mark = if ($r.Ok) { 'OK  ' } else { 'FAIL' }
    $color = if ($r.Ok) { 'Gray' } else { 'Red' }
    Say ("  [{0}] {1,-20} {2}  {3,8} 个文件  {4,7}s" -f $mark, $r.Name, (Format-Size $r.Bytes), $r.Files, $r.Seconds) $color
}
Write-Host ''
Say ("  合计: {0}  {1:N0} 个文件  耗时 {2} 分钟  失败 {3} 项" -f (Format-Size $totalBytes), $totalFiles, [math]::Round($totalSec/60,1), $failCount) Cyan

# 写汇总
$summary = Join-Path $DestRoot '_拷贝汇总.txt'
try {
    $lines = @()
    $lines += "拷贝时间: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    $lines += "模式: $Mode"
    $lines += "源: $src"
    $lines += "目标: $DestRoot"
    $lines += ''
    foreach ($r in $results) {
        $lines += ("{0,-6} {1,-20} {2}  {3,8} 个文件  {4,7}s  {5}" -f
                   $(if ($r.Ok) { 'OK' } else { 'FAIL' }), $r.Name, (Format-Size $r.Bytes), $r.Files, $r.Seconds, $r.Log)
    }
    $lines += ''
    $lines += ("合计: {0}  {1} 个文件  耗时 {2} 分钟  失败 {3} 项" -f
               (Format-Size $totalBytes), $totalFiles, [math]::Round($totalSec/60,1), $failCount)
    [System.IO.File]::WriteAllLines($summary, $lines, (New-Object System.Text.UTF8Encoding($true)))
    Ok "汇总已保存: $summary"
} catch { }

Save-MigrateConfig -Path $cfgPath -Config @{
    SourceIp   = $SourceIp
    SourceUser = $SourceUser
    DestRoot   = $DestRoot
}

Write-Host ''
Say '  ── 下一步 ──────────────────────────────────────────────' Cyan
Say '  运行 04-new-distribute.ps1，把中转盘的文件分发到真正的位置' White
Write-Host ''

Disconnect-Smb $SourceIp
Pause-Exit $(if ($failCount -gt 0) { 2 } else { 0 })
