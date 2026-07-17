# L1 Log Analysis Skill 구현 스펙

## 문서 버전

- **버전**: 1.1.0
- **상태**: Draft (적대적 검토 반영, `harness_loop_plan.md`의 CR-1~CR-6과 동기화)
- **작성일**: 2026-07-17
- **마지막 수정**: 2026-07-19

## 개요

`/l1-log-analysis` skill은 `/ralph-loop`의 self-referential loop 패턴을 기반으로 L1(메모리/캐시/스토리지) 시스템의 로그 분석 작업을 지속적으로 반복 수행합니다.

> **선행 조건**: 이 스펙은 `harness_loop_plan.md`의 "적대적 검토 결과 (Critical Review)" 섹션(CR-1~CR-6)을 전제로 한다. 특히 CR-1(설치 = payload copy + 별도 hook/command 등록, `~/.claude/skills/`에 복사하는 것만으로는 동작하지 않음)과 CR-2(Stop hook이 iteration 필드만 갱신하고 프롬프트 본문은 그대로 재사용하므로 Phase 4는 Stop hook 확장과 함께 구현해야 함)는 이 문서의 Phase 2/5/6/7과 아키텍처 절을 재정의하는 근거다. 아래 각 절의 `[CR-n]` 표기는 plan 문서의 해당 항목과 대응한다.

## 핵심 요구사항

### 1. Platform 호환성
- **Claude Code** (Claude CLI/Desktop) 지원
- **OpenCode** 지원
- 두 플랫폼 간 호환되는 설치/삭제 프로세스

### 2. Installation/Uninstallation
- **Installer**: `install.sh` (WSL/Linux/Mac), `install.ps1` (Windows PowerShell)
- **Uninstaller**: `uninstall.sh` (WSL/Linux/Mac), `uninstall.ps1` (Windows PowerShell)
- **Installer ↔ Uninstaller 짝 맞춤 원칙**
  - Installer가 설치한 것만 Uninstaller가 제거
  - Uninstaller는 Installer가 설치하지 않은 것을 제거하지 않음
  - State tracking을 통한 설치 기록 관리
- **설치 방식**: Copy 사용 (symlink 미사용)

### 3. Ralph Loop 기본 동작
- 세션이 종료되려 할 때 자동으로 차단하고 동일 prompt 다시 feed
- 무한 loop 실행 (max-iterations 또는 completion-promise로 종료)
- State 파일을 통한 iteration 추적
- `[CR-2]` **주의**: 원본 ralph-loop의 "동일 prompt 다시 feed"는 상태 파일 본문을 그대로 재사용한다는 뜻이다. L1은 요구사항 4(분석 결과 지속적 업데이트)를 위해 본문을 매 iteration 재생성해야 하므로, 이 절은 "iteration 카운트만 상속, 본문 재생성은 L1이 새로 구현"으로 읽어야 한다

### 4. L1 Log Analysis 특화 기능
- 로그 파일 자동 감지 및 분석
- 패턴 기반 이슈 식별
- 반복 분석을 통한 이슈 정교화
- 분석 결과 지속적 업데이트

### 5. Pipeline 통합
- opencode skill 시스템과 호환
- Claude Code skill 시스템과 호환
- 다른 skill들과 연동 가능한 pipeline 형태

## 디렉토리 구조

```
l1-log-analysis/
├── .claude-plugin/
│   └── plugin.json                    # Skill 메타데이터
├── commands/
│   ├── l1-log-analysis.md             # 메인 command
│   └── cancel-l1-log-analysis.md      # 취소 command
├── scripts/
│   └── setup-l1-log-analysis.sh       # State 파일 생성 스크립트
├── hooks/
│   ├── hooks.json                     # Stop hook 등록
│   └── stop-hook.sh                   # Exit 차단 및 prompt 재feed
├── analyzers/
│   └── l1-log-analyzer.sh             # 로그 분석 스크립트
├── templates/
│   ├── analysis-report.md             # 분석 결과 템플릿
│   └── prompt-template.md             # 사용자 prompt 템플릿
└── install/
    ├── install.sh                     # WSL/Linux/Mac installer
    ├── install.ps1                    # Windows PowerShell installer
    ├── uninstall.sh                   # WSL/Linux/Mac uninstaller
    ├── uninstall.ps1                  # Windows PowerShell uninstaller
    └── install-state.json             # 설치 상태 기록 (제거용)
```

`[CR-1]` 위 트리는 **source repo 내부 구조**(payload)일 뿐이며, 이것이 그대로 `~/.claude/skills/l1-log-analysis/`에 복사된다고 해서 `commands/*.md`와 `hooks/hooks.json`이 자동으로 동작하지는 않는다. 설치는 다음 세 가지 서로 다른 대상에 나누어 이루어진다 — 이 구분이 이 스펙의 Phase 2/5/6/7 전체를 관통한다:

