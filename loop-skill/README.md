# loop-skill

Generic self-referential loop (ralph-loop pattern) for Claude Code, with a pipeline
extension point. The core knows nothing about any particular domain — it only manages
iteration count, a `<state_dir>/status.json` completion check, and a `state_dir` handoff.
See `docs/implementation-spec_v02.md` and `docs/harness_loop_plan_v02.md` in the parent
repository for the full design rationale.

## Install

```bash
./install/install.sh      # Linux/Mac/WSL
.\install\install.ps1     # Windows PowerShell
```

Copies this skill payload to `~/.claude/skills/loop-skill`, registers
`/loop-skill` and `/cancel-loop-skill` as commands, and adds a `Stop` hook entry to
`~/.claude/settings.json` (with a timestamped backup).

## Use

```bash
/loop-skill Build a REST API for todos --max-iterations 20
/loop-skill --pipeline smoke-test
/cancel-loop-skill
```

The loop stops when the LLM writes `{"status": "complete"}` (or `{"status": "failed",
"reason": "..."}`) to `<state_dir>/status.json`, or when `--max-iterations` is reached.

Project-level defaults for `--pipeline`/`--max-iterations` can be set in
`.claude/loop-skill.config` (dotenv format) so you don't have to repeat them every call —
CLI flags always override the config file:

```bash
# .claude/loop-skill.config
LOOP_SKILL_PIPELINE=smoke-test
LOOP_SKILL_MAX_ITERATIONS=20
```

See `pipelines/README.md` for how to plug in a pipeline.

## Wrap an existing skill into a loop (`apply-skill`)

`/loop-skill`(위)은 항상 그 이름 자체로 시작하는 범용 진입점입니다. 반대로, **이미 갖고 있는 skill을
그 skill 이름으로 그대로 loop처럼 돌리고 싶다면** `apply-skill`을 씁니다. 예를 들어
`~/.claude/skills/l1-log-analysis/`라는 skill이 있다면:

```bash
~/.claude/skills/loop-skill/scripts/apply-skill.sh l1-log-analysis
```

이 한 줄로 `/l1-log-analysis`가 `/l1-log-analysis-loop`로 바뀌고, 그 skill이 하던 작업을
ralph-loop(완료까지 self-referential 반복)으로 수행하게 됩니다.

### 기본 동작 원리

- **이름 변경 + wrap, 원본 보존.** apply는 원본 skill을 `~/.claude/loop-applied/backups/<name>/`로
  옮겨 안전하게 보관하고, 같은 자리에 `<name>-loop`라는 새 skill을 만듭니다. `-loop` 접미사가 붙어
  있으면 "적용됨", 안 붙어 있으면 "미적용"임을 이름만 보고 바로 알 수 있고, 원본과 loop 버전이
  동시에 존재하지 않으므로 헷갈릴 일이 없습니다.
- **엔진은 skill마다 번들, Stop 훅은 머신에 하나만.** loop을 실제로 반복시키는 두 부품 중
  state 파일을 만드는 쪽(`setup-loop-skill.sh`)은 `<name>-loop/` 안에 **복사**되어 그 skill이
  어디로 이동해도 자기완결적으로 동작합니다. 하지만 매 iteration마다 세션 종료를 가로채 재feed하는
  Stop 훅은 **머신에 정확히 하나만** 등록되어 있어야 합니다(`./install/install.sh`가 이미
  등록해 둠) — skill마다 훅을 따로 두면 같은 loop이 한 번의 종료 시도에 여러 번 처리되어
  iteration이 배로 뛰는 문제가 생기기 때문입니다. 여러 프로젝트에서 동시에 서로 다른 `-loop` skill을
  돌려도 이 하나의 훅이 프로젝트별 state 파일과 세션 ID로 서로를 구분하므로 안전합니다.
- **원본 skill의 지시문이 곧 loop 프롬프트가 됩니다.** 원본 `SKILL.md`의 본문(frontmatter 제외)이
  `pipeline.md`로 추출되어, loop이 매 iteration 그대로 재feed하는 내용이 됩니다. 원본 본문에
  "완료되면 status.json에 신호를 쓰라"는 지시가 없으면 apply가 자동으로 표준 문구를 덧붙입니다 —
  그래야 loop이 스스로 끝날 수 있습니다(안 그러면 `--max-iterations`까지 계속 돕니다).
