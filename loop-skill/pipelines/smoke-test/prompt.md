# Smoke Test Pipeline

This is a minimal example pipeline for `loop-skill`, used to verify that
`/loop-skill --pipeline smoke-test` correctly loads this file verbatim as the
loop's fixed prompt body.

Task: write a one-line file named `smoke-test-output.txt` under the reported
`state_dir` containing the current iteration number. Once
`smoke-test-output.txt` already exists (i.e. on the iteration after you first
created it), write `{"status": "complete"}` to `<state_dir>/status.json`
using the Write tool to end the loop.
