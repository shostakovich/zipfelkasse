require "base64"
require "uri"

module Zipfelkasse::Web
  Log = ::Log.for(self)

  IDENTITY_COOKIE = "wer"
  FLASH_COOKIE    = "flash"

  MAX_BODY_BYTES = 1 << 20

  enum Nav
    Expenses
    Balances
    Activity
    Settings
  end

  # The felt-css look and colour mode, chosen per person.
  enum Look
    Clean
    Felt
  end

  enum Theme
    Auto
    Light
    Dark
  end

  class Deps
    getter config : Config
    getter store : Store
    property! fx : FX::Service

    delegate today, now, to: @config

    def initialize(@config, @store)
    end
  end

  def self.positive_id?(value : String?, trim = false) : Int64?
    id = (trim ? value.try(&.strip) : value).try(&.to_i64?(whitespace: false))
    id if id && id > 0
  end

  # Only local paths: browsers strip tabs and read "\" as "/", so "/\t/evil"
  # would become "//evil"; "//" is refused even after decoding.
  def self.safe_return(target : String) : String
    return "/" if target.each_char.any? { |c| unsafe_char?(c) }
    return "/" unless target.starts_with?('/') && !target.starts_with?("//")
    rest, _, fragment = target.partition('#')
    path = rest.partition('?')[0]
    return "/" unless valid_escapes?(path) && valid_escapes?(fragment)
    decoded = URI.decode(path)
    return "/" if decoded.starts_with?("//") || decoded.starts_with?("/wer") || decoded.each_char.any? { |c| unsafe_char?(c) }
    target
  end

  private def self.unsafe_char?(c : Char) : Bool
    c == '\\' || c.control?
  end

  def self.valid_escapes?(s : String) : Bool
    s.split('%').skip(1).all? { |e| e.size >= 2 && e[0].hex? && e[1].hex? }
  end
end
