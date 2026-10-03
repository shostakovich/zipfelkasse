module Zipfelkasse
  class Store
    DATA_MIGRATIONS[4] = ->(s : Store, tx : DB::Connection) { s.convert_amount_weights(tx) }

    # For "by amounts" in a foreign currency, expense_shares.weight used to
    # hold euro cents; now it holds amounts in that currency. The old weights
    # are converted back as well as possible (largest remainder on
    # original_amount_minor, ties to the smaller participant ID, as the edit
    # form did). The euro shares stay, so balances and YNAB fingerprints do
    # too. Deleted expenses and recurrence templates are converted as well.
    protected def convert_amount_weights(tx : DB::Connection) : Nil
      rows = [] of {Int64, Int64, Int64, Int64}
      tx.query("SELECT e.id, e.original_amount_minor, x.participant_id, x.weight " \
               "FROM expenses e JOIN expense_shares x ON x.expense_id = e.id " \
               "WHERE e.split_mode = ? AND e.is_reimbursement = 0 AND e.original_currency <> 'EUR' " \
               "ORDER BY e.id, x.participant_id", Domain::SPLIT_AMOUNT.value) do |rs|
        rs.each { rows << rs.read(Int64, Int64, Int64, Int64) }
      end
      expenses = 0
      rows.chunk_while { |a, b| a[0] == b[0] }.each do |group|
        id, original, *_ = group[0]
        parts, changed = Store.to_original_weights(group.map { |r| Domain::Part.new(r[2], r[3]) }, original)
        next unless changed
        expenses += 1
        parts.each do |p|
          tx.exec("UPDATE expense_shares SET weight = ? WHERE expense_id = ? AND participant_id = ?",
            p.weight, id, p.participant_id)
        end
      end

      templates = [] of {Int64, String}
      tx.query("SELECT id, template_json FROM recurring ORDER BY id") do |rs|
        rs.each { templates << rs.read(Int64, String) }
      end
      converted = 0
      templates.each do |id, raw|
        t = begin
          ExpenseInput.from_json(raw)
        rescue ex
          raise Exception.new("recurring #{id}: template: #{ex.message}")
        end
        cur = t.original_currency.upcase
        next if t.split_mode != Domain::SPLIT_AMOUNT || t.reimbursement? || cur.empty? || cur == "EUR"
        parts, changed = Store.to_original_weights(t.parts, t.original_amount_minor)
        next unless changed
        t.parts = parts
        tx.exec("UPDATE recurring SET template_json = ? WHERE id = ?", t.to_json, id)
        converted += 1
      end

      return if expenses == 0 && converted == 0
      what = [] of String
      what << count_noun(expenses, "Ausgabe", "Ausgaben") if expenses > 0
      what << count_noun(converted, "wiederkehrende Ausgabe", "wiederkehrende Ausgaben") if converted > 0
      insert_activity(tx, 0_i64, ACTION_WEIGHTS_CONVERTED, 0_i64, ActivityDetails.new(text: "Aufteilung nach Beträgen in Fremdwährung umgestellt (#{what.join(" und ")}): Die Beträge pro Person " \
                                                                                            "stehen jetzt in der Originalwährung statt in Euro. Die Euro-Anteile bleiben unverändert."))
    end

    # Distributes original in proportion to the old weights (euro cents),
    # sorted by participant ID; the flag says whether a weight changed.
    # Weights summing to 0 (or negative ones) are left alone.
    protected def self.to_original_weights(parts : Array(Domain::Part), original : Int64) : {Array(Domain::Part), Bool}
      ps = parts.sort_by(&.participant_id)
      return {parts, false} if ps.any? { |p| p.weight < 0 }
      sum = ps.reduce(0_i64) { |acc, p| acc &+ p.weight }
      return {parts, false} if sum <= 0 || original <= 0
      changed = false
      Domain.allocate(original, ps.map(&.weight), 0_i64).each_with_index do |w, i|
        next if w == ps[i].weight
        ps[i] = ps[i].copy_with(weight: w)
        changed = true
      end
      {ps, changed}
    end

    private def count_noun(n : Int32, one : String, many : String) : String
      n == 1 ? "1 #{one}" : "#{n} #{many}"
    end
  end
end
