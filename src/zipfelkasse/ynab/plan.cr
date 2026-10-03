require "digest/sha256"

module Zipfelkasse::YNAB
  HASH_VERSION = "v1"

  struct Want
    getter posting : Posting
    getter category : String? # YNAB category ID, nil = uncategorized
    getter fingerprint : String

    delegate expense_id, date, payee, memo, milliunits, to: @posting

    def initialize(@posting, @category)
      @fingerprint = Want.fingerprint(@posting, @category)
    end

    def new_txn(account_id : String) : SaveTxn
      SaveTxn.new(date: date_text, amount: milliunits, payee_name: payee, memo: memo, account_id: account_id,
        category_id: category, cleared: "cleared", approved: true)
    end

    # Changes the category only if mapped: without a mapping a category set
    # by hand in YNAB is kept. cleared/approved are no longer touched after
    # creation (e.g. reconciled transactions).
    def patch_txn(txn_id : String) : SaveTxn
      SaveTxn.new(date: date_text, amount: milliunits, payee_name: payee, memo: memo, id: txn_id, category_id: category)
    end

    private def date_text : String
      Store.format_date(date)
    end

    # Stored in ynab_sync: must stay byte-identical across versions, or every
    # transaction looks changed and gets PATCHed.
    def self.fingerprint(posting : Posting, category : String?) : String
      data = [HASH_VERSION, Store.format_date(posting.date), posting.milliunits, posting.payee, posting.memo, category].join('\0')
      Digest::SHA256.digest(data)[0, 16].hexstring
    end
  end

  record Update, want : Want, txn_id : String

  record Plan, creates : Array(Want), updates : Array(Update), deletes : Array(Store::YNABSync), forget : Array(Int64) do
    def self.build(wants : Hash(Int64, Want), rows : Hash(Int64, Store::YNABSync), full : Bool) : Plan
      creates, updates = [] of Want, [] of Update
      deletes, forget = [] of Store::YNABSync, [] of Int64
      wants.each do |id, want|
        row = rows[id]?
        txn_id = row.try(&.txn_id)
        if !full && row && row.failed_at?(want.fingerprint)
          # failed and unchanged: retry only in the full sync
        elsif row.nil? || txn_id.nil?
          creates << want
        elsif !row.current?(want.fingerprint)
          updates << Update.new(want, txn_id)
        end
      end
      rows.each do |id, row|
        next if wants.has_key?(id)
        # Gone (deleted or share 0): delete, even if the last attempt (e.g. a
        # PATCH) failed. Only a failed DELETE waits for the full sync.
        if row.txn_id.nil?
          forget << id
        elsif full || !row.delete_failed?
          deletes << row
        end
      end
      new(creates.sort_by!(&.expense_id), updates.sort_by!(&.want.expense_id), deletes.sort_by!(&.expense_id), forget.sort!)
    end
  end
end
