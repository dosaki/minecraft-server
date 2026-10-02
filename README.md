# minecraft-server

On-demand Paper server for the family. Connect to `minecraft.dosaki.net`. The first attempt
wakes the server (about 90 s), then connect again. It stops itself when nobody has been
online for 30–60 minutes. Map: https://map.minecraft.dosaki.net

Design: `docs/superpowers/specs/2026-10-02-minecraft-on-demand-design.md`

## Common tasks

- **Change who can play:** copy `scripts/players.example.json` to `players.json` (gitignored),
  edit it, then run `scripts/set-players.sh players.json`. Takes effect on the next boot.
- **Shell on the server:** `aws ssm start-session --profile dosaki --region eu-west-1 --target <instance_id>`
- **Restore a backup:** in a session, `sudo /opt/minecraft/bin/mc-restore.sh father/2026-W40.tar.zst`
- **Deploy:** merge a PR to `main`. Players get a 5-minute warning, then the server stops and Terraform applies.
- **Tests:** `make test lint`

## Security notes

- AWS access from CI uses GitHub OIDC; no AWS keys are stored in GitHub.
- `gha-minecraft-deploy` can only be assumed by workflows on `main`; `gha-minecraft-plan` (read-only) by pull requests from this repo. Fork PRs get no AWS access.
- Never add a `pull_request_target` workflow that assumes either role, and don't add `environment:` to the deploy job (it changes the OIDC subject and breaks the trust policy).
- Roles the stack creates must carry the `gha-minecraft-workload-boundary` permissions boundary (see `bootstrap/main.tf`).
- Player names live only in SSM (`/minecraft/players`); `players.json` is gitignored.
