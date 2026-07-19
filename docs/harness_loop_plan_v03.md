# 역방향 Loop 적용 — 기존 Skill을 Ralph-Loop으로 감싸기 (v03)

## 문서 정보

- 상태: 설계 확정 (구현 전). 적대적 검토 1회 + 배포 모델 재검토(copy 방식 전환) 반영 완료.
- 선행 문서: `harness_loop_plan_v02.md`, `implementation-spec_v02.md`
- 관계: v02는 "loop 코어 안에 pipeline을 넣는" 정방향(`/loop-skill --pipeline <name>`)을 다뤘다.
  v03은 그 **역방향** — 각 skill 이름 자체(`/l1-log-analysis`)가 진입점이 되어 그 skill을
  ralph-loop으로 돌리는 방식을 다룬다. **loop 엔진의 동작 규약은 건드리지 않는다.**
- 검토 반영 원칙: 이 프로젝트의 핵심 철학은 **미니멀리즘**(도메인 무관 코어, 최소 표면적)이다.
  적대적 검토가 제안한 다수의 방어 기능은 과공학·시기상조로 판단해 **§0 비목표**로 이관했고,
  실제 위험을 줄이는 소수의 알맹이만 각 절에 흡수했다.
- **v03 초안 대비 변경(중요):** 최초 초안은 엔진을 중앙(`loop-skill/`)에 두고 각 `-loop` skill은
  얇은 shim으로 그것을 호출하는 "중앙집중" 방식이었다. 이 방식은 (a) `-loop` skill을 단독으로
  배포할 수 없고, (b) meta의 버전 기록이 **거짓말**이 되는 결함이 있었다(중앙 엔진을 올리면 skill이
  조용히 새 버전으로 돎). → **엔진 start쪽(setup 스크립트)을 각 skill로 복사(bundle)하는 방식으로
  전환.** 버전 stamp가 authoritative해지고, shim과 경로 탐색 문제가 통째로 제거된다(§7.2, §12).

---

## 0. 비목표 (의도적으로 하지 않는 것)

아래는 적대적 검토·재검토에서 제안되었으나 **이번 범위에서 의도적으로 제외**한다. "빠뜨린 것"이
아니라 "안 하기로 결정한 것"이다. 필요해지면 그때 별도 개정으로 다룬다.

- **런타임 충돌 테스트** (apply 때 임시 command를 만들어 precedence 실측): `-loop` 접미사는 이름이
  겹치지 않아 precedence에 **의존하지 않는다**(§3.2). 불필요.
- **동시 실행 락(flock/.lock)**: 단일 사용자 대화형 도구. 동시 apply/unapply는 범위 밖.
- **디스크 공간·권한·악성 원본 수정·인코딩(BOM)·심볼릭 링크 방어**: 표준 파일 연산으로 충분.
- **UX 장식**: progress bar, 색상 출력, 에러 코드 체계, `--verbose`. (`--dry-run`만 유지 — §7.8.)
- **CLI 리네이밍**(`loop-skill-apply` 등): 사용자가 지정한 `apply_skill.sh`/`.ps1` 이름을 따른다.
- **버전 계약(contract) 강제·런타임 ABI 체크·마이그레이션 로직**: state/status 계약은 설계상
  동결(§10)이다. 버전 **가시성**만 제공하고(§9, §7.9), 강제 메커니즘은 만들지 않는다. 계약이
  언젠가 바뀌면 "훅 + 모든 wrap된 skill을 함께 올린다"는 **주석 한 줄**로 족하다.
- **산출 문서 세트**(빠른시작/FAQ/개발자 가이드), **feature flag/점진 롤아웃**, **성능
  최적화**(병렬 `--upgrade-all`, 캐싱, 압축), **외부 통합/확장성**(플러그인 매니저, 원격 저장소,
  사용자 정의 후킹): 제품화 활동. 범위 밖.

---

## 1. 개요

### 1.1 지금까지 (정방향)

```
/loop-skill --pipeline l1-log-analysis
   → setup-loop-skill.sh 가 state 파일 생성
   → Stop 훅이 매 iteration 프롬프트 재feed
```

사용자는 항상 **`/loop-skill`** 범용 진입점으로 시작하고 `--pipeline`으로 대상을 지정한다.
loop이 pipeline을 감싼다.

### 1.2 이번에 원하는 것 (역방향)

```
/l1-log-analysis-loop        ← skill 이름 자체가 진입점
   → (내부적으로 동일한 loop 엔진이 동작)
```

각 skill을 그 **이름으로 직접** ralph-loop처럼 돌린다. `/loop-skill`을 기억할 필요 없이 평소 쓰던
skill을 loop 모드로 쓴다.

### 1.3 이 문서의 핵심 명제 (thesis)

> **loop 엔진(전역 Stop 훅)은 "누가 state 파일을 만들었는지" 전혀 모른다. 따라서 역방향 설계에
> 엔진의 동작 규약 수정은 필요 없다 — 새로운 *생산자(producer)* 하나만 추가하면 된다.**

근거 (v02 코어 코드 확인):

- `hooks/stop-hook.sh`는 `.claude/loop-skill.local.md`의 frontmatter와 `<state_dir>/status.json`만
  읽는다. 프롬프트 본문 출처엔 관심 없다.
- `/loop-skill` 명령은 그 state 파일을 만드는 **하나의 생산자**일 뿐이다.
- `/l1-log-analysis-loop`라는 **또 다른 생산자**를 만들면 같은 엔진이 그대로 돈다.

역방향 생산자는 "state 파일을 만드는 start쪽 로직(`setup-loop-skill.sh`)"을 각 skill에 **번들**하고,
"반복을 담당하는 Stop 훅"은 **중앙에 하나만** 둔다(§7.2). 사용자가 제시한 두 옵션("이름으로 시작"과
"apply_skill.sh 헬퍼")은 결국 하나로 수렴한다: 등록을 자동화하는 `apply_skill.sh`가 정식 해법이다.

---

## 2. 핵심 요구사항 (사용자 확정)

1. 기존 skill을 **wrap**한다 (원본 로직 보존, 재작성 아님).
2. wrap 결과물은 **`-loop` 접미사** (`l1-log-analysis` → `l1-log-analysis-loop`).
   - 이유 A: 이름만 보고 loop 버전 여부 즉시 확인.
   - 이유 B: loop/non-loop 버전을 **중복으로 들고 있지 않아도 된다** (한 시점에 하나만 활성).
3. 원복(unapply) 시 **`-loop` 접미사를 떼서** 원래 skill로 되돌린다.
4. loop 코어가 업데이트되면 **재적용이 쉬워야** 한다 (`unapply → apply` 또는 `apply` 재실행).
5. **각 `-loop` skill은 자기완결적으로 배포 가능**해야 하고, **어떤 엔진 버전이 적용됐는지 확인
   가능**해야 한다 (이번 재검토로 추가된 요구 — §5.4, §7.9, §9).
