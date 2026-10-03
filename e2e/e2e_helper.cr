require "spec"
require "./support/*"

# An example that fails afterwards if a page contained injected scripts or the
# app logged an error. *errors* lists log errors the scenario provokes on
# purpose (substrings of the log line).
macro scenario(name, world, errors = [] of String, &block)
  it {{name}} do
    begin
      {{block.body}}
    rescue ex
      {{world}}.discard
      raise ex
    end
    {{world}}.verify!({{errors}})
  end
end

Spec.after_suite do
  E2E.seeded_world.stop
  if E2E.keep_worlds?
    STDERR.puts "E2E worlds kept in #{E2E.worlds_dir}"
  else
    FileUtils.rm_rf(E2E.worlds_dir)
  end
end
