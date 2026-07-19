# apply-skill.ps1 — apply-skill.sh와 동일 로직 (PowerShell).
# implementation-spec_v03.md §4의 bash 버전(apply-skill.sh)을 1:1로 옮긴 것.
# 함수 대응:
#   extract_pipeline_body -> Get-PipelineBody
#   has_completion_contract -> Test-CompletionContract
#   completion_contract_footer -> Get-CompletionContractFooter
#   frontmatter_field -> Get-FrontmatterField
#   generate_launcher -> New-Launcher (shell: powershell 고정, .ps1 엔진 참조)
#   build_loop_skill -> Build-LoopSkill
#   record_apply_state -> Save-ApplyState
#   do_apply/do_upgrade/do_upgrade_all/do_status -> Invoke-Apply/Invoke-Upgrade/Invoke-UpgradeAll/Invoke-Status
# pwsh가 없는 환경에서 작성되어 실행 검증은 못 했음 — bash 버전과 나란히 두고 리뷰 필요.

param(
  [string]$Origin,
  [switch]$KeepModelInvocation,
  [switch]$Force,
  [switch]$DryRun,
  [string]$Upgrade,
  [switch]$UpgradeAll,
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$Rest
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$EngineSh  = Join-Path $ScriptDir "setup-loop-skill.sh"
$EnginePs1 = Join-Path $ScriptDir "setup-loop-skill.ps1"
$PluginJson = Join-Path $ScriptDir "..\.claude-plugin\plugin.json"

$SkillsDir = Join-Path $HOME ".claude\skills"
$AgentsDir = Join-Path $HOME ".claude\agents"
$LoopAppliedDir = Join-Path $HOME ".claude\loop-applied"
$BackupsDir = Join-Path $LoopAppliedDir "backups"
$ApplyStateFile = Join-Path $LoopAppliedDir "apply-state.json"
$TemplateVersion = "1"

# --status/--list는 param()에 없는 스위치이므로 $Rest로 들어온다.
$Mode = "apply"
$StatusName = ""
if ($Rest -contains "--status") {
  $Mode = "status"
  $idx = [array]::IndexOf($Rest, "--status")
  if ($idx -ge 0 -and $idx + 1 -lt $Rest.Count -and -not ($Rest[$idx + 1] -like "--*")) {
    $StatusName = $Rest[$idx + 1]
  }
} elseif ($Rest -contains "--list") {
  $Mode = "status"
}
if ($Upgrade) { $Mode = "upgrade" }
if ($UpgradeAll) { $Mode = "upgrade-all" }

if (-not (Get-Command jq -ErrorAction SilentlyContinue)) {
  Write-Error "❌ Error: jq가 필요합니다."
}
if (-not (Test-Path $EngineSh) -or -not (Test-Path $EnginePs1)) {
  Write-Error "❌ Error: loop-skill 코어가 불완전합니다 (setup-loop-skill.sh/.ps1 필요)."
}

$EngineVersion = (Get-Content $PluginJson | ConvertFrom-Json).version
New-Item -ItemType Directory -Force -Path $SkillsDir, $BackupsDir | Out-Null
if (-not (Test-Path $ApplyStateFile)) { "{}" | Set-Content $ApplyStateFile }

# --- 공용 함수 -------------------------------------------------------------

function Get-PipelineBody {
  # frontmatter의 첫 두 `---` 구분자만 제거하고 본문(뒤쪽 --- 포함)은 그대로 보존한다.
  # (apply-skill.sh의 awk 로직과 동일한 상태기계 — sandbox에서 검증된 규칙을 그대로 이식)
  param([string]$SkillMd)
  $lines = Get-Content $SkillMd
  $n = 0
  $out = @()
  foreach ($line in $lines) {
    if ($line -eq "---" -and $n -lt 2) { $n++; continue }
    if ($n -ge 2) { $out += $line }
  }
  return ($out -join "`n")
}

function Test-CompletionContract {
  param([string]$PipelineMd)
  $content = Get-Content $PipelineMd -Raw
  return ($content -match '(?i)(status\.json|완료.*신호|completion.*signal)')
}

function Get-CompletionContractFooter {
  return @"

---
## Loop 완료 신호 (loop 코어가 자동 주입)
작업이 진짜로 완전히 끝났다면, Write 툴로 ``<state_dir>/status.json``에 정확히 다음을 기록해
loop을 종료하세요:
    {"status": "complete"}
escape 용도로 앞당겨 쓰지 마세요. 진짜 불가능하면 대신:
    {"status": "failed", "reason": "<짧고 정직한 사유>"}
"@
}

function Get-FrontmatterField {
  param([string]$SkillMd, [string]$Key, [string]$DefaultVal = "")
  $line = Get-Content $SkillMd | Where-Object { $_ -match "^${Key}:" } | Select-Object -First 1
  if (-not $line) { return $DefaultVal }
  $val = ($line -replace "^${Key}:\s*", "") -replace '^"(.*)"$', '$1'
  if ([string]::IsNullOrWhiteSpace($val)) { return $DefaultVal }
  return $val
}

function New-Launcher {
  param([string]$TargetDir, [string]$LoopName, [string]$Description, [string]$MiValue)
  @"
---
name: $LoopName
description: "$Description (ralph-loop 모드: 완료까지 self-referential 반복)"
disable-model-invocation: $MiValue
allowed-tools: ["Bash(`${CLAUDE_SKILL_DIR}/setup-loop-skill.ps1:*)"]
shell: powershell
---

# $LoopName (loop-wrapped)

``````!
"`${CLAUDE_SKILL_DIR}/setup-loop-skill.ps1" --prompt-file "`${CLAUDE_SKILL_DIR}/pipeline.md" `$ARGUMENTS
``````

이 skill은 위 pipeline을 self-referential loop으로 실행합니다. 매 iteration에서 같은
``pipeline.md``가 재feed되며, 직전 결과물은 파일(및 보고된 ``state_dir``)과 git 히스토리로 이어집니다.

CRITICAL: loop은 pipeline이 ``<state_dir>/status.json``에 ``{"status":"complete"}``를 Write 툴로
기록하거나 ``--max-iterations``에 도달할 때만 멈춥니다. 완전히 끝났을 때만 complete를 쓰세요.
진짜 불가능하면 ``{"status":"failed","reason":"<사유>"}``를 쓰세요.
"@ | Set-Content -Path (Join-Path $TargetDir "SKILL.md") -Encoding utf8NoBOM
}

function Build-LoopSkill {
  # BackupDir(pristine)에서 TargetDir(<name>-loop)를 (재)생성한다. apply 최초 실행과
  # upgrade 양쪽에서 공유 — pipeline 본문은 항상 여기서 pristine으로부터 재생성되므로
  # 완료계약 footer가 중첩되지 않는다 (plan §5.2).
  param([string]$Name, [string]$BackupDir, [string]$TargetDir, [string]$MiPolicy)

  $originSkillMd = Join-Path $BackupDir "SKILL.md"
  $body = Get-PipelineBody -SkillMd $originSkillMd
  if ([string]::IsNullOrWhiteSpace($body)) {
    Write-Error "❌ Error: '$Name'의 SKILL.md 본문이 비어 있습니다 (frontmatter-only skill은 wrap할 수 없습니다)."
  }
  $pipelinePath = Join-Path $TargetDir "pipeline.md"
  $body | Set-Content -Path $pipelinePath -Encoding utf8NoBOM

  $injected = $false
  if (-not (Test-CompletionContract -PipelineMd $pipelinePath)) {
    Add-Content -Path $pipelinePath -Value (Get-CompletionContractFooter)
    $injected = $true
  } else {
    Write-Host "ℹ️  완료계약 지시가 이미 있어 footer를 주입하지 않았습니다."
  }

  Copy-Item $EngineSh (Join-Path $TargetDir "setup-loop-skill.sh") -Force
  Copy-Item $EnginePs1 (Join-Path $TargetDir "setup-loop-skill.ps1") -Force

  $description = Get-FrontmatterField -SkillMd $originSkillMd -Key "description" -DefaultVal $Name
  if ($MiPolicy -eq "preserved") {
    $miValue = Get-FrontmatterField -SkillMd $originSkillMd -Key "disable-model-invocation" -DefaultVal "false"
  } else {
    $miValue = "true"
  }
  # apply-skill.ps1(PowerShell)로 실행 중이므로 powershell launcher를 생성한다 —
  # apply-skill.sh(bash)가 만드는 launcher와 이 지점에서만 갈린다(§7.1.2).
  New-Launcher -TargetDir $TargetDir -LoopName "$Name-loop" -Description $description -MiValue $miValue

  # 부가 파일 복사 (SKILL.md는 이미 pipeline.md로 소비했으므로 제외)
  Get-ChildItem $BackupDir | Where-Object { $_.Name -ne "SKILL.md" } | ForEach-Object {
    if ($_.Name -eq "agents" -and $_.PSIsContainer) {
      Copy-Item $_.FullName (Join-Path $TargetDir "agents") -Recurse -Force
      New-Item -ItemType Directory -Force -Path $AgentsDir | Out-Null
      Get-ChildItem $_.FullName -Filter "*.md" | ForEach-Object {
        Copy-Item $_.FullName (Join-Path $AgentsDir $_.Name) -Force
      }
    } else {
      Copy-Item $_.FullName (Join-Path $TargetDir $_.Name) -Recurse -Force
    }
  }

  $checksum = "sha256:" + (Get-FileHash $originSkillMd -Algorithm SHA256).Hash.ToLower()
  $originalMi = Get-FrontmatterField -SkillMd $originSkillMd -Key "disable-model-invocation" -DefaultVal "false"

  [ordered]@{
    origin_name = $Name
    origin = "wrapped"
    origin_path = (Join-Path $SkillsDir $Name)
    backup_path = $BackupDir
    origin_checksum = $checksum
    engine_version = $EngineVersion
    template_version = $TemplateVersion
    original_model_invocation = $originalMi
    model_invocation_policy = $MiPolicy
    contract_injected = $injected
    applied_at = (Get-Date -AsUTC -Format "yyyy-MM-ddTHH:mm:ssZ")
  } | ConvertTo-Json | Set-Content (Join-Path $TargetDir ".loop-meta.json")
}

function Save-ApplyState {
  param([string]$Name, [string]$BackupDir, [string]$TargetDir)
  $state = Get-Content $ApplyStateFile -Raw | ConvertFrom-Json -AsHashtable
  if (-not $state) { $state = @{} }
  $state[$Name] = @{ backup_path = $BackupDir; target_path = $TargetDir }
  $state | ConvertTo-Json | Set-Content $ApplyStateFile
}

# --- Invoke-Apply (최초 wrap) -----------------------------------------------
function Invoke-Apply {
  param([string]$OriginArg)

  if ($OriginArg -match '[\\/]') { $originDir = $OriginArg } else { $originDir = Join-Path $SkillsDir $OriginArg }
  $name = Split-Path $originDir -Leaf

  if ($name -like "*-loop") {
    Write-Error "❌ Error: 이미 loop skill입니다: $name"
  }

  $loopName = "$name-loop"
  $targetDir = Join-Path $SkillsDir $loopName

  # 이미 wrap된 skill에 대한 재실행(재적용/업그레이드)인지 먼저 판별한다. wrap 후에는
  # originDir가 backup으로 이동해 사라지는 것이 정상이므로, 이 분기는 반드시 아래의
  # "originDir가 유효한 skill이어야 한다" 검증보다 먼저 와야 한다(bash 버전과 동일 순서 —
  # apply-skill.sh 작성 중 sandbox에서 실제로 재현된 순서 버그를 여기서도 피한다).
  if (Test-Path $targetDir) {
    if (Test-Path (Join-Path $targetDir ".loop-meta.json")) {
      Write-Host "ℹ️  이미 wrap되어 있습니다. --upgrade로 진행합니다: $name"
      Invoke-Upgrade -NameOrLoop $name
      return
    } else {
      Write-Error "❌ Error: 동일 skill 존재: $loopName (loop wrap이 아님 — 이름 변경 또는 제거 후 재시도)"
    }
  }

  if (-not (Test-Path $originDir) -or -not (Test-Path (Join-Path $originDir "SKILL.md"))) {
    Write-Error "❌ Error: '$OriginArg'은(는) 유효한 skill 디렉토리가 아닙니다 (SKILL.md 없음): $originDir"
  }

  $backupDir = Join-Path $BackupsDir $name
  if (Test-Path $backupDir) {
    Write-Error "❌ Error: 이전 apply의 백업이 이미 존재합니다: $backupDir (수동 확인 필요, 자동 덮어쓰기 안 함)"
  }

  if ($DryRun) {
    Write-Host "[dry-run] 다음이 수행됩니다:"
    Write-Host "  이동: $originDir -> $backupDir"
    Write-Host "  생성: $targetDir\ (SKILL.md, setup-loop-skill.sh, .ps1, pipeline.md, .loop-meta.json)"
    Write-Host "  결과: /$name 사라짐, /$loopName 등장"
    return
  }

  $miPolicy = "forced-disabled"
  if ($KeepModelInvocation) { $miPolicy = "preserved" }

  # --- 트랜잭션: 실패 시 원본 복원 ---
  try {
    Move-Item $originDir $backupDir
    New-Item -ItemType Directory -Force -Path $targetDir | Out-Null
    Build-LoopSkill -Name $name -BackupDir $backupDir -TargetDir $targetDir -MiPolicy $miPolicy
    Save-ApplyState -Name $name -BackupDir $backupDir -TargetDir $targetDir
  } catch {
    Write-Host "⚠️  apply 실패 — 롤백 중..."
    if (Test-Path $targetDir) { Remove-Item $targetDir -Recurse -Force }
    if ((Test-Path $backupDir) -and -not (Test-Path $originDir)) { Move-Item $backupDir $originDir }
    throw
  }

  Write-Host "✅ 적용됨: /$loopName (engine v$EngineVersion, 원본은 $backupDir 에 보관)"
}

# --- Invoke-Upgrade (재적용) -------------------------------------------------
function Invoke-Upgrade {
  param([string]$NameOrLoop)

  $name = $NameOrLoop
  if ($NameOrLoop -like "*-loop") { $name = $NameOrLoop -replace '-loop$', '' }
  $loopName = "$name-loop"
  $targetDir = Join-Path $SkillsDir $loopName
  $metaFile = Join-Path $targetDir ".loop-meta.json"

  if (-not (Test-Path $metaFile)) {
    Write-Error "❌ Error: '$loopName'은(는) loop wrap이 아닙니다 (.loop-meta.json 없음)."
  }

  $meta = Get-Content $metaFile | ConvertFrom-Json
  $backupDir = $meta.backup_path
  if (-not (Test-Path $backupDir)) {
    Write-Error "❌ Error: pristine 백업을 찾을 수 없습니다: $backupDir"
  }

  # drift 감지 (plan §9)
  $storedChecksum = $meta.origin_checksum
  $currentChecksum = "sha256:" + (Get-FileHash (Join-Path $backupDir "SKILL.md") -Algorithm SHA256).Hash.ToLower()
  if ($storedChecksum -ne $currentChecksum -and -not $Force) {
    Write-Host "⚠️  drift 감지: 백업의 SKILL.md가 최초 apply 이후 변경된 것으로 보입니다."
    Write-Host "   stored=$storedChecksum current=$currentChecksum"
    Write-Error "   계속하려면 --force를 붙이세요."
  }

  if ($DryRun) {
    Write-Host "[dry-run] $loopName`: 번들 엔진 재복사 + launcher/pipeline.md 재생성 (engine -> v$EngineVersion)"
    return
  }

  $miPolicy = $meta.model_invocation_policy
  if ($KeepModelInvocation) { $miPolicy = "preserved" }

  # pipeline.md/SKILL.md/엔진을 통째로 재생성 (pristine에서, 절대 기존 pipeline.md에서 재추출 안 함)
  Remove-Item -Force -ErrorAction SilentlyContinue `
    (Join-Path $targetDir "pipeline.md"), (Join-Path $targetDir "SKILL.md"), `
    (Join-Path $targetDir "setup-loop-skill.sh"), (Join-Path $targetDir "setup-loop-skill.ps1")
  Build-LoopSkill -Name $name -BackupDir $backupDir -TargetDir $targetDir -MiPolicy $miPolicy

  Write-Host "✅ 업그레이드됨: /$loopName (engine v$EngineVersion)"
}