6. Linux/Mac/WSL용 `apply_skill.sh`와 Windows용 `apply_skill.ps1`을 쌍으로 제공.

---

## 3. 결정적 발견 — 왜 "command 레이어"가 아니라 "skill 레이어"인가

> 공식 문서(code.claude.com/docs)로 검증한, 이번 설계의 가장 중요한 근거.

### 3.1 커스텀 command는 skill로 통합되었다

> "Custom commands have been merged into skills. A file at `.claude/commands/deploy.md` and a
> skill at `.claude/skills/deploy/SKILL.md` **both create `/deploy`** and work the same way."

즉 `commands/<name>.md`와 `skills/<name>/SKILL.md`는 **같은 `/<name>` 네임스페이스에서 충돌**한다.

### 3.2 충돌 시 **skill이 이긴다** → command 래퍼는 기각

> "if a skill and a command share the same name, **the skill takes precedence.**"

| 잘못된 접근 | 결과 |
|---|---|
| 기존 `skills/l1-log-analysis/SKILL.md` + 새 `commands/l1-log-analysis.md` | `/l1-log-analysis` 입력 시 **기존 skill 우선** → loop 래퍼 **조용히 무시** ❌ |

→ 생산자를 **skill 레이어**에 둔다. `-loop` 접미사는 이름이 달라 **충돌 자체가 없어**, precedence
규칙(버전 의존적일 수 있음)에 **의존하지 않는 설계**다.

### 3.3 SKILL.md는 command와 동일하게 동작한다 (템플릿 메커니즘 검증)

| 기능 | 확인된 사실 | 근거 |
|---|---|---|
| 디렉토리 이름 = `/명령어` | `skills/<dir>/SKILL.md` → `/<dir>`. frontmatter `name`은 표시 라벨 | L263, L273 |
| `$ARGUMENTS` | skill 본문에서 인자 전개 | L283, L310 |
| `` ```! `` 쉘 실행 블록 | skill 본문에서 bash/powershell 실행 (`shell` frontmatter) | L259 |
| `${CLAUDE_SKILL_DIR}` | **SKILL.md 디렉토리 절대경로** — cwd 무관 번들 참조 | L289 |
| `disable-model-invocation: true` | 사용자만 `/name` 호출, Claude 자동호출 차단 | L249, L341 |
| `allowed-tools` | 해당 턴 동안 지정 툴 무프롬프트 승인 | L251, L386 |

**핵심 부수효과:** `${CLAUDE_SKILL_DIR}` 덕분에 launcher가 **자기 디렉토리 안의** 번들 엔진과
pipeline을 직접 참조한다. 중앙 경로 탐색이나 `CLAUDE_PLUGIN_ROOT` 의존이 전혀 없다(§7.2).

---

## 4. 용어 정의

| 용어 | 의미 |
|---|---|
| **원본 skill** | 사용자가 이미 갖고 있거나 새로 작성한 `~/.claude/skills/<name>/SKILL.md`. 다단계 pipeline 로직 포함. |
| **loop 코어 / 엔진** | v02 도메인 무관 엔진. 두 부분으로 나뉜다: **start쪽**(`setup-loop-skill.sh` — state 파일 생성)과 **Stop 훅**(`stop-hook.sh` — 매 iteration 재feed). 배포 모델이 다르다(§7.2). |
| **번들 엔진 (bundled setup)** | apply 시 각 `-loop` skill 디렉토리로 **복사되는** `setup-loop-skill.sh`. 어느 loop-skill 릴리스에서 왔는지 `engine_version`으로 stamp된다(§9). 버전 기록을 authoritative하게 만드는 핵심. |
| **Stop 훅 런타임 (central hook)** | `~/.claude/settings.json`에 **한 번만** 등록되는 전역 Stop 훅. skill에 번들·복사할 수 없다(§7.2). loop-skill 설치 시 등록. |
| **`-loop` skill** | apply 결과물 `skills/<name>-loop/`. launcher `SKILL.md` + 번들 엔진 + `pipeline.md` + meta로 구성된 **자기완결 패키지**. |
| **pipeline 본문** | 원본 skill 본문(작업 지시). wrap 시 `-loop` skill 안 `pipeline.md`로 보존, loop이 매 iteration 재feed. |
| **완료 계약** | `<state_dir>/status.json`에 `{"status":"complete"}`(또는 `failed`)를 쓰라는 표준 지시(v02 §3.6.1). loop이 스스로 끝나는 유일한 신호. |

---

## 5. 설계 — `-loop` 접미사 rename 기반 wrap

### 5.1 상태 전이 (한 시점에 활성 skill은 항상 하나)

```
[apply]
  skills/l1-log-analysis/        (원본, 활성)
        │  rename + wrap + 엔진 번들
        ▼
  skills/l1-log-analysis-loop/   (자기완결 loop 패키지, 활성)   ← /l1-log-analysis-loop 로 확인
  loop-applied/backups/l1-log-analysis/ (원본 pristine 보관, 비활성)

[unapply]
  skills/l1-log-analysis-loop/   삭제
  loop-applied/backups/l1-log-analysis/ → skills/l1-log-analysis/  (복원, 접미사 제거)
```

- **중복 없음:** apply 후 `/l1-log-analysis` 사라지고 `/l1-log-analysis-loop`만 남는다(요구 2-B).
- **가시적 확인:** `/` 메뉴에 `-loop`가 보이면 적용됨(요구 2-A).
- **원본 기능 보존:** launcher가 돌리는 pipeline이 곧 원본 본문.

### 5.2 왜 삭제가 아니라 보관(backup)인가

- **원복**을 위해 pristine 원본 필요.
- **재적용/업그레이드** 시 pipeline 본문을 **항상 pristine 원본에서 재추출**. 이미 wrap된
  `pipeline.md`에서 재추출하면 완료계약 footer가 **중첩 누적**된다. pristine을 단일 진실원본으로
  두면 재적용이 몇 번이든 idempotent.

### 5.3 backup 저장 위치 (skill 스캔에 안 걸려야 함)

Claude Code는 `skills/<name>/SKILL.md`를 한 단계로 스캔한다. 백업을 `skills/` 아래 두면 유령
skill로 등록될 위험 → **skills/ 바깥**에 둔다:

```
~/.claude/loop-applied/
  backups/<name>/            # pristine 원본 디렉토리 통째로
  apply-state.json          # 적용 이력 — 원복 대칭성 보장
