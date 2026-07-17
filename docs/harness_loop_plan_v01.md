# L1 Log Analysis Skill 구현 계획

## 개요

`/l1-log-analysis` skill은 `/ralph-loop`의 self-referential loop 패턴을 기반으로, L1(메모리/캐시/스토리지) 시스템의 로그 분석 작업을 지속적으로 반복 수행하는 skill입니다.

## 적대적 검토 결과 (Critical Review) — 2026-07-19

기존 초안은 실제 `ralph-loop` 소스(`~/.claude/plugins/marketplaces/claude-plugins-official/plugins/ralph-loop/`)와 Claude Code/OMC의 실제 설치·hook 등록 메커니즘을 대조 검증하지 않고 작성되었다. 아래는 코드/설정 파일을 직접 확인하여 발견한 결함이며, **CR-1과 CR-2는 설계 자체가 동작하지 않는 수준의 결함**이므로 이 문서 전체의 아키텍처 절과 Phase 5~7을 이 섹션 기준으로 수정했다.

### CR-1 (Blocker) — "Skill copy 설치"로는 Stop Hook과 슬래시 커맨드가 등록되지 않는다

- **문제**: 기존 초안은 `l1-log-analysis/`를 통째로 `~/.claude/skills/l1-log-analysis/`(Claude Code)와 `.omc/skills/l1-log-analysis/`(OMC)에 `cp -r`하면 `hooks/hooks.json`의 Stop hook과 `commands/*.md`의 슬래시 커맨드가 그대로 동작한다고 가정한다.
- **근거**:
  - Claude Code의 실제 skill 포맷은 `SKILL.md` 단일 파일뿐이다 (`~/.claude/skills/visualize/SKILL.md` 확인). hooks/commands 개념 자체가 skill 스펙에 없다.
  - hooks/commands/`.claude-plugin/plugin.json` 구조는 **plugin** 전용이며, plugin은 `~/.claude/plugins/installed_plugins.json` + `settings.json`의 `enabledPlugins`로 등록되고, `marketplace add` → `plugin install` 흐름을 통해서만 활성화된다 (`docs/LOCAL_PLUGIN_INSTALL.md` 확인). 파일을 임의 디렉토리에 복사하는 것만으로는 Claude Code가 이를 plugin으로 인식하지 않는다.
  - OMC 소스 주석이 이를 명시한다: `"Claude Code hooks are configured in settings.json and run as shell commands."` (`oh-my-claudecode/src/installer/hooks.ts:5`)
  - **결정적 반증 사례**: OMC 자신이 제공하는 `ralph` skill(`skills/ralph/SKILL.md`)도 순수 `SKILL.md`뿐이며 자체 hook 파일이 없다. 실제 loop 지속 로직은 skill 밖에서, OMC plugin 전체 설치 시 **단 한 번** 등록되는 공용 Stop hook(`templates/hooks/stop-continuation.mjs`)이 담당하고, skill은 상태 파일만 쓴다. 이는 "skill이 자기 hook을 못 갖는다"는 구조적 제약을 그대로 보여주는 선례다.
- **영향**: Phase 5(Stop Hook 확장), Phase 6(Command 정의), Phase 7(Install Infrastructure) 전체가 "복사만 하면 끝"이라는 잘못된 전제 위에 있다. 이대로 구현하면 `install.sh` 실행 후 `/l1-log-analysis`는 인식되지 않는 커맨드가 되고, 세션 종료 시 Stop hook도 전혀 발동하지 않는다.
- **해결 방향** (symlink 대신 copy를 쓰겠다는 사용자 결정과 호환됨 — "복사 후 등록"으로 확장):
  1. **Payload 복사**: 기존 계획대로 `scripts/`, `analyzers/`, `templates/`, hook 스크립트 본체를 `~/.claude/skills/l1-log-analysis/`(및 OMC 쪽 대응 경로)에 copy — 이 부분은 변경 없음.
  2. **Command 등록**: 커맨드 마크다운을 `~/.claude/commands/l1-log-analysis.md`, `~/.claude/commands/cancel-l1-log-analysis.md`로 별도 copy. Claude Code는 `~/.claude/commands/*.md`를 사용자 정의 슬래시 커맨드로 직접 인식한다 (`LOCAL_PLUGIN_INSTALL.md`의 "npm global install" 비교표: `~/.claude/agents/`, `~/.claude/commands/` 참조). 이때 커맨드 본문의 `${CLAUDE_PLUGIN_ROOT}`는 plugin 컨텍스트가 없으므로 **설치 시점에 실제 payload 절대경로로 치환**해야 한다.
  3. **Hook 등록**: `hooks/hooks.json`의 Stop hook 항목을, 사용자(또는 프로젝트) `settings.json`의 `hooks.Stop` 배열에 **installer가 직접 병합**한다 (`type: "command"`, `command`는 payload 내 `stop-hook.sh`의 절대경로). 이는 skill/plugin 여부와 무관하게 Claude Code가 지원하는 일반 hook 등록 경로이며, jq로 기존 `settings.json`을 읽고 backup 후 병합·저장한다.
  4. Uninstaller는 이 두 등록(커맨드 파일, settings.json의 hook 항목)도 `install-state.json.files_created[]`에 기록해 정확히 되돌려야 한다 (기존 초안은 `files_created: []`를 항상 빈 배열로 하드코딩해 사실상 죽은 필드였다 — CR-6 참조).
  - 대안으로 진짜 Claude Code plugin(`marketplace add` + `plugin install`)으로 배포하는 방법도 있으나, 이는 "symlink 없이 copy로 install/uninstall을 직접 구현한다"는 사용자 요구와 배치되므로(marketplace 방식은 Claude Code가 자체 캐시 디렉토리를 관리) **채택하지 않고 위 settings.json 직접 등록 방식을 기본안으로 확정**한다.

#### 부록: Claude Code의 Skill vs Command — 왜 원래 의도("skill로 쓰기")와 실제 구현(command 등록)이 다른가

이 프로젝트는 원래 "`/l1-log-analysis`를 skill로 사용"할 생각이었으나, ralph-loop 패턴 자체가 요구하는 두 가지 동작 — ① 인자를 파싱해 즉시 state 파일을 만드는 것, ② 세션 종료를 가로채는 것 — 은 Claude Code의 "skill" 개념 밖에 있다. 원본 `ralph-loop`도 실제로는 `SKILL.md`가 아니라 plugin의 `commands/` + `hooks/` 구조로 되어 있었다(§CR-1 근거).

