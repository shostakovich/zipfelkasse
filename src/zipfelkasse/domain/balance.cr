module Zipfelkasse::Domain
  # A reimbursement is an entry whose payer pays back and whose single share is the recipient.
  record Entry, paid_by : Int64, amount_cents : Int64, shares : Array(Share)

  def balances(entries : Array(Entry)) : Hash(Int64, Int64)
    entries.each_with_object({} of Int64 => Int64) do |e, b|
      b[e.paid_by] = b.fetch(e.paid_by, 0_i64) + e.amount_cents
      e.shares.each { |s| b[s.participant_id] = b.fetch(s.participant_id, 0_i64) - s.amount_cents }
    end
  end

  record Transfer, from : Int64, to : Int64, amount_cents : Int64

  # Greedy: the largest debtor pays the largest creditor; ties go to the smaller ID.
  def settle(balances : Hash(Int64, Int64)) : Array(Transfer)
    open = balances.reject { |_, v| v == 0 }
    transfers = [] of Transfer
    loop do
      creditor = open.select { |_, v| v > 0 }.min_by? { |id, v| {-v, id} }
      debtor = open.select { |_, v| v < 0 }.min_by? { |id, v| {v, id} }
      return transfers unless creditor && debtor
      to, credit = creditor
      from, debt = debtor
      amount = Math.min(credit, -debt)
      transfers << Transfer.new(from: from, to: to, amount_cents: amount)
      {to => credit - amount, from => debt + amount}.each do |id, v|
        v == 0 ? open.delete(id) : (open[id] = v)
      end
    end
  end
end