| # | 산출물 | 설치 대상 | 등록 필요 여부 |
|---|--------|-----------|----------------|
| 1 | payload (scripts/analyzers/templates/hook 본체) | `~/.claude/skills/l1-log-analysis/`, `.omc/skills/l1-log-analysis/` | Copy만으로 충분 |
| 2 | 슬래시 커맨드 | `~/.claude/commands/l1-log-analysis.md` 등 | Copy + `${CLAUDE_PLUGIN_ROOT}` 절대경로 치환 필요 |
| 3 | Stop Hook | `~/.claude/settings.json`의 `hooks.Stop` | JSON 병합 필요 (단순 copy 불가) |

## 구현 단계

### Phase -1: 아키텍처 검증 스파이크 `[CR-1][CR-3]`
**목표**: Phase 0 이전에 이 스펙의 두 핵심 가정을 실제로 검증한다.

**작업 항목**:
- [ ] `~/.claude/settings.json`의 `hooks.Stop` 배열에 수동으로 command hook을 추가하고, 세션 종료 시 실제로 호출되어 `decision: block`을 반환하면 종료가 막히는지 최소 재현
- [ ] `~/.claude/commands/`에 plugin 없이 `.md` 파일을 두고 슬래시 커맨드로 인식되는지 확인
- [ ] OpenCode의 Stop hook 동등 기능(세션 종료 가로채기 + 프롬프트 재주입) 존재 여부를 OpenCode 소스/문서에서 확인

**검증**:
- 세 항목 모두 성공해야 Phase 0으로 진행. 실패 시 이 스펙의 Installation Architecture와 Phase 5/6/7을 재작성해야 함

### Phase 0: Project Structure 설정
**목표**: 기본 디렉토리 구조 생성

**작업 항목**:
- [ ] `l1-log-analysis/` 디렉토리 생성
- [ ] `.claude-plugin/` 디렉토리 생성
- [ ] `commands/` 디렉토리 생성
- [ ] `scripts/` 디렉토리 생성
- [ ] `hooks/` 디렉토리 생성
- [ ] `analyzers/` 디렉토리 생성
- [ ] `templates/` 디렉토리 생성
- [ ] `install/` 디렉토리 생성

**검증**:
- 모든 디렉토리가 존재하는지 확인
- `ls -la l1-log-analysis/` 실행

### Phase 1: ralph-loop 베이스 복사
**목표**: ralph-loop 구조 복사 및 이름 변경

**작업 항목**:
- [ ] ralph-loop plugin.json 복사 및 수정
- [ ] ralph-loop commands 복사 및 이름 변경
- [ ] ralph-loop scripts 복사 및 수정
- [ ] ralph-loop hooks 복사 및 수정
- [ ] 모든 "ralph" → "l1-log-analysis"로 변경

**검증**:
- `grep -r "ralph" l1-log-analysis/` 실행하여 미변경 부분 확인
- Skill 파일 구조 검증

### Phase 2: State 파일 확장
**목표**: l1-log-analysis 전용 필드 추가

**작업 항목**:
- [ ] ralph-loop.local.md → l1-log-analysis.local.md
- [ ] 추가 필드 정의:
  - `log_sources[]`: 분석 대상 로그 파일 목록
  - `analysis_config`: 분석 설정 (pattern, 시간 범위 등)
  - `findings[]`: 발견된 이슈 목록
  - `analysis_iterations`: 분석 iteration 카운트

**State 파일 스키마**:
```yaml
---
active: true
iteration: 1
session_id: ses_xxx
max_iterations: 0
completion_promise: "All L1 log issues resolved or no new issues for 3 iterations"
started_at: "2026-07-17T10:00:00Z"
log_sources:
  - "/var/log/kernel.log"
  - "/tmp/l1-trace.log"
analysis_config:
  patterns: ["memory leak", "cache miss", "IO error", "OOM killer"]
  time_range: "1h"
  severity_filter: "warning"
findings: []
analysis_iterations: 0
---

[Prompt text]
```

**추가 작업 항목** (적대적 검토 반영):
- [ ] `[CR-6]` `MAX_ITERATIONS` 기본값을 원본 ralph-loop의 `0`(무제한)에서 `50`으로 오버라이드
- [ ] `[CR-4]` setup 스크립트 시작부에 상태 파일 존재 여부 가드 추가:
  ```bash
  STATE_FILE=".claude/l1-log-analysis.local.md"
  if [[ -f "$STATE_FILE" ]]; then
    echo "❌ Error: 이미 활성 loop가 있습니다 (iteration $(grep '^iteration:' "$STATE_FILE" | sed 's/iteration: *//'))" >&2
    echo "   중지하려면 세션에서 completion promise를 출력하거나 max-iterations 도달을 기다리세요." >&2
    exit 1
  fi
  ```
  이는 원본 `setup-ralph-loop.sh:140`이 무조건 `cat >`로 상태 파일을 덮어쓰는 것을 막아, 다른 세션의 진행 중인 loop를 보존한다 (CR-4/CR-5의 근본 해결책)

**검증**:
- State 파일 생성 테스트
- YAML frontmatter 파싱 테스트
- `[CR-4]` 활성 loop 존재 시 두 번째 setup 호출이 거부되고 첫 번째 상태 파일이 변경되지 않는지 테스트

