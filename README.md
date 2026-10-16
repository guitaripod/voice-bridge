# voice-bridge

The gateway between Tailscode clients and NVIDIA's NemotronLabs VoiceChat 11B streaming server (the
NIM). Clients speak the `VoiceKit` wire (CodingAgentKit) to `ws /call`; the gateway speaks the NIM's
realtime protocol, and uses the model as an ear: it listens, transcribes the person's speech live, and
every final transcript goes to the agent as a `dispatch`. The model never speaks to the person (see Speech
and dispatch). The gateway also watches for engine errors and silent clients. The contract is
`iOS/Tailscode/docs/voice-call.md`.

It listens on `127.0.0.1` and on this machine's tailnet IPv4 (`tailscale ip -4`, read once at start).
Without tailscale it listens on loopback only and says so. It never binds `0.0.0.0`.

## Install

On a Linux computer with an NVIDIA GPU that has 64 GB or more of memory, one command:

```
curl -fsSL https://raw.githubusercontent.com/guitaripod/voice-bridge/master/install.sh | bash
```

It needs neither Swift nor git. In order, it:

1. Checks Tailscale (the gateway listens on this computer and on its tailnet address, which it reads once when
   it starts) and says what to do when it is down.
2. Downloads the prebuilt program for this machine (Linux x86_64 or aarch64) and checks its SHA-256.
3. Asks that program whether this machine can run voice calls (`voice-bridge doctor`). A machine that cannot gets
   that answer and nothing is installed; `--force` installs the gateway anyway.
4. Installs the program in `~/.local/share/voice-bridge/bin`, links it from `~/.local/bin/voice-bridge`, keeps the
   installer next to it for `voice-bridge update`, writes `~/.config/voice-bridge.env` only when there is none,
   and installs and starts the `voice-bridge` user service. It also copies `nemotron-voicechat.service`, which it
   never enables.
5. Runs `voice-bridge doctor` again and ends with what is left: the one administrator command when Docker or the
   GPU for containers is missing, then "Open Tailscode, pick this server and tap Set up voice", which downloads the
   model (47 GB) and the engine image (23 GB) from the app.

It never restarts a gateway that is already running. Options: `--no-service` installs everything except the
service, `--from-source` builds instead of downloading, `--update` replaces the program and touches nothing else.
Without a prebuilt program for the machine, a failed download or a checksum that does not match, it builds from
source and says why in one sentence; that needs Swift and git, and clones this repo and `CodingAgentKit` side by
side under `~/.local/share/voice-bridge/src` (the package depends on `../CodingAgentKit`). A Mac has no NVIDIA GPU:
the installer says so and stops.

Its settings are `VOICE_RELEASE_BASE` (where `latest.txt` and the archives are, default this repo's latest
release), `VOICE_SHARE_DIR`, `VOICE_ENV_FILE`, `VOICE_UNIT`, `VOICE_SRC`, `VOICE_KIT_REPO`, `VOICE_TAILSCALE`
and `VOICE_FORCE_SERVICE` (rewrite an existing unit).

### Commands

```
voice-bridge                    serve (what the service runs)
voice-bridge --version          voice-bridge 0.2.0
voice-bridge doctor [--json]    check this machine for voice calls
voice-bridge doctor --commands  only the commands that need administrator rights, one per line
voice-bridge update             install the newest release and restart when it is safe
```

