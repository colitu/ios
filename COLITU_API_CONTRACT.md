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
| `POST /auth/register` | `{ "email", "password", "locale", "source": "app:ios", "invite"? }` (`invite`: 6-12 characters A-Z0-9, upper case, left out when empty) | `201` tokens |
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
  `GET /me` may carry an optional `company: { "name", "role": "owner"|"admin"|"member" }` (absent without a company seat); the account tab shows `Company: <name>` only when present.

## Billing

`GET /billing/catalog`, `GET /billing/payment-methods`, `POST /billing/quote`,
`POST /billing/checkout` (opens the hosted Platega page), `GET /billing/orders/{id}`
(the only source of payment success) and `GET /billing/subscription`.

## Invites, anonymous statistics and surveys

All of these use the signed-in client (Bearer, `X-Device-ID`). None of them
blocks a connect or a sign-up; every failure is ignored.

- `GET /referral` — `{ "data": { code, link, enabled, invitee_days, reward_days,
  monthly_cap, invited, pending, rewarded, rejected, days_earned,
  rewarded_this_month, recent: [{ status, reason?, days, created_at }] } }`.
  The invite screen (Account, "Invite a friend") shows the link with Copy and
  Share, four counters (invited; valid invites with "N pending"; Premium days
  earned; rewards left this month = `monthly_cap - rewarded_this_month`) and the
  rules. `recent` is not shown (no invitee names). The register screen has an
  optional "I have an invite code" field; a pasted `https://colitu.com/r/CODE`
  link is reduced to `CODE`. An invite link opened in the app
  (`/r/:code` route, `ColituInvite.handleLink`) keeps the code until sign-up.
