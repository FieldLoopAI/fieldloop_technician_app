/// Build 185 switch, default ON. Logged on its own `B185 FLAGS:` line at
/// app start and at every session open — the B184 FLAGS line (and every
/// earlier one) is left exactly as before. Set to false for exactly the
/// build 184 invoice behavior (mock Job Detail payment badge, no Collect
/// Payment button).
library;

/// Stripe test-mode payments: "Collect Payment" on Invoice Review opens a
/// hosted Stripe Checkout page; the real payment status (Unpaid / Pending /
/// Paid) is read from `/invoices/payment-status`.
/// `--dart-define=B185_STRIPE_PAYMENTS=false`.
const bool kStripePayments = bool.fromEnvironment('B185_STRIPE_PAYMENTS', defaultValue: true);

String describeB185Flags() => 'B185 FLAGS: stripePayments=$kStripePayments';
