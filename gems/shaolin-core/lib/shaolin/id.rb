require "securerandom"
require "digest/sha1"

module Shaolin
  # Id helpers. `deterministic(*parts)` derives a stable UUID from business keys —
  # the canonical event-sourcing pattern for idempotent ingest: the same inputs
  # always yield the same aggregate/stream id, so a re-delivered message maps to
  # the same aggregate (no duplicate). Implemented as a v5-style UUID (SHA1 over a
  # namespace + the joined parts), so it's stable across processes and Ruby
  # versions (SecureRandom.uuid_v5 isn't available everywhere). `generate` is a
  # random v4 UUID for genuinely new entities.
  module Id
    DEFAULT_NAMESPACE = "shaolin".freeze
    SEP = "".freeze # unit separator — unambiguous join of parts

    module_function

    def generate = SecureRandom.uuid

    def deterministic(*parts, namespace: DEFAULT_NAMESPACE)
      raise ArgumentError, "deterministic id needs at least one part" if parts.empty?

      digest = Digest::SHA1.digest([namespace, *parts].join(SEP))
      bytes = digest[0, 16].bytes
      bytes[6] = (bytes[6] & 0x0f) | 0x50 # version 5
      bytes[8] = (bytes[8] & 0x3f) | 0x80 # RFC 4122 variant
      hex = bytes.map { |b| format("%02x", b) }.join
      "#{hex[0, 8]}-#{hex[8, 4]}-#{hex[12, 4]}-#{hex[16, 4]}-#{hex[20, 12]}"
    end
  end
end
