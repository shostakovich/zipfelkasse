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
    extend self

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
      t.try &.to_local.to_s("%d.%m.%Y, %H:%M") || ""
    end

    def expense_count(n : Int) : String
      n == 1 ? "1 Ausgabe" : "#{n} Ausgaben"
    end

    def sign_class(v : Int64) : String
      v > 0 ? "text-success" : (v < 0 ? "text-danger" : "")
    end

    def static(name : String) : String
      Static.url(name)
    end

    # Names in the order of the plush sprite sheets (static/plush/icons-<look>-<theme>.webp).
    PLUSH = %w(receipt scale activity settings users tag repeat banknote archive
      cart utensils key zap home car plane ticket heart
      gift shirt baby paw graduation phone shield piggy wallet)

    # A felt or plush icon from the sprite of the current look and colour mode (see app.css).
    def plush(name : String) : SafeHTML
      name = "tag" unless PLUSH.includes?(name)
      SafeHTML.new(%(<span class="plush plush-#{name}" aria-hidden="true"></span>))
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

  macro template(io, path)
    \{{ run("{{__DIR__.id}}/ecr_process", "{{__DIR__.id}}/../../views/" + {{path}}, {{io.id.stringify}}) }}
  end

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

  record Layout, page : Page, content : View, me : Store::Participant?, group_name : String, flash : String?,
    look : Look, theme : Theme do
    include Helpers

    # Browser chrome colour per colour mode: the page colour of the look.
    def theme_color(dark : Bool) : String
      if dark
        look.felt? ? "#26292d" : "#212529"
      else
        look.felt? ? "#ece4d4" : "#f6f7f9"
      end
    end

    # A static image in a light and a dark version (`name-light.ext`, `name-dark.ext`):
    # the pinned one, or both with the system choosing.
    def themed_srcs(base : String, ext : String) : {String, String?}
      return {static("#{base}-#{theme.to_s.downcase}.#{ext}"), nil} unless theme.auto?
      {static("#{base}-light.#{ext}"), static("#{base}-dark.#{ext}")}
    end

    def to_s(io : IO) : Nil
      Web.template io, "layout.ecr"
    end
  end

  def self.render_page(env : HTTP::Server::Context, store : Store, status : Int32, page : Page, content : View,
                       group_name : String = store.group_name) : String
    html = Layout.new(page, content, env.me?, group_name, env.take_flash, env.look, env.theme).to_s
    response = env.response
    response.status_code = status
    response.content_type = "text/html; charset=utf-8"
    response.headers["Cache-Control"] = "no-store"
    response.content_length = html.bytesize
    html
  end
end
