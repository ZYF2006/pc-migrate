<#
  02-new-scan.ps1 —— 在【新电脑】上运行（不需要管理员）
  作用：连旧机 + 扫描各目录占用（只统计不拷贝）+ 出报告给用户勾选

  用法：
    powershell -NoProfile -ExecutionPolicy Bypass -File .\02-new-scan.ps1
    或双击 launcher-new-scan.bat

  参数：
    -SourceIp    旧机 IP（不填则自动探测）
    -SourceName  旧机计算机名（DNS 能解析时可用）
    -SourceUser  旧机账户名
    -SourcePass  旧机密码
#>

param(
    [string]$SourceIp,
    [string]$SourceName,
    [string]$SourceUser,
    [string]$SourcePass,
    [string]$ReportPath
)

. "$PSScriptRoot\_common.ps1"

Step '新电脑：探测旧机 + 扫描占用（只统计，不拷贝）'

$cfgPath = Join-Path $PSScriptRoot '.migrate-config.json'
$cfg = Load-MigrateConfig $cfgPath
if ($cfg) {
    if (-not $SourceIp)   { $SourceIp   = $cfg.SourceIp }
    if (-not $SourceName) { $SourceName = $cfg.SourceName }
    if (-not $SourceUser) { $SourceUser = $cfg.SourceUser }
}

# ============================================================
#  1. 找旧机
# ============================================================
Step '1/3  定位旧机'

if (-not $SourceIp) {
    Say '  自动搜索旧机 ...' DarkGray
    $SourceIp = Find-MigrateSource -NotebookName $SourceName `
                                  -CacheFile (Join-Path $PSScriptRoot '.last-migrate-ip.txt')
}

if (-not $SourceIp) {
    Err '没有找到旧机'
    Hint '请手动输入旧机 IP（在旧机上运行 01-old-share.ps1 会显示）'
    $SourceIp = Read-Default '旧机 IP'
    if (-not $SourceIp) { Pause-Exit 1 }
}

Ok "旧机 IP: $SourceIp"

# 端口检查
$p445  = Test-Port $SourceIp 445  2000
$p3389 = Test-Port $SourceIp 3389 2000
Say ("  445 (SMB)      : {0}" -f $(if ($p445)  { 'OPEN' } else { 'CLOSED' })) $(if ($p445)  { 'Green' } else { 'Red' })
Say ("  3389 (远程桌面): {0}" -f $(if ($p3389) { 'OPEN' } else { 'CLOSED' })) $(if ($p3389) { 'Green' } else { 'DarkGray' })

if (-not $p445) {
    Err '445 端口不通，无法走 SMB'
    Hint '在旧机上检查：'
    Hint '  1) 网络是否被识别成「公用」 -> 改成「专用」'
    Hint '  2) LanmanServer 服务是否在运行'
    Hint '  3) 防火墙是否放行「文件和打印机共享」'
    Hint '旧机上的 01-old-share.ps1 会自动处理这三项'
    Pause-Exit 1
}

if (-not $SourceName) { $SourceName = Resolve-NetbiosName $SourceIp }
if ($SourceName) { Ok "旧机计算机名: $SourceName" }

# ============================================================
#  2. 认证
# ============================================================
Step '2/3  认证'

if (-not $SourceUser) {
    $SourceUser = Read-Default '旧机账户名（Windows 登录名）'
}
if (-not $SourcePass) {
    $sec = Read-Host "旧机密码（输入时不显示）" -AsSecureString
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try   { $SourcePass = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

if (-not (Connect-Smb -Ip $SourceIp -User $SourceUser -Password $SourcePass -RemoteName $SourceName)) {
    Pause-Exit 1
}

# 保存配置，下次不用再输
Save-MigrateConfig -Path $cfgPath -Config @{
    SourceIp   = $SourceIp
    SourceName = $SourceName
    SourceUser = $SourceUser
}

# ============================================================
#  3. 扫描
# ============================================================
Step '3/3  扫描占用'

$shareUser = "\\$SourceIp\UserProfile"

# 探测约定好的共享路径（不依赖 WinRM/CIM）
# 盘符不写死：01-old-share.ps1 会给旧机每个非系统盘建 Drive<字母> 共享，
# 所以把 A-Z 都探一遍，存在哪些就是哪些（探测失败只花几毫秒）。
Say '  探测共享 ...' Cyan
$shareNames = @('UserProfile')
foreach ($L in [char[]](65..90)) { $shareNames += "Drive$L" }
$liveShares = @()
foreach ($n in $shareNames) {
    $p = "\\$SourceIp\$n"
    if (Test-PathSafe -Path $p) {
        $liveShares += $n
        Say "    [OK] $p" Green
    }
}
if ($liveShares -notcontains 'UserProfile') {
    Err "共享 UserProfile 不可访问"
    Hint '在旧机上重新运行 01-old-share.ps1'
    Pause-Exit 1
}

Say ''
Say '  正在枚举用户目录下各文件夹（robocopy /L，只统计不拷）...' DarkGray

$rows = @()
$dirs = @()
try {
    $dirs = @(Get-ChildItem -LiteralPath $shareUser -Directory -Force -ErrorAction SilentlyContinue)
} catch {
    Err "无法列出 $shareUser 的目录: $($_.Exception.Message)"
    Pause-Exit 1
}

if ($dirs.Count -eq 0) {
    Err "用户目录是空的，认证可能没生效"
    Pause-Exit 1
}

$i = 0
foreach ($d in $dirs) {
    $i++
    Write-Host ("`r    进度 {0}/{1}  {2,-32}" -f $i, $dirs.Count, $d.Name) -NoNewline -ForegroundColor DarkGray
    $s = Get-RemoteSize $d.FullName
    if ($s.Bytes -gt 0) {
        $rows += [pscustomobject]@{ Name = $d.Name; Path = $d.FullName; Bytes = $s.Bytes; Files = $s.Files; Scope = '用户目录' }
    }
}
Write-Host ''

