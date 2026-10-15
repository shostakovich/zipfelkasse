defmodule Zipfelkasse.HTTP do
  @moduledoc """
  Requests to outside services over OTP's `:httpc`, with certificate and host name checks, a
  deadline for the whole response, a cap on the body and without following redirects.
  """

  @connect_timeout 15_000
  @max_body 32 * 1024 * 1024

  @doc """
  GETs `url` with `headers` (`{name, value}` strings) and returns the status and body.
  Options: `:timeout` for the whole response in milliseconds (60 s) and `:max_body` in bytes
  (32 MiB). Errors: `:timeout`, `:too_large` or the reason `:httpc` gives.
  """
  @spec get(String.t(), [{String.t(), String.t()}], keyword()) ::
          {:ok, pos_integer(), binary()} | {:error, term()}
  def get(url, headers \\ [], opts \\ []) do
    with {:ok, status, _headers, body} <- request(:get, url, headers, nil, opts),
         do: {:ok, status, body}
  end

  @doc """
  Sends a `:get`, `:post`, `:patch` or `:delete` request with `headers` and, unless nil, `body`
  as JSON. Returns the status, the response headers (names in lower case) and the body; options
  and errors as `get/3`.
  """
  @spec request(atom(), String.t(), [{String.t(), String.t()}], term(), keyword()) ::
          {:ok, pos_integer(), [{String.t(), String.t()}], binary()} | {:error, term()}
  def request(method, url, headers, body \\ nil, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 60_000)
    deadline = System.monotonic_time(:millisecond) + timeout
    uri = URI.new!(url)

    http_options = [
      timeout: timeout,
      connect_timeout: min(@connect_timeout, timeout),
      autoredirect: false,
      ssl: ssl_options(uri.host)
    ]

    headers = Enum.map(headers, &charlists/1)

    request =
      if is_nil(body),
        do: {String.to_charlist(url), headers},
        else: {String.to_charlist(url), headers, ~c"application/json", JSON.encode!(body)}

    case :httpc.request(method, request, http_options,
           sync: false,
           stream: :self,
           body_format: :binary
         ) do
      {:ok, ref} ->
        receive_response(ref, deadline, Keyword.get(opts, :max_body, @max_body), [], [])

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp receive_response(ref, deadline, max_body, headers, chunks) do
    receive do
      {:http, {^ref, :stream_start, headers}} ->
        receive_response(ref, deadline, max_body, headers, chunks)

      {:http, {^ref, :stream, chunk}} ->
        if byte_size(chunk) > max_body do
          cancel(ref)
          {:error, :too_large}
        else
          receive_response(ref, deadline, max_body - byte_size(chunk), headers, [chunks | chunk])
        end

      {:http, {^ref, :stream_end, _headers}} ->
        {:ok, 200, strings(headers), IO.iodata_to_binary(chunks)}

      {:http, {^ref, {{_version, status, _reason}, headers, body}}} ->
        {:ok, status, strings(headers), body}

      {:http, {^ref, {:error, reason}}} ->
        {:error, reason}
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        cancel(ref)
        {:error, :timeout}
    end
  end

  defp strings(headers),
    do:
      Enum.map(headers, fn {name, value} ->
        {name |> to_string() |> String.downcase(), to_string(value)}
      end)

  defp cancel(ref) do
    :httpc.cancel_request(ref)
    flush(ref)
  end

  defp flush(ref) do
    receive do
      {:http, {^ref, _message}} -> flush(ref)
      {:http, {^ref, _event, _data}} -> flush(ref)
    after
      0 -> :ok
    end
  end

  defp charlists({name, value}), do: {String.to_charlist(name), String.to_charlist(value)}

  defp ssl_options(host) do
    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      server_name_indication: String.to_charlist(host),
      depth: 99,
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]
  end
end
