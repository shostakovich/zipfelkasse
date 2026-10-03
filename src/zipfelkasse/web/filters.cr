require "http/server/handler"
require "uri"

module Zipfelkasse::Web
  CSP = "default-src 'self'; img-src 'self' data:; style-src 'self'; frame-ancestors 'none'; base-uri 'self'; form-action 'self'"

  class SecurityHeaders
    include HTTP::Handler

    def call(context : HTTP::Server::Context)
      headers = context.response.headers
      headers["X-Content-Type-Options"] = "nosniff"
      headers["Referrer-Policy"] = "same-origin"
      headers["X-Frame-Options"] = "DENY"
      headers["Content-Security-Policy"] = CSP
      call_next(context)
    end
  end

  # Client disconnects and timeouts surface as IO errors in whatever handler
  # reads or writes; they are no server errors.
  class QuietDisconnects
    include HTTP::Handler

    def call(context : HTTP::Server::Context)
      call_next(context)
    rescue ex : IO::Error
      Log.debug(exception: ex) { "client connection lost" }
    end
  end

  # Rejects requests that a browser sends from a foreign site and selects the
  # person. Public paths work without a person, static files need none.
  class Gate
    UNIDENTIFIED = {"/healthz", "/manifest.webmanifest", "/sw.js", "/favicon.ico"}
    PUBLIC       = {"/wer", "/wer/neu"}

    def initialize(@d : Deps)
    end

    def install : Nil
      gate = self
      before_all do |env|
        next if env.request.path.starts_with?("/mcp/")
        halt env, 403, gate.rejection(env, 403) unless gate.same_origin?(env.request)
        next if gate.admitted?(env)
        halt env, 401, gate.rejection(env, 401) if env.request.path.starts_with?("/api/")
        env.redirect(gate.login_path(env.request), 303)
      end
    end

    def rejection(env : HTTP::Server::Context, status : Int32) : String
      request = env.request
      Log.warn(&.emit("cross-origin request rejected", method: request.method, path: request.path,
        origin: request.headers["Origin"]? || "")) if status == 403
      Web.error_body(env, @d.store, status)
    end

    # Sec-Fetch-Site, or Origin against Host. Requests without these headers
    # (curl) pass, since they carry no victim's cookie.
    def same_origin?(request : HTTP::Request) : Bool
      return true if request.method.in?("GET", "HEAD", "OPTIONS")
      if site = request.headers["Sec-Fetch-Site"]?.presence
        return site.in?("same-origin", "none")
      end
      origin = request.headers["Origin"]?.presence || return true
      URI.parse(origin).authority == request.headers["Host"]?
    rescue URI::Error
      false
    end

    def admitted?(env : HTTP::Server::Context) : Bool
      path = env.request.path
      return true if path.starts_with?("/static/") || UNIDENTIFIED.includes?(path)
      identify(env) || PUBLIC.includes?(path)
    end

    def login_path(request : HTTP::Request) : String
      return "/wer" unless request.method == "GET" && request.path != "/"
      "/wer?zurueck=" + URI.encode_www_form(request.resource)
    end

    private def identify(env : HTTP::Server::Context) : Bool
      id = env.request.cookies[IDENTITY_COOKIE]?.try(&.value.to_i64?(whitespace: false)) || return false
      participant = @d.store.get_participant?(id) || return false
      return false if participant.archived?
      env.me = participant
      true
    end
  end
end