### Phase 3: 로그 분석 기능
**목표**: L1 로그 분석 스크립트 구현

**작업 항목**:
- [ ] `l1-log-analyzer.sh` 구현
  - 로그 파일 자동 감지 (/var/log/, /tmp/, 지정 경로)
  - L1 관련 패턴 매칭 (memory leak, cache miss, IO error 등)
  - 이슈 식별 및 우선순위 부여
- [ ] 분석 결과 report 생성

**검증**:
- 테스트 로그 파일로 패턴 매칭 테스트
- 접근 불가한 로그 파일 처리 테스트

### Phase 4: Prompt 자동 생성
**목표**: 이전 분석 결과 기반으로 다음 prompt 생성

**[CR-2] 전제 조건**: 원본 `stop-hook.sh:150,169-170`은 iteration 필드만 갱신하고, 상태 파일 본문(두 번째 `---` 이후)은 `awk`로 그대로 읽어 재사용한다. 이 Phase는 Phase 5에서 **본문 자체를 재생성하는 로직**을 stop-hook에 추가하는 것과 분리될 수 없다 — Phase 4의 "prompt 생성 로직"은 순수 함수(findings → 다음 prompt 텍스트)로 구현하고, 그 호출은 Phase 5의 stop-hook 확장 지점에서 이루어진다.

**작업 항목**:
- [ ] 이전 분석 결과 기반으로 다음 prompt 생성 (findings 목록 → prompt 텍스트로 변환하는 순수 함수/스크립트로 구현, 예: `generate-next-prompt.sh`)
- [ ] 발견된 이슈를 context에 포함
- [ ] 중복 이슈 제거 및 신규 이슈 식별
- [ ] `[CR-2]` 생성된 prompt 텍스트를 Phase 5의 stop-hook이 호출할 수 있는 형태(stdout 또는 파일)로 노출

**검증**:
- Iteration 간 prompt continuity 테스트
- Context preservation 테스트
- `[CR-2]` **회귀 테스트**: 서로 다른 findings를 주입한 두 번의 iteration에서 생성된 prompt 본문이 byte-for-byte 다른지 확인 (같으면 CR-2 미해결)

### Phase 5: Stop Hook 확장
**목표**: ralph-loop stop-hook에 로그 분석 추가 + `[CR-1]` 실제 hook 등록 + `[CR-2]` 본문 재생성

**작업 항목**:
- [ ] 기본 ralph-loop stop-hook 유지 (session_id 체크, numeric validation, jq graceful degradation 재사용)
- [ ] `[CR-2]` **(필수)** iteration 갱신과 **같은 원자적 쓰기**(temp file + mv) 안에서 상태 파일 본문을 Phase 4의 prompt 생성 로직 결과로 교체:
  ```bash
  NEXT_ITERATION=$((ITERATION + 1))
  NEXT_PROMPT=$("$SKILL_DIR/scripts/generate-next-prompt.sh" "$STATE_FILE")   # Phase 4 산출물 호출

  # frontmatter만 추출 (첫 번째 ---부터 두 번째 ---까지, iteration 필드는 갱신)
  FRONTMATTER_BLOCK=$(awk '/^---$/{i++; print; next} i==1{print}' "$STATE_FILE" \
    | sed "s/^iteration: .*/iteration: $NEXT_ITERATION/")

  TEMP_FILE="${STATE_FILE}.tmp.$$"
  {
    echo "$FRONTMATTER_BLOCK"
    echo "---"
    echo ""
    echo "$NEXT_PROMPT"
  } > "$TEMP_FILE"
  mv "$TEMP_FILE" "$STATE_FILE"
  ```
  (의사코드 수준 스케치이며 구현 시 원본 `awk`/`sed` 파이프라인을 정밀 검증해야 하지만, 핵심 요구사항은 고정됨: 본문을 findings 기반으로 **실제로 바꾼다** — 원본처럼 그대로 재사용하면 CR-2가 재발한다)
- [ ] `[CR-1]` **(필수, Copy만으로는 불충분)** 이 stop-hook 스크립트 자체는 payload 위치(`~/.claude/skills/l1-log-analysis/hooks/stop-hook.sh`)에 두되, **Claude Code가 이를 실행하려면 `~/.claude/settings.json`의 `hooks.Stop`에 별도로 등록**되어 있어야 한다. 등록은 Phase 7의 installer가 수행하며, Phase 5는 "등록되면 정상 동작하는 스크립트"를 만드는 것까지가 책임 범위다
- [ ] 추가 종료 조건:
  - 모든 이슈 해결 확인
  - 새로운 이슈 N iteration 미발견
  - 사용자 명시적 중지

**Stop Hook Flow**:
```
[Session 종료 시도]
    ↓
[settings.json에 등록된 Stop Hook 커맨드 실행] ← [CR-1] 등록 없으면 이 단계 자체가 발생하지 않음
    ↓
[State 파일 존재 확인]
    ↓
[Session isolation 체크]
    ↓
[Iteration 증가 및 Max 체크]
    ↓
[로그 분석 실행] ← 새로 추가
    ↓
[이슈 발견 시 State 업데이트] ← 새로 추가
    ↓
[Completion Promise 체크]
    ↓
[미완료 시 다음 Prompt "재생성" (본문까지 갱신)] ← [CR-2] 단순 재사용이 아니라 실제 재생성
    ↓
[JSON 반환: block decision + prompt 재feed]
```

