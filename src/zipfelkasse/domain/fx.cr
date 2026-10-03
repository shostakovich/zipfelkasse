require "json"

module Zipfelkasse::Domain
  # The strings in the database are ezb, manuell and fest.
  enum FXSource
    Ecb
    Manual
    Fixed # EUR itself, rate 1

    def key : String
      case self
      in .ecb?    then "ezb"
      in .manual? then "manuell"
      in .fixed?  then "fest"
      end
    end

    def self.from_key?(key : String) : FXSource?
      values.find { |source| source.key == key }
    end

    def to_json(json : JSON::Builder) : Nil
      json.string(key)
    end

    def self.new(pull : JSON::PullParser) : FXSource
      key = pull.read_string
      from_key?(key) || raise JSON::ParseException.new("Unknown FX source #{key.inspect}", *pull.location)
    end
  end

  record FXRate,
    currency : String,
    date : Time,
    rate : Float64, # foreign currency per 1 EUR
    source : FXSource
end
