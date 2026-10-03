require "html"

module Zipfelkasse::Web
  # HTML that is already safe and is written without escaping (e.g. the
  # output of the `icon` helper or a rendered partial).
  struct SafeHTML
    getter html : String

    def initialize(@html : String)
    end

    def to_s(io : IO) : Nil
      io << @html
    end
  end

  module HTML
    # Writes a template value: escaped, unless it is SafeHTML. nil writes
    # nothing (like a missing value in a Go template).
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
