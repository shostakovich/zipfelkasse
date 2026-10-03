require "../spec_helper"

describe "Store backups" do
  use_household

  it "writes backups, keeps the last seven and leaves unrelated files alone" do
    with_temp_dir do |dir|
      File.write(File.join(dir, "notiz.txt"), "x")
      base = Time.utc(2026, 10, 1, 3, 0, 0)
      paths = (0...9).map do |i|
        store.clock = -> { base.shift(days: i) }
        store.backup(dir, 7)
      end
      Dir.children(dir).size.should eq 8
      File.exists?(paths[0]).should be_false
      b = Store.open(paths[8])
      b.list_participants.size.should eq 3
      b.close
    end
  end

  it "writes backups readable by the owner only" do
    with_temp_dir do |dir|
      File.info(store.backup(dir, 7)).permissions.should eq File::Permissions.new(0o600)
    end
  end

  it "rotates only regular backup files" do
    with_temp_dir do |dir|
      other = File.join(dir, "elsewhere.db")
      File.write(other, "x")
      link = File.join(dir, "zipfelkasse-20000101-000000.db")
      File.symlink(other, link)
      %w(20260101 20260102).each { |d| File.write(File.join(dir, "zipfelkasse-#{d}-000000.db"), "x") }
      Store.rotate_backups(dir, 1)
      Dir.children(dir).sort.should eq ["elsewhere.db", "zipfelkasse-20000101-000000.db", "zipfelkasse-20260102-000000.db"]
    end
  end
end
