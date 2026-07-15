defmodule DelegatedSpend.Compliance.MetaTest do
  use ExUnit.Case, async: true

  alias DelegatedSpend.Compliance.Meta

  @headers [
    {"x-forwarded-for", "203.0.113.9, 198.51.100.7"},
    {"User-Agent", "TestUA/1.0"},
    {"x-geo-country", "us"}
  ]
  @cookies %{"spend_session" => "sess-1"}

  test "trusted_hops 0 (default) uses the socket peer and ignores x-forwarded-for" do
    assert Meta.build({127, 0, 0, 1}, @headers, @cookies).ip == "127.0.0.1"
    assert Meta.build("10.0.0.9", @headers, @cookies, trusted_hops: 0).ip == "10.0.0.9"
  end

  test "trusted_hops picks the client by hop count from the right" do
    assert Meta.build({10, 0, 0, 1}, @headers, %{}, trusted_hops: 1).ip == "198.51.100.7"
    assert Meta.build({10, 0, 0, 1}, @headers, %{}, trusted_hops: 2).ip == "203.0.113.9"
  end

  test "split x-forwarded-for headers concatenate in arrival order" do
    headers = [{"x-forwarded-for", "203.0.113.9"}, {"x-forwarded-for", "198.51.100.7"}]
    assert Meta.build({10, 0, 0, 1}, headers, %{}, trusted_hops: 1).ip == "198.51.100.7"
    assert Meta.build({10, 0, 0, 1}, headers, %{}, trusted_hops: 2).ip == "203.0.113.9"
  end

  test "a chain shorter than the hop count records nil, never the proxy" do
    assert Meta.build({10, 0, 0, 1}, [], %{}, trusted_hops: 1).ip == nil
    assert Meta.build({10, 0, 0, 1}, @headers, %{}, trusted_hops: 3).ip == nil
  end

  test "garbage in the picked slot or a bad hop config records nil" do
    headers = [{"x-forwarded-for", "not-an-ip"}]
    assert Meta.build({10, 0, 0, 1}, headers, %{}, trusted_hops: 1).ip == nil
    assert Meta.build({10, 0, 0, 1}, @headers, %{}, trusted_hops: -1).ip == nil
  end

  test "ports and ipv6 brackets are stripped; bare ipv6 parses" do
    headers = [{"x-forwarded-for", "203.0.113.9:4711, [2001:db8::1]:443, 2001:db8::2"}]
    assert Meta.build({10, 0, 0, 1}, headers, %{}, trusted_hops: 1).ip == "2001:db8::2"
    assert Meta.build({10, 0, 0, 1}, headers, %{}, trusted_hops: 2).ip == "2001:db8::1"
    assert Meta.build({10, 0, 0, 1}, headers, %{}, trusted_hops: 3).ip == "203.0.113.9"
  end

  test "country comes only from the configured header, last value wins, normalized" do
    build = fn headers, opts -> Meta.build({10, 0, 0, 1}, headers, %{}, opts).country end

    assert build.(@headers, country_header: "x-geo-country") == "US"
    assert build.(@headers ++ [{"x-geo-country", "es"}], country_header: "x-geo-country") == "ES"
    # a header the edge does not manage is never read, even a plausible one
    assert build.([{"cf-ipcountry", "US"}], country_header: "x-geo-country") == nil
    assert build.(@headers, []) == nil
  end

  test "user agent and session cookie flow through, header names case-blind" do
    meta = Meta.build({10, 0, 0, 1}, @headers, @cookies)
    assert meta.user_agent == "TestUA/1.0"
    assert meta.session_id == "sess-1"

    assert Meta.build({10, 0, 0, 1}, [], %{"my_sess" => "x"}, session_cookie: "my_sess").session_id ==
             "x"

    assert Meta.build({10, 0, 0, 1}, [], nil).session_id == nil
  end
end
