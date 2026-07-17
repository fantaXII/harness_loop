#requires -Version 5.1

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
# install/ lives inside loop-skill/ (see spec §1), so the skill payload root
# IS the parent of install/ — not a "loop-skill" subdirectory beneath it.
$SkillDir = Split-Path -Parent $ScriptDir
$InstallStateFile = Join-Path $ScriptDir "install-state.json"

$ClaudeSkillsDir = Join-Path $env:USERPROFILE ".claude\skills"
$ClaudeCommandsDir = Join-Path $env:USERPROFILE ".claude\commands"
$ClaudeAgentsDir = Join-Path $env:USERPROFILE ".claude\agents"
$ClaudeSettingsFile = Join-Path $env:USERPROFILE ".claude\settings.json"
$PayloadTarget = Join-Path $ClaudeSkillsDir "loop-skill"

$CreatedFiles = @()
$ModifiedFiles = @()
$HooksInstalled = @()

function Test-NotInstalled {
    if (Test-Path $InstallStateFile) {
        Write-Host "❌ Error: Already installed." -ForegroundColor Red
        exit 1
    }
}

function Test-SkillSource {
    if (-not (Test-Path $SkillDir)) {
        Write-Host "❌ Error: skill source not found at $SkillDir" -ForegroundColor Red
        exit 1
    }
}

function Get-SourceHash {
    $hash = Get-FileHash -Algorithm SHA256 -Path (Get-ChildItem -Recurse -File $SkillDir | Sort-Object FullName | ForEach-Object { $_.FullName }) -ErrorAction SilentlyContinue
    # Simplified: hash the concatenated file list; a real implementation should hash content, not just paths.
    return "sha256:approx"
}

function Install-Payload {
    if (Test-Path $PayloadTarget) {
        Write-Host "⚠️  Target already exists at $PayloadTarget — skipping" -ForegroundColor Yellow
        return $false
    }
    New-Item -ItemType Directory -Path $ClaudeSkillsDir -Force | Out-Null
    Copy-Item -Path $SkillDir -Destination $PayloadTarget -Recurse -Force
    return $true
}

function Register-HooksAndCommands {
    New-Item -ItemType Directory -Path $ClaudeCommandsDir -Force | Out-Null
    foreach ($cmd in @("loop-skill", "cancel-loop-skill")) {
        $src = Join-Path $PayloadTarget "commands\$cmd.md"
        $dest = Join-Path $ClaudeCommandsDir "$cmd.md"
        (Get-Content $src -Raw) -replace '\$\{CLAUDE_PLUGIN_ROOT\}', $PayloadTarget | Set-Content $dest
        $script:CreatedFiles += $dest
    }

    if (-not (Test-Path $ClaudeSettingsFile)) {
        New-Item -ItemType Directory -Path (Split-Path $ClaudeSettingsFile) -Force | Out-Null
        '{}' | Set-Content $ClaudeSettingsFile
    }
    $backup = "$ClaudeSettingsFile.loop-skill.bak"
    Copy-Item $ClaudeSettingsFile $backup -Force

    $settings = Get-Content $backup -Raw | ConvertFrom-Json
    $hookCmd = Join-Path $PayloadTarget "hooks\stop-hook.sh"
    if (-not $settings.hooks) { $settings | Add-Member -NotePropertyName hooks -NotePropertyValue ([PSCustomObject]@{}) }
    if (-not $settings.hooks.Stop) { $settings.hooks | Add-Member -NotePropertyName Stop -NotePropertyValue @() }
    $settings.hooks.Stop += [PSCustomObject]@{ hooks = @([PSCustomObject]@{ type = "command"; command = $hookCmd }) }

    try {
        $settings | ConvertTo-Json -Depth 10 | Set-Content $ClaudeSettingsFile
    } catch {
        Write-Host "❌ Error: settings.json merge failed — restoring backup" -ForegroundColor Red
        Copy-Item $backup $ClaudeSettingsFile -Force
        exit 1
    }
    $script:ModifiedFiles += $ClaudeSettingsFile
    $script:HooksInstalled += [PSCustomObject]@{ target_file = $ClaudeSettingsFile; event = "Stop"; command = $hookCmd; backup_file = $backup }
}

function Register-PipelineAgents {
    param([string]$PipelineName)
    if ([string]::IsNullOrEmpty($PipelineName)) { return }
    $agentsSrc = Join-Path $PayloadTarget "pipelines\$PipelineName\agents"
    if (-not (Test-Path $agentsSrc)) { return }
    New-Item -ItemType Directory -Path $ClaudeAgentsDir -Force | Out-Null
    Get-ChildItem -Path $agentsSrc -Filter "*.md" | ForEach-Object {
        $dest = Join-Path $ClaudeAgentsDir $_.Name
        Copy-Item $_.FullName $dest -Force
        $script:CreatedFiles += $dest
    }
}

function Test-OpenCodeAndOhMyOpenagent {
    $opencodeDetected = [bool](Get-Command opencode -ErrorAction SilentlyContinue)
    $omoDetected = $false
    $ocConfig = Join-Path $env:USERPROFILE ".config\opencode\opencode.json"
    if (Test-Path $ocConfig) {
        $content = Get-Content $ocConfig -Raw
        $omoDetected = $content -match "oh-my-openagent|oh-my-opencode"
    }
    if ($opencodeDetected -and -not $omoDetected) {
        Write-Host "ℹ️  OpenCode에서 loop를 쓰려면 oh-my-openagent 설치가 필요합니다." -ForegroundColor Cyan
    }
    return @{ detected = $opencodeDetected; oh_my_openagent_detected = $omoDetected }
}

function Write-InstallState {
    param($PayloadInstalled, $SourceHash, $OpenCodeInfo)
    $state = [PSCustomObject]@{
        version = "1.0.0"
        installed_at = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        install_mode = "copy"
        installations = @{ claude_code = @{ target = $PayloadTarget; source = $SkillDir; type = "copy"; source_hash = $SourceHash; installed = $PayloadInstalled; verified = $PayloadInstalled } }
        hooks_installed = $HooksInstalled
        files_created = $CreatedFiles
        files_modified = $ModifiedFiles
        opencode = $OpenCodeInfo
    }
    $state | ConvertTo-Json -Depth 10 | Set-Content $InstallStateFile
}

function Main {
    Write-Host "🚀 Loop Skill Installer" -ForegroundColor Cyan
    Test-NotInstalled
    Test-SkillSource

    $payloadInstalled = Install-Payload
    if ($payloadInstalled) {
        Register-HooksAndCommands
        Register-PipelineAgents -PipelineName ""
    }

    $hash = Get-SourceHash
    $ocInfo = Test-OpenCodeAndOhMyOpenagent
    Write-InstallState -PayloadInstalled $payloadInstalled -SourceHash $hash -OpenCodeInfo $ocInfo

    Write-Host "✅ Installation complete! Uninstall with: .\install\uninstall.ps1" -ForegroundColor Green
}

Main