- **동시성 규칙은 `/loop-skill`과 완전히 동일합니다.** `-loop` skill이 시작한 loop도 일반
  `/loop-skill` loop과 같은 활성-loop 가드를 공유하므로, 같은 프로젝트에서 동시에 두 loop을 돌릴 수
  없고, `/cancel-loop-skill`로 그대로 중단할 수 있습니다.

### 사용법

```bash
# 적용 — l1-log-analysis를 loop으로 감싼다
apply-skill.sh l1-log-analysis
apply-skill.ps1 -Origin l1-log-analysis    # Windows

# 이후 실제 실행은 Claude Code에서
/l1-log-analysis-loop --max-iterations 30

# 어떤 skill이 어떤 엔진 버전으로 적용됐는지 확인
apply-skill.sh --status

# loop-skill 코어를 업그레이드한 뒤, 이미 wrap된 skill들을 최신 엔진으로 갱신
apply-skill.sh --upgrade-all
# 또는 하나만: apply-skill.sh l1-log-analysis   (이미 wrap돼 있으면 자동으로 upgrade로 처리됨)

# 원복 — l1-log-analysis-loop를 지우고 원래 l1-log-analysis로 되돌린다
unapply-skill.sh l1-log-analysis
```

| 옵션 | 의미 |
|---|---|
| `--keep-model-invocation` | 원본 skill의 `disable-model-invocation` 값을 그대로 유지. 기본은 loop 안전을 위해 무조건 `true`(사용자가 직접 호출해야만 실행)로 강제됩니다. |
| `--force` | 원본이 최초 apply 이후 변경된 것으로 감지되면(drift) 재적용을 거부하는데, 이를 무시하고 진행합니다. |
| `--dry-run` | 실제로 아무것도 옮기거나 만들지 않고 무엇이 수행될지만 출력합니다. |
| `--status` / `--list` | 현재 적용된 모든 `-loop` skill과 각각의 엔진 버전, 최신 대비 뒤처짐 여부를 표로 보여줍니다. |
| `--upgrade <name>` / `--upgrade-all` | 이미 wrap된 skill(들)의 번들 엔진과 launcher를 현재 설치된 loop-skill 버전으로 재생성합니다. 원본 작업 지시(pipeline 본문)는 그대로 보존됩니다. |

### 알려진 제약

- **Windows(`apply-skill.ps1`/`unapply-skill.ps1`/`setup-loop-skill.ps1`)는 로직상 bash 버전과
  1:1 대응하도록 작성됐지만, PowerShell 실행 환경에서 별도 검증이 아직 필요합니다.**
- **본문에 `---` 구분선이 있는 원본 skill 주의:** apply 자체는 frontmatter만 정확히 제거하고 본문의
  `---`는 보존합니다. 하지만 loop이 2번째 iteration부터 Stop 훅을 통해 프롬프트를 재feed할 때,
  이 Stop 훅(`hooks/stop-hook.sh`, v02부터 있던 로직으로 이번 변경과 무관)이 state 파일 안의 모든
  `---` 줄을 구분자로 오인해 걸러내는 기존 결함이 있습니다 — 그 결과 원본 본문에 있던 `---` 구분선이
  2번째 iteration부터는 재feed된 프롬프트에서 사라집니다. 여러 단계를 `---`로 나누는 pipeline을
  wrap할 계획이라면, 그 구분자를 `---` 대신 다른 표기(예: `===` 또는 헤딩)로 바꾸는 것을 권장합니다.
- 활성 loop 하나 제한, cancel 공유 등은 `/loop-skill`과 동일하게 적용됩니다(위 "동시성" 참고).

design rationale과 나머지 세부사항은 `docs/harness_loop_plan_v03.md`, `docs/implementation-spec_v03.md`
(상위 저장소)를 참고하세요.

## Uninstall

```bash
./install/uninstall.sh    # Linux/Mac/WSL
.\install\uninstall.ps1   # Windows PowerShell
```

Removes only what the matching installer created — any other hooks or commands you
added later are left untouched.

**주의:** 이건 loop-skill 코어 자체(Stop 훅, `/loop-skill`, `/cancel-loop-skill`)를 제거하는
것입니다. 개별적으로 wrap한 skill을 되돌리고 싶다면 이건 실행하지 말고, 위 "Wrap an existing skill"
절의 `unapply-skill.sh <name>`을 쓰세요 — 그러면 코어는 그대로 두고 그 skill 하나만 원래대로
복원됩니다.
