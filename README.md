# FCC Egg

Pterodactyl egg that boots an Ubuntu VPS (via [ysdragon/Pterodactyl-VPS-Egg](https://github.com/ysdragon/Pterodactyl-VPS-Egg))
and installs / restarts [Forthway Command Center](https://github.com/llallenll/Forthway-Command-Center) on it.

| File | What it is |
| --- | --- |
| `egg-fcc-install.json` | The egg. Import it in the panel (Nests → Import Egg). |
| `autorun.sh` | Runs on **every** start of the VPS. Checks this repo for script updates, installs everything on the first boot, brings FCC back up under pm2 on later boots, then starts SSH. |
| `run.sh` | The egg's startup script (a copy of the upstream `run.sh`, kept here so it can be updated together with `autorun.sh`). |
| `VERSION` | Version of the scripts. Bump it to roll an update out to the servers. |

On the VPS these live at `/run.sh`, `/autorun.sh` and `/.fcc-scripts-version` (the root of the server's file manager).

## Public or private repo

The VPS downloads the scripts straight from GitHub, so it must be able to read this repo.

* **Public repo** (the current setup). Nothing to configure; the scripts contain no secrets (the SSH password comes
  from the egg variable). Downloads use `raw.githubusercontent.com`.
* **Private repo.** If you ever make it private, create a GitHub personal access token that can read this repo's
  contents (fine-grained token: *Contents: Read-only* on `FCC_Egg`; classic token: `repo` scope) and put it in the
  egg variable **GITHUB TOKEN** (`FCC_GITHUB_TOKEN`) on each server. The installer and `autorun.sh` then download
  through the GitHub API as that token. Anyone who can open the server's Startup tab can read the token.

If the repo cannot be read, the install fails at "Fetching FCC scripts" and every start prints
`Script update check skipped: could not download VERSION from GitHub` and boots normally without updating.

## How updates work

On every start, before anything else, `autorun.sh`:

1. Downloads `VERSION` from this repo (`FCC_EGG_REPO` / `FCC_EGG_REF`, defaults `llallenll/FCC_Egg` / `main`).
2. Compares it with the version recorded on the VPS in `/.fcc-scripts-version`.
3. If they differ, prints the old and new version and asks in the console:

   ```
   [FCC] New scripts on GitHub: version 1.0.0 -> 1.1.0 (this replaces /run.sh and /autorun.sh).
   [FCC] Update run.sh and autorun.sh now? Type y or n in the console (no answer within 60s = n)
   ```

   * `y` downloads `run.sh` and `autorun.sh`, syntax-checks them, keeps the old copies as `/run.sh.bak` and
     `/autorun.sh.bak`, swaps the new ones in, records the new version and immediately re-runs the new
     `autorun.sh`. The new `run.sh` is used from the next start (the copy already running is not disturbed).
   * `n` (or any other answer after being re-asked) changes nothing; you are asked again on the next start.
   * No answer within the timeout counts as `n`, so an unattended restart still brings FCC up. The timeout is the
     egg variable **SCRIPT UPDATE PROMPT TIMEOUT** (`FCC_UPDATE_TIMEOUT`, default 60 seconds, `0` = wait forever).

Nothing is replaced without a `y`. If GitHub cannot be reached, or `curl`/`wget` are not installed yet (first boot),
the check is skipped with a message and the boot continues.

## Releasing a change

1. Edit `autorun.sh` and/or `run.sh`.
2. Bump `VERSION` (any string without spaces, e.g. `1.1.0`). Servers only prompt when this differs from what they have.
3. Push to `main` (or whatever branch the egg variable **SCRIPTS BRANCH** / `FCC_EGG_REF` points at).

Every server prompts on its next start. To test a change on one server first, push to another branch and set that
server's **SCRIPTS BRANCH** variable to it.

## Fresh install

Import `egg-fcc-install.json` (or, for the egg you already have, use its *Update egg from file* button so existing
servers get the new variables too). The install script downloads the Ubuntu rootfs, the upstream `common.sh`, and
`run.sh` + `autorun.sh` + `VERSION` from this repo, so a new server starts on the current version without prompting.
If the repo is private, set **GITHUB TOKEN** on the server before installing.

## Servers created with the previous egg

They still have the old `autorun.sh` without the update check. Update the egg in the panel from the new JSON (so the
servers get the new variables; set **GITHUB TOKEN** if the repo is private), then once, from the panel console (or SSH)
inside the VPS:

```sh
# public repo
curl -fsSL https://raw.githubusercontent.com/llallenll/FCC_Egg/main/autorun.sh -o /autorun.sh && chmod +x /autorun.sh

# private repo (replace TOKEN)
curl -fsSL -H 'Accept: application/vnd.github.raw' -H 'Authorization: Bearer TOKEN' \
  'https://api.github.com/repos/llallenll/FCC_Egg/contents/autorun.sh?ref=main' -o /autorun.sh && chmod +x /autorun.sh
```

Restart the server. Since `/.fcc-scripts-version` does not exist yet, it will report `unknown -> <version>` and ask once;
answer `y` to install the versioned `run.sh` and `autorun.sh`. From then on it updates like a fresh server.
