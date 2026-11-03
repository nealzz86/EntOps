Set-StrictMode -Version 3

BeforeAll {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
    $script:xamlPath = Join-Path $repoRoot "xaml\inputXML.xaml"
    $script:cleanPath = Join-Path $repoRoot "functions\public\Invoke-WPFDiskClean.ps1"

    . (Join-Path $repoRoot "functions\private\DiskCleanCommon.ps1")
    . (Join-Path $repoRoot "functions\private\Clear-WinUtilDiskJunk.ps1")

    $script:defs = @(Get-WinUtilDiskJunkDefs)
    $script:xamlText = Get-Content -LiteralPath $script:xamlPath -Raw -Encoding UTF8
    $script:cleanText = Get-Content -LiteralPath $script:cleanPath -Raw -Encoding UTF8
}

Describe "Get-WinUtilDiskJunkDefs" {
    It "keeps every category id unique" {
        $ids = @($script:defs | ForEach-Object { $_.Id })
        $duplicates = @($ids | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })

        $duplicates | Should -BeNullOrEmpty -Because "a repeated id means two rows share one size label"
    }

    It "gives every category something to measure" {
        $empty = @($script:defs | Where-Object {
                -not @($_.Roots | Where-Object { $_ }) -and -not @($_.Files | Where-Object { $_ }) -and -not $_.Special
            } | ForEach-Object { $_.Id })

        $empty | Should -BeNullOrEmpty -Because "a category with no roots always scans 0 B and only confuses the operator"
    }

    It "ships the AI categories alongside the system ones" {
        $ids = @($script:defs | ForEach-Object { $_.Id })

        $ids | Should -Contain "AiChat"
        $ids | Should -Contain "AiCoder"
        $ids | Should -Contain "AiUpdater"
        $ids | Should -Contain "AiModels"
        $ids.Count | Should -BeGreaterOrEqual 16
    }

    It "never reaches into the folders that hold an AI client's account or chat history" {
        $stateHolders = @("Local Storage", "Session Storage", "IndexedDB", "WebStorage")
        $aiRoots = @($script:defs | Where-Object { $_.Id -like "Ai*" } | ForEach-Object { $_.Roots } | Where-Object { $_ })

        $hits = @(foreach ($root in $aiRoots) { foreach ($holder in $stateHolders) { if ($root -like "*\$holder*") { "$root -> $holder" } } })
        $hits | Should -BeNullOrEmpty -Because "clearing a cache is safe, clearing storage logs people out and drops their conversations"
    }

    It "only touches the updater drop folders for the update package category" {
        $updater = $script:defs | Where-Object { $_.Id -eq "AiUpdater" }

        foreach ($root in @($updater.Roots | Where-Object { $_ })) { $root | Should -Match "\\\*-updater\\" }
        foreach ($file in @($updater.Files | Where-Object { $_ })) { $file | Should -Match "\\\*-updater\\installer\.exe$" }
    }

    It "points the model category at model stores rather than app settings" {
        $models = @($script:defs | Where-Object { $_.Id -eq "AiModels" } | ForEach-Object { $_.Roots } | Where-Object { $_ })

        $models.Count | Should -BeGreaterOrEqual 3
        foreach ($root in $models) {
            ($root -match "\\models$|\\huggingface$|\\modelscope$|\\hub$") | Should -BeTrue -Because "only model stores may be dropped, never $root"
        }
    }
}

