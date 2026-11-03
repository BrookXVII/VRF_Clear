
$settingsPath = "D:\Scripts\VRF\verifybot\pbSettings\BotSettings.json"
$botSettings = Get-Content -Path $settingsPath | ConvertFrom-Json
$botSettings.checkStaffRun = $true
$pendingSettingsPath = "$settingsPath.$PID.pending"
try {
    $botSettings | ConvertTo-Json -Depth 10 |
        Set-Content -LiteralPath $pendingSettingsPath -Encoding UTF8 -ErrorAction Stop
    [System.IO.File]::Replace($pendingSettingsPath, $settingsPath, $null)
}
finally {
    if (Test-Path -LiteralPath $pendingSettingsPath) {
        Remove-Item -LiteralPath $pendingSettingsPath -Force -ErrorAction SilentlyContinue
    }
}