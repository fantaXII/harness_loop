# Pipeline 확장 가이드

이 디렉토리에 `pipelines/<name>/prompt.md`를 추가하면 `/loop-skill --pipeline <name>`으로
그 내용을 loop의 고정 프롬프트로 사용할 수 있습니다.

## 필수
- `pipelines/<name>/prompt.md` — loop이 매 iteration 그대로 재feed할 프롬프트 본문.
  이 파일 안에서 상태를 어떻게 유지할지(단일 리포트 파일, 여러 subagent가 협업하는
  manifest.json 기반 파이프라인 등)는 전적으로 여러분이 설계합니다.
- `prompt.md`는 반드시 "완료로 판단되면 `<state_dir>/status.json`에
  `{"status": "complete"}`를 Write 툴로 기록하라"는 지시를 포함해야 합니다 — 그렇지 않으면
  loop은 절대 스스로 끝나지 않고 `--max-iterations`까지 계속됩니다.

## 선택
- `pipelines/<name>/agents/*.md` — Claude Code 커스텀 subagent 정의. 존재하면 설치 시
  `~/.claude/agents/`로 자동 복사됩니다. 파일 개수/이름/내용은 코어가 전혀 신경 쓰지 않습니다.
- 그 외 원하는 어떤 파일이든(예: playbook 문서) — `prompt.md`에서 Read 툴로 직접 참조하세요.

## 코어가 보장하는 것
- `state_dir`(빈 디렉토리 하나)가 항상 준비되어 있습니다. 경로는 loop 시작 시 출력되고,
  state 파일의 `state_dir` frontmatter 필드에도 기록됩니다.
- 매 iteration 동일한 `prompt.md` 내용이 그대로 재feed됩니다.
- `<state_dir>/status.json`에 `{"status": "complete"}` 또는
  `{"status": "failed", "reason": "..."}`가 쓰이면 loop이 종료됩니다. 코어가 읽는(쓰지 않는)
  state_dir 내부 파일은 이것 하나뿐입니다.

## 코어가 하지 않는 것 (여러분의 책임)
- `state_dir` 내부에 무엇을 만들지 결정하지 않습니다.
- 작업이 끝났는지 판단하지 않습니다 — `prompt.md`가 LLM에게 판단 기준을 제시해야 합니다.
- 여러 agent를 어떤 순서로 부를지 orchestrate하지 않습니다 — 필요하다면 `prompt.md` 자체가
  orchestrator 역할을 하도록 작성하세요 (예시: `harness_loop_plan_v02.md` 부록 A 참고).
