# 범용 Ralph-Loop Skill 구현 계획 (v02)

## 문서 정보

- 이 문서는 `harness_loop_plan.md`(v01)의 적대적 검토와 다회차 논의를 종합한 실행 계획이다. v01은 조사 근거(CR-1~CR-8) 이력 문서로 보존한다.
- **이번 개정(2026-07-19, 2차)에서 범위를 재조정했다**: 이전 v02 초안은 L1 로그 분석에 특화된 8-agent Multi-Agent Pipeline(manifest.json 스키마, agent 7종, playbook 라이브러리)을 구현 대상으로 다뤘다. 이번 구현 범위에서는 이를 **제외**한다 — manifest/agent 기반 구조는 "나중에 pipeline별로 하나씩 설계"할 후속 작업이며, 지금은 **그런 구조를 나중에 얹을 수 있는 범용 loop skill 코어**만 만든다. Multi-Agent/manifest 설계는 이 문서의 "부록 A: 예시 Pipeline"으로 옮겨 **확장 가능성을 보여주는 예시**로만 남긴다.
- **이번 개정(2026-07-19, 3차)에서 완료 판단/설정 방식을 변경했다**: (1) 완료 판단을 원본 ralph-loop의 `<promise>` 텍스트 매칭(LLM 응답 transcript에서 문자열을 파싱해 비교) 방식에서, `state_dir` 안의 고정 이름 파일(`status.json`) 존재·내용 확인 방식으로 바꾼다 — LLM이 자기 응답에 문자열을 정확히 재현하는 데 의존하지 않기 위함이며, 모델 종류에 따라 지시 순응도가 달라지는 문제를 없앤다(§3.6.1). (2) `--pipeline`, `--max-iterations` 등 반복 실행 설정값을 매번 CLI 인자로 입력하지 않도록 프로젝트 config 파일(`.claude/loop-skill.config`)에서 기본값을 읽고, CLI 인자가 있으면 그것을 우선시킨다(§3.7).
- 관련 문서: `harness_loop_plan.md`(v01, 조사 근거) / `implementation-spec.md`(구현 스펙 — 이 v02 확정 후 동기화 예정)
- 작성일: 2026-07-19
- 상태: Draft

## 1. 개요

이 skill은 `ralph-loop`의 self-referential loop 패턴(세션 종료를 Stop hook이 가로채 동일 프롬프트를 재feed)을 그대로 재사용하는 **범용 loop 실행기**다.

**핵심 설계 방향 전환**: 이 skill은 "L1 로그 분석 전용"이 아니라, **어떤 반복 작업(pipeline)이든 위에 얹을 수 있는 범용 뼈대**로 만든다. 코어는 pipeline의 내용에 대해 아무것도 모른다 — 알아야 할 필요도 없다. 코어가 아는 것은:
- 고정 프롬프트를 반복 재feed하는 것
- iteration 카운트와 max-iterations 안전장치
- `state_dir` 안의 고정 이름 완료-신호 파일(`status.json`)을 확인해 종료 판단 (§3.6.1 — LLM 응답 텍스트 파싱이 아니라 파일 기계 확인)
- pipeline이 자유롭게 쓸 수 있는 빈 작업 디렉토리(`state_dir`)를 하나 보장해주는 것
- `--pipeline`/`--max-iterations` 같은 반복 설정값의 기본값을 프로젝트 config 파일에서 읽는 것 (§3.7)

**이번 구현 범위**:
1. 범용 loop 코어 (설치, command/hook 등록, state 관리, completion 판단) — §2~§9
2. Pipeline 확장 계약(extension contract) 정의 — 코어가 지켜야 할 최소 원칙, §3.6
3. Claude Code 1급 지원 + OpenCode Tier 1 지원

**이번 구현 범위 아님 (후속 작업)**:
- 특정 pipeline의 실제 구현 (L1 로그 분석용 manifest.json 스키마, 8개 agent, playbook 라이브러리 등) — 부록 A에 **예시**로만 기술
- Pipeline별 orchestrator 로직, agent 내부 판단 로직

## 2. 핵심 요구사항

1. **설치**: Claude Code에서 `/loop-skill`(가칭)이 실제 슬래시 커맨드로 동작하고 Stop hook이 실제로 걸려야 한다. Symlink는 쓰지 않고 copy + 명시적 등록 방식을 쓴다.
2. **Installer/Uninstaller**: `install.sh`/`install.ps1`/`uninstall.sh`/`uninstall.ps1`. Installer가 등록한 것만 Uninstaller가 제거한다.
3. **Ralph loop 기본 동작**: 세션 종료 시 자동 차단 + 동일 프롬프트 재feed, `max_iterations` 도달 또는 `state_dir/status.json`의 완료 신호로 종료, state 파일로 iteration 추적. 원본 ralph-loop 메커니즘을 **거의 그대로** 재사용하되, 완료 판단부만 LLM 응답 텍스트 매칭(`<promise>`)에서 파일 확인(`status.json`) 방식으로 바꾼다(§3.6.1) — 도메인 특화 로직은 여전히 코어에 넣지 않는다.
4. **Pipeline 확장 가능성**: 코어는 특정 도메인(로그 분석 등)을 가정하지 않는다. 사용자가 `--prompt` 또는 pipeline 정의 파일을 참조시키면, 그 내용이 무엇이든(단순 리포트 작성이든, 여러 subagent로 구성된 복잡한 파이프라인이든) 코어 위에서 반복 실행될 수 있어야 한다.
5. **플랫폼 범위**: Claude Code가 1급 대상. OpenCode는 `oh-my-openagent`(Claude Code 호환 기능 포함) 설치를 전제로 한 **Tier 1 지원만** 한다.
6. **설정 기본값 파일**: `--pipeline`, `--max-iterations` 같이 실행마다 잘 안 바뀌는 설정값을 매번 CLI 인자로 입력하지 않도록, 프로젝트 config 파일(`.claude/loop-skill.config`)에서 기본값을 읽는다. 우선순위는 **CLI 인자 > config 파일 > 코어 내장 기본값**(§3.7).

## 3. 아키텍처 원칙 (확정)

### 3.1 Claude Code: Copy + 명시적 등록

Claude Code의 실제 skill 포맷은 `SKILL.md` 단일 파일뿐이며 hook/command 개념이 없다. hook은 `~/.claude/settings.json`의 `hooks` 키로만, 슬래시 커맨드는 `~/.claude/commands/*.md`로만 인식된다. 설치는 **payload 복사**와 **등록**을 분리한 2단계다.

