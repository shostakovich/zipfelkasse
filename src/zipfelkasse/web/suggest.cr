require "json"

module Zipfelkasse::Web
  # Newer habits win after a few expenses; single outliers do not matter.
  SUGGEST_WINDOW = 10

  FILLER_WORDS = Set{"und", "oder", "für", "mit", "ohne", "bei", "von", "vom", "zu", "zum", "zur", "in", "im",
                     "an", "am", "auf", "aus", "nach", "über", "der", "die", "das", "den", "dem", "des", "ein",
                     "eine", "einen", "einem", "einer"}

  # expense-form.js looks up the title key in `titles`, otherwise the word of
  # the title with the most support in `words`.
  record CategorySuggestions,
    titles : Hash(String, Int64),
    words : Hash(String, {Int64, Int64}) do
    include JSON::Serializable

    @[JSON::Field(key: "t")]
    @titles : Hash(String, Int64)
    @[JSON::Field(key: "w")]
    @words : Hash(String, {Int64, Int64})
  end

  # hist is newest first; per key the most frequent of the recent categories
  # wins, on ties the most recent one.
  def self.suggest_categories(hist : Array(Store::TitleCategory)) : CategorySuggestions
    titles = Hash(String, Array(Int64)).new { |h, k| h[k] = [] of Int64 }
    words = Hash(String, Array(Int64)).new { |h, k| h[k] = [] of Int64 }
    add = ->(m : Hash(String, Array(Int64)), key : String, cat : Int64) do
      m[key] << cat if !key.empty? && m[key].size < SUGGEST_WINDOW
    end
    hist.each do |h|
      key = title_key(h.title)
      add.call(titles, key, h.category_id)
      key.split(' ', remove_empty: true).uniq!.each do |w|
        add.call(words, w, h.category_id) unless FILLER_WORDS.includes?(w)
      end
    end
    suggestions = CategorySuggestions.new({} of String => Int64, {} of String => {Int64, Int64})
    titles.each { |key, cats| suggestions.titles[key] = majority(cats)[0] }
    # A single word needs a clear majority (two thirds), so ambiguous words
    # ("dm": household or groceries) suggest nothing.
    words.each do |w, cats|
      cat, n = majority(cats)
      suggestions.words[w] = {cat, n.to_i64} if 3 * n >= 2 * cats.size
    end
    suggestions
  end

  private def self.majority(cats : Array(Int64)) : {Int64, Int32}
    count = cats.tally
    best = cats[0]
    cats.each { |c| best = c if count[c] > count[best] }
    {best, count[best]}
  end

  # Must match titleKey in expense-form.js.
  def self.title_key(title : String) : String
    title.downcase.scan(/\p{L}+/).join(" ", &.[0])
  end
end
