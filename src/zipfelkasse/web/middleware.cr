require "http/server/handler"
require "uri"

module Zipfelkasse::Web
  CSP = "default-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; frame-ancestors 'none'; base-uri 'self'; form-action 'self'"

  # Request bodies are limited (forms are a few KB).
  MAX_BODY_BYTES = 1 << 20

  # CSP: scripts only from /static (no inline scripts!), inline styles are
  # allowed.
  class SecurityHeaders
    include HTTP::Handler

    def call(context : HTTP::Server::Context)
      h = context.response.headers
      h["X-Content-Type-Options"] = "nosniff"
      h["Referrer-Policy"] = "same-origin"
      h["X-Frame-Options"] = "DENY"
      h["Content-Security-Policy"] = CSP
      call_next(context)
    end
  end

  # Sends everything below /mcp/ to the MCP endpoint, outside the browser
  # middleware (no person to pick, no CSRF check: MCP rejects any Origin
  # itself, and checks its own body limit). Without MCP: plain 404.
  class MCPMount
    include HTTP::Handler

    property endpoint : (HTTP::Server::Context -> Nil)? = nil

    def call(context : HTTP::Server::Context)
      return call_next(context) unless context.request.path.starts_with?("/mcp/")
      if ep = @endpoint
        ep.call(context)
      else
        Web.text_error(context, 404, "404 page not found")
      end
    end
  end

  # Rejects request bodies larger than MAX_BODY_BYTES with 413. Bodies
  # without Content-Length are read here already, so that an oversized one
  # also yields 413 instead of an empty form.
  class LimitBody
    include HTTP::Handler

    def initialize(@d : Deps)
    end

    def call(context : HTTP::Server::Context)
      req = context.request
      body = req.body
      return call_next(context) if body.nil?
      length = req.content_length
      too_large = false
      if length
        too_large = length > MAX_BODY_BYTES
      else
        data = Bytes.new(MAX_BODY_BYTES + 1)
        n = 0
        while n < data.size && (k = body.read(data[n..])) > 0
          n += k
        end
        too_large = n > MAX_BODY_BYTES
        req.body = IO::Memory.new(data[0, n]) unless too_large
      end
      return call_next(context) unless too_large
      @d.log.warn("request body too large", method: req.method, path: Web.log_path(req.path), content_length: length || -1)
      context.response.headers["Connection"] = "close"
      r = Request.new(context, @d)
      if req.path.starts_with?("/api/")
        r.json_error(413, "Die Anfrage ist zu groß.")
      else
        r.error(413, "Die gesendeten Daten sind zu groß. Bitte kürze die Eingaben und versuche es noch einmal.")
      end
      drain(body)
    end

    # Closing while the client is still sending makes it see a connection
    # reset instead of the 413; reading the rest (bounded) avoids that.
    private def drain(body : IO) : Nil
      buf = Bytes.new(64 * 1024)
      left = 16 * MAX_BODY_BYTES
      while left > 0 && (n = body.read(buf[0, Math.min(buf.size, left)])) > 0
        left -= n
      end
    rescue IO::Error
    end
  end

  # Rejects POSTs and the like that a browser sends from a foreign site
  # (Sec-Fetch-Site, or Origin ≠ Host). Requests without these headers (curl)
  # pass, since they carry no victim's cookie.
  class CrossOrigin
    include HTTP::Handler

    def initialize(@d : Deps)
    end

    def call(context : HTTP::Server::Context)
      return call_next(context) if allowed?(context.request)
      req = context.request
      @d.log.warn("cross-origin request rejected", method: req.method, path: Web.log_path(req.path), origin: req.headers["Origin"]? || "")
      r = Request.new(context, @d)
      if req.path.starts_with?("/api/")
        r.json_error(403, "Anfrage von einer fremden Seite abgelehnt.")
      else
        r.error(403, "Diese Anfrage kam von einer fremden Seite und wurde abgelehnt. Bitte lade die Seite neu und versuche es noch einmal.")
      end
    end

    private def allowed?(req : HTTP::Request) : Bool
      return true if req.method.in?("GET", "HEAD", "OPTIONS")
      if site = req.headers["Sec-Fetch-Site"]?.presence
        return site.in?("same-origin", "none")
      end
      origin = req.headers["Origin"]? || return true
      URI.parse(origin).authority == req.headers["Host"]?
    rescue URI::Error
      false
    end
  end

  class Identity
    include HTTP::Handler

    PUBLIC = {"/wer", "/wer/neu", "/healthz", "/manifest.webmanifest", "/sw.js", "/favicon.ico"}

    def initialize(@d : Deps)
    end

    def call(context : HTTP::Server::Context)
      req = context.request
      if (c = req.cookies[IDENTITY_COOKIE]?) && (id = c.value.to_i64?)
        begin
          p = @d.store.get_participant(id)
          unless p.archived?
            context.zk_me = p
            return call_next(context)
          end
        rescue Store::NotFound
        end
      end
      return call_next(context) if public?(req.path)
      if req.path.starts_with?("/api/")
        return Request.new(context, @d).json_error(401, "Bitte zuerst auswählen, wer du bist.")
      end
      target = "/wer"
      if req.method == "GET" && req.path != "/"
        target += "?zurueck=" + URI.encode_www_form(req.resource)
      end
      Web.redirect(context, target, 303)
    end

    private def public?(path : String) : Bool
      PUBLIC.includes?(path) || path.starts_with?("/static/")
    end
  end

  # Only allows local paths as a return target. Rejected are control
  # characters and backslashes (browsers strip tabs/newlines or read "\" as
  # "/", so "/\t/evil" would become "//evil"), anything with a scheme or
  # host, and paths that start with "//", even only after decoding.
  def self.safe_return(s : String) : String
    return "/" if s.each_char.any? { |c| unsafe_char?(c) }
    return "/" unless s.starts_with?('/') && !s.starts_with?("//")
    path = s.partition(/[?#]/)[0]
    decoded = URI.decode(path)
    return "/" if !decoded.starts_with?('/') || decoded.starts_with?("//") || decoded.each_char.any? { |c| unsafe_char?(c) }
    return "/" if decoded.starts_with?("/wer")
    return "/" unless path.matches?(/\A[^%]*(%[0-9A-Fa-f]{2}[^%]*)*\z/) # reject broken escapes
    s
  end

  private def self.unsafe_char?(c : Char) : Bool
    c == '\\' || c.control?
  end
end
