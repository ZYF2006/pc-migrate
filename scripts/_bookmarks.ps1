<#
  _bookmarks.ps1 —— 书签解析与合并（纯函数，无交互，可单独测试）
  用法：在脚本里  . "$PSScriptRoot\_bookmarks.ps1"
        然后  Initialize-BmSerializer
#>

Add-Type -AssemblyName System.Web.Extensions

$script:BmSer = $null

function Initialize-BmSerializer {
    if ($null -eq $script:BmSer) {
        $s = New-Object System.Web.Script.Serialization.JavaScriptSerializer
        $s.MaxJsonLength  = [int]::MaxValue
        $s.RecursionLimit = 512
        $script:BmSer = $s
    }
    return $script:BmSer
}

# 统一节点：@{ name; url; children }。url 为空 = 文件夹
function New-BmNode {
    param([string]$Name, [string]$Url)
    return [ordered]@{ name = $Name; url = $Url; children = @() }
}

# ============================================================
#  解析 Netscape Bookmark HTML（浏览器导出的 .html）
# ============================================================
function ConvertFrom-NetscapeHtml {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { throw "文件不存在: $Path" }
    $html = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    if ([string]::IsNullOrWhiteSpace($html)) { throw "文件为空: $Path" }

    $root  = New-BmNode 'root' ''
    $stack = New-Object System.Collections.Stack
    $stack.Push($root)

    # <DT><H3 ...>文件夹名</H3>  |  <DT><A HREF="url" ...>名字</A>  |  </DL>
    $rx = [regex]'(?is)<DT>\s*<H3[^>]*>(.*?)</H3>|<DT>\s*<A\s[^>]*HREF\s*=\s*"([^"]*)"[^>]*>(.*?)</A>|</DL\s*>'

    foreach ($m in $rx.Matches($html)) {
        if ($m.Groups[1].Success) {
            # 文件夹入栈
            $name = [System.Net.WebUtility]::HtmlDecode(([regex]::Replace($m.Groups[1].Value, '<[^>]+>', '')).Trim())
            if ([string]::IsNullOrWhiteSpace($name)) { $name = '(未命名文件夹)' }
            $node = New-BmNode $name ''
            $parent = $stack.Peek()
            $parent.children = @($parent.children) + @($node)
            $stack.Push($node)
        }
        elseif ($m.Groups[2].Success) {
            # 书签
            $url  = [System.Net.WebUtility]::HtmlDecode($m.Groups[2].Value.Trim())
            $name = [System.Net.WebUtility]::HtmlDecode(([regex]::Replace($m.Groups[3].Value, '<[^>]+>', '')).Trim())
            if ([string]::IsNullOrWhiteSpace($name)) { $name = $url }
            if ([string]::IsNullOrWhiteSpace($url))  { continue }
            $node = New-BmNode $name $url
            $parent = $stack.Peek()
            $parent.children = @($parent.children) + @($node)
        }
        else {
            # </DL> 出栈（保留 root）
            if ($stack.Count -gt 1) { $null = $stack.Pop() }
        }
    }
    return $root
}

# ============================================================
#  解析 Chromium Bookmarks JSON
# ============================================================
function Convert-ChromiumChildren {
    param($Children)
    $out = @()
    if (-not $Children) { return $out }
    foreach ($c in @($Children)) {
        if (-not $c) { continue }
        $t = [string]$c['type']
        if ($t -eq 'url') {
            $u = [string]$c['url']
            if ([string]::IsNullOrWhiteSpace($u)) { continue }
            $out += New-BmNode ([string]$c['name']) $u
        }
        elseif ($t -eq 'folder') {
            $f = New-BmNode ([string]$c['name']) ''
            $f.children = @(Convert-ChromiumChildren $c['children'])
            $out += $f
        }
    }
    return $out
}

function ConvertFrom-ChromiumJson {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { throw "文件不存在: $Path" }
    $null = Initialize-BmSerializer
    $raw = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    $obj = $script:BmSer.DeserializeObject($raw)
    if (-not $obj) { throw "JSON 解析失败: $Path" }

    $roots = $obj['roots']
    if (-not $roots) { throw "不是 Chromium Bookmarks 格式（缺 roots 节点）: $Path" }

    $root = New-BmNode 'root' ''
    $map = [ordered]@{ bookmark_bar = '书签栏'; other = '其他书签'; synced = '移动设备书签' }
    foreach ($key in @('bookmark_bar', 'other', 'synced')) {
        $r = $roots[$key]
        if (-not $r) { continue }
        $bar = New-BmNode $map[$key] ''
        $bar.children = @(Convert-ChromiumChildren $r['children'])
        if (@($bar.children).Count -gt 0) {
            $root.children = @($root.children) + @($bar)
        }
    }
    return $root
}

