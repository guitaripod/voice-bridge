import Foundation
import VoiceKit

extension CallSession {
    func handle(_ frame: ClientFrame) async {
        lastClientFrame = clock.now()
        switch frame {
        case .binary(let pcm): clientAudio(pcm)
        case .text(let text): await clientMessage(text)
        }
    }

    func clientGone() async {
        await finish()
    }

    private func clientMessage(_ text: String) async {
        guard let message = try? VoiceCodec.decodeClient(text) else {
            logger.debug("undecodable client frame")
            return
        }
        switch message {
        case .agent(let state): agent.update(state)
        case .sent(let id): dispatched.removeValue(forKey: id)
        case .refused(let id, let reason):
            logger.info("dispatch refused", metadata: ["reason": "\(reason)"])
            if let text = dispatched.removeValue(forKey: id), dispatchMode == .tool { buffer.requeue(text) }
        case .bye: await finish()
        case .hello, .unknown: break
        }
    }

    private func clientAudio(_ pcm: Data) {
        guard !pcm.isEmpty, pcm.count % 2 == 0, pcm.count <= VoiceWire.maxChunkBytes else {
            logger.debug("dropped malformed audio frame", metadata: ["bytes": "\(pcm.count)"])
            return
        }
        guard !terminal else { return }
        if swapping {
            replay.append(pcm)
            return
        }
        recycle.addAudio(seconds: PCM.seconds(bytes: pcm.count))
        nim?.appendAudio(pcm)
    }
}
