require "json"

module Shaolin
  module LLM
    module Realtime
      # A concrete WebSocket transport for a realtime Client (e.g.
      # `Realtime::OpenAI`) on async-websocket (Falcon-native) — closes the
      # "inject a transport" gap (#28). Satisfies the transport contract:
      # `send(hash)` → a JSON text frame; inbound text frames → parsed (symbol-key)
      # hash to `on_message`; `close`. `connect(url:, headers:)` opens the client —
      # call it inside a running Async reactor (e.g. a Falcon request fiber).
      #
      #   t = Realtime::WebSocketTransport.connect(
      #     url: "wss://api.openai.com/v1/realtime?model=gpt-4o-realtime-preview",
      #     headers: { "authorization" => "Bearer #{ENV['OPENAI_API_KEY']}",
      #                "openai-beta" => "realtime=v1" })
      #   session = Realtime::OpenAI.new(transport: t).connect(...)
      class WebSocketTransport
        def self.connect(url:, headers: {})
          require "async/websocket/client"
          require "async/http/endpoint"
          endpoint = Async::HTTP::Endpoint.parse(url)
          new(Async::WebSocket::Client.connect(endpoint, headers: headers.to_a))
        end

        def initialize(connection)
          @connection = connection
          @on_message = nil
          @reader = nil
        end

        def send(hash)
          @connection.send_text(JSON.generate(hash))
          @connection.flush
        end

        # Register the inbound handler and start reading. The reader runs as an
        # Async task (needs a reactor); each text frame is parsed and dispatched.
        def on_message(&block)
          @on_message = block
          start_reader
        end

        def close
          @reader&.stop if @reader.respond_to?(:stop)
          @connection.close
        end

        # Parse + dispatch one raw frame buffer (the unit the reader feeds).
        def dispatch(buffer)
          @on_message&.call(JSON.parse(buffer, symbolize_names: true))
        end

        private

        def start_reader
          return if @reader

          require "async"
          @reader = Async do
            while (message = @connection.read)
              dispatch(message.buffer)
            end
          rescue StandardError
            nil
          end
        end
      end
    end
  end
end
