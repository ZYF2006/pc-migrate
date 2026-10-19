<#
  _common.ps1 —— pc-migrate 公共函数
  用法：在其它脚本里  . "$PSScriptRoot\_common.ps1"
  注意：本文件必须存为 UTF-8 with BOM
#>

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

# ============================================================
#  输出
# ============================================================
function Say  { param([string]$t, [string]$c = 'Gray')  Write-Host $t -ForegroundColor $c }
function Ok   { param([string]$t) Say "  [OK] $t" Green }
function Warn { param([string]$t) Say "  [!]  $t" Yellow }
function Err  { param([string]$t) Say "  [X]  $t" Red }
function Step { param([string]$t) Write-Host ''; Say ("=" * 68) Cyan; Say "  $t" Cyan; Say ("=" * 68) Cyan }
function Hint { param([string]$t) Say "       $t" DarkGray }

# ============================================================
#  尺寸
# ============================================================
function Format-Size {
    param([double]$bytes)
    if ($bytes -ge 1TB) { return ('{0,9:N2} TB' -f ($bytes / 1TB)) }
    if ($bytes -ge 1GB) { return ('{0,9:N2} GB' -f ($bytes / 1GB)) }
    if ($bytes -ge 1MB) { return ('{0,9:N1} MB' -f ($bytes / 1MB)) }
    if ($bytes -ge 1KB) { return ('{0,9:N0} KB' -f ($bytes / 1KB)) }
    return ('{0,9:N0} B ' -f $bytes)
}