function Invoke-UpgradeAll {
  $any = $false
  Get-ChildItem $SkillsDir -Filter "*-loop" -Directory -ErrorAction SilentlyContinue | ForEach-Object {
    $metaFile = Join-Path $_.FullName ".loop-meta.json"
    if (-not (Test-Path $metaFile)) { return }
    $any = $true
    $name = $_.Name -replace '-loop$', ''
    Write-Host "--- $name ---"
    try { Invoke-Upgrade -NameOrLoop $name }
    catch { Write-Host "⚠️  $name 업그레이드 실패, 계속 진행" }
  }
  if (-not $any) { Write-Host "wrap된 skill이 없습니다." }
}

function Invoke-Status {
  "{0,-28} {1,-9} {2,-9} {3,-12} {4}" -f "NAME", "ORIGIN", "ENGINE", "APPLIED_AT", "" | Write-Host
  Get-ChildItem $SkillsDir -Filter "*-loop" -Directory -ErrorAction SilentlyContinue | ForEach-Object {
    $metaFile = Join-Path $_.FullName ".loop-meta.json"
    if (-not (Test-Path $metaFile)) { return }
    $meta = Get-Content $metaFile | ConvertFrom-Json
    $mark = ""
    if ($meta.engine_version -ne $EngineVersion) { $mark = " (뒤처짐, 최신 v$EngineVersion)" }
    "{0,-28} {1,-9} {2,-9} {3,-12}{4}" -f $_.Name, $meta.origin, $meta.engine_version, $meta.applied_at, $mark | Write-Host
  }
}

# --- 디스패치 ----------------------------------------------------------------
switch ($Mode) {
  "apply" {
    if (-not $Origin) { Write-Error "❌ Error: origin skill 이름 또는 경로가 필요합니다." }
    Invoke-Apply -OriginArg $Origin
  }
  "upgrade" { Invoke-Upgrade -NameOrLoop $Upgrade }
  "upgrade-all" { Invoke-UpgradeAll }
  "status" { Invoke-Status }
}
