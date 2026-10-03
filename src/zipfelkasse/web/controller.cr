module Zipfelkasse::Web
  abstract class Controller
    def initialize(@d : Deps)
    end

    abstract def register : Nil

    protected def page(env : HTTP::Server::Context, view : View, title : String, nav : Nav? = nil, status = 200,
                       error : String? = nil, scripts = [] of String) : String
      Web.render_page(env, @d.store, status, Page.new(title, nav, error, scripts), view)
    end

    protected def redirect(env : HTTP::Server::Context, location : String, flash : String? = nil) : String
      env.flash = flash if flash
      env.redirect(location, 303)
      ""
    end

    protected def or_404(env : HTTP::Server::Context, message : String, & : -> T) : T forall T
      yield
    rescue Store::NotFound
      raise HTTPError.new(env, 404, message)
    end

    # Statuses with an error handler are raised, the others answered here.
    protected def api_error(env : HTTP::Server::Context, status : Int32, message : String) : String
      raise HTTPError.new(env, status, message) if ERROR_STATUSES.includes?(status)
      env.response.status_code = status
      env.response.content_type = "application/json; charset=utf-8"
      {error: message}.to_json
    end

    # Raises Store::NotFound unless the path ends in a positive number.
    protected def path_id(env : HTTP::Server::Context) : Int64
      Web.positive_id?(env.params.url["id"]?) || raise Store::NotFound.new
    end
  end
end