# 沙箱里 Get-PSDrive 的 Used/Free 会返回 0，必须用 DriveInfo
function Get-FreeSpace {
    param([string]$DriveLetter)
    $l = $DriveLetter.TrimEnd(':', '\')
    try {
        $di = New-Object System.IO.DriveInfo($l)
        if (-not $di.IsReady) { return [long]0 }
        return [long]$di.AvailableFreeSpace
    } catch { return [long]0 }
}

function Get-DirSize {
    param([string]$Path)
    try {
        $m = Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue |
             Measure-Object -Property Length -Sum
        return [pscustomobject]@{ Files = [int]$m.Count; Bytes = [long]$m.Sum }
    } catch {
        return [pscustomobject]@{ Files = 0; Bytes = [long]0 }
    }
}

# ============================================================
#  连通性
# ============================================================
function Test-Port {
    param([string]$ComputerName, [int]$Port, [int]$TimeoutMs = 2000)
    $c = New-Object System.Net.Sockets.TcpClient
    try {
        $r = $c.BeginConnect($ComputerName, $Port, $null, $null)
        if ($r.AsyncWaitHandle.WaitOne($TimeoutMs) -and $c.Connected) { return $true }
        return $false
    } catch { return $false } finally { $c.Close() }
}

# 从 IP 反查计算机名（netbios），失败返回 $null
function Resolve-NetbiosName {
    param([string]$Ip)
    try {
        $out = & nbtstat -A $Ip 2>&1
        foreach ($l in @($out)) {
            if ($l -match '^\s*(\S+)\s+<00>\s+UNIQUE') { return $Matches[1] }
        }
    } catch { }
    return $null
}

# ============================================================
#  SMB 认证（用 net.exe，不占盘符、不卡交互）
# ============================================================
function Connect-Smb {
    param(
        [Parameter(Mandatory)][string]$Ip,
        [string]$User,
        [string]$Password,
        [string]$RemoteName
    )
    if (-not $RemoteName) { $RemoteName = Resolve-NetbiosName $Ip }

    $userCandidates = @()
    if ($RemoteName) { $userCandidates += "$RemoteName\$User" }
    $userCandidates += "$Ip\$User"
    $userCandidates += $User

    foreach ($u in $userCandidates) {
        $null = & net use "\\$Ip\IPC$" /user:"$u" "$Password" 2>&1
        if ($LASTEXITCODE -eq 0) {
            Ok "已认证：$u"
            return $true
        }
    }
    Err "认证失败，已尝试：$($userCandidates -join ' / ')"
    Hint "密码错（exit=2）或账户无密码 / 来宾访问被禁用"
    return $false
}

function Disconnect-Smb {
    param([string]$Ip)
    $null = & net use "\\$Ip\IPC$" /delete /y 2>&1
}

# ============================================================
#  旧机 IP 发现 + 缓存
# ============================================================
function Find-MigrateSource {
    param(
        [string]$NotebookName,
        [string]$CacheFile,
        [int[]]$Ports = @(445, 3389)
    )
    # 1) 缓存
    if ($CacheFile -and (Test-Path -LiteralPath $CacheFile)) {
        $last = (Get-Content -LiteralPath $CacheFile -ErrorAction SilentlyContinue | Select-Object -First 1)
        if ($last -match '^\d+\.\d+\.\d+\.\d+$') {
            foreach ($p in $Ports) {
                if (Test-Port $last $p 1500) {
                    Hint "使用缓存的 IP：$last（端口 $p 通）"
                    return $last
                }
            }
            Warn "缓存 IP $last 已不可达，重新搜索"
        }
    }
    # 2) 计算机名解析
    if ($NotebookName) {
        try {
            $addrs = @([System.Net.Dns]::GetHostAddresses($NotebookName) |
                       Where-Object { $_.AddressFamily -eq 'InterNetwork' } |
                       ForEach-Object { $_.IPAddressToString })
            foreach ($a in $addrs) {
                foreach ($p in $Ports) {
                    if (Test-Port $a $p 1500) {
                        if ($CacheFile) { $a | Set-Content -LiteralPath $CacheFile -Encoding ASCII }
                        Hint "通过计算机名解析到：$a"
                        return $a
                    }
                }
            }
        } catch { }
    }
    # 3) 扫本机所在网段
    $localIps = @()
    try {
        $localIps = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                      Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.)' } |
                      Select-Object -ExpandProperty IPAddress)
    } catch { }
    if ($localIps.Count -eq 0) {
        try {
            $localIps = @([System.Net.Dns]::GetHostAddresses([System.Net.Dns]::GetHostName()) |
                          Where-Object { $_.AddressFamily -eq 'InterNetwork' } |
                          ForEach-Object { $_.IPAddressToString } |
                          Where-Object { $_ -notmatch '^(127\.|169\.254\.)' })
        } catch { }
    }

    foreach ($lip in $localIps) {
        $prefix = ($lip -split '\.')[0..2] -join '.'
        Say "  扫描网段 $prefix.1-254 ..." DarkGray
        $found = @()
        foreach ($i in 1..254) {
            $target = "$prefix.$i"
            if ($target -eq $lip) { continue }
            if ((Test-Port $target 445 300) -or (Test-Port $target 3389 300)) { $found += $target }
        }
        foreach ($f in $found) {
            if ($f -eq $lip) { continue }
            $nb = Resolve-NetbiosName $f
            Say ("  发现: {0,-16} {1}" -f $f, $(if ($nb) { $nb } else { '(无 NetBIOS 名)' })) Yellow
        }
        if ($found.Count -gt 0) {
            Warn "请从上面选一台作为源机，把它的 IP 填到 -SourceIp 参数里重跑"
            return $null
        }
    }
    Err "没找到源机。检查：两台是否同一网段 / 旧机共享是否建好 / 防火墙"
    return $null
}

