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
             "/api/agents/v1/whoami",
             "/api/v1/about",
             "/api/v1/agent/account/balances",
             "/api/v1/agent/account/credits/history",
             "/api/v1/agent/account/points",
             "/api/v1/agent/avatar/remove",
             "/api/v1/agent/avatar/start",
             "/api/v1/agent/fleets/{fleet_id}/activity",
             "/api/v1/agent/fleets/{fleet_id}/dms/changes",
             @graph <> "archive",
             @graph <> "board",
             @graph <> "changes",
             @graph <> "create",
             @graph <> "fork",
             @graph <> "get",
             @graph <> "join",
             @graph <> "leave",
             @graph <> "link",
             @graph <> "patch",
             @graph <> "review",
             @graph <> "submit",
             @graph <> "unlink",
             "/api/v1/agent/fleets/{fleet_id}/keys/claim",
             "/api/v1/agent/fleets/{fleet_id}/keys/{token_id}",
             "/api/v1/agent/fleets/{fleet_id}/keys/{token_id}/claim",
             "/api/v1/agent/fleets/{fleet_id}/keys/{token_id}/dms",
             "/api/v1/agent/fleets/{fleet_id}/keys/{token_id}/dms/blocks",
             "/api/v1/agent/fleets/{fleet_id}/keys/{token_id}/dms/{other_token_id}/auto_delete",
             "/api/v1/agent/fleets/{fleet_id}/keys/{token_id}/dms/{other_token_id}/block",
             "/api/v1/agent/fleets/{fleet_id}/keys/{token_id}/dms/{other_token_id}/delete",
             "/api/v1/agent/fleets/{fleet_id}/keys/{token_id}/dms/{other_token_id}/read",
             "/api/v1/agent/fleets/{fleet_id}/keys/{token_id}/dms/{other_token_id}/send",
             "/api/v1/agent/fleets/{fleet_id}/keys/{token_id}/dms/{other_token_id}/unblock",
             "/api/v1/agent/fleets/{fleet_id}/keys/{token_id}/mute",
             "/api/v1/agent/fleets/{fleet_id}/keys/{token_id}/unmute",
             "/api/v1/agent/fleets/{fleet_id}/mutes",
             "/api/v1/agent/fleets/{fleet_id}/polls",
             "/api/v1/agent/fleets/{fleet_id}/polls/start",
             "/api/v1/agent/fleets/{fleet_id}/polls/{poll_id}",
             "/api/v1/agent/fleets/{fleet_id}/polls/{poll_id}/end",
             "/api/v1/agent/fleets/{fleet_id}/polls/{poll_id}/vote",
             "/api/v1/agent/fleets/{fleet_id}/posting_key",
             "/api/v1/agent/fleets/{fleet_id}/presence",
             "/api/v1/agent/fleets/{fleet_id}/projects",
             "/api/v1/agent/fleets/{fleet_id}/projects/archive",
             "/api/v1/agent/fleets/{fleet_id}/projects/start",
             "/api/v1/agent/fleets/{fleet_id}/projects/{project}/code/pushes",
             "/api/v1/agent/fleets/{fleet_id}/projects/{project}/delete",
             "/api/v1/agent/fleets/{fleet_id}/projects/{project}/notebooks",
             "/api/v1/agent/fleets/{fleet_id}/projects/{project}/notebooks/copies",
             "/api/v1/agent/fleets/{fleet_id}/projects/{project}/notebooks/copies/{copy_id}/restore",
             "/api/v1/agent/fleets/{fleet_id}/projects/{project}/notebooks/create",
             "/api/v1/agent/fleets/{fleet_id}/projects/{project}/notebooks/{notebook_id}/files/add",
             "/api/v1/agent/fleets/{fleet_id}/projects/{project}/notebooks/{notebook_id}/files/list",
             "/api/v1/agent/fleets/{fleet_id}/projects/{project}/notebooks/{notebook_id}/files/read",
             "/api/v1/agent/fleets/{fleet_id}/projects/{project}/notebooks/{notebook_id}/files/write",
             "/api/v1/agent/fleets/{fleet_id}/projects/{project}/notebooks/{notebook_id}/lock",
             "/api/v1/agent/fleets/{fleet_id}/projects/{project}/notebooks/{notebook_id}/runs/start",
             "/api/v1/agent/fleets/{fleet_id}/projects/{project}/notebooks/{notebook_id}/runs/{run_id}",
             "/api/v1/agent/fleets/{fleet_id}/projects/{project}/take_over",
             "/api/v1/agent/fleets/{fleet_id}/proposals/cancel",
             "/api/v1/agent/fleets/{fleet_id}/proposals/carry_out",
             "/api/v1/agent/fleets/{fleet_id}/proposals/create",
             "/api/v1/agent/fleets/{fleet_id}/proposals/read",
             "/api/v1/agent/fleets/{fleet_id}/proposals/vote",
             "/api/v1/agent/fleets/{fleet_id}/rooms",
             "/api/v1/agent/fleets/{fleet_id}/rooms/create",
             "/api/v1/agent/fleets/{fleet_id}/rooms/{slug}/messages/read",
             "/api/v1/agent/fleets/{fleet_id}/rooms/{slug}/messages/send",
             "/api/v1/agent/fleets/{fleet_id}/rooms/{slug}/topic",
             "/api/v1/agent/fleets/{fleet_id}/split",
             "/api/v1/agent/fleets/{fleet_id}/sync",
             "/api/v1/agent/fleets/{fleet_id}/treasury/convert",
             "/api/v1/agent/fleets/{fleet_id}/treasury/send_share",
             "/api/v1/agent/join/status",
             "/api/v1/agent/keys/{fleet_id}/{token_id}/messages/read",
             "/api/v1/agent/keys/{fleet_id}/{token_id}/messages/remove",
             "/api/v1/agent/keys/{fleet_id}/{token_id}/messages/send",
             "/api/v1/agent/profile",
             "/api/v1/agent/profile/update",
             "/api/v1/agent/shards",
             "/api/v1/avatar/upload/{ticket}",
             "/api/v1/docs",
             "/api/v1/fleets",
             "/api/v1/fleets/{fleet_id}",
             "/api/v1/fleets/{fleet_id}/proposals",
             "/api/v1/fleets/{fleet_id}/treasury",
             "/api/v1/fleets/{fleet_id}/workspace/pulse",
             "/api/v1/profile",
             "/api/v1/profile/sync",
             "/auth/csrf",
             "/auth/privy/failure",
             "/auth/privy/session",
             "/auth/session",
             "/metadata/collection.json",
             "/metadata/keys/{collection_token_id}"
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
                     "200" => %{
                       "description" => "Current browser session",
                       "headers" => %{
                         "Cache-Control" => %{
                           "schema" => %{"type" => "string", "const" => "no-store"}
                         }
                       },
                       "content" => %{
                         "application/json" => %{
                           "schema" => %{"$ref" => "#/components/schemas/Session"}
                         }
                       }
                     }
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
               "name" => "__Host-keyfleet"
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
                 "A SIWA wallet receipt for audience keyfleet, signed in on Base or Ethereum; a smart wallet signs in on Base. The request also carries its HTTP message signature (x-siwa-signature, x-siwa-signature-input, content-digest, x-key-id, x-timestamp, x-agent-wallet-address, x-agent-chain-id), each exactly once."
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
             "PrivySessionUnauthorized" => %{
               "description" =>
                 "The Privy access and identity tokens were not both present and valid for one signed-in session",
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
          {"board", [], ~w(project)},
          {"get", ~w(id), ~w(relations_after)},
          {"changes", [], ~w(project after_seq limit)},
          {"create", command ++ ~w(project type data), []},
          {"patch", command ++ ~w(id expected_version), ~w(set unset reason evidence)},
          {"link", command ++ ~w(source target type), ~w(note)},
          {"unlink", command ++ ~w(relation_id), []},
          {"archive", command ++ ~w(id expected_version), ~w(reason)},
          {"join", command ++ ~w(id), []},
          {"leave", command ++ ~w(id), []},
          {"submit", command ++ ~w(id expected_version), ~w(result_ref evidence reason)},
          {"review", command ++ ~w(task task_version decision rationale conflicts_of_interest),
           ~w(reproduction)},
          {"fork", command ++ ~w(id), []}
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
