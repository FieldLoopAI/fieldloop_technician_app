const test = require('node:test');
const assert = require('node:assert/strict');
const Stripe = require('stripe');
const { fakeSupabase } = require('./fake_supabase');
const {
  _handle: handle, _headerValue: headerValue, _normalizeWebhookSecret: normalizeWebhookSecret, _signatureDiagnostic: signatureDiagnostic,
} = require('../index');

// Offline only: constructEvent / generateTestHeaderString never call Stripe.
// Both values are dummy fixtures, not real credentials.
const stripe = new Stripe('sk_test_fixture_not_a_real_key');
const WEBHOOK_SECRET = 'whsec_fixture_not_a_real_secret';
const JOB_ID = '13be2358-5296-4d94-9a58-9d1662ac4902';

function seed(overrides = {}) {
  return {
    invoices: [{
      id: 'inv-1', job_id: JOB_ID, amount_cents: 361900, payment_status: 'pending',
      stripe_checkout_session_id: 'cs_test_abc', paid_at: null, stripe_payment_intent_id: null, ...overrides,
    }],
    stripe_events: [],
    jobs: [{ id: JOB_ID, status: 'in_progress' }],
  };
}

function stripeEvent(type, session, id = 'evt_test_1') {
  return { id, object: 'event', type, data: { object: { object: 'checkout.session', ...session } } };
}

function signed(payload, { secret = WEBHOOK_SECRET, base64 = false, headerName = 'stripe-signature', v1 = false } = {}) {
  const body = JSON.stringify(payload);
  const header = stripe.webhooks.generateTestHeaderString({ payload: body, secret });
  const event = {
    body: base64 ? Buffer.from(body).toString('base64') : body,
    isBase64Encoded: base64,
    headers: { [headerName]: header },
  };
  if (v1) {
    event.httpMethod = 'POST';
    event.headers = { 'Stripe-Signature': header };
  } else {
    event.requestContext = { http: { method: 'POST' } };
  }
  return event;
}

function deps(db, webhookSecret = WEBHOOK_SECRET) {
  return { getSupabaseClient: async () => db, getStripe: async () => ({ stripe, webhookSecret }) };
}

async function captureLogs(fn) {
  const lines = [];
  const original = console.log;
  console.log = (...args) => lines.push(args.join(' '));
  try {
    await fn();
  } finally {
    console.log = original;
  }
  return lines;
}

const paidSession = { id: 'cs_test_abc', payment_status: 'paid', amount_total: 361900, payment_intent: 'pi_test_xyz123' };

test('valid signature + completed + matching amount marks the invoice paid', async () => {
  const db = fakeSupabase(seed());
  const res = await handle(signed(stripeEvent('checkout.session.completed', paidSession)), deps(db));
  assert.equal(res.statusCode, 200);
  const inv = db.tables.invoices[0];
  assert.equal(inv.payment_status, 'paid');
  assert.ok(inv.paid_at);
  assert.equal(inv.stripe_payment_intent_id, 'pi_test_xyz123');
  assert.deepEqual(db.tables.stripe_events.map(e => e.id), ['evt_test_1']);
});

test('legacy paid_ts and stripe_payment_intent_ref mirror paid_at and stripe_payment_intent_id', async () => {
  const db = fakeSupabase(seed());
  await handle(signed(stripeEvent('checkout.session.completed', paidSession)), deps(db));
  const inv = db.tables.invoices[0];
  assert.ok(inv.paid_at);
  assert.equal(inv.paid_ts, inv.paid_at);
  assert.equal(inv.stripe_payment_intent_ref, 'pi_test_xyz123');
  assert.equal(inv.stripe_payment_intent_ref, inv.stripe_payment_intent_id);
});

test('expanded payment_intent object: both intent columns get its id', async () => {
  const db = fakeSupabase(seed());
  await handle(signed(stripeEvent('checkout.session.completed', { ...paidSession, payment_intent: { id: 'pi_test_obj999' } })), deps(db));
  const inv = db.tables.invoices[0];
  assert.equal(inv.stripe_payment_intent_id, 'pi_test_obj999');
  assert.equal(inv.stripe_payment_intent_ref, 'pi_test_obj999');
});

test('legacy columns stay untouched on an amount mismatch', async () => {
  const db = fakeSupabase(seed({ paid_ts: null, stripe_payment_intent_ref: null }));
  await handle(signed(stripeEvent('checkout.session.completed', { ...paidSession, amount_total: 1 })), deps(db));
  assert.equal(db.tables.invoices[0].paid_ts, null);
  assert.equal(db.tables.invoices[0].stripe_payment_intent_ref, null);
});

test('jobs.status is never written', async () => {
  const db = fakeSupabase(seed());
  await handle(signed(stripeEvent('checkout.session.completed', paidSession)), deps(db));
  assert.equal(db.calls.filter(c => c.table === 'jobs').length, 0);
  assert.equal(db.tables.jobs[0].status, 'in_progress');
});

