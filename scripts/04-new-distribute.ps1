<#
  04-new-distribute.ps1 —— 在【新电脑】上运行（不需要管理员）
  作用：把中转盘里的备份分发到新电脑真正能用的位置（桌面/文档/D盘等）

  用法：
    powershell -NoProfile -ExecutionPolicy Bypass -File .\04-new-distribute.ps1
    或双击 launcher-new-distribute.bat

  参数：
    -BackupRoot  中转盘根目录（不填则从配置读，再不行自动挑一个空间足够的盘）
    -DryRun      只列出计划，不实际拷贝
    -Only        只跑名称匹配这些关键字的任务（逗号分隔）
#>

param(
    [string]$BackupRoot,
    [switch]$DryRun,
    [string[]]$Only
)

. "$PSScriptRoot\_common.ps1"

$cfgPath = Join-Path $PSScriptRoot '.migrate-config.json'
$cfg = Load-MigrateConfig $cfgPath
if (-not $BackupRoot) {
    if ($cfg -and $cfg.DestRoot) { $BackupRoot = $cfg.DestRoot }
}
if (-not $BackupRoot) {
    $BackupRoot = Resolve-BackupRoot -Current '' -Leaf '迁移备份'
    if (-not $BackupRoot) { Pause-Exit 1 }
}

$U    = $env:USERPROFILE
# 用 Known Folder 取真实路径：OneDrive 重定向时 %USERPROFILE%\Desktop 可能是空壳
$DESK = Get-KnownFolder Desktop
$DOCS = Get-KnownFolder MyDocuments
$PICS = Get-KnownFolder MyPictures
$VIDS = Get-KnownFolder MyVideos
$MUS  = Get-KnownFolder MyMusic
$DOWN = Get-KnownFolder Downloads
if (-not (Test-PathSafe -Path $DOWN)) { $DOWN = $DESK }
$LOG  = Join-Path $DESK '迁移分发日志'

Step "数据分发   $BackupRoot  →  新电脑使用位置"

if (-not (Test-PathSafe -Path $BackupRoot)) {
    Err "找不到备份目录 $BackupRoot"
    Pause-Exit 1
}
New-Item -ItemType Directory -Path $LOG -Force -ErrorAction SilentlyContinue | Out-Null

# ============================================================
#  任务表
#  N=名称 S=源 D=目标 XD=跳过目录 XF=跳过文件 Only=只拷这些文件 Rec=是否必跑
# ============================================================
$tasks = @(
    # ---------- 一、个人文件 ----------
    @{ N='桌面';         G='个人文件'; S="$BackupRoot\Desktop";       D=$DESK; Rec=$true;  XD=@('migrate', '迁移分发日志'); XF=@('~$*', 'desktop.ini') }
    @{ N='文档';         G='个人文件'; S="$BackupRoot\Documents";     D=$DOCS; Rec=$true;  XD=@(); XF=@('desktop.ini', 'Default.rdp') }
    @{ N='下载';         G='个人文件'; S="$BackupRoot\Downloads";     D=$DOWN; Rec=$true;  XD=@(); XF=@('desktop.ini') }
    @{ N='图片';         G='个人文件'; S="$BackupRoot\Pictures";      D=$PICS; Rec=$true;  XD=@(); XF=@('desktop.ini') }
    @{ N='视频';         G='个人文件'; S="$BackupRoot\Videos";        D=$VIDS; Rec=$false; XD=@(); XF=@('desktop.ini') }
    @{ N='音乐';         G='个人文件'; S="$BackupRoot\Music";         D=$MUS;  Rec=$false; XD=@(); XF=@('desktop.ini') }
    @{ N='收藏夹';       G='个人文件'; S="$BackupRoot\Favorites";     D=(Join-Path $U 'Favorites'); Rec=$false; XD=@(); XF=@() }

    # ---------- 二、聊天记录 ----------
    @{ N='QQ聊天记录';   G='聊天记录'; S="$BackupRoot\Tencent-Files"; D=(Join-Path $DOCS 'Tencent Files'); Rec=$true;  XD=@(); XF=@() }
    @{ N='微信文件';     G='聊天记录'; S="$BackupRoot\WeChat-Files";  D=(Join-Path $DOCS 'WeChat Files');  Rec=$false; XD=@(); XF=@() }

    # ---------- 三、用户目录点目录 ----------
    @{ N='.ssh';         G='软件配置'; S="$BackupRoot\.ssh";       D=(Join-Path $U '.ssh');       Rec=$true;  XD=@(); XF=@() }
    @{ N='.gitconfig';   G='软件配置'; S="$BackupRoot\.gitconfig"; D=(Join-Path $U '.gitconfig'); Rec=$false; XD=@(); XF=@() }
    @{ N='.vscode';      G='软件配置'; S="$BackupRoot\.vscode";    D=(Join-Path $U '.vscode');    Rec=$false; XD=@(); XF=@() }
    @{ N='.codex';       G='软件配置'; S="$BackupRoot\.codex";     D=(Join-Path $U '.codex');     Rec=$false; XD=@(); XF=@() }
    @{ N='.claude';      G='软件配置'; S="$BackupRoot\.claude";    D=(Join-Path $U '.claude');    Rec=$false; XD=@(); XF=@() }
    @{ N='.dsh';         G='软件配置'; S="$BackupRoot\.dsh";       D=(Join-Path $U '.dsh');       Rec=$true;  XD=@(); XF=@() }
    @{ N='.jdks';        G='软件配置'; S="$BackupRoot\.jdks";      D=(Join-Path $U '.jdks');      Rec=$false; XD=@(); XF=@() }
    @{ N='.m2';          G='软件配置'; S="$BackupRoot\.m2";        D=(Join-Path $U '.m2');        Rec=$false; XD=@(); XF=@() }
)

