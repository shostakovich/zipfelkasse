require "spec"
require "../src/zipfelkasse/all"

SPEC_LOG = IO::Memory.new

Spec.before_each do
  SPEC_LOG.clear
  Zipfelkasse.setup_logging(SPEC_LOG)
end
