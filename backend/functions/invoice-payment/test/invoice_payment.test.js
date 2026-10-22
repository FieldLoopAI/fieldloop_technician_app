const test = require('node:test');
const assert = require('node:assert/strict');
const { fakeSupabase } = require('./fake_supabase');
const { _handle: handle, _routeOf: routeOf } = require('../index');

const JOB_ID = '13be2358-5296-4d94-9a58-9d1662ac4902';
const TECH = { id: 'tech-1', contractor_id: 'contractor-1', full_name: 'Demo Tech' };
const ACCT = 'acct_1UTF0B0zMj9YCEEe';

function seed(overrides = {}) {
  return {
    jobs: [{ id: JOB_ID, job_id_public: 'FL-1BA500', contractor_id: 'contractor-1', lead_technician_id: 'tech-1' }],
    invoices: [{
      id: 'inv-1', job_id: JOB_ID, invoice_number: 'INV-12345678', created_at: '2026-10-22T10:00:00Z',
      total: 3619, platform_fee: 70.57, platform_fee_rate: 0.0195, payment_status: 'unpaid',
      stripe_checkout_session_id: null, checkout_attempts: 0, ...overrides,
    }],
    contractor_financials: [{ contractor_id: 'contractor-1', stripe_account_id: ACCT }],
  };
}

function fakeStripe({ retrieveStatus = 'open' } = {}) {
  const created = [];
  return {
    created,
    stripe: {
      checkout: {
        sessions: {
          async create(params, opts) {
            created.push({ params, opts });
            const id = `cs_test_new${created.length}`;
            return { id, url: `https://checkout.stripe.com/c/pay/${id}`, status: 'open' };
          },
          async retrieve(id) {
            return { id, url: `https://checkout.stripe.com/c/pay/${id}`, status: retrieveStatus };
          },
        },
      },
    },
  };
}

function deps(db, stripeFake, tech = TECH) {
  return {
    requireTechnician: async () => tech,
    getSupabaseClient: async () => db,
    getStripe: async () => ({ stripe: stripeFake.stripe, webhookSecret: 'unused' }),
  };
}

const checkoutEvent = invoiceId => ({
  routeKey: 'POST /invoices/checkout',
  requestContext: { http: { method: 'POST' } },
  headers: { authorization: 'Bearer x' },
  body: JSON.stringify({ invoiceId }),
});

test('routes for payload v1 and v2, with the /dev stage prefix', () => {
  assert.deepEqual(routeOf({ routeKey: 'POST /invoices/checkout', requestContext: { http: { method: 'POST' } } }),
    { method: 'POST', path: '/invoices/checkout' });
  assert.deepEqual(routeOf({ requestContext: { http: { method: 'GET' } }, rawPath: '/dev/stripe/return' }),
    { method: 'GET', path: '/dev/stripe/return' });
  assert.deepEqual(routeOf({ httpMethod: 'GET', resource: '/invoices/payment-status' }),
    { method: 'GET', path: '/invoices/payment-status' });
});