# 按扩展名自动选解析器；没有扩展名（如 Chromium 的 `Bookmarks` 文件）就看内容
function Read-BookmarkFile {
    param([Parameter(Mandatory)][string]$Path)
    $ext = [System.IO.Path]::GetExtension($Path).ToLower()

    if ($ext -in @('.html', '.htm')) { return ConvertFrom-NetscapeHtml -Path $Path }
    if ($ext -eq '.json')            { return ConvertFrom-ChromiumJson -Path $Path }

    # 无扩展名 / 未知扩展名：读头 512 字节猜格式
    $head = ''
    try {
        $fs = [System.IO.File]::OpenRead($Path)
        try {
            $buf = New-Object byte[] 512
            $n = $fs.Read($buf, 0, 512)
            $head = [System.Text.Encoding]::UTF8.GetString($buf, 0, $n).TrimStart()
        } finally { $fs.Dispose() }
    } catch { throw "读不了文件: $Path ($($_.Exception.Message))" }

    if ($head.StartsWith('{')) { return ConvertFrom-ChromiumJson -Path $Path }
    if ($head -match '(?i)<!DOCTYPE|<META|<DL|NETSCAPE') { return ConvertFrom-NetscapeHtml -Path $Path }

    throw "不认识的书签文件类型（扩展名 '$ext'，开头 '$($head.Substring(0,[Math]::Min(30,$head.Length)))'）"
}

# 统计条目数（只数 url，不含文件夹）
function Count-BmNodes {
    param($Nodes)
    $n = 0
    foreach ($x in @($Nodes)) {
        if (-not $x) { continue }
        if ($x.url) { $n++ }
        if ($x.children -and @($x.children).Count -gt 0) { $n += Count-BmNodes $x.children }
    }
    return $n
}

# ============================================================
#  合并写入
# ============================================================
# 统计一个 Bookmarks 文件里现有的书签条数（供 DryRun 预览用）
function Get-BookmarksCount {
    param([Parameter(Mandatory)][string]$BookmarksPath)
    $null = Initialize-BmSerializer
    if (-not (Test-Path -LiteralPath $BookmarksPath)) { return 0 }
    try {
        $raw = [System.IO.File]::ReadAllText($BookmarksPath, [System.Text.Encoding]::UTF8)
        $doc = $script:BmSer.DeserializeObject($raw)
        if (-not $doc -or -not $doc['roots']) { return 0 }
        $n = Count-BmNodes $doc['roots']['bookmark_bar']['children']
        if ($doc['roots']['other']) { $n += Count-BmNodes $doc['roots']['other']['children'] }
        return $n
    } catch { return 0 }
}

function New-BmGuid {
    return [guid]::NewGuid().ToString('N')
}

# Chromium 的 date_added：1601-01-01 起的微秒数（字符串）
function Get-ChromeTime {
    param([datetime]$When = (Get-Date))
    $epochDiff = [long]11644473600000000
    return [string]([long]($When.ToUniversalTime().Ticks / 10) + $epochDiff)
}

# 把合并后的节点树转成 Chromium 节点结构，同时分配唯一 id
function ConvertTo-ChromiumNodes {
    param(
        $Nodes,
        [Parameter(Mandatory)]$UsedIds,     # HashSet[string]，会被修改
        [ref]$NextCounter                   # 可选：外部计数器
    )
    $out = @()
    foreach ($n in @($Nodes)) {
        if (-not $n) { continue }
        $id = $null
        if ($NextCounter) {
            $i = $NextCounter.Value
            while ($true) {
                $c = [string]$i
                if (-not $UsedIds.Contains($c)) { $null = $UsedIds.Add($c); $id = $c; $NextCounter.Value = $i + 1; break }
                $i++
            }
        } else {
            $i = 1
            while ($true) {
                $c = [string]$i
                if (-not $UsedIds.Contains($c)) { $null = $UsedIds.Add($c); $id = $c; break }
                $i++
            }
        }

        if ($n.url) {
            $out += [ordered]@{
                date_added     = (Get-ChromeTime)
                date_last_used = '0'
                guid           = (New-BmGuid)
                id             = $id
                name           = [string]$n.name
                type           = 'url'
                url            = [string]$n.url
            }
        } else {
            $kids = @()
            if ($n.children -and @($n.children).Count -gt 0) {
                $kids = @(ConvertTo-ChromiumNodes -Nodes $n.children -UsedIds $UsedIds -NextCounter $NextCounter)
            }
            $out += [ordered]@{
                children      = $kids
                date_added    = (Get-ChromeTime)
                date_modified = (Get-ChromeTime)
                guid          = (New-BmGuid)
                id            = $id
                name          = [string]$n.name
                type          = 'folder'
            }
        }
    }
    return $out
}

