# Registered direct-push live validation

Live transcripts use this checkout's real CLI scripts, Git bare origins, Treehouse leases/returns, and a private tmux server. All disposable labs were removed. No default fleet session, operator project, production credential, or upstream service was changed.

- live-push-cleanup.log: base-version refusal and target-version success for the identical registered push; unregistered, missing-HEAD, deleted-remote-with-stale-tracking, and dirty-copy refusals preserve task records and commits; ancestor containment and existing default-branch delivery succeed.
- live-registration-guards.log: actual scaffold/spawn commands refuse missing registration, absent base, and mismatched base without publishing task metadata or launching an agent.
- live-done-proof.log: actual supervisor state reader accepts a pushed completion declaration and blocks it after an unpushed commit. Idle lifecycle input is seeded through the public fm-busy-event.sh recovery interface. This does not claim a live Claude session or model behavior.

Drivers are preserved beside transcripts. Run from the repository root. The push driver expects bin/.baseline-teardown.sh, materialized for this run using git show 9b1ada0401f9fa7ea3ee07a8a7f005a99ce0de58:bin/fm-teardown.sh and removed afterward.

Supplementary suites: fm-dod-lib, fm-project-mode, fm-task-delivery, fm-spawn-pool-base-freshen, fm-teardown. Their mocked integration cases are not counted as live. Initial fixture placement failures were corrected: nested fixtures triggered the home-removal guard, and a dot-prefixed temporary-path component invalidated an intentionally embedded branch name. Delivery tests used ordinary /tmp scratch space; cleanup tests used an evidence-directory temporary child. No production code was changed.

Final result: all five targeted suites exited 0. All live scenarios passed. The base-version registered-push refusal was reproduced before the target-version success. All test scratch directories and worktree-local driver files were removed; no tracked source changes remain.
