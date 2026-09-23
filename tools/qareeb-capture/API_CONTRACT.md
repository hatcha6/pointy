# Qareeb — captured API contract

Reverse-engineered 2026-09-23 from the **Qareeb iOS app** (an agency/store
account) via `tools/qareeb-capture`. Host: `https://api.qareb.ly`
(→ `172.104.147.56`). Auth is **JWT bearer** (`access` / `refresh`).

All secret values below are redacted; this file holds **shapes, not
credentials**. The raw `.flows` stay local and gitignored.

## How it had to be captured (non-obvious)

- Qareeb is **Flutter** → ignores the iOS system proxy. Captured with
  **mitmproxy WireGuard mode**, not a Wi-Fi proxy.
- A **full tunnel breaks login.** The app uses **Firebase App Check**
  (`firebaseappcheck.googleapis.com`); when *its* Google traffic is forced
  through the proxy, attestation fails and the app won't even send the login
  request (generic "failed / retry", no request reaches us). `api.qareb.ly`
  itself does **not** pin — every logged-in and auth call decrypts.
- Fix = **split tunnel**: route ONLY `172.104.147.56/32` through mitmproxy,
  let Firebase/Apple/etc. go direct. Then login works and is captured.

## Authentication

### New-device rule (important)
Password login from an unrecognized device is **refused** and forced onto OTP:

```
POST /api/login/            (new device)
  ← 400 {"error": "جهاز جديد: الرجاء تسجيل الدخول بكلمة مرور مؤقتة (OTP)"}
        ("New device: please log in with a temporary password (OTP)")
```

### Password login (known device)
```
POST /api/login/
  → {"username": "<phone>", "password": "<pw>", "fcm_token": "<fcm>"}
        # NB: `username` IS the phone number (MSISDN), just named username
  ← 200 {"status": true, "username", "phone_number", "is_first_time",
         "info_completed", "profile_id", "role": "sub_admin",
         "refresh": "<jwt>", "access": "<jwt>",
         "account": "client", "account_type_display": "متجر",
         "client_name": "<agency name>", "customer_service_phone_number"}
```

### OTP login (required on a new device) — gated by an IMAGE captcha
```
1) GET  /api/v2/otp/step1                     → issues a captcha (captcha_ref)
2) GET  /captcha/image/{captcha_ref}/         → the captcha IMAGE (human reads it)
3) POST /api/v2/otp/
     → {"phone": "<phone>", "action": "login",
        "captcha": "<solved text>", "captcha_ref": "<ref>"}
     ← 200 {"status": true, "detail": "تم إرسال رمز التحقق بنجاح",
            "results": {"phone", "uuid": "<otp session>", "expires_in": 5}}
4) POST /api/verify_otp/
     → {"phone": "<phone>", "otp": "<code>", "uuid": "<from step 3>"}
     ← 400 {"error": "رمز التحقق غير صحيح"}      # wrong code (captured)
     ← 200 (success): tokens as /api/login/       # INFERRED, not captured
```
**Consequence for a driver:** the OTP path needs a human to read the captcha
image, so connecting a *new device* can't be fully headless. A known device
uses the plain password login above. (Token-refresh endpoint not captured.)

### Logout
```
POST /pos/api/logout/   (empty body)  → 200 {"detail": "تم تسجيل الخروج بنجاح"}
```

## Logged-in surface (Bearer `access`)

| Method | Path | Purpose |
|---|---|---|
| GET | `/api/store/v1/account_info/` | wallet / balance / profile (polled a lot) |
| GET | `/api/store/v2/product_list_detailed/in_stock/` | voucher/product catalog |
| GET | `/api/store/v1/get_product_price/{id}/` | per-product price |
| GET | `/api/v1/cart/` | current cart |
| POST | `/api/v1/cart/` | add: `{"product":"<uuid>","quantity":N}` → `{"status":true,"detail":"تمت الإضافة بنجاح"}` |
| GET | `/api/store/v1/transactions/` | money transactions |
| GET | `/api/store/v1/vouchers_history/` | voucher purchase history |
| GET | `/api/store/v1/transfer-request-list/` | transfers |
| GET | `/api/get_available_profiles/v1/` | selectable profiles |
| GET | `/api/notifications/v1/list/` | notifications |
| GET | `/pos/api/devices/v1/` | registered devices |

