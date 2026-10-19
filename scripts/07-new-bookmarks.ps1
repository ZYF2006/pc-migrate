<#
  07-new-bookmarks.ps1 —— 在【新电脑】上运行
  作用：把旧电脑导出的书签（Netscape HTML 或 Chromium Bookmarks JSON）
        追加合并到本机 Chrome / Edge / 夸克等 Chromium 系浏览器，
        统一放进一个名为「旧电脑书签」的文件夹，不覆盖现有书签。

  用法：
    powershell -NoProfile -ExecutionPolicy Bypass -File .\07-new-bookmarks.ps1 -Source <书签文件或目录>
    或双击 launcher-new-6-bookmarks.bat

  参数：
    -Source   书签来源：.html（Netscape 格式）或 .json（Chromium Bookmarks），也可以是目录
    -Browsers 只处理这些浏览器（默认 chrome,edge,quark）
    -Folder   目标文件夹名（默认「旧电脑书签」）
    -DryRun   只报告不写入
#>

param(
    [string]$Source,
    [string[]]$Browsers = @('chrome', 'edge', 'quark'),
    [string]$Folder = '旧电脑书签',
    [switch]$DryRun
)

. "$PSScriptRoot\_common.ps1"
. "$PSScriptRoot\_bookmarks.ps1"

Step '合并浏览器书签'
$null = Initialize-BmSerializer

$LAD = $env:LOCALAPPDATA
$U   = $env:USERPROFILE

$browserMap = [ordered]@{
    chrome = @{ Name = 'Chrome'; Path = "$LAD\Google\Chrome\User Data";       Proc = 'chrome' }
    edge   = @{ Name = 'Edge';   Path = "$LAD\Microsoft\Edge\User Data";      Proc = 'msedge' }
    quark  = @{ Name = '夸克';   Path = "$LAD\Quark\User Data";               Proc = 'quark' }
    brave  = @{ Name = 'Brave';  Path = "$LAD\BraveSoftware\Brave-Browser\User Data"; Proc = 'brave' }
}

# ============================================================
#  1. 找书签来源
# ============================================================
if (-not $Source) {
    $deskTop = Get-KnownFolder Desktop
    $guess = @(
        (Join-Path $deskTop '书签'),
        (Join-Path $deskTop 'bookmarks'),
        (Join-Path $deskTop 'Bookmarks'),
        (Join-Path $PSScriptRoot '..\bookmarks')
    ) | Where-Object { Test-PathSafe -Path $_ }
    if ($guess.Count -gt 0) { $Source = $guess[0] }
}

if (-not $Source -or -not (Test-PathSafe -Path $Source)) {
    Err '没找到书签来源'
    Hint '用法: -Source "C:\path\bookmarks.html"'
    Hint '从旧电脑导出：浏览器 → 书签管理器（Ctrl+Shift+O）→ 右上角 ⋮ → 导出书签'
    Pause-Exit 1
}

$srcFiles = @()
if ((Get-Item -LiteralPath $Source).PSIsContainer) {
    # 除了 .html/.htm/.json，也要收 Chromium 的 `Bookmarks`（无扩展名）
    $srcFiles = @(Get-ChildItem -LiteralPath $Source -File -ErrorAction SilentlyContinue |
                  Where-Object {
                      $_.Extension -in @('.html', '.htm', '.json') -or
                      $_.Name -in @('Bookmarks', 'bookmarks')
                  })
} else {
    $srcFiles = @(Get-Item -LiteralPath $Source)
}

if ($srcFiles.Count -eq 0) {
    Err "目录里没有 .html / .json / Bookmarks: $Source"
    Pause-Exit 1
}

Say ''
Say ("  书签来源 {0} 个文件：" -f $srcFiles.Count) Cyan
foreach ($f in $srcFiles) { Say ("    {0}" -f $f.FullName) DarkGray }

# ============================================================
#  2. 解析并合并所有来源
# ============================================================
$merged = @()
foreach ($f in $srcFiles) {
    try {
        $r = Read-BookmarkFile -Path $f.FullName
        $cnt = Count-BmNodes @($r.children)
        Say ("  解析 {0,-30} {1,5} 条" -f $f.Name, $cnt) Gray
        $merged += @($r.children)
    } catch {
        Err ("解析失败 {0}: {1}" -f $f.Name, $_.Exception.Message)
    }
}

