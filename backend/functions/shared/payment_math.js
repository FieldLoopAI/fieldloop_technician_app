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
  tail6,
};
