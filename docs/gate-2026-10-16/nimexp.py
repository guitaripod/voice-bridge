import asyncio, base64, json, sys, time, uuid, wave
import websockets

NIM = "ws://127.0.0.1:9000/v1/realtime"

def tools(variant):
    noarg = {"type": "object", "properties": {}}
    task = {"type": "object", "properties": {"task": {"type": "string", "description": "What the person asked for, in their own words."}}, "required": ["task"]}
    send_params = task if variant.get("task_arg") else noarg
    base = [
        {"type": "function", "name": "send_to_agent", "description": variant.get("send_desc", "Send the task the person just described to the coding agent. Call it once, after the person has finished stating the task."), "ack_messages": ["Sending that now.", "One moment."], "parameters": send_params},
        {"type": "function", "name": "agent_status", "description": "Get a short account of what the coding agent is doing right now.", "ack_messages": ["Let me check.", "Checking."], "parameters": noarg},
        {"type": "function", "name": "stop_agent", "description": variant.get("stop_desc", "Stop whatever the coding agent is doing right now."), "ack_messages": ["Stopping it.", "On it."], "parameters": noarg},
    ]
    if variant.get("no_stop"):
        base = [t for t in base if t["name"] != "stop_agent"]
    return base

async def run(prompt, variant, wavs):
    results = []
    async with websockets.connect(NIM, max_size=None) as ws:
        def ev(t, **kw): return json.dumps({"type": t, "event_id": str(uuid.uuid4()), **kw})
        await ws.send(ev("session.update", session={"audio": {"input": {"format": "pcm16"}, "output": {"format": "pcm16"}}, "instructions": prompt, "tools": tools(variant)}))
        cur = {"heard": "", "said": "", "tools": [], "audio_ms": 0}
        async def reader():
            async for m in ws:
                d = json.loads(m)
                t = d.get("type")
                if t == "conversation.item.input_audio_transcription.completed":
                    cur["heard"] = d.get("transcript", "")
                elif t == "response.output_audio_transcript.done":
                    cur["said"] += " " + d.get("transcript", "")
                elif t == "response.output_audio.delta":
                    cur["audio_ms"] += len(base64.b64decode(d["delta"])) / 48
                elif t == "response.function_call_arguments.done":
                    cur["tools"].append((d.get("name"), d.get("arguments")))
                    await ws.send(ev("conversation.item.create", item={"type": "function_call_output", "call_id": d["call_id"], "output": "Sent."}))
                elif t == "error":
                    cur["said"] += f" [error {d}]"
        rt = asyncio.create_task(reader())
        await asyncio.sleep(1.5)
        for path in wavs:
            cur.update({"heard": "", "said": "", "tools": [], "audio_ms": 0})
            w = wave.open(path, "rb"); data = w.readframes(w.getnframes())
            for i in range(0, len(data), 3840):
                await ws.send(ev("input_audio_buffer.append", audio=base64.b64encode(data[i:i+3840]).decode()))
                await asyncio.sleep(0.08)
            for _ in range(int(variant.get('settle', 75))):
                await ws.send(ev("input_audio_buffer.append", audio=base64.b64encode(bytes(3840)).decode()))
                await asyncio.sleep(0.08)
            results.append(dict(cur))
        await ws.send(ev("session.close"))
        rt.cancel()
    return results

if __name__ == "__main__":
    prompt = open(sys.argv[1]).read().strip()
    variant = json.loads(sys.argv[2])
    res = asyncio.run(run(prompt, variant, sys.argv[3:]))
    calls = sum(1 for r in res if any(n == "send_to_agent" for n, _ in r["tools"]))
    for r in res: print(f"  heard={r['heard']!r}\n    tools={r['tools']} said={r['said'].strip()[:110]!r}")
    print(f"send_to_agent {calls}/{len(res)}")