**검증**:
- Session isolation 테스트
- State corruption recovery 테스트
- Transcript parsing 테스트
- `[CR-1]` Stop hook이 `settings.json`에 등록되지 않은 상태에서는 세션 종료를 전혀 막지 못함을 확인하는 네거티브 테스트 (등록 전/후 대조)
- `[CR-2]` 연속 2회 iteration에서 상태 파일 본문이 실제로 달라지는지 확인 (Phase 4 회귀 테스트와 동일 기준)

### Phase 6: Command 정의
**목표**: 메인 command 및 옵션 정의

**작업 항목**:
- [ ] `/l1-log-analysis <log-paths> [options]` 정의
  - `--pattern <pattern>`: 특정 패턴 검색
  - `--since <time>`: 시간 범위 지정
  - `--severity <level>`: 심각도 필터
  - `--max-findings <n>`: 최대 이슈 수

**Command 스펙 (source template — `${CLAUDE_PLUGIN_ROOT}` 포함, payload 내부에 보관)**:
```markdown
---
description: "Analyze L1 (memory/cache/storage) logs with iterative refinement"
argument-hint: "<log-paths> [OPTIONS]"
allowed-tools: ["Bash(${CLAUDE_PLUGIN_ROOT}/scripts/setup-l1-log-analysis.sh:*)"]
hide-from-slash-command-tool: "true"
---

# L1 Log Analysis Command

Execute the setup script to initialize the L1 log analysis loop:

```!
"${CLAUDE_PLUGIN_ROOT}/scripts/setup-l1-log-analysis.sh" $ARGUMENTS
```

This command starts an iterative loop where:
1. Initial log analysis identifies L1 issues
2. Subsequent iterations refine findings
3. Loop continues until completion or max iterations

COMPLETION: Output `<promise>YOUR_PROMISE_TEXT</promise>` when done.
```

**`[CR-1]` 설치본 (installer가 생성 — `~/.claude/commands/l1-log-analysis.md`에 실제로 설치되는 버전)**:

이 소스 템플릿의 `${CLAUDE_PLUGIN_ROOT}`는 plugin 컨텍스트 밖에서는 정의되지 않는 변수이므로, installer가 설치 시점에 실제 payload 절대경로로 **치환한 결과물**을 `~/.claude/commands/`에 써야 한다. 예:

```bash
PAYLOAD_DIR="$HOME/.claude/skills/l1-log-analysis"
sed "s|\${CLAUDE_PLUGIN_ROOT}|${PAYLOAD_DIR}|g" \
  "$SKILL_DIR/commands/l1-log-analysis.md" > "$HOME/.claude/commands/l1-log-analysis.md"
```

치환 후 `allowed-tools`와 본문의 스크립트 경로 모두 `/home/user/.claude/skills/l1-log-analysis/scripts/setup-l1-log-analysis.sh` 같은 고정 절대경로가 되어야 하며, 이 파일이 곧 `install-state.json.files_created[]`에 기록되는 대상이다.

**검증**:
- Command 파싱 테스트
- Option handling 테스트
- `[CR-1]` 설치된 `~/.claude/commands/l1-log-analysis.md`에 `${CLAUDE_PLUGIN_ROOT}` 리터럴이 남아있지 않은지, 치환된 경로가 실제 존재하는 파일을 가리키는지 확인

### Phase 7: Install Infrastructure
**목표**: Installer/Uninstaller 구현 (payload copy + `[CR-1]` hook/command 등록)

**작업 항목**:
- [ ] `install/install-common.sh`: 공통 설치 로직
  - 플랫폼 감지 (Claude Code vs OpenCode)
  - 설치 경로 탐지
  - `install-state.json` 생성/관리
  - `[CR-6]` `compute_source_hash()`: `tar cf - "$SKILL_DIR" 2>/dev/null | sha256sum | cut -d' ' -f1`로 payload 해시 계산, 스키마의 `source_hash`에 기록
