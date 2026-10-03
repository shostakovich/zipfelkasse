require "../spec_helper"

private def share(id, cents) : Domain::Share
  Domain::Share.new(participant_id: id.to_i64, amount_cents: cents.to_i64)
end

private def transfer(from, to, cents) : Domain::Transfer
  Domain::Transfer.new(from.to_i64, to.to_i64, cents.to_i64)
end

private def balances(h : Hash(Int32, Int32)) : Hash(Int64, Int64)
  h.to_h { |id, v| {id.to_i64, v.to_i64} }
end

describe Domain do
  it "computes balances" do
    entries = [
      # A (1) pays 30 € for all three
      Domain::Entry.new(1, 3000, [share(1, 1000), share(2, 1000), share(3, 1000)]),
      # B (2) pays 10 € for C only
      Domain::Entry.new(2, 1000, [share(3, 1000)]),
      # Reimbursement: C pays 5 € to A (A has a 100 % share)
      Domain::Entry.new(3, 500, [share(1, 500)]),
    ]
    got = Domain.balances(entries)
    got.should eq balances({1 => 1500, 2 => 0, 3 => -1500})
    got.values.sum.should eq 0
  end

  it "returns no balances for no entries" do
    Domain.balances([] of Domain::Entry).should be_empty
  end

  describe ".settle" do
    {
      {"empty", {} of Int32 => Int32, [] of Domain::Transfer},
      {"settled", {1 => 0, 2 => 0}, [] of Domain::Transfer},
      {"simple", {1 => 1500, 2 => -1500}, [transfer(2, 1, 1500)]},
      {"greedy", {1 => 5000, 2 => -3000, 3 => -1500, 4 => -500},
       [transfer(2, 1, 3000), transfer(3, 1, 1500), transfer(4, 1, 500)]},
      {"multiple creditors", {1 => 2000, 2 => 1000, 3 => -2500, 4 => -500},
       [transfer(3, 1, 2000), transfer(3, 2, 500), transfer(4, 2, 500)]},
      {"tie broken by ID", {5 => 100, 2 => 100, 9 => -100, 3 => -100},
       [transfer(3, 2, 100), transfer(9, 5, 100)]},
      {"one creditor, tied debtors", {1 => 300, 2 => -100, 3 => -100, 4 => -100},
       [transfer(2, 1, 100), transfer(3, 1, 100), transfer(4, 1, 100)]},
      {"tied creditors", {1 => 100, 2 => 100, 3 => -150, 4 => -50},
       [transfer(3, 1, 100), transfer(3, 2, 50), transfer(4, 2, 50)]},
    }.each do |(name, input, want)|
      it name do
        Domain.settle(balances(input)).should eq want
      end
    end
  end

  it "does not modify its input" do
    b = balances({1 => 100, 2 => -100})
    Domain.settle(b)
    b.should eq balances({1 => 100, 2 => -100})
  end
end
