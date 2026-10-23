const test = require('node:test');
const assert = require('node:assert/strict');
const Stripe = require('stripe');
const { fakeSupabase } = require('./fake_supabase');
const { _handle: handle } = require('../index');

// Build 185 card-fee surcharge: rows with charge_total_cents are checked
// against it; older rows exactly as before. Offline only — dummy fixtures,
// not real credentials.
const stripe = new Stripe('sk_test_fixture_not_a_real_key');
const WEBHOOK_SECRET = 'whsec_fixture_not_a_real_secret';
const JOB_ID = '13be2358-5296-4d94-9a58-9d1662ac4902';

function seed(overrides = {}) {
  return {
    invoices: [{
      id: 'inv-1', job_id: JOB_ID, amount_cents: 428735, payment_status: 'pending',
      stripe_checkout_session_id: 'cs_test_abc', paid_at: null, stripe_payment_intent_id: null, ...overrides,
    }],
    stripe_events: [],
  };
}

function signedCompleted(amountTotal, id = 'evt_test_1') {
  const body = JSON.stringify({
    id, object: 'event', type: 'checkout.session.completed',
    data: { object: { object: 'checkout.session', id: 'cs_test_abc', payment_status: 'paid', amount_total: amountTotal, payment_intent: 'pi_test_xyz123' } },
  });
  return {
    body,
    isBase64Encoded: false,
    headers: { 'stripe-signature': stripe.webhooks.generateTestHeaderString({ payload: body, secret: WEBHOOK_SECRET }) },
    requestContext: { http: { method: 'POST' } },
  };
}

const deps = db => ({ getSupabaseClient: async () => db, getStripe: async () => ({ stripe, webhookSecret: WEBHOOK_SECRET }) });

async function run(row, amountTotal) {
  const db = fakeSupabase(seed(row));
  const lines = [];
  const original = console.log;
  console.log = (...args) => lines.push(args.join(' '));
  let res;
  try {
    res = await handle(signedCompleted(amountTotal), deps(db));
  } finally {
    console.log = original;
  }
  return { res, invoice: db.tables.invoices[0], lines };
}

test('old row (no charge_total_cents): paid when amount_total equals amount_cents', async () => {
  for (const row of [{}, { charge_total_cents: null }, { charge_total_cents: 0 }]) {
    const { res, invoice } = await run(row, 428735);
    assert.equal(res.statusCode, 200);
    assert.equal(invoice.payment_status, 'paid');
  }
});

test('old row: a different amount_total is not marked paid (unchanged mismatch path)', async () => {
  const { res, invoice, lines } = await run({}, 441571);
  assert.equal(res.statusCode, 200);
  assert.equal(invoice.payment_status, 'pending');
  assert.ok(lines.some(l => l.includes('AMOUNT MISMATCH') && l.includes('sessionCents=441571')));
  assert.ok(lines.some(l => l.includes('outcome=amount_mismatch')));
});

test('new row: paid when amount_total equals charge_total_cents', async () => {
  const { res, invoice } = await run({ processing_fee_cents: 12836, charge_total_cents: 441571 }, 441571);
  assert.equal(res.statusCode, 200);
  assert.equal(invoice.payment_status, 'paid');
  assert.equal(invoice.stripe_payment_intent_id, 'pi_test_xyz123');
});

test('new row: the bare invoice amount (no processing fee) is NOT accepted', async () => {
  const { invoice, lines } = await run({ processing_fee_cents: 12836, charge_total_cents: 441571 }, 428735);
  assert.equal(invoice.payment_status, 'pending');
  assert.ok(lines.some(l => l.includes('outcome=amount_mismatch')));
});

test('new row: any other amount is not marked paid, and the mismatch log has no amounts', async () => {
  const { invoice, lines } = await run({ processing_fee_cents: 12836, charge_total_cents: 441571 }, 441570);
  assert.equal(invoice.payment_status, 'pending');
  const mismatch = lines.find(l => l.includes('AMOUNT MISMATCH'));
  assert.ok(mismatch);
  assert.ok(!/441570|441571|428735/.test(mismatch));
});
