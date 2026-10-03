def date(text : String) : Time
  Time.parse(text, "%F", Time::Location::UTC)
end

def with_temp_dir(&)
  dir = File.tempname("zipfelkasse-spec")
  Dir.mkdir_p(dir)
  begin
    yield dir
  ensure
    FileUtils.rm_rf(dir)
  end
end

# The block must raise a ValidationError with exactly this message.
def expect_invalid(message : String, & : ->) : Nil
  expect_raises(Domain::ValidationError) { yield }.message.should eq message
end

# Waits for something that fibers do in the background.
def eventually(timeout : Time::Span = 3.seconds, & : -> Bool) : Nil
  deadline = Time.instant + timeout
  until yield
    fail "condition not met within #{timeout}" if Time.instant > deadline
    sleep 1.millisecond
  end
end

# What the running example works with, set by `use_store` and `use_household`.
module Current
  class_property! store : Store
  class_property! household : Household
end

# Every example of the group gets a fresh in-memory `store`.
def use_store : Nil
  around_each do |example|
    Current.store = Store.open(":memory:")
    begin
      example.run
    ensure
      Current.store.close
    end
  end
end

def store : Store
  Current.store
end
