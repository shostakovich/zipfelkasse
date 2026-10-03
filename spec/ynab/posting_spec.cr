require "../spec_helper"

private def expense(id : Int64, title : String = "Kino", reimbursement = false) : Store::Expense
  input = Store::ExpenseInput.new(title: title, date: date("2026-09-01"), paid_by: 1_i64, amount_cents: 1000_i64,
    reimbursement: reimbursement)
  shares = [Domain::Share.new(1_i64, amount_cents: 500_i64), Domain::Share.new(2_i64, amount_cents: 500_i64)]
  build_expense(id, input, shares, nil, "Anna")
end

describe YNAB do
  describe ".posting_for" do
    it "takes the person's share as the amount and describes the whole expense in the memo" do
      posting = YNAB.posting_for(expense(7), 1_i64).not_nil!

      {posting.amount_cents, posting.payee, posting.memo}
        .should eq({500, "Kino", "Gesamt 10,00 € · bezahlt von Anna · zipfelkasse #7"})
      posting.milliunits.should eq -5000
    end

    it "cuts a long title to the length YNAB accepts" do
      YNAB.posting_for(expense(7, "x" * 250), 1_i64).not_nil!.payee.size.should eq YNAB::MAX_PAYEE_LEN
    end

    it "makes no posting for a person without a share" do
      YNAB.posting_for(expense(7), 3_i64).should be_nil
    end

    it "makes no posting for a reimbursement" do
      YNAB.posting_for(expense(7, reimbursement: true), 1_i64).should be_nil
    end
  end

  describe ".marker_id" do
    {"bla · zipfelkasse #123" => 123, "zipfelkasse #12\n" => 12, "zipfelkasse #12 und mehr" => nil}.each do |memo, id|
      it "finds #{id.inspect} in #{memo.inspect}" do
        YNAB.marker_id(memo).should eq id
      end
    end
  end

  describe ".truncate" do
    it "cuts to the length with an ellipsis" do
      YNAB.truncate("abcd", 3).should eq "ab…"
      YNAB.truncate("abc", 3).should eq "abc"
      YNAB.truncate("abc", 1).should eq "a"
    end
  end

  describe YNAB::Want do
    it "has a fingerprint that never changes, because stored ones are compared with it" do
      posting = YNAB::Posting.new(7_i64, date("2026-09-01"), 500_i64, "Kino", "memo", 0_i64)

      YNAB::Want.new(posting, "c-food").fingerprint.should eq "d4a1ad6e19cee680676eefc66df39514"
    end
  end

  describe ".today" do
    berlin = Time::Location.load("Europe/Berlin")

    it "is the local date, but never later than the date in UTC" do
      YNAB.today(Time.utc(2026, 10, 2, 12), berlin).should eq date("2026-10-02")
      YNAB.today(Time.utc(2026, 10, 2, 23, 30), berlin).should eq date("2026-10-02")
    end
  end
end
