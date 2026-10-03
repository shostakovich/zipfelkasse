# Compile-time program behind `Zipfelkasse::Web.template`: turns an ECR file
# into Crystal code like the standard ECR, except that `<%= x %>` is
# HTML-escaped (`Zipfelkasse::Web::HTML.write`); raw output only with
# `<%== x %>`. It is run by the compiler: crystal run ecr_process.cr -- <file> <io name>
require "ecr/lexer"

record Token, type : ECR::Lexer::Token::Type, value : String, line : Int32, column : Int32, leading : Bool, trailing : Bool

filename = ARGV[0]
io_name = ARGV[1]

lexer = ECR::Lexer.new(File.read(filename))
tokens = [] of Token
loop do
  t = lexer.next_token
  break if t.type.eof?
  tokens << Token.new(t.type, t.value, t.line_number, t.column_number, t.suppress_leading?, t.suppress_trailing?)
end

code = String.build do |str|
  tokens.each_with_index do |token, i|
    previous = tokens[i - 1]? if i > 0
    nxt = tokens[i + 1]?
    case token.type
    when .string?
      text = token.value
      text = text.partition('\n')[2] if previous && previous.trailing && text.includes?('\n')
      text = text.rstrip(" \t") if nxt && nxt.leading && text.rpartition('\n')[2].blank?
      str << io_name << " << " << text.inspect << '\n' unless text.empty?
    when .output?
      location = "#<loc:#{filename.inspect},#{token.line},#{token.column}>"
      if token.value.starts_with?('=')
        str << "#<loc:push>(" << location << token.value[1..] << ")#<loc:pop>.to_s " << io_name << '\n'
      else
        str << "::Zipfelkasse::Web::HTML.write(" << io_name << ", (#<loc:push>" << location << token.value << "#<loc:pop>))\n"
      end
    when .control?
      str << "#<loc:push>#<loc:#{filename.inspect},#{token.line},#{token.column}> " << token.value << "#<loc:pop>\n"
    end
  end
end

print code
