require "kemal"

module Zipfelkasse::Web
  class ErrorHandler
    include HTTP::Handler

    def initialize(@d : Deps)
    end

    def call(context : HTTP::Server::Context)
      call_next(context)
    rescue ex : HTTPError
      Request.new(context, @d).error(ex.status, ex.message || "")
    rescue ex : Kemal::Exceptions::MethodNotAllowed
      methods = ex.allowed_methods
      methods += ["HEAD"] if methods.includes?("GET") && !methods.includes?("HEAD")
      context.response.headers["Allow"] = methods.uniq.sort_by { |m| {"GET", "HEAD", "POST"}.index(m) || 9 }.join(", ")
      Web.text_error(context, 405, "Method Not Allowed")
    rescue ex : Kemal::Exceptions::RouteNotFound
      Web.text_error(context, 404, "404 page not found")
    rescue ex
      Request.new(context, @d).server_error(ex)
    end
  end

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
