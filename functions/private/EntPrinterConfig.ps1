function Get-WinUtilEntPrinterConfigPath {

    <#

    .SYNOPSIS
        Where this machine's own printer and share configuration is kept

    .DESCRIPTION
        The published build carries a copy of the site configuration inside itself, which is fine
        for a read-only default but is not somewhere an operator should edit: it is regenerated on
        every build and it is the same file on every machine. The editor therefore writes here, in
        the user's own profile: one file per machine, never committed, never embedded, and it
        survives a program update.

    #>
    if (-not $sync.winutildir) {
        $sync.winutildir = Join-Path $env:LOCALAPPDATA "winutil"
    }
    return (Join-Path $sync.winutildir "entprinters.user.json")
}

function Update-WinUtilEntPrinterConfig {

    <#

    .SYNOPSIS
        Swaps in this machine's printer and share configuration, if it has one

    .DESCRIPTION
        Called once at startup before any print page reads the config, so every existing consumer
        keeps reading $sync.configs.entprinters and does not have to know an override exists. The
        built-in copy is kept at $sync.configs.entprintersDefault for the editor's
        「恢复内置配置」 and for copying driver-file names onto a new printer.

        A file that cannot be parsed leaves the built-in config in place: a broken hand-edited
        file must not take printing down.

    #>
    $embedded = $sync.configs.entprinters
    if (-not $sync.configs.ContainsKey("entprintersDefault")) {
        $sync.configs.entprintersDefault = $embedded
    }

    $path = Get-WinUtilEntPrinterConfigPath
    if (-not (Test-Path -LiteralPath $path)) { return $embedded }

    $loaded = $null
    try {
        $loaded = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Write-WinUtilLog -Level "WARN" -Component "Printers" -Message "本机打印配置解析失败，改用内置配置: $($_.Exception.Message)"
        Write-Host "  [警告] 本机打印配置（$path）读不懂，已改用程序内置配置。打开「打印共享」页的配置编辑器保存一次即可修复。"
        return $embedded
    }

    if (-not $loaded -or -not $loaded.printers) {
        Write-WinUtilLog -Level "WARN" -Component "Printers" -Message "本机打印配置没有 printers 节点，改用内置配置"
        Write-Host "  [警告] 本机打印配置里没有打印机条目，已改用程序内置配置。"
        return $embedded
    }

    $sync.configs.entprinters = $loaded
    foreach ($problem in @(Test-WinUtilEntPrinterConfig -Config $loaded)) {
        Write-Host "  [提示] 本机打印配置：$problem"
    }
    Write-WinUtilLog -Level "INFO" -Component "Printers" -Message "Loaded per-machine printer config ($(@($loaded.printers).Count) printers, $(@($loaded.shares).Count) shares)"
    return $loaded
}

function New-WinUtilEntPrinterEntry {

    <#

    .SYNOPSIS
        A blank printer row for the editor, with the driver-file names borrowed from an existing entry

    .DESCRIPTION
        Everything except the name, address, location and colour capability is a property of the
        driver package rather than of the printer, and every site here installs from the same Ricoh
        package. Copying those four file names off the first configured printer is what lets someone
        add a printer without opening the JSON to look up how the driver package is laid out.

    #>
    param($Template)

    $source = $null
    if ($Template) { $source = @($Template.printers) | Where-Object { $_ } | Select-Object -First 1 }

    # A PSCustomObject rather than an ordered hashtable: ConvertTo-Json 5.1 refuses an ordered
    # hashtable nested inside an array, and property order still has to be preserved for the file.
    return New-Object psobject -Property ([ordered]@{
        Name            = ""
        Ip              = ""
        PortName        = ""
        DriverName      = if ($source) { [string]$source.DriverName } else { "" }
        DriverZip       = if ($source) { [string]$source.DriverZip } else { "" }
        DriverFile      = if ($source) { [string]$source.DriverFile } else { "" }
        DataFile        = if ($source) { [string]$source.DataFile } else { "" }
        ConfigFile      = if ($source) { [string]$source.ConfigFile } else { "" }
        HelpFile        = if ($source) { [string]$source.HelpFile } else { "" }
        DependentFiles  = if ($source) { @(@($source.DependentFiles) | Where-Object { $_ }) } else { @() }
        Location        = ""
        SupportColor    = $true
    })
}

function New-WinUtilEntShareEntry {
    return New-Object psobject -Property ([ordered]@{
        Name  = ""
        Paths = @()
        User  = ""
        Pass  = ""
        Drive = ""
    })
}