# ============================================================
#  robocopy 封装
# ============================================================
# 返回 $true 表示成功（退出码 < 8）
function Invoke-Robocopy {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Dest,
        [string[]]$ExcludeDirs = @(),
        [string[]]$ExcludeFiles = @(),
        [string[]]$OnlyFiles = @(),
        [string]$LogFile,
        [switch]$ListOnly,          # /L 只枚举不拷
        [switch]$Mirror,            # /MIR 镜像（会删除目标多余文件，慎用）
        [switch]$NoProgress,
        [switch]$Quiet
    )
    if (-not (Test-Path -LiteralPath (Join-Path $env:SystemRoot 'system32\Robocopy.exe'))) {
        Err "找不到 robocopy.exe"
        return $false
    }
    # 注意：不要用 $args 这个自动变量名
    $rcArgs = @($Source, $Dest, '/E', '/R:1', '/W:1', '/XJ', '/J', '/MT:8', '/NP', '/NFL', '/NDL')
    if ($Mirror)    { $rcArgs += '/MIR' }
    if ($ListOnly)  { $rcArgs += '/L' }
    if (-not $NoProgress) { $rcArgs += '/TEE' }
    if ($LogFile)   { $rcArgs += "/LOG:$LogFile" }
    if ($ExcludeDirs.Count  -gt 0) { $rcArgs += '/XD'; $rcArgs += $ExcludeDirs }
    if ($ExcludeFiles.Count -gt 0) { $rcArgs += '/XF'; $rcArgs += $ExcludeFiles }
    if ($OnlyFiles.Count    -gt 0) { $rcArgs += $OnlyFiles }

    $out = & robocopy @rcArgs 2>&1
    $code = $LASTEXITCODE
    if (-not $Quiet) {
        # 只回显错误行，避免刷屏
        foreach ($l in @($out)) {
            if ($l -match 'ERROR|错误|拒绝访问|Access is denied') { Say "    $l" DarkYellow }
        }
    }
    return ($code -lt 8)
}

# 解析 robocopy /L 汇总表拿总字节数（不要加 /NJS）
function Get-RemoteSize {
    param([Parameter(Mandatory)][string]$Path)
    $nullDir = Join-Path $env:TEMP ('_rb_null_' + [guid]::NewGuid().ToString('N'))
    $out = & robocopy $Path $nullDir /L /E /BYTES /NFL /NDL /NJH /R:0 /W:0 /XJ 2>&1
    $bytes = [long]0; $files = 0
    foreach ($l in @($out | ForEach-Object { $_.ToString() })) {
        if ($l -match '^\s*(字节|Bytes)\s*[:：]\s+(\d+)')  { $bytes = [long]$Matches[2] }
        if ($l -match '^\s*(文件|Files)\s*[:：]\s+(\d+)') { $files = [int]$Matches[2] }
    }
    return [pscustomobject]@{ Files = $files; Bytes = $bytes }
}

# 读 robocopy 日志（GBK）
function Read-RobocopyLog {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    return [System.IO.File]::ReadAllLines($Path, [System.Text.Encoding]::GetEncoding(936))
}

# ============================================================
#  文件编码
# ============================================================
function Ensure-Bom {
    param([Parameter(Mandatory)][string]$Path)
    $t = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    [System.IO.File]::WriteAllText($Path, $t, (New-Object System.Text.UTF8Encoding($true)))
}

function Write-GbkFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Text)
    $t = $Text -replace "`r?`n", "`r`n"
    [System.IO.File]::WriteAllText($Path, $t, [System.Text.Encoding]::GetEncoding(936))
}

# ============================================================
#  提权
# ============================================================
function Test-Admin {
    return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# 以管理员身份重跑某个 ps1，等待完成并返回退出码
function Invoke-Elevated {
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [string[]]$ArgumentList = @(),
        [switch]$NoWait
    )
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath) + $ArgumentList
    if ($NoWait) {
        Start-Process powershell.exe -ArgumentList $a -Verb RunAs -WindowStyle Hidden | Out-Null
        return 0
    }
    $p = Start-Process powershell.exe -ArgumentList $a -Verb RunAs -PassThru -Wait -WindowStyle Hidden
    return $p.ExitCode
}

# ============================================================
#  快捷方式
# ============================================================
function Get-LnkTarget {
    param([Parameter(Mandatory)][string]$LnkPath)
    try {
        $sh = New-Object -ComObject WScript.Shell
        $s = $sh.CreateShortcut($LnkPath)
        return $s.TargetPath
    } catch { return $null }
}

