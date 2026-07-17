# Smoke Test Pipeline

This is a minimal example pipeline for `loop-skill`, used to verify that
`/loop-skill --pipeline smoke-test` correctly loads this file verbatim as the
loop's fixed prompt body.

Task: write a one-line file named `smoke-test-output.txt` under the reported
`state_dir` containing the current iteration number, then check whether the
task is done according to the completion promise given on the command line.