| 단계 | 대상 | 방식 |
|------|------|------|
| Payload | `~/.claude/skills/loop-skill/` | Copy |
| Command 등록 | `~/.claude/commands/loop-skill.md`, `~/.claude/commands/cancel-loop-skill.md` | Copy + `${CLAUDE_PLUGIN_ROOT}` → payload 절대경로 치환 |
| Stop Hook 등록 | `~/.claude/settings.json`의 `hooks.Stop` 배열 | JSON 병합 (jq), 병합 전 백업 필수 |

### 3.2 Skill vs Command — 역할 분리

| | Skill (`SKILL.md`) | Command (`commands/*.md`) |
|---|---|---|
| 트리거 | 모델이 판단 or `/이름` → Skill tool | `/이름 args` → bash 블록 즉시 자동 실행 |
| 인자 처리 | 모델이 자연어로 해석 | `argument-hint` + `$ARGUMENTS`로 스크립트에 직접 전달 |
| Hook 등록 | **불가능** | 그 자체로는 무관 — hook은 §3.1의 별도 등록 |

`SKILL.md`는 사람이 읽는 설명 문서로만 유지한다. `/loop-skill <args>` 실행과 loop 시작은 **command 등록**이 담당한다.

### 3.3 OpenCode: Tier 1 전용 (확정)

- OpenCode의 hook 메커니즘은 Claude Code와 근본적으로 다르다 — `@opencode-ai/plugin`의 `event: (input:{event}) => Promise<void>`라는 **JS/TS 코드**이며, `opencode.json`의 `plugin` 배열로 등록한다.
- `oh-my-openagent`(Claude Code 호환 기능 포함) 설치 환경에서는, `claude-code-compat-core`가 `~/.claude/settings.json`의 `hooks.Stop`을 직접 읽고 Claude Code와 동일한 stdin 스키마로 우리 `stop-hook.sh`를 호출한다(SQLite 세션도 Claude JSONL 포맷으로 즉석 재구성).
- **결정**: OpenCode 지원은 **Tier 1만** — `oh-my-openagent` 설치를 하드 의존성으로 문서화하고 §3.1 산출물을 그대로 재사용한다. 별도 OpenCode 네이티브 plugin은 만들지 않는다.

### 3.4 "OMC"(`oh-my-claudecode`) ≠ "OpenCode"

`.omc/`는 **Claude Code plugin `oh-my-claudecode`**의 프로젝트 상태 루트다. OpenCode와는 무관한 별개 제품이며, `.omc/skills/<name>.md`는 파일 하나를 요구하는 규격이다. 설치 대상 문서/코드에서 항상 구분 표기한다. (선택 사항으로 `.omc/skills/loop-skill.md` 설명용 단일 파일을 남길 수 있으나 loop 실행과는 무관.)

### 3.5 코어는 도메인 로직을 모른다 (중요 — 이번 개정의 핵심 원칙)

원본 ralph-loop의 stop-hook(iteration 갱신, `<promise>` 비교, 프롬프트 재feed)은 완전히 도메인 중립적이다. **이 중립성을 유지하는 것이 코어 설계의 최우선 원칙이다.** 코어 코드(setup 스크립트, stop-hook) 어디에도 다음을 하드코딩하지 않는다:
- 특정 산출물 파일 이름(`report.md`, `manifest.json` 등)
- 특정 스키마(구조화 findings, stage 목록 등)
- 특정 agent 이름이나 호출 순서

대신 코어는 pipeline이 자유롭게 쓸 수 있는 **빈 디렉토리 하나**(`state_dir`)만 보장한다. 그 안에 뭘 넣을지는 전적으로 pipeline 저작자(= command 프롬프트를 작성하는 사람)의 몫이다.

### 3.6 Pipeline 확장 계약 (Extension Contract) — 코어가 실제로 구현하는 확장점

코어가 **제공**하는 것:
1. 고정 프롬프트 반복 재feed (원본 ralph-loop 그대로)
2. `state_dir` 하나 보장 (기본값 `.claude/loop-skill/<run-id>/`, `--state-dir`로 재정의 가능) — 생성과 완료-신호 파일(`status.json`) 확인만 하고 그 외 내용은 관여하지 않음(§3.6.1, §6.2)
3. `--max-iterations` 안전장치 + `state_dir/status.json` 완료 확인 (완료 판단 메커니즘은 원본 ralph-loop의 `<promise>` 텍스트 매칭에서 교체됨, §3.6.1). 두 값 모두 config 파일 기본값 지원(§3.7)
4. `--pipeline <name>` 옵션(선택): 지정 시 `pipelines/<name>/prompt.md`의 내용을 고정 프롬프트 본문으로 읽어들여 사용 — **코어는 이 파일 내용을 해석하지 않고 그대로 전달만 한다**. config 파일에 `pipeline` 기본값이 있으면 `--pipeline` 생략 시 사용
5. `pipelines/<name>/agents/*.md`가 존재하면 설치 시 `~/.claude/agents/`로 copy (위치 규칙만 — 파일 내용/개수/이름은 관여하지 않음. §4.2.2/§9의 `register_pipeline_agents()`)

코어가 **관여하지 않는** 것 (pipeline 저작자 책임):
- `state_dir` 내부 구조 (단일 markdown 파일이든, `manifest.json` + 여러 subagent 산출물이든 무관) — 단, `status.json`이라는 파일 **이름과 최소 스키마**(`status` 필드)만은 코어가 아는 유일한 예외(§3.6.1)
- 몇 개의 agent를 쓸지, 어떤 순서로 호출할지, orchestrator 로직을 프롬프트에 어떻게 담을지
- `status.json`의 `status`가 실제로 `complete`인지 판단하는 기준의 구체적 내용 (파일 확인 자체는 코어가 하지만, 그 판단이 옳은지는 pipeline의 LLM 몫)

**검증 기준**: 이 계약이 지켜졌는지는 "L1 로그 분석처럼 복잡한 8-agent pipeline"과 "그냥 코드 리뷰를 반복하는 1-agent pipeline"을 **코어 코드 변경 없이** 둘 다 `pipelines/` 아래 새 디렉토리 하나 추가하는 것만으로 지원할 수 있는지로 판단한다. (부록 A가 이 검증의 예시 역할을 한다.)

#### 3.6.1 완료 신호 계약 (Completion Signal Contract) — `<promise>` 텍스트 매칭 대체 (이번 개정 신규)

