require "http/server/handler"
require "uri"

module Zipfelkasse::Web
  SECURITY_HEADERS = HTTP::Headers{
    "X-Content-Type-Options"  => "nosniff",
    "Referrer-Policy"         => "same-origin",
    "X-Frame-Options"         => "DENY",
    "Content-Security-Policy" => "default-src 'self'; img-src 'self' data: https://felt-css.rocu.de; style-src 'self' https://felt-css.rocu.de; frame-ancestors 'none'; base-uri 'self'; form-action 'self'",
  }

  UNIDENTIFIED_PATHS = {"/healthz", "/sw.js", "/favicon.ico"}
  # The manifest carries the icons of the person's look.
  PUBLIC_PATHS = {"/wer", "/wer/neu", "/manifest.webmanifest"}

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

  # Sets the security headers, rejects requests that a browser sends from a
  # foreign site and selects the person. Public paths work without a person,
  # static files need none.
  def self.install_filters(store : Store) : Nil
    before_all { |env| env.response.headers.merge!(SECURITY_HEADERS) }
    before_all do |env|
      request = env.request
      next if request.path.starts_with?("/mcp/")
      unless same_origin?(request)
        Log.warn(&.emit("cross-origin request rejected", method: request.method, path: request.path,
          origin: request.headers["Origin"]? || ""))
        halt env, 403, error_body(env, store, 403)
      end
      next if admitted?(env, store)
      halt env, 401, error_body(env, store, 401) if request.path.starts_with?("/api/")
      env.redirect(login_path(request), 303)
    end
  end

  # Sec-Fetch-Site, or Origin against Host. Requests without these headers
  # (curl) pass, since they carry no victim's cookie.
  def self.same_origin?(request : HTTP::Request) : Bool
    return true if request.method.in?("GET", "HEAD", "OPTIONS")
    if site = request.headers["Sec-Fetch-Site"]?.presence
      return site.in?("same-origin", "none")
    end
    origin = request.headers["Origin"]?.presence || return true
    URI.parse(origin).authority == request.headers["Host"]?
  rescue URI::Error
    false
  end

  def self.login_path(request : HTTP::Request) : String
    return "/wer" unless request.method == "GET" && request.path != "/"
    "/wer?zurueck=" + URI.encode_www_form(request.resource)
  end

  private def self.admitted?(env : HTTP::Server::Context, store : Store) : Bool
    path = env.request.path
    return true if path.starts_with?("/static/") || UNIDENTIFIED_PATHS.includes?(path)
    id = env.request.cookies[IDENTITY_COOKIE]?.try(&.value.to_i64?(whitespace: false))
    participant = id.try { |i| store.get_participant?(i) }
    return PUBLIC_PATHS.includes?(path) if participant.nil? || participant.archived?
    env.me = participant
    true
  end
end
