require "crypto/subtle"

# The MCP server at /mcp/<MCP_SECRET>: docs/MCP.md describes access and protocol.
module Zipfelkasse::MCP
  Log = ::Log.for(self)

  MAX_BODY = Web::MAX_BODY_BYTES

  # What is logged about a request.
  class RequestInfo
    property method = ""
    property tool = ""
    property version = ""
    property tool_error = ""
  end

  class Server
    # The path contains the secret and is never logged.
    def call(ctx : HTTP::Server::Context) : Nil
      start = Time.instant
      req = ctx.request
      remote = req.remote_address.to_s
      ip = MCP.client_ip(remote, req.headers, @d.config.trusted_proxies)
      secret = req.path.lchop("/mcp/")
      if secret.empty? || secret.includes?('/')
        return Web.text_error(ctx, 404, "404 page not found")
      end
      unless Crypto::Subtle.constant_time_compare(URI.decode(secret), @d.config.mcp_secret)
        Log.warn(&.emit("mcp: wrong secret", ip: ip.to_s, remote: remote))
        return Web.text_error(ctx, 404, "404 page not found")
      end
      unless ip.in?(@d.config.mcp_allowed_cidrs)
        Log.warn(&.emit("mcp: IP not allowed", ip: ip.to_s, remote: remote,
          x_forwarded_for: req.headers.get?("X-Forwarded-For") || [] of String, x_real_ip: MCP.header(req.headers, "X-Real-IP")))
        return write_error(ctx, 403, nil, CODE_FORBIDDEN, "Access from this address is not allowed.")
      end
      unless (origin = MCP.header(req.headers, "Origin")).empty?
        Log.warn(&.emit("mcp: Origin header rejected", ip: ip.to_s, origin: origin))
        return write_error(ctx, 403, nil, CODE_FORBIDDEN, "Access from a browser is not allowed.")
      end
      if req.method != "POST"
        ctx.response.headers["Allow"] = "POST"
        Web.text_error(ctx, 405, "Method Not Allowed")
        return Log.info(&.emit("mcp", ip: ip.to_s, http: req.method, status: 405))
      end

      info = RequestInfo.new
      handle_post(ctx, info)
      attrs = {:ip => ip.to_s, :method => info.method, :status => ctx.response.status_code.to_s,
               :duration => "#{(Time.instant - start).total_milliseconds.round.to_i}ms"}
      attrs[:tool] = info.tool unless info.tool.empty?
      attrs[:version] = info.version unless info.version.empty?
      attrs[:tool_error] = info.tool_error unless info.tool_error.empty?
      Log.info(&.emit("mcp", attrs))
    end
  end

  # Sends everything below /mcp/ to the server, before Kemal's filters and
  # routes: no person to pick, no CSRF check, since the server rejects any
  # Origin itself.
  class Mount
    include HTTP::Handler

    def initialize(@server : Server)
    end

    def call(context : HTTP::Server::Context)
      if context.request.path.starts_with?("/mcp/")
        @server.call(context)
      else
        call_next(context)
      end
    end
  end
end

# Until the tool arguments in mcp/tools.cr are nilable.
module Zipfelkasse::Web
  def self.nil_if_zero(id : Int64) : Int64?
    id unless id == 0
  end
end
