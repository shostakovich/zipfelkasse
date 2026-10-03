# Compile-time program behind `Zipfelkasse::Web.template`: turns an ECR file
# into Crystal code, like the standard ECR, with two differences:
#
# * `<%= x %>` is HTML-escaped (`Zipfelkasse::Web::HTML.write`); raw output
#   only with `<%== x %>` or values of type `Web::SafeHTML`.
# * `<%-` and `-%>` trim *all* whitespace before or after the tag (newlines
#   included).
#
# Usage (by the compiler): crystal run ecr_process.cr -- <file> <io name>
require "ecr/lexer"

filename = ARGV[0]
io_name = ARGV[1]

lexer = ECR::Lexer.new(File.read(filename))
tokens = [] of {ECR::Lexer::Token::Type, String, Int32, Int32, Bool, Bool}
loop do
  t = lexer.next_token
  break if t.type.eof?
  tokens << {t.type, t.value, t.line_number, t.column_number, t.suppress_leading?, t.suppress_trailing?}
end

WS = {' ', '\t', '\n', '\r'}

# Apply the trimming to the neighbouring text tokens.
tokens.each_with_index do |(kind, value, line, col, lead, trail), i|
  next if kind.string?
  if lead && i > 0 && tokens[i - 1][0].string?
    prev = tokens[i - 1]
    tokens[i - 1] = {prev[0], prev[1].rstrip { |c| WS.includes?(c) }, prev[2], prev[3], prev[4], prev[5]}
  end
  if trail && i + 1 < tokens.size && tokens[i + 1][0].string?
    nxt = tokens[i + 1]
    tokens[i + 1] = {nxt[0], nxt[1].lstrip { |c| WS.includes?(c) }, nxt[2], nxt[3], nxt[4], nxt[5]}
  end
end

loc = ->(line : Int32, col : Int32) { "#<loc:#{filename.inspect},#{line},#{col}>" }

code = String.build do |str|
  tokens.each do |kind, value, line, col, _, _|
    case kind
    when .string?
      next if value.empty?
      str << io_name << " << " << value.inspect << '\n'
    when .output?
      if value.starts_with?('=')
        str << "#<loc:push>(" << loc.call(line, col) << value[1..] << ")#<loc:pop>.to_s " << io_name << '\n'
      else
        str << "::Zipfelkasse::Web::HTML.write(" << io_name << ", (#<loc:push>" << loc.call(line, col) << value << "#<loc:pop>))\n"
      end
    when .control?
      str << "#<loc:push>" << loc.call(line, col) << ' ' << value << "#<loc:pop>\n"
    end
  end
end

print code