$totalSrc = Count-BmNodes $merged
if ($totalSrc -eq 0) {
    Err '解析出 0 条书签，检查文件格式'
    Pause-Exit 1
}
Say ("  来源合计 {0} 条" -f $totalSrc) Cyan

# ============================================================
#  3. 写入各浏览器
# ============================================================
$done    = @()
$skipped = @()
$failed  = @()

foreach ($bk in $Browsers) {
    $info = $browserMap[$bk]
    if (-not $info) { Warn "未知浏览器: $bk"; continue }

    if (-not (Test-PathSafe -Path $info.Path)) {
        Say ("  跳过 {0}（未安装）" -f $info.Name) DarkGray
        $skipped += $info.Name
        continue
    }

    $profiles = @(Get-ChildItem -LiteralPath $info.Path -Directory -ErrorAction SilentlyContinue |
                  Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' })
    if ($profiles.Count -eq 0) {
        Say ("  跳过 {0}（无 profile）" -f $info.Name) DarkGray
        $skipped += $info.Name
        continue
    }

    Say ''
    Say ("  ── {0} ──────────────────────────────────────────" -f $info.Name) Cyan

    # 必须关浏览器
    $running = @(Get-Process -Name $info.Proc -ErrorAction SilentlyContinue)
    if ($running.Count -gt 0) {
        if ($DryRun) {
            Warn ("{0} 正在运行（DryRun 不关闭）" -f $info.Name)
        } else {
            Warn ("{0} 正在运行，不关闭的话书签会被覆盖回去" -f $info.Name)
            $q = Read-Default ("  关闭 {0}？(y/n)" -f $info.Name) 'y'
            if ($q -match '^[Yy]') {
                Stop-Process -Name $info.Proc -Force -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 3
            } else {
                Say ("  跳过 {0}" -f $info.Name) DarkGray
                $skipped += $info.Name
                continue
            }
        }
    }

    foreach ($p in $profiles) {
        $bmPath = Join-Path $p.FullName 'Bookmarks'
        if (-not (Test-PathSafe -Path $bmPath)) {
            Say ("  {0}  无 Bookmarks 文件" -f $p.Name) DarkGray
            continue
        }

        if ($DryRun) {
            $cur = Get-BookmarksCount -BookmarksPath $bmPath
            Say ("  [DRY] {0}  现有 {1} 条，将追加 {2} 条" -f $p.Name, $cur, $totalSrc) Cyan
            continue
        }

        # 备份
        $bak = "$bmPath.bak_" + (Get-Date -Format 'yyyyMMdd_HHmmss')
        try { Copy-Item -LiteralPath $bmPath -Destination $bak -Force } catch { }

        try {
            $r = Merge-IntoBookmarks -BookmarksPath $bmPath -MergedNodes $merged -FolderName $Folder
            Ok ("  {0}   {1} → {2} 条（+{3}）" -f $p.Name, $r.Before, $r.After, $r.Added)
            $done += "$($info.Name)\$($p.Name)"
        } catch {
            Err ("  {0} 失败: {1}" -f $p.Name, $_.Exception.Message)
            if (Test-PathSafe -Path $bak) {
                Copy-Item -LiteralPath $bak -Destination $bmPath -Force -ErrorAction SilentlyContinue
                Hint '已从备份回滚'
            }
            $failed += "$($info.Name)\$($p.Name)"
        }
    }
}

# ============================================================
#  4. 汇总
# ============================================================
Step '书签合并完成'
if ($done.Count -gt 0)    { Say ("  成功 {0} 个：{1}" -f $done.Count, ($done -join ', ')) Green }
if ($skipped.Count -gt 0) { Say ("  跳过：{0}" -f ($skipped -join ', ')) DarkGray }
if ($failed.Count -gt 0)  { Say ("  失败：{0}" -f ($failed -join ', ')) Red }

Write-Host ''
Say '  ── 验证 ────────────────────────────────────────────────' Cyan
Say ("  打开浏览器 → 书签管理器（Ctrl+Shift+O）→ 书签栏里应有「{0}」文件夹" -f $Folder) White
Say '  看不到就重启浏览器' White
Write-Host ''

Pause-Exit $(if ($failed.Count -gt 0) { 2 } else { 0 })