**배경**: 원본 ralph-loop는 LLM이 마지막 응답에 `<promise>{고정 문자열}</promise>`를 그대로 출력하면 stop-hook이 transcript를 파싱해 state 파일에 저장된 문자열과 비교하는 방식이었다. 이 방식은 두 가지 문제가 있다: (1) LLM이 정확히 그 문자열을 "복사"해야 하는데, 모델 종류·설정에 따라 지시 순응도가 달라 재현에 실패할 수 있고, 그 실패 양상을 코어가 예측/제어할 수 없다. (2) transcript 파싱(jq 기반)이 실패하는 경우의 graceful degradation 로직이 별도로 필요했다.

**결정**: 완료 판단을 **LLM의 응답 텍스트 파싱**에서 **파일 확인**으로 옮긴다.

- 코어는 `state_dir` 안에 고정된 이름의 파일 하나(`status.json`)만 안다 — pipeline이 자체적으로 만드는 다른 어떤 파일(`manifest.json` 등)도 여전히 모른다. 이건 §3.5 원칙에 대한 예외가 아니라, "코어가 아는 유일한 state_dir 내부 계약"을 하나 정의하는 것이다.
- 스키마(코어가 아는 전부):
  ```json
  { "status": "complete" }
  ```
  또는
  ```json
  { "status": "failed", "reason": "선택적 자유 텍스트" }
  ```
- Stop hook은 `state_dir/status.json`이 존재하고 `status` 필드가 `"complete"` 또는 `"failed"`인지만 기계적으로 확인한다. `complete`/`failed` 둘 다 loop를 종료시키되, 종료 메시지를 다르게 표시한다(`failed`는 "pipeline이 스스로 실패를 신고함"으로 표시해 사용자가 max-iterations 소진과 구분할 수 있게 한다).
- 파일이 없거나 `status` 필드가 없거나 스키마가 깨졌으면 "아직 미완료"로 취급하고 다음 iteration을 진행한다 (원본의 jq graceful degradation 원칙 유지).
- pipeline 저작자는 `prompt.md`(또는 코어 기본 프롬프트, `--pipeline` 미사용 시)에 "완료로 판단되면 `state_dir/status.json`에 `{"status": "complete"}`를 Write 툴로 기록하라"는 지시를 담는다. **텍스트 재현이 아니라 툴 호출(Write)이므로 모델 종류와 무관하게 신뢰도가 높다.**
- 동시쓰기/부분쓰기 방지를 위해 임시 파일 + rename(mv) 원자적 쓰기를 pipeline 지시문에 권장 사항으로 명시한다(코어의 state 파일 갱신과 동일한 패턴, §10.2 항목9).
- `max_iterations`는 `status.json`이 끝내 안 써지는 경우의 **최종 안전장치**로 그대로 유지한다.

### 3.7 설정 기본값 파일 (Config Defaults File) (이번 개정 신규)

**배경**: `--pipeline`, `--max-iterations`처럼 프로젝트마다 사실상 고정되는 값을 매 `/loop-skill` 호출마다 다시 입력하는 건 불필요한 반복이다.

**결정**: 프로젝트 루트의 `.claude/loop-skill.config`(dotenv 형식, `KEY=VALUE`)에서 기본값을 읽는다.

```bash
# .claude/loop-skill.config (예시)
LOOP_SKILL_PIPELINE=l1-log-analysis
LOOP_SKILL_MAX_ITERATIONS=50
```

- **우선순위**: CLI 인자(`--pipeline`, `--max-iterations`) > `.claude/loop-skill.config` > 코어 내장 기본값(`max_iterations=50`, `pipeline=null`).
- 코어는 이 파일의 키를 정해진 몇 개(`LOOP_SKILL_PIPELINE`, `LOOP_SKILL_MAX_ITERATIONS`)만 안다 — pipeline별 세부 설정(예: L1 pipeline만의 옵션)은 이 파일이 아니라 `pipelines/<name>/prompt.md` 안에 pipeline 저작자가 직접 기술한다. 코어 config 파일에 도메인 특화 키가 늘어나기 시작하면 §3.5 원칙 위반 신호로 간주한다.
- `LOOP_SKILL_PIPELINE`의 값은 **`pipelines/` 바로 아래의 폴더 이름 그 자체**다(예: `pipelines/l1-log-analysis/`가 있으면 `LOOP_SKILL_PIPELINE=l1-log-analysis`). 코어는 이 값을 별도 검증 없이 `pipelines/<값>/prompt.md` 경로로 그대로 조합해 존재 여부만 확인한다 — 일치하는 폴더가 없으면(오타 포함) setup 스크립트가 "pipeline not found" 에러로 즉시 실패한다(§4.2.4, §8 Phase 2).
- 파일이 없으면 에러 없이 코어 내장 기본값을 쓴다 (하위 호환성 — 이 파일 없이도 기존처럼 CLI 인자만으로 완전히 동작해야 함).
- `setup-loop-skill.sh`가 이 파일을 읽어 state 파일 frontmatter의 `pipeline`/`max_iterations` 필드를 채운다(§6.1) — 즉 이 config 파일은 loop **시작 시점**에만 읽히고, state 파일에 값이 고정된 이후로는 관여하지 않는다(진행 중 config 파일을 바꿔도 이미 시작된 loop에는 영향 없음).

## 4. 디렉토리 구조

### 4.1 Skill Payload — 코어 (이번 구현 범위)

```
loop-skill/
├── .claude-plugin/
│   └── plugin.json
├── commands/
│   ├── loop-skill.md                # 범용 진입점 — 프롬프트/옵션만 처리, pipeline 내용은 모름
│   └── cancel-loop-skill.md
├── scripts/
│   └── setup-loop-skill.sh          # state 파일 + state_dir 생성 (스키마 강요 없음)
├── hooks/
│   ├── hooks.json
│   └── stop-hook.sh                 # 원본 ralph-loop stop-hook, 도메인 로직 없음
├── pipelines/                       # 확장점 — 이번 범위에서는 비어있거나 최소 예시 1개만
│   └── README.md                    # "여기에 pipelines/<name>/prompt.md를 추가하면 --pipeline <name>으로 쓸 수 있다"는 계약 설명
├── install/
│   ├── install.sh / install.ps1
│   ├── uninstall.sh / uninstall.ps1
│   └── install-state.json
└── README.md
```

### 4.2 확장 예시: L1 로그 분석 pipeline이 추가되면 어떻게 동작하는가 `[참고 — 이번 구현 범위 아님, §3.6 계약을 실제로 이해시키기 위한 워크스루]`

