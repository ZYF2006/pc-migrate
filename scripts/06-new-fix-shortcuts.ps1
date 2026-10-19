<#
  06-new-fix-shortcuts.ps1 —— 在【新电脑】上运行
  作用：扫描桌面 / 开始菜单里的 .lnk，找出指向不存在路径的死链，尝试自动修复，
        修不了的隔离到 _失效快捷方式 文件夹；最后清图标缓存。

  用法：
    powershell -NoProfile -ExecutionPolicy Bypass -File .\06-new-fix-shortcuts.ps1
    或双击 launcher-new-fix-shortcuts.bat

  参数：
    -DryRun    只报告，不改任何东西
    -Deep      死链修复时额外全盘搜索 exe（慢，但命中率高）
#>

param(
    [switch]$DryRun,
    [switch]$Deep
)

. "$PSScriptRoot\_common.ps1"

$U = $env:USERPROFILE
# 桌面可能被 OneDrive 重定向，必须走 Known Folder
$DESK = Get-KnownFolder Desktop
$PUBLIC_DESK = Join-Path $env:PUBLIC 'Desktop'
$START = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
$START_ALL = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'
$QUAR = Join-Path $DESK '_失效快捷方式'

Step '快捷方式体检'

$dirs = @($DESK, $PUBLIC_DESK, $START, $START_ALL) | Where-Object { Test-PathSafe -Path $_ }

# ============================================================
#  1. 枚举所有 .lnk，读出 TargetPath
# ============================================================
$sh = New-Object -ComObject WScript.Shell
$all = @()
foreach ($d in $dirs) {
    $lnks = Get-ChildItem -LiteralPath $d -Filter '*.lnk' -Recurse -File -Force -ErrorAction SilentlyContinue
    foreach ($f in $lnks) {
        $target = $null
        try {
            $s = $sh.CreateShortcut($f.FullName)
            $target = $s.TargetPath
        } catch { }

        $state = 'unknown'
        if ([string]::IsNullOrWhiteSpace($target)) {
            $state = 'no-target'        # 指向 UWP / 特殊目标，正常
        } elseif (Test-PathSafe -Path $target) {
            $state = 'ok'
        } else {
            # 指向的是 .ico / 目录之类也可能存在，再确认一次
            $state = 'dead'
        }

        $all += [pscustomobject]@{
            Lnk    = $f.FullName
            Name   = $f.BaseName
            Dir    = $d
            Target = $target
            State  = $state
        }
    }
}

$okList   = @($all | Where-Object { $_.State -eq 'ok' })
$deadList = @($all | Where-Object { $_.State -eq 'dead' })
$noTarget = @($all | Where-Object { $_.State -eq 'no-target' })

Say ("  共 {0} 个快捷方式：正常 {1} / 失效 {2} / 无目标 {3}" -f $all.Count, $okList.Count, $deadList.Count, $noTarget.Count) Cyan

if ($deadList.Count -eq 0) {
    Ok '没有失效快捷方式'
    Write-Host ''
    Say '  ── 仍然白块？那是图标缓存问题，不是快捷方式问题 ──────' Yellow
    Say '  运行下面两条（需管理员）后重启 explorer：' White
    Say '    del /f /q "%LOCALAPPDATA%\IconCache.db"' Gray
    Say '    ie4uinit.exe -show' Gray
    Write-Host ''
    if (-not $DryRun) {
        $go = Read-Default '现在清图标缓存？(y/n)' 'n'
        if ($go -match '^[Yy]') { Clear-IconCache }
    }
    Pause-Exit 0
}

# ============================================================
#  2. 逐个尝试修复
# ============================================================
Say ''
Say '  ── 失效快捷方式明细 ────────────────────────────────────' Yellow
foreach ($x in $deadList) {
    Say ("  {0}" -f $x.Name) White
    Say ("     指向: {0}" -f $x.Target) DarkGray
    Say ("     位置: {0}" -f $x.Lnk) DarkGray
}

