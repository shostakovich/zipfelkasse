# Fixed ECB rates by currency. Without a rate for a currency it raises the
# ValidationError of an unknown currency; `failure` is raised instead of any
# rate (ECB not reachable); `on_call` runs on every call (e.g. to change a
# rule meanwhile).
class FakeFX < Zipfelkasse::FX::Service
  getter rates : Hash(String, Float64)
  getter calls = [] of Time
  property failure : Exception? = nil
  property on_call : Proc(Nil)? = nil

  def initialize(deps : Zipfelkasse::Web::Deps, @rates = {} of String => Float64)
    super(deps)
  end

  def rate(currency : String, date : Time) : Zipfelkasse::Domain::FXRate
    calls << date
    on_call.try &.call
    failure.try { |ex| raise ex }
    rate = rates[currency]? || raise Zipfelkasse::Domain::ValidationError.new("Für #{currency} gibt es keinen EZB-Kurs.")
    Zipfelkasse::Domain::FXRate.new(currency, date, rate, Zipfelkasse::Domain::FXSource::Ecb)
  end
end
