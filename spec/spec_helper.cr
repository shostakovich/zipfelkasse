require "spec"
require "file_utils"
require "../src/zipfelkasse/all"

alias App = Zipfelkasse::App
alias CLI = Zipfelkasse::CLI
alias Config = Zipfelkasse::Config
alias Domain = Zipfelkasse::Domain
alias Export = Zipfelkasse::Export
alias FX = Zipfelkasse::FX
alias MCP = Zipfelkasse::MCP
alias Recurring = Zipfelkasse::Recurring
alias Stopper = Zipfelkasse::Stopper
alias Store = Zipfelkasse::Store
alias Web = Zipfelkasse::Web
alias YNAB = Zipfelkasse::YNAB

require "./support/*"

SPEC_LOG = IO::Memory.new

Spec.before_each do
  SPEC_LOG.clear
  Zipfelkasse.setup_logging(SPEC_LOG)
end
