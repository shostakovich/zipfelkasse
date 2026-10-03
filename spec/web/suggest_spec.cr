require "../spec_helper"

# The expenses, newest first, as {title, category, times}.
private def history(*entries : {String, Int64, Int32}) : Array(Store::TitleCategory)
  entries.flat_map { |title, category, times| Array.new(times) { Store::TitleCategory.new(title, category) } }.to_a
end

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
    it "suggests the category a title was used with most often, regardless of its case, and ignores an outlier" do
      suggestions = Web.suggest_categories(history({"Kaufland", food, 2}, {"kaufland", dining, 1}, {"Kaufland", food, 3}))

      suggestions.titles["kaufland"]?.should eq food
    end

    it "suggests the most recent category on a tie" do
      suggestions = Web.suggest_categories(history({"DM", home, 1}, {"dm", food, 1}))

      suggestions.titles["dm"]?.should eq home
    end

    it "counts only the recent history" do
      suggestions = Web.suggest_categories(history({"Rewe", dining, 3}, {"Rewe", food, 7}, {"Rewe", dining, 10}))

      suggestions.titles["rewe"]?.should eq food
    end

    it "does not suggest a category for a part of a title" do
      Web.suggest_categories(history({"Aldi Süd", food, 1})).titles.has_key?("aldi").should be_false
    end

    it "suggests a category for every word of a title, with the support of the category" do
      suggestions = Web.suggest_categories(history({"Kaufland", food, 5}, {"Aldi Süd", food, 1}))

      {"kaufland" => {food, 5_i64}, "aldi" => {food, 1_i64}, "süd" => {food, 1_i64}}.each do |word, support|
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