- [ ] `install/install.sh`: WSL/Linux/Mac installer
  - Copy mode 사용 (payload)
  - `[CR-6]` **jq 사전 체크 추가** — 기존 초안은 uninstall.sh만 jq를 요구했고 install.sh는 요구하지 않았으나, hook 등록(아래)에 jq가 필요하므로 대칭적으로 추가
  - 기존 설치 확인
  - 권한 체크
  - `[CR-1]` **`register_hooks_and_commands()`**:
    ```bash
    register_hooks_and_commands() {
      local payload_dir="$1"   # e.g. $HOME/.claude/skills/l1-log-analysis
      local created=() modified=()

      # 1) 커맨드 등록: ${CLAUDE_PLUGIN_ROOT} → payload 절대경로 치환
      for cmd in l1-log-analysis cancel-l1-log-analysis; do
        local dest="$HOME/.claude/commands/${cmd}.md"
        sed "s|\${CLAUDE_PLUGIN_ROOT}|${payload_dir}|g" \
          "${payload_dir}/commands/${cmd}.md" > "$dest"
        created+=("$dest")
      done

      # 2) Stop Hook 등록: settings.json 백업 후 jq로 병합
      local settings="$HOME/.claude/settings.json"
      local backup="${settings}.l1-log-analysis.bak"
      [[ -f "$settings" ]] || echo '{}' > "$settings"
      cp "$settings" "$backup"

      local hook_cmd="${payload_dir}/hooks/stop-hook.sh"
      jq --arg cmd "$hook_cmd" '
        .hooks.Stop = ((.hooks.Stop // []) + [{"hooks": [{"type": "command", "command": $cmd}]}])
      ' "$backup" > "${settings}.tmp" && mv "${settings}.tmp" "$settings"

      # 3) 유효성 재검증 — 실패 시 즉시 롤백
      if ! jq empty "$settings" 2>/dev/null; then
        cp "$backup" "$settings"
        echo "❌ Error: settings.json 병합 실패, 백업으로 롤백했습니다." >&2
        return 1
      fi

      modified+=("$settings")
      # created[]/modified[]/backup 경로를 install-state.json에 기록 (호출부에서 처리)
      printf '%s\n' "${created[@]}" "${modified[@]}" "$backup"
    }
    ```
  - `[CR-6]` trap 기반 partial cleanup: `register_hooks_and_commands` 또는 payload 복사 중 실패 시, 그때까지 생성된 파일과 `settings.json` 변경을 되돌리고 `install-state.json`을 만들지 않음
  - 설치 상태 기록 (`hooks_installed`/`files_created`/`files_modified`를 실제 값으로 채움 — 더 이상 빈 배열 아님)
- [ ] `install/install.ps1`: Windows PowerShell installer
  - Copy mode 사용
  - 기존 설치 확인 / 권한 체크
  - `[CR-1]` `Register-HooksAndCommands`: 위 bash 함수와 동일 역할, `ConvertFrom-Json`/`ConvertTo-Json`으로 `settings.json` 병합, 백업은 `Copy-Item`
- [ ] `install/uninstall.sh`: WSL/Linux/Mac uninstaller
  - `install-state.json` 확인
  - 기록된 설치만 제거 (payload)
  - `[CR-1]` **`unregister_hooks_and_commands()`**: `files_created[]`의 커맨드 파일 삭제, `hooks_installed[].command`를 기준으로 jq `del()`로 해당 hook 항목만 정밀 제거(전체 파일을 백업으로 덮어쓰면 사용자가 그 사이 추가한 다른 hook까지 날아갈 수 있으므로 **정밀 제거를 기본으로**, 백업 복원은 fallback)
  - Cleanup
- [ ] `install/uninstall.ps1`: Windows PowerShell uninstaller
  - `install-state.json` 확인 / 기록된 설치만 제거
  - `[CR-1]` `Unregister-HooksAndCommands`

**Install State Schema** (`[CR-1][CR-6]` — `source_hash` 추가, `hooks_installed`/`files_created`/`files_modified`를 실제로 채움):
```json
{
  "version": "1.0.0",
  "installed_at": "2026-07-17T10:00:00Z",
  "install_mode": "copy",
  "platform": "Linux",
  "installations": {
    "claude_code": {
      "target": "/home/user/.claude/skills/l1-log-analysis",
      "source": "/home/user/study/BackEnd/loop_skill/l1-log-analysis",
      "type": "copy",
      "source_hash": "sha256:8f3a...",
      "installed": true,
      "verified": true
    },
    "omc": {
      "target": "/home/user/study/BackEnd/loop_skill/.omc/skills/l1-log-analysis",
      "source": "/home/user/study/BackEnd/loop_skill/l1-log-analysis",
      "type": "copy",
      "source_hash": "sha256:8f3a...",
      "installed": true,
      "verified": true
    }
  },
  "hooks_installed": [
    {
      "target_file": "/home/user/.claude/settings.json",
      "event": "Stop",
      "command": "/home/user/.claude/skills/l1-log-analysis/hooks/stop-hook.sh",
      "backup_file": "/home/user/.claude/settings.json.l1-log-analysis.bak"
    }
  ],
  "files_created": [
    "/home/user/.claude/commands/l1-log-analysis.md",
    "/home/user/.claude/commands/cancel-l1-log-analysis.md"
  ],
  "files_modified": [
    "/home/user/.claude/settings.json"
  ]
}
```

**검증**:
- Install/Uninstall 매칭 테스트
- Platform detection 테스트
- Safety tests (error cases)
- `[CR-1]` 설치 직후 `~/.claude/settings.json`의 `hooks.Stop`에 항목이 실제로 존재하는지, `~/.claude/commands/*.md`가 실제로 존재하는지 검증 (Test 19-21 참고)
- `[CR-6]` 두 번 연속 설치 시도 시 `source_hash`가 동일하면 "변경 없음", 다르면 "소스가 변경됨 — 재설치 권장" 경고가 출력되는지 확인 (자동 업데이트는 범위 밖, 감지만 함)

