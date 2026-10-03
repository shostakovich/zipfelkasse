module Zipfelkasse
  class Store
    DATA_MIGRATIONS[2] = ->(s : Store, tx : DB::Connection) { s.resplit_shares(tx) }

    # Recomputes the cent shares of all expenses (deleted ones too) with the
    # current split rule, where the extra cent of a tie rotates with the
    # expense ID instead of always going to the smallest participant ID.
    # Weights stay; expenses whose stored weights the split rejects (old
    # imports) stay unchanged. The YNAB sync notices the new shares through
    # its fingerprint.
    protected def resplit_shares(tx : DB::Connection) : Nil
      rows = [] of {Int64, String, Int64, Int64, Int64, Int64}
      tx.query("SELECT e.id, e.split_mode, e.amount_cents, x.participant_id, x.weight, x.amount_cents " \
               "FROM expenses e JOIN expense_shares x ON x.expense_id = e.id ORDER BY e.id, x.participant_id") do |rs|
        rs.each { rows << rs.read(Int64, String, Int64, Int64, Int64, Int64) }
      end
      changed = 0
      rows.chunk_while { |a, b| a[0] == b[0] }.each do |group|
        id, mode, amount, *_ = group[0]
        parts = group.map { |r| Domain::Part.new(r[3], r[4]) }
        fresh = begin
          Domain.split(Domain::SplitMode.new(mode), amount, parts, id)
        rescue Domain::ValidationError
          next
        end
        diff = false
        fresh.each_with_index do |sh, i| # both sorted by participant
          next if sh.amount_cents == group[i][5]
          diff = true
          tx.exec("UPDATE expense_shares SET amount_cents = ? WHERE expense_id = ? AND participant_id = ?",
            sh.amount_cents, id, sh.participant_id)
        end
        changed += 1 if diff
      end
      return if changed == 0
      insert_activity(tx, 0_i64, ACTION_SHARES_RECALCULATED, 0_i64, ActivityDetails.new(text: "Rest-Cents von #{changed} Ausgaben neu verteilt: Bei Gleichstand bekommt den Extra-Cent jetzt " \
                                                                                              "reihum eine andere Person statt immer dieselbe."))
    end
  end
end
