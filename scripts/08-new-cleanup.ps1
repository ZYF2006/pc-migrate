<#
  08-new-cleanup.ps1 —— 在【新电脑】上运行（建议管理员）
  作用：扫描迁移遗留的垃圾（中转盘冗余、临时文件、回收站、失效备份），
        列清单给用户勾选后再删。默认只报告，不删。

  用法：
    powershell -NoProfile -ExecutionPolicy Bypass -File .\08-new-cleanup.ps1
    或双击 launcher-new-cleanup.bat

  参数：
    -BackupRoot  中转盘根目录（不填则从配置读；读不到就跳过中转盘检查）
    -Apply       真正执行删除（不加则只报告）
    -KeepBackup  保留中转盘，只清本机垃圾
#>

param(
    [string]$BackupRoot,
    [switch]$Apply,
    [switch]$KeepBackup
)

. "$PSScriptRoot\_common.ps1"

$cfgPath = Join-Path $PSScriptRoot '.migrate-config.json'
$cfg = Load-MigrateConfig $cfgPath
if (-not $BackupRoot) {
    if ($cfg -and $cfg.DestRoot) { $BackupRoot = $cfg.DestRoot }
}
# 清理脚本不主动猜中转盘：猜错可能把别的目录当备份列进「保留/删除」
# 没有配置且没传参时，只清本机垃圾（等价于 -KeepBackup）
if (-not $BackupRoot) { $KeepBackup = $true }

$U   = $env:USERPROFILE
$LAD = $env:LOCALAPPDATA
$AD  = $env:APPDATA

Step '迁移垃圾扫描'

$admin = Test-Admin
if (-not $admin) { Warn '当前不是管理员，部分项目（回收站 / Windows Temp）可能读不到' }

# ============================================================
#  候选清单
#  Level: safe = 删了没影响 / check = 删前要问用户 / keep = 不建议删
# ============================================================
$items = @()

# 判断某个名字是否命中排除通配符列表
function Test-Excluded {
    param([string]$Name, [string[]]$Patterns)
    if (-not $Patterns) { return $false }
    foreach ($p in $Patterns) {
        if ($Name -like $p) { return $true }
    }
    return $false
}

function Add-Item {
    param(
        [string]$Name, [string]$Path, [string]$Level, [string]$Why,
        [string]$Glob = $null,
        [string[]]$Exclude = @()      # 子项名通配符，命中的不统计也不删
    )
    $exists = $false
    $size = [long]0
    $files = 0

    # 取目录下需要处理的直接子项（应用排除规则）
    $kids = @()
    if ($Path -and (Test-PathSafe -Path $Path)) {
        $kids = @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue |
                  Where-Object { -not (Test-Excluded -Name $_.Name -Patterns $Exclude) })
    }

    if ($Glob) {
        try {
            $fs = @(Get-ChildItem -Path $Glob -Force -File -ErrorAction SilentlyContinue |
                    Where-Object { -not (Test-Excluded -Name $_.Name -Patterns $Exclude) })
            if ($fs.Count -gt 0) {
                $exists = $true
                $files  = $fs.Count
                $size   = [long](($fs | Measure-Object -Property Length -Sum).Sum)
            }
        } catch { }
    } else {
        if (Test-PathSafe -Path $Path) {
            $exists = $true
            foreach ($k in $kids) {
                if ($k.PSIsContainer) {
                    $sz = Get-DirSize $k.FullName
                    $size += $sz.Bytes; $files += $sz.Files
                } else {
                    $size += [long]$k.Length; $files += 1
                }
            }
        }
    }

    $script:items += [pscustomobject]@{
        Name  = $Name
        Path  = $(if ($Glob) { $Glob } else { $Path })
        Glob  = $Glob
        Level = $Level
        Why   = $Why
        Exclude = $Exclude
        Exists= $exists
        Bytes = $size
        Files = $files
        Selected = ($Level -eq 'safe')
    }
}

# ---------- 一、本机垃圾（安全） ----------
# 关键排除：dsh-* 是 DSH 沙箱自己的临时目录，删掉会让沙箱降级成
# ConstrainedLanguage（.NET 静态方法全被拦），后续脚本全部跑不动。
Add-Item -Name '用户临时文件'   -Path (Join-Path $LAD 'Temp') -Level 'safe' `
         -Exclude @('dsh-*', 'acp-decompress-*', 'acp-*') `
         -Why '临时文件，正在使用的会被跳过（已排除 DSH 沙箱目录）'
Add-Item -Name 'Windows 临时文件' -Path 'C:\Windows\Temp' -Level 'safe' `
         -Why '系统临时文件，需管理员'
Add-Item -Name '缩略图缓存'     -Glob (Join-Path $LAD 'Microsoft\Windows\Explorer\thumbcache_*.db') -Level 'safe' `
         -Why '会自动重建'
