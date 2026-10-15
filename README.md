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
| `VOICE_LOG_LEVEL` | `info` | swift-log level |

## Health

`GET /health` answers `VoiceHealth`: `engine` is `ready`, `loading`, `down` or `busy`. `ready` means the
NIM's `GET /v1/realtime/health` says `"triton_status":"ready"`, `loading` is its 503, `down` is no
answer, and `busy` is a held call. The probe is cached for 2 seconds.

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

## Install

```
swift build -c release && install -m755 .build/release/voice-bridge .build/release/voice-probe ~/.local/bin/
cp packaging/voice-bridge.service ~/.config/systemd/user/
```

Put `VOICE_*` settings in `~/.config/voice-bridge.env`, then enable the unit with `systemctl --user`.

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

`swift test`. Everything runs on loopback against a scripted fake NIM; no GPU, docker or display.
