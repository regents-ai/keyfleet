defmodule KeyfleetWeb.ApiContractTest do
  use KeyfleetWeb.ConnCase, async: true

  @contract Path.expand("../../contracts/api-contract.openapiv3.yaml", __DIR__)
  @served_contract Application.app_dir(:keyfleet, "priv/static/api-contract.openapiv3.yaml")

  @graph "/api/v1/agent/fleets/{fleet_id}/graph/"

  test "the canonical contract declares the complete admitted browser auth surface" do
    contract = YamlElixir.read_from_file!(@contract)

    assert Map.keys(contract["paths"]) |> Enum.sort() == [
             "/api/agents/v1/me",
             "/api/agents/v1/pair",
             @graph <> "archive",
             @graph <> "changes",
             @graph <> "create",
             @graph <> "get",
             @graph <> "link",
             @graph <> "patch",
             @graph <> "unlink",
             "/api/v1/agent/fleets/{fleet_id}/proposals/read",
             "/api/v1/agent/fleets/{fleet_id}/rooms",
             "/api/v1/agent/fleets/{fleet_id}/rooms/create",
             "/api/v1/agent/fleets/{fleet_id}/rooms/{slug}/messages/read",
             "/api/v1/agent/fleets/{fleet_id}/rooms/{slug}/messages/send",
             "/api/v1/agent/fleets/{fleet_id}/rooms/{slug}/topic",
             "/api/v1/agent/fleets/{fleet_id}/sync",
             "/api/v1/agent/join/status",
             "/api/v1/agent/keys/{fleet_id}/{token_id}/messages/read",
             "/api/v1/agent/keys/{fleet_id}/{token_id}/messages/send",
             "/api/v1/agent/keys/{fleet_id}/{token_id}/pairing",
             "/api/v1/agent/keys/{fleet_id}/{token_id}/step-down",
             "/api/v1/agent/pairings",
             "/api/v1/agent/profile/update",
             "/api/v1/fleets",
             "/api/v1/fleets/{fleet_id}",
             "/api/v1/profile",
             "/api/v1/profile/sync",
             "/auth/csrf",
             "/auth/privy/failure",
             "/auth/privy/session",
             "/auth/session",
             "/metadata/{slot}/{token_id}"
           ]

    assert Map.take(contract["paths"], [
             "/auth/csrf",
             "/auth/privy/failure",
             "/auth/privy/session",
             "/auth/session"
           ]) ==
             %{
               "/auth/csrf" => %{
                 "get" => %{
                   "operationId" => "getBrowserCsrf",
                   "responses" => %{
                     "200" => %{
                       "description" => "CSRF token for browser session changes",
                       "content" => %{
                         "application/json" => %{
                           "schema" => %{
                             "type" => "object",
                             "additionalProperties" => false,
                             "required" => ["csrf_token"],
                             "properties" => %{
                               "csrf_token" => %{"type" => "string", "minLength" => 1}
                             }
                           }
                         }
                       }
                     },
                     "429" => %{
                       "description" =>
                         "Too many new browser sessions were started from the client address",
                       "headers" => %{
                         "Retry-After" => %{
                           "schema" => %{"type" => "string", "const" => "300"}
                         },
                         "Cache-Control" => %{
                           "schema" => %{"type" => "string", "const" => "no-store"}
                         }
                       },
                       "content" => %{
                         "application/json" => %{
                           "schema" => %{
                             "type" => "object",
                             "additionalProperties" => false,
                             "required" => ["error"],
                             "properties" => %{
                               "error" => %{
                                 "type" => "object",
                                 "additionalProperties" => false,
                                 "required" => ["code", "message", "hint"],
                                 "properties" => %{
                                   "code" => %{"type" => "string", "const" => "rate_limited"},
                                   "message" => %{"type" => "string"},
                                   "hint" => %{"type" => "string"}
                                 }
                               }
                             }
                           }
                         }
                       }
                     }
                   }
                 }
               },
               "/auth/privy/failure" => %{
                 "post" => %{
                   "operationId" => "reportPrivyBrowserFailure",
                   "security" => [%{"csrfToken" => []}],
                   "requestBody" => %{
                     "required" => true,
                     "content" => %{
                       "application/json" => %{
                         "schema" => %{
                           "type" => "object",
                           "additionalProperties" => false,
                           "required" => ["reason"],
                           "properties" => %{
                             "reason" => %{
                               "type" => "string",
                               "enum" => [
                                 "bridge_startup",
                                 "flow_closed",
                                 "invalid_message",
                                 "provider_error",
                                 "request_timeout",
                                 "session_exchange",
                                 "unable_to_sign"
                               ]
                             }
                           }
                         }
                       }
                     }
                   },
                   "responses" => %{
                     "204" => %{"description" => "Diagnostic accepted or safely ignored"},
                     "403" => %{"$ref" => "#/components/responses/CsrfForbidden"}
                   }
                 }
               },
               "/auth/privy/session" => %{
                 "post" => %{
                   "operationId" => "createPrivyBrowserSession",
                   "security" => [
                     %{
                       "privyAccessToken" => [],
                       "privyIdentityToken" => [],
                       "csrfToken" => []
                     }
                   ],
                   "requestBody" => %{
                     "required" => false,
                     "content" => %{
                       "application/json" => %{
                         "schema" => %{
                           "type" => "object",
                           "maxProperties" => 0,
                           "additionalProperties" => false
                         }
                       }
                     }
                   },
                   "responses" => %{
                     "200" => %{"$ref" => "#/components/responses/Session"},
                     "401" => %{"$ref" => "#/components/responses/PrivySessionUnauthorized"},
                     "403" => %{"$ref" => "#/components/responses/CsrfForbidden"}
                   }
                 },
                 "delete" => %{
                   "operationId" => "deletePrivyBrowserSession",
                   "security" => [%{"csrfToken" => []}],
                   "responses" => %{
                     "200" => %{"$ref" => "#/components/responses/Logout"},
                     "403" => %{"$ref" => "#/components/responses/CsrfForbidden"}
                   }
                 }
               },
               "/auth/session" => %{
                 "get" => %{
                   "operationId" => "getBrowserSession",
                   "responses" => %{
                     "200" => %{"$ref" => "#/components/responses/Session"}
                   }
                 }
               }
             }

    assert contract["components"]["securitySchemes"] == %{
             "privyAccessToken" => %{
               "type" => "http",
               "scheme" => "bearer",
               "bearerFormat" => "Privy access token"
             },
             "privyIdentityToken" => %{
               "type" => "apiKey",
               "in" => "header",
               "name" => "privy-id-token"
             },
             "cookieSession" => %{
               "type" => "apiKey",
               "in" => "cookie",
               "name" => "_keyfleet_key"
             },
             "csrfToken" => %{
               "type" => "apiKey",
               "in" => "header",
               "name" => "x-csrf-token"
             },
             "siwaReceipt" => %{
               "type" => "apiKey",
               "in" => "header",
               "name" => "x-siwa-receipt",
               "description" =>
                 "A SIWA wallet receipt for audience keyfleet on Base. The request also carries its HTTP message signature (signature, signature-input, content-digest, x-key-id, x-timestamp, x-agent-wallet-address, x-agent-chain-id), each exactly once."
             }
           }

    account_control = %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["kind", "label", "avatar_src"],
      "properties" => %{
        "kind" => %{"type" => "string", "enum" => ["sign_in", "signed_in"]},
        "label" => %{"type" => "string"},
        "avatar_src" => %{
          "type" => ["string", "null"],
          "pattern" => "^data:image/svg\\+xml;base64,"
        }
      }
    }

    assert contract["components"]["schemas"]["Session"] == %{
             "type" => "object",
             "additionalProperties" => false,
             "required" => ["authenticated", "account_control"],
             "properties" => %{
               "authenticated" => %{"type" => "boolean"},
               "account_control" => account_control
             }
           }

    assert contract["components"]["schemas"]["Error"] == %{
             "type" => "object",
             "additionalProperties" => false,
             "required" => ["error"],
             "properties" => %{
               "error" => %{
                 "type" => "object",
                 "additionalProperties" => false,
                 "required" => ["code", "message", "hint"],
                 "properties" => %{
                   "code" => %{"type" => "string", "enum" => ["unauthorized"]},
                   "message" => %{"type" => "string"},
                   "hint" => %{"type" => "string"}
                 }
               }
             }
           }

    assert Map.take(contract["components"]["responses"], [
             "Session",
             "Unauthorized",
             "PrivySessionUnauthorized",
             "Logout",
             "CsrfForbidden"
           ]) == %{
             "Session" => %{
               "description" => "Current browser session",
               "content" => %{
                 "application/json" => %{
                   "schema" => %{"$ref" => "#/components/schemas/Session"}
                 }
               }
             },
             "Unauthorized" => %{
               "description" =>
                 "The Privy access and identity tokens were not both present and valid for one signed-in session",
               "content" => %{
                 "application/json" => %{
                   "schema" => %{"$ref" => "#/components/schemas/Error"}
                 }
               }
             },
             # Only the browser sign-in exchange may publish the marker, and only
             # as an optional header on a body identical to every other refusal.
             "PrivySessionUnauthorized" => %{
               "description" =>
                 "The Privy access and identity tokens were not both present and valid for one signed-in session",
               "headers" => %{
                 "x-ash-provider-relogin" => %{
                   "description" =>
                     "Present only when the access token itself could not be verified, which permits one fresh provider login",
                   "required" => false,
                   "schema" => %{"type" => "string", "const" => "allowed"}
                 }
               },
               "content" => %{
                 "application/json" => %{
                   "schema" => %{"$ref" => "#/components/schemas/Error"}
                 }
               }
             },
             "Logout" => %{
               "description" => "Local browser session removed",
               "content" => %{
                 "application/json" => %{
                   "schema" => %{
                     "type" => "object",
                     "additionalProperties" => false,
                     "required" => ["ok"],
                     "properties" => %{"ok" => %{"type" => "boolean", "const" => true}}
                   }
                 }
               }
             },
             "CsrfForbidden" => %{"description" => "CSRF token was absent or invalid"}
           }
  end

  # The fields each workspace body admits, as the signed-request check admits them.
  test "each workspace operation is a signed POST whose body admits exactly its own fields" do
    contract = YamlElixir.read_from_file!(@contract)
    schemas = contract["components"]["schemas"]
    command = ~w(as_key command_id)

    for {op, required, optional} <- [
          {"get", ~w(id), []},
          {"changes", [], ~w(after_seq limit)},
          {"create", command ++ ~w(type scope data), []},
          {"patch", command ++ ~w(id expected_version), ~w(set unset reason evidence)},
          {"link", command ++ ~w(source target type), ~w(note)},
          {"unlink", command ++ ~w(relation_id), []},
          {"archive", command ++ ~w(id expected_version), ~w(reason)}
        ] do
      assert %{"post" => operation} = path = contract["paths"][@graph <> op]
      assert Map.keys(path) == ["post"]
      assert operation["security"] == [%{"siwaReceipt" => []}]

      "#/components/schemas/" <> name =
        operation["requestBody"]["content"]["application/json"]["schema"]["$ref"]

      schema = schemas[name]
      assert schema["additionalProperties"] == false
      assert Enum.sort(Map.get(schema, "required", [])) == Enum.sort(required)
      assert Enum.sort(Map.keys(schema["properties"])) == Enum.sort(required ++ optional)
    end

    assert schemas["WorkspaceCreateRequest"]["properties"]["scope"] == %{
             "$ref" => "#/components/schemas/WorkspaceScope"
           }

    # The fleet, or one of a Fibonacci fleet's twenty levels, written one way only.
    scope = Regex.compile!(schemas["WorkspaceScope"]["pattern"])
    scopes = ["fleet" | Enum.map(1..20, &"level:#{&1}")]
    assert Enum.all?(scopes, &Regex.match?(scope, &1))

    refute Enum.any?(
             ~w(level:0 level:21 level:01 Level:1 level: fleet:1 all),
             &Regex.match?(scope, &1)
           )
  end

  # A signed agent route the router serves and the contract leaves out, or
  # the other way round, fails here.
  test "the contract documents exactly the signed agent routes the router serves" do
    contract = YamlElixir.read_from_file!(@contract)

    served =
      for %{path: "/api/v1/agent/" <> _ = path, verb: verb} <-
            Phoenix.Router.routes(KeyfleetWeb.Router),
          do: {verb |> to_string() |> String.upcase(), Regex.replace(~r/:(\w+)/, path, "{\\1}")}

    documented =
      for {"/api/v1/agent/" <> _ = path, operations} <- contract["paths"],
          {method, operation} <- operations do
        assert operation["security"] == [%{"siwaReceipt" => []}], "#{method} #{path}"

        assert %{
                 "401" => %{"$ref" => "#/components/responses/AgentUnauthorized"},
                 "413" => %{"$ref" => "#/components/responses/AgentRequestTooLarge"}
               } = operation["responses"]

        {String.upcase(method), path}
      end

    assert Enum.sort(served) == Enum.sort(documented)
  end

  test "a created room's address is lowercase letters, digits and single dashes" do
    contract = YamlElixir.read_from_file!(@contract)

    slug =
      Regex.compile!(
        contract["components"]["schemas"]["RoomCreateRequest"]["properties"]["slug"]["pattern"]
      )

    assert Enum.all?(~w(hull-survey a 7 open-6 hull-survey-2), &Regex.match?(slug, &1))
    refute Enum.any?(~w(Hull hull--survey -hull hull- hull_survey), &Regex.match?(slug, &1))
  end

  test "the served contract is byte-identical and available over HTTP", %{conn: conn} do
    assert File.read!(@served_contract) == File.read!(@contract)

    conn = get(conn, "/api-contract.openapiv3.yaml")
    assert response(conn, 200) == File.read!(@contract)
    assert get_resp_header(conn, "content-type") == ["application/yaml"]
  end
end
