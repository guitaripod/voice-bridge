# Changelog

Each release in a line or two per change, written for the person deciding whether to update. The
installer and `voice-bridge update` take the number from the newest numbered heading, and the
program reports the same one.

## 0.2.0 — 2026-10-16

- Installing needs no Swift and no git. `install.sh` downloads a prebuilt program for the machine (Linux x86_64 and aarch64), checks its SHA-256, puts it in `~/.local/share/voice-bridge/bin` with a link in `~/.local/bin`, writes `~/.config/voice-bridge.env` only when there is none, and installs the `voice-bridge` user service. It builds from source only when there is no program for the machine, the download fails or does not check out, or `--from-source` asks. `--no-service` installs everything except the service.
- `voice-bridge doctor` says in plain words whether this machine can run voice calls (an NVIDIA card with 64 GB), then one line per check with the command that needs administrator rights or the note that Tailscode does the step. It exits 3 when the machine cannot run voice, and `--json` prints the same report the gateway serves on `/setup`. The installer runs it last and ends with what is left to do.
- `voice-bridge --version` answers, and a word the program does not know is refused instead of starting a second server.
- `GET /update` answers `{current, latest, behind}` from the release list, cached for hours and tolerant of a machine that is offline, so an app can offer the update.
- `voice-bridge update` installs the newest release and restarts the service only when no call is running and no download or engine load is under way; otherwise it installs, says why it did not restart, and restarts the next time it is run when the gateway is idle.

- The voice model is an ear only. The first run against the real model showed that it does not call tools reliably and ignores instructions to be silent, so `VOICE_SPEECH` (new) defaults to `muted`: no tools are registered, nothing the model says or sounds reaches the app, the phase never says speaking, and a model that rambles into the void is not a fault. `VOICE_SPEECH=model` keeps the old behaviour. `VOICE_DISPATCH` now defaults to `transcripts`, so every final transcript of at least three words goes to the agent; `tool` needs `VOICE_SPEECH=model`.
- The engine starts with `LLM_GPU_MEM_UTIL=0.30` and `TTS_GPU_MEM_UTIL=0.25` (`VOICE_LLM_MEM_UTIL` and `VOICE_TTS_MEM_UTIL`, 0.1 to 0.6) instead of NVIDIA's 0.45 and 0.40, which could not start on a 96 GB card that already runs a desktop. The container measured about 58 GB, so the card must have 64 GB (was 80) and 62000 MB must be free to start (was 70000). The unit in `packaging/` carries the same two values.
- The voice container no longer runs with `--rm`: when it dies while loading, the gateway reads its log first, puts the last lines in the engine check (`tail`), names a memory shortfall `gpuMemory` with the free and wanted memory, and then removes it.
- `voice-probe` takes `--instructions FILE`, `--no-tools`, `--tools-json FILE` and `--summary-table`, so the gate can be re-run against a new prompt or model. The README records the 2026-10-16 gate numbers.

## 0.1.0 — 2026-10-16

- The gateway between Tailscode calls and the NemotronLabs VoiceChat NIM: calls, tools, watchdogs, the setup checklist, the model and image downloads, and an engine that starts for a call and stops when idle.
