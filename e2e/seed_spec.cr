require "./e2e_helper"

# Builds the test household (see E2E::Seed) through the app; every step
# must succeed.
describe "Seed" do
  world = E2E::World.new("seed", now: E2E::Seed::PHASE_A)
  after_all { world.stop }

  scenario "builds a household with every feature", world do
    seed = E2E::Seed.new(world).run
    seed.expenses.size.should be > 500
  end
end
