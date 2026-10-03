require "crypto/subtle"

# An MCP server (JSON-RPC 2.0 over Streamable HTTP, JSON-only responses) at
# /mcp/<MCP_SECRET>. Its tools read, and two of them add expenses and
# reimbursements; nothing is changed or deleted.
#
# Access (see docs/MCP.md): wrong secret → 404, client IP not in
# MCP_ALLOWED_CIDRS → 403 (behind TRUSTED_PROXIES, X-Forwarded-For counts),
# Origin header set → 403. Without MCP_SECRET, MCP is disabled.
#
# Protocol: "dual era". Modern clients (2026-07-28, stateless, _meta in every
# request, mandatory headers) and older clients with the initialize handshake
# (2025-11-25, 2025-06-18, 2025-03-26) are served on the same endpoint.
# There are no sessions and no SSE streams.
module Zipfelkasse::MCP
  Log = ::Log.for(self)

  MAX_BODY = 1 << 20

  # An unread rest of a body of this size or more closes the connection after
  # the response.
  MAX_SKIP = 256 << 10

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
        return text_error(ctx, 404, "404 page not found")
      end
      unless Crypto::Subtle.constant_time_compare(URI.decode(secret), @d.config.mcp_secret)
        Log.warn(&.emit("mcp: wrong secret", ip: ip.to_s, remote: remote))
        return text_error(ctx, 404, "404 page not found")
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
        text_error(ctx, 405, "Method Not Allowed")
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
    ensure
      # A client still writing would get a reset instead of the response.
      ctx.request.body.try { |body| discard(body, 4 * MAX_BODY) }
    end

    private def text_error(ctx : HTTP::Server::Context, status : Int32, message : String) : Nil
      skip_unread(ctx)
      Web.text_error(ctx, status, message)
    end

    # Before the response: skips what the handler left unread and closes the
    # connection if that is MAX_SKIP or more (a known Content-Length counts
    # the rest in advance, so exactly MAX_SKIP is enough then).
    private def skip_unread(ctx : HTTP::Server::Context) : Nil
      req = ctx.request
      body = req.body || return
      n = discard(body, MAX_SKIP + 1)
      ctx.response.headers["Connection"] = "close" if n > MAX_SKIP || (n == MAX_SKIP && req.content_length)
    end

    # The number of bytes read, at most limit.
    private def discard(io : IO, limit : Int32) : Int32
      buf = Bytes.new(64 * 1024)
      total = 0
      while total < limit
        n = begin
          io.read(buf[0, Math.min(buf.size, limit - total)])
        rescue IO::Error
          0
        end
        break if n == 0
        total += n
      end
      total
    end
  end
end

module Zipfelkasse
  class App
    # Mounts /mcp/<secret>; without MCP_SECRET, MCP stays disabled.
    def self.wire_mcp(app : App, d : Web::Deps, mcp : Web::MCPMount) : Nil
      if d.config.mcp_secret.empty?
        Log.info { "MCP disabled (MCP_SECRET is empty)" }
        return
      end
      server = MCP::Server.new(d)
      mcp.endpoint = ->server.call(HTTP::Server::Context)
      Log.info(&.emit("MCP enabled", path: "/mcp/***", allowed: d.config.mcp_allowed_cidrs.map(&.to_s),
        proxies: d.config.trusted_proxies.map(&.to_s)))
    end
  end
end