```

### 5.4 배포 모델 — "skill 단독 release"의 실제 의미와 한계

`-loop` skill 디렉토리는 launcher + 번들 엔진(`setup-loop-skill.sh`) + `pipeline.md` + 부가 파일 +
meta로 **자기완결**이다. 그러나 완전 zero-dependency는 아니다:

- **번들 가능(start쪽):** state 파일을 만드는 `setup-loop-skill.sh`는 skill 안에 복사되므로 함께
  이동한다.
- **번들 불가(Stop 훅):** Claude Code는 `settings.json`에 등록된 훅만 실행한다. skill 폴더 안의
  `stop-hook.sh`는 아무 일도 안 한다. 게다가 skill마다 훅을 넣고 N개를 등록하면 매 Stop마다 N개가
  동시 발화해 공유 state 파일을 두고 **경쟁**한다(iteration 이중 증가 등). → Stop 훅은 **머신당 하나,
  중앙 등록**이어야 한다.

따라서 정직한 release 스토리:

> **`-loop` skill 폴더를 대상 머신 `~/.claude/skills/`로 복사** + **대상 머신에 loop Stop-훅 런타임을
> 1회 설치**(= loop-skill 플러그인의 훅을 settings.json에 등록).

중앙집중 초안 대비 개선점: 공유 의존성이 "`loop-skill` 전체"에서 "**Stop 훅 하나**"로 줄고, skill이
어떤 엔진 버전을 쓰는지가 `engine_version`으로 **고정·확인 가능**해진다(더 이상 중앙 엔진 업그레이드에
조용히 끌려가지 않는다).

**크로스-OS:** `-loop` 폴더는 `.sh`+`.ps1` 엔진을 둘 다 담아 OS 중립이다(§7.1.2). 다른 OS 머신에서는
그 OS의 `apply`(재wrap)로 launcher만 재생성하면 되고, 그 머신의 Stop 훅 런타임은 여전히 1회 설치가
전제다.

---

## 6. 디렉토리 구조 (apply 전후)

### 6.1 apply 전

```
~/.claude/skills/
  loop-skill/                     # v02 loop 코어 (설치됨 — Stop 훅 런타임 + 엔진 원본)
  l1-log-analysis/                # 원본 skill
    SKILL.md                      # frontmatter + 다단계 pipeline 본문
    agents/*.md                   # (있으면) subagent 정의
    playbook.md                   # (있으면) 참고 파일
```

### 6.2 apply 후

```
~/.claude/skills/
  loop-skill/                     # 코어 (그대로) — Stop 훅이 여기서 중앙 동작
  l1-log-analysis-loop/           # ← 새 활성 skill (자기완결 패키지)
    SKILL.md                      # [생성] loop launcher — apply한 OS에 맞는 shell로 생성 (§7.1)
    setup-loop-skill.sh           # [번들·복사] engine_version stamp된 start쪽 엔진 (bash)
    setup-loop-skill.ps1          # [번들·복사] 동일 엔진 (PowerShell) — 크로스-OS 재wrap용 (§7.1.2)
    pipeline.md                   # [생성] 원본 본문 + 완료계약 footer
    agents/*.md                   # 원본에서 복사 (있으면)
    playbook.md                   # 원본에서 복사 (있으면)
    .loop-meta.json               # [생성] 출처/엔진 버전 (§9)
~/.claude/loop-applied/
  backups/l1-log-analysis/        # pristine 원본 (비활성)
  apply-state.json
```

원본 `l1-log-analysis/`는 skills 경로에서 사라진다 → `/l1-log-analysis` 미노출.
(초안의 `run-loop.sh` shim은 없어졌다 — launcher가 번들 엔진을 직접 호출하므로. §7.2)

---

## 7. `-loop` skill launcher 및 apply/unapply 동작

### 7.1 `SKILL.md` 템플릿 (apply 시 생성)

```markdown
---
name: l1-log-analysis-loop
description: "<원본 description> (ralph-loop 모드: 완료까지 self-referential 반복)"
disable-model-invocation: true
allowed-tools: ["Bash(${CLAUDE_SKILL_DIR}/setup-loop-skill.sh:*)"]
---

# l1-log-analysis (loop-wrapped)

​```!
"${CLAUDE_SKILL_DIR}/setup-loop-skill.sh" --prompt-file "${CLAUDE_SKILL_DIR}/pipeline.md" $ARGUMENTS
​```

이 skill은 위 pipeline을 self-referential loop으로 실행합니다. 매 iteration에서 같은
`pipeline.md`가 재feed되며, 직전 결과물은 파일(및 보고된 `state_dir`)과 git 히스토리로 이어집니다.

CRITICAL: loop은 pipeline이 `<state_dir>/status.json`에 `{"status":"complete"}`를 Write 툴로
기록하거나 `--max-iterations`에 도달할 때만 멈춥니다. 완전히 끝났을 때만 complete를 쓰세요.
진짜 불가능하면 `{"status":"failed","reason":"<사유>"}`를 쓰세요.
```

설계 포인트:
- 디렉토리 이름 `l1-log-analysis-loop` → 명령어 `/l1-log-analysis-loop`. 별도 command 등록 불필요.
- `${CLAUDE_SKILL_DIR}`로 **자기 디렉토리 안의** 번들 엔진과 `pipeline.md`를 직접 호출 → cwd·중앙
  경로 무관. shim 불필요.
- `$ARGUMENTS`로 `/l1-log-analysis-loop --max-iterations 30` 전달.
- `disable-model-invocation` 정책은 §7.1.1 참조.

#### 7.1.1 `disable-model-invocation` — 안전 기본값과 원본 보존의 트레이드오프

`disable-model-invocation`은 Claude Code의 skill frontmatter 필드로, "누가 이 skill을 실행시킬 수
있는가"를 결정한다.

| 값 | 사용자가 `/name` 호출 | Claude가 대화 맥락상 자동 호출 |
|---|---|---|
| 미설정(기본값 `false`) | 가능 | 가능 |
| `true` | 가능 | **불가** — 사용자가 직접 쳐야만 실행 |

**launcher는 기본적으로 `true`를 강제한다.** loop은 여러 iteration에 걸쳐 자동 반복되는, 되돌리기
어려운 워크플로우이므로 Claude가 맥락만으로 loop을 켜면 위험하다(`/deploy` 자동 트리거 금지와 같은
이유).

**문제:** 원본 skill이 이 필드를 설정하지 않았다면(= 자동호출을 활용하도록 설계됐다면), wrap 시
`true` 강제는 "wrap = 원본 로직 보존"(요구 1)을 조용히 어긴다.

**해결 — `--keep-model-invocation` (apply_skill.sh 플래그):**

| apply 명령 | launcher의 `disable-model-invocation` |
|---|---|
| `apply_skill.sh <name>` (기본) | `true` 강제 (안전 우선) |
| `apply_skill.sh --keep-model-invocation <name>` | 원본 skill의 실제 값을 그대로 반영 |

**재적용 시에도 이 선택이 흔들리지 않도록**, 최초 apply의 결정을 `.loop-meta.json`의
`model_invocation_policy`에 고정해 §7.4 재적용이 그대로 재현한다(§9). 요약: **"안전이 기본값, 원본
재현은 옵트인 — 그 선택은 meta에 고정되어 재적용에도 유지."**

#### 7.1.2 크로스-OS — `.sh` + `.ps1` 엔진 둘 다 번들

번들 엔진이 bash(`setup-loop-skill.sh`) 하나뿐이면 Git Bash 없는 Windows에서 `-loop` 폴더가 돌지
않는다. → **두 엔진을 항상 함께 번들**한다: `setup-loop-skill.sh`(bash) + `setup-loop-skill.ps1`
(PowerShell). 폴더 자체는 OS 중립이 된다.

launcher `SKILL.md`의 `!`-블록은 한 skill당 하나의 `shell`만 쓰므로(bash **또는** powershell), **활성
launcher는 apply를 실행한 OS에 맞춰 생성**한다:

| apply 실행 | 생성되는 launcher `shell:` | `!`-블록이 부르는 엔진 |
|---|---|---|
| `apply_skill.sh` (Unix/WSL/Git Bash) | 미지정(기본 bash) | `${CLAUDE_SKILL_DIR}/setup-loop-skill.sh` |
| `apply_skill.ps1` (Windows PowerShell) | `powershell` | `${CLAUDE_SKILL_DIR}/setup-loop-skill.ps1` |

**크로스-OS 이동(예: Mac에서 만든 skill을 Windows에서 실행):** 폴더에 두 엔진이 이미 들어 있으므로,
대상 OS에서 `apply`(또는 `--rewrap`)만 다시 돌리면 그 OS용 launcher가 이미 번들된 엔진으로부터
**오프라인으로 재생성**된다. 네트워크·재다운로드 불필요. `pipeline.md`·meta·백업은 그대로 유지.

즉 "폴더는 OS 중립(두 엔진 보유), 활성 launcher만 OS별"이라는 구조로 self-contained 배포가 OS를
가로질러 성립한다. (두 엔진은 동일 계약(§10)을 구현하므로 어느 쪽을 써도 중앙 Stop 훅과 상호운용.)

### 7.2 엔진 배포 모델 — 번들 setup(복사) vs 중앙 Stop 훅

이번 설계의 핵심 결정. loop 엔진은 두 부분이고 배포 방식이 다르다.

| 부분 | 하는 일 | 배포 방식 | 이유 |
|---|---|---|---|
| `setup-loop-skill.sh` (start쪽) | state 파일 생성 후 종료 | **각 `-loop` skill에 복사(번들)** | launcher가 `${CLAUDE_SKILL_DIR}`로 직접 호출 → shim·경로탐색 불요. 버전 stamp가 authoritative. skill이 자기완결. |
| `stop-hook.sh` (Stop 훅) | 매 iteration 프롬프트 재feed | **중앙 1개, settings.json 등록** | 훅은 settings.json에 등록돼야만 발화. skill별로 N개 등록하면 매 Stop마다 경쟁(§5.4). |

두 부분은 **state 파일 스키마 + `status.json` 신호**라는 동결된 계약(§10)으로만 통신하므로, 번들
setup과 중앙 훅이 버전이 달라도 그 계약만 지키면 상호운용된다. (계약 자체는 v02에서 동결. 강제
체크는 하지 않음 — §0.)

**초안 대비:** `run-loop.sh` shim과 "중앙 코어 경로를 런타임에 찾는" §7.2 로직 전체가 **삭제**된다.
`${CLAUDE_SKILL_DIR}/setup-loop-skill.sh`가 경로 문제를 공짜로 해결한다.

> **번들 전제 검증(구현 시 확인):** `setup-loop-skill.sh`는 `--pipeline` 분기에서만
> `${CLAUDE_PLUGIN_ROOT}/pipelines/`를 참조한다. `-loop` skill은 `--prompt-file`만 쓰므로 이 분기를
> 타지 않아, 스크립트는 자기 위치와 무관하게 **재배치 가능(relocatable)**하다. state/config 경로는
> 프로젝트 상대(`.claude/…`)라 문제없다.

### 7.3 `apply_skill.sh <origin>` — 적용

입력: 원본 skill 디렉토리 또는 임의 소스 디렉토리.

1. **검증:** 대상 존재, `SKILL.md` 존재, `jq` 존재, **번들할 엔진 소스**(설치된 loop-skill의
   `setup-loop-skill.sh`/`.ps1`) 위치·버전 확인.
2. **이름 도출 + 충돌 검사:** `<name>` = basename → 결과 `<name>-loop`.
   - 원본 이름이 이미 `-loop`로 끝나면(이미 wrap된 것으로 추정) **install 실패**, 사유
     `이미 loop skill입니다: <name>` 출력.
   - `skills/<name>-loop/`가 이미 존재하면 `.loop-meta.json` 유무로 판별:
     - **meta 있음** → 우리가 만든 이전 wrap → 재적용(§7.4)으로 분기.
     - **meta 없음** → **무관한 동명 skill.** 덮어쓰면 데이터 손실이므로 **install 실패**로
       중단하고 사유 `동일 skill 존재: <name>-loop (loop wrap이 아님 — 이름 변경 또는 제거 후 재시도)`
       를 출력해 사용자가 원인을 알게 한다. (자동 덮어쓰기 없음.)
3. **pristine 백업:** 원본을 `loop-applied/backups/<name>/`로 이동. `apply-state.json`에 기록.
4. **pipeline 본문 추출:** `SKILL.md`에서 **첫 두 `---`(frontmatter)만 제거**하고 본문을
   `pipeline.md`로. 뒤쪽 `---`는 보존. **본문이 비면(frontmatter-only) 에러.**
5. **완료 계약 자동 주입(§8):** 완료 지시 미포함 시 표준 footer append.
6. **엔진 번들(양쪽 OS):** 설치된 loop-skill의 `setup-loop-skill.sh`와 `.ps1`을 **둘 다** `-loop`
   디렉토리로 복사(§7.1.2)하고, 그 출처 버전을 meta `engine_version`에 stamp.
7. **launcher 생성:** `skills/<name>-loop/SKILL.md`를 §7.1 템플릿으로. 원본 `description` 계승.
8. **부가 파일 복사:** 원본 `agents/`·참고 문서 복사. `agents/*.md`는 install 규약대로
   `~/.claude/agents/`에도 등록(선택).
9. **meta 기록:** `.loop-meta.json`(§9).
10. **트랜잭션:** 어느 단계든 실패 시 원본 복원 롤백(v02 install.sh `cleanup_on_failure` 패턴).
11. 결과 출력: "적용됨: /l1-log-analysis-loop (engine v0.1.0, 원본은 backups에 보관)".

### 7.4 재적용 / 업그레이드 (idempotent)

`apply_skill.sh <name>` 또는 `--upgrade <name>`를 이미 wrap된 대상에 재실행:
- pipeline 본문을 **pristine 백업에서 재추출**(§5.2 — 현재 `pipeline.md`에서 재추출 금지).
- **번들 엔진(`setup-loop-skill.sh` + `.ps1` 둘 다)을 현재 설치된 loop-skill 버전으로 재복사**,
  `engine_version` 갱신.
- launcher/완료계약 footer 재생성. `model_invocation_policy`는 meta에서 읽어 유지(§7.1.1).
- 원본 백업·`agents/`는 유지.

→ 코어가 바뀌어도 **`apply`만 다시 하면** 각 skill의 번들 엔진이 최신으로 교체된다(요구 4).

### 7.5 `--upgrade-all`

`skills/*-loop/` 중 `.loop-meta.json`이 있는 대상 전부에 §7.4 적용. loop-skill 새 릴리스 설치 후
일괄 재번들.

### 7.6 `unapply_skill.sh <name>` — 원복

1. `skills/<name>-loop/` 삭제(번들 엔진 포함).
2. `loop-applied/backups/<name>/` → `skills/<name>/` 복원 (접미사 제거).
3. 백업·meta 정리, `apply-state.json` 항목 제거.
4. `agents/` 중 이 apply가 등록한 것만 제거(install-state 대칭 원칙).

**요구 4의 두 경로 모두 지원:** `unapply → apply`(완전 재구성), `apply` 재실행(제자리 업그레이드).

### 7.7 신규 작성(원본이 기존 skill이 아닌 경우)

임의 소스를 loop pipeline으로 처음 만들 때: rename/백업 없이 곧바로 `<name>-loop` 생성(엔진 번들
포함). meta에 `origin: authored`. unapply는 `-loop` 삭제만.

### 7.8 `--dry-run`

apply/unapply에 `--dry-run` 지원 — 실제 변경 없이 "무엇이 이동/생성/삭제될지"만 출력. 파괴적
rename 전 저비용 확인.

### 7.9 `--status` / `--list` — 무엇이 어떤 버전으로 적용됐나 (요구 5)

`apply_skill.sh --list`(또는 `--status [<name>]`)는 `skills/*-loop/`의 `.loop-meta.json`을 읽어
표로 출력한다:

```
NAME                    ORIGIN    ENGINE   APPLIED_AT
l1-log-analysis-loop    wrapped   0.1.0    2026-07-19
l2-triage-loop          authored  0.2.0    2026-07-20
```

설치된 loop-skill 버전과 각 skill의 `engine_version`을 비교해 **뒤처진 skill을 표시**(업그레이드
후보 안내). 버전 **가시성**까지가 범위이며, 자동 강제 업그레이드는 하지 않는다(§0).

---

## 8. 완료 계약 자동 주입 — "아무 skill에나 쉽게"를 진짜로 만드는 장치

숨은 전제: **pipeline이 `status.json`을 쓰지 않으면 loop은 영원히 안 끝난다**(`--max-iterations`까지
소모). 작성자가 매번 손으로 넣게 하면 "쉽게"가 성립하지 않는다.

→ `apply_skill.sh`가 표준 완료계약 footer를 `pipeline.md`에 **자동 append**:

```markdown

---
## Loop 완료 신호 (loop 코어가 자동 주입)
작업이 진짜로 완전히 끝났다면, Write 툴로 `<state_dir>/status.json`에 정확히 다음을 기록해
loop을 종료하세요:
    {"status": "complete"}
escape 용도로 앞당겨 쓰지 마세요. 진짜 불가능하면 대신:
    {"status": "failed", "reason": "<짧고 정직한 사유>"}
```

- **중복 방지:** `(status\.json|완료.*신호|completion.*signal)` (대소문자 무시) 감지 시 주입 안 함.
- **lint:** 감지도 주입도 안 된 경우 **경고**(loop이 self-terminate 못 할 수 있음).
- 재적용 시 항상 pristine에서 재생성하므로 footer가 쌓이지 않음(§5.2).

---

## 9. `.loop-meta.json` 데이터 모델

각 `-loop` skill 디렉토리에 두어 idempotency·업그레이드·버전 가시성에 사용. **실제로 쓰이는
필드만** 둔다(추측성 확장 배제 — §0).

```json
{
  "origin_name": "l1-log-analysis",
  "origin": "wrapped",                       // "wrapped" | "authored"
  "origin_path": "~/.claude/skills/l1-log-analysis",
  "backup_path": "~/.claude/loop-applied/backups/l1-log-analysis",
  "origin_checksum": "sha256:...",           // pristine 원본 SKILL.md 해시 (drift 감지)
  "engine_version": "0.1.0",                 // 번들된 setup-loop-skill.sh가 나온 loop-skill 릴리스 (authoritative)
  "template_version": "1",                   // launcher 템플릿 버전
  "original_model_invocation": "disabled",   // 원본 값 (참고 기록)
  "model_invocation_policy": "forced-disabled", // "forced-disabled" | "preserved" — §7.1.1 결정. 재적용에 그대로 재현
  "contract_injected": true,
  "applied_at": "2026-07-19T00:00:00Z"
}
```

- `engine_version`은 **번들된 엔진 파일 자체의 출처 버전**이라 거짓말이 되지 않는다(중앙집중 초안의
  결함 해소). `--status`(§7.9)가 이 값을 읽는다.
- `model_invocation_policy`(실제 반영 결정)와 `original_model_invocation`(원본 참고값)을 분리해,
  재적용 시 재판단 없이 정책을 재생산한다(§7.1.1).
- `origin_checksum`으로 drift 감지: 재적용 시 pristine 백업 해시를 재계산해 불일치 시 **경고 +
  `--force` 확인**(git 검사·mtime 등 추가 감지는 안 함 — §0).

`apply-state.json`(전역, `loop-applied/`)은 어떤 원본이 어디로 이동됐는지 목록을 들어 원복
대칭성을 보장한다(v02 install-state.json과 같은 원칙).

---

## 10. 코어 변경 사항 (단 하나, 사소함)

loop **엔진 동작 규약**(stop-hook, state 스키마, 완료 신호)은 **불변.** setup 스크립트에 입력 모드
하나만 추가:

- **`--prompt-file <path>` 신설:** 기존 `--pipeline <name>`·인라인 PROMPT에 더해, **임의 절대경로의
  프롬프트 파일**을 loop 본문으로 읽는다. `-loop` skill의 `pipeline.md`(같은 디렉토리)를 가리킨다.
  - 우선순위: `--pipeline` > `--prompt-file` > 인라인 PROMPT.
  - `--prompt-file`은 절대경로라 `CLAUDE_PLUGIN_ROOT` 의존이 없다 → 번들 엔진이 어디로 복사돼도
    동작(§7.2 relocatable 근거).

그 외 `--max-iterations`, `.claude/loop-skill.config` 기본값, `[CR-4]` 활성 loop 가드는 재사용.

**계약 동결 주석:** state 파일 스키마와 `status.json` 신호는 v02에서 동결됐다. 만약 이 계약이 언젠가
바뀌면 **중앙 Stop 훅과 모든 wrap된 skill의 번들 엔진을 함께 올려야 한다**(`--upgrade-all`). 이를
자동 감지·강제하는 메커니즘은 만들지 않는다(§0).

---

## 11. 동시성 · cancel · config

- **활성 loop 1개 제한(프로젝트당):** `.claude/loop-skill.local.md` + `[CR-4]` 가드로, **같은
  프로젝트 디렉토리**에서는 한 시점에 loop 하나뿐. `-loop` loop과 일반 `/loop-skill` loop은 같은
  프로젝트라면 **동시 실행 불가** — 알려진 제약.
- **Stop 훅은 중앙 1개:** 여러 `-loop` skill이 있어도 훅은 하나뿐이라 경쟁이 없다(§7.2). 활성 loop을
  구분하는 것은 훅 개수가 아니라 단일 state 파일이다.
- **cancel 재사용:** (같은 프로젝트에서) 활성 loop이 하나이므로 기존 `/cancel-loop-skill`이 그대로
  중단. skill별 cancel 불필요.
- **per-skill 기본값:** `.claude/loop-skill.config`(프로젝트 전역) 재사용. CLI 인자 우선(v02 §3.7).

### 11.1 여러 loop을 동시에 돌리는 것과, 훅을 여러 개 등록하는 것은 다른 축이다

두 가지가 자주 혼동되므로 구분해서 명시한다.

**병렬성은 세션/프로젝트 축에서 나온다 — 훅 개수와 무관.** `stop-hook.sh`는 이미 두 가지로
다중 세션을 지원한다:
- **state 파일이 프로젝트 상대경로**(`.claude/loop-skill.local.md`, `stop-hook.sh:12`) — 프로젝트
  A와 B에서 각각 세션을 열면 서로 다른 state 파일을 보므로 애초에 안 부딪힌다.
- **session_id 체크**(`stop-hook.sh:24-28`) — state 파일과 hook input의 `session_id`가 다르면 그
  세션의 훅 호출은 즉시 `exit 0`. 남의 세션 loop에 손대지 않는다.

즉 프로젝트 X에서 `l1-log-analysis-loop`가 돌고 프로젝트 Y에서 `l2-triage-loop`가 동시에 돌아도,
**훅은 1개**로 충분하다. 이 병렬성은 "skill마다 자기 훅을 갖는 것"에서 나오는 게 아니라 "state
파일이 프로젝트/세션별로 격리된 것"에서 나온다.

**훅을 skill마다 번들·등록하면 얻는 건 병렬성이 아니라 중복 실행이다.** Claude Code 훅은
"어떤 skill이 이 loop을 시작했는지" 라우팅하지 않는다 — 등록된 Stop 엔트리는 **매 Stop 이벤트마다
전부** 실행된다. skill 3개가 각자 자기 훅 사본을 등록하면:

```
세션 1개, Stop 이벤트 1번
  → 훅 사본 #1: state 읽음 → iteration 5→6, block
  → 훅 사본 #2: 같은 state 읽음 → 6→7, block   (같은 세션의 같은 loop을 또 처리)
  → 훅 사본 #3: 7→8, block
```

병렬 loop 3개가 아니라 **loop 1개의 iteration이 Stop마다 3배로 뜀**. `--max-iterations 50`이
실제로 ~17회에 끝나고 block 결정도 중복 발생한다 — 이것이 §5.4/§7.2가 "Stop 훅은 중앙 1개"를
못 박은 이유다.

### 11.2 하나의 훅이 서로 다른 종료 조건의 loop들을 동시에 안전하게 처리하는 이유

프로젝트 X의 `l1-log-analysis-loop`는 아직 완료 조건이 안 됐고, 프로젝트 Y의 `l2-triage-loop`는
완료됐다고 하자. 이 둘은 같은 중앙 훅(같은 코드)에 걸리지만 서로 전혀 간섭하지 않는다 — 훅이
**무상태(stateless)** 이고, loop을 구분하는 상태가 전부 loop별 파일에 있기 때문이다. 격리는
3단계로 쌓인다:

1. **state 파일이 프로젝트별** — 훅은 실행될 때 그 세션의 cwd 기준 `.claude/loop-skill.local.md`를
   읽는다. X와 Y는 서로 다른 state 파일을 본다(§11.1).
2. **session_id 체크** — 남의 세션 state 파일은 애초에 손대지 않는다(§11.1).
3. **완료 신호(`status.json`)도 loop별** — 전역 파일이 아니라 **각 loop의 `state_dir` 안**에 있다
   (`.claude/loop-skill/<run-id>/status.json`). 훅은 이 경로를 **자기가 방금 읽은 state 파일의
   `state_dir` frontmatter**에서 얻는다(`stop-hook.sh:21, 51-52`). 즉 매 호출이
   "그 세션의 state 파일 → 그 loop의 status.json"이라는 자기 체인만 따라간다. Y가 자기
   `status.json`에 `complete`를 써도 X를 처리하는 훅 호출은 그 파일을 볼 방법 자체가 없다.

**경계 조건:** 이 독립성은 **서로 다른 프로젝트 디렉토리**일 때만 성립한다. 같은 프로젝트에서
두 loop을 동시에 시작하려 하면 state 파일 경로가 같으므로 `[CR-4]` 가드가 **시작 자체를 거부**한다
(§11 첫 항목). 즉 충돌 가능 지점은 시작 시점에 차단되고, 시작에 성공한 loop들끼리는 위 3단계로
완전 독립이다.

### 11.3 single loop 안전성 & 기존 ralph-loop과의 충돌 여부

**single loop 실행 = v02와 동일, 새 critical 결함 없음.** 훅이 중앙에 **정확히 1개** 등록된 상태에서
loop 하나를 도는 런타임 경로(setup이 state 씀 → Stop 훅이 status.json 확인 → 재feed/종료)는 이미
검증된 v02 ralph-loop와 바이트 단위로 동일하다. 역방향 설계가 바꾼 것은 *생산자*(state 파일을 만드는
launcher)뿐이다. §13.1의 risk들은 다중 등록·배포·재실행 축에서만 발현하며, R1(중복 등록)·R3(state
지뢰)만이 single loop에도 영향을 줄 수 있는데 이는 *실행*이 아니라 *등록/이전 실행 잔재* 문제다.

**`/loop-skill`(이 프로젝트의 ralph-loop 코어)과 충돌하지 않는다.** 둘은 **같은 state 파일 + 같은
중앙 훅**을 공유하는 *동일 시스템의 두 생산자*다. 같은 프로젝트에선 `[CR-4]`가 상호배제하고 cancel도
공유한다. 다른 프로젝트면 독립(§11.2).

**외부 ralph-loop(예: OMC `oh-my-claudecode:ralph`)과도 원칙적으로 충돌하지 않는다 — 단 미검증
조합 1개.** 각 훅은 자기 state 파일에만 반응하고 없으면 즉시 `exit 0`한다(loop-skill 훅은
`.claude/loop-skill.local.md`, 외부 훅은 자기 state). → 서로 간섭 없음. **유일한 미검증 지점:** 한
세션에서 외부 ralph와 `-loop`를 *동시에* 활성화하면 두 Stop 훅이 각자 block을 반환해 어느 프롬프트가
이길지 불명. 외부 구현 내부를 확인 못 했으니 실측 대상이며, 실무상 한 세션에 loop 하나만 돌리면
발생하지 않는다.

---

## 12. 대안 및 기각 사유

| 대안 | 기각 사유 |
|---|---|
| **commands/에 얇은 래퍼 생성** | 동명 skill이 있으면 skill 우선 → 래퍼 무시(§3.2). |
| **중앙 엔진 + skill별 shim (v03 초안)** | `-loop` skill 단독 배포 불가; meta 버전이 **거짓말**이 됨(중앙 엔진 업그레이드에 조용히 끌려감). 번들 방식이 버전 authoritative + shim/경로탐색 제거로 더 단순(§7.2). |
| **Stop 훅까지 skill에 번들** | 훅은 settings.json 등록만 발화; N개 등록 시 매 Stop마다 경쟁(§5.4). 불가능. |
| **원본 이름 그대로 유지** | 요구가 `-loop` 접미사(가시 확인 + 중복 방지)로 확정(§2). |
| **원본 삭제(백업 없음)** | 원복·idempotent 재적용 불가(§5.2). |
| **`--pipeline` 재활용(엔진 무복사)** | 본문이 launcher와 분리 + `CLAUDE_PLUGIN_ROOT` 경로 취약. `--prompt-file` + 번들이 자기완결(§10). |

---

## 13. 위험 요소 및 완화

| 위험 | 완화 |
|---|---|
| 완료 계약 누락 → loop 무한 | footer 자동 주입 + 미주입 경고(§8). `--max-iterations` 안전망. |
| 재적용 시 footer 중첩 | pipeline 본문을 항상 pristine에서 재생성(§5.2, §7.4). |
| backup이 유령 skill 등록 | skills 스캔 경로 밖(`loop-applied/`)에 보관(§5.3). |
| 여러 skill 훅이 경쟁 | Stop 훅은 중앙 1개만 등록, 번들 금지(§5.4, §7.2). |
| 번들 엔진 버전 drift(중앙과 skill 불일치) | `--status`가 뒤처진 skill 표시(§7.9); `--upgrade-all`로 재번들(§7.5). |
| 원본이 model 자동호출 의존 | `--keep-model-invocation` + meta 보존(§7.1.1, §9). |
| 부분 실패로 어정쩡한 상태 | apply 트랜잭션 롤백(§7.3-10). |
| 본문에 `---` 있는 skill 파싱 오류 | frontmatter는 첫 두 `---`만 제거(§7.3-4). |
| **`-loop`가 무관한 동명 skill과 충돌** | apply가 `.loop-meta.json` 유무로 판별해 **install 실패** 처리, 사유 `동일 skill 존재` 출력(§7.3-2). 자동 덮어쓰기 없음. |
| 크로스-OS 배포(`.sh`만으로 Windows 불가) | `.sh`+`.ps1` 둘 다 번들, launcher는 OS별 재생성(§7.1.2). |
| 원본 이름 muscle-memory | `-loop` 변경은 명시 선택; 적용 시 새 이름 출력; `--dry-run` 사전 확인(§7.8). |

### 13.1 남겨두는 Stop 훅 관련 risk point (미해결 — 문서화만)

아래는 **single loop 실행에는 critical하지 않으나**(§11.3), 다중 등록·배포·재실행 축에서 남는
risk다. 이번 범위에서 완전 해결하지 않고 **명시적으로 남겨** 구현/운영 시 인지하도록 한다.

| # | risk point | 현재 상태 / 방향 |
|---|---|---|
| R1 | **멱등 등록의 dedup 정확성.** 훅이 user/project settings.json + 플러그인 `hooks.json` 등 여러 레이어에 존재 가능 → apply가 한 곳만 보면 중복 엔트리 추가 → 중복-실행 경쟁 부활. 현 `install.sh`도 dedup 없이 append. | 미해결. apply는 **설치 모드(copy/plugin) + 모든 settings 레이어**를 고려해 dedup해야 함. 구현 시 결정 필요. |
| R2 | **세션 중 훅 등록 즉시 발화 여부.** installer/self-bootstrap이 훅을 등록해도, Claude Code가 훅을 세션 시작 시 캐시하면 **첫 loop은 단발**일 수 있음. | 미검증 → **Phase 0 실측**(§14). 결과에 따라 배포 자가치유 범위가 갈림. |
| R3 | **죽은 loop의 state 지뢰.** loop이 크래시/세션 종료로 중단되면 `.claude/loop-skill.local.md`가 남고, setup쪽 `[CR-4]`가 파일 존재만 보고 향후 loop을 전부 거부. | 미해결. 현재는 `/cancel-loop-skill` 수동 정리. liveness(타임스탬프/PID stale) 판정은 별도 개정. |
| R4 | **전역 blast radius + 비대칭 uninstall.** 중앙 훅은 모든 세션의 매 Stop에서 실행(파일 없으면 즉시 exit). 마지막 `-loop` unapply 시 공유 훅은 제거 안 함(loop-skill 자체가 사용) → orphan 잔재. | 수용(경미). 훅 자체 graceful degradation 존재. 레퍼런스 카운팅은 과함(§0). |
| R5 | **배포되는 자동실행 스크립트 = 공급망 표면.** `-loop` 공유 = 무프롬프트 승인된 실행 스크립트 동봉. | 개인용 수용; 공유 시나리오에선 수신자가 번들 엔진을 신뢰해야 함. 문서 고지 수준. |

**single loop 안전성 확인(§11.3):** 훅이 정확히 1개 등록된 상태에서 loop 하나를 도는 실행 경로는
v02 ralph-loop와 동일하며 위 risk들은 다중/배포/재실행 축에서만 발현한다. R1(중복 등록)과 R3(state
지뢰)만이 single loop에도 영향을 줄 수 있는데, 둘 다 *실행*이 아니라 *등록/이전 실행 잔재* 문제다.

---

## 14. 구현 단계 (Phase)

- **Phase 0 — 스파이크(blocking, 간소):** 손으로 `foo-loop/`(`SKILL.md` + `pipeline.md` + `setup`
  복사본)를 만들어 `/foo-loop`가 (a) `!`-블록으로 **번들 setup**을 기동, (b) 중앙 Stop 훅 loop
  실동작, (c) `${CLAUDE_SKILL_DIR}`·`$ARGUMENTS` 해결을 실측. **번들 setup relocatable 확인**(§7.2).
  **추가 검증: (d) 세션 중 settings.json에 훅을 등록하면 그 세션의 Stop에서 바로 발화하는지(R2,
  §13.1) — 배포 자가치유 가능 범위를 결정.**
- **Phase 1 — 코어 확장:** `setup-loop-skill.sh`에 `--prompt-file` 모드 추가(§10) + 스모크.
- **Phase 2 — launcher 템플릿:** §7.1 확정(shim 없음).
- **Phase 3 — `apply_skill.sh`:** 적용(§7.3) + frontmatter 파싱 + 엔진 번들·stamp + 완료계약(§8) +
  meta(§9) + 트랜잭션 롤백.
- **Phase 4 — 재적용/업그레이드/가시성:** idempotent 재적용(§7.4) + `--upgrade-all`(§7.5) +
  `--status`/`--list`(§7.9) + drift 경고.
- **Phase 5 — `unapply_skill.sh`:** 원복(§7.6) 대칭성.
- **Phase 6 — 크로스-OS:** `apply_skill.ps1`/`unapply_skill.ps1` + `setup-loop-skill.ps1` 엔진.
  apply가 `.sh`/`.ps1` 양쪽 엔진을 번들하고 OS별 launcher(`shell:`)를 생성(§7.1.2). `.ps1` 엔진이
  bash 엔진과 동일 계약(state 스키마/`status.json`)을 구현하는지 검증.
- **Phase 7 — 통합 테스트(§15) + README.**

---

## 15. 테스트 계획 (LLM self-testable)

1. **기본 wrap:** `apply_skill.sh demo` → `/demo` 사라지고 `/demo-loop` 등장, `backups/demo/` 존재,
   `demo-loop/setup-loop-skill.sh` 번들됨.
2. **loop 동작:** `/demo-loop` → 번들 setup이 state 생성, 중앙 Stop 훅 재feed, `status.json`
   complete 시 종료.
3. **완료계약 주입:** 완료 지시 없는 skill → footer 붙음. 이미 있는 skill → 중복 주입 없음.
4. **idempotent 재적용:** `apply_skill.sh demo` 2회 → footer 한 번만; 번들 엔진 재복사됨.
5. **버전 가시성:** `--status` → `demo-loop`의 `engine_version` 출력; 코어 올린 뒤 뒤처짐 표시.
6. **업그레이드:** 코어 새 버전 설치 후 `--upgrade-all` → 번들 setup 교체, 본문 보존.
7. **원복:** `unapply_skill.sh demo` → `/demo` 복귀, `/demo-loop`·backup 소멸, 체크섬 일치.
8. **중복 방지:** apply 후 `/` 목록에 `demo`와 `demo-loop` 동시 존재 안 함.
9. **동시성 가드:** `-loop` loop 중 `/loop-skill ...` → `[CR-4]` 거부.
10. **cancel 재사용:** `-loop` loop 중 `/cancel-loop-skill` → 즉시 중단.
11. **본문 `---` 보존:** 본문에 `---` 있는 skill wrap → frontmatter만 제거, 본문 온전.
12. **빈 본문 에러:** frontmatter-only skill → apply 명확히 에러.
13. **번들 relocatable:** 번들 setup을 다른 경로에서 `--prompt-file`로 실행 → 정상 동작(§7.2).
14. **동명 skill 충돌:** meta 없는 `demo-loop`이 이미 있을 때 `apply_skill.sh demo` → install 실패,
    사유 `동일 skill 존재` 출력, 기존 `demo-loop` 무손상.
15. **크로스-OS 번들:** apply 후 `demo-loop/`에 `.sh`+`.ps1` 둘 다 존재; Windows에서 재wrap 시
    `shell: powershell` launcher가 `.ps1` 엔진으로 생성.

---

## 16. 체크리스트

- [ ] loop **엔진 동작 규약** 무수정. 코어 변경은 `--prompt-file` 하나뿐(§10).
- [ ] 생산자는 **skill 레이어**(§3.2) — command 레이어 아님.
- [ ] start쪽 엔진은 **각 skill에 번들 복사**, Stop 훅은 **중앙 1개**(§7.2).
- [ ] `engine_version` stamp로 버전 authoritative + `--status`로 가시화(요구 5, §7.9, §9).
- [ ] `-loop` 접미사 rename, 원복 시 접미사 제거(요구 2·3).
- [ ] 한 시점 활성 skill 하나 — 중복 없음(요구 2-B).
- [ ] pristine 백업 유지 → idempotent 재적용·업그레이드(요구 4).
- [ ] 완료 계약 자동 주입 + lint 경고(§8).
- [ ] `${CLAUDE_SKILL_DIR}` 직접 호출 — shim·중앙 경로탐색 없음.
- [ ] frontmatter 첫 두 `---`만 제거(본문 `---` 보존), 빈 본문 에러.
- [ ] **동명 skill 충돌 시 install 실패**(`.loop-meta.json`로 판별) + 사유 `동일 skill 존재` 출력(§7.3-2).
- [ ] **크로스-OS: `.sh`+`.ps1` 엔진 둘 다 번들, launcher는 OS별 생성**(§7.1.2).
- [ ] `--keep-model-invocation` / `--force` / `--dry-run` / `--status` / `--upgrade[-all]` 플래그.
- [ ] `apply`/`unapply` + `.ps1` 쌍.
- [ ] 트랜잭션 롤백 — 부분 실패 시 원본 복원.
- [ ] release 스토리 문서화: skill 폴더 복사 + Stop 훅 런타임 1회 설치(§5.4).
- [ ] **남긴 risk point 인지(§13.1):** R1 dedup 정확성 / R3 state 지뢰(구현 시 결정), R2 세션 중 훅 발화(Phase 0 검증).

---

## 17. 참고

- `harness_loop_plan_v02.md` — 정방향 코어 설계, §3.6 확장 계약, §3.7 config, 부록 A(L1 예시).
- `implementation-spec_v02.md` — setup/stop-hook/install 실제 스크립트.
- Claude Code 공식 문서(code.claude.com/docs): skills — command↔skill 통합, 우선권 규칙,
  `${CLAUDE_SKILL_DIR}`·`$ARGUMENTS`·`disable-model-invocation`·`allowed-tools`.