이번 구현 범위(§4.1)에는 `pipelines/`가 비어있거나 최소 예시 하나만 있다. **후속 작업으로 L1 로그 분석 pipeline을 추가한다면** 아래처럼 된다 — 핵심은 `commands/`, `scripts/`, `hooks/` 등 **코어 파일은 단 한 줄도 바뀌지 않는다**는 것이다. `pipelines/l1-log-analysis/` 디렉토리 하나가 통째로 추가될 뿐이다.

#### 4.2.1 Payload에 추가되는 것

```
loop-skill/
├── commands/                        # ← 그대로, 변경 없음
├── scripts/                         # ← 그대로, 변경 없음
├── hooks/                           # ← 그대로, 변경 없음
├── pipelines/
│   ├── README.md
│   └── l1-log-analysis/             # ← 새로 추가되는 부분 (전체 신규)
│       ├── prompt.md                # 고정 프롬프트 — orchestrator(역할③) 지시문 전체가 여기 담김
│       ├── agents/                  # 역할①②④⑤⑥⑦⑧에 대응하는 subagent 정의
│       │   ├── l1-issue-agent.md
│       │   ├── l1-timeline-agent.md
│       │   ├── l1-router-agent.md
│       │   ├── l1-analysis-agent.md
│       │   ├── l1-verifier-agent.md
│       │   ├── l1-aggregator-agent.md
│       │   └── l1-report-agent.md
│       └── playbooks/               # router(④)가 선택하는 분석 방법론
│           ├── memory-leak.md
│           ├── cache-miss.md
│           ├── io-error.md
│           └── unknown-pattern.md
└── install/                         # ← 그대로, 변경 없음
```

#### 4.2.2 설치 시 무엇이 달라지는가 — `agents/` 서브폴더에 대한 제네릭 규칙 추가

Pipeline이 subagent를 쓰려면 `.claude/agents/*.md`로 설치되어 있어야 `Agent` 툴이 호출할 수 있다. 이를 위해 §3.6 계약에 **제네릭 규칙**(항목 5)이 포함되어 있다 — 이것도 L1 전용이 아니라 모든 pipeline에 적용되는 규칙이다:

> installer는 `pipelines/<선택된 pipeline>/agents/*.md`가 존재하면, 그 내용을 `~/.claude/commands/*.md`와 같은 방식으로 `~/.claude/agents/`에 copy한다. 코어는 이 파일들의 **내용**을 알 필요가 없다 — "agents/ 폴더가 있으면 통째로 복사한다"는 위치 규칙만 안다.

즉 `register_hooks_and_commands()`(§9) 옆에 `register_pipeline_agents(pipeline_name)` 하나가 더 필요하다는 뜻이며, 이 함수도 pipeline 이름과 무관하게 동작하는 제네릭 함수다. `playbooks/`는 agent가 아니라 그냥 참고 문서이므로 별도 등록 없이 payload 안에 있는 그대로 읽힌다(agent가 Read 툴로 접근).

#### 4.2.3 사용자가 실행하는 명령

프로젝트에 `.claude/loop-skill.config`가 이미 있는 경우(§3.7), 매번 `--pipeline`/`--max-iterations`를 입력할 필요가 없다:

```bash
# .claude/loop-skill.config
LOOP_SKILL_PIPELINE=l1-log-analysis
LOOP_SKILL_MAX_ITERATIONS=50
```

```bash
/loop-skill "/var/log/kernel.log 분석해줘"
```

config 파일이 없거나 이번 실행만 다른 값을 쓰고 싶으면 기존처럼 CLI 인자로 override 할 수 있다:

```bash
/loop-skill --pipeline l1-log-analysis "/var/log/kernel.log 분석해줘" --max-iterations 100
```

`setup-loop-skill.sh`는 (CLI 인자 우선, 없으면 config 파일 순으로) `pipeline` 값을 확정한 뒤 `pipelines/l1-log-analysis/prompt.md`의 내용을 state 파일 본문으로 읽어들인다 — 이 시점에도 코어는 그 내용이 "8-agent orchestrator 지시문"이라는 걸 모른다. 그냥 텍스트 파일 하나를 읽어 복사할 뿐이다. 완료 조건은 더 이상 CLI 인자로 받지 않는다 — `prompt.md` 안에 "완료 시 `state_dir/status.json`에 `{"status":"complete"}`를 쓰라"는 지시가 포함되어 있고(§3.6.1), 코어는 그 파일만 확인한다.

#### 4.2.4 Iteration별 동작 흐름 (코어 관점에서는 "그냥 반복", 실제로는 pipeline이 다 함)

| Iteration | Stop Hook(코어)이 하는 일 | 메인 세션(prompt.md 지시를 따르는 LLM = orchestrator)이 하는 일 |
|---|---|---|
| 1 | state 파일 없음 → setup 실행, `state_dir` 생성(빈 디렉토리) | `state_dir`에 `manifest.json`이 없는 것을 확인 → 초기화 → `l1-issue-agent`를 Task로 호출 → 결과를 `manifest.json`에 기록 |
| 2 | `state_dir/status.json` 없음 확인 → 동일 프롬프트 재feed (본문 변경 없음) | `manifest.json` Read → `current_stage`가 `timeline-verification`임을 확인 → `l1-timeline-agent` 호출 → 기록 |
| 3~N | 동일 | `routing` → `log-analysis` → `verification`(위반 시 `needs_rework`로 되돌림) → `aggregation` → `report` 순으로 진행 |
| N+1 | `state_dir/status.json`의 `status`가 `complete`임을 확인 → state 파일 삭제, loop 종료 | 모든 stage `complete` && verifier 통과 && `report.md` 존재 확인 후 `state_dir/status.json`에 `{"status":"complete"}` Write |

Stop Hook 열의 동작은 코어 문서(§7.1)와 **완전히 동일하다** — L1 pipeline이 얹혀도 코어 코드는 정말 아무것도 모른 채로 그저 텍스트 매칭과 재feed만 반복한다. 복잡한 것은 전부 오른쪽 열, 즉 prompt.md의 지시를 따르는 LLM(과 그것이 호출하는 subagent들)의 몫이다.

#### 4.2.5 `state_dir` 안의 실제 모습 (iteration 3 시점 예시)

```
.claude/loop-skill/run-20260719-100000/
├── manifest.json              # current_stage: "log-analysis", 이전 3개 stage: complete
├── issue.md                   # complete
├── timeline.md                # complete
├── playbook-selection.json    # complete, selected: "memory-leak"
└── (analysis-findings.md 등은 아직 생성 전)
```

