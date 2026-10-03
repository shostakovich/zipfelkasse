require "spec"
require "./support/*"

# Defines an example that checks, after the block, that no page contained
# injected scripts.
macro scenario(name, world, &block)
  it {{name}} do
    begin
      {{block.body}}
    rescue ex
      {{world}}.discard
      raise ex
    end
    {{world}}.verify!
  end
end
