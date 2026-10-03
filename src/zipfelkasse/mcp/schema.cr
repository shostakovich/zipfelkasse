require "json"

module Zipfelkasse::MCP
  class Prop
    include JSON::Serializable

    getter type : String | Array(String) | Nil
    getter description : String?
    @[JSON::Field(key: "enum")]
    getter choices : Array(String)?
    getter items : Prop?
    getter minimum : Int32?
    getter maximum : Int32?
    @[JSON::Field(key: "exclusiveMinimum")]
    getter exclusive_minimum : Int32?
    @[JSON::Field(key: "additionalProperties")]
    getter additional : Prop?
    @[JSON::Field(key: "anyOf")]
    getter any_of : Array(Prop)?

    def initialize(@type = nil, @description = nil, @choices = nil, @items = nil, @minimum = nil, @maximum = nil,
                   @exclusive_minimum = nil, @additional = nil, @any_of = nil)
    end
  end

  module Schema
    extend self

    def text(description : String) : Prop
      Prop.new("string", description)
    end

    def date(description : String) : Prop
      text(description + " Format YYYY-MM-DD (DD.MM.YYYY is accepted too).")
    end

    def choice(type : T.class, description : String) : Prop forall T
      Prop.new("string", description, choices: type.values.map(&.to_s.underscore))
    end

    def integer(description : String, minimum : Int32? = nil, maximum : Int32? = nil) : Prop
      Prop.new("integer", description, minimum: minimum, maximum: maximum)
    end

    def limit(description : String) : Prop
      integer(description, 1, SQLSandbox::MAX_ROWS)
    end

    def number(description : String, minimum : Int32? = nil, exclusive_minimum : Int32? = nil) : Prop
      Prop.new("number", description, minimum: minimum, exclusive_minimum: exclusive_minimum)
    end

    def flag(description : String) : Prop
      Prop.new("boolean", description)
    end

    def list_of_text(description : String) : Prop
      Prop.new("array", description, items: Prop.new("string"))
    end

    def text_or_list(description : String) : Prop
      Prop.new(description: description, any_of: [Prop.new("string"), Prop.new("array", items: Prop.new("string"))])
    end

    def text_or_number(description : String? = nil) : Prop
      Prop.new(["string", "number"], description)
    end

    def map_of_text_or_number(description : String) : Prop
      Prop.new("object", description, additional: text_or_number)
    end
  end

  struct ObjectSchema
    include JSON::Serializable

    getter type = "object"
    getter properties : Hash(String, Prop)
    @[JSON::Field(key: "additionalProperties")]
    getter additional_properties = false
    getter required : Array(String)?

    def initialize(@properties = {} of String => Prop, @required = nil)
    end
  end

  struct Annotations
    include JSON::Serializable

    @[JSON::Field(key: "readOnlyHint")]
    getter read_only : Bool
    @[JSON::Field(key: "destructiveHint")]
    getter destructive = false
    @[JSON::Field(key: "idempotentHint")]
    getter idempotent : Bool
    @[JSON::Field(key: "openWorldHint")]
    getter open_world = false

    def initialize(*, @read_only, @idempotent)
    end
  end

  READ_ONLY = Annotations.new(read_only: true, idempotent: true)

  WRITE = Annotations.new(read_only: false, idempotent: false)

  struct ToolDefinition
    include JSON::Serializable

    getter name : String
    getter title : String
    getter description : String
    @[JSON::Field(key: "inputSchema")]
    getter input_schema : ObjectSchema
    getter annotations : Annotations

    def initialize(@name, @title, @description, @input_schema, @annotations)
    end
  end
end
