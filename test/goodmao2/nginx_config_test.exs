defmodule Goodmao2.NginxConfigTest do
  @moduledoc """
  Holds the nginx config to the rules the application relies on, in both places it is written:
  the Ansible template production runs, and the hand-deploy example in `doc/deployment.md` an
  operator copies. The example had drifted from the template in exactly these ways.

  - `UserAuth.client_ip/1` trusts the first `X-Forwarded-For` address, which is only the peer
    when nginx *sets* the header. Appending keeps whatever the client sent.
  - Magic-link, email-confirmation and share URLs carry bearer tokens in the path, so the
    access log must use the redacting format (CLAUDE.md: "nginx redacts them").
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)
  @template Path.join(@root, "ansible/roles/nginx/templates/goodmao2.conf.j2")
  @deployment_doc Path.join(@root, "doc/deployment.md")

  defp configs do
    [_, example] = Regex.run(~r/```nginx\n(.*?)```/s, File.read!(@deployment_doc))
    [template: File.read!(@template), deployment_example: example]
  end

  test "every proxied location sets X-Forwarded-For to the peer, never appends" do
    for {name, config} <- configs() do
      refute config =~ "$proxy_add_x_forwarded_for", "#{name} appends X-Forwarded-For"

      proxied = length(Regex.scan(~r/^\s*proxy_pass\s/m, config))

      set =
        length(Regex.scan(~r/^\s*proxy_set_header\s+X-Forwarded-For\s+\$remote_addr;/m, config))

      assert proxied > 0, "#{name} proxies nothing"
      assert set == proxied, "#{name}: #{proxied} proxied locations, #{set} set X-Forwarded-For"
    end
  end

  test "the access log redacts every token-bearing path" do
    for {name, config} <- configs() do
      assert config =~ ~r/access_log\s+\S+\s+goodmao2_redacted;/,
             "#{name} logs without the redacting format"

      for path <- ~w(users/log-in users/settings/confirm-email entries/shared reports/shared) do
        # Once in the request-URI map, once in the Referer map.
        assert length(String.split(config, path)) - 1 >= 2,
               "#{name} doesn't redact /#{path}/ in both the path and the Referer"
      end
    end
  end
end
