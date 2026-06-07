require "async/websocket/adapters/rack"

module Shaolin
  module HTTP
    # First-class WebSocket for the Falcon (async) server, on async-websocket
    # (issue #28) — the Falcon-native WS (same author as Falcon), not the
    # EventMachine-era faye. A controller action upgrades with `ws(req) { |s| ... }`
    # and gets a JS-like `Socket`: register `on_open`/`on_message`/`on_close`/
    # `on_error`, then `send` / `close`. Each inbound frame is delivered to
    # `on_message` as a String (text or binary bytes). Falcon only (async reactor);
    # under Puma use a dedicated WS server.
    module WebSocket
      module_function

      def upgrade?(env) = Async::WebSocket::Adapters::Rack.websocket?(env)

      # SERVER: upgrade `env` to a WebSocket; yields a Socket to `setup` (which
      # registers callbacks), then runs the read loop until the peer closes.
      # Returns the Rack response the async server drives. `nil` if not a WS request.
      def open(env, &setup)
        Async::WebSocket::Adapters::Rack.open(env) do |connection|
          run_socket(connection, setup)
        end
      end

      # CLIENT: connect OUT to ANY WebSocket server (Asterisk ARI, a third-party
      # feed, another shaolin service — domain-agnostic, same Socket API). Runs
      # inside the caller's Async reactor. `headers:` for auth/subprotocols.
      #
      #   Shaolin::HTTP::WebSocket.connect("wss://host/path", headers: { "authorization" => "Bearer x" }) do |s|
      #     s.on_message { |data| ... }
      #     s.send("hello")
      #   end
      def connect(url, headers: {}, &setup)
        require "async/websocket/client"
        require "async/http/endpoint"
        endpoint = Async::HTTP::Endpoint.parse(url)
        Async::WebSocket::Client.connect(endpoint, headers: headers.to_a) do |connection|
          run_socket(connection, setup)
        end
      end

      def run_socket(connection, setup)
        socket = Socket.new(connection)
        setup&.call(socket)
        socket.run
      end

      # JS-like wrapper over an async-websocket connection.
      class Socket
        def initialize(connection)
          @connection = connection
          @handlers = {}
        end

        def on_open(&blk)    = (@handlers[:open] = blk)
        def on_message(&blk) = (@handlers[:message] = blk)
        def on_close(&blk)   = (@handlers[:close] = blk)
        def on_error(&blk)   = (@handlers[:error] = blk)

        # Send a frame. Strings go as text by default; pass binary: true for bytes.
        def send(data, binary: false)
          binary ? @connection.send_binary(data) : @connection.send_text(data.to_s)
          @connection.flush
          self
        end

        def close = @connection.close

        # Drive the connection: open → message* → close. Any handler/IO error is
        # routed to on_error (if set) and ends the loop cleanly.
        def run
          @handlers[:open]&.call(self)
          while (message = @connection.read)
            @handlers[:message]&.call(message.buffer, self)
          end
        rescue StandardError => e
          @handlers[:error]&.call(e, self)
        ensure
          @handlers[:close]&.call(self)
          begin
            @connection.close
          rescue StandardError
            nil
          end
        end
      end
    end
  end
end
