require "http/server"
require "uri"
require "base64"

class HTTP::Server::Context
  # The selected person (set by the identity middleware).
  property zk_me : Zipfelkasse::Store::Participant? = nil
end

module Zipfelkasse::Web
  # Values for Page#nav: which tab of the main navigation is active.
  NAV_EXPENSES = "ausgaben"
  NAV_BALANCES = "salden"
  NAV_ACTIVITY = "aktivitaet"
  NAV_SETTINGS = "einstellungen"

  # The identity cookie holds the ID of the person you are. No login:
  # whoever can open the app may pick any person.
  IDENTITY_COOKIE = "wer"
  FLASH_COOKIE    = "flash"

  # An exchange-rate source (implemented by FX::Service): the rate of a
  # currency for a date in ECB format, manual rates take precedence.
  module FXRater
    abstract def rate(currency : String, date : Time) : Domain::FXRate
  end

  # The shared dependencies of all HTTP packages.
  class Deps
    getter config : Config
    getter store : Store
    getter render : Renderer
    getter log : Logger
    # Exchange rates (FX::Service); nil until main has created it.
    property fx : FXRater? = nil

    def initialize(@config, @store, @render, @log)
    end

    # Today's date in the configured time zone.
    def today : Time
      @config.today
    end

    def now : Time
      @config.now
    end
  end

  # Ends a request with the German error page and this status.
  class HTTPError < Exception
    getter status : Int32

    def initialize(@status : Int32, message : String)
      super(message)
    end

    def self.not_found(message : String) : HTTPError
      new(404, message)
    end
  end

  # A request with the helpers handlers need.
  class Request
    getter ctx : HTTP::Server::Context
    getter d : Deps

    def initialize(@ctx, @d)
    end

    delegate response, request, to: @ctx

    def path : String
      @ctx.request.path
    end

    def method : String
      @ctx.request.method
    end

    # The selected person; behind the identity middleware it is always set
    # on non-public paths.
    def me : Store::Participant
      @ctx.zk_me || raise "no person selected"
    end

    def me? : Store::Participant?
      @ctx.zk_me
    end

    # The path parameter :id (Go's PathID): invalid or <= 0 gives 0.
    def path_id : Int64
      Web.form_id(@ctx.params.url["id"]? || "", trim: false)
    end

    def query(name : String) : String
      @ctx.params.query[name]? || ""
    end

    def query_params : URI::Params
      @ctx.params.query
    end

    # Go's PostFormValue: the first value from the request body.
    def post_form_value(name : String) : String
      body_params[name]? || ""
    end

    # All values of a field from the request body (e.g. several "teil").
    def post_form_values(name : String) : Array(String)
      body_params.fetch_all(name)
    end

    # The urlencoded (or multipart) form in the request body.
    def body_params : URI::Params
      @ctx.params.body
    end

    # Go's FormValue: body first, then the URL query.
    def form_value(name : String) : String
      body_params[name]? || query(name)
    end

    # --- responses ---------------------------------------------------------------

    # Renders a page in the layout (see Renderer#page).
    def page(status : Int32, page : Page, & : IO ->) : Nil
      @d.render.page(self, status, page) { |io| yield io }
    end

    # The German error page with status.
    def error(status : Int32, message : String) : Nil
      @d.render.error(self, status, message)
    end

    def not_found(message : String) : Nil
      error(404, message)
    end

    # Logs err and renders the 500 page.
    def server_error(ex : Exception) : Nil
      @d.log.error("request", method: method, path: Web.log_path(path), err: ex)
      error(500, "Da ist etwas schiefgegangen.")
    end

    # A redirect like Go's http.Redirect (303 unless given): the path is
    # cleaned; GET and HEAD get a tiny HTML body.
    def redirect(url : String, status = 303) : Nil
      Web.redirect(@ctx, url, status)
    end

    # JSON written like Go's json.NewEncoder(w).Encode (HTML characters
    # escaped, trailing newline).
    def json(status : Int32, & : GoCompat::JSON::Builder ->) : Nil
      response.content_type = "application/json; charset=utf-8"
      response.status_code = status
      GoCompat::JSON.encode(response) { |j| yield j }
    end

    # {"error": message}
    def json_error(status : Int32, message : String) : Nil
      json(status) { |j| j.object { j.field "error", message } }
    end

    # Plain text like Go's http.Error.
    def text_error(status : Int32, message : String) : Nil
      Web.text_error(@ctx, status, message)
    end

    # Stores a success message for the next rendered page (pattern POST →
    # redirect → message). Call it before the redirect.
    def set_flash(message : String) : Nil
      response.cookies << HTTP::Cookie.new(FLASH_COOKIE, Base64.urlsafe_encode(message, padding: false),
        path: "/", max_age: 60.seconds, http_only: true, samesite: HTTP::Cookie::SameSite::Lax)
    end

    # Reads and deletes the flash message (every rendered page does this).
    def take_flash : String
      c = request.cookies[FLASH_COOKIE]? || return ""
      response.cookies << HTTP::Cookie.new(FLASH_COOKIE, "", path: "/", max_age: Time::Span.zero)
      begin
        String.new(Base64.decode(c.value))
      rescue Base64::Error
        ""
      end
    end

    # Sets the identity cookie for person id (valid for 1 year).
    def set_identity(id : Int64) : Nil
      secure = request.headers["X-Forwarded-Proto"]? == "https"
      response.cookies << HTTP::Cookie.new(IDENTITY_COOKIE, id.to_s, path: "/", max_age: (365 * 24 * 3600).seconds,
        http_only: true, secure: secure, samesite: HTTP::Cookie::SameSite::Lax)
    end
  end

  # An ID from a form or query value (Go's formID): invalid or <= 0 gives 0.
  # Like strconv.ParseInt it accepts a leading sign and leading zeros.
  def self.form_id(v : String, trim = true) : Int64
    v = GoCompat.trim_space(v) if trim
    return 0_i64 unless v.matches?(/\A[+-]?\d+\z/)
    id = v.to_i64? || 0_i64
    id > 0 ? id : 0_i64
  end

  # The request path for the log: the MCP secret in /mcp/<secret> is masked.
  def self.log_path(p : String) : String
    p.starts_with?("/mcp/") ? "/mcp/***" : p
  end

  # Plain text like Go's http.Error.
  def self.text_error(ctx : HTTP::Server::Context, status : Int32, message : String) : Nil
    res = ctx.response
    res.headers.delete("Content-Length")
    res.headers["Content-Type"] = "text/plain; charset=utf-8"
    res.headers["X-Content-Type-Options"] = "nosniff"
    res.status_code = status
    res.print message, '\n'
  end

  def self.redirect(ctx : HTTP::Server::Context, url : String, status = 303) : Nil
    url = clean_redirect(url)
    res = ctx.response
    res.headers["Location"] = url
    res.status_code = status
    if ctx.request.method.in?("GET", "HEAD")
      res.content_type = "text/html; charset=utf-8"
      res.print %(<a href="#{::HTML.escape(url)}">See Other</a>.\n\n) if ctx.request.method == "GET"
    end
  end

  # path.Clean of the path part, like Go's http.Redirect (query and fragment
  # are kept, a trailing slash too).
  def self.clean_redirect(url : String) : String
    return url unless url.starts_with?('/')
    cut = url.index(/[?#]/) || url.size
    path, rest = url[0, cut], url[cut..]
    cleaned = Path.posix(path).normalize.to_s
    cleaned += "/" if path.ends_with?('/') && !cleaned.ends_with?('/')
    cleaned + rest
  end
end