function Set-LnkTarget {
    param(
        [Parameter(Mandatory)][string]$LnkPath,
        [Parameter(Mandatory)][string]$TargetPath,
        [int]$IconIndex = 0
    )
    try {
        $sh = New-Object -ComObject WScript.Shell
        $s = $sh.CreateShortcut($LnkPath)
        $s.TargetPath = $TargetPath
        $s.IconLocation = "$TargetPath,$IconIndex"
        $s.Save()
        return $true
    } catch { return $false }
}

# 清图标缓存（修白块图标）。注意 ie4uinit -show 在非交互会话里可能返回 1，属正常
function Clear-IconCache {
    $killed = $false
    try {
        Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 800
        $killed = $true
    } catch { }

    $files = @(
        (Join-Path $env:LOCALAPPDATA 'IconCache.db'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Explorer\iconcache_*.db'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Explorer\thumbcache_*.db')
    )
    $n = 0
    foreach ($pat in $files) {
        try {
            Get-ChildItem -Path $pat -Force -ErrorAction SilentlyContinue | ForEach-Object {
                try { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop; $n++ } catch { }
            }
        } catch { }
    }
    Say ("  已删除 {0} 个图标缓存文件" -f $n) DarkGray

    $null = & ie4uinit.exe -show 2>&1

    if ($killed) {
        try {
            Start-Process explorer.exe
            Start-Sleep -Seconds 2
        } catch {
            Warn '自动重启 explorer 失败，请手动按 Ctrl+Shift+Esc → 文件 → 运行新任务 → explorer.exe'
        }
    }
    Ok '图标缓存已清理'
}

# ============================================================
#  配置持久化（.last-migrate.json）
# ============================================================
function Save-MigrateConfig {
    param([Parameter(Mandatory)][string]$Path, [hashtable]$Config)
    try {
        ($Config | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $Path -Encoding UTF8
    } catch { }
}

function Load-MigrateConfig {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
    } catch { return $null }
}

# ============================================================
#  路径探测（防 Access is denied）
# ============================================================
# 某些目录（如 D:\workbuddy\WorkBuddyAI）会让 Test-Path 抛 PermissionDenied，
# 而 Test-Path 的 -ErrorAction 并不能吞掉这个异常。统一用这个包一层。
function Test-PathSafe {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    try { return [bool](Test-Path -LiteralPath $Path -ErrorAction Stop) }
    catch { return $false }
}

# 安全枚举子目录（同样防权限异常）
function Get-ChildDirSafe {
    param([string]$Path)
    try { return @(Get-ChildItem -LiteralPath $Path -Directory -Force -ErrorAction Stop) }
    catch { return @() }
}

# ============================================================
#  已知文件夹（OneDrive 重定向安全）
# ============================================================
# 很多电脑把「桌面」「文档」重定向到了 OneDrive，此时
#   C:\Users\x\Desktop 可能存在但为空，真实路径是 C:\Users\x\OneDrive\Desktop
# 必须走 Shell 的 Known Folder 才拿得到真实路径。
function Get-KnownFolder {
    param([ValidateSet('Desktop','MyDocuments','MyPictures','MyVideos','MyMusic','Favorites','Downloads')][string]$Name)
    try {
        $sh = New-Object -ComObject Shell.Application
        $f  = $sh.Namespace(0).ParseName($Name)
        if ($f) {
            $p = $f.Path
            if ($p -and (Test-PathSafe -Path $p)) { return $p }
        }
    } catch { }

    # 兜底 1：注册表 User Shell Folders（展开 %USERPROFILE% 等变量）
    $regMap = @{
        Desktop     = 'Desktop'
        MyDocuments = 'Personal'
        MyPictures  = 'My Pictures'
        MyVideos    = 'My Video'
        MyMusic     = 'My Music'
        Favorites   = 'Favorites'
        Downloads   = '{374DE290-123F-4565-9164-39C4925E467B}'
    }
    try {
        $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'
        $raw = (Get-ItemProperty -Path $key -Name $regMap[$Name] -ErrorAction Stop).($regMap[$Name])
        if ($raw) {
            $exp = [System.Environment]::ExpandEnvironmentVariables($raw)
            if (Test-PathSafe -Path $exp) { return $exp }
        }
    } catch { }

    # 兜底 2：%USERPROFILE% 下的默认名字
    $defMap = @{
        Desktop = 'Desktop'; MyDocuments = 'Documents'; MyPictures = 'Pictures'
        MyVideos = 'Videos'; MyMusic = 'Music'; Favorites = 'Favorites'
        Downloads = 'Downloads'
    }
    return (Join-Path $env:USERPROFILE $defMap[$Name])
}

