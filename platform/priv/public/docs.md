# Developer documentation

KeyFleet has a small public surface: documentation you can read without an account, a health check, and one account API for the person who signed in.

## Start without an account

Public documentation and the health check need no API key or wallet. Read this page, the [agent guide]({{origin}}/llms.txt) or the [OpenAPI JSON specification]({{origin}}/openapi.json).

```sh
curl --fail '{{origin}}/healthz'
curl --fail -H 'Accept: text/markdown' '{{origin}}/docs'
curl --fail '{{origin}}/openapi.json'
```

The health response is the plain text `ok`. It confirms the web service is responding, not that every outside service is available.

The homepage, this documentation, About, Contact, Privacy and Terms answer `Accept: text/markdown` at their ordinary addresses. Browsers receive HTML by default. Unknown page addresses return 404 rather than an empty document.

## Read and update your profile

`GET /api/v1/profile` returns the profile of the person whose credentials are presented. `PATCH /api/v1/profile` updates its `display_name` or `wallet_address`. `POST /api/v1/profile/sync` creates the profile on first use and refreshes it from your sign-in evidence afterwards.

Every request carries both a Privy access token in `Authorization: Bearer …` and a Privy identity token in `Privy-Id-Token`. These are your own sign-in credentials, not an API key. Keep them private; never paste tokens, private keys or recovery phrases into a chat, report or public issue.

The following command assumes the two token variables were supplied through your own secure credential handling:

```sh
curl --fail-with-body '{{origin}}/api/v1/profile' \
  -H 'Accept: application/json' \
  -H "Authorization: Bearer ${PRIVY_ACCESS_TOKEN}" \
  -H "Privy-Id-Token: ${PRIVY_IDENTITY_TOKEN}"
```

A successful response contains a `profile` object with the profile id, display name, the linked wallets and the selected wallet. Missing or invalid credentials return 401. A profile that has not been created yet returns 404; call `POST /api/v1/profile/sync` first. An invalid update returns 422. A service that is not configured for sign-in returns 503. Profile responses are never cached.

## Contracts

The [OpenAPI JSON specification]({{origin}}/openapi.json) describes the health check and the profile API above, including their authentication requirements. The [YAML contract]({{origin}}/api-contract.openapiv3.yaml) is the full served contract, including the browser session endpoints the site itself uses.

Public documentation does not authorize a payment, signature, credential change or other change to your account.

Need help? Read [About]({{origin}}/about), [Contact]({{origin}}/contact), [Privacy]({{origin}}/privacy) and [Terms]({{origin}}/terms).
