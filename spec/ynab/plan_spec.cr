require "../spec_helper"

private PERSON = 1_i64
private DAY    = Time.utc(2026, 9, 1)

private def want(id : Int64, cents : Int64 = 1000_i64, category : String? = nil) : YNAB::Want
  YNAB::Want.new(YNAB::Posting.new(id, DAY, cents, "Kino", "memo #{id}", nil), category)
end

private def wants(*list : YNAB::Want) : Hash(Int64, YNAB::Want)
  list.to_h { |w| {w.expense_id, w} }
end

private def rows(*list : Store::YNABSync) : Hash(Int64, Store::YNABSync)
  list.to_h { |r| {r.expense_id, r} }
end

private def synced(w : YNAB::Want, txn_id : String) : Store::YNABSync
  Store::YNABSync.synced(w.expense_id, PERSON, txn_id, w.fingerprint, DAY)
end

describe YNAB::Plan do
  it "creates what has no transaction yet" do
    a, b = want(1), want(2)
    plan = YNAB::Plan.build(wants(a, b), rows(synced(a, "t1")), false)
    {plan.creates.map(&.expense_id), plan.updates, plan.deletes, plan.forget}.should eq({[2_i64], [] of YNAB::Update, [] of Store::YNABSync, [] of Int64})
    YNAB::Plan.build(wants(b, a), {} of Int64 => Store::YNABSync, false).creates.map(&.expense_id).should eq [1, 2]
  end

  it "creates a row that lost its transaction" do
    a = want(1)
    YNAB::Plan.build(wants(a), rows(Store::YNABSync.new(1_i64, PERSON)), false).creates.should eq [a]
    YNAB::Plan.build(wants(a), rows(Store::YNABSync.pending(1_i64, PERSON)), false).creates.should eq [a]
  end

  it "updates what changed since it was transferred" do
    old, current = want(1), want(1, 2000_i64)
    plan = YNAB::Plan.build(wants(current), rows(synced(old, "t1")), false)
    plan.updates.should eq [YNAB::Update.new(current, "t1")]
    plan.creates.should be_empty
    YNAB::Plan.build(wants(old), rows(synced(old, "t1")), false).updates.should be_empty
    # Another category changes the fingerprint too.
    YNAB::Plan.build(wants(want(1, 1000_i64, "c-food")), rows(synced(old, "t1")), false).updates.size.should eq 1
  end

  it "retries a failed state only when it changed or in the full sync" do
    a, changed = want(1), want(1, 2000_i64)
    failed = Store::YNABSync.failed(1_i64, PERSON, "t1", a.fingerprint, "broken")
    YNAB::Plan.build(wants(a), rows(failed), false).updates.should be_empty
    YNAB::Plan.build(wants(a), rows(failed), true).updates.map(&.txn_id).should eq ["t1"]
    YNAB::Plan.build(wants(changed), rows(failed), false).updates.map(&.txn_id).should eq ["t1"]
    without = Store::YNABSync.failed(1_i64, PERSON, nil, a.fingerprint, "broken")
    YNAB::Plan.build(wants(a), rows(without), false).creates.should be_empty
    YNAB::Plan.build(wants(a), rows(without), true).creates.should eq [a]
  end

  it "deletes what is gone and forgets rows without a transaction" do
    a = want(1)
    gone = synced(a, "t1")
    plan = YNAB::Plan.build({} of Int64 => YNAB::Want, rows(gone, Store::YNABSync.new(2_i64, PERSON), Store::YNABSync.pending(3_i64, PERSON)), false)
    {plan.deletes, plan.forget}.should eq({[gone], [2_i64, 3_i64]})
  end

  it "retries a failed delete only in the full sync" do
    failed = synced(want(1), "t1").delete_failed("broken")
    YNAB::Plan.build({} of Int64 => YNAB::Want, rows(failed), false).deletes.should be_empty
    YNAB::Plan.build({} of Int64 => YNAB::Want, rows(failed), true).deletes.should eq [failed]
  end

  it "sorts everything by expense ID" do
    old = (1..3).map { |i| want(i.to_i64) }
    plan = YNAB::Plan.build(wants(want(9), want(4), want(7, 2000_i64)), rows(synced(want(7), "t7"), synced(old[2], "t3"), synced(old[0], "t1")), false)
    {plan.creates.map(&.expense_id), plan.updates.map(&.want.expense_id), plan.deletes.map(&.expense_id)}.should eq({[4, 9], [7], [1, 3]})
  end
end