# ============================================================
#  盘符探测（不写死 F 盘）
# ============================================================
function Get-DriveLetters {
    param([switch]$IncludeNetwork)
    $out = @()
    foreach ($d in [System.IO.DriveInfo]::GetDrives()) {
        try {
            if (-not $d.IsReady) { continue }
            if ($d.DriveType -eq 'Fixed') { $out += $d.Name.TrimEnd('\') }
            elseif ($IncludeNetwork -and $d.DriveType -eq 'Network') { $out += $d.Name.TrimEnd('\') }
        } catch { }
    }
    return $out
}

# 挑一个放得下 $NeedBytes 的盘（优先非系统盘、空间最大的）
# 返回形如 '<某个非系统盘>:\迁移备份'；找不到返回 $null
function Suggest-BackupRoot {
    param([long]$NeedBytes = 0, [string]$Leaf = '迁移备份')
    $sys = $env:SystemDrive.TrimEnd('\')
    $cands = @()
    foreach ($letter in (Get-DriveLetters)) {
        if ($letter -eq $sys) { continue }
        $free = Get-FreeSpace $letter
        if ($free -le 0) { continue }
        if ($NeedBytes -gt 0 -and $free -lt $NeedBytes) { continue }
        $cands += [pscustomobject]@{ Letter = $letter; Free = $free }
    }
    if ($cands.Count -eq 0) {
        # 退一步：系统盘也接受（只要空间够）
        $free = Get-FreeSpace $sys
        if ($free -gt 0 -and ($NeedBytes -le 0 -or $free -ge $NeedBytes)) {
            return (Join-Path "$sys\" $Leaf)
        }
        return $null
    }
    $pick = $cands | Sort-Object -Property Free -Descending | Select-Object -First 1
    return (Join-Path "$($pick.Letter)\" $Leaf)
}

# 交互式确认中转盘：默认值来自 Suggest-BackupRoot
function Resolve-BackupRoot {
    param([string]$Current, [long]$NeedBytes = 0, [string]$Leaf = '迁移备份')
    if ($Current) { return $Current }
    $sug = Suggest-BackupRoot -NeedBytes $NeedBytes -Leaf $Leaf
    if (-not $sug) {
        Err '找不到空间足够的中转盘'
        Hint '插一块移动硬盘，或用 -DestRoot 显式指定一个目录'
        return $null
    }
    $free = Get-FreeSpace ($sug -split ':')[0]
    Hint ("检测到可用盘: {0} 可用 {1}" -f ($sug -split ':')[0], (Format-Size $free))
    return (Read-Default '中转盘根目录' $sug)
}

# ============================================================
#  提示 + 暂停
# ============================================================
function Read-Default {
    param([string]$Prompt, [string]$Default = '')
    $shown = if ($Default) { "$Prompt [$Default]: " } else { "${Prompt}: " }
    $v = Read-Host $shown
    if ([string]::IsNullOrWhiteSpace($v)) { return $Default }
    return $v.Trim()
}

function Pause-Exit {
    param([int]$Code = 0)
    Write-Host ''
    Read-Host '按回车退出'
    exit $Code
}
