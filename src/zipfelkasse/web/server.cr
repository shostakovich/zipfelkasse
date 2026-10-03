require "kemal"

module Zipfelkasse::Web
  # The central error handler (first in the chain):
  #
  # * HTTPError → the German error page with its status,
  # * an unknown path → plain "404 page not found", a known path with the
  #   wrong method → 405 with Allow (like Go's ServeMux),
  # * anything else → logged, then the 500 page "Da ist etwas schiefgegangen.".
  class ErrorHandler
    include HTTP::Handler

    def initialize(@d : Deps)
    end

    def call(ctx : HTTP::Server::Context)
      call_next(ctx)
    rescue ex : HTTPError
      Request.new(ctx, @d).error(ex.status, ex.message || "")
    rescue ex : Kemal::Exceptions::MethodNotAllowed
      methods = ex.allowed_methods
      methods += ["HEAD"] if methods.includes?("GET") && !methods.includes?("HEAD")
      ctx.response.headers["Allow"] = methods.uniq.sort_by { |m| {"GET", "HEAD", "POST"}.index(m) || 9 }.join(", ")
      Web.text_error(ctx, 405, "Method Not Allowed")
    rescue ex : Kemal::Exceptions::RouteNotFound
      Web.text_error(ctx, 404, "404 page not found")
    rescue ex
      Request.new(ctx, @d).server_error(ex)
    end
  end

  # Builds the HTTP handler chain:
  #
  #     ErrorHandler → SecurityHeaders → MCPMount (/mcp/…) → LimitBody →
  #     CrossOrigin → Identity → routes
  def self.handlers(d : Deps, mcp : MCPMount) : Array(HTTP::Handler)
    Kemal.config.logging = false
    Kemal.config.powered_by_header = false
    Kemal.config.serve_static = false
    Kemal.config.always_rescue = false
    Kemal.config.add_handler(ErrorHandler.new(d))
    Kemal.config.add_handler(SecurityHeaders.new)
    Kemal.config.add_handler(mcp)
    Kemal.config.add_handler(LimitBody.new(d))
    Kemal.config.add_handler(CrossOrigin.new(d))
    Kemal.config.add_handler(Identity.new(d))
    Kemal.config.setup
    Kemal.config.handlers
  end
end
