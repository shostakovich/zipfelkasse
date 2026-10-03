require "kemal"

module Zipfelkasse::Web
  # Ends a request with an error page (or JSON, or plain text) and this
  # status; *status* needs an error handler (see Web.install_errors).
  class HTTPError < Kemal::Exceptions::CustomException
    def initialize(env : HTTP::Server::Context, status : Int32, message : String)
      env.response.status_code = status
      super(env, message)
    end
  end

  record ErrorText, page : String, api_text : String? = nil do
    def api : String
      api_text || page
    end
  end

  ERROR_TEXTS = {
    400 => ErrorText.new("Ungültige Anfrage."),
    401 => ErrorText.new("Bitte zuerst auswählen, wer du bist."),
    403 => ErrorText.new("Diese Anfrage kam von einer fremden Seite und wurde abgelehnt. Bitte lade die Seite neu und versuche es noch einmal.",
      "Anfrage von einer fremden Seite abgelehnt."),
    404 => ErrorText.new("Seite nicht gefunden."),
    405 => ErrorText.new("Diese Seite kennt die verwendete Methode nicht."),
    413 => ErrorText.new("Die gesendeten Daten sind zu groß. Bitte kürze die Eingaben und versuche es noch einmal."),
    500 => ErrorText.new("Da ist etwas schiefgegangen."),
  }

  record ErrorView, message : String do
    Web.view "web/error.ecr"
  end

  # Statuses that routes render themselves (422, 502, ...) must not be listed:
  # Kemal hands every response with a listed status to its error handler.
  ERROR_STATUSES = {400, 404, 405, 409, 413, 500}

  def self.install_errors(store : Store) : Nil
    ERROR_STATUSES.each do |status|
      error(status) do |env, ex|
        reject_body(env) if status == 413
        error_body(env, store, status, ex.as?(HTTPError).try(&.message))
      end
    end
  end

  # Closing while the client is still sending makes it see a connection reset
  # instead of the 413; reading (a bounded rest of) the body avoids that.
  private def self.reject_body(env : HTTP::Server::Context) : Nil
    request = env.request
    Log.warn(&.emit("request body too large", method: request.method, path: request.path))
    env.response.headers["Connection"] = "close"
    body = request.body || return
    buffer = Bytes.new(64 * 1024)
    left = 16 * MAX_BODY_BYTES
    while left > 0 && (read = body.read(buffer[0, Math.min(buffer.size, left)])) > 0
      left -= read
    end
  rescue IO::Error
  end

  def self.error_body(env : HTTP::Server::Context, store : Store, status : Int32, message : String? = nil) : String
    text = ERROR_TEXTS[status]? || ErrorText.new(HTTP::Status.new(status).description || "")
    path = env.request.path
    response = env.response
    response.status_code = status
    if path.starts_with?("/api/")
      response.content_type = "application/json; charset=utf-8"
      {error: message || text.api}.to_json
    elsif path.starts_with?("/mcp/")
      response.content_type = "text/plain; charset=utf-8"
      "#{HTTP::Status.new(status).description}\n"
    else
      message ||= text.page
      render_page(env, store, status, Page.new(message), ErrorView.new(message))
    end
  rescue ex
    Log.error(exception: ex) { "error page failed" }
    env.response.content_type = "text/plain; charset=utf-8"
    "#{message || "Da ist etwas schiefgegangen."}\n"
  end
end