이 구조는 순전히 L1 pipeline이 스스로 정의한 것이다 — 다른 pipeline(예: "코드 리뷰를 반복하는 pipeline")이었다면 `state_dir` 안에 `review-round-1.md`, `review-round-2.md` 같은 완전히 다른 파일들이 생겼을 것이고, 코어는 그 차이를 전혀 신경 쓰지 않는다.

> 8-agent 역할 정의, `manifest.json` 상세 스키마, playbook 내용은 **부록 A**에 별도로 정리했다. 이 절은 "코어 위에 얹었을 때 실제로 어떻게 굴러가는지"의 흐름만 보여주는 것이 목적이다.

### 4.3 State 산출물 (설치 대상 머신, 프로젝트별로 생성됨)

```
<프로젝트>/.claude/
├── loop-skill.config                # (선택) --pipeline/--max-iterations 기본값, 사용자가 직접 작성 (§3.7)
├── loop-skill.local.md              # ralph-loop state 파일 (최소 frontmatter, §6.1)
└── loop-skill/
    └── <run-id>/                    # state_dir
        ├── status.json              # 완료 신호 — 코어가 아는 유일한 state_dir 내부 파일 (§3.6.1). 진행 중에는 없음
        └── (그 외는 pipeline 저작자 마음대로: 단일 report.md 하나일 수도, manifest.json + 여러 파일일 수도. §4.2가 L1 pipeline 기준 실제 예시)
```

## 5. 설치 아키텍처

### 5.1 Claude Code (1급 대상)

§3.1 표와 동일.

### 5.2 OMC (`oh-my-claudecode`, 선택 사항)

`.omc/skills/loop-skill.md` 단일 파일 — 설명용, loop와 무관. 설치 실패해도 전체 설치를 막지 않는다.

### 5.3 OpenCode (Tier 1, 조건부)

별도 설치 없음. §3.1 산출물이 그대로 재사용된다. installer는 OpenCode 감지 시 `oh-my-openagent` 설치 여부를 확인해 안내만 한다(에러 아님).

## 6. State 데이터 모델 (코어만, generic)

### 6.1 State 파일 (YAML Frontmatter, 최소화)

```yaml
---
active: true
iteration: 1
session_id: ses_xxx
max_iterations: 50            # 원본 ralph-loop 기본값 0(무제한)을 안전 기본값 50으로 오버라이드. CLI > .claude/loop-skill.config > 이 기본값 순으로 결정(§3.7)
started_at: "2026-07-19T10:00:00Z"
state_dir: ".claude/loop-skill/run-20260719-100000"
pipeline: null                 # --pipeline 옵션을 안 쓰면 null, 쓰면 pipeline 이름. CLI > config 파일 순으로 결정(§3.7)
---

[고정 prompt — --pipeline 지정 시 pipelines/<name>/prompt.md 내용, 아니면 사용자가 직접 입력한 프롬프트. 완료 시 state_dir/status.json을 쓰라는 지시가 이 본문(또는 코어 기본 프롬프트 템플릿)에 포함된다 — §3.6.1]
```

`completion_promise` 필드는 이번 개정으로 제거되었다 — 완료 판단은 frontmatter의 문자열이 아니라 `state_dir/status.json`(§3.6.1)로 옮겨졌다. `analysis_config`, `findings[]`, `manifest`, `agent` 같은 도메인 특화 필드도 코어 스키마에 **절대 넣지 않는다** — 그건 pipeline이 `state_dir` 안에 자기 마음대로 만드는 것이다.

### 6.2 State Dir 계약

코어가 보장하는 것은 "빈 디렉토리 하나가 존재한다"는 사실과, 그 안의 **딱 하나의 고정 이름 파일(`status.json`)**을 완료 판단을 위해 읽는다는 사실뿐이다(§3.6.1). `status.json` 이외의 내부에 무엇을 만들지(단일 파일, JSON 매니페스트, 여러 서브디렉토리)는 전적으로 pipeline의 몫이며, 코어의 setup 스크립트나 stop-hook은 `status.json`을 제외한 이 디렉토리 내부를 **절대 읽거나 쓰지 않는다**. `status.json`도 코어는 **쓰지 않는다** — pipeline(LLM)만 쓰고, 코어는 읽기만 한다.

## 7. 핵심 메커니즘 (코어)

### 7.1 Stop Hook Flow

```
[Session 종료 시도]
    ↓
[settings.json에 등록된 Stop Hook 커맨드 실행]   ← §3.1 등록 없으면 이 단계 자체가 없음
    ↓
[State 파일 존재 확인] → [Session isolation 체크] → [Iteration 증가 및 Max 체크]
    ↓
[state_dir/status.json 존재 + status 필드 확인]   ← 코어는 status가 "실제로" 참인지는 모름, 파일에 적힌 값만 기계적으로 읽음(§3.6.1)
    ↓
[미완료 시 동일한 고정 Prompt 재feed]   ← 본문 재생성 없음, pipeline 내용 무관
    ↓
[JSON 반환: block decision + prompt 재feed]
```

원본 ralph-loop의 `stop-hook.sh`(numeric validation, session_id 체크, jq graceful degradation)의 iteration/session/max-iterations 로직은 **수정 없이 그대로 재사용**한다. 완료 판단 부분만 원본의 `<promise>` transcript 텍스트 비교에서 `state_dir/status.json` 파일 확인으로 교체한다(§3.6.1) — 이 교체가 이번 개정에서 코어 코드에 가하는 유일한 실질적 수정이다. `status.json`이 없거나 스키마가 깨졌으면 미완료로 간주하는 것도 원본의 jq graceful degradation과 동일한 원칙이다. 이번 개정으로 "manifest.json을 읽어 verifier 통과를 확인" 같은 도메인 로직은 코어에서 완전히 제거된 상태를 유지한다 — 그런 판단은 pipeline의 프롬프트가 LLM에게 위임하는 것이지, Stop hook이 하는 일이 아니다.

### 7.2 Command 진입점

`commands/loop-skill.md`는 다음만 한다:
1. `setup-loop-skill.sh $ARGUMENTS` 실행 — CLI 인자(`--max-iterations`, `--pipeline`, `--state-dir`) 파싱 → 생략된 값은 `.claude/loop-skill.config`에서 읽고 → 그마저 없으면 코어 내장 기본값 사용(§3.7 우선순위)
2. `--pipeline <name>`이 (CLI 또는 config로) 확정되면 `pipelines/<name>/prompt.md` 내용을 state 파일 본문으로 사용, 아니면 사용자가 준 프롬프트 텍스트를 그대로 사용
3. Setup 스크립트가 `state_dir`를 생성 (내용은 비워둠 — pipeline이 이후 `status.json` 등을 채움)

