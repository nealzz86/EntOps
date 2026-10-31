#===========================================================================
# Tests - Work button routing

BeforeAll {
    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
    . (Join-Path $script:repoRoot "functions\public\Invoke-WPFUpdatesdisable.ps1")
    . (Join-Path $script:repoRoot "functions\public\Invoke-WPFButton.ps1")

    function Start-WinUtilJob {
        param([string]$Name, [scriptblock]$ScriptBlock, [hashtable]$Parameters)
    }
    function Step-WinUtilJob {
        param([string]$Status, [int]$Percent, [string]$State, [string]$Overlay, [switch]$Hide)
    }
    function Write-WinUtilLog {
        param($Message, $Level, $Component)
    }
    function Write-WinUtilErrorRecord {
        param($ErrorRecord, $Component, $Context)
    }
    function Invoke-WPFFeatureInstall { }
    function Invoke-WPFPresets {
        param($preset, $imported, $checkboxfilterpattern)
    }
    function Invoke-WPFUltimatePerformance {
        param([switch]$Enable)
    }
}

Describe "Work button preflight" {
    BeforeEach {
        $script:sync = [Hashtable]::Synchronized(@{
            ActiveJob = $null
            configs = @{
                feature = @{
                    WPFFeatureInstall = [pscustomobject]@{
                        Content = "Install Features"
                        function = "Invoke-WPFFeatureInstall"
                    }
                }
                routes = @{
                    WPFUpdatesdisable = [pscustomobject]@{
                        function = "Invoke-WPFUpdatesdisable"
                        work = $true
                        confirm = "Confirm-WPFUpdatesdisable"
                    }
                }
            }
            WPFUpdatesdisable = [pscustomobject]@{ Content = "Disable Updates" }
        })
        $script:capturedJob = $null

        Mock Step-WinUtilJob { }
        Mock Write-WinUtilLog { }
        Mock Write-WinUtilErrorRecord { }
        Mock Invoke-WPFFeatureInstall { }
        Mock Invoke-WPFUpdatesdisable { }
        Mock Confirm-WPFUpdatesdisable { $true }
        Mock Start-WinUtilJob {
            $script:capturedJob = [pscustomobject]@{
                Name = $Name
                ScriptBlock = $ScriptBlock
                Parameters = $Parameters
            }
        }
    }

    AfterEach {
        Remove-Variable -Name sync -Scope Script -ErrorAction SilentlyContinue
        Remove-Variable -Name capturedJob -Scope Script -ErrorAction SilentlyContinue
    }

    It "lets feature installation validate its selection before starting a job" {
        Invoke-WPFButton -Button "WPFFeatureInstall"

        Should -Invoke Invoke-WPFFeatureInstall -Times 1 -Exactly
        Should -Invoke Start-WinUtilJob -Times 0 -Exactly
    }

    It "does not start the update-disable job when confirmation is declined" {
        Mock Confirm-WPFUpdatesdisable { $false }

        Invoke-WPFButton -Button "WPFUpdatesdisable"

        Should -Invoke Confirm-WPFUpdatesdisable -Times 1 -Exactly
        Should -Invoke Start-WinUtilJob -Times 0 -Exactly
    }

    It "passes completed confirmation into the update-disable job" {
        Invoke-WPFButton -Button "WPFUpdatesdisable"

        Should -Invoke Start-WinUtilJob -Times 1 -Exactly -ParameterFilter {
            $Name -eq "Disable Updates" -and $Parameters.Confirmed -eq $true
        }

        $jobParameters = $script:capturedJob.Parameters
        & $script:capturedJob.ScriptBlock @jobParameters

        Should -Invoke Invoke-WPFUpdatesdisable -Times 1 -Exactly -ParameterFilter { $Confirmed }
        Should -Invoke Confirm-WPFUpdatesdisable -Times 1 -Exactly
    }
}

Describe "Declared route dispatch" {
    BeforeEach {
        $script:sync = [Hashtable]::Synchronized(@{
            ActiveJob = $null
            configs = @{
                feature = @{}
                routes = @{}
            }
        })
        $script:jobCount = 0

        Mock Step-WinUtilJob { }
        Mock Write-WinUtilLog { }
        Mock Write-WinUtilErrorRecord { }
        Mock Start-WinUtilJob { $script:jobCount++ }
    }

    AfterEach {
        Remove-Variable -Name sync -Scope Script -ErrorAction SilentlyContinue
        Remove-Variable -Name jobCount -Scope Script -ErrorAction SilentlyContinue
    }

    It "calls the handler with the arguments the route declares" {
        $script:sync.configs.routes["WPFStandard"] = [pscustomobject]@{
            function = "Invoke-WPFPresets"
            arguments = [pscustomobject]@{ preset = "Standard"; checkboxfilterpattern = "WPFTweak*" }
        }
        Mock Invoke-WPFPresets { }

        Invoke-WPFButton -Button "WPFStandard"

        Should -Invoke Invoke-WPFPresets -Times 1 -Exactly -ParameterFilter {
            $preset -eq "Standard" -and $checkboxfilterpattern -eq "WPFTweak*"
        }
        # A button that only repaints the interface must not queue a job
        $script:jobCount | Should -Be 0
    }

    It "queues a job for a route that changes the system" {
        $script:sync.configs.routes["WPFRemoveUltPerf"] = [pscustomobject]@{
            function = "Invoke-WPFUltimatePerformance"
            work = $true
        }
        $script:sync.WPFRemoveUltPerf = [pscustomobject]@{ Content = "Remove Ultimate Performance" }
        Mock Invoke-WPFUltimatePerformance { }

        Invoke-WPFButton -Button "WPFRemoveUltPerf"

        $script:jobCount | Should -Be 1
    }

    It "warns rather than saying nothing when a button has no route" {
        # This is the failure a new button produces: it is wired to the dispatcher like every other,
        # matches nothing, and the click is silent.
        Invoke-WPFButton -Button "WPFStrayButton"

        Should -Invoke Write-WinUtilLog -Times 1 -Exactly -ParameterFilter {
            $Level -eq "WARN" -and $Component -eq "UI" -and $Message -like "*WPFStrayButton*"
        }
    }

    It "warns when a route names a handler that is not there" {
        $script:sync.configs.routes["WPFBroken"] = [pscustomobject]@{ function = "Invoke-WPFNotDefined" }

        Invoke-WPFButton -Button "WPFBroken"

        Should -Invoke Write-WinUtilLog -Times 1 -Exactly -ParameterFilter {
            $Level -eq "WARN" -and $Message -like "*Invoke-WPFNotDefined*"
        }
    }
}
