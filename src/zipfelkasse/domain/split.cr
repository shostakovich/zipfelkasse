require "json"

module Zipfelkasse::Domain
  REIMBURSEMENT_TITLE = "Rückzahlung"

  enum SplitMode
    Equal   # the weight is ignored and stored as 1
    Shares  # weight = integer shares (>= 0)
    Percent # weight = basis points, sum 10000
    Amount  # weight = amount in the smallest unit of the entry's currency, sum = its amount

    def key : String
      to_s.underscore
    end
  end

  # Caps shares so that total * weight cannot overflow.
  private MAX_SHARE_WEIGHT = 1_000_000

  def parse_weight(mode : SplitMode, currency : String, v : String) : Int64
    case mode
    in .equal? then 0_i64
    in .shares?
      v.strip.to_i64? || raise ValidationError.new("Anteile müssen ganze Zahlen sein („#{v}“).")
    in .percent? then parse_basis_points(v)
    in .amount?  then parse_minor(v, weight_decimals(mode, currency))
    end
  end

  def weight_decimals(mode : SplitMode, currency : String) : Int32
    case mode
    in .equal?, .shares? then 0
    in .percent?         then 2
    in .amount?          then currency_decimals(currency)
    end
  end

  record Part, participant_id : Int64, weight : Int64 = 0_i64 do
    include JSON::Serializable
  end

  record Share, participant_id : Int64, weight : Int64 = 0_i64, amount_cents : Int64 = 0_i64 do
    include JSON::Serializable
  end

  def split(mode : SplitMode, total : Int64, parts : Array(Part), rotation : Int64) : Array(Share)
    split_converted(mode, total, total, "EUR", parts, rotation)
  end

  # Divides total (euro cents, > 0) among parts according to mode, for an
  # expense entered as original (smallest unit of currency) and converted to
  # total; for euros original = total. Only `SplitMode::Amount` depends on it: the
  # weights are amounts in currency and must add up to original; total is
  # distributed in proportion to them (for euros the shares are exactly the
  # weights).
  def split_converted(mode : SplitMode, total : Int64, original : Int64, currency : String,
                      parts : Array(Part), rotation : Int64) : Array(Share)
    raise ValidationError.new("Der Betrag muss größer als 0 sein.") if total <= 0
    raise ValidationError.new("Der Betrag ist zu groß.") if total > MAX_AMOUNT_CENTS
    raise ValidationError.new("Mindestens eine Person muss an der Ausgabe beteiligt sein.") if parts.empty?
    ps = parts.sort_by(&.participant_id)
    ps.each_with_index do |p, i|
      raise ValidationError.new("Ungültige Person in der Aufteilung.") if p.participant_id <= 0
      if i > 0 && ps[i - 1].participant_id == p.participant_id
        raise ValidationError.new("Eine Person ist in der Aufteilung doppelt aufgeführt.")
      end
      raise ValidationError.new("Anteile dürfen nicht negativ sein.") if !mode.equal? && p.weight < 0
    end

    case mode
    in .equal?
      ps = ps.map(&.copy_with(weight: 1_i64))
    in .shares?
      if ps.any? { |p| p.weight > MAX_SHARE_WEIGHT }
        raise ValidationError.new("Anteile dürfen höchstens #{MAX_SHARE_WEIGHT} sein.")
      end
      sum = ps.sum(0_i64, &.weight)
      raise ValidationError.new("Die Summe der Anteile muss größer als 0 sein.") if sum <= 0
    in .percent?
      raise ValidationError.new("Die Prozente müssen zusammen 100 % ergeben.") if ps.any? { |p| p.weight > 10000 }
      sum = ps.sum(0_i64, &.weight)
      if sum != 10000
        raise ValidationError.new("Die Prozente müssen zusammen 100 % ergeben (aktuell #{format_basis_points(sum)}).")
      end
    in .amount?
      wide = 0_i128
      ps.each do |p|
        wide += p.weight
        raise ValidationError.new("Der Betrag ist zu groß.") if wide > Int64::MAX
      end
      sum = wide.to_i64
      if sum != original
        raise ValidationError.new("Die Beträge müssen zusammen #{format_money(original, currency)} ergeben (aktuell #{format_money(sum, currency)}).")
      end
    end

    allocate(total, ps.map(&.weight), rotation).map_with_index do |cents, i|
      Share.new(ps[i].participant_id, ps[i].weight, cents)
    end
  end

  # Distributes total (>= 0) in proportion to weights (>= 0, sum at most
  # Int64::MAX) using the largest-remainder method; the result sums to
  # exactly total (all zero if the weights sum to 0). On tied remainders,
  # precedence rotates with rotation (the expense ID): the tied entries form a
  # circle in index order, the first cent goes to the one at index rotation
  # mod count, the next to the following one, and so on. That way, across
  # many unevenly split expenses, the extra cent does not always land on the
  # same person. Callers pass the weights sorted by participant ID. Computes
  # with 128-bit products, so that total · weight cannot overflow. The JS
  # preview (static/expense-form.js) computes the same way.
  def allocate(total : Int64, weights : Array(Int64), rotation : Int64) : Array(Int64)
    # Weights are >= 0 by contract.
    sum = weights.reduce(0_u64) { |acc, w| acc &+ w.to_u64! }
    result = Array.new(weights.size, 0_i64)
    return result if sum == 0
    rems = Array.new(weights.size, 0_u64)
    weights.each_with_index do |w, i|
      product = total.to_u64!.to_u128 * w.to_u64!
      result[i] = (product // sum).to_u64.to_i64!
      rems[i] = (product % sum).to_u64
    end
    allocated = result.reduce(0_i64) { |acc, c| acc &+ c }
    # Largest remainder first; ties stay in index order and are then rotated
    # by rotation (left, so that the entry at rotation mod count comes first).
    order = (0...weights.size).to_a
      .sort_by! { |i| {UInt64::MAX - rems[i], i} }
      .chunk_while { |a, b| rems[a] == rems[b] }
      .flat_map { |tied| tied.rotate((rotation.remainder(tied.size) + tied.size).remainder(tied.size)) }
      .to_a
    # The remainder is smaller than the number of entries with a remainder:
    # at most one cent each.
    (total - allocated).times { |k| result[order[k]] += 1 }
    result
  end
end
