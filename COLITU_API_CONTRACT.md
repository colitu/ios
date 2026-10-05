# Colitu client API contract (iOS)

The iOS client talks only to the Colitu panel at `https://api.colitu.com/api/v1`.
The authoritative schema is `api/client/openapi.yaml` in the panel repository;
this file summarises what the app relies on.

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
  recommended order.
- `PUT /me/preferences` — `{ "preferred_node_id", "preferred_country",
  "preferred_region", "preferred_protocol" }`.
- `GET /config` / `POST /config/refresh` — configuration envelope:
  `revision`, `expires_at`, `offline_grace_until`, `server`, `profile`
  (`format: "xray-mobile-v1"`, `payload`) and, in automatic mode, `candidates`.
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
