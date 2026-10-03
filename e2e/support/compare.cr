require "json"

module E2E
  # Equivalence of two answers to the same request.
  module Compare
    # Headers whose values must match exactly.
    HEADERS = %w(Location Cache-Control Content-Disposition Allow X-Content-Type-Options Referrer-Policy
      X-Frame-Options Content-Security-Policy Connection)

    def self.responses(a : Response, b : Response) : Array(String)
      diffs = [] of String
      diffs << "status: #{a.status} vs #{b.status}" if a.status != b.status
      HEADERS.each do |h|
        va, vb = a.headers[h]?, b.headers[h]?
        diffs << "header #{h}: #{va.inspect} vs #{vb.inspect}" if va != vb
      end
      ta, tb = media_type(a), media_type(b)
      diffs << "Content-Type: #{a.content_type.inspect} vs #{b.content_type.inspect}" if ta != tb
      ca, cb = cookies(a), cookies(b)
      diffs << "Set-Cookie: #{ca} vs #{cb}" if ca != cb
      ba, bb = body(a), body(b)
      diffs << "body:\n#{text_diff(ba, bb)}" if ba != bb
      diffs
    end

    private def self.media_type(r : Response) : String
      r.content_type.downcase.delete(' ')
    end

    private def self.cookies(r : Response) : Array(String)
      r.cookies.map do |c|
        attrs = [c.name, c.value, "Path=#{c.path}", "HttpOnly=#{c.http_only}", "Secure=#{c.secure}",
                 "SameSite=#{c.samesite}", "Max-Age=#{c.max_age.try(&.total_seconds.to_i)}"]
        attrs.join(";")
      end.sort
    end

    # Canonical body: DOM for HTML, structure for JSON, bytes otherwise.
    def self.body(r : Response) : String
      if r.html? && !r.body.empty?
        DOM.canonical(r.body)
      elsif r.json? && !r.body.empty?
        begin
          json(JSON.parse(r.body))
        rescue JSON::ParseException
          r.body
        end
      else
        r.body
      end
    end

    # JSON with sorted keys and integral floats written as integers; strings
    # holding JSON (MCP tool results) are canonicalised too.
    def self.json(v : JSON::Any) : String
      String.build { |io| write_json(v, io, 0) }
    end

    private def self.write_json(v : JSON::Any, io : IO, depth : Int32) : Nil
      ind = "  " * depth
      case raw = v.raw
      when Hash
        io << "{\n"
        raw.keys.sort.each do |k|
          io << ind << "  " << k.inspect << ": "
          write_json(raw[k], io, depth + 1)
          io << "\n"
        end
        io << ind << "}"
      when Array
        io << "[\n"
        raw.each do |e|
          io << ind << "  "
          write_json(e, io, depth + 1)
          io << "\n"
        end
        io << ind << "]"
      when Float64
        io << (raw == raw.round && raw.abs < 1e15 ? raw.to_i64.to_s : raw.to_s)
      when String
        if raw.starts_with?('{') || raw.starts_with?('[')
          begin
            io << "(json) "
            write_json(JSON.parse(raw), io, depth)
            return
          rescue JSON::ParseException
          end
        end
        io << raw.inspect
      else
        io << raw.inspect
      end
    end

    # The first differing lines of two texts, with a little context.
    def self.text_diff(a : String, b : String, context = 3, max = 12) : String
      la, lb = a.lines, b.lines
      i = 0
      while i < la.size && i < lb.size && la[i] == lb[i]
        i += 1
      end
      ja, jb = la.size - 1, lb.size - 1
      while ja >= i && jb >= i && la[ja] == lb[jb]
        ja -= 1
        jb -= 1
      end
      String.build do |io|
        io << "@@ line " << (i + 1) << "\n"
        (Math.max(0, i - context)...i).each { |k| io << "  " << la[k] << "\n" }
        (i..Math.min(ja, i + max - 1)).each { |k| io << "- " << la[k] << "\n" } if ja >= i
        io << "  … (#{ja - i - max + 1} more)\n" if ja - i + 1 > max
        (i..Math.min(jb, i + max - 1)).each { |k| io << "+ " << lb[k] << "\n" } if jb >= i
        io << "  … (#{jb - i - max + 1} more)\n" if jb - i + 1 > max
      end
    end
  end
end
