# voice-bridge

The gateway between Tailscode clients and NVIDIA's NemotronLabs VoiceChat 11B streaming server (the
NIM). Clients speak the `VoiceKit` wire (CodingAgentKit) to `ws /call`; the gateway speaks the NIM's
realtime protocol, runs the three tools (`send_to_agent`, `agent_status`, `stop_agent`), and watches
the model for runaway, loops, engine errors and silent clients. The contract is
`iOS/Tailscode/docs/voice-call.md`.

It listens on `127.0.0.1` and on this machine's tailnet IPv4 (`tailscale ip -4`, read once at start).
Without tailscale it listens on loopback only and says so. It never binds `0.0.0.0`.

## Environment

| variable | default | |
| --- | --- | --- |
| `VOICE_PORT` | `4102` | listen port |
| `VOICE_NIM_URL` | `ws://127.0.0.1:9000/v1/realtime` | the NIM's realtime socket |
| `VOICE_PASSWORD` | unset | when set, `Authorization: Bearer <password>` is required on `/call` and `/health` |
| `VOICE_DISPATCH` | `tool` | `tool` or `transcripts`, see Dispatch modes; shown in the `/health` detail |
| `VOICE_LOG_LEVEL` | `info` | swift-log level |
| `VOICE_ENGINE` | `auto` | `managed`, `external` or `auto`, see Managed and external engines |
| `VOICE_IDLE_STOP_MINUTES` | `10` | minutes without a call or a setup job before the gateway stops its engine; `0` never stops it |
| `VOICE_MODEL_DIR` | `~/.local/share/voice-bridge/model` | where the model is downloaded and looked for |
| `NGC_API_KEY` | unset | passed to the NGC CLI as `NGC_CLI_API_KEY` for the model download |

## Health

`GET /health` answers `VoiceHealth`. `engine` is one of:

| engine | meaning |
| --- | --- |
| `ready` | the NIM's `GET /v1/realtime/health` says `"triton_status":"ready"` |
| `loading` | the NIM is starting (its 503, or a container of ours that is not ready yet) |
| `stopped` | managed, everything is installed, the container is not running and the GPU has the memory: a call starts it |
| `needsSetup` | managed, something is missing: see `GET /setup` |
| `busy` | a call is held, or (managed, stopped) the GPU's free memory is under 70000 MB; the detail names the programs holding it |
| `down` | no answer, or the container died or failed to start |

An external engine only ever shows `ready`, `loading`, `down` and `busy` (a held call). The probe is cached
for 2 seconds.

## Dispatch modes

How the person's words reach the agent is a switch, because the model's tool arguments and its habit of
calling `send_to_agent` are unreliable. The text sent is always the model's own transcript of the speech.

- `tool` (default): the final transcripts since the last dispatch are kept, and when the model calls
  `send_to_agent` they are joined (at most 4000 characters) and sent as one `dispatch`; the tool answers
  `Sent.`, or `Nothing to send.` when there is nothing. If the model calls it after a speech turn has
  ended but before that turn's transcript has arrived, the tool still answers `Sent.` at once and the
  `dispatch` goes out the moment the transcript completes, joined with anything pending. Without a
  transcript within 3 s the intent is dropped and logged. If the model never calls the tool, nothing is sent.
- `transcripts`: every final transcript of at least 3 words (after trimming) is dispatched as soon as it
  completes, whatever the model does. `send_to_agent` only answers `Sent.`, or `Already sent.` when the
  current turn was dispatched already. Shorter transcripts are shown to the client but not sent.

What decides between them is the gate rule in `iOS/Tailscode/docs/voice-call.md`: `send_to_agent` must be
called on at least 95% of 50 scripted task utterances. `voice-probe run --json` reports
`summary.sendToAgentRate` over the scripted utterances. At 95% or better keep `tool`; below that, use
`transcripts`. The same run's `userTranscript` against what was said (word error rate) is the other
input: `transcripts` sends every transcript error to the agent without the model's judgement in between.

## Call behaviour worth knowing

- One call at a time. A second caller gets `error(busy)`. A client speaking another protocol version
  gets `error(version)`. A NIM that cannot be reached gives `error(engineDown)`. 15 s without any
  client frame gives `error(silent)`.
