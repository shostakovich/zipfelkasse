module Zipfelkasse::Web
  class Handlers
    # Width: bar length in percent of half the row (0–100).
    record BalanceRow, participant : Store::Participant, cents : Int64, width : Int64

    # A settlement suggestion; link opens the prefilled reimbursement form.
    record TransferRow, from : Store::Participant, to : Store::Participant, cents : Int64, link : String

    def register_balances : Nil
      Web.route(@d, "GET", "/salden") { |r| balances(r) }
    end

    def balances(r : Request) : Nil
      balances = @d.store.balances
      people = @d.store.list_participants(true)
      max_abs = balances.values.max_of?(&.abs) || 0_i64
      rows = [] of BalanceRow
      people.each do |p|
        b = balances.fetch(p.id, 0_i64)
        next if p.archived? && b == 0
        width = max_abs > 0 && b != 0 ? Math.max(1_i64, (b.abs * 100 + max_abs // 2) // max_abs) : 0_i64
        rows << BalanceRow.new(p, b, width)
      end
      by_id = people.to_h { |p| {p.id, p} }
      transfers = Domain.settle(balances).map do |t|
        query = URI::Params.build do |q|
          q.add "an", t.to.to_s
          q.add "betrag", t.amount_cents.to_s
          q.add "rueckzahlung", "1"
          q.add "von", t.from.to_s
        end
        TransferRow.new(by_id[t.from], by_id[t.to], t.amount_cents, "/ausgaben/neu?" + query)
      end
      me = r.me?
      r.page(200, Page.new(title: "Salden", nav: NAV_BALANCES)) do |__io__|
        Web.template __io__, "web/balances.ecr"
      end
    end
  end
end
