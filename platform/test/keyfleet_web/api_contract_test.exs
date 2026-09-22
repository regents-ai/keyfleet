defmodule KeyFleetWeb.ApiContractTest do
  use KeyFleetWeb.ConnCase, async: true

  @contract Path.expand("../../contracts/api-contract.openapiv3.yaml", __DIR__)
  @served_contract Application.app_dir(:keyfleet, "priv/static/api-contract.openapiv3.yaml")

  @graph "/api/v1/agent/fleets/{fleet_id}/graph/"

  test "the canonical contract declares the complete admitted browser auth surface" do
    contract = YamlElixir.read_from_file!(@contract)

    assert Map.keys(contract["paths"]) |> Enum.sort() == [
             @graph <> "archive",
             @graph <> "changes",
             @graph <> "create",
             @graph <> "get",
             @graph <> "link",
             @graph <> "patch",
             @graph <> "unlink",
             "/api/v1/profile",
             "/api/v1/profile/sync",
             "/auth/csrf",
             "/auth/privy/failure",
             "/auth/privy/session",
             "/auth/session"
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
                               "error" => %{"type" => "string", "const" => "rate_limited"}
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
               "error" => %{"type" => "string", "enum" => ["unauthorized"]}
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
             "type" => "string",
             "const" => "fleet"
           }
  end

  test "the served contract is byte-identical and available over HTTP", %{conn: conn} do
    assert File.read!(@served_contract) == File.read!(@contract)

    conn = get(conn, "/api-contract.openapiv3.yaml")
    assert response(conn, 200) == File.read!(@contract)
    assert get_resp_header(conn, "content-type") == ["application/yaml"]
  end
end