Add-Item -Name '崩溃转储'       -Path (Join-Path $LAD 'CrashDumps') -Level 'safe' `
         -Why '程序崩溃留下的 dmp 文件'
Add-Item -Name 'Windows 错误报告' -Path (Join-Path $LAD 'Microsoft\Windows\WER') -Level 'safe' `
         -Why '错误报告缓存'
Add-Item -Name '传递优化缓存'   -Path 'C:\Windows\SoftwareDistribution\DeliveryOptimization' -Level 'safe' `
         -Why 'Windows 更新分发缓存'

# ---------- 二、迁移遗留（要问） ----------
Add-Item -Name '失效快捷方式'   -Path (Join-Path (Get-KnownFolder Desktop) '_失效快捷方式') -Level 'check' `
         -Why '修不好的快捷方式，装完软件后可以删'
Add-Item -Name 'AppData补拷'    -Path (Join-Path (Get-KnownFolder Desktop) 'AppData补拷') -Level 'check' `
         -Why '已分发后就没用了，但要确认浏览器密码/设置都生效了'
Add-Item -Name '迁移分发日志'   -Path (Join-Path (Get-KnownFolder Desktop) '迁移分发日志') -Level 'check' `
         -Why '排查用日志，确认无误后可删'
# 不写死日期：文档目录下所有 _旧电脑微信备份_* 都算
foreach ($wb in @(Get-ChildItem -LiteralPath (Get-KnownFolder MyDocuments) -Directory -Force -ErrorAction SilentlyContinue |
                  Where-Object { $_.Name -like '_旧电脑微信备份*' })) {
    Add-Item -Name '旧电脑微信备份' -Path $wb.FullName -Level 'check' `
             -Why '微信数据库加密，搬不走聊天记录；确认不要了再删'
}

# ---------- 三、回收站 ----------
# 不写死盘符：枚举本机所有就绪的固定盘
foreach ($d in (Get-DriveLetters)) {
    $letter = $d.TrimEnd(':')
    $rb = "$($letter):\`$RECYCLE.BIN"
    if (Test-PathSafe -Path $rb) {
        $sz = Get-DirSize $rb
        if ($sz.Bytes -gt 0) {
            Add-Item -Name ("回收站 {0}:" -f $letter) -Path $rb -Level 'check' `
                     -Why ("{0} 个文件，确认里面没有要恢复的" -f $sz.Files)
        }
    }
}

