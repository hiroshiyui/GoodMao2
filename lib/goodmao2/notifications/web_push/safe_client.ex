defmodule Goodmao2.Notifications.WebPush.SafeClient do
  @moduledoc """
  SSRF-safe outbound HTTP client for Web Push delivery.

  A push `endpoint` is **browser-supplied**, so a POST to it is an SSRF vector. This module
  wraps `Req` with:

    * HTTPS only (except `localhost` in dev/test, gated by config)
    * DNS resolution with a **private/loopback/link-local IP denylist** (IPv4 and IPv6,
      including IPv4-mapped and NAT64 forms — an attacker cannot smuggle `127.0.0.1` inside
      an IPv6 address)
    * **DNS pinning**: the resolved public IP is pinned to the connection while SNI + the
      `Host` header keep the original hostname, defeating DNS-rebinding TOCTOU
    * no redirect following, and the response body is **never read**: only the status and
      headers matter, and a hostile endpoint that passes validation could otherwise stream an
      unbounded body into memory for as long as it kept sending

  Endpoints are validated at storage time (`PushSubscription.changeset/2`) *and* here at
  send time, so a value that turned private after storage is still refused.
  """
  import Bitwise

  @connect_timeout 5_000
  @receive_timeout 10_000

  # Test hooks (see config/test.exs): route Req through Req.Test stubs and skip the real DNS
  # resolution so the sandbox can intercept the outbound call.
  @req_test_options Application.compile_env(:goodmao2, [__MODULE__, :req_test_options], [])
  @bypass_ssrf Application.compile_env(:goodmao2, [__MODULE__, :bypass_ssrf_check], false)
  @allow_http_localhost Application.compile_env(
                          :goodmao2,
                          [__MODULE__, :allow_http_localhost],
                          false
                        )

  @doc """
  Validates a URL for safe outbound use.

  Returns `:ok`, or `{:error, reason}` for a non-HTTPS scheme, a missing host, a URL that
  fails to resolve, or one that resolves to a private/loopback address.
  """
  def validate_url(url) when is_binary(url) do
    case validate_and_resolve(url) do
      {:ok, _resolved} -> :ok
      {:error, _} = error -> error
    end
  end

  def validate_url(_), do: {:error, :invalid_url}

  @doc """
  POSTs `body` with `headers` to `url`, DNS-pinned and SSRF-validated.

  Returns `{:ok, status, resp_headers}` for **any** HTTP status (the caller decides what a
  given status means — e.g. 410 ⇒ prune), or `{:error, reason}` when the URL is unsafe or
  the request never completed.
  """
  def post(url, body, headers) when is_binary(url) and is_binary(body) and is_list(headers) do
    with {:ok, resolved} <- validate_and_resolve(url) do
      opts =
        resolved
        |> build_pinned_opts(headers)
        |> Keyword.put(:body, body)

      case Req.post(opts) do
        {:ok, %Req.Response{status: status, headers: resp_headers}} ->
          {:ok, status, resp_headers}

        {:error, reason} ->
          {:error, {:request_failed, reason}}
      end
    end
  end

  # Parses, validates, and resolves a URL so the caller can pin to the resolved IP.
  defp validate_and_resolve(url) when is_binary(url) do
    uri = URI.parse(url)

    with :ok <- validate_scheme(uri),
         :ok <- validate_host(uri),
         :ok <- validate_port(uri),
         {:ok, ip} <- safe_resolve_ip(uri.host) do
      {:ok, %{ip: ip, host: uri.host, uri: uri}}
    end
  end

  # Connect to the resolved IP directly; keep SNI + Host = original hostname.
  defp build_pinned_opts(resolved, headers) do
    %{ip: ip, host: host, uri: %URI{} = uri} = resolved
    ip_string = ip |> :inet.ntoa() |> to_string()
    port = uri.port || if(uri.scheme == "https", do: 443, else: 80)

    pinned_url = %URI{uri | host: ip_string, port: port} |> URI.to_string()
    headers_with_host = [{"host", host} | headers]

    base_opts = [
      url: pinned_url,
      headers: headers_with_host,
      connect_options: [
        timeout: @connect_timeout,
        # Peer verification is Mint's default, but a dependency default is not a contract:
        # state it, so a future client change cannot silently downgrade it.
        transport_opts: [
          verify: :verify_peer,
          cacerts: :public_key.cacerts_get(),
          server_name_indication: String.to_charlist(host)
        ]
      ],
      receive_timeout: @receive_timeout,
      max_redirects: 0,
      redirect: false,
      max_retries: 0,
      decode_body: false,
      # Stop at the first body chunk: the status and headers are already in hand, and nothing
      # downstream reads the body. Bounds memory to one chunk however much the endpoint sends.
      into: fn {:data, _chunk}, acc -> {:halt, acc} end
    ]

    Keyword.merge(base_opts, @req_test_options)
  end

  defp validate_scheme(%URI{scheme: "https"}), do: :ok

  defp validate_scheme(%URI{scheme: "http", host: host})
       when host in ["localhost", "127.0.0.1"] do
    if @allow_http_localhost, do: :ok, else: {:error, :https_required}
  end

  defp validate_scheme(_), do: {:error, :https_required}

  # A push service lives on 443. Honouring any port would let a browser-supplied endpoint turn
  # the server into a TLS port scanner of public hosts (the body is never read, but a connect
  # succeeding or failing is an oracle). The http-localhost test path keeps its ephemeral port.
  defp validate_port(%URI{scheme: "https", port: port}) when port in [nil, 443], do: :ok
  defp validate_port(%URI{scheme: "http"}), do: :ok
  defp validate_port(_), do: {:error, :invalid_port}

  defp validate_host(%URI{host: nil}), do: {:error, :invalid_host}
  defp validate_host(%URI{host: ""}), do: {:error, :invalid_host}
  defp validate_host(_), do: :ok

  if @bypass_ssrf do
    defp safe_resolve_ip(_host), do: {:ok, {127, 0, 0, 1}}
  else
    defp safe_resolve_ip(host) do
      case resolve_ip(host) do
        {:ok, ip} ->
          if private_ip?(ip), do: {:error, :private_ip}, else: {:ok, ip}

        {:error, _} ->
          {:error, :dns_resolution_failed}
      end
    end

    defp resolve_ip(host) do
      host_charlist = String.to_charlist(host)

      case :inet.getaddr(host_charlist, :inet) do
        {:ok, ip} -> {:ok, ip}
        {:error, _} -> :inet.getaddr(host_charlist, :inet6)
      end
    end
  end

  @doc false
  # IPv4 ranges that must never be reached from a browser-supplied endpoint.
  def private_ip?({127, _, _, _}), do: true
  def private_ip?({10, _, _, _}), do: true
  def private_ip?({172, b, _, _}) when b >= 16 and b <= 31, do: true
  def private_ip?({192, 168, _, _}), do: true
  def private_ip?({169, 254, _, _}), do: true
  def private_ip?({0, _, _, _}), do: true
  # 100.64.0.0/10 — CGNAT / shared address space (RFC 6598)
  def private_ip?({100, b, _, _}) when b >= 64 and b <= 127, do: true
  # 192.0.0.0/24 IETF protocol assignments, 192.0.2.0/24 TEST-NET-1 (RFC 6890)
  def private_ip?({192, 0, 0, _}), do: true
  def private_ip?({192, 0, 2, _}), do: true
  # 198.18.0.0/15 benchmarking (RFC 2544); 198.51.100.0/24 TEST-NET-2; 203.0.113.0/24 TEST-NET-3
  def private_ip?({198, b, _, _}) when b in [18, 19], do: true
  def private_ip?({198, 51, 100, _}), do: true
  def private_ip?({203, 0, 113, _}), do: true
  # 224.0.0.0/4 multicast and 240.0.0.0/4 reserved (covers 255.255.255.255)
  def private_ip?({a, _, _, _}) when a >= 224, do: true
  # IPv6 unspecified ::
  def private_ip?({0, 0, 0, 0, 0, 0, 0, 0}), do: true
  # IPv6 loopback ::1
  def private_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  # IPv6 fc00::/7 (unique local)
  def private_ip?({a, _, _, _, _, _, _, _}) when a >= 0xFC00 and a <= 0xFDFF, do: true
  # IPv6 fe80::/10 (link-local) and fec0::/10 (deprecated site-local)
  def private_ip?({a, _, _, _, _, _, _, _}) when a >= 0xFE80 and a <= 0xFEFF, do: true
  # 6to4 (2002::/16) embeds an IPv4 in the next 32 bits; a relay could route it into RFC 1918.
  def private_ip?({0x2002, hi, lo, _, _, _, _, _}),
    do: private_ip?({hi >>> 8, hi &&& 0xFF, lo >>> 8, lo &&& 0xFF})

  # Teredo (2001:0::/32) tunnels to an obfuscated IPv4 we cannot vet; deny the whole prefix.
  def private_ip?({0x2001, 0, _, _, _, _, _, _}), do: true
  # 64:ff9b:1::/48 local-use NAT64 (RFC 8215) — a site-private translator, deny outright.
  def private_ip?({0x64, 0xFF9B, 1, _, _, _, _, _}), do: true
  # IPv6 ff00::/8 (multicast)
  def private_ip?({a, _, _, _, _, _, _, _}) when a >= 0xFF00 and a <= 0xFFFF, do: true
  # IPv4-mapped IPv6 (::ffff:x.y.z.w) — extract embedded IPv4 and re-check.
  def private_ip?({0, 0, 0, 0, 0, 0xFFFF, hi, lo}) do
    private_ip?({hi >>> 8, hi &&& 0xFF, lo >>> 8, lo &&& 0xFF})
  end

  # NAT64 (64:ff9b::/96, RFC 6052) — extract embedded IPv4 and re-check, so a host resolving
  # to e.g. 64:ff9b::7f00:1 cannot reach 127.0.0.1 via a NAT64 gateway.
  def private_ip?({0x64, 0xFF9B, 0, 0, 0, 0, hi, lo}) do
    private_ip?({hi >>> 8, hi &&& 0xFF, lo >>> 8, lo &&& 0xFF})
  end

  # IPv4-compatible IPv6 (::a.b.c.d, deprecated) — extract embedded IPv4 and re-check.
  # After the explicit :: / ::1 clauses, so those keep their exact match.
  def private_ip?({0, 0, 0, 0, 0, 0, hi, lo}) do
    private_ip?({hi >>> 8, hi &&& 0xFF, lo >>> 8, lo &&& 0xFF})
  end

  def private_ip?(_), do: false
end