| | Skill (`SKILL.md`) | Command (`commands/*.md`) |
|---|---|---|
| 트리거 방식 | 모델이 description을 보고 스스로 판단해 호출(Skill tool 경유), 또는 `/이름` 입력 시 Skill tool로 라우팅 | `/이름 args` 입력 시 frontmatter의 bash 블록(```` ```! ````)이 **즉시, 자동으로 실행** |
| 인자 처리 | 모델이 자연어로 해석 | frontmatter `argument-hint` + `$ARGUMENTS`가 스크립트에 그대로 전달 — `--max-iterations 20` 같은 옵션 파싱에 적합 |
| Hook 등록 | **불가능** — SKILL.md는 hook을 가질 수 없다 (OMC 자신의 `ralph` skill도 `SKILL.md` 단독이며, hook은 OMC plugin 전체 설치 시 한 번만 별도 등록됨) | 그 자체로는 hook과 무관 — 이 문서에서는 command 등록과 hook 등록(`settings.json.hooks.Stop`)을 **별개의 두 단계**로 취급 |
| 이 프로젝트에서의 결론 | `SKILL.md`는 사람이 읽는 설명/문서 용도로만 남긴다 (예: `.omc/skills/l1-log-analysis.md`, CR-7 참고) | 실제 `/l1-log-analysis <args>` 실행과 loop 시작은 **command 등록**(`~/.claude/commands/l1-log-analysis.md`)이 담당해야 한다 |

**결론**: "skill로 쓰겠다"는 원래 의도 자체가 이 기능(자동 인자 파싱 실행 + Stop hook)과 구조적으로 맞지 않는다. Claude Code 쪽 loop 기능이 동작하려면 **command 등록이 선택이 아니라 필수**다. Skill은 병행해서 문서/설명용으로 유지할 수 있지만, loop 실행 경로를 대체하지 못한다.

### CR-2 (Blocker) — Phase 4(자동 prompt 생성)는 상속받은 Stop Hook 메커니즘과 충돌한다

- **문제**: 원본 `stop-hook.sh:150,169-170,181-188`을 보면, 매 iteration마다 실제로 갱신되는 것은 frontmatter의 `iteration:` 한 줄(`sed`)뿐이다. `PROMPT_TEXT`는 상태 파일의 두 번째 `---` 이후 본문을 **그대로** 다시 읽어(`awk`) `reason`으로 되먹인다 — 즉 원본 ralph-loop은 "완전히 동일한 프롬프트"를 반복 주입하도록 설계되어 있다.
- **영향**: Phase 4가 요구하는 "이전 분석 결과를 반영한 새 prompt를 매 iteration 생성"은 이 메커니즘으로는 불가능하다. 지금 계획대로 구현하면 Phase 4는 그냥 아무 효과가 없거나(본문이 안 바뀌므로), 혹은 구현자가 별도 로직 없이 "될 것"이라 가정하고 넘어가게 된다.
- **해결 방향 (1차, 폐기됨)**: ~~Stop hook을 확장하여, iteration 증가와 같은 원자적 쓰기 안에서 상태 파일의 본문도 `l1-log-analyzer.sh`의 최신 findings를 반영해 재생성해야 한다~~ — 이 해결 방향은 "스크립트가 findings를 계산해 프롬프트에 주입한다"는 전제였는데, CR-8(아래)에서 로그 분석 자체를 스크립트가 아니라 LLM chain-of-thought로 하기로 결정하면서 전제가 바뀌었다.
- **해결 방향 (2차, 확정 — CR-8과 함께 읽을 것)**: LLM이 매 iteration 직접 쓰고 갱신하는 리포트 파일(예: `.claude/l1-log-analysis/report.md`)이 "진짜 상태"를 담으므로, Stop hook은 원본 ralph-loop처럼 **거의 동일한 프롬프트를 재사용해도 무방**하다. 프롬프트는 "이전 리포트를 Read하고 이어서 분석하라"는 고정 지시만 담으면 되고, 이전 iteration과의 차이는 파일 시스템에 이미 반영되어 있다(LLM이 직접 쓴 파일이므로). 원자적 본문 재생성 로직은 **불필요**해졌다 — Phase 5 수정 참고.

### CR-3 (개정, 검증 완료) — OpenCode의 Stop Hook은 Claude Code와 근본적으로 다른 메커니즘이며, "OpenCode에서 동작" 여부는 서드파티 plugin에 달려 있다

- **원래 문제 제기**: 문서 전체가 "Claude Code든 OpenCode든 동일한 Stop Hook 패턴이 있다"고 전제했으나 근거가 없었다.
- **검증 결과** (설치된 `@opencode-ai/plugin` SDK 및 `oh-my-openagent` 패키지 소스 직접 확인, 2026-07-19):
  1. **OpenCode 공식 plugin 메커니즘은 선언형 JSON이 아니라 코드다.** `@opencode-ai/plugin`의 `Plugin = (input: PluginInput, options?) => Promise<Hooks>` 타입을 보면, plugin은 `{client, project, directory, worktree, $}`를 받아 `Hooks` 객체를 반환하는 **비동기 JS/TS 함수**다. 그 중 `event?: (input: {event: Event}) => Promise<void>`가 세션 라이프사이클 전체(`session.idle`, `session.stop`, `session.created`, `session.error` 등 — 실제 이벤트 타입 문자열은 `oh-my-openagent` 번들에서 확인)를 받는 범용 핸들러이며, 어떤 이벤트인지는 핸들러 내부에서 `event.type`으로 분기해야 한다. Claude Code의 `hooks.json`(`{"Stop": [{"hooks":[{"type":"command","command":"..."}]}]}`) 같은 **선언형 설정 파일 등록 방식이 아니다.**
  2. **Plugin 등록은 `opencode.json`의 `plugin` 배열**을 통해서만 이루어진다. 값은 npm 모듈명 문자열이거나(`opencode plugin <module>` CLI가 이 형태로 설치), `file://<절대경로>` 로컬 파일 URL이다(`oh-my-openagent` 번들 코드에서 `entry.startsWith("file://")` 분기를 직접 확인). 즉 로컬 코드로 plugin을 만드는 것 자체는 가능하지만, Claude Code의 "디렉토리에 파일을 복사하면 스캔되어 인식"되는 방식과 달리 **`opencode.json`에 명시적으로 등록**해야 한다.
  3. **커맨드는 별도 파일 위치**로 보인다 — `oh-my-openagent` 소스에 `.opencode/command`, `~/.config/opencode` 하위 등의 경로가 등장하지만, 정확한 frontmatter 스키마는 이번 조사에서 확정하지 못했다. Phase -1에서 실제 `.opencode/command/*.md` 예시를 만들어 검증 필요.
  4. **사용자가 관찰한 "OpenCode에서도 `/ralph-loop`이 동작한다"의 실체**: bare OpenCode의 내장 기능이 아니라, 설치된 서드파티 plugin **`oh-my-openagent`**(별칭 `oh-my-opencode`, `opencode.json`의 `plugin` 배열에 `"oh-my-openagent"`로 등록되어 있음)가 `dist/hooks/ralph-loop/` 아래에 `session-event-handler`, `loop-state-controller`, `continuation-prompt-builder`/`continuation-prompt-injector`, `completion-promise-detector`, `no-progress-turn-detector`, `loop-session-recovery` 등 **완전히 독립적으로 재구현한 TypeScript 모듈 묶음**을 갖고 있고, 이를 OpenCode의 `event`(`session.idle`/`session.stop`) API에 등록해서 동작하는 것이다. Claude Code의 `stop-hook.sh`가 OpenCode에서 그대로 실행되는 게 **아니다.**
  5. **추가로 발견한 사실**: `oh-my-openagent`는 `claude-code-compat-core`라는 별도 호환 레이어를 갖고 있다. 이 레이어는 (a) 정식 Claude Code plugin 설치 경로에서 `.claude-plugin/plugin.json` + `hooks/hooks.json`을 스캔하거나, (b) `~/.claude/settings.json` / `.claude/settings.json` / `.claude/settings.local.json`을 **직접 읽어서** OpenCode 이벤트로 재등록하는 기능을 제공한다(소스에서 `getClaudeSettingsPaths()`, `findPluginManifestPath()` 함수로 확인). 이는 CR-1에서 설계한 "Stop hook을 `settings.json.hooks.Stop`에 등록"하는 방식이, 사용자 환경에 `oh-my-openagent`가 이미 설치되어 있다면 **OpenCode에서도 부수적으로 인식될 가능성**이 있다는 뜻이다 — 그러나 이는 **bare OpenCode의 기능이 아니라 서드파티 plugin에 대한 의존**이다.

- **지원 범위를 다음 두 티어로 명확히 나눠 문서화한다** (더 이상 "듀얼 플랫폼 loop 지원"을 하나의 문장으로 뭉뚱그리지 않는다):
  - **Tier 0 (bare OpenCode, 서드파티 plugin 없음)**: loop 기능 **미지원**. 지원하려면 Claude 쪽 bash 스크립트를 재사용할 수 없고, `@opencode-ai/plugin`의 `event` API를 쓰는 **완전히 별도의 JS/TS plugin**을 새로 작성해 `opencode.json`에 `file://` 경로로 등록해야 한다. 참고 구현체로 `oh-my-openagent`의 `dist/hooks/ralph-loop/*`가 있으나 이는 우리 코드가 아니라 **참고용 재구현 사례**일 뿐이다.
  - **Tier 1 (사용자 환경에 `oh-my-openagent`가 설치되어 있음)**: (a) 사용자가 이미 갖고 있는 `oh-my-openagent`의 자체 ralph-loop 재구현이 우리 L1 skill과 무관하게 동작 중일 수 있고 — 이건 우리가 만든 게 동작하는 게 아니라 오해하기 쉬우므로 문서/README에 명시 — (b) CR-1의 `settings.json.hooks.Stop` 등록이 `claude-code-compat-core`를 통해 픽업될 가능성이 있으나 **미검증**이며 Phase -1에 검증 항목으로 추가한다.
- **추가 검증 (2026-07-19, 3차)**: `oh-my-openagent`의 compat 레이어 내부(`findMatchingHooks`, hook 호출부)를 더 확인한 결과, Tier 1의 실현 가능성은 "가능성"을 넘어 **코드 레벨에서 사실상 확정적**이다:
  - Claude Code의 훅 이벤트 타입 목록(`PreToolUse`, `PostToolUse`, `Stop`, `SessionStart`, `SessionEnd` 등)을 `ALL_HOOK_EVENT_TYPES`로 **그대로** 재현하고 있다
  - `findMatchingHooks(config, "Stop")`가 `.claude/settings.json`(CR-1에서 우리가 병합해 넣는 바로 그 파일)의 `hooks.Stop`을 읽어 매칭한다
  - 호출 시 구성하는 stdin이 Claude Code와 **동일한 스키마**다: `{session_id, transcript_path, cwd, hook_event_name: "Stop", stop_hook_active, ...}`
  - OpenCode는 세션을 SQLite(`opencode.db`)로 저장해 Claude Code의 JSONL transcript와 포맷이 다른데, compat 레이어는 `buildTranscriptFromSession()`으로 **Claude Code JSONL 포맷의 transcript 파일을 즉석에서 재구성**해 우리 `stop-hook.sh`의 `grep '"role":"assistant"'` + jq 파싱이 그대로 통하게 만든다
  - 즉, `oh-my-openagent`(Claude Code 호환 기능 포함)가 설치된 환경이라면 **CR-1의 산출물(payload + `~/.claude/commands/*.md` + `settings.json.hooks.Stop`)을 그대로 재사용하는 것만으로 OpenCode에서도 동작할 가능성이 매우 높다** — 별도의 OpenCode 전용 코드가 필요 없다는 뜻이다. 다만 이는 여전히 정적 코드 분석 근거이며 실제 구동 테스트는 Phase -1에서 확인해야 한다.

- **결정 (2026-07-19, 사용자 확정)**: OpenCode 지원 범위는 **Tier 1만** 채택한다.
  - Tier 0(bare OpenCode용 신규 네이티브 plugin 개발)은 **이번 구현 범위에서 명시적으로 제외**한다. 후속 작업으로 남겨두되 이번 Phase 목록/체크리스트에는 포함하지 않는다
  - "OpenCode 지원"은 "`oh-my-openagent`(Claude Code 호환 기능 포함)가 설치된 환경에서 Claude Code용 산출물이 그대로 동작함"으로 정의하고, **하드 의존성으로 문서에 명시**한다
  - `oh-my-openagent`가 없는 bare OpenCode 사용자를 위해서는, installer가 OpenCode를 감지하되 `oh-my-openagent` 미설치를 확인하면 "OpenCode에서 loop 기능을 쓰려면 `oh-my-openagent`(Claude Code 호환) 설치가 필요합니다"라는 안내 메시지를 출력하고 payload 설치만 진행 (또는 완전히 skip)
  - Phase -1의 OpenCode Tier 0 검증 항목은 삭제하고, Tier 1 검증(우리 산출물이 실제로 compat 레이어를 통해 발동하는지)에 집중한다 (아래 Phase -1 수정 참고)

### CR-4 — Setup 스크립트가 활성 loop를 조용히 덮어쓴다 (Concurrent Execution 위험의 실제 원인)

- **문제**: `setup-ralph-loop.sh:140` (`cat > .claude/ralph-loop.local.md <<EOF ...`)는 기존 상태 파일 존재 여부를 전혀 확인하지 않는다. 기존 위험 목록 8번("Concurrent Execution")의 완화책으로 적힌 "Active state file 존재 시 error"는 **원본 스크립트에 구현되어 있지 않은 문장**이다.
- **영향**: 세션 A가 loop를 실행 중일 때 같은 프로젝트에서 세션 B가 `/l1-log-analysis`를 실행하면, 세션 A의 진행 상황(iteration, findings)이 통보 없이 사라진다. 상태 파일은 프로젝트 단위로 하나뿐이라 이 위험은 상시 존재한다.
- **해결 방향**: `setup-l1-log-analysis.sh`에 `[[ -f "$STATE_FILE" ]]` 가드를 추가하고, active 상태 파일이 있으면 "이미 활성 loop가 있습니다. 종료하려면 ... " 에러로 즉시 중단하도록 Phase 2/6에 명시한다.

### CR-5 — Session Isolation은 "독립 상태"가 아니라 "겹치지 않게 막는" 수준이다

- **문제**: 원본 `stop-hook.sh:27-35`의 session_id 체크는 상태 파일과 세션이 다르면 **그 세션의 Stop hook은 그냥 조용히 종료를 허용**할 뿐이다(자기 loop를 새로 시작하지 않음). 그런데 기존 문서의 Test 8/10(Session Isolation)은 "Session A와 B가 각각 독립된 state를 가진다"고 단언한다. 상태 파일은 프로젝트당 **하나**(`.claude/l1-log-analysis.local.md`)이므로 이는 사실과 다르다 — 세션 B가 자신의 loop를 시작하려고 setup 스크립트를 실행하면 CR-4에서 설명한 대로 세션 A의 파일을 덮어쓴다.
- **해결 방향**: 아래 테스트 계획 절에서 Test 8/10을 "세션 간 상태 미간섭(non-interference)" 테스트로 정정하고, 기대 결과를 실제 동작(다른 세션의 Stop hook은 no-op, 동시 setup은 CR-4 가드에 의해 거부됨)에 맞게 재작성한다.

### CR-6 — 위험 목록의 완화책 중 일부는 실제로 구현되지 않은 "거짓 완화"다

샘플 코드와 대조한 결과, 다음 완화책은 문장으로만 존재하고 제공된 스크립트/스키마 어디에도 구현되어 있지 않다. 코드가 하지 않는 완화를 문서에 남겨두는 것은 안 적는 것보다 위험하므로, 각각 "구현 항목으로 승격" 또는 "삭제" 처리했다(본문 위험 목록 참고):
- 위험 1 "Max iterations 기본값 50 강제" — `setup-ralph-loop.sh:10`의 기본값은 `MAX_ITERATIONS=0`(무제한)이며 이를 50으로 바꾸는 로직이 없다 → Phase 2에 "L1 전용 기본값을 50으로 오버라이드" 작업 항목 추가.
- 위험 5 "Fallback mechanism으로 log-based completion detection" — 아무 스크립트에도 구현 없음 → 미정 항목으로 표시, Phase 5 작업 항목에 추가하거나 범위에서 제외. **(CR-8로 재해결)**: 이후 CR-8에서 종료 조건 자체를 스크립트 계산이 아니라 LLM 자기평가(completion-promise 문구)로 전환하면서, 이 항목은 "구현 여부"가 아니라 "애초에 스크립트가 계산할 필요 없음"으로 정리됨 — Phase 5 최신 내용 참고.
- 위험 11 "Confidence score 및 threshold" — 패턴 매칭 완화책으로 언급되지만 `l1-log-analyzer.sh` 스펙 어디에도 정의되지 않음 → Phase 3 작업 항목에 구체적 산식으로 추가하거나 삭제. **(CR-8로 재해결)**: 로그 분석 자체가 스크립트가 아니라 LLM CoT로 전환되면서 "confidence score 산식"이라는 개념 자체가 무의미해짐 — 위험 목록 11번 최신 내용 참고.
- 위험 14 "Install state에 source hash 기록" — 샘플 `install-state.json` 스키마에 `source_hash` 필드가 없다 → 스키마와 `write_install_state()`에 실제로 추가(아래 Phase 7 수정 참고).
- Installer 규칙 "설치 실패 시 partial cleanup 수행" — 샘플 `install.sh`에 `trap`/에러 시 롤백 로직이 없다 → Phase 7에 명시적 작업 항목으로 추가.
- `install-state.json`의 `files_created: []`, `files_modified: []`는 스키마 설명상 uninstaller가 참조한다고 되어 있지만, 실제 `uninstall_claude_code()`/`uninstall_opencode()`는 `installations[].target`만 사용하고 이 두 필드는 항상 빈 배열로 하드코딩되어 아무도 채우거나 읽지 않는 죽은 필드였다. CR-1의 hook/command 등록이 추가되면 이 필드가 **실제로 필요**해지므로(등록된 커맨드 파일, settings.json 내 병합된 hook 항목을 추적해야 함) Phase 7에서 진짜 구현 대상으로 승격한다.

### CR-7 (신규) — `.omc/skills/`는 OpenCode 경로가 아니다: "OMC"와 "OpenCode"를 혼동한 명명 오류

- **문제**: 기존 문서는 설치 대상 표에서 `.omc/skills/l1-log-analysis/`를 "OpenCode (OMC)"라고 표기했다. 이는 두 가지 서로 다른 이름을 하나로 착각한 것이다:
  - **OMC** = `oh-my-claudecode` — **Claude Code 전용** plugin. 이 프로젝트에도 이미 설치되어 있으며(`~/.claude/plugins/cache/omc/oh-my-claudecode/`), `.omc/`는 이 plugin의 프로젝트별 상태 루트다.
  - **OpenCode** = 별도의 CLI/제품(`opencode` 바이너리, `opencode.json` 설정). 이름이 비슷할 뿐 `.omc/`와 무관하다.
- **근거**:
  - `oh-my-claudecode/src/lib/worktree-paths.ts:46`: `SKILLS: '.omc/skills'` — OMC(Claude Code plugin)의 프로젝트 skill 경로 정의
  - `oh-my-claudecode/src/utils/config-dir.ts:61`: `join(getClaudeConfigDir(), '.omc')` — `getClaudeConfigDir()`는 `~/.claude`를 가리키는 함수. 즉 `.omc/`는 개념적으로 "Claude 쪽 상태"다
  - `oh-my-claudecode`의 skillify/learner 템플릿은 `.omc/skills/<skill-name>.md` — **디렉토리가 아니라 파일 하나**를 생성한다. `hooks/`, `commands/`, `analyzers/` 서브디렉토리를 가진 `l1-log-analysis/`를 통째로 여기 복사해 넣는다는 원래 설계 자체가 이 위치의 실제 규격과 맞지 않는다
  - OpenCode 쪽 실제 프로젝트 skill 경로는 **`.opencode/skills/`**이며(`oh-my-openagent` 번들에서 `.opencode/skills`, `.opencode/command` 경로 확인), `.omc/skills/`와는 완전히 별개의 디렉토리다
- **영향**: 기존 문서대로 `.omc/skills/l1-log-analysis/`에 payload를 복사해도 그것은 "OpenCode 설치"가 아니라 "OMC(Claude Code plugin)의 프로젝트 skill 등록 시도"이며, 형식(디렉토리 vs 단일 파일)도 맞지 않아 OMC의 skill 로더에도 제대로 인식되지 않을 가능성이 크다. OpenCode는 이 경로를 아예 스캔하지 않는다.
- **해결 방향**: 설치 대상을 용어부터 분리한다.
  - Claude Code 자체: `~/.claude/skills/l1-log-analysis/`(payload) + `~/.claude/commands/*.md`(command) + `~/.claude/settings.json`(hook) — CR-1 기준
  - OMC(oh-my-claudecode, 선택 사항): 원한다면 `.omc/skills/l1-log-analysis.md` 단일 파일로 별도 요약본 제공 — 이는 "설명용 skill 등록"일 뿐 loop 기능과 무관
  - OpenCode(Tier 0/Tier 1, CR-3 기준): `.opencode/skills/`, `.opencode/command/`, `opencode.json`의 `plugin` 배열 — Claude Code 대상과는 완전히 다른 파일들
  - 문서 전체에서 "OpenCode (OMC)"라는 표기를 제거하고 세 가지를 명시적으로 구분해 표기한다 (아래 Installation Architecture 표 수정 참고)

### CR-8 (신규, 사용자 지정 — 설계 패러다임 전환) — 로그 분석은 결정론적 스크립트가 아니라 LLM chain-of-thought 추론이어야 한다

- **문제**: 기존 Phase 2/3/4/5는 일관되게 "스크립트가 이슈를 찾아낸다"는 설계였다.
  - Phase 3: `l1-log-analyzer.sh`가 고정 패턴(`"memory leak", "cache miss", "IO error", "OOM killer"`)으로 grep해 이슈를 식별
  - Phase 2: `analysis_config.patterns[]`(고정 패턴 배열), `findings[]`(스크립트가 채우는 구조화 필드)를 상태 스키마로 정의
  - Phase 5(CR-2 1차 해결 방향): Stop hook이 analyzer 스크립트를 호출해 findings를 계산하고 프롬프트 본문에 주입
  - 위험 목록 11번("Confidence score 및 threshold")도 스크립트가 신뢰도를 계산한다는 전제

  이는 "L1 로그 분석 방법론을 LLM에게 주고, LLM이 chain-of-thought로 직접 로그를 읽고 추론하며 이슈를 찾아낸다"는 요구사항과 근본적으로 다른 패러다임이다. 결정론적 grep은 패턴을 미리 다 알고 있어야 하지만, 실제 L1(메모리/캐시/스토리지) 이슈는 처음 보는 로그 조합에서 원인을 추론해야 하는 경우가 많다 — 이게 바로 LLM CoT가 필요한 이유다.

- **해결 방향 (설계 전환)**:
  1. **Phase 3 `l1-log-analyzer.sh`의 역할 축소**: "이슈를 찾아내는 주체"에서 **"LLM이 원하면 Bash로 호출할 수 있는 1차 스캔 보조 도구"**로 격하한다. 예: 알려진 키워드로 후보 라인만 빠르게 좁혀주는 grep 유틸 — 결과를 "찾은 이슈"로 취급하지 않고 "LLM이 검토할 후보"로만 취급. 실제 원인 추론·우선순위·심각도 판단은 전부 LLM이 한다
  2. **Phase 2 상태 스키마 축소**: `analysis_config.patterns[]`, `findings[]` 같은 구조화 필드를 상태 파일 frontmatter에서 제거한다. YAML frontmatter는 원본 ralph-loop처럼 `iteration`, `session_id`, `max_iterations`, `completion_promise`, `started_at`, `log_sources[]`(분석 대상 파일 목록만) 정도의 최소 메타데이터만 유지한다
  3. **"진짜 상태"는 LLM이 직접 쓰는 자유형식 리포트 파일**로 이동: 예 `.claude/l1-log-analysis/report.md`. 이 파일은 매 iteration LLM이 스스로 Read(이전 내용 확인) → 분석 → Write/Edit(갱신)한다. 구조화된 YAML이 아니라 LLM이 CoT로 정리한 markdown(가설, 근거, 확신도, 다음에 확인할 것 등)이 자연스럽다
  4. **Phase 4("Prompt 자동 생성")는 사실상 불필요해진다**: 리포트 파일 자체가 이전 iteration의 결과물이므로, 프롬프트는 "이전 리포트를 확인하고 이어서 분석하라"는 고정 지시만 있으면 된다. 이 프롬프트 지시는 command 템플릿(`commands/l1-log-analysis.md`)에 정적으로 작성한다 — Phase 4를 별도 Phase로 두지 않고 Phase 6(Command 정의)에 흡수한다
  5. **완료 조건도 LLM 자기평가로 전환**: "N iteration 동안 신규 이슈 미발견 시 종료" 같은 조건을 스크립트가 카운트하는 대신, completion-promise 문구 자체를 LLM이 판단할 수 있는 형태로 설계한다. 예: `--completion-promise "최근 3회 연속 iteration에서 리포트에 새로운 이슈를 추가하지 않았고, 기존 이슈에 대한 해결 방안까지 모두 작성했다"`. 이건 원본 ralph-loop의 `<promise>` 메커니즘을 그대로 쓰면서 CoT 철학과도 맞는다 — 원본 stop-hook.sh의 `<promise>` 텍스트 비교 로직은 수정 없이 재사용 가능
  6. **Command/Skill 프롬프트에 "로그 분석 방법론" 섹션 필수 추가**: `commands/l1-log-analysis.md`(또는 병행하는 `SKILL.md`)에 다음을 명시한다 — 어떤 카테고리를 우선 확인할지(메모리 누수, 캐시 미스, IO 에러, OOM 등은 "예시"로만 제공하고 목록에 없는 패턴도 찾도록 유도), 가설-검증 순서, 언제 "확신 있음"으로 리포트에 기록할지, 리포트 파일 갱신 형식. 이건 Phase 6의 신규 작업 항목이다 (아래 Phase 6 수정 참고)

- **CR-2와의 관계**: CR-2가 지적한 "원본 stop-hook은 프롬프트 본문을 그대로 재사용해 Phase 4와 충돌한다"는 문제 자체가, CR-8 설계 전환으로 **자연히 해소**된다. LLM이 직접 쓰는 리포트 파일이 상태를 담당하므로, 프롬프트 본문이 고정이어도 문제없다 — Phase 5의 "원자적 본문 재생성" 필수 항목은 삭제한다.

- **영향받는 Phase**: Phase 2(스키마 축소), Phase 3(analyzer 스크립트 역할 축소), Phase 4(제거 — Phase 6에 흡수), Phase 5(CR-2 관련 필수 항목 삭제), Phase 6(방법론 프롬프트 추가). 각 Phase 절에 `[CR-8]` 태그로 반영했다.
- **4차 확장 (2026-07-19)**: 단일 LLM이 리포트 하나를 쓰는 모델을 넘어, 8개 역할(문제 파악/timeline 검증/orchestration/router/log 분석/verifier/aggregator/report 작성)로 나뉜 Multi-Agent Pipeline으로 구체화했다. 뼈대 설계는 "핵심 메커니즘" 절의 "CR-8 확장: Multi-Agent Pipeline 뼈대 설계" 참고 — `report_path` 단일 파일은 `pipeline_dir` + `manifest.json`으로, "방법론 섹션"은 `playbooks/` 라이브러리로 확장되었다.

### 반영 방식

이 섹션에서 식별한 결함은 아래 각 절(핵심 요구사항, 구조, Installation Architecture, Phase 정의, 위험 요소, 테스트 계획)에 직접 반영했다. 각 수정 지점에는 `[CR-n]` 태그로 이 섹션과 연결해 두었다.

## 핵심 요구사항

1. **Platfrom 호환성**
   - **Claude Code** (Claude CLI/Desktop) 지원
   - **OpenCode** 지원 — `[CR-3][CR-7]` **주의**: OpenCode는 Claude Code와 완전히 다른 plugin/hook 메커니즘(JS/TS `event` API, `opencode.json` 등록)을 쓰며, "OMC"(`oh-my-claudecode`, `.omc/`)와 "OpenCode"는 별개다. Tier 0(bare OpenCode)용 신규 구현 없이는 이 요구사항이 충족되지 않는다 — Phase -1 검증 결과에 따라 범위를 확정한다 (자세한 내용은 "적대적 검토 결과"의 CR-3/CR-7 참고)
   - 두 플랫폼 간 호환되는 설치/삭제 프로세스 — 위와 동일한 이유로 "동일한 설치 로직 재사용"은 어렵고, 플랫폼별로 별도 로직이 필요함을 전제한다

2. **Installation/Uninstallation**
   - Windows, WSL 각각 별도 installer 구현
   - `install.sh` (WSL/Linux/Mac)
   - `install.ps1` (Windows PowerShell)
   - `uninstall.sh` (WSL/Linux/Mac)
   - `uninstall.ps1` (Windows PowerShell)
   - **Installer ↔ Uninstaller 짝 맞춤 원칙**
     - Installer가 설치한 것만 Uninstaller가 제거
     - Uninstaller는 Installer가 설치하지 않은 것을 제거하지 않음
     - State tracking을 통한 설치 기록 관리

3. **ralph-loop 기본 동작 유지**
   - 세션이 종료되려 할 때 자동으로 차단하고 동일 prompt 다시 feed
   - 무한 loop 실행 (max-iterations 또는 completion-promise로 종료)
   - State 파일을 통한 iteration 추적

4. **L1 Log Analysis 특화 기능**
   - 로그 파일 자동 감지 및 분석
   - 패턴 기반 이슈 식별
   - 반복 분석을 통한 이슈 정교화
   - 분석 결과 지속적 업데이트

5. **Pipeline 통합**
   - opencode skill 시스템과 호환
   - Claude Code skill 시스템과 호환
   - 다른 skill들과 연동 가능한 pipeline 형태

## 구조

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
├── install/
│   ├── install.sh                     # WSL/Linux/Mac installer
│   ├── install.ps1                    # Windows PowerShell installer
│   ├── uninstall.sh                   # WSL/Linux/Mac uninstaller
│   ├── uninstall.ps1                  # Windows PowerShell uninstaller
│   ├── install-state.json             # 설치 상태 기록 (제거용)
│   └── install-common.sh              # 공통 설치 로직
└── README.md                          # 사용자 documentation
```

> **[CR-1]** 이전 초안에는 `.claude/`, `.omc/skills/`가 "설치 위치 (symlink)"로 표기되어 있었으나, 이 문서는 symlink를 쓰지 않기로 확정했고(사용자 결정), 애초에 이 두 경로는 이 저장소(source) 안에 존재하는 디렉토리가 아니라 **설치 대상 머신의 홈/프로젝트 경로**(`~/.claude/skills/...`, `<프로젝트>/.omc/skills/...`)이므로 소스 트리 구조도에 넣는 것 자체가 오해를 유발한다. 설치 대상 경로는 아래 "Installation Architecture" 절의 표로 분리했다.

## Installation Architecture

### 설치 위치

**[CR-1][CR-3][CR-7]** 복사만으로는 hook/command가 동작하지 않으므로 "payload 복사"와 "등록(registration)"을 별개 대상으로 나눈다. 또한 **"OMC"(oh-my-claudecode, Claude Code plugin)와 "OpenCode"(별도 제품)는 서로 다른 것**이며 설치 대상도 완전히 다르므로 표를 셋으로 분리한다(CR-7).

**1) Claude Code (bare, plugin 없이 동작해야 함 — 이 문서의 핵심 대상)**

| 대상 | 설치 경로 | 방식 | 비고 |
|------|----------|------|------|
| Payload | `~/.claude/skills/l1-log-analysis/` | Copy | scripts/analyzers/templates/hook 스크립트 본체 |
| Command 등록 | `~/.claude/commands/l1-log-analysis.md`, `~/.claude/commands/cancel-l1-log-analysis.md` | Copy + 경로 치환 | `${CLAUDE_PLUGIN_ROOT}` → payload 절대경로로 설치 시점에 치환. **[부록: Skill vs Command]** loop 실행에는 skill이 아니라 command 등록이 필수 |
| Stop Hook 등록 | `~/.claude/settings.json` (`hooks.Stop` 배열에 병합) | JSON 병합 (jq) | 기존 `settings.json` 백업 후 병합. `command` 값은 payload 내 `stop-hook.sh` 절대경로 |

**2) OMC (`oh-my-claudecode`, Claude Code plugin — 선택 사항, loop와 무관) `[CR-7]`**

| 대상 | 설치 경로 | 방식 | 비고 |
|------|----------|------|------|
| 설명용 skill (선택) | `.omc/skills/l1-log-analysis.md` | Copy (단일 파일) | **디렉토리가 아니라 파일 하나**. OMC의 skill 로더 규격에 맞춤. hook/command와 무관하게 "이런 기능이 있다"는 설명만 제공 — loop 실행 경로가 아님 |

**3) OpenCode (별도 제품 — Tier 1 전용, 확정) `[CR-3 결정]`**

Tier 0(bare OpenCode 네이티브 plugin)는 이번 범위에서 제외한다. OpenCode 지원은 아래 한 가지 경로만 취급한다:

| 대상 | 설치 경로 | 방식 | 비고 |
|------|----------|------|------|
| 별도 설치 없음 | — | — | Claude Code용으로 설치한 payload/command/hook(위 1번 표)이 그대로 재사용됨 |
| 전제 조건 | `oh-my-openagent`(Claude Code 호환 기능 포함)가 사용자 OpenCode 환경에 설치되어 있어야 함 | 하드 의존 | `claude-code-compat-core`가 `~/.claude/settings.json`을 읽어 동일한 stdin 스키마로 우리 `stop-hook.sh`를 호출 (§CR-3 3차 검증 근거) |
| Installer의 역할 | OpenCode 감지 시 `oh-my-openagent` 설치 여부 확인, 없으면 안내 메시지만 출력 (에러 아님) | — | Phase 7에 반영 |

`.opencode/skills/`, `.opencode/command/`, 네이티브 `@opencode-ai/plugin` 작성은 Tier 0 백로그로 남기며 이번 구현 대상이 아니다.

### Installation Strategy

**기본 전략**: Copy + 명시적 등록 (symlink 미사용, 확정)

```bash
# 1) Payload 복사 (Claude Code)
cp -r ${PROJECT_ROOT}/l1-log-analysis ~/.claude/skills/l1-log-analysis

# 1') Payload 복사 (OpenCode, 프로젝트별)
cp -r ${PROJECT_ROOT}/l1-log-analysis ${PROJECT_ROOT}/.omc/skills/l1-log-analysis

# 2) Command 등록 — ${CLAUDE_PLUGIN_ROOT}를 payload 절대경로로 치환한 뒤 복사 [CR-1]
sed "s|\${CLAUDE_PLUGIN_ROOT}|$HOME/.claude/skills/l1-log-analysis|g" \
  "$SKILL_DIR/commands/l1-log-analysis.md" > ~/.claude/commands/l1-log-analysis.md
sed "s|\${CLAUDE_PLUGIN_ROOT}|$HOME/.claude/skills/l1-log-analysis|g" \
  "$SKILL_DIR/commands/cancel-l1-log-analysis.md" > ~/.claude/commands/cancel-l1-log-analysis.md

# 3) Stop Hook 등록 — settings.json에 병합 (jq, 기존 파일 백업) [CR-1]
#    상세 구현은 Phase 7 "register_hooks_and_commands()" 참고
```

**복사 이유**:
- 플랫폼 간 symlink 호환성 문제 회피
- Windows에서 symlink 생성 시 admin 권한 필요
- 사용자가 원본 소스를 수정해도 설치된 skill에 영향 없음
- 각 플랫폼별 독립적인 버전 관리 가능

**복사만으로 부족한 이유 [CR-1]**: Claude Code는 `~/.claude/skills/**`를 스캔해 hook이나 슬래시 커맨드를 자동 등록하지 않는다. hook은 `settings.json`의 `hooks` 키(또는 정식 plugin 등록)를 통해서만, 슬래시 커맨드는 `~/.claude/commands/*.md`(또는 정식 plugin의 `commands/`)를 통해서만 인식된다. 따라서 위 2), 3) 단계는 선택 사항이 아니라 loop 기능이 동작하기 위한 필수 단계다.

### Installer ↔ Uninstaller 짝 맞춤 원칙

#### 1. State Tracking (install-state.json)

Installer는 설치 시 모든 변경 사항을 기록합니다:

```json
{
  "version": "1.0.0",
  "installed_at": "2026-07-17T10:00:00Z",
  "install_mode": "copy",
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

**[CR-1][CR-6]** 이전 초안에서 `hooks_installed`/`files_created`/`files_modified`는 스키마에만 존재하고 `write_install_state()`가 항상 빈 배열로 채우는 죽은 필드였다. Command/Hook 등록이 실제 구현 대상이 된 이상 이 세 필드는 uninstaller가 되돌려야 할 대상의 **유일한 출처**이므로 실제 값으로 채워야 한다. `source_hash`도 마찬가지로 스키마에 추가하고 `sha256sum -- "$SKILL_DIR" | cut -d' ' -f1`(디렉토리는 `tar cf - "$SKILL_DIR" | sha256sum` 등으로 계산)로 실제 계산해 기록한다 — 이전 초안은 위험 목록에서만 "source hash 기록"을 언급하고 스키마/스크립트 어디에도 구현하지 않았다.

#### 2. Installer 규칙

- 설치 전 `install-state.json` 존재 확인 → 존재하면 error 후 중단
- 설치 시 모든 파일/디렉토리 생성/변경을 기록
- 설치 실패 시 partial cleanup 수행
- 설치 완료 시 `install-state.json` 저장

#### 3. Uninstaller 규칙

- `install-state.json` 존재 확인 → 없으면 error 후 중단
- 기록된 내용만 제거:
  - `installations[].target`에서 파일/디렉토리 제거
  - `files_created[]`의 파일만 제거
  - `files_modified[]`는 복원하지 않음 (원본 백업 없음)
- **절대 기록되지 않은 것을 제거하지 않음**
- 제거 완료 후 `install-state.json` 삭제

#### 4. Safety Checks

Installer:
```bash
# 이미 설치되어 있는지 확인
if [ -f install-state.json ]; then
  echo "Error: Already installed. Run uninstall first."
  exit 1
fi

# Symlink 대상이 이미 존재하는지 확인
if [ -e ~/.claude/skills/l1-log-analysis ]; then
  echo "Error: Target already exists. Remove manually first."
  exit 1
fi
```

Uninstaller:
```bash
# 설치 기록 확인
if [ ! -f install-state.json ]; then
  echo "Error: Not installed (install-state.json not found)."
  exit 1
fi

# 기록된 설치만 제거
if [ "${installations[claude_code][installed]}" = "true" ]; then
  rm -rf "${installations[claude_code][target]}"
fi
```

## 구현 단계

### Phase -1: 아키텍처 검증 스파이크 (신규) `[CR-1][CR-3][CR-7]`
**목표**: Phase 0 착수 전, 이 계획의 핵심 가정을 실제 환경에서 검증한다. CR-1/CR-3/CR-7 중 Claude Code 쪽(settings.json hook, commands 디렉토리)은 이미 소스 근거로 검증됨 — 아래는 **실기 재현**과 **OpenCode 쪽 남은 미확인 항목**이다.

**Claude Code (재현 검증)**
- [ ] `~/.claude/settings.json`의 `hooks.Stop` 배열에 수동으로 항목을 추가하고, 실제 세션 종료 시 해당 커맨드가 호출되어 `decision: block`으로 종료를 막는지 최소 재현으로 확인
- [ ] `~/.claude/commands/`에 임의의 `.md` 커맨드 파일을 두고 `/커맨드이름`으로 인식되는지 확인 (plugin 없이)

**OpenCode (Tier 1만 — `oh-my-openagent` 의존, 확정된 범위)** `[CR-3 결정]`
- [ ] `oh-my-openagent`(Claude Code 호환 기능 포함)가 설치된 환경에서 `~/.claude/settings.json`에 CR-1 방식으로 병합한 `hooks.Stop` 항목이 `claude-code-compat-core`를 통해 실제로 OpenCode 세션에서도 발동하는지 실기로 확인
- [ ] `~/.claude/commands/l1-log-analysis.md`가 OpenCode 세션에서도 `/l1-log-analysis`로 인식되는지 확인 (compat 레이어가 command도 스캔하는지는 아직 미확인 — hook만 확인된 상태이므로 별도 검증 필요)
- [ ] `oh-my-openagent` 미설치 환경(bare OpenCode)에서 installer가 안내 메시지만 출력하고 정상 종료하는지 확인 (Tier 0는 범위 밖이므로 에러가 아니라 안내여야 함)
- [ ] 사용자가 관찰한 "OpenCode에서 `/ralph-loop` 동작"이 `oh-my-openagent`의 독자 재구현(`dist/hooks/ralph-loop/*`)에 의한 것임을 최종 확인 — 우리 skill과는 별개라는 점을 README/사용자 안내에 명시

- [ ] 위 결과를 이 문서의 CR-1/CR-3/CR-7 절에 검증 결과로 반영(성공/실패, 재현 커맨드 기록)

**Tier 0(bare OpenCode 네이티브 plugin)는 이번 범위에서 제외**하기로 확정했으므로 (CR-3 "결정" 참고) Phase -1에서 검증하지 않는다. 후속 작업으로만 백로그에 남긴다.

**검증 실패 시**: Claude Code 항목이 실패하면 Phase 0 이후 전체 일정 재검토 대상. OpenCode Tier 1 항목이 실패하면 "OpenCode 지원"을 이번 릴리스에서 완전히 제외하고 Claude Code 전용으로 문서를 확정한다.

### Phase 0: Project Structure 설정
- [ ] 기본 디렉토리 구조 생성
- [ ] `l1-log-analysis/` 디렉토리로 skill 구조 분리

### Phase 1: ralph-loop 베이스 복사
- [ ] ralph-loop 전체 구조 복사
- [ ] 이름 변경: ralph → l1-log-analysis
- [ ] 기본 동작 확인

### Phase 2: State 파일 확장 `[CR-8 — 스키마 축소]`
- [ ] ralph-loop.local.md → l1-log-analysis.local.md
- [ ] 추가 필드 (CR-8 반영 — `analysis_config`/`findings[]` 등 구조화 필드는 **제거**, 최소 메타데이터만 유지):
  - `log_sources[]`: 분석 대상 로그 파일 목록
  - `report_path`: LLM이 직접 읽고 쓰는 리포트 파일 경로 (예: `.claude/l1-log-analysis/report.md`) — "진짜 상태"는 이 파일에 있고, frontmatter는 위치만 가리킴
  - ~~`analysis_config`~~, ~~`findings[]`~~, ~~`analysis_iterations`~~: **삭제**. 이 필드들은 스크립트가 패턴 매칭 결과를 구조화해 채운다는 전제였는데, CR-8에서 로그 분석을 LLM CoT로 전환하면서 전제가 사라짐. LLM의 분석 내용은 `report_path`가 가리키는 자유형식 markdown에 담긴다
- [ ] `[CR-6]` `setup-l1-log-analysis.sh`의 `MAX_ITERATIONS` 기본값을 원본 ralph-loop의 `0`(무제한)에서 `50`으로 오버라이드 (위험 목록 1번 완화책을 실제로 구현)
- [ ] `[CR-4]` setup 스크립트 시작부에 `[[ -f "$STATE_FILE" ]]`이면 "이미 활성 loop가 있습니다" 에러 후 `exit 1`하는 가드 추가 (기존 활성 loop 조용히 덮어쓰기 방지)

### Phase 3: 로그 스캔 보조 도구 (Log Analysis → CoT 전환) `[CR-8 — 역할 축소]`
**주의**: 이 Phase의 이름과 역할이 CR-8로 바뀌었다. `l1-log-analyzer.sh`는 더 이상 "이슈를 찾아내는 주체"가 아니라, LLM이 필요하면 Bash로 호출하는 **1차 스캔 보조 도구**다. 실제 원인 추론·우선순위·심각도 판단은 전부 LLM이 command 프롬프트의 "로그 분석 방법론"(Phase 6)을 참고해 chain-of-thought로 수행한다.

- [ ] `l1-log-analyzer.sh` 구현 (보조 도구로 범위 축소)
  - 로그 파일 자동 감지 (/var/log/, /tmp/, 지정 경로)
  - 알려진 키워드로 **후보 라인만** 빠르게 추려주는 grep 유틸 (memory leak, cache miss, IO error 등은 "예시 키워드"로만 제공 — 목록에 없는 패턴도 LLM이 직접 읽으며 찾아야 함)
  - ~~이슈 식별 및 우선순위 부여~~: **삭제** — 이건 LLM의 역할
- [ ] `[CR-8]` 스크립트 출력은 "찾은 이슈"가 아니라 "LLM이 검토할 후보 라인 목록"으로 명명하고 문서화한다
- [ ] ~~분석 결과 report 생성~~: **삭제, LLM이 직접 담당**. 리포트(`report_path`)는 스크립트가 아니라 LLM이 매 iteration Read/Write로 직접 작성·갱신한다

### Phase 4: (삭제됨 — Phase 6에 흡수) `[CR-8]`
~~Prompt 자동 생성~~은 별도 Phase로 두지 않는다. CR-8 설계 전환으로, 이전 iteration과의 연속성은 LLM이 직접 쓰는 리포트 파일(`report_path`)이 담당하므로, 프롬프트는 "이전 리포트를 Read하고 이어서 분석하라"는 **고정 지시**만 있으면 충분하다. 이 고정 지시는 Phase 6(Command 정의)의 command 템플릿에 정적으로 작성한다.

(1차 초안에서 있었던 "이전 분석 결과 기반으로 다음 prompt 생성", "발견된 이슈를 context에 포함", "중복 이슈 제거 및 신규 이슈 식별" 항목은 전부 스크립트가 findings를 계산해 프롬프트에 주입한다는 전제였고, CR-8로 그 전제가 사라지면서 불필요해졌다.)

### Phase 5: Stop Hook 확장
- [ ] 기본 ralph-loop stop-hook **거의 그대로 유지** — `[CR-8]` CR-2가 요구했던 "iteration 갱신과 같은 원자적 쓰기 안에서 프롬프트 본문 재생성" 항목은 **삭제**한다. LLM이 직접 쓰는 리포트 파일이 상태를 담당하므로, 원본처럼 `iteration:` 필드만 갱신하고 프롬프트 본문(고정 지시)은 그대로 재사용해도 된다 (CR-8/CR-2 2차 해결 방향 참고)
- [ ] `[CR-1]` **(필수)** Stop hook은 skill 디렉토리 내부 `hooks.json`을 두는 것만으로는 호출되지 않는다 — 설치 시 `~/.claude/settings.json`의 `hooks.Stop` 배열에 병합 등록해야 실제로 실행된다 (Phase 7 참고)
- [ ] `[CR-8]` 종료 조건은 스크립트 계산이 아니라 **LLM 자기평가**로 전환: `--completion-promise`에 "리포트 갱신이 최근 N iteration 동안 없었고, 모든 이슈에 해결 방안까지 작성됨" 같은 LLM이 판단 가능한 문구를 쓰도록 유도. 원본 stop-hook의 `<promise>` 텍스트 비교 로직(`stop-hook.sh:129-142`)은 **수정 없이 그대로 재사용**한다
  - ~~모든 이슈 해결 확인~~, ~~새로운 이슈 N iteration 미발견~~: 별도 스크립트 로직으로 만들지 않는다 — 위 completion-promise 문구로 LLM이 스스로 판단
  - 사용자 명시적 중지: `--max-iterations` 도달 시 원본 그대로 강제 종료 (변경 없음)

### Phase 6: Command 정의 (Phase 4 흡수 + 방법론 프롬프트 신규) `[CR-8]`
- [ ] `/l1-log-analysis <log-paths> [options]`
  - `--pattern <pattern>`: `[CR-8]` **의미 변경** — 스크립트가 이 패턴으로만 grep해서 필터링하는 게 아니라, "우선 확인해볼 키워드 힌트"로 LLM에게 전달됨. 지정하지 않아도 LLM이 알아서 넓게 탐색
  - `--since <time>`: 시간 범위 지정 (로그 소스 필터링용, 유지)
  - `--severity <level>`: `[CR-8]` **의미 변경** — 스크립트가 계산하는 필터가 아니라 LLM에게 주는 "이 정도 심각도부터 리포트에 기록해라" 기준
  - `--max-findings <n>`: 리포트에 기록할 이슈 개수 상한 (LLM에게 주는 가이드라인)
- [ ] `[CR-1]` 커맨드 프론트매터의 `allowed-tools`와 본문 스크립트 경로에 쓰인 `${CLAUDE_PLUGIN_ROOT}`를 제거하고, 설치 시점에 payload 절대경로(`~/.claude/skills/l1-log-analysis`)로 치환한 뒤 `~/.claude/commands/`에 설치하는 것을 전제로 커맨드 템플릿 작성 (plugin 컨텍스트가 없으므로 `${CLAUDE_PLUGIN_ROOT}`는 설치 후 빈 값이 되어 깨진다)
- [ ] `[CR-8]` **신규 — "L1 로그 분석 방법론" 섹션을 command 프롬프트 본문에 명시적으로 작성**:
  - 우선 확인할 카테고리 예시(메모리 누수, 캐시 미스, IO 에러, OOM 등)를 "예시일 뿐, 이 목록에 없는 패턴도 찾아야 한다"는 문구와 함께 제공
  - 가설 → 근거 수집(로그 라인 인용) → 확신도 판단의 CoT 순서를 지시
  - `report_path`(`.claude/l1-log-analysis/report.md`)가 있으면 먼저 Read해서 이어서 작업, 없으면 새로 작성하라는 고정 지시 (Phase 4가 하려던 일을 이 정적 지시문이 대체)
  - completion-promise 판단 기준을 LLM이 이해할 수 있는 자연어로 예시 제공 (Phase 5 참고)
- [ ] `[CR-8]` `l1-log-analyzer.sh`(Phase 3) 호출은 "선택 사항"임을 프롬프트에 명시 — LLM이 필요하다고 판단하면 Bash로 호출, 아니면 직접 Read/Grep으로 로그를 봐도 됨

### Phase 7: Install Infrastructure
- [ ] `install/install-common.sh`: 공통 설치 로직
  - 플랫폼 감지 (Claude Code vs OpenCode)
  - Copy 모드 결정 (symlink 미사용, 확정)
  - 설치 경로 탐지
  - `install-state.json` 생성/관리
  - `[CR-6]` 소스 디렉토리 hash 계산 함수 (`compute_source_hash()`) — 스키마의 `source_hash` 필드를 실제로 채움
- [ ] `install/install.sh`: WSL/Linux/Mac installer
  - 기존 설치 확인
  - `[CR-6]` **jq 사전 체크 추가**: 기존 초안은 `uninstall.sh`만 jq를 요구하고 `install.sh`는 요구하지 않아 비대칭이었다 — hook 등록에 jq가 필요하므로 install.sh도 시작 시 jq 존재를 확인
  - 권한 체크
  - Payload 복사: Claude Code, OpenCode
  - `[CR-1]` **`register_hooks_and_commands()` 신규 함수**:
    - 커맨드 마크다운 2개를 `${CLAUDE_PLUGIN_ROOT}` → payload 절대경로로 치환하여 `~/.claude/commands/`에 설치, 경로를 `files_created[]`에 기록
    - `~/.claude/settings.json`을 백업(`.bak`)한 뒤 jq로 `hooks.Stop` 배열에 항목 병합, 백업 경로와 병합 내용을 `hooks_installed[]`에 기록, 원본 경로를 `files_modified[]`에 기록
    - `settings.json`이 없으면 새로 생성, 있으면 기존 `hooks.Stop` 배열이 없는 경우/있는 경우를 모두 처리
  - `[CR-6]` **`trap` 기반 partial cleanup**: 복사·등록 도중 임의 단계에서 실패하면 그때까지 만든 파일/등록 항목을 정리하고 비정상 `install-state.json`을 남기지 않음 (기존 초안은 이 문장만 있고 구현이 없었음)
  - 설치 상태 기록 (hooks_installed/files_created/files_modified를 실제 값으로 채움)
- [ ] `install/install.ps1`: Windows PowerShell installer
  - 위 install.sh와 동일한 항목(jq 사전 체크는 PowerShell에서는 `ConvertFrom-Json`/`ConvertTo-Json` 사용으로 대체 가능하므로 불필요 — 대신 `settings.json` 파싱 실패 시 처리 경로 명시)
  - `Register-HooksAndCommands` 함수 (위 `register_hooks_and_commands()`와 동일 역할)
- [ ] `install/uninstall.sh`: WSL/Linux/Mac uninstaller
  - `install-state.json` 확인
  - 기록된 설치만 제거 (payload 디렉토리)
  - `[CR-1]` **`unregister_hooks_and_commands()` 신규 함수**: `files_created[]`에 기록된 커맨드 파일 제거, `hooks_installed[].backup_file`로 `settings.json`을 복원하거나 jq로 해당 hook 항목만 정밀 제거
  - Cleanup
  - State 파일 삭제
- [ ] `install/uninstall.ps1`: Windows PowerShell uninstaller
  - 위 uninstall.sh와 동일 항목 (`Unregister-HooksAndCommands`)

### Phase 8: Integration
- [ ] opencode skill 시스템 등록 테스트
- [ ] Claude Code skill 시스템 등록 테스트
- [ ] 사용자 documentation 작성
- [ ] 테스트 및 검증

## 핵심 메커니즘

### 1. State 파일 구조 (YAML Frontmatter)

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

[사용자 prompt 또는 자동 생성된 prompt]
```

### 2. Stop Hook Flow `[CR-8 반영 — 스크립트 분석/State 업데이트 단계 삭제]`

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
[Completion Promise 체크] ← LLM이 리포트 파일 갱신을 마치고 스스로 판단해 출력한 <promise> 확인 (CR-8: 스크립트 계산 아님)
    ↓
[미완료 시 동일한 고정 Prompt 재feed] ← [CR-8] "다음 prompt 생성" 단계 삭제. 연속성은 LLM이 쓴 리포트 파일이 담당
    ↓
[JSON 반환: block decision + prompt 재feed]
```

이전 초안에 있던 "로그 분석 실행"과 "이슈 발견 시 State 업데이트" 단계는 삭제되었다 — 그건 Stop hook(스크립트)이 아니라 **세션 안의 LLM**이 매 iteration 직접 하는 일이며, Stop hook의 책임 범위 밖이다.

### 3. 로그 분석 루프 `[CR-8 반영 — "자동 prompt"가 아니라 manifest.json 기반 orchestrator 루프]`

**주의**: 아래 예시는 CR-8 최초안(단일 `report.md`)을 사용자 요청(2026-07-19, 4차)에 따라 **Multi-Agent Pipeline**으로 확장한 최신 버전이다. 상세 설계는 바로 아래 "CR-8 확장: Multi-Agent Pipeline 뼈대 설계" 절 참고.

```
Iteration 1:
  - 고정 prompt: "/l1-log-analysis /var/log/kernel.log 를 분석하라. .claude/l1-log-analysis/<run-id>/manifest.json 이 없으면 새로 만들고,
    있으면 Read해서 orchestrator로서 다음 미완료 stage를 판단해 해당 subagent를 Task로 호출하라."
  - 메인 세션(=orchestrator)이 manifest.json 생성, 1번째 stage(issue-identification) subagent 호출 → 결과를 manifest.json에 기록

Iteration 2:
  - 동일한 고정 prompt가 재feed됨 (systemMessage로 "iteration 2"만 알려줌)
  - orchestrator가 manifest.json을 Read → 다음 미완료 stage(timeline-verification 또는 그 다음) 확인 → 해당 subagent Task 호출 → manifest.json 갱신

Iteration N:
  - 동일한 고정 prompt 재feed
  - orchestrator가 manifest.json에서 모든 stage가 complete이고 verifier stage가 verified:true인 것을 확인하면 completion-promise를 <promise> 태그로 출력해 loop 종료
  - verifier가 위반을 발견했다면 해당 stage를 needs_rework로 되돌리고 loop 계속 (rework_count 상한으로 무한루프 방지)
```

## CR-8 확장: Multi-Agent Pipeline 뼈대 설계 (2026-07-19, 4차 개정 — 사용자 요청)

사용자가 구상하는 L1 로그 분석 skill은 단일 LLM 턴이 아니라 8개 역할로 나뉜 파이프라인이다:
① 문제점 파악 agent → ② timeline 확인/로그 요약/이슈 시간대 검증 agent → ③ 전체 control을 담당하는 orchestration agent → ④ 여러 playbook 중 분석 방법을 고르는 router agent → ⑤ 실제 로그 분석 agent → ⑥ manifest.json으로 파이프라인 준수 여부를 검사하는 verifier agent → ⑦ 결과를 취합해 결론 내는 aggregator agent → ⑧ report 작성 agent.

이 절은 **각 agent의 내부 로직을 설계하지 않는다** (사용자 지시: "지금 위 agent를 설계할 필요는 없다"). 대신 이 8개 역할이 나중에 하나씩 끼워질 수 있는 **뼈대(skeleton)**가 ralph-loop 구조와 호환되는지, Claude Code/OpenCode(Tier 1) 양쪽에서 실현 가능한지를 확인하고 뼈대만 확정한다.

#### 실현 가능성 판단: 가능 — 두 가지 독립적 근거

1. **Claude Code**: 이 대화(그리고 이 문서를 작성 중인 나 자신)의 `Agent` 툴이 정확히 이 패턴이다 — `subagent_type`으로 프로젝트에 정의된 커스텀 agent(`.claude/agents/*.md` frontmatter: name, description, tools, model)를 호출한다. Orchestrator는 메인 세션 자체이며, 나머지 7개 역할은 메인 세션이 `Agent` 툴로 호출하는 subagent로 자연스럽게 매핑된다. ralph-loop의 Stop hook은 "메인 세션"에만 걸리므로, 메인 세션이 몇 번이고 subagent를 호출하며 여러 iteration에 걸쳐 파이프라인을 진행해도 문제 없다 — Stop hook은 메인 세션이 턴을 끝내려 할 때만 개입한다
2. **OpenCode**: `opencode agent create --mode [all|primary|subagent]`로 확인했듯 OpenCode도 **네이티브로** primary/subagent 개념과 `task` 툴(권한 목록에 `task`가 명시됨)을 갖고 있다. 게다가 `oh-my-openagent`의 compat 레이어에 `loadPluginAgents()` 함수가 있어 Claude Code plugin의 `agents/` 디렉토리를 스캔해 OpenCode로 포팅한다 — hook/command/skill과 같은 급으로 agent도 이미 포팅 대상이다

이 두 근거는 **독립적**이다. OpenCode 자체 agent 포맷(`opencode agent create`가 생성하는 파일)과 Claude Code agent 포맷(`.claude/agents/*.md`)이 완전히 같은 스키마인지는 미확인이지만, Tier 1 전략(오늘 확정)과 일관되게 **agent 정의도 Claude Code 포맷 하나로만 작성하고 `oh-my-openagent`의 `loadPluginAgents()` 포팅에 의존**하는 쪽을 기본 전략으로 채택한다. 이렇게 하면 agent를 두 벌 유지하지 않아도 된다.

#### 뼈대 1: 디렉토리 구조 — `report_path` 단일 파일 → `pipeline_dir` + `manifest.json`으로 확장

CR-8 최초안의 `report_path`(단일 markdown)는 8-agent 파이프라인을 담기엔 부족하다. 아래로 대체한다:

```
.claude/l1-log-analysis/<run-id>/
├── manifest.json                  # 파이프라인 상태 — verifier(⑥)가 검사하는 대상
├── issue.md                       # ①의 산출물
├── timeline.md                    # ②의 산출물 (이슈 시간대가 실제 로그에 있는지 검증 결과 포함)
├── playbook-selection.json        # ④의 산출물 (선택된 playbook 이름 + 선택 근거)
├── analysis-findings.md           # ⑤의 산출물
├── verification-result.json       # ⑥의 산출물 (통과/위반 목록)
├── summary.md                     # ⑦의 산출물
└── report.<format>                # ⑧의 최종 산출물
```

playbook 라이브러리(④가 고르는 대상)는 상태 파일과 별개로 skill payload에 둔다:
```
l1-log-analysis/playbooks/
├── memory-leak.md
├── cache-miss.md
├── io-error.md
└── unknown-pattern.md   # 기존 playbook에 안 맞는 경우를 위한 fallback
```

#### 뼈대 2: `manifest.json` 스키마 (뼈대 수준 — 필드 확정, 내부 로직은 각 agent 설계 시 구체화)

```json
{
  "pipeline_version": 1,
  "run_id": "l1-20260719-103000",
  "log_sources": ["/var/log/kernel.log"],
  "current_stage": "issue-identification",
  "stages": [
    {"id": "issue-identification", "agent": "l1-issue-agent",     "status": "pending", "artifact": "issue.md",                 "rework_count": 0},
    {"id": "timeline-verification", "agent": "l1-timeline-agent",  "status": "pending", "artifact": "timeline.md",              "rework_count": 0},
    {"id": "routing",               "agent": "l1-router-agent",    "status": "pending", "artifact": "playbook-selection.json",  "rework_count": 0},
    {"id": "log-analysis",          "agent": "l1-analysis-agent",  "status": "pending", "artifact": "analysis-findings.md",     "rework_count": 0},
    {"id": "verification",          "agent": "l1-verifier-agent",  "status": "pending", "artifact": "verification-result.json", "rework_count": 0},
    {"id": "aggregation",           "agent": "l1-aggregator-agent","status": "pending", "artifact": "summary.md",               "rework_count": 0},
    {"id": "report",                "agent": "l1-report-agent",    "status": "pending", "artifact": "report.md",                "rework_count": 0}
  ],
  "final_report_path": null
}
```
`status` 값: `pending` / `in_progress` / `complete` / `needs_rework`. orchestration agent(③)는 이 파일 하나만 보고 "다음에 뭘 해야 하는지" 판단한다 — 이게 CR-8의 "상태는 파일에, 프롬프트는 고정"이라는 원칙을 8-agent 파이프라인 규모로 그대로 유지하는 핵심이다.

#### 뼈대 3: Orchestrator(③) 루프 로직 (뼈대 수준 — 매 iteration 이렇게 동작)

1. `manifest.json` Read (없으면 최초 생성)
2. `current_stage` 확인
3. 상태가 `pending`/`needs_rework`면: 해당 stage의 agent를 `Agent` 툴(Claude Code) / `task` 툴(OpenCode)로 호출, 필요한 이전 stage 산출물 경로를 프롬프트에 함께 전달
4. subagent 완료 시: `manifest.json`의 해당 stage `status: complete`, `artifact` 경로 기록, `current_stage`를 다음 stage로 이동
5. `routing`(④) stage 완료 시 `playbook-selection.json`에 적힌 playbook이 `log-analysis`(⑤) 호출 시 참고 자료로 전달됨
6. `verification`(⑥) stage에서 위반 발견 시: 해당 stage(들)를 `needs_rework`로 되돌리고 `rework_count` 증가, `current_stage`를 그 stage로 재설정
7. 모든 stage `complete` && `verification` 통과 && `final_report_path` 존재 → completion-promise 출력

이 로직 전체가 **Stop hook이 재feed하는 고정 프롬프트 한 장**으로 표현 가능하다 (CR-8/CR-2 원칙 유지 — Stop hook 자체는 수정 불필요).

#### Phase 재정의 (뼈대 수준)

- **Phase 2**: `report_path` 필드를 `pipeline_dir`(위 디렉토리 구조 루트)로 교체. `manifest.json`은 별도 파일이지 frontmatter에 넣지 않는다
- **Phase 3**: `l1-log-analyzer.sh`는 ⑤ log-analysis agent가 선택적으로 쓰는 도구로 유지(기존 CR-8 결정과 동일)
- **Phase 6**: "로그 분석 방법론" 단일 섹션 대신 **playbook 라이브러리**(`playbooks/*.md`)로 구조화. Command 프롬프트에는 "manifest.json이 없으면 pipeline_dir와 초기 manifest.json을 만들고 orchestrator로 동작하라"는 고정 지시만 남긴다
- **신규 작업 항목 (Phase 번호 미정, Phase 5~7 사이)**: `.claude/agents/l1-*.md` 8종(또는 필요한 만큼) 스캐폴드 — 이번 Phase에서는 **frontmatter와 placeholder 본문만** 만들고 실제 판단 로직은 후속 작업으로 미룬다 (사용자 지시와 일치)

#### 새 위험 요소 (Multi-Agent Pipeline 관련)

17. **Rework 무한루프**: verifier가 같은 stage를 계속 `needs_rework`로 되돌리면 `--max-iterations`까지 소모하고도 완료 못할 수 있다 → **완화**: `manifest.json`의 stage별 `rework_count`에 상한(예: 3) 설정, 초과 시 orchestrator가 강제로 "미해결" 상태로 report를 작성하고 종료
18. **Iteration당 토큰/비용 폭증**: 하나의 orchestrator 턴 안에서 여러 subagent를 연쇄 호출하면 컨텍스트와 비용이 급격히 늘 수 있다 → **완화**: orchestrator 프롬프트에 "한 iteration에는 최대 1~2개 stage만 진행하고 나머지는 다음 iteration으로 넘겨라"는 지시로 턴당 작업량 제한
19. **OpenCode agent 포맷 미검증**: `.claude/agents/*.md`가 `loadPluginAgents()`를 통해 OpenCode에서 완전히 동일하게 동작하는지(툴 이름 매핑, `task` 호출 시그니처 등) 미확인 → **완화**: Phase -1에 검증 항목 추가 (아래)
20. **manifest.json 동시 쓰기 경합**: 여러 subagent가 동시에(병렬 Task 호출) `manifest.json`을 갱신하려 하면 레이스 컨디션 발생 가능 → **완화**: orchestrator만 `manifest.json`을 쓰고, subagent는 자신의 산출물 파일만 쓴 뒤 결과를 orchestrator에게 리턴하는 방식으로 쓰기 권한을 orchestrator에 집중

#### Phase -1 추가 검증 항목

- [ ] Claude Code에서 `.claude/agents/l1-issue-agent.md`(placeholder) 정의 후 메인 세션이 `Agent` 툴로 실제 호출 가능한지 확인
- [ ] `oh-my-openagent` 설치 환경에서 동일 `.claude/agents/*.md`가 `loadPluginAgents()`를 통해 OpenCode `task` 툴로 호출 가능한지 확인 (Tier 1 범위 내에서 agent 포팅까지 검증)
- [ ] 8-stage 파이프라인 중 최소 1개 stage(예: issue-identification)를 placeholder agent로 만들어 manifest.json 갱신까지 end-to-end 최소 재현

## ralph-loop와의 주요 차이

| 기능 | ralph-loop | l1-log-analysis |
|------|-----------|-----------------|
| 목적 | 일반적인 반복 개발 | L1 로그 분석 특화 |
| Prompt | 사용자 제공 고정 | 자동 생성 (context 기반) |
| State | iteration, promise | + log_sources, findings |
| Stop 조건 | Promise/Max | + 이슈 해결/반복 미발견 |
| Hook | Stop hook만 | + Pre-analysis hook |

## 기술 스택

- **Language**: Bash (scripts/hooks), PowerShell (installers), Markdown (commands)
- **Data Format**: YAML (frontmatter), JSON (hook output, install state)
- **Log Parsing**: grep, awk, sed, jq
- **Pattern Matching**: 정규식, 키워드 매칭
- **Platform Detection**: Shell 변수, PowerShell 환경 변수
- **File Operations**: ln (symlink), cp (copy), rm, jq (JSON parsing)

## Installer/Uninstaller 설계

> **[CR-1][CR-6] 이 절의 코드 샘플은 CR-1 이전 baseline이다.** 아래 `install.sh`/`install.ps1`/`uninstall.sh`/`uninstall.ps1` 샘플은 "payload를 copy한다"는 부분만 구현하고 있으며, Phase 7에서 추가하기로 한 `register_hooks_and_commands()` / `unregister_hooks_and_commands()` / jq 사전 체크 / `source_hash` 계산 / trap 기반 partial cleanup은 **포함되어 있지 않다**. 이 샘플을 그대로 구현 최종본으로 쓰면 CR-1(hook/command 미등록)이 재현된다 — 실제 구현 시 반드시 Phase 7 체크리스트의 신규 함수를 추가해야 한다. 상세 스펙(함수 시그니처, settings.json 병합 로직)은 `implementation-spec.md`에 구체화했다.

### install.sh (WSL/Linux/Mac)

```bash
#!/bin/bash

set -euo pipefail

# Constants
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
INSTALL_STATE_FILE="$SCRIPT_DIR/install-state.json"
SKILL_DIR="$PROJECT_ROOT/l1-log-analysis"

# Detect Claude Code and OpenCode paths
CLAUDE_SKILLS_DIR="${HOME}/.claude/skills"
OMC_SKILLS_DIR="${PROJECT_ROOT}/.omc/skills"

# Function: Detect if Claude Code is installed
detect_claude_code() {
  if [ -d "$CLAUDE_SKILLS_DIR" ]; then
    return 0
  fi
  return 1
}

# Function: Detect if OpenCode is installed
detect_opencode() {
  if [ -d "$PROJECT_ROOT/.omc" ] || command -v omc &> /dev/null; then
    return 0
  fi
  return 1
}

# Function: Check if already installed
check_not_installed() {
  if [ -f "$INSTALL_STATE_FILE" ]; then
    echo "❌ Error: Already installed."
    echo "   Run ./install/uninstall.sh first to remove existing installation."
    exit 1
  fi
}

# Function: Check if skill source exists
check_skill_source() {
  if [ ! -d "$SKILL_DIR" ]; then
    echo "❌ Error: Skill source not found at $SKILL_DIR"
    echo "   Build the skill first."
    exit 1
  fi
}

# Function: Install to Claude Code
install_to_claude_code() {
  local target_dir="$CLAUDE_SKILLS_DIR/l1-log-analysis"
  local install_result="false"

  echo "📦 Installing to Claude Code..."

  # Check if target exists
  if [ -e "$target_dir" ]; then
    echo "⚠️  Warning: Target already exists at $target_dir"
    echo "   Skipping Claude Code installation."
    install_result="false"
  else
    # Copy to target
    if cp -r "$SKILL_DIR" "$target_dir"; then
      install_result="true"
      echo "   ✓ Copied to: $target_dir"
    else
      echo "   ❌ Failed to install to Claude Code"
      install_result="false"
    fi
  fi

  # Output result for JSON capture
  echo "CLAUDE_CODE_INSTALL_RESULT:$install_result:copy:$target_dir"
}

# Function: Install to OpenCode
install_to_opencode() {
  local target_dir="$OMC_SKILLS_DIR/l1-log-analysis"
  local install_result="false"

  echo "📦 Installing to OpenCode..."

  # Create .omc/skills directory if needed
  mkdir -p "$OMC_SKILLS_DIR"

  # Check if target exists
  if [ -e "$target_dir" ]; then
    echo "⚠️  Warning: Target already exists at $target_dir"
    echo "   Skipping OpenCode installation."
    install_result="false"
  else
    # Copy to target
    if cp -r "$SKILL_DIR" "$target_dir"; then
      install_result="true"
      echo "   ✓ Copied to: $target_dir"
    else
      echo "   ❌ Failed to install to OpenCode"
      install_result="false"
    fi
  fi

  # Output result for JSON capture
  echo "OMC_INSTALL_RESULT:$install_result:copy:$target_dir"
}

# Function: Write install state
write_install_state() {
  local claude_installed="${1:-false}"
  local claude_type="${2:-}"
  local claude_target="${3:-}"
  local omc_installed="${4:-false}"
  local omc_type="${5:-}"
  local omc_target="${6:-}"

  cat > "$INSTALL_STATE_FILE" << EOF
{
  "version": "1.0.0",
  "installed_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "install_mode": "copy",
  "platform": "$(uname -s)",
  "installations": {
    "claude_code": {
      "target": "$claude_target",
      "source": "$SKILL_DIR",
      "type": "copy",
      "installed": $claude_installed,
      "verified": $claude_installed
    },
    "omc": {
      "target": "$omc_target",
      "source": "$SKILL_DIR",
      "type": "copy",
      "installed": $omc_installed,
      "verified": $omc_installed
    }
  },
  "hooks_installed": [],
  "files_created": [],
  "files_modified": []
}
EOF

  echo "✓ Install state written to: $INSTALL_STATE_FILE"
}

# Main installation flow
main() {
  echo "🚀 L1 Log Analysis Skill Installer"
  echo "====================================="
  echo ""

  # Pre-checks
  check_not_installed
  check_skill_source

  # Detect platforms
  echo "🔍 Detecting platforms..."
  local has_claude_code=false
  local has_opencode=false

  if detect_claude_code; then
    echo "   ✓ Claude Code detected"
    has_claude_code=true
  else
    echo "   ℹ️  Claude Code not found"
  fi

  if detect_opencode; then
    echo "   ✓ OpenCode detected"
    has_opencode=true
  else
    echo "   ℹ️  OpenCode not found"
  fi

  echo ""

  # Install to platforms
  local claude_result=false
  local claude_target=""
  local omc_result=false
  local omc_target=""

  if [ "$has_claude_code" = true ]; then
    local output
    output=$(install_to_claude_code)
    echo "$output"

    # Parse result
    if echo "$output" | grep -q "CLAUDE_CODE_INSTALL_RESULT:true"; then
      claude_result=true
      claude_target=$(echo "$output" | grep "CLAUDE_CODE_INSTALL_RESULT:" | cut -d: -f4)
    fi
  fi

  if [ "$has_opencode" = true ]; then
    local output
    output=$(install_to_opencode)
    echo "$output"

    # Parse result
    if echo "$output" | grep -q "OMC_INSTALL_RESULT:true"; then
      omc_result=true
      omc_target=$(echo "$output" | grep "OMC_INSTALL_RESULT:" | cut -d: -f4)
    fi
  fi

  echo ""

  # Write install state
  write_install_state "$claude_result" "copy" "$claude_target" "$omc_result" "copy" "$omc_target"

  echo ""
  echo "✅ Installation complete!"
  echo ""
  echo "To uninstall: ./install/uninstall.sh"
}

# Run main
main "$@"
```

### install.ps1 (Windows PowerShell)

```powershell
#requires -Version 5.1

param(
    [switch]$Force
)

# Constants
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir
$InstallStateFile = Join-Path $ScriptDir "install-state.json"
$SkillDir = Join-Path $ProjectRoot "l1-log-analysis"

# Detect paths
$ClaudeSkillsDir = Join-Path $env:USERPROFILE ".claude\skills"
$OmSkillsDir = Join-Path $ProjectRoot ".omc\skills"

# Function: Check if already installed
function Test-NotInstalled {
    if (Test-Path $InstallStateFile) {
        Write-Host "❌ Error: Already installed." -ForegroundColor Red
        Write-Host "   Run .\install\uninstall.ps1 first to remove existing installation."
        exit 1
    }
}

# Function: Check if skill source exists
function Test-SkillSource {
    if (-not (Test-Path $SkillDir)) {
        Write-Host "❌ Error: Skill source not found at $SkillDir" -ForegroundColor Red
        Write-Host "   Build the skill first."
        exit 1
    }
}

# Function: Detect if Claude Code is installed
function Test-ClaudeCode {
    return Test-Path $ClaudeSkillsDir
}

# Function: Detect if OpenCode is installed
function Test-OpenCode {
    return (Test-Path (Join-Path $ProjectRoot ".omc")) -or (Get-Command omc -ErrorAction SilentlyContinue)
}

# Function: Create copy (no admin required)
function New-CopyInstall {
    param(
        [string]$Source,
        [string]$Target
    )

    try {
        Copy-Item -Path $Source -Destination $Target -Recurse -Force
        return @{Success=$true; Type="copy"}
    } catch {
        return @{Success=$false; Type=""}
    }
}

# Function: Install to Claude Code
function Install-ClaudeCode {
    param(
        [string]$Source,
        [string]$TargetDir
    )

    Write-Host "📦 Installing to Claude Code..." -ForegroundColor Cyan

    $TargetPath = Join-Path $TargetDir "l1-log-analysis"

    # Check if target exists
    if (Test-Path $TargetPath) {
        Write-Host "⚠️  Warning: Target already exists at $TargetPath" -ForegroundColor Yellow
        Write-Host "   Skipping Claude Code installation."
        return @{Installed=$false; Type=""; Target=""}
    }

    # Create skills directory if needed
    if (-not (Test-Path $TargetDir)) {
        New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null
    }

    # Install using copy
    $result = New-CopyInstall -Source $Source -Target $TargetPath

    if ($result.Success) {
        Write-Host "   ✓ Copy: $TargetPath" -ForegroundColor Green
        return @{Installed=$true; Type="copy"; Target=$TargetPath}
    } else {
        Write-Host "   ❌ Failed to install to Claude Code" -ForegroundColor Red
        return @{Installed=$false; Type=""; Target=""}
    }
}

# Function: Install to OpenCode
function Install-OpenCode {
    param(
        [string]$Source,
        [string]$TargetDir
    )

    Write-Host "📦 Installing to OpenCode..." -ForegroundColor Cyan

    $TargetPath = Join-Path $TargetDir "l1-log-analysis"

    # Create skills directory if needed
    if (-not (Test-Path $TargetDir)) {
        New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null
    }

    # Check if target exists
    if (Test-Path $TargetPath) {
        Write-Host "⚠️  Warning: Target already exists at $TargetPath" -ForegroundColor Yellow
        Write-Host "   Skipping OpenCode installation."
        return @{Installed=$false; Type=""; Target=""}
    }

    # Install using copy
    $result = New-CopyInstall -Source $Source -Target $TargetPath

    if ($result.Success) {
        Write-Host "   ✓ Copy: $TargetPath" -ForegroundColor Green
        return @{Installed=$true; Type="copy"; Target=$TargetPath}
    } else {
        Write-Host "   ❌ Failed to install to OpenCode" -ForegroundColor Red
        return @{Installed=$false; Type=""; Target=""}
    }
}

# Function: Write install state
function Write-InstallState {
    param(
        [bool]$ClaudeInstalled,
        [string]$ClaudeType,
        [string]$ClaudeTarget,
        [bool]$OmInstalled,
        [string]$OmType,
        [string]$OmTarget
    )

    $state = @{
        version = "1.0.0"
        installed_at = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        install_mode = "copy"
        platform = [System.Environment]::OSVersion.Platform
        installations = @{
            claude_code = @{
                target = $ClaudeTarget
                source = $SkillDir
                type = "copy"
                installed = $ClaudeInstalled
                verified = $ClaudeInstalled
            }
            omc = @{
                target = $OmTarget
                source = $SkillDir
                type = "copy"
                installed = $OmInstalled
                verified = $OmInstalled
            }
        }
        hooks_installed = @()
        files_created = @()
        files_modified = @()
    }

    $state | ConvertTo-Json -Depth 10 | Out-File -FilePath $InstallStateFile -Encoding utf8
    Write-Host "✓ Install state written to: $InstallStateFile" -ForegroundColor Green
}

# Main installation flow
function Main {
    Write-Host "🚀 L1 Log Analysis Skill Installer" -ForegroundColor Cyan
    Write-Host "=====================================" -ForegroundColor Cyan
    Write-Host ""

    # Pre-checks
    Test-NotInstalled
    Test-SkillSource

    # Detect platforms
    Write-Host "🔍 Detecting platforms..." -ForegroundColor Cyan
    $hasClaudeCode = Test-ClaudeCode
    $hasOpenCode = Test-OpenCode

    if ($hasClaudeCode) {
        Write-Host "   ✓ Claude Code detected" -ForegroundColor Green
    } else {
        Write-Host "   ℹ️  Claude Code not found" -ForegroundColor Gray
    }

    if ($hasOpenCode) {
        Write-Host "   ✓ OpenCode detected" -ForegroundColor Green
    } else {
        Write-Host "   ℹ️  OpenCode not found" -ForegroundColor Gray
    }

    Write-Host ""

    # Install to platforms
    $claudeResult = @{Installed=$false; Type=""; Target=""}
    $omcResult = @{Installed=$false; Type=""; Target=""}

    if ($hasClaudeCode) {
        $claudeResult = Install-ClaudeCode -Source $SkillDir -TargetDir $ClaudeSkillsDir
        Write-Host ""
    }

    if ($hasOpenCode) {
        $omcResult = Install-OpenCode -Source $SkillDir -TargetDir $OmSkillsDir
        Write-Host ""
    }

    # Write install state
    Write-InstallState `
        -ClaudeInstalled $claudeResult.Installed `
        -ClaudeType "copy" `
        -ClaudeTarget $claudeResult.Target `
        -OmInstalled $omcResult.Installed `
        -OmType "copy" `
        -OmTarget $omcResult.Target

    Write-Host ""
    Write-Host "✅ Installation complete!" -ForegroundColor Green
    Write-Host ""
    Write-Host "To uninstall: .\install\uninstall.ps1"
}

# Run main
Main
```

### uninstall.sh (WSL/Linux/Mac)

```bash
#!/bin/bash

set -euo pipefail

# Constants
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_STATE_FILE="$SCRIPT_DIR/install-state.json"

# Function: Check if installed
check_installed() {
  if [ ! -f "$INSTALL_STATE_FILE" ]; then
    echo "❌ Error: Not installed (install-state.json not found)."
    exit 1
  fi
}

# Function: Read install state
read_install_state() {
  if ! command -v jq &> /dev/null; then
    echo "❌ Error: jq is required for uninstallation."
    echo "   Install with: sudo apt-get install jq  (Ubuntu/Debian)"
    echo "               brew install jq          (Mac)"
    exit 1
  fi

  echo "📋 Reading install state..."
  echo "   File: $INSTALL_STATE_FILE"
}

# Function: Uninstall Claude Code installation
uninstall_claude_code() {
  local target=$(jq -r '.installations.claude_code.target' "$INSTALL_STATE_FILE")
  local installed=$(jq -r '.installations.claude_code.installed' "$INSTALL_STATE_FILE")

  if [ "$installed" = "true" ] && [ -n "$target" ] && [ "$target" != "null" ]; then
    echo "🗑️  Removing Claude Code installation..."
    if [ -e "$target" ]; then
      rm -rf "$target"
      echo "   ✓ Removed: $target"
    else
      echo "   ℹ️  Target not found: $target"
    fi
  else
    echo "ℹ️  Claude Code was not installed"
  fi
}

# Function: Uninstall OpenCode installation
uninstall_opencode() {
  local target=$(jq -r '.installations.omc.target' "$INSTALL_STATE_FILE")
  local installed=$(jq -r '.installations.omc.installed' "$INSTALL_STATE_FILE")

  if [ "$installed" = "true" ] && [ -n "$target" ] && [ "$target" != "null" ]; then
    echo "🗑️  Removing OpenCode installation..."
    if [ -e "$target" ]; then
      rm -rf "$target"
      echo "   ✓ Removed: $target"
    else
      echo "   ℹ️  Target not found: $target"
    fi
  else
    echo "ℹ️  OpenCode was not installed"
  fi
}

# Function: Cleanup
cleanup() {
  echo "🧹 Cleaning up..."
  if [ -f "$INSTALL_STATE_FILE" ]; then
    rm "$INSTALL_STATE_FILE"
    echo "   ✓ Removed: $INSTALL_STATE_FILE"
  fi
}

# Main uninstallation flow
main() {
  echo "🗑️  L1 Log Analysis Skill Uninstaller"
  echo "======================================"
  echo ""

  # Check installed
  check_installed
  read_install_state

  echo ""

  # Uninstall installations
  uninstall_claude_code
  uninstall_opencode

  echo ""

  # Cleanup
  cleanup

  echo ""
  echo "✅ Uninstallation complete!"
}

# Run main
main "$@"
```

### uninstall.ps1 (Windows PowerShell)

```powershell
#requires -Version 5.1

# Constants
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$InstallStateFile = Join-Path $ScriptDir "install-state.json"

# Function: Check if installed
function Test-Installed {
    if (-not (Test-Path $InstallStateFile)) {
        Write-Host "❌ Error: Not installed (install-state.json not found)." -ForegroundColor Red
        exit 1
    }
}

# Function: Read install state
function Read-InstallState {
    Write-Host "📋 Reading install state..." -ForegroundColor Cyan
    Write-Host "   File: $InstallStateFile"
}

# Function: Uninstall Claude Code installation
function Uninstall-ClaudeCode {
    $state = Get-Content $InstallStateFile | ConvertFrom-Json
    $target = $state.installations.claude_code.target
    $installed = $state.installations.claude_code.installed

    if ($installed -eq $true -and $target -and $target -ne "null") {
        Write-Host "🗑️  Removing Claude Code installation..." -ForegroundColor Cyan
        if (Test-Path $target) {
            Remove-Item -Path $target -Recurse -Force
            Write-Host "   ✓ Removed: $target" -ForegroundColor Green
        } else {
            Write-Host "   ℹ️  Target not found: $target" -ForegroundColor Gray
        }
    } else {
        Write-Host "ℹ️  Claude Code was not installed" -ForegroundColor Gray
    }
}

# Function: Uninstall OpenCode installation
function Uninstall-OpenCode {
    $state = Get-Content $InstallStateFile | ConvertFrom-Json
    $target = $state.installations.omc.target
    $installed = $state.installations.omc.installed

    if ($installed -eq $true -and $target -and $target -ne "null") {
        Write-Host "🗑️  Removing OpenCode installation..." -ForegroundColor Cyan
        if (Test-Path $target) {
            Remove-Item -Path $target -Recurse -Force
            Write-Host "   ✓ Removed: $target" -ForegroundColor Green
        } else {
            Write-Host "   ℹ️  Target not found: $target" -ForegroundColor Gray
        }
    } else {
        Write-Host "ℹ️  OpenCode was not installed" -ForegroundColor Gray
    }
}

# Function: Cleanup
function Invoke-Cleanup {
    Write-Host "🧹 Cleaning up..." -ForegroundColor Cyan
    if (Test-Path $InstallStateFile) {
        Remove-Item -Path $InstallStateFile -Force
        Write-Host "   ✓ Removed: $InstallStateFile" -ForegroundColor Green
    }
}

# Main uninstallation flow
function Main {
    Write-Host "🗑️  L1 Log Analysis Skill Uninstaller" -ForegroundColor Cyan
    Write-Host "======================================" -ForegroundColor Cyan
    Write-Host ""

    # Check installed
    Test-Installed
    Read-InstallState

    Write-Host ""

    # Uninstall installations
    Uninstall-ClaudeCode
    Uninstall-OpenCode

    Write-Host ""

    # Cleanup
    Invoke-Cleanup

    Write-Host ""
    Write-Host "✅ Uninstallation complete!" -ForegroundColor Green
}

# Run main
Main
```

## 위험 요소 및 완화

### 0. 아키텍처 Risk Points (신규 — 적대적 검토에서 발견) `[CR-1~CR-6]`

0. **[CR-1][최우선] "Copy 설치"만으로는 Stop Hook/슬래시 커맨드가 등록되지 않음**
   - **위험**: `~/.claude/skills/`와 `.omc/skills/`로 payload를 복사해도, hooks/commands는 Claude Code가 그 경로를 스캔해 자동 등록하는 대상이 아니다(§CR-1 근거 참조). 설치는 "성공"으로 보고되지만 `/l1-log-analysis`는 인식되지 않고 Stop hook도 발동하지 않는다 — 사용자가 실제로 loop를 실행하기 전까지는 드러나지 않는 조용한 실패
   - **완화**: `register_hooks_and_commands()`로 `~/.claude/commands/*.md` 설치 + `~/.claude/settings.json`의 `hooks.Stop`에 병합 등록 (Phase 7). 설치 스크립트는 등록 직후 `/help`나 파일 존재 확인으로 **등록 성공 여부를 자체 검증**하고 실패 시 명확히 실패로 보고
   - **완화**: install-state.json에 `verified` 플래그를 hook/command 등록까지 포함해 재정의 (기존에는 payload 복사 성공만으로 `verified: true`였다)

0-1. **[CR-2] Stop Hook의 "고정 프롬프트 재주입" 메커니즘과 Phase 4 자동 prompt 생성의 충돌**
   - **위험**: 원본 stop-hook은 상태 파일 본문을 그대로 재사용하도록 설계되어 있어, 분석 결과를 반영한 새 prompt를 매 iteration 만든다는 목표(Phase 4)와 구조적으로 맞지 않는다. 구현자가 이를 인지하지 못하면 Phase 4가 아무 효과 없이 "완료"로 표시될 위험
   - **완화**: iteration 갱신과 본문 재생성을 하나의 원자적 쓰기로 묶어 stop-hook 자체를 확장 (Phase 5 필수 항목)

0-2. **[CR-3 — 결정 반영] OpenCode 지원 = Tier 1(`oh-my-openagent` 의존)만, 명시적 하드 의존성**
   - **위험**: "OpenCode 지원"이 사용자에게는 "별도 설치 없이 된다"로 오해될 수 있으나 실제로는 서드파티 plugin(`oh-my-openagent`, Claude Code 호환 기능 포함) 설치가 **전제 조건**이다. 이 전제가 문서/README에 명시되지 않으면 미설치 사용자가 "왜 OpenCode에서 안 되지"라는 버그 리포트를 낼 수 있다
   - **위험**: `oh-my-openagent`가 향후 버전에서 `claude-code-compat-core`의 스캔 경로나 stdin 스키마를 바꾸면 조용히 깨질 수 있다 — 우리가 제어할 수 없는 외부 의존
   - **완화**: README/설치 메시지에 "OpenCode에서 loop를 쓰려면 `oh-my-openagent`(Claude Code 호환 기능) 설치가 필요합니다"를 명시. installer가 OpenCode 감지 시 `oh-my-openagent` 존재 여부까지 확인해 안내
   - **완화**: Tier 0(자체 네이티브 plugin)은 백로그로 남기되 이번 범위에서는 명시적으로 제외 — "언젠가 만들 예정"이 아니라 "이번 릴리스는 Tier 1 전용"으로 확정해 범위 팽창을 막는다

0-3. **[CR-7 — 신규] "OMC"(Claude Code plugin)와 "OpenCode"(별도 제품) 명명 혼동**
   - **위험**: `.omc/skills/`를 "OpenCode 설치 위치"로 잘못 표기하면, 구현자가 실제 OpenCode 경로(`.opencode/skills/`, `.opencode/command/`, `opencode.json`)에 아무것도 설치하지 않고도 "OpenCode 지원 완료"로 착각할 수 있다. 또한 `.omc/skills/`는 디렉토리가 아니라 단일 `.md` 파일 규격이라, 원래 계획대로 `l1-log-analysis/` 전체를 복사하면 OMC의 skill 로더에도 제대로 인식되지 않을 수 있다
   - **완화**: 설치 대상 표를 Claude Code / OMC(선택, 설명용) / OpenCode(Tier 0·1) 셋으로 명시적으로 분리(위 "설치 위치" 표 참고). `.omc/skills/l1-log-analysis.md`는 단일 파일 요약본으로만 취급하고 loop 실행 경로에서 제외

### Ralph Loop 관련 Risk Points

1. **무한 Loop (Infinite Loop)**
   - **위험**: Max iterations 미설치, Completion promise 부재 시 영구 루프
   - **완화**: `[CR-6]` Max iterations 기본값 50 강제 — **주의**: 원본 `setup-ralph-loop.sh`의 기본값은 `0`(무제한)이며 이를 50으로 바꾸는 로직이 없다. Phase 2에서 실제로 오버라이드하지 않으면 이 완화는 문장으로만 존재하게 된다
   - **완화**: Completion promise 기본값 설정
   - **완화**: Session timeout 및 resource limit 적용 — **주의**: 구체적 구현 방법(어떤 timeout, 어디서 강제하는지)이 정의되어 있지 않음. Claude Code 세션 자체의 timeout API 존재 여부부터 확인 필요

2. **State 파일 손상 (State File Corruption)**
   - **위험**: YAML frontmatter 파싱 실패, iteration 비정상 값
   - **완화**: 기존 ralph-loop 검증 로직 재사용 (numeric validation)
   - **완화**: 손상 시 graceful degradation 및 cleanup

3. **Session Isolation** `[CR-5 — 완화 문구 정정]`
   - **위험**: Multiple session에서 동시 loop 실행 시 state 충돌 — **정정**: 상태 파일은 프로젝트당 1개(`.claude/l1-log-analysis.local.md`)이므로 "동시 loop 실행"은 애초에 지원되지 않는다. 위험은 "두 세션이 동시에 loop를 쓰려 할 때 한쪽이 조용히 깨진다"는 것이지, "state가 충돌한다"가 아니다
   - **위험**: 한 session에서 종료 후 다른 session에 영향 — 실제로는 세션 B가 세션 A의 loop 중 `/l1-log-analysis`를 실행하면 CR-4(설정 파일 무조건 덮어쓰기)에 의해 세션 A의 진행 상황이 사라짐
   - **완화**: session_id 기반 isolation 기능 — 이미 원본 `stop-hook.sh:27-35`에 구현되어 있음(다른 세션의 Stop hook은 조용히 종료 허용). 이는 "충돌 방지"가 아니라 "잘못된 세션이 남의 loop를 이어받지 않게 하는 것"임을 명확히 함
   - **완화**: `[CR-4]` setup 스크립트에 active-state-file 가드 추가 — 세션 B가 세션 A의 활성 loop를 덮어쓰지 못하도록 명시적 에러로 차단 (진짜 "isolation"은 이 가드가 담당)

4. **Hook Execution Race Condition**
   - **위험**: Stop hook 실행 중 추가 요청으로 state 불일치
   - **위험**: Parallel hook 호출로 중복 state 업데이트
   - **완화**: State file 업데이트 시 atomic operation (temp file + mv)
   - **완화**: File lock mechanism 추가

5. **Transcript Parsing Failure**
   - **위험**: Transcript format 변경으로 assistant message 추출 실패
   - **위험**: Completion promise detection 실패로 무한 loop
   - **완화**: jq parsing failure 시 graceful degradation — 원본 `stop-hook.sh:111-126`에 이미 구현되어 있음(재사용)
   - **완화**: `[CR-6]` Fallback mechanism으로 log-based completion detection — **미구현**. 이전 초안은 문장만 있고 실제 fallback 로직/데이터 소스가 정의되어 있지 않다. 범위에 포함한다면 Phase 5에 "transcript 파싱 실패 시 `l1-log-analyzer.sh`의 findings 개수 정체(N iteration 동안 신규 없음)를 fallback 종료 조건으로 사용" 같은 구체적 로직을 추가하고, 포함하지 않는다면 이 완화 문구를 삭제한다

6. **Memory/Disk Growth**
   - **위험**: Loop iteration 증가 시 state 파일/로그 누적
   - **위험**: Analysis results 무한 증가
   - **완화**: State 파일 rotation (max N findings, max M iterations)
   - **완화**: Analysis results size limit 및 cleanup

7. **Prompt Injection**
   - **위험**: Malicious completion promise로 조기 종료 유도
   - **위험**: System prompt manipulation
   - **완화**: Completion promise strict validation
   - **완화**: Promise content sanitization

8. **Concurrent Execution** `[CR-4 — 완화가 미구현이었음]`
   - **위험**: Multiple /l1-log-analysis command 실행으로 state 충돌
   - **위험**: Parallel loop으로 resource 경합
   - **완화**: State file lock 사용
   - **완화**: Active state file 존재 시 error — **주의**: 원본 `setup-ralph-loop.sh:140`은 이 가드 없이 무조건 `cat >`로 상태 파일을 덮어쓴다(CR-4). Phase 2에서 실제로 가드를 추가하기 전까지 이 항목은 이름만 있는 완화다

### L1 Log Analysis 관련 Risk Points

9. **Log File Permissions**
   - **위험**: 접근 불가한 로그 파일로 분석 실패
   - **완화**: 접근 불가 시 warning 후 continue
   - **완화**: Fallback log sources 사용

10. **Large Log File Processing**
    - **위험**: GB 단위 로그 파일 처리로 메모리 부족
    - **완화**: tail 사용으로 최근 N 줄만 처리
    - **완화**: Streaming processing (line by line)

11. **Pattern Matching False Positives** `[CR-8 — 전제 자체가 바뀜]`
    - **위험 (원래)**: 잘못된 이슈 식별으로 잘못된 해결책 제시
    - **위험 (CR-8 반영 후 재정의)**: "Pattern Matching"은 이제 스크립트가 이슈를 판정하는 절차가 아니라 LLM이 참고하는 1차 후보 추출 도구일 뿐이다(Phase 3). 진짜 위험은 오히려 반대 방향 — **LLM이 근거 없이 확신도를 과대평가**하거나, 리포트에 "확인됨"으로 적어놓고 실제로는 로그 라인을 충분히 인용하지 않는 것
    - **완화**: ~~Multiple pattern consensus mechanism~~, ~~Confidence score 및 threshold~~ — **삭제**. 스크립트가 신뢰도를 계산한다는 전제 자체가 CR-8로 사라짐
    - **완화 (신규)**: Phase 6의 "로그 분석 방법론" 프롬프트에 "확신도를 적을 때는 반드시 근거가 된 로그 라인을 인용하라"는 지시를 명시해, LLM 스스로 근거 기반 판단을 하도록 유도한다 (코드가 아니라 프롬프트 설계로 완화)

12. **Recursive Log Analysis**
    - **위험**: Log 분석 결과를 다시 로그로 처리하여 무한 재귀
    - **완화**: Analysis 결과 별도 저장
    - **완화**: Log source whitelist/blacklist

### Installer/Uninstaller 관련 Risk Points

13. **Installer/Uninstaller 매칭 실패**
    - **위험**: installer가 설치하지 않은 것을 uninstaller가 제거
    - **위험**: installer가 설치한 것을 uninstaller가 제거하지 않음
    - **완화**: install-state.json을 통한 strict 기록 및 검증
    - **완화**: Uninstaller는 JSON에 기록된 것만 제거

14. **Copy Mode Storage Growth**
    - **위험**: Copy 설치로 디스크 중복 사용
    - **위험**: Skill source 변경 시 설치된 버전 불일치
    - **완화**: `[CR-6]` Install state에 source hash 기록 — install-state.json 스키마에 `source_hash` 필드 추가, `compute_source_hash()`로 실제 계산 (Phase 7)
    - **완화**: Update mechanism 구현 (diff-based update) — **범위 외로 명시**: 이번 구현 범위에는 포함하지 않는다. `source_hash` 불일치를 감지만 하고("재설치 필요" 경고 출력) 자동 업데이트는 후속 작업으로 미룬다 — diff-based update를 "완화책"으로 남겨두고 실제로 만들지 않으면 CR-6과 같은 거짓 완화가 반복된다

15. **[신규 — CR-1 파생] settings.json 병합 실패로 인한 사용자 환경 손상**
    - **위험**: `register_hooks_and_commands()`가 jq로 `~/.claude/settings.json`을 덮어쓰는 과정에서 실패(디스크 full, 권한 문제, 동시 쓰기)하면 사용자의 기존 hook/permission 설정 전체가 손상될 수 있다 — 이는 payload 복사보다 훨씬 blast radius가 큰 작업
    - **완화**: 병합 전 반드시 `settings.json.l1-log-analysis.bak`로 백업, 병합 후 JSON 유효성 재검증(`jq empty`), 실패 시 즉시 백업으로 롤백
    - **완화**: uninstaller는 `hooks_installed[].backup_file`을 이용해 정밀 복원(전체 파일 덮어쓰기 대신 병합했던 hook 항목만 jq로 제거)하는 것을 기본으로 하고, 백업 파일이 있으면 최후 수단으로 제공

16. **플랫폼 호환성**
    - **위험**: Claude Code vs OpenCode 설치 경로 불일치
    - **위험**: OS별 path separator 차이
    - **완화**: Platform detection function 사용
    - **완화**: 각 플랫폼 별도 설치/삭제 로직
    - **완화**: Path normalization (/ vs \)

17. **State File Location**
    - **위험**: install-state.json 위치 불일치
    - **위험**: Project root 기반 vs install script 기반 경로
    - **완화**: Absolute path 기록
    - **완화**: State file location validation

## 테스트 계획

### LLM Self-Testable Test Cases

**LLM이 스스로 검증할 수 있는 테스트 케이스 설계 원칙:**
- 테스트 입력, 실행 단계, 예상 결과가 명확히 정의
- LLM이 테스트 실행 후 결과를 스스로 판단 가능
- 자동화 가능한 구조 (script로 실행 가능)
- 실패 시 명확한 failure reason 제공

#### Installer/Uninstaller Self-Testable Tests

**Test 1: Fresh Install to Claude Code Only**
```bash
# Pre-condition: No install-state.json, no l1-log-analysis in Claude Code
# Test steps:
./install/install.sh
# Expected outputs:
# 1. install-state.json created
# 2. l1-log-analysis copied to ~/.claude/skills/l1-log-analysis
# 3. state.claude_code.installed = true
# 4. state.claude_code.type = "copy"
# 5. state.omc.installed = false (if OMC not detected)
# 6. Exit code 0
```

**Test 2: Install When Already Installed**
```bash
# Pre-condition: install-state.json exists
# Test steps:
./install/install.sh
# Expected outputs:
# 1. Error message: "Already installed"
# 2. No changes to filesystem
# 3. Exit code 1
# 4. Original install-state.json unchanged
```

**Test 3: Uninstall After Fresh Install**
```bash
# Pre-condition: Fresh install completed (Test 1)
# Test steps:
./install/uninstall.sh
# Expected outputs:
# 1. ~/.claude/skills/l1-log-analysis removed
# 2. install-state.json removed
# 3. No other files removed
# 4. Exit code 0
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
# 3. state.{platform}.installed = false
# 4. Exit code 0
```

**Test 6: Corrupted State File**
```bash
# Pre-condition: install-state.json with invalid JSON
# Test steps:
./install/uninstall.sh
# Expected outputs:
# 1. Error message: "Invalid install state"
# 2. Exit code 1
```

**Test 7: Platform Detection - Both Platforms**
```bash
# Pre-condition: Both Claude Code and OMC installed
# Test steps:
./install/install.sh
# Expected outputs:
# 1. Both platforms detected
# 2. Both installations attempted
# 3. state.claude_code.installed = true
# 4. state.omc.installed = true
```

#### Ralph Loop Self-Testable Tests

**Test 8: Basic Loop with Completion Promise**
```bash
# Pre-condition: /l1-log-analysis skill installed
# Test command:
/l1-log-analysis "Analyze /var/log/syslog" --completion-promise "DONE" --max-iterations 5
# Test steps (LLM self-execute):
# 1. Iteration 1: Initial analysis
# 2. Iteration 2-4: Refine analysis
# 3. Iteration 5: Output "<promise>DONE</promise>"
# Expected outputs:
# 1. Loop runs exactly 5 times
# 2. State file iteration increments each time
# 3. Final state.iteration = 5
# 4. State file removed after completion
```

**Test 9: Max Iterations Exceeded**
```bash
# Pre-condition: /l1-log-analysis skill installed
# Test command:
/l1-log-analysis "Analyze logs" --max-iterations 3
# Test steps:
# 1. Iterate 3 times
# 2. Do NOT output completion promise
# Expected outputs:
# 1. Loop stops after 3 iterations
# 2. State file removed
# 3. Message: "Max iterations reached"
```

**Test 10: Cross-Session Non-Interference** `[CR-5 — Session Isolation에서 명칭·기대값 정정]`
```bash
# Pre-condition: Two Claude Code sessions in the SAME project (state file is project-scoped, not per-session)
# Test steps:
# Session A: /l1-log-analysis "Analyze test.log" --max-iterations 5   (starts a loop, state file session_id=ses_A)
# Session B (while A's loop is active): /l1-log-analysis "Analyze other.log"
# Expected outputs:
# 1. Session B's setup is REJECTED with "이미 활성 loop가 있습니다" (CR-4 guard) — it does NOT get its own independent state
# 2. Session A's state file is untouched by Session B's rejected attempt (session_id still ses_A, iteration unchanged)
# 3. If Session B's Stop hook fires while Session A's loop is active (e.g. Session B was NOT running l1-log-analysis at all),
#    Session B's hook reads session_id=ses_A != its own hook_session and exits 0 (allows exit) WITHOUT touching the state file
# 4. There is exactly one active loop at a time per project — this test must NOT assert "each session has independent state"
```

**Test 11: State File Corruption Recovery**
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

**Test 12: Transcript Parsing with Multiple Tool Calls**
```bash
# Pre-condition: Session with multiple tool calls in last turn
# Test steps:
# 1. Run iteration with bash command + text output
# 2. Output completion promise
# Expected outputs:
# 1. Promise detected in text content
# 2. Tool call content ignored
# 3. Loop completes successfully
```

#### Log Analysis Self-Testable Tests

**Test 13: Log Pattern Detection**
```bash
# Pre-condition: Test log file with known patterns
# Test steps:
/l1-log-analysis "Analyze test.log" --pattern "memory leak"
# Expected outputs:
# 1. Pattern found in test.log
# 2. Finding recorded in state.findings
# 3. Analysis report includes matched lines
```

**Test 14: Multiple Log Sources**
```bash
# Pre-condition: Two test log files
# Test steps:
/l1-log-analysis "Analyze /tmp/log1.log /tmp/log2.log"
# Expected outputs:
# 1. Both files analyzed
# 2. state.log_sources contains both paths
# 3. Combined findings report
```

**Test 15: Inaccessible Log File**
```bash
# Pre-condition: Log file with no read permission
# Test steps:
/l1-log-analysis "Analyze /root/secure.log"
# Expected outputs:
# 1. Warning message about permission error
# 2. Loop continues without error
# 3. state.log_sources excludes inaccessible file
```

**Test 16: Large Log File (Performance Test)**
```bash
# Pre-condition: 1GB log file
# Test steps:
/l1-log-analysis "Analyze large.log" --max-iterations 1
# Expected outputs:
# 1. Analysis completes within reasonable time (< 30s)
# 2. Memory usage stable
# 3. No disk space exhaustion
```

#### Integration Self-Testable Tests

**Test 17: Full Cycle - Install → Run → Uninstall**
```bash
# Test steps:
./install/install.sh
/l1-log-analysis "Analyze test.log" --completion-promise "TEST_DONE" --max-iterations 2
# (LLM outputs <promise>TEST_DONE</promise> in iteration 2)
./install/uninstall.sh
# Expected outputs:
# 1. Installation succeeds
# 2. Loop runs 2 iterations and completes
# 3. Uninstallation removes all traces
# 4. No leftover files
```

**Test 18: Concurrent Install Attempts**
```bash
# Pre-condition: Clean environment
# Test steps:
./install/install.sh &  # Background
./install/install.sh &  # Background
wait
# Expected outputs:
# 1. One installation succeeds
# 2. One fails with "Already installed"
# 3. Consistent final state
```

#### Hook/Command Registration Self-Testable Tests (신규 — CR-1 검증) `[CR-1]`

**Test 19: Command Actually Registers as a Slash Command**
```bash
# Pre-condition: Fresh install completed
# Test steps:
ls ~/.claude/commands/l1-log-analysis.md ~/.claude/commands/cancel-l1-log-analysis.md
grep -c '${CLAUDE_PLUGIN_ROOT}' ~/.claude/commands/l1-log-analysis.md   # must be 0 after install-time substitution
# Expected outputs:
# 1. Both command files exist under ~/.claude/commands/
# 2. No unresolved ${CLAUDE_PLUGIN_ROOT} placeholders remain
# 3. The embedded script path is an absolute path that exists on disk
```

**Test 20: Stop Hook Actually Registers in settings.json**
```bash
# Pre-condition: Fresh install completed
# Test steps:
jq '.hooks.Stop' ~/.claude/settings.json
jq empty ~/.claude/settings.json   # validity check
ls ~/.claude/settings.json.l1-log-analysis.bak
# Expected outputs:
# 1. hooks.Stop contains an entry whose command points at the installed stop-hook.sh absolute path
# 2. settings.json remains valid JSON
# 3. A pre-merge backup file exists
```

**Test 21: Uninstall Restores settings.json Precisely**
```bash
# Pre-condition: Test 20 passed, then ./install/uninstall.sh run
# Test steps:
jq '.hooks.Stop' ~/.claude/settings.json
diff <(jq -S . ~/.claude/settings.json) <(jq -S . ~/.claude/settings.json.l1-log-analysis.bak)
# Expected outputs:
# 1. The l1-log-analysis Stop hook entry is gone
# 2. Any OTHER pre-existing hooks/permissions the user had are untouched
# 3. Backup file is removed after successful restore (or retained per policy — decide and assert one)
```

**Test 22 (CR-8로 재정의됨 — 이전: "Phase-4 Prompt Body Changes", CR-2가 요구하던 stop-hook 본문 재생성은 CR-8로 불필요해짐): Report File Actually Evolves Across Iterations, State File Body Stays Static** `[CR-8]`
```bash
# Pre-condition: /l1-log-analysis running against a log with distinguishable content
# Test steps:
# 1. Capture .claude/l1-log-analysis/report.md after iteration 1
# 2. Let iteration 2 run
# 3. Capture the state file body (.claude/l1-log-analysis.local.md, after the second ---) AND report.md again
# Expected outputs:
# 1. report.md DIFFERS between iteration 1 and 2 (LLM actually wrote new content — a FAILED test if unchanged)
# 2. The state file's prompt BODY is byte-identical between iteration 1 and 2 (only the `iteration:` frontmatter field changed)
#    — this is now the EXPECTED/correct behavior under CR-8, unlike the old CR-2 expectation
# 3. On the next iteration, the LLM's first action should be reading report.md (verify via transcript: a Read/Bash call on report.md path before new analysis)
```

### 1. Installer/Uninstaller Tests

**Unit Tests:**
- [ ] install.sh 파싱 로직 테스트
- [ ] install.ps1 파싱 로직 테스트
- [ ] uninstall.sh 상태 읽기 테스트
- [ ] uninstall.ps1 상태 읽기 테스트

**Integration Tests:**
- [ ] install.sh → uninstall.sh 매칭 테스트
  - 설치 후 install-state.json 생성 확인
  - uninstall 시 기록된 것만 제거 확인
  - uninstall 후 기록되지 않은 것 유지 확인
- [ ] install.ps1 → uninstall.ps1 매칭 테스트 (Windows)
  - 동일한 매칭 테스트
- [ ] Claude Code 단독 설치/삭제 테스트
- [ ] OpenCode 단독 설치/삭제 테스트
- [ ] 둘 다 설치/삭제 테스트

**Safety Tests:**
- [ ] 이미 설치되어 있을 때 install error 테스트
- [ ] 설치되지 않았을 때 uninstall error 테스트
- [ ] Target 이미 존재할 때 skip 테스트
- [ ] Install-state.json 손상 시 error 테스트

**Platform Tests:**
- [ ] WSL 환경에서 설치/삭제 테스트
- [ ] Linux 환경에서 설치/삭제 테스트
- [ ] Mac 환경에서 설치/삭제 테스트
- [ ] Windows PowerShell에서 설치/삭제 테스트

### 2. Skill Tests

**Unit Tests:**
- [ ] setup script 파싱 로직
- [ ] stop hook 분기 테스트
- [ ] log analyzer 패턴 매칭

**Integration Tests:**
- [ ] 전체 loop 동작
- [ ] State 파일 생성/업데이트
- [ ] Claude Code skill 등록 테스트
- [ ] OpenCode skill 등록 테스트

**End-to-End Tests:**
- [ ] 실제 L1 이슈가 있는 환경에서 실행
- [ ] Completion promise 동작 확인
- [ ] Max iterations 동작 확인

## 다음 단계

1. Phase 0부터 시작하여 순차적으로 구현
2. 각 Phase 완료 후 테스트 및 검증
3. 사용자 피드백에 따라 기능 추가/수정

## Checklist

### Phase -1 (아키텍처 검증, 신규) `[CR-1][CR-3][CR-7]`
- [ ] settings.json hooks.Stop 수동 등록 재현 테스트 (Claude Code)
- [ ] ~/.claude/commands/*.md 수동 슬래시 커맨드 인식 재현 테스트 (Claude Code)
- [ ] `oh-my-openagent` 설치 환경에서 CR-1의 settings.json hook이 OpenCode에서도 발동하는지 확인 (OpenCode Tier 1 — **범위 확정**, Tier 0는 제외)
- [ ] `.omc/skills/`와 `.opencode/skills/`가 서로 다른 경로임을 설치 스크립트 주석/변수명에도 명확히 반영 (CR-7)

### Installer/Uninstaller 개발
- [ ] install.sh 개발
- [ ] install.ps1 개발
- [ ] uninstall.sh 개발
- [ ] uninstall.ps1 개발
- [ ] install-state.json 스키마 정의 (`source_hash`, 실제로 채워지는 `hooks_installed`/`files_created`/`files_modified` 포함)
- [ ] Platform detection 공통 로직
- [ ] `[CR-1]` `register_hooks_and_commands()` / `unregister_hooks_and_commands()` 구현
- [ ] `[CR-6]` install.sh jq 사전 체크, trap 기반 partial cleanup
- [ ] `[CR-3]` OpenCode 감지 시 `oh-my-openagent` 설치 여부 확인, 미설치 시 안내 메시지 출력 (에러 아님)

### Skill 개발 `[CR-8 — Phase 4 삭제, Phase 3/5/6 재정의]`
- [ ] Phase 0, 1, 2(스키마 축소), 3(analyzer → 보조 도구), 5(단순화된 stop-hook), 6(방법론 프롬프트 포함), 7 완료 — **Phase 4는 삭제되어 Phase 6에 흡수됨**

### 테스트
- [ ] Installer/Uninstaller 테스트
- [ ] Skill 테스트
- [ ] `[CR-1]` Hook/Command Registration 테스트 (Test 19-21)
- [ ] `[CR-8]` LLM이 report.md를 실제로 iteration마다 Read→갱신하는지 확인하는 회귀 테스트 (Test 22를 CR-8 기준으로 대체 — "프롬프트 본문 변경"이 아니라 "리포트 파일 변경"을 확인)
- [ ] `[CR-8]` completion-promise가 LLM 자기평가 문구로 정상 종료되는지 확인 (거짓 종료·조기 종료 방지 확인 포함)

### Documentation
- [ ] README 작성
- [ ] 사용자 가이드 작성
- [ ] 개발자 가이드 작성

## 참고 문서

- ralph-loop 소스: `/home/fanta/.claude/plugins/marketplaces/claude-plugins-official/plugins/ralph-loop/`
- Claude Code skill 가이드: https://docs.anthropic.com
- OpenCode skill 가이드: https://github.com/anomalyco/opencode/

---

**작성일**: 2026-07-17
**상태**: Draft (아키텍처 재검토 반영)
**우선순위**: High
**마지막 수정**: 2026-07-19 (4차 개정 — CR-8을 Multi-Agent Pipeline 뼈대로 확장: 사용자가 구상한 8-agent 역할(문제 파악/timeline 검증/orchestration/router/log 분석/verifier/aggregator/report 작성)을 수용할 수 있는 구조를 설계 — `report_path` 단일 파일을 `pipeline_dir` + `manifest.json`(stage별 status/artifact/rework_count 추적)으로 확장, `playbooks/` 라이브러리 도입, orchestrator 루프 로직 정의, Claude Code `Agent`/OpenCode `task` 툴 양쪽에서의 실현 가능성을 `opencode agent create --mode subagent`와 `oh-my-openagent`의 `loadPluginAgents()` 근거로 확인, 신규 위험 4건(rework 무한루프/토큰 폭증/OpenCode agent 포맷 미검증/manifest 동시쓰기 경합)과 Phase -1 검증 항목 추가. 각 agent의 내부 로직은 이번 범위에서 설계하지 않음(뼈대만 확정, 사용자 지시). 3차 개정: OpenCode 지원 범위를 Tier 1(`oh-my-openagent` 의존)만으로 확정, CR-8 최초 신설(로그 분석 스크립트→LLM CoT 전환). 2차 개정: CR-3 검증 완료, CR-7 신설("OMC"≠"OpenCode"), Skill vs Command 비교 부록. 1차 개정: CR-1/CR-2/CR-4/CR-5/CR-6)
**관련 문서**: `/home/fanta/study/BackEnd/loop_skill/docs/implementation-spec.md` (구현 스펙 — 2차~4차 개정 모두 아직 미반영, 전체 plan 완료 후 동기화 예정)