### Phase 8: Integration
**목표**: 플랫폼 통합 및 테스트

**작업 항목**:
- [ ] opencode skill 시스템 등록 테스트
- [ ] Claude Code skill 시스템 등록 테스트
- [ ] 사용자 documentation 작성
- [ ] LLM self-testable tests 실행

**검증**:
- End-to-end tests
- Platform compatibility tests

## 위험 요소 및 완화

### 0. 아키텍처 Risk Points (신규 — 적대적 검토) `[CR-1~CR-6]`

0. **[CR-1][최우선] Payload copy만으로는 Stop Hook/슬래시 커맨드가 등록되지 않음**
   - **위험**: 설치는 성공으로 보고되지만 실제로는 `/l1-log-analysis`가 인식되지 않고 Stop hook도 발동하지 않는 조용한 실패 상태가 된다 (근거: `SKILL.md`는 hooks/commands 개념이 없음, plugin은 `installed_plugins.json` 등록 필요, Claude Code hooks는 `settings.json`에서만 구성됨)
   - **완화**: Phase 7의 `register_hooks_and_commands()`로 명시적 등록, 설치 스크립트가 등록 성공을 자체 검증한 후에만 `verified: true` 기록

0-1. **[CR-2] Stop Hook의 고정 프롬프트 재사용과 Phase 4 자동 생성의 충돌**
   - **위험**: 원본 stop-hook은 상태 파일 본문을 그대로 재사용 — Phase 4 목표(분석 결과 반영한 새 prompt)와 구조적으로 맞지 않음
   - **완화**: Phase 5에서 iteration 갱신과 본문 재생성을 하나의 원자적 쓰기로 확장 구현

0-2. **[CR-3] OpenCode Stop Hook 동등 기능 미검증**
   - **위험**: OpenCode가 세션 종료 가로채기를 지원하지 않으면 듀얼 플랫폼 loop 자체가 성립하지 않음
   - **완화**: Phase -1에서 우선 검증, 미지원 시 loop 범위를 Claude Code 전용으로 축소

### Ralph Loop 관련 Risk Points

1. **무한 Loop (Infinite Loop)**
   - **위험**: Max iterations 미설치, Completion promise 부재 시 영구 루프
   - **완화**: `[CR-6]` Max iterations 기본값 50 강제 — Phase 2에서 실제로 `MAX_ITERATIONS=0`(원본 기본값)을 50으로 오버라이드해야 하며, 문서화만으로는 미완인 상태였음
   - **완화**: Completion promise 기본값 설정
   - **완화**: Session timeout 및 resource limit 적용

2. **State 파일 손상 (State File Corruption)**
   - **위험**: YAML frontmatter 파싱 실패, iteration 비정상 값
   - **완화**: 기존 ralph-loop 검증 로직 재사용 (numeric validation)
   - **완화**: 손상 시 graceful degradation 및 cleanup

3. **Session Isolation**
   - **위험**: Multiple session에서 동시 loop 실행 시 state 충돌
   - **위험**: 한 session에서 종료 후 다른 session에 영향
   - **완화**: session_id 기반 isolation 기능
   - **완화**: State file의 session_id와 현재 session 비교

4. **Hook Execution Race Condition**
   - **위험**: Stop hook 실행 중 추가 요청으로 state 불일치
   - **위험**: Parallel hook 호출로 중복 state 업데이트
   - **완화**: State file 업데이트 시 atomic operation (temp file + mv)
   - **완화**: File lock mechanism 추가

5. **Transcript Parsing Failure**
   - **위험**: Transcript format 변경으로 assistant message 추출 실패
   - **위험**: Completion promise detection 실패로 무한 loop
   - **완화**: jq parsing failure 시 graceful degradation
   - **완화**: Fallback mechanism으로 log-based completion detection

### Installer/Uninstaller 관련 Risk Points

6. **Installer/Uninstaller 매칭 실패**
   - **위험**: installer가 설치하지 않은 것을 uninstaller가 제거
   - **위험**: installer가 설치한 것을 uninstaller가 제거하지 않음
   - **완화**: install-state.json을 통한 strict 기록 및 검증
   - **완화**: Uninstaller는 JSON에 기록된 것만 제거

7. **Copy Mode Storage Growth**
   - **위험**: Copy 설치로 디스크 중복 사용
   - **위험**: Skill source 변경 시 설치된 버전 불일치
   - **완화**: `[CR-6]` Install state에 source hash 기록 — Phase 7의 `compute_source_hash()`로 실제 계산 (이전 초안은 스키마/스크립트 어디에도 구현이 없었음)
   - **완화**: Update mechanism 구현 — **범위 축소**: 이번 구현은 hash 불일치 "감지 + 경고"까지만 하고, diff-based 자동 업데이트는 후속 작업으로 명시적으로 범위 밖 처리 (구현하지 않을 완화책을 남겨두지 않기 위함)

