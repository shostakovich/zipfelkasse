module Zipfelkasse::MCP
  # Helpers of the statistics tool for time groupings and year-over-year
  # comparison.
  module Statistics
    extend self

    alias Key = {String?, String?, String?, String?}

    # Lists the periods without expenses of a time grouping with 0: from from
    # (or the first row) to to (or today), never beyond today.
    def fill_gaps(rows : Array(Store::StatRow), filter : Store::StatsFilter, today : Time) : Array(Store::StatRow)
      unit = filter.group_by.period_unit.not_nil!
      first = filter.from || rows.first?.try { |r| Domain::Period.first_day(unit, r.period.to_s) }
      return rows unless first
      Store.fill_periods(rows, filter.group_by, first, MCP.min_time(filter.to, today))
    end

    # Whether a period lies within the requested range of a time-keyed
    # grouping: from from (or the first row) to to (or today), never beyond
    # today.
    def period_window(filter : Store::StatsFilter, rows : Array(Store::StatRow), today : Time) : Proc(String, Bool)
      unit = filter.group_by.period_unit.not_nil!
      first = filter.from.try { |t| Domain::Period.label(unit, t) } || rows.compact_map(&.period).min?
      return ->(period : String) { false } unless first
      last = Domain::Period.label(unit, MCP.min_time(filter.to, today))
      ->(period : String) { first <= period <= last }
    end

    # Each row with the amount of the same group one year earlier. previous
    # are the rows of the period one year earlier; their periods are shifted
    # by one year to match. Groups that only exist in previous are appended
    # with 0 – for time-keyed groupings (window given) only if their period
    # lies within window.
    def with_previous(rows : Array(Store::StatRow), previous : Array(Store::StatRow), window : Proc(String, Bool)?,
                      group : Store::StatsGroup) : Array({Store::StatRow, Int64})
      key = ->(row : Store::StatRow) { {row.category, row.title.try(&.downcase(:fold)), row.person, row.period}.as(Key) }
      earlier = {} of Key => Store::StatRow
      previous.each do |row|
        shifted = row.copy_with(period: row.period.try { |period| Domain::Period.shift_label(period, 1) })
        if have = earlier[key.call(shifted)]?
          # week 53 merged into week 52 of a year without week 53
          earlier[key.call(shifted)] = have.copy_with(amount_cents: have.amount_cents + shifted.amount_cents)
        else
          earlier[key.call(shifted)] = shifted
        end
      end
      pairs = rows.map { |row| {row, earlier.delete(key.call(row)).try(&.amount_cents) || 0_i64} }
      appended = false
      earlier.each_value do |row|
        next if window && !window.call(row.period.to_s)
        gone = Store::StatRow.new(category: row.category, title: row.title, period: row.period, person: row.person,
          paid_cents: group.person? ? 0_i64 : nil)
        pairs << {gone, row.amount_cents}
        appended = true
      end
      if appended && window
        # Back into the order of Store#stats: by period, then amount, then category.
        pairs = pairs.each_with_index.to_a.sort_by! { |(row, _), i| {row.period.to_s, -row.amount_cents, row.category || NO_CATEGORY_LABEL, i} }.map(&.[0])
      end
      pairs
    end
  end
end
