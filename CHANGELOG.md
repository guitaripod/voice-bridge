# Changelog

Each release in a line or two per change, written for the person deciding whether to update. The
installer and `voice-bridge update` take the number from the newest numbered heading, and the
program reports the same one.

## 0.2.0 — 2026-10-16

- Installing needs no Swift and no git. `install.sh` downloads a prebuilt program for the machine (Linux x86_64 and aarch64), checks its SHA-256, puts it in `~/.local/share/voice-bridge/bin` with a link in `~/.local/bin`, writes `~/.config/voice-bridge.env` only when there is none, and installs the `voice-bridge` user service. It builds from source only when there is no program for the machine, the download fails or does not check out, or `--from-source` asks. `--no-service` installs everything except the service.
- `voice-bridge doctor` says in plain words whether this machine can run voice calls (an NVIDIA card with 80 GB), then one line per check with the command that needs administrator rights or the note that Tailscode does the step. It exits 3 when the machine cannot run voice, and `--json` prints the same report the gateway serves on `/setup`. The installer runs it last and ends with what is left to do.
- `voice-bridge --version` answers, and a word the program does not know is refused instead of starting a second server.
- `GET /update` answers `{current, latest, behind}` from the release list, cached for hours and tolerant of a machine that is offline, so an app can offer the update.
- `voice-bridge update` installs the newest release and restarts the service only when no call is running and no download or engine load is under way; otherwise it installs, says why it did not restart, and restarts the next time it is run when the gateway is idle.

## 0.1.0 — 2026-10-16

- The gateway between Tailscode calls and the NemotronLabs VoiceChat NIM: calls, tools, watchdogs, the setup checklist, the model and image downloads, and an engine that starts for a call and stops when idle.
