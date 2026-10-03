# Recurring expenses: a rule is always created from an existing expense,
# which is the template and the first instance; its date is the anchor from
# which all occurrences are computed (Domain.next_date).
module Zipfelkasse::Recurring
  Log = ::Log.for(self)

  # Occurrences created per rule and run (e.g. for a very old start date);
  # the hourly runs catch up on the rest.
  MAX_INSTANCES_PER_RUN = 400

  # Raised by materialize when rules failed; created counts the instances
  # that were created nevertheless.
  class Error < Exception
    getter created : Int32

    def initialize(message : String, @created : Int32)
      super(message)
    end
  end

  class Service
    include Web::Helpers

    getter d : Web::Deps
    @mutex = Mutex.new

    def initialize(@d : Web::Deps)
    end

    def today : Time
      @d.today
    end

    # Creates all instances due up to and including today (at most
    # MAX_INSTANCES_PER_RUN per rule) and returns their count. Repeated calls
    # create no duplicates; occurrences for which an equal expense exists are
    # skipped. A failing rule does not stop the others; their errors are
    # raised together afterwards.
    def materialize(today : Time, stopper : Stopper? = nil) : Int32
      @mutex.synchronize do
        today = Domain.date_of(today)
        n = 0
        errors = [] of String
        @d.store.due_recurring(today).each do |r|
          k, err = catch_up(r, today)
          n += k
          errors << Service.rule_error(r, err) if err
          break if stopper.try(&.stopped?)
        end
        raise Error.new(errors.join('\n'), n) unless errors.empty?
        n
      end
    end

    # materialize for one rule only (right after it was created or resumed);
    # other due rules are left to the next run. Unknown, paused or not yet due
    # rules create nothing.
    def materialize_rule(id : Int64, today : Time) : Int32
      @mutex.synchronize do
        today = Domain.date_of(today)
        r = begin
          @d.store.get_recurring(id)
        rescue Store::NotFound
          return 0
        end
        return 0 if !r.active? || r.next_date > today
        n, err = catch_up(r, today)
        raise Error.new(Service.rule_error(r, err), n) if err
        n
      end
    end

    protected def self.rule_error(r : Store::Recurring, err : Exception) : String
      "recurring rule #{r.id} (#{r.template.title.inspect}): #{err.message}"
    end

    # A failed occurrence leaves next_date where it is, so the next run
    # retries it.
    private def catch_up(r : Store::Recurring, today : Time) : {Int32, Exception?}
      return {0, Exception.new("unknown frequency #{r.frequency.value.inspect}")} unless r.frequency.valid?
      n = 0
      begin
        existing = @d.store.expense_dates_like(r.template, r.next_date, today)
        d = r.next_date
        i = 0
        while d <= today
          if i == MAX_INSTANCES_PER_RUN
            Log.info(&.emit("recurring expenses: per-run limit reached, the rest follows in the next run", rule: r.id, next_date: Store.format_date(d), limit: MAX_INSTANCES_PER_RUN))
            break
          end
          n += 1 if create_occurrence(r, d, existing.includes?(d))
          next_date = Domain.next_date(r.frequency, r.start_date, d)
          @d.store.set_recurring_next_date(r.id, d, next_date)
          d = next_date
          i += 1
        end
      rescue Store::RecurringChanged
        # Paused, deleted or resumed meanwhile (r is a snapshot): that change wins.
        Log.info(&.emit("recurring expenses: rule changed meanwhile, stopping its catch-up", rule: r.id))
      rescue ex
        return {n, ex}
      end
      {n, nil}
    end

    # exists: an equal expense was entered by hand or by a deleted rule.
    private def create_occurrence(r : Store::Recurring, d : Time, exists : Bool) : Bool
      if exists
        Log.info(&.emit("recurring expense: an equal expense already exists, skipping the occurrence", rule: r.id, date: Store.format_date(d)))
        return false
      end
      @d.store.create_expense(0_i64, instance(r, d))
      true
    rescue Store::RecurringExists # e.g. after a crash before next_date advanced
      false
    end

    # A foreign currency gets the rate of the occurrence date. If that rate is
    # only temporarily unavailable (ECB down, database), the occurrence fails
    # and is retried in the next run rather than stored with a stale rate. If
    # no rate exists for the date at all (ValidationError), the template's
    # rate is kept: waiting would block the rule forever.
    private def instance(r : Store::Recurring, date : Time) : Store::ExpenseInput
      input = r.template
      input.parts = input.parts.dup
      input.date = date
      input.recurring_id = r.id
      cur = input.original_currency
      fx = @d.fx
      return input if Domain.eur?(cur) || fx.nil?
      rate = begin
        fx.rate(cur, date)
      rescue ex : Domain::ValidationError
        Log.warn(exception: ex, &.emit("recurring expense: no rate for the date, using the template's rate", rule: r.id, currency: cur, date: Store.format_date(date)))
        return input
      rescue ex
        raise Exception.new("rate for #{cur} on #{Store.format_date(date)} not available, retrying in the next run: #{ex.message}", cause: ex)
      end
      amount = Domain.to_eur_cents(input.original_amount_minor, cur, rate.rate)
      return input if amount <= 0 || amount > Domain::MAX_AMOUNT_CENTS
      # For SPLIT_AMOUNT the weights stay amounts in cur; the store
      # distributes the converted amount in proportion to them.
      input.amount_cents = amount
      input.fx_rate = rate.rate
      input.fx_source = rate.source
      input
    end

    # Materializes right away and then on a fixed tick every hour from the
    # start until the stopper fires.
    def run(stopper : Stopper, every : Time::Span = 1.hour) : Nil
      tick = Time.instant + every
      loop do
        begin
          n = materialize(today, stopper)
          Log.info(&.emit("recurring expenses created", count: n)) if n > 0
        rescue ex
          Log.error(exception: ex) { "recurring expenses" } unless stopper.stopped?
        end
        # A run that overran a tick starts the next one right away; further
        # missed ticks are dropped.
        return unless stopper.wait(tick - Time.instant)
        until tick > Time.instant
          tick += every
        end
      end
    end
  end
end

module Zipfelkasse
  class App
    def self.wire_recurring(app : App, d : Web::Deps, mcp : Web::MCPMount) : Nil
      service = Recurring::Service.new(d)
      service.register
      app.jobs << ->(s : Stopper) { service.run(s) }
    end
  end
end
