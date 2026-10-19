<#
  01-old-share.ps1 —— 在【旧电脑】上运行（必须以管理员身份）
  作用：改网络为专用 + 启 LanmanServer + 放行防火墙 + 建共享 + 统计占用 + 出报告

  用法：
    右键 -> 以管理员身份运行 PowerShell，然后
      powershell -NoProfile -ExecutionPolicy Bypass -File .\01-old-share.ps1
    或双击 launcher-old.bat
#>

param(
    # 共享名前缀，最终会建 UserProfile / DriveD / DriveE ...
    [string]$SharePrefix = '',
    # 额外的自定义共享： @{ Name='项目'; Path='D:\项目' }
    [hashtable[]]$ExtraShares = @()
)

. "$PSScriptRoot\_common.ps1"

Step '旧电脑：建共享 + 统计占用'

if (-not (Test-Admin)) {
    Err '需要管理员权限'
    Hint '请右键本文件所在目录 -> 在终端中打开 -> 以管理员身份运行；或双击 launcher-old.bat'
    Pause-Exit 1
}
Ok '管理员权限已确认'

$computerName = $env:COMPUTERNAME
$userDir      = $env:USERPROFILE
Say  "  计算机名: $computerName" Gray
Say  "  用户目录: $userDir" Gray

# ============================================================
#  1. 网络配置文件改成「专用」
# ============================================================
Step '1/4  网络配置文件'

try {
    $profiles = @(Get-NetConnectionProfile -ErrorAction Stop)
    foreach ($p in $profiles) {
        if ($p.NetworkCategory -ne 'Private') {
            Say "  $($p.Name): $($p.NetworkCategory) -> Private" Yellow
            Set-NetConnectionProfile -InterfaceIndex $p.InterfaceIndex -NetworkCategory Private -ErrorAction SilentlyContinue
        } else {
            Ok "$($p.Name): 已是 Private"
        }
    }
} catch {
    Warn "无法读取网络配置文件（$($_.Exception.Message)），跳过"
}

# ============================================================
#  2. 启服务 + 放行防火墙
# ============================================================
Step '2/4  服务与防火墙'

try {
    $svc = Get-Service LanmanServer -ErrorAction Stop
    if ($svc.Status -ne 'Running') {
        Set-Service LanmanServer -StartupType Automatic -ErrorAction SilentlyContinue
        Start-Service LanmanServer -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
    }
    Ok "LanmanServer: $((Get-Service LanmanServer).Status)"
} catch {
    Err "LanmanServer 处理失败: $($_.Exception.Message)"
}

# 「文件和打印机共享」的防火墙规则组
$fwGroups = @('@FirewallAPI.dll,-28502', '@FirewallAPI.dll,-32752')
foreach ($g in $fwGroups) {
    try {
        Enable-NetFirewallRule -Group $g -ErrorAction Stop | Out-Null
        Ok "防火墙已放行: $g"
    } catch {
        Warn "防火墙组 $g 启用失败: $($_.Exception.Message)"
    }
}

