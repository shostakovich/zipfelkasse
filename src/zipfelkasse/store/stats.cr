module Zipfelkasse
  class Store
    enum StatsGroup
      Category
      Title
      Year
      Month
      Week
      Person
      CategoryMonth

      # Groupings whose rows are periods only.
      def time? : Bool
        year? || month? || week?
      end

      def period_unit : Domain::PeriodUnit?
        case self
        in .year?                    then Domain::PeriodUnit::Year
        in .month?, .category_month? then Domain::PeriodUnit::Month
        in .week?                    then Domain::PeriodUnit::Week
        in .category?, .title?, .person?
          nil
        end
      end

      # Periods look like "2026", "2026-09" and ISO week "2026-W40". The week
      # format needs SQLite >= 3.46 (3.45 returns NULL).
      def period_sql : String?
        case self
        in .year?                    then "substr(e.date, 1, 4)"
        in .month?, .category_month? then "substr(e.date, 1, 7)"
        in .week?                    then "strftime('%G-W%V', e.date)"
        in .category?, .title?, .person?
          nil
        end
      end
    end

    # Reimbursements and deleted expenses never count.
    record StatsFilter,
      group_by : StatsGroup,
      from : Time? = nil,            # inclusive
      to : Time? = nil,              # inclusive
      participant_id : Int64? = nil, # only this person's share, otherwise the total amounts
      category_id : Int64? = nil,
      without_category : Bool = false,        # then category_id is ignored
      any_text : Array(String) = [] of String # title or notes contain one of them

    # Depending on the grouping, category, title, period and/or person are
    # set (category is nil for expenses without one). title is one of the
    # group's titles (grouped case-insensitively); paid_cents is only set for
    # person (paid by the person, while amount_cents is their share).
    record StatRow,
      category : String? = nil,
      title : String? = nil,
      period : String? = nil,
      person : String? = nil,
      count : Int64 = 0_i64,
      amount_cents : Int64 = 0_i64,
      paid_cents : Int64? = nil

    # Time groupings are sorted by period, the others by amount (largest
    # first); periods without expenses are missing (see `fill_periods`).
    def stats(f : StatsFilter) : Array(StatRow)
      where = ["e.deleted_at IS NULL", "e.is_reimbursement = 0"]
      args = [] of DB::Any
      if from = f.from
        where << "e.date >= ?"
        args << Store.format_date(from)
      end
      if to = f.to
        where << "e.date <= ?"
        args << Store.format_date(to)
      end
      if f.without_category
        where << "e.category_id IS NULL"
      elsif id = f.category_id
        where << "e.category_id = ?"
        args << id
      end
      cond, cond_args = Store.text_cond(f.any_text)
      unless cond.empty?
        where << cond
        args.concat(cond_args)
      end
      return stats_by_person(where, args, f.participant_id) if f.group_by.person?

      from_clause = "expenses e LEFT JOIN categories c ON c.id = e.category_id"
      amount = "e.amount_cents"
      if participant_id = f.participant_id
        from_clause += " JOIN expense_shares x ON x.expense_id = e.id AND x.participant_id = ?"
        args.unshift(participant_id) # the JOIN comes before the WHERE
        amount = "x.amount_cents"
      end
      period = f.group_by.period_sql || "NULL"
      # Columns: label (category or title), period, count, amount.
      label, group, order =
        case f.group_by
        when .category?       then {"c.name", "c.name", "4 DESC, c.name IS NULL, c.name"}
        when .title?          then {"max(e.title)", "#{FOLD_FUNC}(e.title)", "4 DESC, 1"}
        when .category_month? then {"c.name", "c.name, #{period}", "2, 4 DESC, c.name IS NULL, c.name"}
        else                       {"NULL", period, "2"}
        end
      q = "SELECT #{label}, #{period}, count(*), sum(#{amount}) FROM #{from_clause} " \
          "WHERE #{where.join(" AND ")} GROUP BY #{group} ORDER BY #{order}"
      @db.query_all(q, args: args) do |rs|
        name, label_period, count, cents = rs.read(String?, String?, Int64, Int64)
        if f.group_by.title?
          StatRow.new(title: name, period: label_period, count: count, amount_cents: cents)
        else
          StatRow.new(category: name, period: label_period, count: count, amount_cents: cents)
        end
      end
    end

    private def stats_by_person(where : Array(String), args : Array(DB::Any), participant_id : Int64?) : Array(StatRow)
      cond = where.join(" AND ")
      q = <<-SQL
        SELECT p.name,
          (SELECT count(*) FROM expense_shares x JOIN expenses e ON e.id = x.expense_id WHERE x.participant_id = p.id AND #{cond}),
          (SELECT coalesce(sum(x.amount_cents), 0) FROM expense_shares x JOIN expenses e ON e.id = x.expense_id WHERE x.participant_id = p.id AND #{cond}),
          (SELECT coalesce(sum(e.amount_cents), 0) FROM expenses e WHERE e.paid_by = p.id AND #{cond})
          FROM participants p WHERE 1 = 1
        SQL
      # The conditions appear three times, so do their arguments.
      all = args + args + args
      if participant_id
        q += " AND p.id = ?"
        all << participant_id
      end
      rows = @db.query_all(q, args: all, as: {String, Int64, Int64, Int64})
      rows.reject! { |_, count, _, paid| count == 0 && paid == 0 }
      rows.sort_by! { |name, _, cents, _| {-cents, name.downcase} }
      rows.map { |name, count, cents, paid| StatRow.new(person: name, count: count, amount_cents: cents, paid_cents: paid) }
    end

    # Adds a zero row for every period of a time grouping between first and
    # last (inclusive) that has none. Rows outside that range stay.
    def self.fill_periods(rows : Array(StatRow), group : StatsGroup, first : Time, last : Time) : Array(StatRow)
      unit = group.period_unit
      return rows if unit.nil? || !group.time? || last < first
      have = rows.to_h { |r| {r.period.to_s, r} }
      filled = Domain::Period.labels(unit, first, last).map { |p| have.delete(p) || StatRow.new(period: p) }
      rows.each { |r| filled << r if have.has_key?(r.period.to_s) }
      filled.sort_by(&.period.to_s)
    end
  end
end
