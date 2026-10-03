require "../spec_helper"

def new_test_store : Zipfelkasse::Store
  Zipfelkasse::Store.open(":memory:")
end

def with_store(&)
  s = new_test_store
  begin
    yield s
  ensure
    s.close
  end
end

def must_participant(s : Zipfelkasse::Store, name : String) : Int64
  s.create_participant(nil, name)
end

def date(s : String) : Time
  Time.parse(s, "%F", Time::Location::UTC)
end

# The message of the ValidationError the block raises.
def store_validation_error(&) : String
  yield
  fail "expected a ValidationError"
rescue ex : Zipfelkasse::Domain::ValidationError
  ex.message || ""
end
