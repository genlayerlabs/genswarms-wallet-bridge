defmodule DelegatedSpend.Evm.Secp256k1 do
  @moduledoc """
  Port of a production-proven pure-Elixir EVM module; do not diverge.

  secp256k1 ECDSA for the money path — no Rust NIF, no subprocess. Replaces the
  `ex_secp256k1` NIF using OTP's **built-in `:crypto`** (OpenSSL-backed, ships with
  Erlang, supports `:secp256k1`) for the security-critical EC scalar multiplications,
  plus a small, deterministic RFC-6979 layer in pure Elixir. In the genswarms spirit:
  use what the runtime gives you (`:crypto`, like the framework uses `curl`) instead
  of a heavy native dep with a platform-specific precompiled artifact.

  Why this is correct and safe to hand-write:
    * The hard part — `k·G` and `d·G` — stays inside OpenSSL via `:crypto.generate_key`
      (verified to compute plain scalar·G), so we never roll our own field/point math
      on the signing path.
    * `k` is **deterministic per RFC 6979** (HMAC-SHA256), which is strictly safer than
      a random nonce (a bad RNG → reused `k` → leaked key; that's the whole reason 6979
      exists), and it makes signatures reproducible → testable byte-for-byte against the
      canonical EIP-155 spec vector (`tests/chain/evm_signing.exs`).
    * `s` is low-s normalized (EIP-2 / anti-malleability).
  Verified identical to `ex_secp256k1.sign/2` (also RFC-6979) across random inputs.

  `recover/4` checks client signatures (including self-submit authorization
  preflight) and is pure-Elixir point recovery — the one place we do
  field/point arithmetic.
  """
  import Bitwise

  # secp256k1 domain parameters (y² = x³ + 7 over F_p, generator G, order n).
  @p 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F
  @n 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
  @gx 0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798
  @gy 0x483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8
  @half_n div(@n, 2)

  @doc "Public key `d·G` for a 32-byte private key → `0x04 ‖ X ‖ Y` (65 bytes)."
  @spec public_key(<<_::256>>) :: <<_::520>>
  def public_key(<<_::binary-size(32)>> = priv) do
    {pub, ^priv} = :crypto.generate_key(:ecdh, :secp256k1, priv)
    pub
  end

  @doc """
  Deterministic ECDSA (RFC 6979) sign of a 32-byte `digest` with a 32-byte private key.
  Returns `{r, s, recid}` — `r`/`s` as 32-byte big-endian binaries, `recid` ∈ 0..3
  (low-s normalized). Drop-in for `ex_secp256k1.sign/2`'s payload.
  """
  @spec sign(<<_::256>>, <<_::256>>) :: {binary, binary, non_neg_integer}
  def sign(<<_::binary-size(32)>> = digest, <<_::binary-size(32)>> = priv) do
    z = :binary.decode_unsigned(digest)
    d = :binary.decode_unsigned(priv)
    sign_loop(z, d, rfc6979_init(priv, digest))
  end

  @doc "Recover `0x04 ‖ X ‖ Y` from `digest`, `r`/`s` (binaries), and `recid` (pure EC)."
  @spec recover(<<_::256>>, binary, binary, non_neg_integer) :: <<_::520>>
  def recover(<<_::binary-size(32)>> = digest, r_bin, s_bin, recid) do
    r = :binary.decode_unsigned(r_bin)
    s = :binary.decode_unsigned(s_bin)
    z = :binary.decode_unsigned(digest)

    x = r + if(recid >= 2, do: @n, else: 0)
    alpha = mod(x * x * x + 7, @p)
    beta = powmod(alpha, div(@p + 1, 4), @p)
    y = if rem(beta, 2) == (recid &&& 1), do: beta, else: @p - beta

    # Q = r⁻¹ · (s·R − z·G)
    rinv = powmod(r, @n - 2, @n)
    sr = mul(s, {x, y})
    zg = mul(z, {@gx, @gy})
    {qx, qy} = mul(rinv, add(sr, negate(zg)))
    <<4, qx::256, qy::256>>
  end

  # ── RFC 6979 deterministic nonce (HMAC-SHA256) ──────────────────────────────────
  defp rfc6979_init(priv, digest) do
    h1 = bits2octets(digest)
    v0 = :binary.copy(<<1>>, 32)
    k0 = :binary.copy(<<0>>, 32)
    k1 = hmac(k0, v0 <> <<0>> <> priv <> h1)
    v1 = hmac(k1, v0)
    k2 = hmac(k1, v1 <> <<1>> <> priv <> h1)
    v2 = hmac(k2, v1)
    {k2, v2}
  end

  defp sign_loop(z, d, {k, v}) do
    v = hmac(k, v)
    cand = :binary.decode_unsigned(v)

    case try_sign(cand, z, d) do
      {:ok, r, s, recid} -> {pad32(r), pad32(s), recid}
      :retry -> sign_loop(z, d, {hmac(k, v <> <<0>>), hmac(k, v)})
    end
  end

  defp try_sign(k, _z, _d) when k < 1 or k >= @n, do: :retry

  defp try_sign(k, z, d) do
    {pub, _} = :crypto.generate_key(:ecdh, :secp256k1, <<k::256>>)
    <<4, rx::256, ry::256>> = pub
    r = mod(rx, @n)

    if r == 0 do
      :retry
    else
      s = mod(powmod(k, @n - 2, @n) * (z + r * d), @n)
      recid = (ry &&& 1) ||| if(rx >= @n, do: 2, else: 0)

      cond do
        s == 0 -> :retry
        s > @half_n -> {:ok, r, @n - s, bxor(recid, 1)}
        true -> {:ok, r, s, recid}
      end
    end
  end

  # bits2int for a 256-bit hash is the integer itself; bits2octets reduces mod n.
  defp bits2octets(digest) do
    z = :binary.decode_unsigned(digest)
    z = if z >= @n, do: z - @n, else: z
    <<z::256>>
  end

  defp hmac(key, data), do: :crypto.mac(:hmac, :sha256, key, data)

  # ── pure-Elixir affine EC point math (recover only) ─────────────────────────────
  defp add(:inf, q), do: q
  defp add(p, :inf), do: p

  defp add({x1, y1}, {x2, y2}) do
    cond do
      x1 == x2 and mod(y1 + y2, @p) == 0 -> :inf
      x1 == x2 and y1 == y2 -> double({x1, y1})
      true -> chord({x1, y1}, {x2, y2})
    end
  end

  defp chord({x1, y1}, {x2, y2}) do
    m = mod((y2 - y1) * powmod(mod(x2 - x1, @p), @p - 2, @p), @p)
    x3 = mod(m * m - x1 - x2, @p)
    {x3, mod(m * (x1 - x3) - y1, @p)}
  end

  defp double({x, y}) do
    m = mod(3 * x * x * powmod(mod(2 * y, @p), @p - 2, @p), @p)
    x3 = mod(m * m - 2 * x, @p)
    {x3, mod(m * (x - x3) - y, @p)}
  end

  defp negate({x, y}), do: {x, mod(-y, @p)}

  defp mul(k, point), do: mul(k, point, :inf)
  defp mul(0, _point, acc), do: acc

  defp mul(k, point, acc) do
    acc = if (k &&& 1) == 1, do: add(acc, point), else: acc
    mul(k >>> 1, double(point), acc)
  end

  defp powmod(b, e, m), do: :crypto.mod_pow(b, e, m) |> :binary.decode_unsigned()
  defp mod(a, m), do: Integer.mod(a, m)
  defp pad32(n), do: <<n::256>>
end
