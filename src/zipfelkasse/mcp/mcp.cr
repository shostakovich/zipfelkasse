require "crypto/subtle"

module Zipfelkasse::MCP
  Log = ::Log.for(self)

  class Server
    def register : Nil
      post("/mcp/:secret") { |env| serve(env) }
    end

    private def serve(env : HTTP::Server::Context) : Nil
      start = Time.instant
      request = env.request
      ip = MCP.client_ip(request.remote_address, request.headers, @d.config.trusted_proxies)
      who = ip.try(&.to_s) || "invalid IP"
      unless Crypto::Subtle.constant_time_compare(env.params.url["secret"], @d.config.mcp_secret)
        Log.warn(&.emit("mcp: wrong secret", ip: who, remote: request.remote_address.to_s))
        raise Kemal::Exceptions::RouteNotFound.new(env)
      end
      log = {} of Symbol => String
      begin
        unless ip && @d.config.mcp_allowed_cidrs.any?(&.contains?(ip))
          Log.warn(&.emit("mcp: IP not allowed", ip: who, remote: request.remote_address.to_s,
            x_forwarded_for: request.headers.get?("X-Forwarded-For") || [] of String, x_real_ip: request.headers["X-Real-IP"]?.to_s))
          raise RPCError.forbidden("Access from this address is not allowed.")
        end
        if origin = request.headers["Origin"]?.presence
          Log.warn(&.emit("mcp: Origin header rejected", ip: who, origin: origin))
          raise RPCError.forbidden("Access from a browser is not allowed.")
        end
        handle_post(env, log)
      rescue ex : RPCError
        reply_error(env, ex)
      end
      Log.info(&.emit("mcp", log.merge({:ip => who, :status => env.response.status_code.to_s,
                                        :duration => "#{(Time.instant - start).total_milliseconds.round.to_i}ms"})))
    end
  end
end