# 兜底：直接开 445 入站（只在专用/域网络生效）
try {
    $ruleName = 'PC-Migrate SMB 445'
    Remove-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
    New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Protocol TCP `
        -LocalPort 445 -Action Allow -Profile Private,Domain -ErrorAction Stop | Out-Null
    Ok '已添加 445 入站规则（Private/Domain）'
} catch {
    Warn "445 规则添加失败: $($_.Exception.Message)"
}

# ============================================================
#  3. 统计占用
# ============================================================
Step '3/4  统计占用（可能需要 1-3 分钟）'

Say '  统计用户目录下各文件夹 ...' DarkGray
$rows = @()
$dirs = @(Get-ChildItem -LiteralPath $userDir -Directory -Force -ErrorAction SilentlyContinue)
foreach ($d in $dirs) {
    $s = Get-DirSize $d.FullName
    if ($s.Bytes -gt 0) {
        $rows += [pscustomobject]@{ Name = $d.Name; Bytes = $s.Bytes; Files = $s.Files; Scope = '用户目录' }
    }
}
$totalUser = [long](($rows | Measure-Object -Property Bytes -Sum).Sum)

Say '  统计其他磁盘 ...' DarkGray
$drives = @()
try {
    $drives = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue)
} catch {
    try { $drives = @(Get-WmiObject Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue) } catch { }
}

$driveRows = @()
foreach ($d in $drives) {
    $letter = $d.DeviceID.TrimEnd(':')
    $root   = "$($d.DeviceID)\"
    if (-not (Test-PathSafe -Path $root)) { continue }
    $isSys  = ($d.DeviceID -eq $env:SystemDrive)
    $driveRows += [pscustomobject]@{
        Letter = $letter
        Root   = $root
        Total  = [long]$d.Size
        Free   = [long]$d.FreeSpace
        IsSys  = $isSys
    }
    if (-not $isSys) {
        Say "  统计 $root 下的目录 ..." DarkGray
        $subs = @(Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue |
                  Where-Object { $_.Name -notin @('$RECYCLE.BIN', 'System Volume Information') })
        foreach ($sd in $subs) {
            $s = Get-DirSize $sd.FullName
            if ($s.Bytes -gt 0) {
                $rows += [pscustomobject]@{ Name = $sd.FullName; Bytes = $s.Bytes; Files = $s.Files; Scope = "${letter}盘" }
            }
        }
    }
}

Say ''
Say '  ── 占用明细（按大小排序）──────────────────────────────────────' Cyan
$rows | Sort-Object -Property Bytes -Descending | Select-Object -First 40 | ForEach-Object {
    $mark = if ($_.Bytes -ge 1GB) { '  <<< 大' } else { '' }
    $color = if ($_.Bytes -ge 1GB) { 'Yellow' } else { 'Gray' }
    Say ("  {0,-42} {1}{2}" -f $_.Name, (Format-Size $_.Bytes), $mark) $color
    Say ("  {0,-42} {1,9} 个文件" -f '', $_.Files) DarkGray
}
Say ''
Say ("  用户目录合计: {0}" -f (Format-Size $totalUser)) Cyan

# ============================================================
#  4. 建共享
# ============================================================
Step '4/4  创建共享'

function New-ShareSafe {
    param([string]$Name, [string]$Path, [string]$Desc)
    if (-not (Test-PathSafe -Path $Path)) { Warn "路径不存在，跳过: $Path"; return $false }
    try {
        $existing = Get-SmbShare -Name $Name -ErrorAction SilentlyContinue
        if ($existing) {
            Say "  $Name 已存在，先删除旧共享" DarkGray
            Remove-SmbShare -Name $Name -Force -ErrorAction SilentlyContinue
        }
        New-SmbShare -Name $Name -Path $Path -FullAccess 'Everyone' -Description $Desc -ErrorAction Stop | Out-Null
        Ok "$Name  ->  $Path"
        return $true
    } catch {
        Err "$Name 创建失败: $($_.Exception.Message)"
        return $false
    }
}

$made = @()
$userShare = if ($SharePrefix) { "${SharePrefix}UserProfile" } else { 'UserProfile' }
if (New-ShareSafe -Name $userShare -Path $userDir -Desc '整个用户目录（迁移用）') {
    $made += $userShare
}

foreach ($dr in $driveRows) {
    if ($dr.IsSys) { continue }
    $n = if ($SharePrefix) { "${SharePrefix}Drive$($dr.Letter)" } else { "Drive$($dr.Letter)" }
    if (New-ShareSafe -Name $n -Path $dr.Root -Desc "整个 $($dr.Root) 盘") {
        $made += $n
    }
}

foreach ($es in $ExtraShares) {
    if ($es.Name -and $es.Path) {
        $n = if ($SharePrefix) { "$SharePrefix$($es.Name)" } else { $es.Name }
        if (New-ShareSafe -Name $n -Path $es.Path -Desc '自定义共享') { $made += $n }
    }
}

# ============================================================
#  汇总 + 导出报告
# ============================================================
Step '完成'

Say '  新电脑应该能连到这些共享：' Cyan
try {
    Get-SmbShare | Where-Object { $_.Name -notmatch '\$$' } | ForEach-Object {
        Say ("    \\{0}\{1,-18} -> {2}" -f $computerName, $_.Name, $_.Path) Green
    }
} catch { }

# 报告写到用户目录根，新电脑能直接读
$reportPath = Join-Path $userDir '_共享清单.txt'
try {
    $lines = @()
    $lines += "计算机名: $computerName"
    $lines += "用户目录: $userDir"
    $lines += "生成时间: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    $lines += ''
    $lines += '===== 用户目录下各文件夹 ====='
    foreach ($r in ($rows | Where-Object { $_.Scope -eq '用户目录' } | Sort-Object Bytes -Descending)) {
        $lines += ("{0,-42} {1}  {2,9} 个文件" -f $r.Name, (Format-Size $r.Bytes), $r.Files)
    }
    $lines += ("{0,-42} {1}" -f '合计', (Format-Size $totalUser))
    $lines += ''
    $lines += '===== 各盘目录 ====='
    foreach ($r in ($rows | Where-Object { $_.Scope -ne '用户目录' } | Sort-Object Bytes -Descending)) {
        $lines += ("{0,-42} {1}  {2,9} 个文件" -f $r.Name, (Format-Size $r.Bytes), $r.Files)
    }
    $lines += ''
    $lines += '===== 磁盘 ====='
    foreach ($dr in $driveRows) {
        $lines += ("{0}\  总 {1}  可用 {2}  {3}" -f $dr.Root, (Format-Size $dr.Total), (Format-Size $dr.Free), $(if ($dr.IsSys) { '(系统盘)' } else { '' }))
    }
    $lines += ''
    $lines += '===== 共享 ====='
    foreach ($n in $made) {
        $sh = Get-SmbShare -Name $n -ErrorAction SilentlyContinue
        if ($sh) { $lines += ("\\{0}\{1}  ->  {2}" -f $computerName, $sh.Name, $sh.Path) }
    }
    [System.IO.File]::WriteAllLines($reportPath, $lines, (New-Object System.Text.UTF8Encoding($true)))
    Ok "报告已保存: $reportPath"
    $localCopy = Join-Path $PSScriptRoot '共享清单.txt'
    try {
        [System.IO.File]::WriteAllLines($localCopy, $lines, (New-Object System.Text.UTF8Encoding($true)))
        Ok "报告副本: $localCopy"
    } catch { }
} catch {
    Warn "报告保存失败: $($_.Exception.Message)"
}

Write-Host ''
Say '  ── 接下来 ──────────────────────────────────────────────' Cyan
Say "  1. 把新电脑连到同一个网络（同一个路由器 / 手机热点）" White
Say "  2. 在新电脑上运行 02-new-scan.ps1，它会自动找到这台机器的 IP" White
Say "  3. 若自动找不到，把这台机器的 IPv4 地址手动告诉它" White
Write-Host ''
Say '  本机 IPv4 地址：' Cyan
try {
    Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.)' } |
        ForEach-Object { Say "    $($_.IPAddress)  ($($_.InterfaceAlias))" Green }
} catch { }

Pause-Exit 0
