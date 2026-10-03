module Zipfelkasse::Web
  # Registers a route. The handler gets a Request; errors go to the central
  # handler (Web::ErrorHandler). Kemal's GET routes also answer HEAD.
  def self.route(d : Deps, method : String, path : String, &block : Request -> _) : Nil
    Kemal::RouteHandler::INSTANCE.add_route(method, path) do |ctx|
      block.call(Request.new(ctx, d))
      nil
    end
  end

  # The routes of the core app (people, expenses, balances, activity,
  # settings) plus static files, health check and PWA.
  class Handlers
    include Helpers

    def initialize(@d : Deps)
    end

    def register : Nil
      d = @d
      Web.route(d, "GET", "/static/*") { |r| Static.serve(r) }
      Web.route(d, "GET", "/healthz") { |r| healthz(r) }
      Web.route(d, "GET", "/manifest.webmanifest") { |r| manifest(r) }
      Web.route(d, "GET", "/sw.js") { |r| service_worker(r) }
      Web.route(d, "GET", "/favicon.ico") { |r| favicon(r) }

      Web.route(d, "GET", "/wer") { |r| who_page(r) }
      Web.route(d, "POST", "/wer") { |r| who_select(r) }
      Web.route(d, "POST", "/wer/neu") { |r| who_create(r) }

      register_pages
    end

    # Pages of the core app (expenses.cr, balances.cr, activity.cr,
    # settings.cr reopen this class and add their routes here).
    def register_pages : Nil
      {% for m in @type.methods.select { |m| m.name.starts_with?("register_") && m.name != "register_pages" } %}
        {{ m.name.id }}
      {% end %}
    end

    def healthz(r : Request) : Nil
      begin
        @d.store.ping
      rescue ex
        return r.text_error(503, "db: #{ex.message}")
      end
      r.response.content_type = "text/plain; charset=utf-8"
      r.response.print "ok\n"
    end

    # --- who are you? ------------------------------------------------------------

    private def render_who(r : Request, status : Int32, return_to : String, name : String, error : String) : Nil
      participants = @d.store.list_participants(false)
      me = r.me?
      r.page(status, Page.new(title: "Wer bist du?", error: error)) do |__io__|
        Web.template __io__, "web/who.ecr"
      end
    end

    def who_page(r : Request) : Nil
      render_who(r, 200, Web.safe_return(r.query("zurueck")), "", "")
    end

    def who_select(r : Request) : Nil
      ret = Web.safe_return(r.form_value("zurueck"))
      id = r.form_value("id").to_i64? || 0_i64
      p = begin
        @d.store.get_participant(id)
      rescue Store::NotFound
        nil
      end
      if p.nil? || p.archived?
        return render_who(r, 422, ret, "", "Diese Person gibt es nicht (mehr).")
      end
      r.set_identity(p.id)
      r.redirect(ret)
    end

    def who_create(r : Request) : Nil
      ret = Web.safe_return(r.form_value("zurueck"))
      name = r.form_value("name")
      id = begin
        @d.store.join_as_participant(name)
      rescue ex : Domain::ValidationError
        return render_who(r, 422, ret, name, ex.message || "")
      end
      r.set_identity(id)
      r.set_flash("Willkommen!")
      r.redirect(ret)
    end
  end
end
