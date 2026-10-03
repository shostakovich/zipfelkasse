module Zipfelkasse::Web
  record Page,
    title : String = "",                   # page title (without the group name)
    nav : String = "",                     # active tab, see the NAV_* constants; "" = none
    error : String = "",                   # error message at the top (e.g. validation error)
    scripts : Array(String) = [] of String # extra static scripts before </body>, e.g. "expense-form.js"

  class_property location : Time::Location = Time::Location.local

  # Include this module where templates are expanded.
  module Helpers
    def eur(cents : Int64) : String
      Domain.format_cents(cents)
    end

    def money(minor : Int64, currency : String) : String
      Domain.format_money(minor, currency)
    end

    def date(t : Time?) : String
      t ? Domain.format_date(t) : ""
    end

    def iso_date(t : Time?) : String
      t ? t.to_s("%Y-%m-%d") : ""
    end

    def date_time(t : Time?) : String
      t ? t.in(Web.location).to_s("%d.%m.%Y, %H:%M") : ""
    end

    def sign_class(v : Int64) : String
      v > 0 ? "positive" : (v < 0 ? "negative" : "")
    end

    def static(name : String) : String
      Static.url(name)
    end

    def icon(name : String) : SafeHTML
      SafeHTML.new(%(<svg class="icon" aria-hidden="true"><use href="#{::HTML.escape(Static.url("icons.svg") + "#" + name)}"></use></svg>))
    end

    def category_icon(name : String) : String
      Web.category_icon(name)
    end
  end

  class Renderer
    include Helpers

    def initialize(@store : Store)
    end

    # Not IO: a block arg restricted wider than the yielded type crashes Crystal 1.21.1 when read two blocks deep.
    def page(req : Request, status : Int32, page : Page, & : String::Builder ->) : Nil
      content = String.build { |io| yield io }
      me = req.me?
      group_name = @store.group_name
      flash = req.take_flash
      html = String.build do |__io__|
        Web.template __io__, "layout.ecr"
      end
      res = req.response
      res.headers["Content-Type"] = "text/html; charset=utf-8"
      res.headers["Cache-Control"] = "no-store"
      res.status_code = status
      res.print html
    end

    def error(req : Request, status : Int32, message : String) : Nil
      page = Page.new(title: message)
      page(req, status, page) do |__io__|
        Web.template __io__, "web/error.ecr"
      end
    end
  end
end
