require "http/server"

class HTTP::Server::Context
  property! me : Zipfelkasse::Store::Participant

  def query(name : String) : String
    params.query[name]? || ""
  end

  def form(name : String) : String
    params.body[name]? || ""
  end

  def flash=(message : String) : String
    response.cookies << HTTP::Cookie.new(Zipfelkasse::Web::FLASH_COOKIE, URI.encode_www_form(message),
      path: "/", max_age: 60.seconds, http_only: true, samesite: HTTP::Cookie::SameSite::Lax)
    message
  end

  def take_flash : String?
    cookie = request.cookies[Zipfelkasse::Web::FLASH_COOKIE]? || return
    response.cookies << HTTP::Cookie.new(Zipfelkasse::Web::FLASH_COOKIE, "", path: "/", max_age: Time::Span.zero)
    URI.decode_www_form(cookie.value) if Zipfelkasse::Web.valid_escapes?(cookie.value)
  end

  def identify_as(participant_id : Int64) : Nil
    secure = request.headers["X-Forwarded-Proto"]? == "https"
    response.cookies << HTTP::Cookie.new(Zipfelkasse::Web::IDENTITY_COOKIE, participant_id.to_s,
      path: "/", max_age: 365.days, http_only: true, secure: secure, samesite: HTTP::Cookie::SameSite::Lax)
  end
end
