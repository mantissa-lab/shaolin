require "socket"
require "net/http"

module NetHelpers
  def free_port
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    server.close
    port
  end

  # Poll an HTTP endpoint until it responds (server booting in a thread).
  def get_when_ready(port, path = "/", attempts: 50)
    attempts.times do
      return Net::HTTP.get_response(URI("http://127.0.0.1:#{port}#{path}"))
    rescue StandardError
      sleep 0.1
    end
    nil
  end
end