test('base64 body (isBase64Encoded) verifies', async () => {
  const db = fakeSupabase(seed());
  const res = await handle(signed(stripeEvent('checkout.session.completed', paidSession), { base64: true }), deps(db));
  assert.equal(res.statusCode, 200);
  assert.equal(db.tables.invoices[0].payment_status, 'paid');
});

test('payload v1 with a mixed-case Stripe-Signature header verifies', async () => {
  const db = fakeSupabase(seed());
  const res = await handle(signed(stripeEvent('checkout.session.completed', paidSession), { v1: true }), deps(db));
  assert.equal(res.statusCode, 200);
  assert.equal(db.tables.invoices[0].payment_status, 'paid');
});

test('header lookup is case-insensitive and reads multiValueHeaders', () => {
  assert.equal(headerValue({ headers: { 'STRIPE-SIGNATURE': 'a' } }, 'stripe-signature'), 'a');
  assert.equal(headerValue({ headers: null, multiValueHeaders: { 'Stripe-Signature': ['b'] } }, 'stripe-signature'), 'b');
  assert.equal(headerValue({}, 'stripe-signature'), null);
});

test('wrong secret -> 400 and nothing written', async () => {
  const db = fakeSupabase(seed());
  const res = await handle(signed(stripeEvent('checkout.session.completed', paidSession), { secret: 'whsec_other_fixture' }), deps(db));
  assert.equal(res.statusCode, 400);
  assert.equal(db.calls.length, 0);
  assert.equal(db.tables.invoices[0].payment_status, 'pending');
});

test('tampered body -> 400', async () => {
  const db = fakeSupabase(seed());
  const event = signed(stripeEvent('checkout.session.completed', paidSession));
  event.body = event.body.replace('361900', '1');
  const res = await handle(event, deps(db));
  assert.equal(res.statusCode, 400);
  assert.equal(db.calls.length, 0);
});

test('missing signature header -> 400', async () => {
  const db = fakeSupabase(seed());
  const event = signed(stripeEvent('checkout.session.completed', paidSession));
  event.headers = {};
  assert.equal((await handle(event, deps(db))).statusCode, 400);
});

test('duplicate event id -> 200 without reprocessing', async () => {
  const db = fakeSupabase(seed());
  await handle(signed(stripeEvent('checkout.session.completed', paidSession)), deps(db));
  const firstPaidAt = db.tables.invoices[0].paid_at;
  db.tables.invoices[0].payment_status = 'pending'; // would be re-marked if reprocessed
  const res = await handle(signed(stripeEvent('checkout.session.completed', paidSession)), deps(db));
  assert.equal(res.statusCode, 200);
  assert.equal(JSON.parse(res.body).duplicate, true);
  assert.equal(db.tables.invoices[0].payment_status, 'pending');
  assert.equal(db.tables.invoices[0].paid_at, firstPaidAt);
});

test('amount mismatch is logged and not marked paid', async () => {
  const db = fakeSupabase(seed());
  const res = await handle(signed(stripeEvent('checkout.session.completed', { ...paidSession, amount_total: 361800 })), deps(db));
  assert.equal(res.statusCode, 200);
  assert.equal(db.tables.invoices[0].payment_status, 'pending');
  assert.equal(db.tables.invoices[0].paid_at, null);
});

test('completed but not yet paid (async method) does not mark paid; async_payment_succeeded does', async () => {
  const db = fakeSupabase(seed());
  await handle(signed(stripeEvent('checkout.session.completed', { ...paidSession, payment_status: 'unpaid' }, 'evt_a')), deps(db));
  assert.equal(db.tables.invoices[0].payment_status, 'pending');
  await handle(signed(stripeEvent('checkout.session.async_payment_succeeded', paidSession, 'evt_b')), deps(db));
  assert.equal(db.tables.invoices[0].payment_status, 'paid');
});

test('expired resets a pending invoice with the same session to unpaid', async () => {
  const db = fakeSupabase(seed());
  const res = await handle(signed(stripeEvent('checkout.session.expired', { id: 'cs_test_abc', payment_status: 'unpaid' })), deps(db));
  assert.equal(res.statusCode, 200);
  assert.equal(db.tables.invoices[0].payment_status, 'unpaid');
});

test('expired for an older session or a paid invoice changes nothing', async () => {
  const other = fakeSupabase(seed());
  await handle(signed(stripeEvent('checkout.session.expired', { id: 'cs_test_older' })), deps(other));
  assert.equal(other.tables.invoices[0].payment_status, 'pending');

  const paid = fakeSupabase(seed({ payment_status: 'paid' }));
  await handle(signed(stripeEvent('checkout.session.expired', { id: 'cs_test_abc' })), deps(paid));
  assert.equal(paid.tables.invoices[0].payment_status, 'paid');
});

test('unknown event type -> 200, no invoice change', async () => {
  const db = fakeSupabase(seed());
  const res = await handle(signed(stripeEvent('customer.created', { id: 'cus_1' })), deps(db));
  assert.equal(res.statusCode, 200);
  assert.equal(db.tables.invoices[0].payment_status, 'pending');
});

