module Zipfelkasse::Web
  # A page to render in the layout.
  record Page,
    title : String = "",                # page title (without the group name)
    nav : String = "",                  # active tab, see the NAV_* constants; "" = none
    error : String = "",                # error message at the top (e.g. validation error)
    scripts : Array(String) = [] of String # extra static scripts before </body>, e.g. "expense-form.js"

  class_property location : Time::Location = Time::Location.local

  # The functions templates use (Go's FuncMap). Include this module where
  # templates are expanded.
  module Helpers
    # int64 cents → "1.234,56 €"
    def eur(cents : Int64) : String
      Domain.format_cents(cents)
    end

    # int64 cents → "1234,56" (for <input>)
    def amount_input(cents : Int64) : String
      Domain.format_cents_input(cents)
    end

    # (minor, "USD") → "12,34 USD"
    def money(minor : Int64, currency : String) : String
      Domain.format_money(minor, currency)
    end

    def percent(basis_points : Int64) : String
      Domain.format_basis_points(basis_points)
    end

    # date → "02.10.2026" ("" for nil)
    def date(t : Time?) : String
      t ? Domain.format_date(t) : ""
    end

    # date → "2026-10-02" (for <input type=date>)
    def iso_date(t : Time?) : String
      t ? t.to_s("%Y-%m-%d") : ""
    end

    # timestamp in local time → "03.10.2026, 12:00"
    def date_time(t : Time?) : String
      t ? t.in(Web.location).to_s("%d.%m.%Y, %H:%M") : ""
    end

    # for balances: "positive" / "negative" / ""
    def sign_class(v : Int64) : String
      v > 0 ? "positive" : (v < 0 ? "negative" : "")
    end

    # "app.css" → "/static/app.css?v=…"
    def static(name : String) : String
      Static.url(name)
    end

    # An icon from static/icons.svg, e.g. <%= icon "plus" %>.
    def icon(name : String) : SafeHTML
      SafeHTML.new(%(<svg class="icon" aria-hidden="true"><use href="#{::HTML.escape(Static.url("icons.svg") + "#" + name)}"></use></svg>))
    end

    # category name → icon name for icon()
    def category_icon(name : String) : String
      Web.category_icon(name)
    end

    # (minor, "USD") → "12,34" (for <input>)
    def minor_input(minor : Int64, currency : String) : String
      Domain.format_minor_input(minor, currency)
    end

    # rate 1.0876 → "1,0876" (for <input>)
    def rate_input(rate : Float64) : String
      Domain.format_rate(rate)
    end
  end

  # Renders pages in the shared layout.
  class Renderer
    include Helpers

    def initialize(@store : Store)
    end

    # Renders the page content (the block writes it, usually with
    # Web.template) inside the layout and sends it with status.
    def page(req : Request, status : Int32, page : Page, & : IO ->) : Nil
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

    # The error page (e.g. 404 "Ausgabe nicht gefunden.").
    def error(req : Request, status : Int32, message : String) : Nil
      page = Page.new(title: message)
      page(req, status, page) do |__io__|
        Web.template __io__, "web/error.ecr"
      end
    end
  end
end