function Write-WinUtilEntPrinterConfig {

    <#

    .SYNOPSIS
        Normalizes, validates and saves a printer and share configuration to this machine

    .DESCRIPTION
        Nothing reaches the disk unless validation passes, so a half-typed row cannot leave the next
        install failing at 3 a.m. Returns the list of problems found and leaves the existing file
        untouched when that list is not empty.

    .PARAMETER Config
        Hashtable or object with formName, formWidthTenthMm, formHeightTenthMm, colorUserCode,
        driverDirNames, printers and shares

    #>
    param([Parameter(Mandatory)] $Config)

    $normalized = ConvertTo-WinUtilEntPrinterConfig -Config $Config
    $problems = @(Test-WinUtilEntPrinterConfig -Config $normalized)
    if ($problems.Count -gt 0) { return $problems }

    $path = Get-WinUtilEntPrinterConfigPath
    $directory = [System.IO.Path]::GetDirectoryName($path)
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    # The rows are PSCustomObjects, not ordered hashtables: ConvertTo-Json 5.1 throws on an ordered
    # hashtable nested inside an array, and -InputObject keeps the root from being enumerated.
    $json = ConvertTo-Json -InputObject $normalized -Depth 8
    # A failed write must not leave a truncated file behind: the next startup would fall back to the
    # built-in config and the operator would wonder why their edits disappeared.
    $tempPath = "$path.tmp"
    [System.IO.File]::WriteAllText($tempPath, $json, [System.Text.UTF8Encoding]::new($false))
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
    Move-Item -LiteralPath $tempPath -Destination $path

    # Read back from the text just written, so what runs in memory is exactly what is on disk.
    $sync.configs.entprinters = $json | ConvertFrom-Json
    Write-WinUtilLog -Level "INFO" -Component "Printers" -Message "Saved per-machine printer config to $path"
    return @()
}

function Remove-WinUtilEntPrinterConfig {

    <#

    .SYNOPSIS
        Drops this machine's configuration so the built-in one applies again

    #>
    $path = Get-WinUtilEntPrinterConfigPath
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Force
        Write-WinUtilLog -Level "INFO" -Component "Printers" -Message "Removed per-machine printer config"
    }
    if ($sync.configs.entprintersDefault) {
        $sync.configs.entprinters = $sync.configs.entprintersDefault
    } else {
        # Startup is what caches the built-in copy. Without it the in-memory config is whatever the
        # editor last saved, and saying nothing would promise a restore that did not happen.
        Write-WinUtilLog -Level "WARN" -Component "Printers" -Message "没有内置配置可回退，界面仍显示刚才保存的配置"
    }
}

function ConvertTo-WinUtilEntPrinterConfig {

    <#

    .SYNOPSIS
        Trims what the operator typed and fills in what the editor leaves blank

    .DESCRIPTION
        Pure: takes the edited values, returns objects ready to serialize. Port names
        are derived from the address because the install step matches on them, and the paper size is
        stored in tenths of a millimetres because that is what DEVMODE carries.

    .PARAMETER Config
        The edited configuration, loosely typed on purpose: hashtables from the editor or objects
        from a previous save both work

    #>
    param([Parameter(Mandatory)] $Config)

    $printers = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in @($Config.printers) | Where-Object { $_ }) {
        $ip = ("" + $entry.Ip).Trim()
        $port = ("" + $entry.PortName).Trim()
        if (-not $port -and $ip) { $port = "IP_$ip" }

        $printers.Add((New-Object psobject -Property ([ordered]@{
            Name           = ("" + $entry.Name).Trim()
            Ip             = $ip
            PortName       = $port
            DriverName     = ("" + $entry.DriverName).Trim()
            DriverZip      = ("" + $entry.DriverZip).Trim()
            DriverFile     = ("" + $entry.DriverFile).Trim()
            DataFile       = ("" + $entry.DataFile).Trim()
            ConfigFile     = ("" + $entry.ConfigFile).Trim()
            HelpFile       = ("" + $entry.HelpFile).Trim()
            DependentFiles = @(@($entry.DependentFiles) | Where-Object { $_ } | ForEach-Object { ("" + $_).Trim() })
            Location       = ("" + $entry.Location).Trim()
            SupportColor   = [bool]$entry.SupportColor
        })))
    }

    $shares = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in @($Config.shares) | Where-Object { $_ }) {
        $shares.Add((New-Object psobject -Property ([ordered]@{
            Name  = ("" + $entry.Name).Trim()
            Paths = @(@($entry.Paths) | Where-Object { $_ } | ForEach-Object { ("" + $_).Trim() })
            User  = ("" + $entry.User).Trim()
            Pass  = ("" + $entry.Pass)
            Drive = ("" + $entry.Drive).Trim().ToUpperInvariant()
        })))
    }

    $width = ("" + $Config.formWidthTenthMm).Trim()
    $height = ("" + $Config.formHeightTenthMm).Trim()
    if ($width -match "^\d+(\.\d+)?$") { $width = [int]([double]$width) }
    if ($height -match "^\d+(\.\d+)?$") { $height = [int]([double]$height) }

    return New-Object psobject -Property ([ordered]@{
        formName          = ("" + $Config.formName).Trim()
        formWidthTenthMm  = $width
        formHeightTenthMm = $height
        colorUserCode     = ("" + $Config.colorUserCode).Trim()
        driverDirNames    = @(@($Config.driverDirNames) | Where-Object { $_ } | ForEach-Object { ("" + $_).Trim() })
        printers          = $printers.ToArray()
        shares            = $shares.ToArray()
    })
}

