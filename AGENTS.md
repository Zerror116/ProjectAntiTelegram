# локальный агент Project Memory

This repository has long-running локальный агент context split into local memory files.
Before changing production logic, read the relevant memory first:

- `.local-memory/logic_deploy_memory.md` for deployment, production incidents, delivery,
  tenant rules, and current critical business decisions.
- `.local-memory/local_messenger_status.md` for messenger, notifications, reserved inbox,
  support, media, push, and address-flow status.

The old локальный агент thread "Логика и деплой" is intentionally archived because its
transcript grew to multiple gigabytes and can freeze the desktop UI. Do not rely
on reopening that thread for context; use these memory files and inspect the code
directly.

## Default Verification

- Run focused checks for touched code, then the broader project check when risk is
  user-facing.
- For Flutter web changes, prefer:
  - `flutter analyze`
  - `flutter build web --release --no-wasm-dry-run`
  - `bash scripts/prod_health_check.sh garphoenix.com` after deploy
- For backend route changes, run `node --check` on changed server files before
  deployment.
- Do not deploy unless the user explicitly asks or the current task is clearly a
  production incident requiring rollout.

## Safety

- The worktree may contain unrelated local changes from previous urgent fixes.
  Do not revert them.
- Never include secrets, passwords, SSH credentials, tokens, or private account
  details in memory files or final answers.