A word it does not know is refused with exit 2 instead of starting a second server. `doctor` reads the same checks
the gateway serves on `GET /setup`, from this machine, without a running gateway, and starts no job. It prints
the hardware verdict first ("This machine has an NVIDIA RTX PRO 6000 Blackwell Workstation Edition with 96 GB:
voice calls can run here." or "No NVIDIA GPU with 64 GB: voice calls cannot run on this machine."), then one line
per check with a mark, the command to run or the note that Tailscode does the step. It exits 3 when the machine
cannot run voice calls, 0 otherwise; `--json` prints the `SetupReport`. It reads `~/.config/voice-bridge.env` under
the real environment, so it judges the machine the way the service sees it. A download the gateway is running
right now shows as "not downloaded yet" there: ask the gateway (`GET /setup`) for jobs.

### Updating

`GET /update` answers `{"current": "0.2.0", "latest": "0.2.1", "behind": true}` from `$VOICE_RELEASE_BASE/latest.txt`,
read at most every 6 hours (10 minutes after a failure). Offline, it keeps answering with the last version it saw, or
`"latest": null, "behind": false` when it never saw one. It is behind the same bearer password as `/health`.

`voice-bridge update` runs the staged installer (`~/.local/share/voice-bridge/install.sh`) in `--update` mode, which
replaces the program on disk and nothing else, then restarts `voice-bridge.service` only when the running gateway
says it has nothing to lose: `/health` reports no call and an engine that is not loading, and `/setup` reports no
open job and no step working. Otherwise it installs, says why it did not restart (exit 4), and the next run only
restarts. A gateway it cannot ask (wrong password in the env file) is treated as busy. There is a window of a few
milliseconds between the question and the restart in which a call could begin.

### Releasing

Add a numbered heading to the top of `CHANGELOG.md` and set `GatewayInfo.version` to the same number (a test
fails when they differ), tag it with the bare number (`0.2.1`, no `v`) and push the tag. `.github/workflows/release.yml`
builds `scripts/package-release.sh` on a `swift:6.4.1-jammy` container for x86_64 and aarch64 (jammy's glibc 2.35 is
the oldest worth supporting) and publishes `voice-bridge-<version>-linux-<arch>.tar.gz`, its `.sha256` and
`latest.txt`. There is no macOS asset.

## Environment

| variable | default | |
| --- | --- | --- |
| `VOICE_PORT` | `4102` | listen port |
| `VOICE_NIM_URL` | `ws://127.0.0.1:9000/v1/realtime` | the NIM's realtime socket |
| `VOICE_PASSWORD` | unset | when set, `Authorization: Bearer <password>` is required on `/call` and `/health` |
| `VOICE_DISPATCH` | `transcripts` | `transcripts` or `tool`, see Speech and dispatch; shown in the `/health` detail |
| `VOICE_SPEECH` | `muted` | `muted` or `model`, see Speech and dispatch; shown in the `/health` detail |
| `VOICE_LLM_MEM_UTIL` | `0.30` | share of the card the NIM's language engine reserves, 0.1 to 0.6, see Memory: the NIM's two engines |
| `VOICE_TTS_MEM_UTIL` | `0.25` | share of the card the NIM's speech engine reserves, 0.1 to 0.6 |
| `VOICE_LOG_LEVEL` | `info` | swift-log level |
| `VOICE_ENGINE` | `auto` | `managed`, `external` or `auto`, see Managed and external engines |
| `VOICE_IDLE_STOP_MINUTES` | `10` | minutes without a call or a setup job before the gateway stops its engine; `0` never stops it |
| `VOICE_MODEL_DIR` | `~/.local/share/voice-bridge/model` | where the model is downloaded and looked for |
| `VOICE_RELEASE_BASE` | this repo's latest release | where `GET /update` and `voice-bridge update` read `latest.txt`; see Install |
| `NGC_API_KEY` | unset | passed to the NGC CLI as `NGC_CLI_API_KEY` for the model download |

## Health

`GET /health` answers `VoiceHealth`. `engine` is one of:

| engine | meaning |
| --- | --- |
| `ready` | the NIM's `GET /v1/realtime/health` says `"triton_status":"ready"` |
| `loading` | the NIM is starting (its 503, or a container of ours that is not ready yet) |
| `stopped` | managed, everything is installed, the container is not running and the GPU has the memory: a call starts it |
| `needsSetup` | managed, something is missing: see `GET /setup` |
| `busy` | a call is held, or (managed, stopped) the GPU's free memory is under 62000 MB; the detail names the programs holding it |
| `down` | no answer, or the container died or failed to start |

An external engine only ever shows `ready`, `loading`, `down` and `busy` (a held call). The probe is cached
for 2 seconds.

## Speech and dispatch

The 2026-10-16 gate (see Gate results) showed that the model does not call tools reliably and ignores
instructions to be silent, so the gateway uses it as an ear. Two switches decide what it does, and the
`/health` detail names both ("Dispatch: transcripts. Speech: muted.").

`VOICE_SPEECH`:

- `muted` (default): the model listens and transcribes and nothing else. The session opens with a short ASCII
  instruction ("You are a silent listener...") and **no tools at all**, so the model cannot call anything or
  speak an acknowledgement. Whatever audio or words it produces anyway is discarded: no binary audio and no
  `say` frame reach the client, and the phase is never `speaking` (only `listening`, `hearing` and `degraded`).
  The runaway and loop watchdogs ignore that discarded output, so a model that rambles into the void never
  degrades the call. Engine errors, a closed NIM socket and 10 s of NIM silence while a reply is owed still
  do. A tool call that arrives anyway is answered "That tool does not exist." and does nothing.
- `model`: today's behaviour for experiments. The model speaks, its audio and words are forwarded, the
  watchdogs apply, and the persona and the three tools (`send_to_agent`, `agent_status`, `stop_agent`) are
  registered.

`VOICE_DISPATCH` decides how the person's words reach the agent. The text sent is always the model's own
transcript of the speech.

- `transcripts` (default): every final transcript of at least 3 words (after trimming) is dispatched as soon
  as it completes. Shorter transcripts are shown to the client but not sent. `send_to_agent`, when the model
  can call it, only answers `Sent.`, or `Already sent.` when the current turn was dispatched already.
- `tool` (needs `VOICE_SPEECH=model`): the final transcripts since the last dispatch are kept, and when the
  model calls `send_to_agent` they are joined (at most 4000 characters) and sent as one `dispatch`; the tool
  answers `Sent.`, or `Nothing to send.` when there is nothing. If the model calls it after a speech turn has
  ended but before that turn's transcript has arrived, the tool still answers `Sent.` at once and the
  `dispatch` goes out the moment the transcript completes, joined with anything pending. Without a
  transcript within 3 s the intent is dropped and logged. If the model never calls the tool, nothing is sent.
  A muted model has no tools, so `VOICE_DISPATCH=tool` with `VOICE_SPEECH=muted` dispatches transcripts.

`voice-probe run --json` reports `summary.sendToAgentRate` and each utterance's `userTranscript`, which is
what a new prompt or model is judged on: the rule in `iOS/Tailscode/docs/voice-call.md` is `send_to_agent` on
at least 95% of 50 scripted task utterances before `tool` is worth keeping, and `transcripts` sends every
transcript error to the agent without the model's judgement in between.

## Call behaviour worth knowing

- One call at a time. A second caller gets `error(busy)`. A client speaking another protocol version
  gets `error(version)`. A NIM that cannot be reached gives `error(engineDown)`. 15 s without any
  client frame gives `error(silent)`.
- The gateway sends `ready`, then `phase(listening)`. It never sends `phase(connecting)`. With the default
  `VOICE_SPEECH=muted` it also never sends `phase(speaking)`, model audio or `say` frames.
- `user` and `say` frames carry the whole text so far while `final` is false, and the whole text when it
  is true, so a client replaces rather than appends.
- Faults (`runaway`, `loop`, NIM error, closed NIM socket, 10 s of NIM silence while a reply is owed)
  send `degraded(recovering: true)`, mute the model and swap the voice session; the client then sees
  `recycled`. A second fault within 60 s, or a swap that cannot connect, leaves `degraded(recovering: false)`.
- At a quiet moment after 90 s of audio or 4 person turns the session is swapped the same way. Microphone
  audio during the swap is kept for 2 s and replayed into the new session.

## Setup and the voice model

The gateway proves what its machine can do for voice, fixes what is missing, and runs the model on demand.
The app only draws what the gateway reports. The wire is `SetupKit` (CodingAgentKit) and the contract is
`iOS/Tailscode/docs/setup.md`. All of it sits behind the same bearer password and bind policy as `/health`.

| route | |
| --- | --- |
| `GET /setup` | `[SetupReport]`, one for capability `voice` |
| `POST /setup/fix` `{"fix": "<id>"}` | starts a job, answers its `SetupJob`; `404` for an unknown fix, `409` (with the running job as the body) when that fix is already running, `422` when the machine cannot run voice at all |
| `GET /setup/jobs/{id}` | follows a job; `404` for an unknown id |
| `DELETE /setup/jobs/{id}` | cancels it, kills its whole process group, keeps the partial files, answers the settled job |

### Checks

Every state is a fact about the machine, read through `nvidia-smi`, `docker`, `nvidia-ctk`, `df`,
`/etc/os-release`, the CDI spec directories, the model directory and the NIM's own health route. Facts are
names and numbers, never sentences; `detail` is an English fallback.

| id | what it proves | facts | when it is not `ok` |
| --- | --- | --- | --- |
| `voice.gpu` | an NVIDIA GPU answers `nvidia-smi` | `name` | `unavailable`, and the report is `available: false` |
| `voice.vram` | the card (not what is free) has 64 GB or more | `totalMB`, `needMB` (62000) | `unavailable` under 64000 MB, or when the size cannot be read |
| `voice.docker` | `docker version` works for this user | `os`, `problem` (`missing`, `denied`, `stopped`) | `blocked`, fix is a `command` chosen by OS (Arch, Debian and Ubuntu, anything else a pointer line) with the reason it needs privileges |
| `voice.cdi` | a `nvidia.com/gpu=` CDI device exists (`nvidia-ctk cdi list`, or a spec file in `/etc/cdi` or `/var/run/cdi`) | `toolkit` (`installed`, `missing`) | `blocked`, fix is `sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml` |
| `voice.model` | `config.pbtxt` and the `nemotron-voicechat/1` weights are there and at least 99% of 46868000000 bytes | `bytes`, `needBytes`, and while a job is open `job`, `progress`; after a failed one `lastFailure`, `lastJob` | `todo` with the job `voice.downloadModel` (bytes still to fetch, minutes), `working` while it runs |
| `voice.image` | `docker image inspect` finds the image | `bytes`, `needBytes`, as above | `todo` with the job `voice.pullImage` (22500000000 bytes), `working` while it runs; waits (`after: voice.docker`, no fix) while docker is not usable |
| `voice.engine` | see below | `mode`, `state`, `freeMB`, `needMB`, `holders`, `progress`, `reason`, and after a failed start `failure`, `tail` | see below |
| `voice.gateway` | always `ok` | `version` | |

`voice.engine`: `ok` when it is running and healthy, and also `ok` when it is stopped and the GPU has 62000 MB
free (the state means "starts on demand"); `working` while it loads, with `progress`; `blocked` when it is
stopped but the free memory is under 62000 MB (facts `freeMB`, `needMB` and `holders`, the programs holding
the GPU, largest first) or when it is down (`reason`); `todo` with `after` naming the step above it while
something is missing. There is never a fix for a busy GPU: the gateway does not stop anyone else's job.
A start that failed is down with `failure` (`gpuMemory`, `exited`, `notReady` or `startFailed`), the facts that
go with it (`freeMB` and `needMB` for `gpuMemory`) and `tail`, the last 10 lines of the container's log, for
2 minutes.

`ready` is true when every check is `ok`. The open job (if any) is on the report as `job` and on its check as
`working`. When an external engine answers, the local steps (docker, CDI, model, image) are reported `ok` with
`mode: external`, because the engine proves them.

Fix ids: `voice.downloadModel` and `voice.pullImage` are jobs, `voice.installDocker` and `voice.generateCDI`
are copyable commands (the latter two are not accepted by `POST /setup/fix`).

### Jobs

A job is a JSON file under `~/.local/state/voice-bridge/jobs/` (the newest 20 settled ones are kept). A job that
was running when the gateway stopped reads as `failed` with failure `interrupted`; running its fix again picks
the work up where the files stand. Failure ids: `noDisk` (facts `needMB`, `freeMB`, checked before anything
starts and again when a tool reports it), `network`, `denied`, `interrupted`, `other`; the tool's last lines are
in the facts under `tail`, and `other` carries a `reason`. Starting a fix whose result is already there
succeeds at once.

- `voice.downloadModel`: uses the NGC CLI on the `PATH` if there is one, else the copy in
  `~/.local/share/voice-bridge/ngc`, else downloads NVIDIA's own zip for this CPU from the URL on
  <https://ngc.nvidia.com/setup/installers/cli>, checks its SHA-256 against `NGCRelease` and refuses on a
  mismatch (the zip is deleted). Then `ngc registry model download-version nim/nvidia/nemotron-labs-voicechat:1.0.0
  --dest <model dir>`, with progress as bytes on disk against 46868000000, then `chmod -R a+rwX` as the NIM
  documentation asks. It needs an NGC API key: run `ngc config set` once, or put `NGC_API_KEY` in
  `~/.config/voice-bridge.env`.
- `voice.pullImage`: `docker pull nvcr.io/nim/nvidia/nemotron-labs-voicechat:latest`. Progress is the share of
  layers finished, taken from the layer lines `docker pull` prints: coarse, because layers differ in size.
  nvcr.io needs `docker login nvcr.io` (user `$oauthtoken`, password the NGC API key) once; without it the job
  fails `denied`.

#### Pinning the NGC checksum

`Sources/VoiceGatewayCore/Jobs/NGCRelease.swift` holds the NGC CLI version and the SHA-256 of its Linux AMD64 and
ARM64 zips. To move to a newer release:

1. Read the install page <https://ngc.nvidia.com/setup/installers/cli>, or
   `curl -s https://api.ngc.nvidia.com/v2/resources/nvidia/ngc-apps/ngc_cli/versions`, and note the version in the
   `wget` URL and the SHA256 it prints for AMD64 and for ARM64.
2. Download both zips from `https://api.ngc.nvidia.com/v2/resources/nvidia/ngc-apps/ngc_cli/versions/<version>/files/ngccli_linux.zip`
   (and `ngccli_arm64.zip`) and check that `sha256sum` agrees with the page.
3. Change `version`, `linuxSHA256` and `arm64SHA256` together, and the same values in
   `theShippedDigestsAreTheOnesNVIDIAPublishes`, then run `swift test`.

### Managed and external engines

`VOICE_ENGINE=managed`: the gateway starts the container itself and stops it when idle. `external`: someone
else runs it (the optional `packaging/nemotron-voicechat.service`) and the gateway only talks to it, exactly as
before. `auto` (the default) decides once, at start: managed, unless something already answers on the NIM port
and no container of ours exists. A `VOICE_NIM_URL` other than `127.0.0.1:9000` or `localhost:9000` is always
external, since only that port is the one the container publishes. If you run the unit yourself, set
`VOICE_ENGINE=external`: its container has the same name as the one the gateway manages.

A managed engine is started with exactly:

```
docker run -d --name nemotron-labs-voicechat --device nvidia.com/gpu=0 --shm-size=8GB \
  -e NIM_HTTP_API_PORT=9000 -e LLM_GPU_MEM_UTIL=0.30 -e TTS_GPU_MEM_UTIL=0.25 \
  -p 127.0.0.1:9000:9000 -v <model dir>:/data/models \
  --entrypoint /s2s/run_s2s_server.sh nvcr.io/nim/nvidia/nemotron-labs-voicechat:latest
```

(CDI device form, because this Docker has no `nvidia` runtime. No `--rm`: a container that dies while loading
keeps its log until the gateway has read it, see below.) The two `-e` values are `VOICE_LLM_MEM_UTIL` and
`VOICE_TTS_MEM_UTIL`, each validated to 0.1 to 0.6 (anything else falls back to the default). `<model dir>` is `VOICE_MODEL_DIR`, or the
`nemotron-labs-voicechat_v1.0.0` folder inside it where NGC unpacks the download.

- A start happens only for a call, and only if the GPU's free memory, read again right before, is at least
  62000 MB. Otherwise nothing starts, `/health` says `busy` naming who holds the GPU, and the call gets
  `engine(busy)` and `error(engineDown)`. Missing pieces give `engine(needsSetup)` and the same error.
- While the engine loads, the call's socket stays open and the gateway sends `engine(loading, progress)` every 2
  seconds, then continues with `ready` exactly as for a running engine. The NIM reports no percentage, so
  `progress` is the time spent against a typical 4 minute load (never above 0.99 before it is ready): a picture,
  not a measurement. A load that is not ready after 8 minutes stops the container and sends
  `error(engineDown)` with the reason, as does a refused `docker run` or a container that dies.
- When the container exits while loading, the gateway runs `docker logs --tail 60` on it **before** removing it,
  puts the last 10 lines in the failure's `tail` fact and all 60 in its own log, and then runs `docker rm -f`.
  vLLM's "less than desired GPU memory utilization" is recognised as the failure `gpuMemory`, with `freeMB`
  and `needMB` taken from the message (the engine that refused, not the sum of both).
- After `VOICE_IDLE_STOP_MINUTES` with no call and no setup job, `docker stop nemotron-labs-voicechat` returns the
  GPU to whatever else the machine does, and `docker rm -f` removes it. The gateway touches no other
  container, ever: it matches the name exactly, and a stale container of ours in a stopped state is removed
  with `docker rm -f` by that name before a new start.
- Restarting the gateway leaves a running engine alone. A client that leaves while the engine loads does not
  stop the load.

### Known gaps

The unit tests use fake `docker`, `nvidia-smi`, `nvidia-ctk`, `ngc`, `curl` and `df`. Three behaviours of
NVIDIA's tools are written from their documentation and have not run end to end here: whether `ngc` resumes a
partial download by itself when run again (the gateway simply runs it again on the same directory), the
exact text of its authentication errors (used to tell `denied` from `network`), and `docker pull` output
under the containerd image store (used for layer counting; without layer lines the job still runs, with no
fraction). A card whose `nvidia-smi` reports no memory size (unified memory) is reported unavailable.

## Memory: the NIM's two engines

The NIM runs two vLLM engines in one container, a language engine and a speech (TTS) engine, and each reserves
a share of the whole card when it starts: NVIDIA's defaults are `LLM_GPU_MEM_UTIL=0.45` and
`TTS_GPU_MEM_UTIL=0.40`, so 85% of the card. Both are plain environment variables the container reads.

On the RTX PRO 6000 (95.05 GiB) with a desktop already holding about 12 GB, that failed at start: "Free memory
on device (34.67/95.05 GiB) is less than desired GPU memory utilization (0.4, 38.02 GiB)". With
`LLM_GPU_MEM_UTIL=0.30` and `TTS_GPU_MEM_UTIL=0.25` the NIM loaded in about 5 minutes and the whole container
used about 58 GB. So the gateway defaults to those lower shares, which is also why the numbers it checks are
lower than they once were: a card must have 64 GB (`voice.vram` is `unavailable` below 64000 MB) and 62000 MB
must be free to start (the measured 58 GB plus a margin). A machine whose other jobs leave more room can raise
the shares with `VOICE_LLM_MEM_UTIL` and `VOICE_TTS_MEM_UTIL` (0.1 to 0.6). Lower shares than the measured
pair have not been tried.

## Gate results 2026-10-16

First run against the real NIM on the RTX PRO 6000 (files in `voice/gate-results/`), five scripted task
utterances with `voice-probe` and an end-to-end call through the gateway:

| measure | result |
| --- | --- |
| first model audio after the end of speech | p50 157 ms, p95 239 ms (5 of 5 answered) |
| `send_to_agent` calls | 0 of 5 with the shipped prompt; about 1 of 5 at best with heavily tuned prompts |
| model errors, runaways, recycles | none |
| NIM start on the 96 GB card | failed with NVIDIA's default memory shares, loaded in about 5 min with 0.30 and 0.25, container 58 GB |

The live user transcript streams as the person talks and is mostly right. Errors are the kind a coding agent
survives: "cache" heard as "cash", "build" as "bill", "add a dark mode" as "a dark mode". The model ignores
instructions to be silent or to answer in one word and improvises assistant chatter ("I can run those tests for
you. Just let me know what specific tests you would like me to run."), so prompts cannot fix the tool calls or
the speech. Hence the decision that the model is an ear only: `VOICE_SPEECH=muted` and
`VOICE_DISPATCH=transcripts` are the defaults. To re-run the gate against a new prompt or model:

```
voice-probe run --wav u1.wav --wav u2.wav --instructions prompt.txt --no-tools --summary-table
```

## Packaging

`packaging/voice-bridge.service` is the user unit the installer writes, and `packaging/nemotron-voicechat.service`
is only for `VOICE_ENGINE=external`: it keeps the container running all the time, which is what the managed
engine replaces. The installer copies it and never enables it; `scripts/test-install.sh` checks both against
the files here.

## voice-probe

The measurement tool for the real-GPU gate. It talks to the NIM directly, with the same session setup,
tools and recycle policy as the gateway.

```
voice-probe run --nim ws://127.0.0.1:9000/v1/realtime --wav a.wav --wav b.wav \
    [--gap-ms 1500] [--settle-ms 4000] \
    [--barge-in-ms 300 --interrupt-wav x.wav] [--soak-seconds 600] [--json out.json] \
    [--instructions prompt.txt] [--no-tools | --tools-json tools.json] [--summary-table]
```

`--instructions FILE` replaces the persona text sent with `session.update` (the default is the speaking persona
of `VOICE_SPEECH=model`). `--no-tools` registers no tools, as the gateway does when muted; `--tools-json FILE`
registers the tools in the file instead, a JSON array of the NIM's own tool objects
(`{"type":"function","name":...,"description":...,"ack_messages":[...],"parameters":{...}}`). `--summary-table`
prints one plain row per utterance (first audio, tools, runaway, what was heard, what the model said) and the
totals instead of the long summary, so two runs can be put side by side. The JSON is unaffected.

WAVs must be 24 kHz mono 16-bit PCM (`ffmpeg -i in.wav -ar 24000 -ac 1 -c:a pcm_s16le out.wav`). Audio is
streamed in 80 ms chunks at real-time pace, followed by `--gap-ms` of silence. Per utterance it records the
time from end of speech to the first model audio, what the model heard, the tool calls it made, what it
said, the audio it produced and the runaway flags (audio more than 3 s after `response.done`, or more than
25 s in one utterance). With `--barge-in-ms` the interrupt WAV starts that long after the model's first
audio, and the report gives the time from interrupt start to the last model audio. `--soak-seconds` repeats
the WAV list and recycles the session on the gateway's policy. The JSON is `voice-probe/1`: every key is
always present and absent measurements are `null`.

`voice-probe fake-nim --port 9100` serves a scripted NIM that hears loud audio as speech and answers with
a tool call and a tone, for trying the probe or a client without a GPU.

## Tests

`scripts/test-install.sh` installs from a fake release served by `python3 -m http.server` into a throwaway `HOME`,
with a `PATH` that holds no `swift`, no `git` and no service manager, and fake `nvidia-smi`, `docker`, `tailscale`,
`systemctl` and `loginctl`. It covers the binary install, an env file that is already there, a failed checksum,
a machine without a GPU, `--no-service`, `--force`, re-running, `--update`, and, when `.build/debug` is current, the
real program's own `doctor` through the installer. It never touches the real `~/.local`, `~/.config` or a service.

`swift test`. Everything runs on loopback against a scripted fake NIM; no GPU, docker, network or display. The
machine is faked two ways: a scripted `CommandRunner` that answers `docker`, `nvidia-smi` and the rest from a
value, and real processes (fake executables in a temporary `PATH`) for the jobs, so process groups, streaming
and cancel are the real thing.
