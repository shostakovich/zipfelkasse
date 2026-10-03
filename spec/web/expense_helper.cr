require "./web_helper"

# Fixed rates; unknown currencies raise.
class FakeFX
  include Zipfelkasse::Web::FXRater

  getter rates : Hash(String, Float64)

  def initialize(@rates = {} of String => Float64)
  end

  def rate(currency : String, date : Time) : Zipfelkasse::Domain::FXRate
    r = @rates[currency]? || raise "no rate"
    Zipfelkasse::Domain::FXRate.new(currency, date, r, Zipfelkasse::Domain::FXSource::Ecb)
  end
end

# Anna, Ben and Cleo plus the first seed category; Anna is logged in.
class ExpenseGroup
  getter srv : TestServer
  getter anna : Int64
  getter ben : Int64
  getter cleo : Int64
  getter food : Int64

  def initialize(@srv : TestServer, fx : Zipfelkasse::Web::FXRater)
    @srv.d.fx = fx
    @anna = must_participant(store, "Anna")
    @ben = must_participant(store, "Ben")
    @cleo = must_participant(store, "Cleo")
    @food = store.list_categories[0].id
  end

  def store : Zipfelkasse::Store
    @srv.store
  end

  def cookie : Hash(String, String)
    who_cookie(anna)
  end

  # Status and HTML-unescaped body.
  def get(path : String) : {Int32, String}
    res = @srv.get(path, cookie)
    {res.status_code, HTML.unescape(res.body)}
  end

  # Posts as Anna: status, Location and HTML-unescaped body.
  def post(path : String, form = URI::Params.new) : {Int32, String, String}
    res = @srv.post_form(path, form, cookie)
    {res.status_code, res.headers["Location"]? || "", HTML.unescape(res.body)}
  end

  # A valid form: Anna pays 30 € for everyone, split equally.
  def form : URI::Params
    v = URI::Params.new
    {"titel" => "Einkauf", "datum" => "2026-09-30", "kategorie" => food.to_s, "waehrung" => "EUR",
     "betrag" => "30,00", "bezahlt_von" => anna.to_s, "aufteilung" => "equal"}.each { |k, val| v[k] = val }
    [anna, ben, cleo].each { |id| v.add("teil", id.to_s) }
    v
  end

  def create(v : URI::Params) : Zipfelkasse::Store::Expense
    status, loc, body = post("/ausgaben/neu", v)
    fail "POST /ausgaben/neu: #{status} → #{loc.inspect}: #{error_of(body)}" unless status == 303 && loc == "/"
    store.list_expenses(Zipfelkasse::Store::ExpenseFilter.new(limit: 1)).first? || fail "no expense saved"
  end
end

def with_expense_group(fx : Zipfelkasse::Web::FXRater = FakeFX.new, &)
  with_server { |srv| yield ExpenseGroup.new(srv, fx) }
end

# The error message of a rendered page.
def error_of(body : String) : String
  _, sep, after = body.partition(%(role="alert">))
  sep.empty? ? "(no error message)" : after.partition('<')[0]
end

def shares_of(e : Zipfelkasse::Store::Expense) : Hash(Int64, Int64)
  e.shares.to_h { |s| {s.participant_id, s.amount_cents} }
end