8. **[신규] settings.json 병합 실패로 인한 사용자 환경 손상** `[CR-1 파생]`
   - **위험**: `register_hooks_and_commands()`가 `~/.claude/settings.json`을 jq로 덮어쓰는 과정에서 실패하면(디스크 full, 권한 문제 등) 사용자의 기존 hook/permission 설정 전체가 손상될 수 있다 — payload 복사보다 blast radius가 훨씬 크다
   - **완화**: 병합 전 `settings.json.l1-log-analysis.bak` 백업, 병합 후 `jq empty`로 유효성 재검증, 실패 시 즉시 롤백 (Phase 7 `register_hooks_and_commands()` 참고)
   - **완화**: uninstaller는 전체 파일 복원 대신 `hooks_installed[].command` 기준 정밀 `jq del()` 제거를 기본으로 사용, 백업 복원은 fallback으로만

## 테스트 계획

### LLM Self-Testable Test Cases

**Test 1: Fresh Install to Claude Code Only**
```bash
# Pre-condition: No install-state.json, no l1-log-analysis in Claude Code
# Test steps:
./install/install.sh
# Expected outputs:
# 1. install-state.json created
# 2. l1-log-analysis copied to ~/.claude/skills/l1-log-analysis
# 3. state.claude_code.installed = true
# 4. Exit code 0
```

**Test 2: Install When Already Installed**
```bash
# Pre-condition: install-state.json exists
# Test steps:
./install/install.sh
# Expected outputs:
# 1. Error message: "Already installed"
# 2. Exit code 1
```

**Test 3: Uninstall After Fresh Install**
```bash
# Pre-condition: Fresh install completed (Test 1)
# Test steps:
./install/uninstall.sh
# Expected outputs:
# 1. ~/.claude/skills/l1-log-analysis removed
# 2. install-state.json removed
# 3. Exit code 0
```

**Test 4: Uninstall When Not Installed**
```bash
# Pre-condition: No install-state.json
# Test steps:
./install/uninstall.sh
# Expected outputs:
# 1. Error message: "Not installed"
# 2. Exit code 1
```

**Test 5: Install Target Exists**
```bash
# Pre-condition: l1-log-analysis directory exists in target
# Test steps:
./install/install.sh
# Expected outputs:
# 1. Warning: "Target already exists"
# 2. Skip installation for that platform
# 3. Exit code 0
```

**Test 6: Basic Loop with Completion Promise**
```bash
# Pre-condition: /l1-log-analysis skill installed
# Test command:
/l1-log-analysis "Analyze /var/log/syslog" --completion-promise "DONE" --max-iterations 5
# Expected outputs:
# 1. Loop runs exactly 5 times
# 2. State file iteration increments each time
# 3. Final state.iteration = 5
# 4. State file removed after completion
```

**Test 7: Max Iterations Exceeded**
```bash
# Pre-condition: /l1-log-analysis skill installed
# Test command:
/l1-log-analysis "Analyze logs" --max-iterations 3
# Expected outputs:
# 1. Loop stops after 3 iterations
# 2. State file removed
# 3. Message: "Max iterations reached"
```

**Test 8: Cross-Session Non-Interference** `[CR-5 — 명칭·기대값 정정]`
```bash
# Pre-condition: Two Claude Code sessions in the SAME project (state file is project-scoped: .claude/l1-log-analysis.local.md)
# Test steps:
# Session A: /l1-log-analysis "Analyze test.log" --max-iterations 5   (loop starts, session_id=ses_A)
# Session B (while A is active): /l1-log-analysis "Analyze other.log"
# Expected outputs:
# 1. Session B's setup is REJECTED by the [CR-4] active-state guard ("이미 활성 loop가 있습니다") — NOT its own independent state
# 2. Session A's state file (iteration, session_id) is unchanged by B's rejected attempt
# 3. A Stop hook firing in a session that never called /l1-log-analysis but shares the project simply exits 0 (allows exit) without touching state
# 4. Do NOT assert "each session has independent state" — the design has exactly one active loop per project
```

**Test 9: State File Corruption Recovery**
```bash
# Pre-condition: Active loop running
# Test steps:
# 1. Modify state file to set iteration="invalid"
# 2. Trigger stop hook
# Expected outputs:
# 1. Error message: "State file corrupted"
# 2. State file removed
# 3. Loop stops gracefully
```

**Test 10: Full Cycle - Install → Run → Uninstall**
```bash
# Test steps:
./install/install.sh
/l1-log-analysis "Analyze test.log" --completion-promise "TEST_DONE" --max-iterations 2
./install/uninstall.sh
# Expected outputs:
# 1. Installation succeeds
# 2. Loop runs 2 iterations and completes
# 3. Uninstallation removes all traces
```

**Test 11: Command Actually Registers** `[CR-1 — 신규]`
```bash
# Pre-condition: Fresh install completed
# Test steps:
ls ~/.claude/commands/l1-log-analysis.md ~/.claude/commands/cancel-l1-log-analysis.md
grep -c '${CLAUDE_PLUGIN_ROOT}' ~/.claude/commands/l1-log-analysis.md
# Expected outputs:
# 1. Both files exist
# 2. grep count is 0 (no unresolved placeholder)
# 3. The embedded script absolute path exists on disk
```

