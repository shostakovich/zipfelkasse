module Zipfelkasse
  class Stopper
    @channel = Channel(Nil).new

    def stop : Nil
      @channel.close unless @channel.closed?
    end

    def stopped? : Bool
      @channel.closed?
    end

    def wait(span : Time::Span) : Bool
      return false if stopped?
      select
      when @channel.receive?
        false
      when timeout(span.positive? ? span : Time::Span.zero)
        !stopped?
      end
    end

    def done : Channel(Nil)
      @channel
    end
  end
end
