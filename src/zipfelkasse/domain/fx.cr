module Zipfelkasse::Domain
  # `date` is the day the rate applies to (for ECB rates possibly the last
  # banking day before the requested date).
  record FXRate,
    currency : String, # ISO 4217, upper case
    date : Time,       # calendar date (00:00 UTC)
    rate : Float64,    # foreign currency per 1 EUR
    source : String    # FX_SOURCE_ECB, FX_SOURCE_MANUAL, FX_SOURCE_FIXED

  FX_SOURCE_ECB    = "ezb"     # ECB reference rate
  FX_SOURCE_MANUAL = "manuell" # entered/overridden by hand
  FX_SOURCE_FIXED  = "fest"    # EUR itself, rate 1
end
