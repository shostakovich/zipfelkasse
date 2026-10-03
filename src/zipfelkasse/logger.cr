module Zipfelkasse
  # A small structured logger writing lines like Go's slog TextHandler:
  #
  #     time=2026-10-03T08:13:21.123+02:00 level=INFO msg="Zipfelkasse running" addr=:8080
  #
  # Attributes keep the order in which they are given.
  class Logger
    enum Level
      Debug
      Info
      Warn
      Error
    end

    getter io : IO
    property level : Level

    def initialize(@io : IO = STDERR, @level = Level::Info, @location : Time::Location = Time::Location.local)
    end

    def debug(msg : String, **attrs) : Nil
      log(Level::Debug, msg, attrs)
    end

    def info(msg : String, **attrs) : Nil
      log(Level::Info, msg, attrs)
    end

    def warn(msg : String, **attrs) : Nil
      log(Level::Warn, msg, attrs)
    end

    def error(msg : String, **attrs) : Nil
      log(Level::Error, msg, attrs)
    end

    def log(level : Level, msg : String, attrs) : Nil
      return if level < @level
      line = String.build do |s|
        s << "time=" << Time.local(@location).to_s("%Y-%m-%dT%H:%M:%S.%L%:z")
        s << " level=" << level.to_s.upcase
        s << " msg="
        Logger.value(s, msg)
        attrs.each do |k, v|
          s << ' ' << k << '='
          Logger.value(s, v)
        end
        s << '\n'
      end
      @io << line
      @io.flush
    end

    # Writes a value, quoted like slog when it needs quoting.
    def self.value(io : IO, v) : Nil
      text = case v
             when Exception    then v.message || v.class.name
             when Time::Span   then "#{v.total_milliseconds.round.to_i}ms"
             when Array, Tuple then "[#{v.join(' ')}]"
             else                   v.to_s
             end
      if needs_quoting?(text)
        text.inspect(io)
      else
        io << text
      end
    end

    private def self.needs_quoting?(s : String) : Bool
      return true if s.empty?
      s.each_char.any? { |c| c == ' ' || c == '"' || c == '=' || c.ord < 0x20 || c == '\u007f' || c == Char::REPLACEMENT || !c.printable? }
    end
  end
end
