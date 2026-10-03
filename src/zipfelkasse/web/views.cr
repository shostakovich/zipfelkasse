require "html"

module Zipfelkasse::Web
  struct SafeHTML
    def initialize(@html : String)
    end

    def to_s(io : IO) : Nil
      io << @html
    end
  end

  module HTML
    def self.write(io : IO, value) : Nil
      case value
      when SafeHTML, View then value.to_s(io)
      when Nil            then nil
      else                     ::HTML.escape(value.to_s, io)
      end
    end
  end

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

    def category_icon(name : String?) : String
      Web.category_icon(name || "")
    end
  end

  # A template with the records's fields as its only data. `<%= %>` escapes,
  # `<%== %>` does not, and other views are written as they are.
  module View
    include Helpers
  end

  # Expands the ECR template *path* (relative to src/views, e.g.
  # "web/home.ecr") at this place, writing to *io*.
  macro template(io, path)
    \{{ run("{{__DIR__.id}}/ecr_process", "{{__DIR__.id}}/../../views/" + {{path}}, {{io.id.stringify}}) }}
  end

  # Defines `to_s` of a view record from its template.
  macro view(path)
    include ::Zipfelkasse::Web::View

    def to_s(io : IO) : Nil
      ::Zipfelkasse::Web.template io, {{path}}
    end
  end

  record Page,
    title : String,
    nav : Nav? = nil,
    error : String? = nil,
    scripts : Array(String) = [] of String

  # Not a View itself: it holds one.
  record Layout, page : Page, content : View, me : Store::Participant?, group_name : String, flash : String? do
    include Helpers

    def to_s(io : IO) : Nil
      Web.template io, "layout.ecr"
    end
  end

  def self.render_page(env : HTTP::Server::Context, store : Store, status : Int32, page : Page, content : View) : String
    html = Layout.new(page, content, env.me?, store.group_name, env.take_flash).to_s
    response = env.response
    response.status_code = status
    response.content_type = "text/html; charset=utf-8"
    response.headers["Cache-Control"] = "no-store"
    response.content_length = html.bytesize
    html
  end
end
