require "log"

module Zipfelkasse
  Log = ::Log.for(self)

  struct LogFormat < ::Log::StaticFormatter
    def run
      @io << "time="
      @entry.timestamp.to_s(@io, "%Y-%m-%dT%H:%M:%S.%L%:z")
      @io << " level=" << @entry.severity.label << " msg="
      value(@entry.message)
      @entry.data.each do |key, v|
        @io << ' ' << key << '='
        value(v.raw)
      end
      if ex = @entry.exception
        @io << " err="
        value(ex.message || ex.class.name)
      end
    end

    private def value(v) : Nil
      case v
      when Array
        @io << '['
        v.each_with_index do |item, i|
          @io << ' ' if i > 0
          value(item.is_a?(::Log::Metadata::Value) ? item.raw : item)
        end
        @io << ']'
      else
        text = v.to_s
        needs_quoting?(text) ? text.inspect(@io) : @io << text
      end
    end

    private def needs_quoting?(s : String) : Bool
      s.empty? || s.each_char.any? { |c| c == ' ' || c == '"' || c == '=' || c == Char::REPLACEMENT || !c.printable? }
    end
  end

  def self.setup_logging(io : IO = STDERR) : Nil
    backend = ::Log::IOBackend.new(io, formatter: LogFormat, dispatcher: ::Log::DispatchMode::Sync)
    ::Log.setup do |config|
      config.bind "*", :info, backend
      config.bind "kemal", :warn, backend
    end
  end
end