- `POST /client/metrics` (at most every 6 h, only with "Anonymous usage
  statistics" on) — `{ "platform": "ios", "app_version", "counters": {non-zero
  of connect_attempts, connect_successes, first_connect_attempts,
  first_connect_successes, sessions, unexpected_disconnects, functional_checks,
  functional_ok, recoveries, recovery_successes, protocol_switches,
  protocol_switch_successes, flaps}, "histograms": {"connect_ms" |
  "recovery_ms" | "detection_ms": [9 ints]}, "kill_switch": bool, "features":
  [split_tunnel, shield, ad_block, advanced_mode, multihop, auto_connect,
  kill_switch, manual_server (custom_dns is never sent: iOS has none)] }`.
  Histogram bucket upper bounds in ms: 500, 1000, 2000, 3000, 5000, 8000, 15000,
  30000, and a last open bucket. Each counter is capped at 10000. `202` (or any
  2xx) and `400` clear what was sent; `429`, `5xx` and no answer keep it.
- `POST /client/ac-events` (at most hourly, <= 300 events per request of one
  network, queue capped at 1000 with the oldest dropped) — `{ "platform":
  "ios", "app_version", "network_token", "network_type": "wifi" | "cellular" |
  "ethernet" | "other" | "", "events": [...] }`. `network_token` is the token of
  the last `GET /servers` made while the VPN was off (the one the protocol
  observations use), empty when none. Same answers as `/client/metrics`.
  Event kinds (`node_id` lower-case UUID of the server list, `protocol` one of
  vless-reality, vless-xhttp, hysteria2, trojan, shadowsocks, tuic, `ms` 0-600000):
  `connect {node_id, protocol, outcome ok|fail, reason?, ms, first_try, mode
  auto|manual}` (one per connect flow, auto and manual), `recovery {node_id,
  protocol, to_protocol?, outcome, reason?, ms, detect_ms?, spare}`,
  `switch {protocol, to_protocol?, outcome, flap}`, `drop {node_id, protocol,
  reason, minutes}`, `probe {node_id, outcome, ms?}` (last per node per hour),
  `choice {node_id, ms, best_node_id, best_ms, mode: "auto"}` (once per automatic
  choice). Reasons: timeout, reset, tls, dns, refused, handshake, blocked,
  no_network, core_crash, auth, quota, network_change, other. The app maps what
  the connect flow throws (`ColituAcEvents.reasonOfError`): a timeout ->
  `timeout`; a tunnel that came up and carried nothing -> `blocked`; a core
  start/crash reason of the extension -> `core_crash`; the device or API
  unreachable -> `no_network`; session, plan, device-limit and entitlement
  errors -> `auth`; daily limit / quota -> `quota`; everything else -> `other`.
  Turning "Anonymous usage statistics" off deletes the stored counters and the
  queued events.
- `GET /client/survey` (at most once a day after sign-in, never while connecting,
  skipped when "Show surveys" is off) — `{ "survey": null }` or `{ "survey":
  { "kind": "csat" | "nps" | "pmf" | "churn", "conversation_id"? } }`;
  `POST /client/survey` — `{ "kind", "score"?, "answer"?, "reason"?, "comment"?,
  "conversation_id"?, "dismissed", "platform": "ios" }` -> `204`. `score`: csat
  1-5, nps 0-10; `answer` (pmf): very | somewhat | not; `reason` (churn): price |
  speed | blocked | not_needed | other_vpn | technical | other; `comment` at most
  1000 characters (csat and churn); `conversation_id` travels with csat only.
  Closing the sheet sends `dismissed: true` and no answer.

## Colitu Passport (v2, per account)

The passport lives on the server (colitu-panel `docs/passport-server.md`): the
server counts the minutes from the nodes' traffic reports and evaluates every
rule. The app counts nothing (the tunnel extension has no passport code); it
caches the last state for offline display (`PassportServerState.applyTo`),
plays the reveals of the server's events and sends cosmetic choices.
Signed-in client (Bearer, `X-Device-ID`); failures are ignored.

- `GET /client/passport` — the state: `collector_no`, `nickname`, `title_id`,
  `cover_id`, `tester`, `premium`, `chapter2_open`, `companion`, `today { day,
  minutes, pieces, next_piece_at_minute }`, `run { country, minutes }`,
  `stamps [{ country, unlocked_at, pieces, level, mastered }]`,
  `achievements [{ id, earned_at }]`, `collections [{ id, earned_at }]`,
  `covers`, `weekly { week, goals [{ id, target, progress, done }] }`,
  `expeditions_done`, `unseen_events`, `updated_at`. Server ids use hyphens
  (`nordic-master`, `gold-rush`); the app maps them to its underscore ids.
  Fetched on app start and foreground, after a connect, when the passport
  opens and every 60 s while it is open and connected.
- `GET /client/passport/events?unseen=1` (only when `unseen_events` > 0) —
  `{ "data": [{ id, kind, payload, created_at }] }`; kinds `stamp_unlocked`,
  `piece`, `level_up`, `mastered`, `achievement`, `collection`,
  `chapter_opened`, `weekly_done`, `companion`. Played in id order; unknown
  kinds are skipped. Then `POST /client/passport/events/ack
  { "through_id" }` → 204.
- `PUT /client/passport/profile` — `{ nickname?, title_id?, cover_id?,
  tz_offset_min }` (only the changed field; `""` clears it). The time zone is
  sent once and again when it changes. Answers with the state.
- `POST /client/passport/events { "kind": "share" }` → 204 when the Story card
  is shared (weekly share goal).
- `POST /client/passport/import` — once per device, before the first state
  replaces the cache, when this device has v1 progress: `{ device_id, stamps
  [{ country, pieces, unlocked_at }], achievements, collections,
  expeditions_done, companion, nickname?, title_id?, cover_id? }`. Done on
  success, on 409 `PASSPORT_ALREADY_IMPORTED` and on other 4xx (except 401,
  408, 429); retried on network errors and 5xx. Answers with the merged state.
- `POST /passport/metrics` is no longer called (v1 only). Sign-out clears the
  cached passport (friends, cities and the sound/haptics switches stay).

## Not provided by the panel

Password reset, email verification, social sign-in, in-app purchases, support
chat and push notifications are not part of the panel API; the app does not
call them.
