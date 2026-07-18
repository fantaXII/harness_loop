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

## Uninstall

```bash
./install/uninstall.sh    # Linux/Mac/WSL
.\install\uninstall.ps1   # Windows PowerShell
```

Removes only what the matching installer created — any other hooks or commands you
added later are left untouched.
