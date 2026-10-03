require "../spec_helper"
require "http/client"

FELT_CSS_URL = URI.parse("https://felt-css.rocu.de/felt.css")

# Classes that neither felt.css nor app.css styles: hooks for scripts and
# tests, and names that only label the structure (activity-time, balances,
# expense, expense-amount, expense-group, expense-main, row-actions, search,
# split-rows, split-sum).
HOOK_CLASSES = %w(
  activity-group activity-item activity-main activity-time balances changes empty
  expense expense-amount expense-chevron expense-group expense-main expense-meta expense-side expense-title
  link-list list-group-label list-more my-balance-amount reimbursement row-actions row-meta
  search split-row split-rows split-sum transfer whoami
).to_set

# Classes the Crystal helpers put into the markup (`icon`, `sign_class`).
HELPER_CLASSES = %w(icon text-success text-danger).to_set

# Class tokens of the `class="…"` attributes in the templates. ERB control
# tags (`<% if … %> active<% end %>`) separate tokens; tokens with ERB output
# in them (`<%= sign_class … %>`) are unknown at this point and skipped.
private def template_classes : Set(String)
  Dir.glob("#{__DIR__}/../../src/views/**/*.ecr").each_with_object(Set(String).new) do |path, classes|
    File.read(path).scan(/class="((?:<%.*?%>|[^"])*)"/m) do |match|
      value = match[1].gsub(/<%=.*?%>/m, "\0").gsub(/<%.*?%>/m, " ")
      value.split.each { |token| classes << token unless token.includes?('\0') }
    end
  end
end

describe Web::Static do
  it "styles every class the templates use" do
    felt = begin
      client = HTTP::Client.new(FELT_CSS_URL)
      client.connect_timeout = client.read_timeout = 10.seconds
      response = client.get(FELT_CSS_URL.request_target)
      raise "HTTP #{response.status_code}" unless response.success?
      response.body
    rescue ex
      pending!("#{FELT_CSS_URL} not reachable (#{ex.message})")
    end
    css = felt + String.new(Web::Static::FILES["app.css"])
    defined = css.scan(/\.(-?[_a-zA-Z][\w-]*)/).map(&.[1]).to_set
    used = template_classes + HELPER_CLASSES
    used.size.should be > 50
    (used - defined - HOOK_CLASSES).to_a.sort.should eq [] of String
    (HOOK_CLASSES - (used - defined)).to_a.sort.should eq [] of String # stale entries of HOOK_CLASSES
  end
end
