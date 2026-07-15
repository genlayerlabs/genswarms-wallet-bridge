defmodule DelegatedSpend.Compliance.Meta do
  @moduledoc """
  Builds the app-attested request metadata the three-arity intake handlers
  take, doing the two edge-trust steps that are easy to get wrong once:

    * The client IP is picked from `x-forwarded-for` by hop count. With
      `trusted_hops: n` reverse proxies in front of the listener, the client
      is entry `n + 1` counting backwards from the socket peer; entries
      further left are client-supplied noise. `trusted_hops: 0` (default)
      ignores the spoofable header entirely and uses the socket peer. A chain
      shorter than the hop count yields `ip: nil` — honest missing evidence
      beats recording the proxy's own address.
    * The country is read ONLY from the header named in `country_header` —
      one the TRUSTED EDGE sets or overwrites (`"cf-ipcountry"` behind
      Cloudflare; a GeoIP header your own Caddy/nginx sets otherwise). When
      several values arrive the last one wins (appended nearest the origin);
      no option or no header means `country: nil`, which the geofence denies.

  Pure data in (`conn.remote_ip`, `conn.req_headers`, `conn.req_cookies`),
  normalized meta out — no Plug dependency.
  """

  alias DelegatedSpend.Compliance.Store

  @doc """
  Build normalized handler meta from connection data.

  Options: `trusted_hops` (default 0), `country_header` (default none),
  `session_cookie` (default `"spend_session"`).
  """
  def build(remote_ip, headers, cookies, opts \\ []) when is_list(headers) do
    headers = Enum.map(headers, fn {name, value} -> {String.downcase(name), value} end)

    Store.normalize_meta(%{
      ip: client_ip(remote_ip, headers, Keyword.get(opts, :trusted_hops, 0)),
      country: country(headers, Keyword.get(opts, :country_header)),
      user_agent: headers |> header_values("user-agent") |> List.first(),
      session_id: session_id(cookies, Keyword.get(opts, :session_cookie, "spend_session"))
    })
  end

  defp client_ip(remote_ip, headers, trusted_hops)
       when is_integer(trusted_hops) and trusted_hops >= 0 do
    chain = forwarded_chain(headers) ++ [remote_ip]

    # Right to left: positions 1..trusted_hops are the proxies we operate;
    # the client is the next entry. Enum.at/2 with a negative index past the
    # head returns nil — a chain shorter than expected records no IP.
    chain |> Enum.at(-(trusted_hops + 1)) |> parse_ip()
  end

  defp client_ip(_remote_ip, _headers, _bad_hops), do: nil

  defp forwarded_chain(headers) do
    for value <- header_values(headers, "x-forwarded-for"),
        entry <- String.split(value, ","),
        entry = String.trim(entry),
        entry != "",
        do: entry
  end

  defp parse_ip(ip) when is_tuple(ip) do
    case :inet.ntoa(ip) do
      {:error, _} -> nil
      chars -> to_string(chars)
    end
  end

  defp parse_ip(entry) when is_binary(entry) do
    case entry |> strip_port() |> to_charlist() |> :inet.parse_strict_address() do
      {:ok, addr} -> addr |> :inet.ntoa() |> to_string()
      {:error, _} -> nil
    end
  end

  defp parse_ip(_), do: nil

  # "[2001:db8::1]:443" → "2001:db8::1"; "1.2.3.4:8080" → "1.2.3.4";
  # bare IPv6 (many colons) and bare IPv4 pass through untouched.
  defp strip_port(entry) do
    case Regex.run(~r/^\[([^\]]+)\](?::\d+)?$/, entry) do
      [_, inner] ->
        inner

      nil ->
        case String.split(entry, ":") do
          [host, port] -> if Regex.match?(~r/^\d+$/, port), do: host, else: entry
          _ -> entry
        end
    end
  end

  defp country(_headers, nil), do: nil

  defp country(headers, header_name) when is_binary(header_name),
    do: headers |> header_values(String.downcase(header_name)) |> List.last()

  defp header_values(headers, name), do: for({^name, value} <- headers, do: value)

  defp session_id(cookies, name) when is_map(cookies), do: Map.get(cookies, name)
  defp session_id(_cookies, _name), do: nil
end