test('DB failure while marking paid -> 500 and the event is forgotten so the retry runs', async () => {
  const failing = fakeSupabase(seed(), { failOn: [{ table: 'invoices', op: 'update' }] });
  const res = await handle(signed(stripeEvent('checkout.session.completed', paidSession)), deps(failing));
  assert.equal(res.statusCode, 500);
  assert.deepEqual(failing.tables.stripe_events, []);

  const retryDb = fakeSupabase(failing.tables);
  const retry = await handle(signed(stripeEvent('checkout.session.completed', paidSession)), deps(retryDb));
  assert.equal(retry.statusCode, 200);
  assert.equal(retryDb.tables.invoices[0].payment_status, 'paid');
});

test('DB failure on the dedupe insert -> 500', async () => {
  const db = fakeSupabase(seed(), { failOn: [{ table: 'stripe_events', op: 'insert' }] });
  const res = await handle(signed(stripeEvent('checkout.session.completed', paidSession)), deps(db));
  assert.equal(res.statusCode, 500);
  assert.equal(db.tables.invoices[0].payment_status, 'pending');
});

test('secret normalization: whitespace and surrounding quotes are removed', () => {
  const variants = [
    WEBHOOK_SECRET, ` ${WEBHOOK_SECRET} `, `${WEBHOOK_SECRET}\n`, `"${WEBHOOK_SECRET}"`,
    `'${WEBHOOK_SECRET}'`, ` "${WEBHOOK_SECRET}"\r\n`, `\t'${WEBHOOK_SECRET}' `,
  ];
  variants.forEach((raw, i) => assert.equal(normalizeWebhookSecret(raw), WEBHOOK_SECRET, `variant ${i}`));
  assert.equal(normalizeWebhookSecret(null), '');
  assert.equal(normalizeWebhookSecret(' "" '), '');
});

for (const [label, stored] of [
  ['quoted', `"${WEBHOOK_SECRET}"`],
  ['padded', `  ${WEBHOOK_SECRET}\n`],
  ['quoted+padded', ` '${WEBHOOK_SECRET}' `],
]) {
  test(`a ${label} stored secret still verifies and marks paid`, async () => {
    const db = fakeSupabase(seed());
    const res = await handle(signed(stripeEvent('checkout.session.completed', paidSession)), deps(db, stored));
    assert.equal(res.statusCode, 200);
    assert.equal(db.tables.invoices[0].payment_status, 'paid');
  });
}

test('a secret that is only quotes/whitespace counts as missing (500, nothing written)', async () => {
  const db = fakeSupabase(seed());
  const res = await handle(signed(stripeEvent('checkout.session.completed', paidSession)), deps(db, ' "" '));
  assert.equal(res.statusCode, 500);
  assert.equal(db.calls.length, 0);
});

test('bad signature: 400, plus one diagnostic line with no secret or signature text', async () => {
  const db = fakeSupabase(seed());
  const event = signed(stripeEvent('checkout.session.completed', paidSession), { secret: 'whsec_other_fixture' });
  const bodyBytes = Buffer.byteLength(event.body);
  let res;
  const lines = await captureLogs(async () => { res = await handle(event, deps(db)); });
  assert.equal(res.statusCode, 400);
  assert.equal(JSON.parse(res.body).error, 'Bad signature');
  assert.equal(db.calls.length, 0);
  const diag = lines.filter(l => l.includes('bad signature diag'));
  assert.deepEqual(diag, [
    `STRIPE WEBHOOK: bad signature diag secretStartsWithWhsec=true secretLength=${WEBHOOK_SECRET.length} bodyBytes=${bodyBytes}`,
  ]);
  const all = lines.join('\n');
  assert.equal(all.includes(WEBHOOK_SECRET), false);
  assert.equal(all.includes(WEBHOOK_SECRET.slice(6)), false);
  assert.equal(all.includes(event.headers['stripe-signature']), false);
  assert.equal(/v1=[0-9a-f]{16,}/.test(all), false);
});

test('diagnostic reports a non-whsec secret and the body size without any content', () => {
  const line = signatureDiagnostic('sk_test_wrong_kind_fixture', Buffer.from('{"a":1}'));
  assert.equal(line, 'STRIPE WEBHOOK: bad signature diag secretStartsWithWhsec=false secretLength=26 bodyBytes=7');
  assert.equal(line.includes('sk_test'), false);
});

test('missing signature still returns 400 "Missing signature" with no diagnostics', async () => {
  const db = fakeSupabase(seed());
  const event = signed(stripeEvent('checkout.session.completed', paidSession));
  event.headers = {};
  let res;
  const lines = await captureLogs(async () => { res = await handle(event, deps(db)); });
  assert.equal(res.statusCode, 400);
  assert.equal(JSON.parse(res.body).error, 'Missing signature');
  assert.equal(lines.some(l => l.includes('diag')), false);
});
