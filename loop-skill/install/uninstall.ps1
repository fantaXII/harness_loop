#requires -Version 5.1

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$InstallStateFile = Join-Path $ScriptDir "install-state.json"

function Test-Installed {
    if (-not (Test-Path $InstallStateFile)) {
        Write-Host "❌ Error: Not installed." -ForegroundColor Red
        exit 1
    }
}

function Unregister-HooksAndCommands {
    $state = Get-Content $InstallStateFile -Raw | ConvertFrom-Json
    foreach ($f in $state.files_created) {
        if (Test-Path $f) { Remove-Item $f -Force; Write-Host "   ✓ Removed: $f" -ForegroundColor Green }
    }

    $hookInfo = $state.hooks_installed | Select-Object -First 1
    if ($hookInfo -and (Test-Path $hookInfo.target_file)) {
        $settings = Get-Content $hookInfo.target_file -Raw | ConvertFrom-Json
        if ($settings.hooks -and $settings.hooks.Stop) {
            $settings.hooks.Stop = $settings.hooks.Stop | Where-Object {
                -not ($_.hooks | Where-Object { $_.command -eq $hookInfo.command })
            }
            try {
                $settings | ConvertTo-Json -Depth 10 | Set-Content $hookInfo.target_file
                Write-Host "   ✓ Removed Stop hook entry from $($hookInfo.target_file)" -ForegroundColor Green
            } catch {
                Write-Host "⚠️  Precise removal failed — backup at $($hookInfo.backup_file)" -ForegroundColor Yellow
            }
        }
        if (Test-Path $hookInfo.backup_file) { Remove-Item $hookInfo.backup_file -Force }
    }
}

function Uninstall-Payload {
    $state = Get-Content $InstallStateFile -Raw | ConvertFrom-Json
    $target = $state.installations.claude_code.target
    if ($state.installations.claude_code.installed -and (Test-Path $target)) {
        Remove-Item $target -Recurse -Force
        Write-Host "   ✓ Removed: $target" -ForegroundColor Green
    }
}

function Main {
    Write-Host "🗑️  Loop Skill Uninstaller" -ForegroundColor Cyan
    Test-Installed
    Unregister-HooksAndCommands
    Uninstall-Payload
    Remove-Item $InstallStateFile -Force
    Write-Host "✅ Uninstallation complete!" -ForegroundColor Green
}

Main
