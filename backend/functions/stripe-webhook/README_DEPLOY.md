# stripe-webhook (Build 185)

| Method | Path | Auth |
|---|---|---|
| POST | `/stripe/webhook` | none at the gateway — the `stripe-signature` header is verified in code |

Create the route on HTTP API `tqb5mpwlpf` (stage `dev`) with **no gateway authorizer**.
Payload format 1.0 or 2.0 both work (header lookup is case-insensitive; base64 bodies are decoded).

## Stripe dashboard (TEST mode)

1. Developers -> Webhooks -> Add endpoint:
   `https://tqb5mpwlpf.execute-api.us-east-1.amazonaws.com/dev/stripe/webhook`
2. Events to send:
   - `checkout.session.completed`
   - `checkout.session.async_payment_succeeded`
   - `checkout.session.expired`
3. Copy the endpoint's signing secret (`whsec_...`) into the secret
   `fieldloop/stripe-test` as `webhookSecret` (next to `secretKey`).

## Behaviour

- Bad or missing signature -> 400. Missing `webhookSecret` -> 500.
- Dedupe: `stripe_events` row per event id; a repeat -> 200, not reprocessed.
- Paid only when `session.payment_status = 'paid'` AND `session.amount_total = invoices.amount_cents`
  (a mismatch is logged as `AMOUNT MISMATCH` and the invoice stays pending).
- On paid it writes `invoices.payment_status = 'paid'`, `paid_at`, `stripe_payment_intent_id`, and the
  existing legacy columns `paid_ts` (= `paid_at`) and `stripe_payment_intent_ref` (= `stripe_payment_intent_id`).
  Both legacy columns must exist on `invoices` (they are not in the repo migrations); if either is missing,
  the update fails, the webhook returns 500 and Stripe retries.
- `checkout.session.expired` -> back to `unpaid` only while still `pending` with the same session id.
- DB failure -> 500 (the event row is removed first, so Stripe's retry is processed).
- Never writes `jobs`.

## Runtime / env / IAM

- Node.js 20.x or newer, handler `index.handler`, stripe `23.0.0`, apiVersion `2026-09-30.endive`.
- No env vars.
- IAM: `secretsmanager:GetSecretValue` on `fieldloop/stripe-test` and on
  `fieldloop/supabase-service-credentials`.

## Build the zip (fresh — never reuse any committed function.zip)

```powershell
npm ci --omit=dev
Remove-Item function.zip -ErrorAction SilentlyContinue
Compress-Archive -Path index.js, package.json, shared, node_modules -DestinationPath function.zip
```

Files: `index.js`, `package.json`, `shared/` (`auth.js`, `secrets.js`, `supabaseClient.js`,
`payment_math.js`, `stripeClient.js`), `node_modules/`.

## Tests

```powershell
npm ci
npm test
```
