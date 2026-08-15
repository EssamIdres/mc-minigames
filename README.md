# MC Server (mc-minigames)

Runs a free Minecraft (Paper) server on GitHub Actions.

## Setup (one time)

1. In repo **Settings â†’ Secrets and variables â†’ Actions â†’ New repository secret**:
   - `PLAYIT_SECRET` â€” your playit.gg agent secret (`secret_key` from your playit.toml)
   - `RCLONE_CONFIG` â€” your rclone config file contents (Google Drive remote named `mcworlds`)
2. Go to the **Actions** tab and click **Run workflow** (or push to `main`).

## How it works

- Fresh world every run (new world).
- Backs up the world to Google Drive (`mcworlds:minecraft/mc-minigames/backups/`) **every 1 minute**.
- Keeps only the **3 newest** backups; the oldest is deleted automatically.
- Server stops after 6 hours (GitHub limit). Re-run the workflow to start again.
- Find your server IP in the workflow log (playit tunnel address).

## Config

- `server.properties` â€” MOTD, max players, etc.
- `run.sh` â€” server + backup logic. Set `JAVA_HEAP` if you want more/less RAM (default 10G).