### 7.3 활성 Loop 중복 방지

setup 스크립트는 기존 활성 state 파일이 있으면 거부한다(§10.2 항목 참고) — 이건 도메인 무관 안전장치이므로 코어에 포함한다.

## 8. 구현 단계 (코어만)

### Phase -1: 아키텍처 검증 스파이크 (blocking)
- [ ] `~/.claude/settings.json`의 `hooks.Stop`에 수동 등록 후 세션 종료 차단 재현 (Claude Code)
- [ ] `~/.claude/commands/*.md`가 plugin 없이 슬래시 커맨드로 인식되는지 확인 (Claude Code)
- [ ] `oh-my-openagent` 설치 환경에서 §3.1 산출물이 OpenCode에서도 발동하는지 확인 (Tier 1)

### Phase 0: 프로젝트 구조 설정
- [ ] §4.1 디렉토리 구조 생성

### Phase 1: ralph-loop 베이스 복사
- [ ] ralph-loop 전체 구조 복사, 이름 변경(ralph → loop-skill), 기본 동작 확인

### Phase 2: State 파일 + State Dir 스캐폴드
- [ ] §6.1 최소 frontmatter로 state 파일 생성 스크립트 작성 (`completion_promise` 필드 없음)
- [ ] `MAX_ITERATIONS` 기본값을 50으로 오버라이드
- [ ] `.claude/loop-skill.config` 파싱 로직 추가 (§3.7 — `LOOP_SKILL_PIPELINE`, `LOOP_SKILL_MAX_ITERATIONS`), CLI 인자 우선 병합
- [ ] setup 스크립트에 활성 loop 존재 시 거부 가드 추가
- [ ] `state_dir` 생성 로직 (내용은 비워둠 — §6.2 계약 준수)
- [ ] `--pipeline <name>` 옵션 파싱 (CLI 또는 config로 지정 시 `pipelines/<name>/prompt.md` 로드, 없으면 에러)

### Phase 3: Stop Hook
- [ ] 원본 ralph-loop stop-hook 이식 — iteration/session/max-iterations 로직은 그대로, 완료 판단부만 `<promise>` transcript 비교에서 `state_dir/status.json` 파일 확인으로 교체(§3.6.1, §7.1). 그 외 도메인 로직 없음을 코드 주석으로 명시
- [ ] `status.json` 없음/스키마 깨짐 시 graceful degradation(미완료로 취급) 처리
- [ ] settings.json 등록이 없으면 동작하지 않는다는 전제를 문서에 명시

### Phase 4: Command 정의
- [ ] `/loop-skill <prompt> [options]` 또는 `/loop-skill --pipeline <name> [options]`
- [ ] `${CLAUDE_PLUGIN_ROOT}` 제거, 설치 시점 절대경로 치환 전제로 템플릿 작성

### Phase 5: Pipeline 확장 계약 문서화 + 최소 스모크 검증
- [ ] `pipelines/README.md`에 §3.6 계약을 실제 사용자가 읽고 따라할 수 있는 형태로 작성
- [ ] **계약 검증용 최소 예시 pipeline 1개** 작성 (L1 로그 분석이 아닌, 아주 단순한 것 — 예: "파일 하나를 반복해서 다듬는" 정도의 1-stage pipeline) — 목적은 코어가 정말 도메인 무관하게 동작하는지 스모크 테스트하는 것뿐, 실사용 pipeline 완성이 목적이 아니다
- [ ] 부록 A(L1 로그 분석)의 구조가 코어 변경 없이 `pipelines/l1-log-analysis/`로 얹힐 수 있는지 **설계 리뷰만** 수행 (실제 구현은 후속 작업)

### Phase 6: Install Infrastructure
- [ ] `install.sh`/`install.ps1`: payload copy + jq 사전 체크(sh) + `register_hooks_and_commands()`(command 치환 설치 + settings.json 병합, 백업·유효성 재검증 포함) + `compute_source_hash()` + trap 기반 partial cleanup
- [ ] `register_pipeline_agents(name)` / `unregister_pipeline_agents(name)` — `pipelines/<name>/agents/*.md` 존재 시에만 동작하는 제네릭 함수 (§3.6 항목 5, §4.2.2). 이번 범위엔 실제 pipeline이 없어도 함수 자체는 만들어 둔다 (no-op 경로 테스트 가능하도록)
- [ ] `uninstall.sh`/`uninstall.ps1`: `install-state.json` 확인 → 기록된 것만 제거 → `unregister_hooks_and_commands()` + `unregister_pipeline_agents()`
- [ ] OpenCode 감지 + `oh-my-openagent` 존재 확인 + 안내 메시지 (§5.3)
- [ ] `install-state.json` 스키마: `source_hash`, 실제로 채워지는 `hooks_installed[]`/`files_created[]`/`files_modified[]`

### Phase 7: Integration
- [ ] Claude Code 전체 사이클(install → `/loop-skill` → loop 진행(옵션 없이, 그리고 `--pipeline` 예시 둘 다) → `status.json` 완료 신호 → uninstall) 검증
- [ ] Tier 1 OpenCode 전체 사이클 검증
- [ ] README/사용자 가이드 작성 (Tier 1 하드 의존성 + pipeline 확장 방법 명시)

## 9. Installer/Uninstaller 핵심 함수 (설계 원칙 — 전체 스크립트는 구현 스펙에서)

```bash
# install.sh 핵심 함수 시그니처
compute_source_hash()               # 소스 디렉토리 해시 → install-state.json.source_hash
register_hooks_and_commands()       # commands/*.md 치환 설치 + settings.json.hooks.Stop 병합(백업·jq empty 재검증·실패 시 롤백)
register_pipeline_agents(name)      # pipelines/<name>/agents/*.md가 있으면 ~/.claude/agents/에 copy (§4.2.2 — pipeline 이름과 무관한 제네릭 함수, 없으면 no-op)
detect_opencode_and_oh_my_openagent() # §5.3 감지/안내

# uninstall.sh 핵심 함수 시그니처
unregister_hooks_and_commands()     # files_created[] 삭제 + hooks_installed[].command 기준 jq del()로 정밀 제거
unregister_pipeline_agents(name)    # register_pipeline_agents()가 설치한 agent 파일만 files_created[]에 기록된 대로 정밀 제거
```

