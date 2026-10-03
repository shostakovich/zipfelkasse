require "./spec_helper"

describe App do
  it "says that MCP is disabled without a secret" do
    with_server { SPEC_LOG.to_s.should contain "MCP disabled" }
  end

  it "says that MCP is enabled with a secret, but not the secret" do
    config = Config.from_env({"MCP_SECRET" => "geheim-a1b2c3", "MCP_ALLOWED_CIDRS" => "0.0.0.0/0"})

    with_server(config) do
      SPEC_LOG.to_s.should contain %(msg="MCP enabled" path=/mcp/*** allowed=[0.0.0.0/0] proxies=[])
      SPEC_LOG.to_s.should_not contain "geheim-a1b2c3"
    end
  end
end
