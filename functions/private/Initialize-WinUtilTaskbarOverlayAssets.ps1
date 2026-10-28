function Initialize-WinUtilTaskbarOverlayAssets {
    param(
        [bool]$IncludeLogo = $true,
        [bool]$IncludeStatusAssets = $true
    )

    [System.Threading.Monitor]::Enter($sync.SyncRoot)
    try {
        if ($null -eq $sync.AssetRenderLock) {
            $sync.AssetRenderLock = [object]::new()
        }
        $assetRenderLock = $sync.AssetRenderLock
    } finally {
        [System.Threading.Monitor]::Exit($sync.SyncRoot)
    }

    # The overlays are also rasterised on a thread of their own at startup. Waiting for that thread
    # here would put an unbounded lock wait on the interface thread, and a render that never
    # finishes would look exactly like a frozen window - so this asks once and walks away. A taskbar
    # icon that stays plain for a while costs nothing; a window that stops painting costs everything.
    if (-not [System.Threading.Monitor]::TryEnter($assetRenderLock, 0)) { return }
    try {
        if ($IncludeLogo -and -not $sync["logorender"]) {
            $sync["logorender"] = (Invoke-WinUtilAssets -Type "Logo" -Size 90 -Render)
        }

        if ($IncludeStatusAssets -and -not $sync["checkmarkrender"]) {
            $sync["checkmarkrender"] = (Invoke-WinUtilAssets -Type "checkmark" -Size 512 -Render)
        }

        if ($IncludeStatusAssets -and -not $sync["warningrender"]) {
            $sync["warningrender"] = (Invoke-WinUtilAssets -Type "warning" -Size 512 -Render)
        }
    } finally {
        [System.Threading.Monitor]::Exit($assetRenderLock)
    }
}
