require "../spec_helper"

describe "category suggestions" do
  food, dining, home = 1_i64, 2_i64, 3_i64

  describe "title keys" do
    {
      "Kaufland" => "kaufland", "  KAUFLAND  Mitte" => "kaufland mitte", "Miete 03/24" => "miete",
      "Bäckerei-Müller!" => "bäckerei müller", "2024" => "",
    }.each do |title, key|
      it "turns #{title.inspect} into #{key.inspect}" do
        Web.title_key(title).should eq key
      end
    end
  end

  describe "learning from the recent history" do
    suggestions = Web.suggest_categories([] of Store::TitleCategory)

    before_each do
      history = [] of Store::TitleCategory # newest first
      add = ->(title : String, category : Int64, times : Int32) { times.times { history << Store::TitleCategory.new(title, category) } }
      add.call("Kaufland", food, 2)
      add.call("kaufland", dining, 1) # an outlier
      add.call("Kaufland", food, 3)
      add.call("DM", home, 1) # a tie: the most recent one wins
      add.call("dm", food, 1)
      add.call("Aldi Süd", food, 1)
      add.call("Rewe", dining, 3) # within the window food wins 7:3 ...
      add.call("Rewe", food, 7)
      add.call("Rewe", dining, 10) # ... older ones beyond the window do not count
      suggestions = Web.suggest_categories(history)
    end

    {"kaufland" => 1_i64, "dm" => 3_i64, "aldi süd" => 1_i64, "rewe" => 1_i64}.each do |key, category|
      it "suggests category #{category} for the title #{key.inspect}" do
        suggestions.titles[key]?.should eq category
      end
    end

    it "does not suggest a category for a part of a title" do
      suggestions.titles.has_key?("aldi").should be_false
    end

    it "suggests a category for every word of a title, with the support of the category" do
      {"kaufland" => {food, 5_i64}, "aldi" => {food, 1_i64}, "süd" => {food, 1_i64}, "rewe" => {food, 7_i64}}.each do |word, support|
        suggestions.words[word]?.should eq support
      end
    end
  end

  it "makes no suggestion for an ambiguous word or a filler word" do
    words = Web.suggest_categories([
      Store::TitleCategory.new("dm", home), Store::TitleCategory.new("DM", food),
      Store::TitleCategory.new("Brot und Butter", food), Store::TitleCategory.new("Brot und Käse", food),
    ]).words

    words.has_key?("dm").should be_false
    words.has_key?("und").should be_false
  end

  it "counts a word once per title" do
    Web.suggest_categories([Store::TitleCategory.new("Rewe Rewe", food)]).words["rewe"].should eq({food, 1})
  end
end
