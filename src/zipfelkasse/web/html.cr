require "html"

module Zipfelkasse::Web
  struct SafeHTML
    getter html : String

    def initialize(@html : String)
    end

    def to_s(io : IO) : Nil
      io << @html
    end
  end

  module HTML
    def self.write(io : IO, value) : Nil
      case value
      when SafeHTML then value.to_s(io)
      when Nil      then nil
      else               ::HTML.escape(value.to_s, io)
      end
    end

    def self.escape(s : String) : String
      ::HTML.escape(s)
    end
  end

  # Expands the ECR template *path* (relative to src/views, e.g.
  # "web/home.ecr") at this place, writing to *io*. Local variables of the
  # caller are visible in the template. `<%= %>` escapes, `<%== %>` does not.
  macro template(io, path)
    \{{ run("{{__DIR__.id}}/ecr_process", "{{__DIR__.id}}/../../views/" + {{path}}, {{io.id.stringify}}) }}
  end
end
