// Build 185 payment math and guards. Pure functions only (no I/O) so they
// can be unit-tested and shared by generate-invoice-pdf, invoice-payment and
// stripe-webhook. Every amount that reaches Stripe is integer cents.

// An Error carrying an HTTP status for the Lambda's catch block.
function httpError(statusCode, message) {
  const err = new Error(message);
  err.statusCode = statusCode;
  return err;
}

// Dollars (number or numeric string from Postgres) -> integer cents.
function toCents(amount) {
  const n = Number(amount);
  if (amount === null || amount === undefined || amount === '' || !Number.isFinite(n)) {
    throw httpError(400, 'Amount is not a number');
  }
  return Math.round(n * 100);
}

// The contractor's platform fee rate. No fallback: a missing, zero or
// negative rate is a configuration error, never a silent 2%.
function requireFeeRate(rate) {
  const n = Number(rate);
  if (rate === null || rate === undefined || rate === '' || !Number.isFinite(n) || n <= 0) {
    throw httpError(400, 'Platform fee rate is not configured for this contractor');
  }
  return n;
}

function feeCentsFor(totalCents, rate) {
  return Math.round(totalCents * requireFeeRate(rate));
}

// totalCents, feeCents and netCents for an invoice total in dollars.
function invoiceCents(grossTotal, rate) {
  const totalCents = toCents(grossTotal);
  const feeCents = feeCentsFor(totalCents, rate);
  return { totalCents, feeCents, netCents: totalCents - feeCents };
}

// True when the stored fee agrees with the stored rate within 1 cent.
function storedFeeMatches(totalCents, storedFee, rate) {
  return Math.abs(toCents(storedFee) - feeCentsFor(totalCents, rate)) <= 1;
}

const FROZEN_PAYMENT_STATUSES = ['pending', 'paid'];

// Once payment is initiated the invoice can't be regenerated or adjusted.
function isPaymentFrozen(paymentStatus) {
  return FROZEN_PAYMENT_STATUSES.includes(paymentStatus);
}

function assertJobFound(job) {
  if (!job) throw httpError(404, 'Job not found');
}

function assertJobOwner(job, technician) {
  assertJobFound(job);
  if (!technician || job.lead_technician_id !== technician.id) {
    throw httpError(403, 'This technician is not assigned to this job');
  }
}

// Card-fee surcharge (invoice-payment's STRIPE_PASS_FEE): the customer pays
// Stripe's percentage + fixed fee on top of the invoice. The rate stays a
// decimal string ("0.029") and the math is exact integer arithmetic.

// "0.029" -> { num: 29n, den: 1000n }; null unless 0 <= rate < 1 with at
// most 6 decimals.
function parseFeePct(raw) {
  const s = String(raw ?? '').trim();
  const m = /^(0?)\.(\d{1,6})$|^0$/.exec(s);
  if (!m) return null;
  if (s === '0') return { num: 0n, den: 1n };
  return { num: BigInt(m[2]), den: 10n ** BigInt(m[2].length) };
}

// The charge total T so that T - S covers pct*T + fixed:
// T = ceil((S + fixed) / (1 - pct)), all integer cents.
function surchargeTotalCents(totalCents, pct, fixedCents) {
  if (!Number.isSafeInteger(totalCents) || totalCents < 0) throw httpError(400, 'Amount is not a number');
  if (!Number.isSafeInteger(fixedCents) || fixedCents < 0) throw httpError(500, 'Card processing fee is not configured correctly');
  const numerator = (BigInt(totalCents) + BigInt(fixedCents)) * pct.den;
  const denominator = pct.den - pct.num;
  return Number((numerator + denominator - 1n) / denominator);
}

// Last 6 characters of a Stripe id — the only part ever logged.
function tail6(id) {
  return id ? String(id).slice(-6) : 'none';
}

module.exports = {
  httpError,
  toCents,
  requireFeeRate,
  feeCentsFor,
  invoiceCents,
  storedFeeMatches,
  FROZEN_PAYMENT_STATUSES,
  isPaymentFrozen,
  assertJobFound,
  assertJobOwner,
  parseFeePct,
  surchargeTotalCents,
  tail6,
};
