require "./e2e_helper"

describe "Process: shutdown" do
  world = E2E::World.new("shutdown")
  after_all { world.stop }

  {Signal::TERM, Signal::INT}.each do |signal|
    scenario "#{signal} stops the server with exit code 0 and a consistent database", world do
      user = world.user
      user.login("Anna").status.should eq 303
      before = E2E::Database.count(world.app.db_path, "SELECT count(*) FROM participants")
      shutdowns = world.app.log.scan("shutting down").size

      status = world.app.stop(signal).not_nil!
      begin
        {status.success?, status.exit_code}.should eq({true, 0})
        world.app.log.scan("shutting down").size.should eq shutdowns + 1
        world.app.healthy?.should be_false
        (File.info?(world.app.db_path + "-wal").try(&.size) || 0).should eq 0
        E2E::Database.open(world.app.db_path) do |db|
          db.scalar("PRAGMA integrity_check").should eq "ok"
          db.scalar("SELECT count(*) FROM participants").should eq before
        end
      ensure
        world.app.start
      end
    end
  end
end

describe "Process: startup errors" do
  world = E2E::World.new("startup-errors")
  after_all { world.stop }

  refused = ->(env : Hash(String, String)) do
    status, output = world.new_app(env).run_to_exit
    output.should_not contain "Unhandled exception"
    {status.exit_code, output}
  end

  scenario "invalid settings are named and nothing is started", world do
    {
      "MCP_ALLOWED_CIDRS" => "not-an-address",
      "TRUSTED_PROXIES"   => "10.0.0.0/33",
      "TZ"                => "Mars/Olympus",
    }.each do |name, value|
      app = world.new_app({name => value})
      status, output = app.run_to_exit
      {name, status.exit_code, output.includes?(name)}.should eq({name, 1, true})
      output.should_not contain "Unhandled exception"
      File.exists?(app.db_path).should be_false
    end
  end

  scenario "an address without a port is refused", world do
    code, output = refused.call({"ZIPFELKASSE_ADDR" => "nonsense"})
    {code, output.includes?("nonsense")}.should eq({1, true})
  end

  scenario "a port in use is refused and named", world do
    taken = TCPServer.new("127.0.0.1", 0)
    begin
      addr = "127.0.0.1:#{taken.local_address.port}"
      code, output = refused.call({"ZIPFELKASSE_ADDR" => addr})
      {code, output.includes?(addr)}.should eq({1, true})
    ensure
      taken.close
    end
  end

  scenario "a database that cannot be created is refused and named", world do
    blocker = File.join(E2E.worlds_dir, "not-a-directory")
    File.write(blocker, "")
    db = File.join(blocker, "zipfelkasse.db")
    code, output = refused.call({"ZIPFELKASSE_DB" => db})
    {code, output.includes?(db)}.should eq({1, true})
  end

  scenario "an unknown subcommand prints the usage and exits with 2", world do
    output = IO::Memory.new
    status = Process.run(E2E.bin, ["frobnicate"], output: output, error: output)
    {status.exit_code, output.to_s.includes?("frobnicate"), output.to_s.includes?("usage")}.should eq({2, true, true})
  end
end

describe "Process: nightly backup" do
  pending "writes a backup shortly after 03:00 and keeps the last seven (the loop ignores the frozen clock)" do
    world = E2E::World.new("backup", now: "2026-10-03T00:59:55Z")
    begin
      user = world.user
      user.login("Anna").status.should eq 303
      dir = File.join(world.app.dir, "backups")
      Dir.mkdir_p(dir)
      (1..8).each { |n| File.write(File.join(dir, "zipfelkasse-2026010#{n}-030000.db"), "") }

      E2E.wait_until("nightly backup", 10.seconds) { Dir.children(dir).any?(&.starts_with?("zipfelkasse-20261003-")) }
      world.app.log.should contain "backup written"
      Dir.children(dir).size.should eq 7
      newest = File.join(dir, Dir.children(dir).max)
      E2E::Database.count(newest, "SELECT count(*) FROM participants").should eq 1
    ensure
      world.stop
    end
  end
end