test('checkout creates a destination-charge session with the stored amounts', async () => {
  const db = fakeSupabase(seed());
  const s = fakeStripe();
  const res = await handle(checkoutEvent('inv-1'), deps(db, s));
  assert.equal(res.statusCode, 200);
  const body = JSON.parse(res.body);
  assert.equal(body.amountCents, 361900);
  assert.equal(body.feeCents, 7057);
  assert.equal(body.sessionId, 'cs_test_new1');

  const { params, opts } = s.created[0];
  assert.equal(params.mode, 'payment');
  assert.deepEqual(params.payment_method_types, ['card']);
  assert.equal(params.line_items[0].price_data.currency, 'usd');
  assert.equal(params.line_items[0].price_data.unit_amount, 361900);
  assert.equal(params.line_items[0].price_data.product_data.name, 'Invoice INV-12345678 - FL-1BA500');
  assert.equal(params.line_items[0].quantity, 1);
  assert.equal(params.payment_intent_data.application_fee_amount, 7057);
  assert.equal(params.payment_intent_data.transfer_data.destination, ACCT);
  assert.deepEqual(params.payment_intent_data.metadata, { invoice_id: 'inv-1', job_id: JOB_ID });
  assert.deepEqual(params.metadata, { invoice_id: 'inv-1', job_id: JOB_ID });
  assert.equal(params.client_reference_id, 'inv-1');
  assert.ok(params.expires_at - Math.floor(Date.now() / 1000) >= 30 * 60);
  assert.equal(params.success_url, 'https://tqb5mpwlpf.execute-api.us-east-1.amazonaws.com/dev/stripe/return?status=success');
  assert.equal(params.cancel_url, 'https://tqb5mpwlpf.execute-api.us-east-1.amazonaws.com/dev/stripe/return?status=cancel');
  assert.equal(opts.idempotencyKey, 'invoice_inv-1_0');

  const inv = db.tables.invoices[0];
  assert.equal(inv.payment_status, 'pending');
  assert.equal(inv.stripe_checkout_session_id, 'cs_test_new1');
  assert.equal(inv.amount_cents, 361900);
  assert.equal(inv.application_fee_cents, 7057);
  assert.equal(inv.checkout_attempts, 1);
  assert.ok(inv.payment_initiated_at);
});

test('STRIPE_RETURN_BASE overrides the return URL base', async () => {
  process.env.STRIPE_RETURN_BASE = 'https://example.test/return';
  try {
    const s = fakeStripe();
    await handle(checkoutEvent('inv-1'), deps(fakeSupabase(seed()), s));
    assert.equal(s.created[0].params.success_url, 'https://example.test/return?status=success');
  } finally {
    delete process.env.STRIPE_RETURN_BASE;
  }
});

test('checkout refuses a technician who is not the job lead (403), no session', async () => {
  const s = fakeStripe();
  const res = await handle(checkoutEvent('inv-1'), deps(fakeSupabase(seed()), s, { id: 'tech-2' }));
  assert.equal(res.statusCode, 403);
  assert.equal(s.created.length, 0);
});

test('checkout refuses when a newer invoice exists', async () => {
  const data = seed();
  data.invoices.push({ ...data.invoices[0], id: 'inv-2', created_at: '2026-10-22T11:00:00Z' });
  const s = fakeStripe();
  const res = await handle(checkoutEvent('inv-1'), deps(fakeSupabase(data), s));
  assert.equal(res.statusCode, 409);
  assert.match(JSON.parse(res.body).error, /newer invoice/);
  assert.equal(s.created.length, 0);
});

test('checkout refuses a paid invoice', async () => {
  const s = fakeStripe();
  const res = await handle(checkoutEvent('inv-1'), deps(fakeSupabase(seed({ payment_status: 'paid' })), s));
  assert.equal(res.statusCode, 409);
  assert.equal(s.created.length, 0);
});

test('pending + open session returns the same url without a new session', async () => {
  const db = fakeSupabase(seed({ payment_status: 'pending', stripe_checkout_session_id: 'cs_test_old', checkout_attempts: 1, amount_cents: 361900, application_fee_cents: 7057 }));
  const s = fakeStripe({ retrieveStatus: 'open' });
  const res = await handle(checkoutEvent('inv-1'), deps(db, s));
  assert.equal(res.statusCode, 200);
  assert.equal(JSON.parse(res.body).sessionId, 'cs_test_old');
  assert.equal(s.created.length, 0);
});

test('pending + expired session creates a new one with the next idempotency key', async () => {
  const db = fakeSupabase(seed({ payment_status: 'pending', stripe_checkout_session_id: 'cs_test_old', checkout_attempts: 1 }));
  const s = fakeStripe({ retrieveStatus: 'expired' });
  const res = await handle(checkoutEvent('inv-1'), deps(db, s));
  assert.equal(res.statusCode, 200);
  assert.equal(s.created[0].opts.idempotencyKey, 'invoice_inv-1_1');
  assert.equal(db.tables.invoices[0].stripe_checkout_session_id, 'cs_test_new1');
  assert.equal(db.tables.invoices[0].checkout_attempts, 2);
});