Note the two path families: `/api/store/v*` and `/api/v1` for the store app,
`/pos/api/*` for POS-oriented calls (logout, devices).

## Purchase (cart → checkout) — the money path

Captured with one real **3 LYD Libyana** top-up.

```
POST /api/v1/cart/         → {"product":"<uuid>","quantity":N}   # N=0 removes the line
  ← {"status":true,"detail":"تمت الإضافة بنجاح"}
GET  /api/v1/cart/         → {"hash":"<sha256 of cart state>","pin":null,"profile":null, …items…}
POST /api/v1/cart/checkout/
  → {"hash":"<the hash from GET /api/v1/cart/>", "pin":"<agency purchase PIN>", "profile":<id|null>}
  ← 200 {"detail":"Success","status":true,
         "order_reference":"<hex order id>",
         "result":[{
            "SN":"<voucher serial>", "id":"<uuid>", "code":"<recharge code / PIN>",
            "product":"3 دينار", "purchase_date":"<iso>", "purchase_price":"3.000",
            "status":"sent",
            "mno_type":"Libyana","mno_type_code":"30","mno_type_ar":"ليبيانا",
            "mno_type_logo":"/media/…png",
            "print_count":1, "text":"<printable voucher text>",
            "instructions_print":"# الرقم السري * 120 *", "help_print":"…"
         }]}
```

Driver-critical:
- **Checkout takes an agency purchase `pin`, but it's optional per account** —
  the PIN is a toggle in Qareeb's own settings. Send it only when the account
  has the purchase PIN enabled; when disabled it's omitted/null. The driver must
  treat `pin` as a conditional, per-account credential, not an always-required one.
- **`hash` must be read from the live `GET /api/v1/cart/`** (a cart-integrity
  token) and echoed back — don't fabricate it. Same discipline as reading HD
  Box's term from its form, not the list.
- **`order_reference`** is the reconciliation / idempotency key (≈ HD Box
  buy-log id). Nothing here is proven idempotent, so the driver still owes its
  own **at-most-once guard**, exactly like HD Box / LNET.
- The deliverable is `result[].code` (recharge code) + `SN` + `text` /
  `instructions_print` (printable receipt). `status:"sent"` = delivered.
- Products are **operator-specific** (`mno_type`: Libyana / Madar / …).

## What the driver relies on (`backend/apps/integrations/providers/qareeb.py`)

Shapes read from the same capture while building the driver. Values are
placeholders; nothing here is a real token, phone number or code.

### Request identity
Every call carries the app's own headers, value for value: `user-agent: Dart/3.6
(dart:io)`, `channel: iPhone`, `x-app-type: mobile`, `version: 1.1.8.13`,
`x-os-version`, `x-device-model: iPhone`, plus two per-install ids,
`x-device-uuid` (lower-case UUID) and `identifier` (upper-case UUID). These ids
are most likely what "new device" keys on (inferred, not proven). The driver
mints them once per account and keeps them, so one OTP confirmation should last
for the life of the installation.

### Tokens
`access` lives **28 days**, `refresh` **100 days** (SimpleJWT `exp − iat`). The
driver keeps both encrypted and, on a 401, logs in again by password once; the
refresh endpoint is still uncaptured.

### Firebase App Check — not enforced on the API (checked 2026-09-23)
No captured request to `api.qareb.ly` carries an `X-Firebase-AppCheck` header
or any other attestation token. App Check gates the **app** (it will not send a
login when its own attestation fails, see above), not the server. If Qareeb
starts enforcing it, a 401/403 whose body mentions App Check/Firebase/attest/
integrity is reported as `attestation_required` rather than as a wrong
password. No workaround is possible from a server; it would need Qareeb to
issue an agency API credential.

### Account
```
GET /api/store/v1/account_info/
  ← {"result": {"balance": "<decimal LYD>", "account_name": "<agency>", …}}