`install-state.json` 스키마:
```json
{
  "version": "1.0.0",
  "installed_at": "2026-07-19T10:00:00Z",
  "install_mode": "copy",
  "installations": {
    "claude_code": {"target": "~/.claude/skills/loop-skill", "source": "...", "type": "copy", "source_hash": "sha256:...", "installed": true, "verified": true}
  },
  "hooks_installed": [
    {"target_file": "~/.claude/settings.json", "event": "Stop", "command": "~/.claude/skills/loop-skill/hooks/stop-hook.sh", "backup_file": "~/.claude/settings.json.loop-skill.bak"}
  ],
  "files_created": ["~/.claude/commands/loop-skill.md", "~/.claude/commands/cancel-loop-skill.md"],
  "files_modified": ["~/.claude/settings.json"],
  "opencode": {"detected": false, "oh_my_openagent_detected": false}
}
```

Installer 규칙: 설치 전 `install-state.json` 존재 확인(있으면 에러), 실패 시 trap으로 partial cleanup, 완료 시에만 상태 파일 저장. Uninstaller 규칙: `install-state.json` 없으면 에러, 기록된 것만 제거, 완료 후 상태 파일 삭제.

## 10. 위험 요소 및 완화 (코어만)

### 10.1 아키텍처
1. **Payload copy만으로는 Stop Hook/커맨드가 등록되지 않음** → §3.1 명시적 등록으로 해결. 설치 스크립트가 등록 성공을 자체 검증한 뒤에만 `verified: true` 기록
2. **OpenCode 지원이 서드파티(`oh-my-openagent`) 하드 의존** → README/설치 메시지에 명시, 미설치 시 안내만
3. **`.omc/`와 OpenCode 혼동** → §3.4에 따라 항상 구분 표기
4. **코어에 도메인 로직이 스며드는 것** (이번 개정 신규 위험): 구현 중 "이럴 땐 report.md를 자동으로 만들어주면 편하지 않을까" 같은 유혹으로 코어에 특정 pipeline 가정이 하나둘 들어갈 위험 → **완화**: §3.6/§3.6.1 계약을 코드 리뷰 체크리스트로 명시 — `state_dir` 안에서 코어가 다뤄도 되는 파일은 `status.json` 단 하나뿐이며, 그 외 파일(이름 무관)을 읽거나 쓰는 코드가 setup/stop-hook에 추가되면 그 자체로 리뷰 반려 사유. `status.json`도 코어는 읽기만 하고 절대 쓰지 않는다(§6.2)

### 10.2 Ralph Loop
5. **무한 Loop**: `max_iterations` 기본값 50 강제(§3.7 config로 조정 가능), `status.json`이 끝내 안 써져도 이 기본값이 최종 backstop
6. **State 파일 손상**: 원본 numeric validation 재사용, 손상 시 graceful degradation
7. **Setup이 활성 loop를 덮어씀**: Phase 2 가드로 방지
8. **Session Isolation**: 상태 파일은 프로젝트당 1개. session_id 불일치 시 다른 세션의 Stop hook은 조용히 종료 허용 — "독립 상태"가 아니라 "겹치지 않게 막는" 수준으로 문서화
9. **Hook Race Condition**: state 파일과 `status.json` 갱신 모두 temp file + mv로 원자적 처리 (pipeline 프롬프트 지시에도 권장 사항으로 명시, §3.6.1)
10. **`status.json` 파싱 실패/스키마 오류**: jq 실패 또는 `status` 필드 누락 시 미완료로 간주하는 graceful degradation (원본의 transcript 파싱 실패 대응 원칙을 파일 확인 방식에 맞게 이전)

### 10.3 Installer/Uninstaller
11. **Installer/Uninstaller 매칭 실패**: `install-state.json` strict 기록/검증
12. **settings.json 병합 실패로 사용자 환경 손상**: 병합 전 백업, 병합 후 `jq empty` 재검증, 실패 시 즉시 롤백. uninstall은 정밀 제거 기본
13. **Copy Mode Storage Growth**: `source_hash` 불일치 감지 + 경고만
14. **플랫폼 경로 불일치**: Platform detection 함수, path normalization

(L1 로그 분석 pipeline 관련 위험 — rework 무한루프, manifest.json 동시쓰기 경합, OpenCode agent 포맷 미검증 등 — 은 코어 범위가 아니므로 부록 A로 이동)

## 11. 테스트 계획 (코어만, LLM Self-Testable)

1. **Fresh Install → Command/Hook 등록 확인**: `install.sh` 실행 후 커맨드 파일 존재, `${CLAUDE_PLUGIN_ROOT}` 리터럴 미존재, `settings.json`의 `hooks.Stop`에 항목 존재, 유효한 JSON, 백업 파일 존재
2. **Uninstall 정밀 복원**: uninstall 전 사용자가 추가한 다른 hook/permission이 uninstall 후에도 남아있는지 확인
3. **Active Loop 중복 방지**: 활성 loop가 있는 상태에서 재호출 시 명시적 에러, 기존 state 파일 불변
4. **Cross-Session Non-Interference**: 세션 B가 세션 A의 활성 loop 중 새 loop를 시작하려 하면 거부됨
5. **완료 신호 파일 확인 (§3.6.1)**: `state_dir/status.json`에 `{"status":"complete"}`가 쓰였을 때만 종료, 파일이 없거나 `status` 값이 다르면(예: `failed`, 스키마 오류) 종료하지 않거나 별도 메시지로 종료
6. **State Dir 비침습성 — `status.json` 예외 확인 (신규 — §3.6.1/§6.2 계약 검증)**: 코어(setup/stop-hook)가 `status.json`을 **쓰지 않고 읽기만** 하는지, 그 외 `state_dir` 내부 파일은 실행 전후로 하나도 만들거나 지우지 않았는지 확인
7. **옵션 없는 기본 사용**: `--pipeline` 없이 순수 프롬프트만으로도 완료 시 `status.json`을 쓰라는 지시가 기본 프롬프트 템플릿에 포함되어 정상 동작하는지 확인 (하위 호환성)
8. **`--pipeline` 기본 로딩**: Phase 5의 최소 예시 pipeline으로 `--pipeline <name>` 지정 시 해당 `prompt.md` 내용이 state 파일 본문에 실제로 들어가는지 확인
9. **Tier 1 OpenCode 재현**: `oh-my-openagent` 설치 환경에서 §3.1 산출물만으로 Stop hook 발동 확인
10. **Full Cycle**: install → `/loop-skill` → 반복 → `status.json` 완료 신호 → uninstall, 잔여 파일 없음
11. **Config 파일 우선순위 (신규 — §3.7 검증)**: `.claude/loop-skill.config`에 `LOOP_SKILL_MAX_ITERATIONS=30`을 두고 CLI로 `--max-iterations 10`을 주면 실제 적용값이 10(CLI 우선)인지, CLI 생략 시 30(config 값)인지 확인. config 파일이 아예 없을 때 코어 내장 기본값(50)이 적용되는지도 확인

