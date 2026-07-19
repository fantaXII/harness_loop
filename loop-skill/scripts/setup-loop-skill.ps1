# setup-loop-skill.ps1 — Loop Skill Setup Script (PowerShell)
# 계약은 setup-loop-skill.sh와 동일. state 파일 포맷(YAML frontmatter + 본문)도 동일하게 생성한다.
# 상세 주석은 bash 버전(implementation-spec_v03.md §2, 원본 setup-loop-skill.sh) 참고 —
# 여기서는 문법 차이만 표기.

param(
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$Args
)

$ErrorActionPreference = "Stop"

$StateFile = ".claude\loop-skill.local.md"
$ConfigFile = ".claude\loop-skill.config"
$DefaultMaxIterations = 50

$PromptParts = @()
$MaxIterations = $null
$PipelineName = ""
$PromptFile = ""
$StateDirOverride = ""
$CliMaxIterationsSet = $false
$CliPipelineSet = $false

if (-not $Args) { $Args = @() }

$i = 0
while ($i -lt $Args.Count) {
  switch ($Args[$i]) {
    { $_ -in "-h", "--help" } {
      Write-Host "Loop Skill - Generic self-referential development loop (PowerShell)"
      Write-Host "See setup-loop-skill.sh --help for full option reference (identical options)."
      exit 0
    }
    "--max-iterations" {
      $val = $Args[$i + 1]
      if (-not ($val -match '^\d+$')) {
        Write-Error "❌ Error: --max-iterations must be a non-negative integer, got: $val"
        exit 1
      }
      $MaxIterations = $val; $CliMaxIterationsSet = $true; $i += 2; continue
    }
    "--pipeline" {
      $PipelineName = $Args[$i + 1]; $CliPipelineSet = $true; $i += 2; continue
    }
    "--prompt-file" {
      $val = $Args[$i + 1]
      if (-not (Test-Path -Path $val -PathType Leaf)) {
        Write-Error "❌ Error: --prompt-file requires an existing file path, got: $val"
        exit 1
      }
      $PromptFile = $val; $i += 2; continue
    }
    "--state-dir" {
      $StateDirOverride = $Args[$i + 1]; $i += 2; continue
    }
    default {
      $PromptParts += $Args[$i]; $i += 1; continue
    }
  }
}

# §3.7 config defaults (동일 우선순위: CLI > config 파일 > 내장 기본값)
if (Test-Path $ConfigFile) {
  $configContent = Get-Content $ConfigFile
  $configPipeline = ($configContent | Select-String '^LOOP_SKILL_PIPELINE=' | Select-Object -Last 1)
  $configMaxIter  = ($configContent | Select-String '^LOOP_SKILL_MAX_ITERATIONS=' | Select-Object -Last 1)
  if (-not $CliPipelineSet -and $configPipeline) {
    $PipelineName = ($configPipeline -split '=', 2)[1]
  }
  if (-not $CliMaxIterationsSet -and $configMaxIter) {
    $val = ($configMaxIter -split '=', 2)[1]
    if ($val -match '^\d+$') { $MaxIterations = $val }
    else { Write-Warning "⚠️  ignoring invalid LOOP_SKILL_MAX_ITERATIONS: $val" }
  }
}
if (-not $MaxIterations) { $MaxIterations = $DefaultMaxIterations }

# [CR-4] Active loop guard
if (Test-Path $StateFile) {
  $frontmatter = (Get-Content $StateFile) -join "`n"
  if ($frontmatter -match 'iteration:\s*(\d+)') { $currentIter = $Matches[1] } else { $currentIter = "?" }
  Write-Error "❌ Error: 이미 활성 loop가 있습니다 (iteration $currentIter)"
  Write-Error "   중지하려면 /cancel-loop-skill을 실행하거나 status.json 완료 신호/max-iterations 도달을 기다리세요."
  exit 1
}

# Resolve prompt body: --pipeline > --prompt-file > inline PROMPT (§10, 동일 우선순위)
if ($PipelineName) {
  $pluginRoot = if ($env:CLAUDE_PLUGIN_ROOT) { $env:CLAUDE_PLUGIN_ROOT } else { "." }
  $pipelinePromptFile = Join-Path $pluginRoot "pipelines\$PipelineName\prompt.md"
  if (-not (Test-Path $pipelinePromptFile)) {
    Write-Error "❌ Error: pipeline '$PipelineName' not found (expected $pipelinePromptFile)"
    exit 1
  }
  $Prompt = Get-Content $pipelinePromptFile -Raw
} elseif ($PromptFile) {
  $Prompt = Get-Content $PromptFile -Raw
} else {
  $Prompt = $PromptParts -join " "
  if (-not $Prompt) {
    Write-Error "❌ Error: No prompt provided and no --pipeline/--prompt-file given"
    exit 1
  }
}

# state_dir 준비
$RunId = "loop-" + (Get-Date -AsUTC -Format "yyyyMMdd-HHmmss")
$StateDir = if ($StateDirOverride) { $StateDirOverride } else { ".claude\loop-skill\$RunId" }
New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
New-Item -ItemType Directory -Force -Path ".claude" | Out-Null

$PipelineYaml = if ($PipelineName) { "`"$PipelineName`"" }
  elseif ($PromptFile) { "`"prompt-file:$(Split-Path (Split-Path $PromptFile -Parent) -Leaf)`"" }
  else { "null" }

$StartedAt = (Get-Date -AsUTC -Format "yyyy-MM-ddTHH:mm:ssZ")
$SessionId = $env:CLAUDE_CODE_SESSION_ID

@"
---
active: true
iteration: 1
session_id: $SessionId
max_iterations: $MaxIterations
started_at: "$StartedAt"
state_dir: "$StateDir"
pipeline: $PipelineYaml
---

$Prompt
"@ | Set-Content -Path $StateFile -Encoding utf8NoBOM

Write-Host "🔄 Loop skill activated in this session!"
Write-Host ""
Write-Host "Iteration: 1"
Write-Host "Max iterations: $(if ($MaxIterations -gt 0) { $MaxIterations } else { 'unlimited' })"
Write-Host "State dir: $StateDir"
Write-Host ""
Write-Host "To end this loop, write EXACTLY this JSON to $StateDir\status.json using the Write tool:"
Write-Host '  {"status": "complete"}'
Write-Host "If the task genuinely cannot be completed, write instead:"
Write-Host '  {"status": "failed", "reason": "<short reason>"}'
Write-Host "Only write this when the condition is truly met — do not write it prematurely to escape the loop."