**Test 12: Stop Hook Actually Registers in settings.json** `[CR-1 — 신규]`
```bash
# Pre-condition: Fresh install completed
# Test steps:
jq '.hooks.Stop' ~/.claude/settings.json
jq empty ~/.claude/settings.json
ls ~/.claude/settings.json.l1-log-analysis.bak
# Expected outputs:
# 1. hooks.Stop contains an entry pointing at the installed stop-hook.sh absolute path
# 2. settings.json is still valid JSON
# 3. Backup file exists
```

**Test 13: Uninstall Restores settings.json Precisely (Not Wholesale)** `[CR-1 — 신규]`
```bash
# Pre-condition: A pre-existing unrelated hook/permission was in settings.json BEFORE install.sh ran; Test 12 passed; then ./install/uninstall.sh
# Test steps:
jq '.hooks.Stop' ~/.claude/settings.json
jq '.permissions' ~/.claude/settings.json   # or whatever pre-existing key was present
# Expected outputs:
# 1. The l1-log-analysis Stop hook entry is gone
# 2. The unrelated pre-existing hook/permission the user had BEFORE install is still present
#    (fails if uninstall did a wholesale restore of the pre-install backup and the user made
#    OTHER settings.json edits in between install and uninstall)
```

**Test 14: Phase-4 Prompt Body Actually Changes Across Iterations** `[CR-2 — 신규]`
```bash
# Pre-condition: /l1-log-analysis running against a log producing different findings each iteration
# Test steps:
# 1. Capture state file body after iteration 1 (findings A)
# 2. Let iteration 2 run, producing findings B != A
# 3. Capture state file body after iteration 2
# Expected outputs:
# 1. Body text differs between iteration 1 and 2 (not byte-identical)
# 2. Body reflects findings B
# 3. An unchanged body is a FAILED test — it means CR-2 was not actually fixed
```

## 기술 스택

- **Language**: Bash (scripts/hooks), PowerShell (installers), Markdown (commands)
- **Data Format**: YAML (frontmatter), JSON (hook output, install state)
- **Log Parsing**: grep, awk, sed, jq
- **Pattern Matching**: 정규식, 키워드 매칭
- **Platform Detection**: Shell 변수, PowerShell 환경 변수
- **File Operations**: cp (copy), rm, jq (JSON parsing)

## 체크리스트

### Phase -1: 아키텍처 검증 (신규, blocking) `[CR-1][CR-3]`
- [ ] settings.json `hooks.Stop` 수동 등록 재현
- [ ] `~/.claude/commands/*.md` plugin 없이 슬래시 커맨드 인식 재현
- [ ] OpenCode Stop hook 동등 기능 존재 여부 확인

### Installer/Uninstaller 개발
- [ ] install.sh 개발 (jq 사전 체크, `register_hooks_and_commands()`, trap 기반 partial cleanup 포함)
- [ ] install.ps1 개발 (`Register-HooksAndCommands` 포함)
- [ ] uninstall.sh 개발 (`unregister_hooks_and_commands()` 포함)
- [ ] uninstall.ps1 개발 (`Unregister-HooksAndCommands` 포함)
- [ ] install-state.json 스키마 정의 (`source_hash`, 실제로 채워지는 `hooks_installed`/`files_created`/`files_modified`)
- [ ] Platform detection 공통 로직
- [ ] `compute_source_hash()` 구현

### Skill 개발
- [ ] Phase 0: Project Structure 설정
- [ ] Phase 1: ralph-loop 베이스 복사
- [ ] Phase 2: State 파일 확장 (max-iterations 기본값 50 오버라이드, active-state 가드 포함)
- [ ] Phase 3: 로그 분석 기능
- [ ] Phase 4: Prompt 자동 생성 (Phase 5와 함께 완료해야 유효 — `[CR-2]`)
- [ ] Phase 5: Stop Hook 확장 (본문 재생성 로직, hook 등록 전제 포함)
- [ ] Phase 6: Command 정의 (설치 시점 경로 치환 포함)

### 테스트
- [ ] LLM Self-Testable Tests (Test 1-14 — Test 8은 CR-5 기준으로 정정됨, Test 11-14는 신규)
- [ ] Unit Tests
- [ ] Integration Tests
- [ ] End-to-End Tests

### Documentation
- [ ] README 작성
- [ ] 사용자 가이드 작성
- [ ] 개발자 가이드 작성

## 참고 문서

- ralph-loop 소스: `/home/fanta/.claude/plugins/marketplaces/claude-plugins-official/plugins/ralph-loop/`
- Claude Code skill 가이드: https://docs.anthropic.com
- OpenCode skill 가이드: https://github.com/anomalyco/opencode/

---

**작성자**: L1 Log Analysis Team
**검토자**: 적대적 검토 완료 (2026-07-19) — `harness_loop_plan.md`의 CR-1~CR-6 근거로 Phase -1 신설, Phase 2/4/5/6/7 수정, 위험 목록/테스트 정정
**승인자**: [미정]