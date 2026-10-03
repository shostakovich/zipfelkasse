module Zipfelkasse::Domain
  # An expense in the form needed for balances. Reimbursements are ordinary
  # entries: payer = whoever pays back, single share = recipient.
  record Entry, paid_by : Int64, amount_cents : Int64, shares : Array(Share)

  # Positive = is owed money, negative = owes money. All balances sum to 0.
  def balances(entries : Array(Entry)) : Hash(Int64, Int64)
    entries.each_with_object({} of Int64 => Int64) do |e, b|
      b[e.paid_by] = b.fetch(e.paid_by, 0_i64) + e.amount_cents
      e.shares.each { |s| b[s.participant_id] = b.fetch(s.participant_id, 0_i64) - s.amount_cents }
    end
  end

  record Transfer, from : Int64, to : Int64, amount_cents : Int64

  # Greedy: the largest debtor pays the largest creditor until everything is
  # settled. Ties are broken by the smaller ID, so the result is deterministic.
  # IDs must be > 0 (0 means "none").
  def settle(balances : Hash(Int64, Int64)) : Array(Transfer)
    b = balances.reject { |_, v| v == 0 }
    transfers = [] of Transfer
    loop do
      creditor = debtor = 0_i64
      b.each do |id, v|
        creditor = id if v > 0 && (creditor == 0 || v > b[creditor] || (v == b[creditor] && id < creditor))
        debtor = id if v < 0 && (debtor == 0 || v < b[debtor] || (v == b[debtor] && id < debtor))
      end
      return transfers if creditor == 0 || debtor == 0
      amount = Math.min(b[creditor], -b[debtor])
      transfers << Transfer.new(from: debtor, to: creditor, amount_cents: amount)
      b[creditor] -= amount
      b[debtor] += amount
      b.delete(creditor) if b[creditor] == 0
      b.delete(debtor) if b[debtor] == 0
    end
  end
end