function Test-WinUtilEntPrinterConfig {

    <#

    .SYNOPSIS
        What is wrong with a printer and share configuration, in Chinese, as a list

    .DESCRIPTION
        Pure and independent of the interface, because both the save button and the startup load run
        the same rules. Every problem names the entry it belongs to: an operator fixing a typo at
        3 a.m. should not have to count array indexes.

    .PARAMETER Config
        The normalized configuration

    #>
    param([Parameter(Mandatory)] $Config)

    $problems = [System.Collections.Generic.List[string]]::new()

    $paperName = ("" + $Config.formName).Trim()
    if (-not $paperName) {
        $problems.Add("纸张名称不能为空。")
    } elseif ($paperName.Length -gt 31) {
        $problems.Add("纸张名称「$paperName」超过 31 个字符，驱动里的纸名放不下。")
    }
    foreach ($size in @(@{ Label = "纸张宽度"; Value = $Config.formWidthTenthMm }, @{ Label = "纸张高度"; Value = $Config.formHeightTenthMm })) {
        $tenths = 0
        if (-not [int]::TryParse(("" + $size.Value).Trim(), [ref]$tenths)) {
            $problems.Add("$($size.Label)要填整数，单位 0.1 毫米。")
        } elseif ($tenths -lt 100 -or $tenths -gt 32767) {
            $problems.Add("$($size.Label)只能是 10～3276.7 毫米（即 100～32767 个 0.1 毫米），当前 $tenths。")
        }
    }

    $printerNames = @{}
    $index = 0
    foreach ($printer in @($Config.printers) | Where-Object { $_ }) {
        $index++
        $label = ("" + $printer.Name).Trim()
        if (-not $label) { $label = "第 $index 台" }

        if (-not ("" + $printer.Name).Trim()) { $problems.Add("$label ：名称不能为空。") }
        elseif ($printerNames.ContainsKey($printer.Name)) { $problems.Add("打印机名称「$($printer.Name)」重复（$label）。") }
        else { $printerNames[$printer.Name] = $true }

        $ip = ("" + $printer.Ip).Trim()
        $address = $null
        if (-not [System.Net.IPAddress]::TryParse($ip, [ref]$address)) {
            $problems.Add("$label ：IP「$ip」不是有效的 IPv4 地址。")
        }
        if (("" + $printer.PortName).Trim() -match "\s") {
            $problems.Add("$label ：端口名称「$($printer.PortName)」不能含空格。")
        }
        foreach ($field in @("DriverName", "DriverZip", "DriverFile", "DataFile", "ConfigFile", "HelpFile")) {
            if (-not ("" + $printer.$field).Trim()) {
                $problems.Add("$label ：$field 不能为空（驱动包里的文件名）。")
            }
        }
    }
    if (@($Config.printers | Where-Object { $_ }).Count -eq 0) {
        $problems.Add("至少要配置一台打印机。")
    }

    $drives = @{}
    $shareIndex = 0
    foreach ($share in @($Config.shares) | Where-Object { $_ }) {
        $shareIndex++
        $label = ("" + $share.Name).Trim()
        if (-not $label) { $label = "第 $shareIndex 个共享" }

        if (-not ("" + $share.Name).Trim()) { $problems.Add("$label ：名称不能为空。") }
        $paths = @(@($share.Paths) | Where-Object { $_ })
        if ($paths.Count -eq 0) {
            $problems.Add("$label ：至少要有共享路径（形如 \\\\server\\share）。")
        }
        foreach ($path in $paths) {
            if (("" + $path) -notmatch "^\\\\[^\\]+\\") {
                $problems.Add("$label ：路径「$path」不是 UNC 路径，应为 \\\\服务器\\共享名。")
            }
        }
        if (("" + $share.User).Trim() -match "\s") {
            $problems.Add("$label ：账号「$($share.User)」不能含空格（域账号请写成 域\账号）。")
        }
        $drive = ("" + $share.Drive).Trim()
        if ($drive -notmatch "^[A-Z]:$") {
            $problems.Add("$label ：盘符「$drive」要写成单个字母加冒号，例如 Z:。")
        } elseif ($drives.ContainsKey($drive)) {
            $problems.Add("$label ：盘符 $drive 已被「$($drives[$drive])」使用。")
        } else { $drives[$drive] = ("" + $share.Name) }
    }

    return $problems.ToArray()
}
