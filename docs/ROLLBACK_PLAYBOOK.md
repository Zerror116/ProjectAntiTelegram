# Phoenix Rollback Playbook

## Scope
This playbook covers rollback for:
- backend code in `/opt/fenix/server`
- web build in `/var/www/garphoenix.com`
- Android update manifest under `/opt/fenix/server/downloads`

It explicitly does **not** delete or rewrite `/opt/fenix-data`.

## Before deploy
1. Verify `deploy_safe.sh` completed the production health check.
2. Verify nightly backups exist in `/opt/fenix-backups/postgres` and `/opt/fenix-backups/storage`.
3. Record current git commit and deployed web build timestamp.

## Backend rollback
1. Checkout the previous known-good commit locally.
2. Run `./deploy_safe.sh --skip-build` from that commit.
3. Confirm:
   - `https://garphoenix.com/health`
   - `systemctl status fenix-server.service`
   - `systemctl status fenix-worker.service`

## Web rollback
1. Checkout the previous known-good commit locally.
2. Run `./deploy_safe.sh --skip-backend` from that commit.
3. Hard-refresh the browser and verify the bootstrap shell and first chat open.

## Restore data snapshots
### Postgres
Use the latest custom dump from `/opt/fenix-backups/postgres/*.dump` and restore into maintenance mode only.

### Storage
Restore only by copying files from `/opt/fenix-backups/storage/<timestamp>/` back into `/opt/fenix-data/`.
Do not delete current storage during restore.

## Android manifest rollback
1. Restore the previous manifest and APK file from `/opt/fenix/server/downloads` backup.
2. Re-run `scripts/prod_health_check.sh`.

## Hard rules
- Never run destructive sync against `/opt/fenix-data`.
- Never delete `uploads`, `downloads`, `media_assets`, `product_card_snapshots`, `messages`, or notification tables as part of rollback.
- Roll back code first; restore data only if code rollback is insufficient.
