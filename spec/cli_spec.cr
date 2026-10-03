require "./spec_helper"

describe CLI do
  describe ".health_url" do
    {
      ""               => "http://127.0.0.1:8080/healthz",
      ":8080"          => "http://127.0.0.1:8080/healthz",
      "0.0.0.0:9000"   => "http://127.0.0.1:9000/healthz",
      "[::]:9000"      => "http://127.0.0.1:9000/healthz",
      "127.0.0.1:8081" => "http://127.0.0.1:8081/healthz",
    }.each do |address, url|
      it "checks #{url} for the address #{address.inspect}" do
        CLI.health_url(address).should eq url
      end
    end

    it "rejects an address without a port" do
      expect_raises(Exception) { CLI.health_url("broken") }
    end
  end

  it "drops connections that stall reading or writing" do
    server = CLI::TimeoutServer.new("127.0.0.1", 0)
    client = TCPSocket.new("127.0.0.1", server.local_address.port)
    connection = server.accept?.not_nil!

    {connection.read_timeout, connection.write_timeout}.should eq({30.seconds, 60.seconds})
  ensure
    connection.try &.close
    client.try &.close
    server.try &.close
  end
end