# ---------- 四、其他盘（不写死盘符） ----------
# 备份里如果有 DriveD / DriveE ... 目录，就还原到同名盘。
# 新电脑没有那个盘时不盲拷（下面的过滤会跳过并提示）。
$driveBackups = @()
if (Test-PathSafe -Path $BackupRoot) {
    $driveBackups = @(Get-ChildItem -LiteralPath $BackupRoot -Directory -Force -ErrorAction SilentlyContinue |
                      Where-Object { $_.Name -match '^Drive([A-Z])$' })
}
foreach ($db in ($driveBackups | Sort-Object Name)) {
    $null = $db.Name -match '^Drive([A-Z])$'
    $letter = $Matches[1]
    $tasks += @{
        N  = "${letter}盘数据"
        G  = '其他盘'
        S  = $db.FullName
        D  = "${letter}:\"
        Rec= $false
        XD = @('$RECYCLE.BIN', 'System Volume Information')
        XF = @()
    }
}
if ($driveBackups.Count -eq 0) {
    Say '  备份里没有其他盘的数据（只有用户目录），跳过整盘还原' DarkGray
}

# 过滤
$todo = @()
foreach ($t in $tasks) {
    if ($Only -and $Only.Count -gt 0) {
        $hit = $false
        foreach ($k in $Only) { if ($t.N -like "*$k*") { $hit = $true; break } }
        if (-not $hit) { continue }
    }
    if (-not (Test-PathSafe -Path $t.S)) {
        Say ("  跳过（备份里没有）: {0}" -f $t.N) DarkGray
        continue
    }
    # 目标盘不存在时不要盲拷：D/E 盘在新电脑上可能根本不存在
    if ($t.D -match '^([A-Za-z]):\\?$') {
        $wantDrive = $Matches[1].ToUpper() + ':'
        if (-not (Test-PathSafe -Path "$wantDrive\")) {
            Warn ("  跳过（新电脑没有 {0} 盘）: {1}" -f $wantDrive, $t.N)
            Hint ("   备份里的数据还在 {0}，可以手动拷到别的盘" -f $t.S)
            continue
        }
    }
    $todo += $t
}

if ($todo.Count -eq 0) {
    Err '没有可分发的任务'
    Pause-Exit 1
}

# ============================================================
#  预览
# ============================================================
Say ''
Say '  ── 分发计划 ────────────────────────────────────────────' Cyan
$totalEst = [long]0
foreach ($g in ($todo | Group-Object G)) {
    Say "  [$($g.Name)]" Yellow
    foreach ($t in $g.Group) {
        $sz = Get-DirSize $t.S
        $totalEst += $sz.Bytes
        Say ("    {0,-14} {1}" -f $t.N, (Format-Size $sz.Bytes)) Gray
        Say ("    {0,-14} → {1}" -f '', $t.D) DarkGray
    }
}
Write-Host ''
Say ("  预计拷贝总量: {0}" -f (Format-Size $totalEst)) Cyan

if ($DryRun) {
    Write-Host ''
    Warn 'DryRun 模式，未实际拷贝'
    Pause-Exit 0
}

Write-Host ''
$go = Read-Default '开始分发？(y/n)' 'y'
if ($go -notmatch '^[Yy]') { Pause-Exit 0 }

# ============================================================
#  执行
# ============================================================
$results = @()
$idx = 0
foreach ($t in $todo) {
    $idx++
    Step ("[{0}/{1}] {2}" -f $idx, $todo.Count, $t.N)
    Say "  源:   $($t.S)" DarkGray
    Say "  目标: $($t.D)" DarkGray

    if (-not (Test-PathSafe -Path $t.D)) {
        try {
            New-Item -ItemType Directory -Path $t.D -Force -ErrorAction Stop | Out-Null
        } catch {
            Err "无法创建目标目录 $($t.D): $($_.Exception.Message)"
            $results += [pscustomobject]@{ Name = $t.N; Ok = $false; Bytes = 0; Files = 0 }
            continue
        }
    }

    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $log = Join-Path $LOG ("{0}_{1}.log" -f $t.N, $stamp)

    # /XO 不覆盖目标里更新的文件
    $rcArgs = @($t.S, $t.D, '/E', '/R:1', '/W:1', '/XJ', '/J', '/MT:8', '/NP', '/XO', '/NFL', '/NDL', '/TEE', "/LOG:$log")
    if ($t.XD.Count -gt 0) { $rcArgs += '/XD'; $rcArgs += $t.XD }
    if ($t.XF.Count -gt 0) { $rcArgs += '/XF'; $rcArgs += $t.XF }

    $t0 = Get-Date
    $out = & robocopy @rcArgs 2>&1
    $code = $LASTEXITCODE
    $sec = [math]::Round(((Get-Date) - $t0).TotalSeconds, 1)
    $ok = ($code -lt 8)

    # 从日志里数出实际拷了多少
    $copied = 0; $copiedBytes = [long]0
    $logLines = Read-RobocopyLog $log
    foreach ($l in $logLines) {
        if ($l -match '^\s*(文件|Files)\s*[:：]\s+(\d+)') { $copied = [int]$Matches[2] }
        if ($l -match '^\s*(字节|Bytes)\s*[:：]\s+(\d+)') { $copiedBytes = [long]$Matches[2] }
    }

    if ($ok) {
        Ok ("{0}   拷贝 {1} 个文件  {2}  {3}s" -f $t.N, $copied, (Format-Size $copiedBytes), $sec)
    } else {
        Err ("{0} 有错误（退出码 {1}），见日志 {2}" -f $t.N, $code, $log)
    }

    $results += [pscustomobject]@{ Name = $t.N; Ok = $ok; Bytes = $copiedBytes; Files = $copied; Code = $code; Log = $log }
}

# ============================================================
#  汇总
# ============================================================
Step '分发完成'

$failCount = @($results | Where-Object { -not $_.Ok }).Count
foreach ($r in $results) {
    $mark  = if ($r.Ok) { 'OK  ' } else { 'FAIL' }
    $color = if ($r.Ok) { 'Gray' } else { 'Red' }
    Say ("  [{0}] {1,-14} {2,8} 个文件  {3}" -f $mark, $r.Name, $r.Files, (Format-Size $r.Bytes)) $color
}
Write-Host ''
Say ("  成功 {0} 项，失败 {1} 项" -f ($results.Count - $failCount), $failCount) $(if ($failCount -gt 0) { 'Yellow' } else { 'Cyan' })

$summary = Join-Path $LOG ('_分发汇总_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.txt')
try {
    $lines = @()
    $lines += "分发时间: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    $lines += "备份源: $BackupRoot"
    $lines += ''
    foreach ($r in $results) {
        $lines += ("{0,-6} {1,-14} {2,8} 个文件  {3}" -f $(if ($r.Ok) { 'OK' } else { 'FAIL' }), $r.Name, $r.Files, (Format-Size $r.Bytes))
    }
    [System.IO.File]::WriteAllLines($summary, $lines, (New-Object System.Text.UTF8Encoding($true)))
    Ok "汇总: $summary"
} catch { }

Write-Host ''
Say '  ── 下一步 ──────────────────────────────────────────────' Cyan
Say '  1. 运行 05-new-appdata.ps1 补拷 AppData 精选（书签/密码/软件设置）' White
Say '  2. 运行 06-new-fix-shortcuts.ps1 修快捷方式' White
Say '  3. 运行 07-new-bookmarks.ps1 合并书签' White
Write-Host ''

Pause-Exit $(if ($failCount -gt 0) { 2 } else { 0 })