test('pending + complete session never opens a second charge', async () => {
  const s = fakeStripe({ retrieveStatus: 'complete' });
  const res = await handle(checkoutEvent('inv-1'),
    deps(fakeSupabase(seed({ payment_status: 'pending', stripe_checkout_session_id: 'cs_test_old' })), s));
  assert.equal(res.statusCode, 409);
  assert.equal(s.created.length, 0);
});

test('stored fee that disagrees with the rate by more than 1 cent is refused', async () => {
  const s = fakeStripe();
  const res = await handle(checkoutEvent('inv-1'), deps(fakeSupabase(seed({ platform_fee: 72.38 })), s));
  assert.equal(res.statusCode, 409);
  assert.equal(s.created.length, 0);
});

test('missing fee rate is refused (no fallback)', async () => {
  const s = fakeStripe();
  const res = await handle(checkoutEvent('inv-1'), deps(fakeSupabase(seed({ platform_fee_rate: null })), s));
  assert.equal(res.statusCode, 400);
  assert.match(JSON.parse(res.body).error, /Platform fee rate/);
  assert.equal(s.created.length, 0);
});

test('missing connected account is refused', async () => {
  const data = seed();
  data.contractor_financials[0].stripe_account_id = null;
  const s = fakeStripe();
  const res = await handle(checkoutEvent('inv-1'), deps(fakeSupabase(data), s));
  assert.equal(res.statusCode, 409);
  assert.match(JSON.parse(res.body).error, /no Stripe account/);
  assert.equal(s.created.length, 0);
});

test('checkout never writes jobs', async () => {
  const db = fakeSupabase(seed());
  await handle(checkoutEvent('inv-1'), deps(db, fakeStripe()));
  assert.equal(db.calls.filter(c => c.table === 'jobs' && c.op !== 'select').length, 0);
});

test('payment-status returns the latest invoice for the lead technician', async () => {
  const data = seed({ payment_status: 'pending' });
  const event = { routeKey: 'GET /invoices/payment-status', requestContext: { http: { method: 'GET' } }, queryStringParameters: { jobId: JOB_ID } };
  const res = await handle(event, deps(fakeSupabase(data), fakeStripe()));
  assert.equal(res.statusCode, 200);
  assert.deepEqual(JSON.parse(res.body), {
    invoice: { id: 'inv-1', invoice_number: 'INV-12345678', payment_status: 'pending', paid_at: null, total: 3619 },
  });
});

test('payment-status refuses another technician and returns null with no invoice', async () => {
  const event = { routeKey: 'GET /invoices/payment-status', requestContext: { http: { method: 'GET' } }, queryStringParameters: { jobId: JOB_ID } };
  const refused = await handle(event, deps(fakeSupabase(seed()), fakeStripe(), { id: 'tech-2' }));
  assert.equal(refused.statusCode, 403);
  const empty = seed();
  empty.invoices = [];
  const none = await handle(event, deps(fakeSupabase(empty), fakeStripe()));
  assert.deepEqual(JSON.parse(none.body), { invoice: null });
});

test('/stripe/return is a static page with no auth and no data', async () => {
  let authCalled = false;
  const res = await handle(
    { requestContext: { http: { method: 'GET' } }, rawPath: '/dev/stripe/return', queryStringParameters: { status: 'success' } },
    { requireTechnician: async () => { authCalled = true; }, getSupabaseClient: async () => { throw new Error('no'); }, getStripe: async () => { throw new Error('no'); } },
  );
  assert.equal(res.statusCode, 200);
  assert.match(res.body, /Thank you\. You can return to the FieldLoop app\./);
  assert.equal(authCalled, false);
});