# 把 $MergedNodes 追加到 $BookmarksPath 的「$FolderName」文件夹下
# 返回 @{ Before; After; Added }
function Merge-IntoBookmarks {
    param(
        [Parameter(Mandatory)][string]$BookmarksPath,
        [Parameter(Mandatory)]$MergedNodes,
        [string]$FolderName = '旧电脑书签'
    )
    $null = Initialize-BmSerializer

    if (-not (Test-Path -LiteralPath $BookmarksPath)) { throw "Bookmarks 文件不存在: $BookmarksPath" }
    $raw = [System.IO.File]::ReadAllText($BookmarksPath, [System.Text.Encoding]::UTF8)
    $doc = $script:BmSer.DeserializeObject($raw)
    if (-not $doc) { throw "Bookmarks 解析失败: $BookmarksPath" }
    if (-not $doc['roots']) { throw "Bookmarks 缺 roots 节点: $BookmarksPath" }

    # 1. 收集已有 id
    $used = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($k in @('bookmark_bar', 'other', 'synced')) {
        $r = $doc['roots'][$k]
        if (-not $r) { continue }
        if ($r['id']) { $null = $used.Add([string]$r['id']) }
        $stack2 = New-Object System.Collections.Stack
        $stack2.Push($r['children'])
        while ($stack2.Count -gt 0) {
            $cur = $stack2.Pop()
            foreach ($n in @($cur)) {
                if (-not $n) { continue }
                if ($n['id']) { $null = $used.Add([string]$n['id']) }
                if ($n['children'] -and @($n['children']).Count -gt 0) { $stack2.Push($n['children']) }
            }
        }
    }

    $before = (Count-BmNodes $doc['roots']['bookmark_bar']['children']) +
              (Count-BmNodes $(if ($doc['roots']['other']) { $doc['roots']['other']['children'] } else { @() }))

    # 2. 转节点
    $counter = 1
    $newKids = @(ConvertTo-ChromiumNodes -Nodes $MergedNodes -UsedIds $used -NextCounter ([ref]$counter))

    # 3. 找/建目标文件夹
    $bar = $doc['roots']['bookmark_bar']
    if (-not $bar) { throw "Bookmarks 缺 bookmark_bar 节点: $BookmarksPath" }
    if (-not $bar['children']) { $bar['children'] = @() }

    $existing = $null
    foreach ($c in @($bar['children'])) {
        if ($c -and [string]$c['type'] -eq 'folder' -and [string]$c['name'] -eq $FolderName) { $existing = $c; break }
    }

    if ($existing) {
        $existing['children'] = @($existing['children']) + @($newKids)
        $existing['date_modified'] = Get-ChromeTime
    } else {
        # 新文件夹的 id 从计数器继续分配
        $fid = $null
        $i = $counter
        while ($true) {
            $c = [string]$i
            if (-not $used.Contains($c)) { $null = $used.Add($c); $fid = $c; break }
            $i++
        }
        $folder = [ordered]@{
            children      = @($newKids)
            date_added    = (Get-ChromeTime)
            date_modified = (Get-ChromeTime)
            guid          = (New-BmGuid)
            id            = $fid
            name          = $FolderName
            type          = 'folder'
        }
        $bar['children'] = @($bar['children']) + @($folder)
    }

    # 4. 删掉 checksum，让浏览器自己重算
    #    注意：不能写 $doc.Contains('checksum') —— Dictionary<string,object> 的 Contains 要 KeyValuePair
    $hasChecksum = $false
    foreach ($k in @($doc.Keys)) {
        if ([string]$k -eq 'checksum') { $hasChecksum = $true; break }
    }
    if ($hasChecksum) { $null = $doc.Remove('checksum') }

    # 5. 写回（无 BOM UTF-8）
    $json = $script:BmSer.Serialize($doc)
    [System.IO.File]::WriteAllText($BookmarksPath, $json, (New-Object System.Text.UTF8Encoding($false)))

    $after = (Count-BmNodes $doc['roots']['bookmark_bar']['children']) +
             (Count-BmNodes $(if ($doc['roots']['other']) { $doc['roots']['other']['children'] } else { @() }))

    return [pscustomobject]@{ Before = $before; After = $after; Added = ($after - $before) }
}