```

### Catalog (what is in stock)
```
GET /api/store/v2/product_list_detailed/in_stock/
  ← {"result": [
       {"category_name": "<Arabic>", "display_product": true|false,
        "data": [ <brand>, … ]}, …]}
<brand> = {"code": "<brand code>", "ar_desc", "en_desc", "logo": "/media/…",
           "product_currency": "LYD",
           "products": [{"id": "<uuid>", "desc": "5 دينار",
                         "cost": "<agency cost>", "price": "<suggested retail>",
                         "amount": "<face value>"}, …]}
```
- Only a category with `display_product: true` spells its products out inline.
  The others list brands with no products; each brand's cards are one more call:
  `GET /api/store/v1/get_product_price/{brand code}/ ← {"result": <brand>}`.
- A card absent from the listing is out of stock. The listing is the stock.
- The international-transfers category (`حوالات…`) is not cards: it sends money
  to a named recipient. The driver skips it by that label.

### Cart (shared by the whole agency account)
```
GET /api/v1/cart/
  ← {"hash": "<sha256>", "pin": null, "profile": null,
     "is_pin_required": true|false, "is_quick_switch_enabled": true|false,
     "items": [{"product": {"id": "<uuid>", "cost": "<decimal>", …},
                "quantity": N}, …]}
```
The same cart is seen by the owner's phone and by every till on the account,
so a purchase takes a turn (a Redis lock), removes anything it did not put
there, re-reads the cart, and checks out with the **live** `hash`. `pin` is
sent only when `is_pin_required`. `profile` is sent only when
`is_quick_switch_enabled`; otherwise it is null and the login's active
profile pays.

### Profiles
```
GET /api/get_available_profiles/v1/
  ← {"available_profiles": [
       {"profile_id": "<id>", "profile_type": "individual|store_employee|…",
        "is_active": true|false,
        "<profile_type>": {"name": "<display name>", …}}, …]}
```
The record describing a profile sits under a key named after its
`profile_type`. **The endpoint that switches the active profile was not
captured.** Until it is, the owner picks a profile in Pointy, and the till
refuses to buy (`profile_mismatch`) while the login is acting as a different
one, unless quick switch lets checkout name the profile.

### Voucher history (reconciliation)
```
GET /api/store/v1/vouchers_history/?page=N
  ← {"results": [{"voucher_id": "<uuid>", "status": "sent",
                  "cost": "<decimal>", "purchase_date": "<naive ISO>",
                  "mno_type__code": "<brand code>", "mno_type__name": "<brand>",
                  "product": "5 دينار", "purchase_user": "<phone>",
                  "code": "<PIN>", "SN": "<serial>", …}, …],
     "total_results": N, "total_pages": N}
```
Account-wide (every login and profile), newest first, 15 to a page.
`purchase_date` has no zone and is **Tripoli wall-clock time**.
`purchase_user` is a phone number. The driver only compares it with its own
login and never stores or shows it.

### Confirming a new device: the captcha step
```
GET /api/v2/otp/step1
  ← {"field": {"hashkey": "<captcha_ref>", "image_url": "/captcha/image/<ref>/",
               "help_text": "<Arabic>"}}
```
The driver fetches the image and passes it to the owner as a `data:` URL. It
sends the answer to `/api/v2/otp/` and the texted code to `/api/verify_otp/`.

## Deliberately NOT captured
- `verify_otp` **success** body — inferred from `/api/login/`.
- Any **token-refresh** endpoint — not exercised.

## Product image 404s are normal
`GET /media/products/<n>.png|jpeg` frequently returns **404** (tiny HTML body) —
those products simply have no uploaded image. Not an error to handle.