Describe "Disk clean panel wiring" {
    It "has a checkbox and a size label for every category" {
        $missing = [System.Collections.Generic.List[string]]::new()
        foreach ($def in $script:defs) {
            if ($script:xamlText -notmatch "Name=`"WPFDisk$($def.Id)`"") { $missing.Add("$($def.Id) has no WPFDisk$($def.Id) checkbox") }
            if ($script:xamlText -notmatch "Name=`"WPFDiskSize$($def.Id)`"") { $missing.Add("$($def.Id) has no WPFDiskSize$($def.Id) size label") }
        }

        $missing.Count | Should -Be 0 -Because ($missing | Out-String)
    }

    It "leaves the re-downloadable categories unchecked" {
        foreach ($id in @("AiUpdater", "AiModels", "LocalDev")) {
            $match = [regex]::Match($script:xamlText, "Name=`"WPFDisk$id`"[^>]*")
            $match.Success | Should -BeTrue
            $match.Value | Should -Not -Match "IsChecked=`"True`"" -Because "dropping $id costs a re-download, so the operator has to ask for it"
        }
    }

    It "ticks the AppData sweeps that only touch regenerable caches" {
        foreach ($id in @("LocalCache", "LocalNet")) {
            $match = [regex]::Match($script:xamlText, "Name=`"WPFDisk$id`"[^>]*")
            $match.Success | Should -BeTrue
            $match.Value | Should -Match "IsChecked=`"True`"" -Because "$id is the item operators actually expect cleaned by default"
        }
    }

    It "maps every category to a checkbox in the clean handler" {
        $missing = [System.Collections.Generic.List[string]]::new()
        foreach ($def in $script:defs) {
            if ($script:cleanText -notmatch "$($def.Id)\s*=\s`"WPFDisk$($def.Id)`"") { $missing.Add($def.Id) }
        }

        $missing.Count | Should -Be 0 -Because "a category the scan shows but the cleaner cannot tick is a dead row ($($missing -join ', '))"
    }

    It "warns about the categories that cost a re-download" {
        $script:cleanText | Should -Match "AiModels"
        $script:cleanText | Should -Match "重新下载"
    }
}

Describe "Files support in a junk category" {
    BeforeAll {
        $script:sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("entops-junk-" + [Guid]::NewGuid().ToString("N"))
        $updater = Join-Path $script:sandbox "some-app-updater"
        $pending = Join-Path $updater "pending"
        New-Item -ItemType Directory -Path $pending -Force | Out-Null
        [System.IO.File]::WriteAllBytes((Join-Path $updater "installer.exe"), (New-Object byte[] 4096))
        [System.IO.File]::WriteAllBytes((Join-Path $pending "payload.bin"), (New-Object byte[] 2048))
        $script:sandboxDef = @{
            Id    = "Sandbox"
            Name  = "沙箱"
            Roots = @((Join-Path $updater "pending"))
            Files = @((Join-Path $updater "installer.exe"))
        }
    }

    AfterAll {
        if ($script:sandbox -and (Test-Path -LiteralPath $script:sandbox)) {
            Remove-Item -LiteralPath $script:sandbox -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "counts loose files as well as directories" {
        Measure-WinUtilDiskJunkDef -Def $script:sandboxDef | Should -Be 6144
    }

    It "deletes loose files and returns what it freed" {
        $freed = Clear-WinUtilDiskJunkDef -Def $script:sandboxDef

        $freed | Should -Be 6144
        (Test-Path -LiteralPath (Join-Path $script:sandbox "some-app-updater\installer.exe")) | Should -BeFalse
        (Get-ChildItem -LiteralPath (Join-Path $script:sandbox "some-app-updater\pending") -Force).Count | Should -Be 0
        (Test-Path -LiteralPath (Join-Path $script:sandbox "some-app-updater\pending")) | Should -BeTrue -Because "the engine empties a root, it never removes the root itself"
    }

    It "survives a category that declares no files at all" {
        $noFiles = @{ Id = "NoFiles"; Name = "无文件"; Roots = @((Join-Path $script:sandbox "missing")) }

        { Measure-WinUtilDiskJunkDef -Def $noFiles } | Should -Not -Throw
        Measure-WinUtilDiskJunkDef -Def $noFiles | Should -Be 0
    }
}

Describe "AppData\Local categories" {
    It "ships the local app data sweeps" {
        $ids = @($script:defs | ForEach-Object { $_.Id })

        $ids | Should -Contain "LocalCache"
        $ids | Should -Contain "LocalNet"
        $ids | Should -Contain "LocalDev"
        $ids.Count | Should -BeGreaterOrEqual 19
    }

    It "only offers standard cache leaves one level under AppData\Local" {
        $leafNames = @("Cache", "Code Cache", "GPUCache", "GrShaderCache", "ShaderCache", "CachedData",
            "CachedExtensions", "blob_storage", "logs", "log", "tmp", "temp",
            "Crashpad", "CrashReports", "sentry", "SquirrelTemp")
        $roots = @($script:defs | Where-Object { $_.Id -eq "LocalCache" } | ForEach-Object { $_.Roots } | Where-Object { $_ })

        $roots.Count | Should -BeGreaterOrEqual 1
        $badLeaf = @($roots | Where-Object { $leafNames -notcontains (Split-Path $_ -Leaf) })
        $badLeaf | Should -BeNullOrEmpty -Because ("only regenerable leaves are offered, not " + ($badLeaf | Select-Object -First 3 | Out-String))

        $outside = @($roots | Where-Object { $_ -notlike ($env:LOCALAPPDATA + "\*") })
        $outside | Should -BeNullOrEmpty -Because "the sweep must never walk out of the current user's AppData\Local"
    }

    It "skips installed programs, app packages and the folders other categories own" {
        $roots = @($script:defs | Where-Object { $_.Id -eq "LocalCache" } | ForEach-Object { $_.Roots } | Where-Object { $_ })
        $blocked = @("Programs", "Packages", "Microsoft", "Application Data")
        $base = $env:LOCALAPPDATA.TrimEnd("\")

        # 比较第一段目录名，不用 *Microsoft* 这种通配：Microsoft_Corporation 是正经应用
        $topsRaw = @(foreach ($root in $roots) {
                $rel = $root
                if ($rel.Length -gt $base.Length -and $rel.Substring(0, $base.Length) -eq $base) { $rel = $rel.Substring($base.Length + 1) }
                ($rel -split "\\")[0]
            })
        $tops = @($topsRaw | Sort-Object -Unique)
        $badTops = @($tops | Where-Object { $blocked -contains $_ })
        $badTops | Should -BeNullOrEmpty -Because "those hold installed software and app state, not cache"

        $updaters = @($tops | Where-Object { $_ -like "*-updater" })
        $updaters | Should -BeNullOrEmpty -Because "the update package category already owns the *-updater folders"
    }

    It "keeps the network category on caches, not on browser profiles or fonts" {
        $roots = @($script:defs | Where-Object { $_.Id -eq "LocalNet" } | ForEach-Object { $_.Roots } | Where-Object { $_ })

        $roots.Count | Should -BeGreaterOrEqual 3
        $hits = @(foreach ($root in $roots) { foreach ($bad in @("User Data", "Fonts", "Explorer")) { if ($root -like "*\$bad*") { "$root -> $bad" } } })
        $hits | Should -BeNullOrEmpty -Because "profile settings, installed fonts and thumbnail caches belong to other categories"
    }

    It "clears package downloads without clearing installed toolchains" {
        $roots = @($script:defs | Where-Object { $_.Id -eq "LocalDev" } | ForEach-Object { $_.Roots } | Where-Object { $_ })

        $roots | Should -Contain (Join-Path $env:LOCALAPPDATA "pip\cache")
        $roots | Should -Contain (Join-Path $env:LOCALAPPDATA "uv\cache")
        $hits = @(foreach ($root in $roots) { foreach ($bad in @("\uv\python", "\uv\tools", "\Yarn", "\Programs", "\pnpm\")) { if ($root -like "*$bad*") { "$root -> $bad" } } })
        $hits | Should -BeNullOrEmpty -Because "uv and yarn keep installed interpreters and global bins in there, and those are not junk"
    }
}

Describe "AppData\Local sweep against a fake AppData" {
    BeforeAll {
        $script:laBackup = $env:LOCALAPPDATA
        $script:laSandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("entops-la-" + [Guid]::NewGuid().ToString("N"))
        foreach ($dir in @("MyApp\Cache", "MyApp\Local Storage", "MyApp\logs", "Programs\SomeApp\Cache",
                "Packages\SomeApp\Cache", "Microsoft\Edge\Cache", "SomeApp-updater\pending")) {
            New-Item -ItemType Directory -Path (Join-Path $script:laSandbox $dir) -Force | Out-Null
        }
        # %LOCALAPPDATA%\Application Data 是指回自己的 junction，跟进去会把整层重复数一遍
        New-Item -ItemType Junction -Path (Join-Path $script:laSandbox "Application Data") -Target $script:laSandbox | Out-Null

        $env:LOCALAPPDATA = $script:laSandbox
        $script:sweep = @((Get-WinUtilDiskJunkDefs | Where-Object { $_.Id -eq "LocalCache" }).Roots)
    }

    AfterAll {
        if ($script:laBackup) { $env:LOCALAPPDATA = $script:laBackup }
        if ($script:laSandbox -and (Test-Path -LiteralPath $script:laSandbox)) {
            [System.IO.Directory]::Delete((Join-Path $script:laSandbox "Application Data"), $false)
            Remove-Item -LiteralPath $script:laSandbox -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "offers the cache leaves of a normal app folder" {
        $script:sweep | Should -Contain (Join-Path $script:laSandbox "MyApp\Cache")
        $script:sweep | Should -Contain (Join-Path $script:laSandbox "MyApp\logs")
    }

    It "does not reach into program folders, packages, updaters or the self junction" {
        $blocked = @(
            (Join-Path $script:laSandbox "Programs\SomeApp\Cache")
            (Join-Path $script:laSandbox "SomeApp-updater\pending")
            (Join-Path $script:laSandbox "Application Data\Cache")
        )
        $leaves = @($script:sweep | Where-Object { $_ -like "*\Local Storage" })

        foreach ($path in $blocked) { $script:sweep | Should -Not -Contain $path }
        # Microsoft 整层交给别的类别，避免碰到已装 SDK 和浏览器配置
        @($script:sweep | Where-Object { $_ -like (Join-Path $script:laSandbox "Microsoft\*") }) | Should -BeNullOrEmpty
        $leaves | Should -BeNullOrEmpty -Because "Local Storage holds logins"
    }
}
