module Zipfelkasse
  # Shutdown signal for background jobs (Go's context cancellation):
  # `wait(span)` sleeps but returns early (false) once `stop` was called.
  class Stopper
    @channel = Channel(Nil).new

    def stop : Nil
      @channel.close unless @channel.closed?
    end

    def stopped? : Bool
      @channel.closed?
    end

    # Sleeps for span; true if the time passed, false if stopped meanwhile.
    def wait(span : Time::Span) : Bool
      return false if stopped?
      select
      when @channel.receive?
        false
      when timeout(span.positive? ? span : Time::Span.zero)
        !stopped?
      end
    end

    # A channel that is closed on stop (for selects of the jobs).
    def done : Channel(Nil)
      @channel
    end
  end
end
