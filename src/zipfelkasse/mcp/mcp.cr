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
  MAX_BODY = 1 << 20

  # What is logged about a request.
  class RequestInfo
    property method = ""
    property tool = ""
    property version = ""
    property tool_error = ""
    property status = 200
  end

  class Server
    # The path contains the secret and is never logged.
    def call(ctx : HTTP::Server::Context) : Nil
      start = Time.instant
      req = ctx.request
      ip = MCP.client_ip(req, @d.config.trusted_proxies)
      secret = req.path.lchop("/mcp/")
      if secret.empty? || secret.includes?('/')
        return Web.text_error(ctx, 404, "404 page not found")
      end
      unless Crypto::Subtle.constant_time_compare(URI.decode(secret), @d.config.mcp_secret)
        @log.warn("mcp: wrong secret", ip: ip, remote: req.remote_address.to_s)
        return Web.text_error(ctx, 404, "404 page not found")
      end
      unless ip.in?(@d.config.mcp_allowed_cidrs)
        @log.warn("mcp: IP not allowed", ip: ip, remote: req.remote_address.to_s,
          x_forwarded_for: req.headers.get?("X-Forwarded-For") || [] of String, x_real_ip: req.headers["X-Real-IP"]? || "")
        return write_error(ctx, 403, nil, CODE_FORBIDDEN, "Access from this address is not allowed.")
      end
      if (origin = req.headers["Origin"]?) && !origin.empty?
        @log.warn("mcp: Origin header rejected", ip: ip, origin: origin)
        return write_error(ctx, 403, nil, CODE_FORBIDDEN, "Access from a browser is not allowed.")
      end
      if req.method != "POST"
        ctx.response.headers["Allow"] = "POST"
        Web.text_error(ctx, 405, "Method Not Allowed")
        return @log.info("mcp", ip: ip, http: req.method, status: 405)
      end

      info = RequestInfo.new
      handle_post(ctx, info)
      attrs = {"ip" => ip.to_s, "method" => info.method, "status" => info.status.to_s,
               "duration" => "#{(Time.instant - start).total_milliseconds.round.to_i}ms"}
      attrs["tool"] = info.tool unless info.tool.empty?
      attrs["version"] = info.version unless info.version.empty?
      attrs["tool_error"] = info.tool_error unless info.tool_error.empty?
      @log.log(Logger::Level::Info, "mcp", attrs)
    end
  end
end

module Zipfelkasse
  class App
    # Mounts /mcp/<secret>; without MCP_SECRET, MCP stays disabled.
    def self.wire_mcp(app : App, d : Web::Deps, mcp : Web::MCPMount) : Nil
      if d.config.mcp_secret.empty?
        d.log.info("MCP disabled (MCP_SECRET is empty)")
        return
      end
      server = MCP::Server.new(d)
      mcp.endpoint = ->server.call(HTTP::Server::Context)
      d.log.info("MCP enabled", path: "/mcp/***", allowed: d.config.mcp_allowed_cidrs.map(&.to_s),
        proxies: d.config.trusted_proxies.map(&.to_s))
    end
  end
end
