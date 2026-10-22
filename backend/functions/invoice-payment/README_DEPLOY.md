# invoice-payment (Build 185)

One Lambda serving three routes on HTTP API `tqb5mpwlpf` (stage `dev`, us-east-1):

| Method | Path | Auth |
|---|---|---|
| POST | `/invoices/checkout` | technician JWT, checked in code (`shared/auth.js` `requireTechnician`) |
| GET | `/invoices/payment-status` | technician JWT, checked in code |
| GET | `/stripe/return` | none (static "Thank you" page, shows no data) |

Create all three routes with **no gateway authorizer**; integrate each with this Lambda.

## Prerequisites (in this order)

1. Run `supabase/migrations/20261022_stripe_payments.sql`.
2. Seed the demo contractor's connected account:
   `contractor_financials.stripe_account_id = 'acct_1UTF0B0zMj9YCEEe'` for the demo job's contractor.
3. Secret `fieldloop/stripe-test` = `{"secretKey": "sk_test_...", "webhookSecret": "whsec_..."}`.
   A key that is not `sk_test_`/`rk_test_` is refused (test mode only).

## Runtime

- Node.js 20.x or newer (stripe 23.0.0 requires node >= 20). Handler `index.handler`.
- Stripe SDK pinned to `23.0.0`; `apiVersion` set explicitly to `2026-09-30.endive`
  (the SDK's bundled version). Cold start logs `STRIPE SDK: version=23.0.0 apiVersion=2026-09-30.endive`.

## Env vars

| Name | Default | Purpose |
|---|---|---|
| `STRIPE_RETURN_BASE` | `https://tqb5mpwlpf.execute-api.us-east-1.amazonaws.com/dev/stripe/return` | Checkout success/cancel URL base (`?status=success` / `?status=cancel`) |

## IAM (execution role)

- `secretsmanager:GetSecretValue` on `fieldloop/stripe-test` (ARN `arn:aws:secretsmanager:us-east-1:<account>:secret:fieldloop/stripe-test-*`).
- The existing `secretsmanager:GetSecretValue` on `fieldloop/supabase-service-credentials`.

## Build the zip (fresh — never reuse any committed function.zip)

From `backend/functions/invoice-payment` in PowerShell:

```powershell
npm ci --omit=dev
Remove-Item function.zip -ErrorAction SilentlyContinue
Compress-Archive -Path index.js, package.json, shared, node_modules -DestinationPath function.zip
```

Files in the zip: `index.js`, `package.json`, `shared/` (`auth.js`, `secrets.js`,
`supabaseClient.js`, `payment_math.js`, `stripeClient.js`), `node_modules/`.
`test/` is not needed. `node_modules/` and `*.zip` are git-ignored here.

## Tests

```powershell
npm ci
npm test
```

## Logs

Only invoice id, job id, cents amounts and the last 6 characters of Stripe ids:
`CHECKOUT: created ...`, `CHECKOUT: reuse open session ...`, `CHECKOUT: session expired ...`,
`CHECKOUT: fee mismatch ...`, `INVOICE PAYMENT ERROR: ...`.

## Related deploys in this build

- `generate-invoice-pdf`: B185 guards. Its zip must now include `shared/payment_math.js`.
  Deploy only AFTER the migration (it reads `invoices.payment_status`).
- `generate-invoice` (`/invoices/preview`): the 2% fee fallback was removed.
- `stripe-webhook`: see its own README_DEPLOY.md.