# ---------- 找 exe 的候选路径 ----------
function Find-Exe {
    param([string]$ExeName, [switch]$DeepSearch)
    $hits = @()

    # a) 注册表 App Paths
    $appPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\$ExeName",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\$ExeName",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\$ExeName"
    )
    foreach ($k in $appPaths) {
        try {
            $v = (Get-ItemProperty -LiteralPath $k -Name '(default)' -ErrorAction Stop).'(default)'
            if ($v -and (Test-PathSafe -Path $v)) { $hits += $v }
        } catch { }
    }

    # b) 卸载项里的 InstallLocation
    $uninstRoots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    foreach ($root in $uninstRoots) {
        try {
            $keys = Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue
            foreach ($k in $keys) {
                $p = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
                if (-not $p) { continue }
                $loc = $p.InstallLocation
                if (-not $loc) { continue }
                $cand = Join-Path $loc $ExeName
                if (Test-PathSafe -Path $cand) { $hits += $cand }
            }
        } catch { }
    }

    # c) 常见安装目录（一层 + 两层深）
    # 盘符不写死：本机所有就绪的固定盘都当候选（很多人把软件装在 D/E/F）
    $bases = @(
        "$env:ProgramFiles", "${env:ProgramFiles(x86)}",
        "$env:LOCALAPPDATA\Programs", "$env:APPDATA", "$env:LOCALAPPDATA"
    )
    foreach ($dl in (Get-DriveLetters)) { $bases += "$dl\" }
    $bases = $bases | Where-Object { $_ -and (Test-PathSafe -Path $_) } | Select-Object -Unique

    foreach ($b in $bases) {
        try {
            $cand = Join-Path $b $ExeName
            if (Test-PathSafe -Path $cand) { $hits += $cand }
            foreach ($sub in (Get-ChildItem -LiteralPath $b -Directory -ErrorAction SilentlyContinue)) {
                $cand2 = Join-Path $sub.FullName $ExeName
                if (Test-PathSafe -Path $cand2) { $hits += $cand2 }
                foreach ($sub2 in (Get-ChildItem -LiteralPath $sub.FullName -Directory -ErrorAction SilentlyContinue)) {
                    $cand3 = Join-Path $sub2.FullName $ExeName
                    if (Test-PathSafe -Path $cand3) { $hits += $cand3 }
                }
            }
        } catch { }
    }

    # d) 全盘搜索（很慢）
    if ($DeepSearch -and $hits.Count -eq 0) {
        Say ("     全盘搜索 {0} ...（可能要几分钟）" -f $ExeName) DarkYellow
        # 用 DriveInfo 枚举，不用 Get-PSDrive（后者在受限环境会返回空）
        foreach ($dl in (Get-DriveLetters)) {
            try {
                $hits += @(Get-ChildItem -LiteralPath "$dl\" -Filter $ExeName -Recurse -File `
                                        -ErrorAction SilentlyContinue -Force |
                           Select-Object -First 3 -ExpandProperty FullName)
            } catch { }
        }
    }

    return ($hits | Select-Object -Unique)
}

$fixed = @()
$stillDead = @()

foreach ($x in $deadList) {
    $exe = $null
    if ($x.Target -and $x.Target -match '\.exe$') {
        $exe = Split-Path -Leaf $x.Target
    }

    $newTarget = $null
    if ($exe) {
        $cands = @(Find-Exe -ExeName $exe -DeepSearch:$Deep)
        if ($cands.Count -ge 1) {
            $newTarget = $cands[0]
            if ($cands.Count -gt 1) {
                Say ("     {0} 找到 {1} 个候选，用第一个: {2}" -f $x.Name, $cands.Count, $newTarget) DarkYellow
            }
        }
    }

    if ($newTarget) {
        if ($DryRun) {
            Say ("  [DRY] 会修: {0}" -f $x.Name) Cyan
            Say ("        {0}  →  {1}" -f $x.Target, $newTarget) DarkGray
        } else {
            $r = Set-LnkTarget -LnkPath $x.Lnk -TargetPath $newTarget
            if ($r) {
                Ok ("已修: {0}  →  {1}" -f $x.Name, $newTarget)
                $fixed += $x
            } else {
                Err ("写入失败: {0}" -f $x.Name)
                $stillDead += $x
            }
        }
    } else {
        $stillDead += $x
    }
}

# ============================================================
#  3. 隔离修不好的
# ============================================================
if ($stillDead.Count -gt 0) {
    Say ''
    Say ("  ── 修不好的 {0} 个 ────────────────────────────────────" -f $stillDead.Count) Yellow
    foreach ($x in $stillDead) {
        Say ("  {0}  →  {1}" -f $x.Name, $x.Target) DarkGray
    }
    Write-Host ''
    Say '  这些程序在新电脑上没装（或装在别的名字下）。' White
    Say '  建议：先按清单装软件，装完再跑一次本脚本。' White
    Write-Host ''

    if (-not $DryRun) {
        $q = Read-Default '把修不好的快捷方式移到桌面 _失效快捷方式 文件夹？(y/n)' 'y'
        if ($q -match '^[Yy]') {
            New-Item -ItemType Directory -Path $QUAR -Force -ErrorAction SilentlyContinue | Out-Null
            foreach ($x in $stillDead) {
                if ($x.Lnk -like "$QUAR*") { continue }
                try {
                    Move-Item -LiteralPath $x.Lnk -Destination $QUAR -Force -ErrorAction Stop
                    Say ("  已隔离: {0}" -f $x.Name) DarkGray
                } catch {
                    Warn ("隔离失败: {0}  {1}" -f $x.Name, $_.Exception.Message)
                }
            }
            Ok "已隔离到 $QUAR"
        }
    }
}

# ============================================================
#  4. 清图标缓存
# ============================================================
if (-not $DryRun) {
    Write-Host ''
    $go = Read-Default '清图标缓存（修白块图标）？需要重启 explorer，会短暂黑一下桌面 (y/n)' 'y'
    if ($go -match '^[Yy]') { Clear-IconCache }
}

# ============================================================
#  汇总
# ============================================================
Step '快捷方式体检完成'
Say ("  正常 {0}  已修 {1}  待装软件 {2}" -f $okList.Count, $fixed.Count, $stillDead.Count) Cyan

Pause-Exit 0
