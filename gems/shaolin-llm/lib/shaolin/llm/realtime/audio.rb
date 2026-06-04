require "base64"

module Shaolin
  module LLM
    module Realtime
      # Provider-agnostic audio primitives for realtime sessions. Audio crosses the
      # wire as base64 over the session; this normalizes encode/decode and names
      # the default PCM format realtime APIs expect (16-bit little-endian PCM,
      # 24 kHz, mono). Adapters convert to/from their provider's framing.
      module Audio
        # The de-facto realtime input/output format (OpenAI Realtime, etc.).
        FORMAT = { encoding: "pcm16", sample_rate: 24_000, channels: 1 }.freeze

        module_function

        def encode(bytes) = Base64.strict_encode64(bytes.to_s)
        def decode(b64) = Base64.strict_decode64(b64.to_s)

        # Split a PCM buffer into ~`ms`-millisecond frames (handy for paced sends).
        def frames(bytes, ms: 20, format: FORMAT)
          bytes_per_sample = 2 * format[:channels]
          per_frame = (format[:sample_rate] * ms / 1000) * bytes_per_sample
          bytes.to_s.scan(/.{1,#{per_frame}}/m)
        end
      end
    end
  end
end