# ---------- 四、中转盘 ----------
if (-not $KeepBackup -and (Test-PathSafe -Path $BackupRoot)) {
    $sz = Get-DirSize $BackupRoot
    Add-Item -Name '中转盘备份' -Path $BackupRoot -Level 'keep' `
             -Why ("{0} {1} 个文件 —— 确认所有数据都在新位置后再删" -f (Format-Size $sz.Bytes), $sz.Files)
}

# ============================================================
#  报告
# ============================================================
Say ''
$totalSafe = [long]0
$totalCheck = [long]0

Say '  ── 安全可删 ────────────────────────────────────────────' Green
foreach ($i in @($items | Where-Object { $_.Level -eq 'safe' -and $_.Exists -and $_.Bytes -gt 0 })) {
    $totalSafe += $i.Bytes
    Say ("  {0,-18} {1}" -f $i.Name, (Format-Size $i.Bytes)) White
    Say ("  {0,-18} {1}" -f '', $i.Path) DarkGray
    Say ("  {0,-18} {1}" -f '', $i.Why) DarkGray
}

Say ''
Say '  ── 需要确认 ────────────────────────────────────────────' Yellow
foreach ($i in @($items | Where-Object { $_.Level -eq 'check' -and $_.Exists -and $_.Bytes -gt 0 })) {
    $totalCheck += $i.Bytes
    Say ("  {0,-18} {1}" -f $i.Name, (Format-Size $i.Bytes)) White
    Say ("  {0,-18} {1}" -f '', $i.Path) DarkGray
    Say ("  {0,-18} {1}" -f '', $i.Why) DarkGray
}

Say ''
Say '  ── 保留 ────────────────────────────────────────────────' Red
foreach ($i in @($items | Where-Object { $_.Level -eq 'keep' -and $_.Exists })) {
    Say ("  {0,-18} {1}" -f $i.Name, (Format-Size $i.Bytes)) White
    Say ("  {0,-18} {1}" -f '', $i.Why) DarkGray
}

Write-Host ''
Say ("  安全可删合计: {0}      需确认合计: {1}" -f (Format-Size $totalSafe), (Format-Size $totalCheck)) Cyan
Write-Host ''

if (-not $Apply) {
    Warn '当前是报告模式（只统计不删）。加 -Apply 才真正删除。'
    Write-Host ''
    Say '  想删安全项：' White
    Say '    powershell -NoProfile -ExecutionPolicy Bypass -File .\08-new-cleanup.ps1 -Apply' Gray
    Write-Host ''
    Pause-Exit 0
}

# ============================================================
#  执行删除
# ============================================================
$targets = @($items | Where-Object { $_.Exists -and $_.Level -in @('safe', 'check') -and $_.Bytes -gt 0 })
if ($targets.Count -eq 0) { Ok '没有可清理的项目'; Pause-Exit 0 }

Write-Host ''
Say '  将删除以下项目：' Yellow
foreach ($t in $targets) { Say ("    [{0}] {1}  {2}" -f $t.Level, $t.Name, (Format-Size $t.Bytes)) Gray }
Write-Host ''
$go = Read-Default '确认删除？(y/n)' 'n'
if ($go -notmatch '^[Yy]') { Pause-Exit 0 }

$freed = [long]0
foreach ($t in $targets) {
    Say ("  清理 {0} ..." -f $t.Name) DarkGray
    $before = $t.Bytes

    # 回收站单独处理：Clear-RecycleBin 可能报错但仍返回成功，用前后差值算
    if ($t.Path -like '*`$RECYCLE.BIN') {
        $d = ($t.Path -split ':')[0]
        $null = & Clear-RecycleBin -DriveLetter $d -Force -ErrorAction SilentlyContinue 2>&1
        $after = Get-DirSize $t.Path
        $f = [Math]::Max(0, [long]$before - $after.Bytes)
        $freed += $f
        Ok ("{0}  释放 {1}" -f $t.Name, (Format-Size $f))
        continue
    }

    try {
        if ($t.Glob) {
            Get-ChildItem -Path $t.Glob -Force -File -ErrorAction SilentlyContinue |
                Where-Object { -not (Test-Excluded -Name $_.Name -Patterns $t.Exclude) } |
                ForEach-Object {
                    try { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop; $freed += $_.Length }
                    catch { }
                }
        } elseif ($t.Exclude -and $t.Exclude.Count -gt 0) {
            # 有排除规则：逐个子项删，保留命中的
            $kept = @()
            foreach ($k in @(Get-ChildItem -LiteralPath $t.Path -Force -ErrorAction SilentlyContinue)) {
                if (Test-Excluded -Name $k.Name -Patterns $t.Exclude) { $kept += $k.Name; continue }
                $sz = if ($k.PSIsContainer) { (Get-DirSize $k.FullName).Bytes } else { [long]$k.Length }
                try {
                    Remove-Item -LiteralPath $k.FullName -Recurse -Force -ErrorAction Stop
                    $freed += $sz
                } catch { }
            }
            if ($kept.Count -gt 0) {
                Say ("    保留 {0} 项: {1}" -f $kept.Count, ($kept -join ', ')) DarkGray
            }
        } else {
            # 目录：先尝试整目录删，失败就逐个文件删（跳过被占用的）
            try {
                Remove-Item -LiteralPath $t.Path -Recurse -Force -ErrorAction Stop
                $freed += $before
            } catch {
                $sz = Get-DirSize $t.Path
                $freed += $sz.Bytes
                try {
                    # 路径过长时 robocopy /MIR 空目录再删
                    $empty = Join-Path $env:TEMP ('_empty_' + [guid]::NewGuid().ToString('N'))
                    New-Item -ItemType Directory -Path $empty -Force | Out-Null
                    $null = & robocopy $empty $t.Path /MIR /R:0 /W:0 /NP /NFL /NDL /NJH /NJS 2>&1
                    Remove-Item -LiteralPath $t.Path -Recurse -Force -ErrorAction SilentlyContinue
                    Remove-Item -LiteralPath $empty -Recurse -Force -ErrorAction SilentlyContinue
                } catch { }
            }
        }
        Ok ("{0}  释放 {1}" -f $t.Name, (Format-Size $before))
    } catch {
        Warn ("{0} 清理失败: {1}" -f $t.Name, $_.Exception.Message)
    }
}

# ============================================================
#  汇总
# ============================================================
Step '清理完成'
Say ("  本次释放约 {0}" -f (Format-Size $freed)) Cyan

Write-Host ''
Say '  ── 磁盘现状 ────────────────────────────────────────────' Cyan
foreach ($d in @('C', 'D', 'E', 'F')) {
    $free = Get-FreeSpace $d
    if ($free -gt 0) { Say ("  {0}: 可用 {1}" -f $d, (Format-Size $free)) Gray }
}

Write-Host ''
if (Test-PathSafe -Path $BackupRoot) {
    $sz = Get-DirSize $BackupRoot
    Warn ("中转盘 {0} 仍在，占 {1}" -f $BackupRoot, (Format-Size $sz.Bytes))
    Say '  确认新电脑一切正常后，可以手动删掉它：' White
    Say ("    Remove-Item -LiteralPath '{0}' -Recurse -Force" -f $BackupRoot) Gray
}
Write-Host ''

Pause-Exit 0
