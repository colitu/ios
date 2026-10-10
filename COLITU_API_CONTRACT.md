# Colitu client API contract (iOS)

The iOS client talks only to the Colitu panel at `https://api.colitu.com/api/v1`.
The authoritative schema is `api/client/openapi.yaml` in the panel repository;
this file summarises what the app relies on.

TLS: the API client (all API bases incl. mirrors, `endpoints.json`) trusts only
six pinned roots (ISRG Root X1/X2/YE/YR, GTS Root R1/R4; `lib/colitu/api/cert_pins.dart`)
until 2027-12-31T23:59:59Z, then the system store again. A refused handshake is a
network-level failure (base failover, logged as `CERT_PIN_MISMATCH <host>`).

All request and response bodies are JSON with `snake_case` keys. The panel
rejects unknown request fields. Errors use:

```json
{ "error": { "code": "DEVICE_LIMIT_REACHED", "message": "device limit reached" } }
```

## Authentication

| Route | Body | Response |
|---|---|---|
| `POST /auth/register` | `{ "email", "password" }` | `201` tokens |
| `POST /auth/login` | `{ "email", "password" }` | `200` tokens |
| `POST /auth/refresh` | `{ "refresh_token" }` + `X-Device-ID` header | `200` tokens |
| `POST /auth/logout` | `{ "refresh_token" }` | `204` |

Tokens: `{ "access_token", "refresh_token", "token_type": "Bearer", "expires_in" }`.
Refresh tokens rotate; reusing an old one revokes the whole token family.

## Device registration

`POST /devices/register` (Bearer) registers the installation and returns the
device row. Its `id` is sent as `X-Device-ID` on every device-scoped request.

```json
{
  "device_key": "<persistent random key, 20-256 chars>",
  "name": "ios device",
  "platform": "ios",
  "app_version": "5.0.4+15",
  "os_version": "18.0",
  "capabilities": {
    "config_formats": ["xray-mobile-v1"],
    "protocols": ["vless-reality", "hysteria2", "trojan", "shadowsocks"]
  }
}
```

Registration requires an active entitlement (new accounts get the free plan:
10 GB a month) and enforces the plan's device limit (`DEVICE_LIMIT_REACHED`).

## Device-scoped routes (Bearer + `X-Device-ID`)

- `GET /client/bootstrap` — user, device, entitlement, usage, configuration
  availability, maintenance flag and `app_policy` (`update_required`,
  `update_recommended`).
- `GET /servers` — `{ "servers": [{ "id", "name", "country", "city", "region",
  "status", "load", "protocols", "latency_host", "latency_port" }] }` in
  recommended order. With the VPN off it also carries `client_network`,
  `network_token` and `network_hints`: `{ "blocked": [..], "preferred": [..],
  "scope", "updated_at" }`. `preferred` (Adaptive Connect 3.0) lists the
  protocols that worked for at least 80 % of the devices on this network (or
  country), best first; `blocked` may be empty. The app lowercases and
  de-duplicates both lists, drops from `preferred` whatever is in `blocked`,
  and, on a network without a last good transport of its own, starts with the
  offered, non-stalled preferred protocols in that order without a probe round.
- `PUT /me/preferences` — `{ "preferred_node_id", "preferred_country",
  "preferred_region", "preferred_protocol" }`.
- `GET /config` / `POST /config/refresh` — configuration envelope:
  `revision`, `expires_at`, `offline_grace_until`, `server`, `profile`
  (`format: "xray-mobile-v1"`, `payload`) and, in automatic mode, `candidates`.
- `GET /client/recovery?client_country=<CC>` — recovery set (Adaptive Connect 3.0;
  `client_country` is the last `client_country` of `/servers`, upper case,
  omitted when unknown):
  `{ "generated_at", "recovery_until", "configs": [<config envelope>, ..] }`,
  1 to 4 envelopes (one per country first, each like `/config?protocol=auto&node=<id>`),
  `recovery_until` about 14 days ahead. The app fetches it in the background
  when none is stored or `generated_at` is older than 24 h (at most one attempt
  per 6 h) and keeps the raw JSON in the Keychain (`SecureTokenStore`). 401/403
  delete it; network errors and 5xx keep it; sign-out deletes it. It is used
  only in automatic server mode when every API base fails at network level (the
  app keeps no regular config cache): the servers are tried in order, each like
  a `/config` envelope; after `recovery_until` the set is deleted. Nodes still
  check the device credential.
  Off-switch: `kAdaptiveConnect3` (`lib/colitu/config/adaptive_connect3.dart`) is
  `false` in this release: no fetch, no use of a stored set, and no hinted start
  from `network_hints.preferred` (behaviour as before 3.0).
- `POST /client/protocol-observations` — `{ "node_id", "observations":
  [{ "protocol", "reachable", "latency_ms" }] }`, best effort.
- `GET /me`, `GET /me/entitlement`, `GET /me/usage`, `GET /devices`,
  `DELETE /devices/{id}`.

## Billing

`GET /billing/catalog`, `GET /billing/payment-methods`, `POST /billing/quote`,
`POST /billing/checkout` (opens the hosted Platega page), `GET /billing/orders/{id}`
(the only source of payment success) and `GET /billing/subscription`.

## Not provided by the panel

Password reset, email verification, social sign-in, in-app purchases, support
chat and push notifications are not part of the panel API; the app does not
call them.