# 其他盘（按实际探测到的共享来，不猜 D/E/F）
$driveLetters = @()
foreach ($n in $liveShares) {
    if ($n -match '^Drive([A-Z])$') { $driveLetters += $Matches[1] }
}
if ($driveLetters.Count -eq 0) {
    Warn '旧机上没有探测到任何盘共享（只有用户目录）。如果数据在其他盘，回旧机重跑 01-old-share.ps1'
}

foreach ($L in $driveLetters) {
    $root = "\\$SourceIp\Drive$L"
    if (-not (Test-PathSafe -Path $root)) { continue }
    Say "  枚举 $L 盘 ..." DarkGray
    $subs = @(Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue |
              Where-Object { $_.Name -notin @('$RECYCLE.BIN', 'System Volume Information') })
    foreach ($sd in $subs) {
        $s = Get-RemoteSize $sd.FullName
        if ($s.Bytes -gt 0) {
            $rows += [pscustomobject]@{ Name = "$L`:\$($sd.Name)"; Path = $sd.FullName; Bytes = $s.Bytes; Files = $s.Files; Scope = "${L}盘" }
        }
    }
}

# ============================================================
#  报告
# ============================================================
if (-not $ReportPath) { $ReportPath = Join-Path $PSScriptRoot '旧机占用报告.txt' }

$totalBytes = [long](($rows | Measure-Object -Property Bytes -Sum).Sum)
$totalFiles = [int](($rows | Measure-Object -Property Files -Sum).Sum)

Step '扫描完成'

Say ("  共 {0} 个目录，合计 {1}，{2:N0} 个文件" -f $rows.Count, (Format-Size $totalBytes), $totalFiles) Cyan
Write-Host ''
Say '  ── 占用明细（按大小排序，前 50）──────────────────────────────' Cyan
$rows | Sort-Object -Property Bytes -Descending | Select-Object -First 50 | ForEach-Object {
    $mark  = if ($_.Bytes -ge 1GB) { '  <<< 大' } else { '' }
    $color = if ($_.Bytes -ge 1GB) { 'Yellow' } else { 'Gray' }
    Say ("  {0,-40} {1}{2}" -f $_.Name, (Format-Size $_.Bytes), $mark) $color
}

# 写报告
try {
    $lines = @()
    $lines += "旧机 IP      : $SourceIp"
    $lines += "旧机计算机名 : $SourceName"
    $lines += "扫描时间     : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    $lines += "合计         : $(Format-Size $totalBytes) / $totalFiles 个文件"
    $lines += ''
    $lines += '===== 用户目录 ====='
    foreach ($r in ($rows | Where-Object { $_.Scope -eq '用户目录' } | Sort-Object Bytes -Descending)) {
        $lines += ("{0,-40} {1}  {2,9} 个文件" -f $r.Name, (Format-Size $r.Bytes), $r.Files)
    }
    $lines += ''
    $lines += '===== 其他盘 ====='
    foreach ($r in ($rows | Where-Object { $_.Scope -ne '用户目录' } | Sort-Object Bytes -Descending)) {
        $lines += ("{0,-40} {1}  {2,9} 个文件" -f $r.Name, (Format-Size $r.Bytes), $r.Files)
    }
    [System.IO.File]::WriteAllLines($ReportPath, $lines, (New-Object System.Text.UTF8Encoding($true)))
    Ok "报告已保存: $ReportPath"
} catch {
    Warn "报告保存失败: $($_.Exception.Message)"
}

Write-Host ''
Say '  ── 下一步 ──────────────────────────────────────────────' Cyan
Say '  1. 把上面标 <<< 大的目录名告诉用户，让他确认哪些要拷' White
Say '  2. 编辑 03-new-copy.ps1 里的 $Plan 任务表，或直接用默认全拷' White
Say '  3. 运行 03-new-copy.ps1' White
Write-Host ''

Disconnect-Smb $SourceIp
Pause-Exit 0
