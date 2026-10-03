require "../spec_helper"

describe "category suggestions" do
  it "normalizes titles to keys" do
    {
      "Kaufland"          => "kaufland",
      "  KAUFLAND  Mitte" => "kaufland mitte",
      "Miete 03/24"       => "miete",
      "Bäckerei-Müller!"  => "bäckerei müller",
      "2024"              => "",
    }.each { |input, want| Web.title_key(input).should eq want }
  end

  it "learns from the recent history" do
    food, dining, home = 1_i64, 2_i64, 3_i64
    hist = [] of Store::TitleCategory # newest first
    add = ->(title : String, cat : Int64, n : Int32) { n.times { hist << Store::TitleCategory.new(title, cat) } }
    add.call("Kaufland", food, 2)
    add.call("kaufland", dining, 1) # outlier
    add.call("Kaufland", food, 3)
    add.call("DM", home, 1) # tie: the most recent one wins
    add.call("dm", food, 1)
    add.call("Aldi Süd", food, 1)
    add.call("Rewe", dining, 3) # within the window food wins 7:3 …
    add.call("Rewe", food, 7)
    add.call("Rewe", dining, 10) # … older ones beyond the window do not count

    s = Web.suggest_categories(hist)
    {"kaufland" => food, "dm" => home, "aldi süd" => food, "rewe" => food}.each do |key, want|
      s.titles[key]?.should eq want
    end
    s.titles.has_key?("aldi").should be_false
    # Every word of a title, with the support of the suggested category.
    {"kaufland" => {food, 5_i64}, "aldi" => {food, 1_i64}, "süd" => {food, 1_i64}, "rewe" => {food, 7_i64}}.each do |w, want|
      s.words[w]?.should eq want
    end

    # Ambiguous words (1:1) and filler words do not count as single words.
    words = Web.suggest_categories([
      Store::TitleCategory.new("dm", home), Store::TitleCategory.new("DM", food),
      Store::TitleCategory.new("Brot und Butter", food), Store::TitleCategory.new("Brot und Käse", food),
    ]).words
    words.has_key?("dm").should be_false
    words.has_key?("und").should be_false
    # A word counts once per title.
    Web.suggest_categories([Store::TitleCategory.new("Rewe Rewe", food)]).words["rewe"].should eq({food, 1})
  end
end
