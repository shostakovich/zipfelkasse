module Zipfelkasse::Web
  module Views
    # Width: bar length in percent of half the row (0–100).
    record BalanceRow, participant : Store::Participant, cents : Int64, width : Int64

    # A settlement suggestion; link opens the prefilled reimbursement form.
    record TransferRow, from : Store::Participant, to : Store::Participant, cents : Int64, link : String

    record Balances, rows : Array(BalanceRow), transfers : Array(TransferRow), me : Store::Participant? do
      Web.view "web/balances.ecr"
    end
  end

  class BalancesController < Controller
    def register : Nil
      get("/salden") { |env| show(env) }
    end

    private def show(env : HTTP::Server::Context) : String
      balances = @d.store.balances
      people = @d.store.list_participants(true)
      max_abs = balances.values.max_of?(&.abs) || 0_i64
      rows = people.compact_map do |p|
        cents = balances.fetch(p.id, 0_i64)
        next if p.archived? && cents == 0
        width = max_abs > 0 && cents != 0 ? Math.max(1_i64, (cents.abs * 100 + max_abs // 2) // max_abs) : 0_i64
        Views::BalanceRow.new(p, cents, width)
      end
      by_id = people.to_h { |p| {p.id, p} }
      transfers = Domain.settle(balances).map do |t|
        query = URI::Params.build do |q|
          q.add "an", t.to.to_s
          q.add "betrag", t.amount_cents.to_s
          q.add "rueckzahlung", "1"
          q.add "von", t.from.to_s
        end
        Views::TransferRow.new(by_id[t.from], by_id[t.to], t.amount_cents, "/ausgaben/neu?" + query)
      end
      page(env, Views::Balances.new(rows, transfers, env.me?), "Salden", Nav::Balances)
    end
  end
end