- The gateway sends `ready`, then `phase(listening)`. It never sends `phase(connecting)`.
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
| `voice.vram` | the card (not what is free) has 80 GB or more | `totalMB`, `needMB` (70000) | `unavailable` under 80000 MB, or when the size cannot be read |
| `voice.docker` | `docker version` works for this user | `os`, `problem` (`missing`, `denied`, `stopped`) | `blocked`, fix is a `command` chosen by OS (Arch, Debian and Ubuntu, anything else a pointer line) with the reason it needs privileges |
| `voice.cdi` | a `nvidia.com/gpu=` CDI device exists (`nvidia-ctk cdi list`, or a spec file in `/etc/cdi` or `/var/run/cdi`) | `toolkit` (`installed`, `missing`) | `blocked`, fix is `sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml` |
| `voice.model` | `config.pbtxt` and the `nemotron-voicechat/1` weights are there and at least 99% of 46868000000 bytes | `bytes`, `needBytes`, and while a job is open `job`, `progress`; after a failed one `lastFailure`, `lastJob` | `todo` with the job `voice.downloadModel` (bytes still to fetch, minutes), `working` while it runs |
| `voice.image` | `docker image inspect` finds the image | `bytes`, `needBytes`, as above | `todo` with the job `voice.pullImage` (22500000000 bytes), `working` while it runs; waits (`after: voice.docker`, no fix) while docker is not usable |
| `voice.engine` | see below | `mode`, `state`, `freeMB`, `needMB`, `holders`, `progress`, `reason` | see below |
| `voice.gateway` | always `ok` | `version` | |

`voice.engine`: `ok` when it is running and healthy, and also `ok` when it is stopped and the GPU has 70000 MB
free (the state means "starts on demand"); `working` while it loads, with `progress`; `blocked` when it is
stopped but the free memory is under 70000 MB (facts `freeMB`, `needMB` and `holders`, the programs holding
the GPU, largest first) or when it is down (`reason`); `todo` with `after` naming the step above it while
something is missing. There is never a fix for a busy GPU: the gateway does not stop anyone else's job.

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
docker run -d --rm --name nemotron-labs-voicechat --device nvidia.com/gpu=0 --shm-size=8GB \
  -e NIM_HTTP_API_PORT=9000 -p 127.0.0.1:9000:9000 -v <model dir>:/data/models \
  --entrypoint /s2s/run_s2s_server.sh nvcr.io/nim/nvidia/nemotron-labs-voicechat:latest
```

(CDI device form, because this Docker has no `nvidia` runtime.) `<model dir>` is `VOICE_MODEL_DIR`, or the
`nemotron-labs-voicechat_v1.0.0` folder inside it where NGC unpacks the download.

- A start happens only for a call, and only if the GPU's free memory, read again right before, is at least
  70000 MB. Otherwise nothing starts, `/health` says `busy` naming who holds the GPU, and the call gets
  `engine(busy)` and `error(engineDown)`. Missing pieces give `engine(needsSetup)` and the same error.
- While the engine loads, the call's socket stays open and the gateway sends `engine(loading, progress)` every 2
  seconds, then continues with `ready` exactly as for a running engine. The NIM reports no percentage, so
  `progress` is the time spent against a typical 4 minute load (never above 0.99 before it is ready): a picture,
  not a measurement. A load that is not ready after 8 minutes stops the container and sends
  `error(engineDown)` with the reason, as does a refused `docker run` or a container that dies.
- After `VOICE_IDLE_STOP_MINUTES` with no call and no setup job, `docker stop nemotron-labs-voicechat` returns the
  GPU to whatever else the machine does. The gateway touches no other container, ever: it matches the name
  exactly, and a stale container of ours in a stopped state is removed with `docker rm -f` by that name.
- Restarting the gateway leaves a running engine alone. A client that leaves while the engine loads does not
  stop the load.

### Known gaps

The unit tests use fake `docker`, `nvidia-smi`, `nvidia-ctk`, `ngc`, `curl` and `df`. Three behaviours of
NVIDIA's tools are written from their documentation and have not run end to end here: whether `ngc` resumes a
partial download by itself when run again (the gateway simply runs it again on the same directory), the
exact text of its authentication errors (used to tell `denied` from `network`), and `docker pull` output
under the containerd image store (used for layer counting; without layer lines the job still runs, with no
fraction). A card whose `nvidia-smi` reports no memory size (unified memory) is reported unavailable.

## Install

```
swift build -c release && install -m755 .build/release/voice-bridge .build/release/voice-probe ~/.local/bin/
cp packaging/voice-bridge.service ~/.config/systemd/user/
```

Put `VOICE_*` settings (and `NGC_API_KEY`) in `~/.config/voice-bridge.env`, then enable the unit with
`systemctl --user`. The user running it must be able to use Docker (`docker version` works) and see `nvidia-smi`.

`packaging/nemotron-voicechat.service` is only for `VOICE_ENGINE=external`: it keeps the container running
all the time, which is what the managed engine replaces.

## voice-probe

The measurement tool for the real-GPU gate. It talks to the NIM directly, with the same session setup,
tools and recycle policy as the gateway.

```
voice-probe run --nim ws://127.0.0.1:9000/v1/realtime --wav a.wav --wav b.wav \
    [--gap-ms 1500] [--settle-ms 4000] \
    [--barge-in-ms 300 --interrupt-wav x.wav] [--soak-seconds 600] [--json out.json]
```

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

`swift test`. Everything runs on loopback against a scripted fake NIM; no GPU, docker, network or display. The
machine is faked two ways: a scripted `CommandRunner` that answers `docker`, `nvidia-smi` and the rest from a
value, and real processes (fake executables in a temporary `PATH`) for the jobs, so process groups, streaming
and cancel are the real thing.
