# unapply-skill.ps1 — unapply-skill.sh와 동일 로직 (PowerShell)
# implementation-spec_v03.md §6, pwsh 없는 환경에서 작성되어 실행 검증은 못 했음.
param(
  [Parameter(Mandatory=$true)][string]$Name,
  [switch]$DryRun
)
$ErrorActionPreference = "Stop"
$SkillsDir = Join-Path $HOME ".claude\skills"
$AgentsDir = Join-Path $HOME ".claude\agents"
$ApplyStateFile = Join-Path $HOME ".claude\loop-applied\apply-state.json"

$BaseName = $Name -replace '-loop$', ''
$LoopName = "$BaseName-loop"
$TargetDir = Join-Path $SkillsDir $LoopName
$OriginTarget = Join-Path $SkillsDir $BaseName
$MetaFile = Join-Path $TargetDir ".loop-meta.json"

if (-not (Test-Path $MetaFile)) {
  Write-Error "❌ '$LoopName'은(는) loop wrap이 아니거나 존재하지 않습니다."
}
$Meta = Get-Content $MetaFile | ConvertFrom-Json
$BackupDir = $Meta.backup_path
if (-not (Test-Path $BackupDir)) {
  Write-Error "❌ pristine 백업을 찾을 수 없습니다: $BackupDir"
}
if (Test-Path $OriginTarget) {
  Write-Error "❌ 복원 대상이 이미 존재합니다: $OriginTarget — 수동 확인 필요."
}

if ($DryRun) {
  Write-Host "[dry-run] 삭제: $TargetDir / 복원: $BackupDir -> $OriginTarget"
  exit 0
}

$AgentsSrc = Join-Path $BackupDir "agents"
if (Test-Path $AgentsSrc) {
  Get-ChildItem $AgentsSrc -Filter "*.md" | ForEach-Object {
    Remove-Item (Join-Path $AgentsDir $_.Name) -ErrorAction SilentlyContinue
  }
}

Remove-Item $TargetDir -Recurse -Force
Move-Item $BackupDir $OriginTarget

if (Test-Path $ApplyStateFile) {
  $state = Get-Content $ApplyStateFile -Raw | ConvertFrom-Json -AsHashtable
  if ($state) {
    $state.Remove($BaseName)
    $state | ConvertTo-Json | Set-Content $ApplyStateFile
  }
}

Write-Host "✅ 원복됨: /$BaseName ($LoopName 및 백업 제거)"
