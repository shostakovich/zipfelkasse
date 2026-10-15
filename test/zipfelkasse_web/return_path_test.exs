defmodule ZipfelkasseWeb.ReturnPathTest do
  use ExUnit.Case, async: true

  alias ZipfelkasseWeb.ReturnPath

  for {target, safe} <- [
        {"/activity", "/activity"},
        {"/balances?x=1#a", "/balances?x=1#a"},
        {"/expenses/new?from=%2F", "/expenses/new?from=%2F"},
        {"", "/"},
        {nil, "/"},
        {"//evil.example", "/"},
        {"https://evil.example", "/"},
        {"evil", "/"},
        {"javascript:alert(1)", "/"},
        {"/\\evil", "/"},
        {"/a\\b", "/"},
        {"/%09/evil.example/x", "/"},
        {"/\t/evil.example/x", "/"},
        {"/\r\n/evil.example", "/"},
        {"/x\u0085y", "/"},
        {"/%2F/evil.example", "/"},
        {"/%zz", "/"},
        {"/a#%z", "/"},
        {"/%FF", "/"},
        {"/who", "/"},
        {"/who?return_to=/", "/"},
        {"/whoever", "/"},
        {"/who/new", "/"},
        {"/%77ho", "/"}
      ] do
    test "#{inspect(target)} goes to #{safe}" do
      assert ReturnPath.safe(unquote(target)) == unquote(safe)
    end
  end
end
