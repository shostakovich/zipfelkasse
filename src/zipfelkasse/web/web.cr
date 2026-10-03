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

  module FXRater
    abstract def rate(currency : String, date : Time) : Domain::FXRate
  end

  class Deps
    getter config : Config
    getter store : Store
    property! fx : FXRater

    delegate today, now, to: @config

    def initialize(@config, @store)
    end
  end

  class_property location : Time::Location = Time::Location.local

  def self.positive_id?(value : String?, trim = false) : Int64?
    id = (trim ? value.try(&.strip) : value).try(&.to_i64?(whitespace: false))
    id if id && id > 0
  end

  def self.text_error(ctx : HTTP::Server::Context, status : Int32, message : String) : Nil
    ctx.response.status_code = status
    ctx.response.content_type = "text/plain; charset=utf-8"
    ctx.response.headers["X-Content-Type-Options"] = "nosniff"
    ctx.response.print message, '\n'
  end

  # Only local paths are allowed as a return target. Rejected are control
  # characters and backslashes (browsers strip tabs/newlines or read "\" as
  # "/", so "/\t/evil" would become "//evil"), anything with a scheme or
  # host, paths that start with "//" (even only after decoding) and broken
  # escapes in the path or fragment.
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
