require "json"

module Zipfelkasse::GoCompat
  # Writes JSON the way Go's encoding/json does, so that rows and answers
  # written by the Go and the Crystal version are identical:
  #
  # * keys in the order they are written (Go structs: field order; for Go
  #   maps use `#map`, which sorts the keys),
  # * strings escaped like Go (`<`, `>`, `&` with `html: true`,
  #   U+2028/U+2029 always, control characters as `\n` or `\u001f`),
  # * floats like Go (`1`, `1.5`, `1e+21`).
  #
  #     GoCompat::JSON.build do |j|
  #       j.object { j.field "title", "Miete"; j.field "amount_cents", 145000 }
  #     end
  module JSON
    def self.build(html = true, & : Builder ->) : String
      String.build do |io|
        yield Builder.new(io, html)
      end
    end

    # Encoder output with a trailing newline (Go's json.NewEncoder(w).Encode).
    def self.encode(io : IO, html = true, & : Builder ->) : Nil
      yield Builder.new(io, html)
      io << '\n'
    end

    class Builder
      getter io : IO

      def initialize(@io : IO, @html : Bool = true)
        @first = [true]
      end

      def object(&) : Nil
        separate
        @io << '{'
        @first << true
        yield
        @first.pop
        @io << '}'
      end

      def array(&) : Nil
        separate
        @io << '['
        @first << true
        yield
        @first.pop
        @io << ']'
      end

      # A key with a value (or with a block that writes the value).
      def field(key : String, value) : Nil
        key(key)
        value(value)
      end

      def field(key : String, &) : Nil
        key(key)
        yield
      end

      def key(key : String) : Nil
        separate
        GoCompat::JSON.string(@io, key, @html)
        @io << ':'
        @first[-1] = true # the value follows without a comma
      end

      def value(v : String) : Nil
        separate
        GoCompat::JSON.string(@io, v, @html)
      end

      def value(v : Bool) : Nil
        separate
        @io << v
      end

      def value(v : Nil) : Nil
        separate
        @io << "null"
      end

      def value(v : Int) : Nil
        separate
        @io << v
      end

      def value(v : Float) : Nil
        separate
        @io << GoCompat.json_float(v.to_f64)
      end

      def value(v : Array | Tuple) : Nil
        array { v.each { |e| value(e) } }
      end

      # A Go map: keys sorted (byte order).
      def value(v : Hash) : Nil
        map(v)
      end

      def map(h : Hash(String, _)) : Nil
        object do
          h.keys.sort!.each { |k| field(k, h[k]) }
        end
      end

      def value(v : ::JSON::Any) : Nil
        case raw = v.raw
        when Hash  then object { raw.each { |k, e| field(k, e) } }
        when Array then array { raw.each { |e| value(e) } }
        else            value(raw)
        end
      end

      # Already encoded JSON, written as is.
      def raw(json : String) : Nil
        separate
        @io << json
      end

      private def separate : Nil
        if @first[-1]
          @first[-1] = false
        else
          @io << ','
        end
      end
    end

    HEX = "0123456789abcdef"

    # A JSON string literal exactly like Go's encoding/json.
    def self.string(io : IO, s : String, html = true) : Nil
      io << '"'
      reader = Char::Reader.new(s)
      while reader.has_next?
        c = reader.current_char
        invalid = !reader.error.nil?
        reader.next_char
        if invalid
          io << "\\ufffd"
          next
        end
        case c
        when '"'  then io << "\\\""
        when '\\' then io << "\\\\"
        when '\n' then io << "\\n"
        when '\r' then io << "\\r"
        when '\t' then io << "\\t"
        when '\b' then io << "\\b"
        when '\f' then io << "\\f"
        when '<', '>', '&'
          if html
            io << "\\u00" << HEX[c.ord >> 4] << HEX[c.ord & 0xf]
          else
            io << c
          end
        when ' ' then io << "\\u2028"
        when ' ' then io << "\\u2029"
        else
          if c.ord < 0x20
            io << "\\u00" << HEX[c.ord >> 4] << HEX[c.ord & 0xf]
          else
            io << c
          end
        end
      end
      io << '"'
    end

    def self.string(s : String, html = true) : String
      String.build { |io| string(io, s, html) }
    end
  end
end
