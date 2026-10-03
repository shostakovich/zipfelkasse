require "./e2e_helper"

# Builds the shared test household (see E2E::Seed) and keeps the database of
# the binary under test as e2e/data/seed.db for the read-only comparison.
describe "Seed" do
  world = E2E::World.new("seed", now: E2E::Seed::PHASE_A)
  after_all { world.stop }

  scenario "builds a household with every feature", world do
    seed = E2E::Seed.new(world).run
    seed.expenses.size.should be > 500
    world.save(File.join(E2E.data_dir, "seed.db"))
  end
end