## 12. 기술 스택

- **Language**: Bash(scripts/hooks), PowerShell(installers), Markdown(commands/pipeline prompt)
- **Data Format**: YAML(state frontmatter), JSON(hook 출력, install state)
- **File Operations**: cp(copy), rm, jq(JSON 병합/파싱)
- (Multi-Agent 관련 스택은 부록 A 참고 — 코어 범위 아님)

## 13. 체크리스트

- [ ] Phase -1 아키텍처 검증 완료 (blocking)
- [ ] Phase 0~7 완료
- [ ] Installer/Uninstaller 매칭 테스트, Safety 테스트
- [ ] §3.6 Pipeline 확장 계약 스모크 테스트 (최소 예시 pipeline 1개)
- [ ] §3.6.1 완료 신호(`status.json`) · §3.7 config 파일 우선순위 테스트
- [ ] Tier 1 OpenCode 검증
- [ ] README/사용자 가이드 (Tier 1 하드 의존성 + pipeline 확장 방법 명시)
- [ ] `implementation-spec.md` 동기화 (이 문서 확정 후)
- [ ] (후속 작업, 이번 범위 아님) 부록 A의 L1 로그 분석 pipeline을 `pipelines/l1-log-analysis/`로 실제 구현

## 14. 참고 문서

- `harness_loop_plan.md`(v01) — 이 계획의 조사 근거(CR-1~CR-8), 코드 인용, 시행착오 기록 (Multi-Agent Pipeline 최초 설계 포함)
- `implementation-spec.md` — 구현 스펙 (이 v02 확정 후 동기화 예정)
- ralph-loop 소스: `/home/fanta/.claude/plugins/marketplaces/claude-plugins-official/plugins/ralph-loop/`
- `oh-my-claudecode` 소스: `~/.claude/plugins/cache/omc/oh-my-claudecode/` (OMC 참고용)
- `oh-my-openagent` 소스: `~/.cache/opencode/packages/oh-my-openagent/node_modules/oh-my-openagent/` (Tier 1 근거)

---

## 부록 A: 예시 Pipeline — L1 로그 분석 (Multi-Agent) `[이번 구현 범위 아님 — §3.6 계약이 실제로 확장 가능함을 보여주는 참고 예시]`

이 부록은 코어가 완성된 뒤 **별도 작업으로** `pipelines/l1-log-analysis/`에 구현할 예시다. 각 agent의 내부 로직은 설계하지 않는다 — 여기서는 §3.6 계약 위에 이런 구조를 얹을 수 있다는 것만 보여준다.

### A.1 8개 역할 (예시)

| # | 역할 | 비고 |
|---|------|------|
| 1 | 문제점 파악 agent | subagent |
| 2 | Timeline 확인·로그 요약·이슈 시간대 검증 agent | subagent |
| 3 | Orchestration agent | **메인 세션 자체** — 코어의 "고정 프롬프트" 그 자체가 orchestrator 역할을 하도록 pipeline이 작성 |
| 4 | 분석 방법(playbook) 선택 router agent | subagent |
| 5 | 실제 로그 분석 agent | subagent |
| 6 | `manifest.json` 기반 파이프라인 준수 검사 verifier agent | subagent |
| 7 | 결과 취합·결론 aggregator agent | subagent |
| 8 | Report 작성 agent | subagent |

### A.2 `pipelines/l1-log-analysis/`가 `state_dir` 안에 만들 구조 (예시 — 코어와 무관)

```
<state_dir>/
├── status.json                # 완료 신호 — 코어가 아는 유일한 파일(§3.6.1), 마지막 iteration에만 존재
├── manifest.json               # 이 pipeline이 자체적으로 정의하는 스키마 — 코어는 이 파일의 존재도 모름
├── issue.md / timeline.md / playbook-selection.json / analysis-findings.md
├── verification-result.json / summary.md / report.md
```

`manifest.json` 예시 스키마(상세 설계는 후속 작업):
```json
{
  "current_stage": "issue-identification",
  "stages": [
    {"id": "issue-identification", "agent": "l1-issue-agent", "status": "pending", "rework_count": 0}
  ]
}
```

### A.3 이 예시가 §3.6 계약을 어떻게 쓰는지

- `pipelines/l1-log-analysis/prompt.md`(코어가 그대로 읽어 전달하는 고정 프롬프트)에 "manifest.json이 없으면 만들고, 있으면 orchestrator로서 다음 미완료 stage의 subagent를 호출하라"는 지시와, "모든 stage 완료 && verifier 통과 확인 후 `state_dir/status.json`에 `{"status":"complete"}`를 Write하라"는 완료 신호 지시(§3.6.1)를 함께 담는다 — **코어 코드 변경 없이** 이 로직 전체가 프롬프트 레벨에서 구현된다
- Agent 정의(`.claude/agents/l1-*.md`)는 pipeline 저작자가 별도로 준비 — 코어의 설치 스크립트가 이 파일들을 알 필요는 없다(다만 install 시 함께 복사되도록 pipeline 디렉토리 구조에 포함시킬 수는 있음, 후속 설계)
- OpenCode(Tier 1)에서는 `oh-my-openagent`의 `loadPluginAgents()`가 이 agent 정의를 포팅한다는 근거(§3.3)가 이미 확인되어 있으므로, 이 예시도 Tier 1에서 별도 코드 없이 동작할 가능성이 높다

### A.4 이 예시에만 해당하는 위험 (코어 위험 목록에서 제외된 것)

- **Rework 무한루프**: verifier가 같은 stage를 계속 `needs_rework`로 되돌릴 위험 → pipeline 자체의 `rework_count` 상한으로 완화 (코어의 `max_iterations`가 최후 안전망)
- **Iteration당 토큰/비용 폭증**: pipeline 프롬프트에 "iteration당 최대 1~2 stage" 지시로 완화
- **manifest.json 동시 쓰기 경합**: orchestrator만 쓰고 subagent는 산출물 파일만 쓰는 규칙으로 완화
- **OpenCode agent 포맷 미검증**: 코어 Phase -1과 별개로, 이 pipeline을 실제 구현할 때 재검증 필요
