# A rule is created from an expense, its template and first instance.
module Zipfelkasse::Recurring
  Log = ::Log.for(self)

  MAX_MISSED_COUNT = 1000

  # Per rule and run; the hourly runs catch up on the rest.
  MAX_INSTANCES_PER_RUN = 400

  class Error < Exception
    getter created : Int32

    def initialize(message : String, @created : Int32)
      super(message)
    end
  end

  # missed counts up to MAX_MISSED_COUNT + 1; existing ones would be skipped.
  record Preview, frequency : Domain::Frequency, next_date : Time, missed : Int32, existing : Int32

  class Service
    getter d : Web::Deps
    @mutex = Mutex.new

    def initialize(@d : Web::Deps)
    end

    # A failing rule does not stop the others; their errors are raised together.
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

    def previews(expense : Store::Expense) : Array(Preview)
      today = @d.today
      existing = Set(Time).new
      if expense.date < today
        existing = @d.store.expense_dates_like(expense.to_input, expense.date.shift(days: 1), today)
      end
      Domain::Frequency.values.map do |frequency|
        first = Domain.next_date(frequency, expense.date, expense.date)
        missed = skipped = 0
        date = first
        while date <= today && missed <= MAX_MISSED_COUNT
          missed += 1
          skipped += 1 if existing.includes?(date)
          date = Domain.next_date(frequency, expense.date, date)
        end
        Preview.new(frequency, first, missed, skipped)
      end
    end

    protected def self.rule_error(r : Store::Recurring, err : Exception) : String
      "recurring rule #{r.id} (#{r.template.title.inspect}): #{err.message}"
    end

    # A failed occurrence leaves next_date where it is, so the next run
    # retries it.
    private def catch_up(r : Store::Recurring, today : Time) : {Int32, Exception?}
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

    private def create_occurrence(r : Store::Recurring, d : Time, exists : Bool) : Bool
      if exists
        Log.info(&.emit("recurring expense: an equal expense already exists, skipping the occurrence", rule: r.id, date: Store.format_date(d)))
        return false
      end
      @d.store.create_expense(nil, instance(r, d))
      true
    rescue Store::RecurringExists # e.g. after a crash before next_date advanced
      false
    end

    # The rate of the occurrence date. Temporarily unavailable, the occurrence
    # is retried next run; missing for good, the template's rate is kept.
    private def instance(r : Store::Recurring, date : Time) : Store::ExpenseInput
      input = r.template
      input.date = date
      input.recurring_id = r.id
      cur = input.original_currency
      return input if Domain.eur?(cur)
      rate = begin
        @d.fx.rate(cur, date)
      rescue ex : Domain::ValidationError
        Log.warn(exception: ex, &.emit("recurring expense: no rate for the date, using the template's rate", rule: r.id, currency: cur, date: Store.format_date(date)))
        return input
      rescue ex
        raise Exception.new("rate for #{cur} on #{Store.format_date(date)} not available, retrying in the next run: #{ex.message}", cause: ex)
      end
      amount = begin
        Domain.to_eur_cents(input.original_amount_minor, cur, rate.rate)
      rescue Domain::ValidationError
        return input
      end
      return input if amount <= 0 || amount > Domain::MAX_AMOUNT_CENTS
      input.amount_cents = amount
      input.fx_rate = rate.rate
      input.fx_source = rate.source
      input
    end

    def run(stopper : Stopper, every : Time::Span = 1.hour) : Nil
      tick = Time.instant + every
      loop do
        begin
          n = materialize(@d.today, stopper)
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
