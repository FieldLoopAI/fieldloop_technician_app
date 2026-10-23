const test = require('node:test');
const assert = require('node:assert/strict');
const { fakeSupabase } = require('./fake_supabase');
const { _handle: handle, _passFeeConfig: passFeeConfig } = require('../index');
const { parseFeePct, surchargeTotalCents, feeCentsFor } = require('../shared/payment_math');

// Build 185 card-fee surcharge (STRIPE_PASS_FEE). Offline: Stripe and
// Supabase are fakes.

const JOB_ID = '13be2358-5296-4d94-9a58-9d1662ac4902';
const TECH = { id: 'tech-1', contractor_id: 'contractor-1', full_name: 'Demo Tech' };
const ACCT = 'acct_1UTF0B0zMj9YCEEe';
const ENV_KEYS = ['STRIPE_PASS_FEE', 'STRIPE_FEE_PCT', 'STRIPE_FEE_FIXED_CENTS'];

function seed(overrides = {}) {
  return {
    jobs: [{ id: JOB_ID, job_id_public: 'FL-1BA500', contractor_id: 'contractor-1', lead_technician_id: 'tech-1' }],
    invoices: [{
      id: 'inv-1', job_id: JOB_ID, invoice_number: 'INV-12345678', created_at: '2026-10-22T10:00:00Z',
      total: 4287.35, platform_fee: 83.60, platform_fee_rate: 0.0195, payment_status: 'unpaid',
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

const deps = (db, stripeFake) => ({
  requireTechnician: async () => TECH,
  getSupabaseClient: async () => db,
  getStripe: async () => ({ stripe: stripeFake.stripe, webhookSecret: 'unused' }),
});

const checkoutEvent = invoiceId => ({
  routeKey: 'POST /invoices/checkout',
  requestContext: { http: { method: 'POST' } },
  headers: { authorization: 'Bearer x' },
  body: JSON.stringify({ invoiceId }),
});

const statusEvent = {
  routeKey: 'GET /invoices/payment-status',
  requestContext: { http: { method: 'GET' } },
  headers: { authorization: 'Bearer x' },
  queryStringParameters: { jobId: JOB_ID },
};

async function withEnv(values, fn) {
  const saved = Object.fromEntries(ENV_KEYS.map(k => [k, process.env[k]]));
  for (const k of ENV_KEYS) delete process.env[k];
  Object.assign(process.env, values);
  try {
    return await fn();
  } finally {
    for (const k of ENV_KEYS) {
      if (saved[k] === undefined) delete process.env[k];
      else process.env[k] = saved[k];
    }
  }
}

async function runCheckout(env, overrides) {
  return withEnv(env, async () => {
    const db = fakeSupabase(seed(overrides));
    const stripeFake = fakeStripe();
    const res = await handle(checkoutEvent('inv-1'), deps(db, stripeFake));
    const created = stripeFake.created[0];
    if (created) delete created.params.expires_at; // time-dependent
    return { res, body: JSON.parse(res.body), created, invoice: db.tables.invoices[0] };
  });
}

const PCT = parseFeePct('0.029');

// ---------------------------------------------------------------- the math

test('parseFeePct: exact decimal rates only, 0 <= rate < 1', () => {
  assert.deepEqual(parseFeePct('0.029'), { num: 29n, den: 1000n });
  assert.deepEqual(parseFeePct('.035'), { num: 35n, den: 1000n });
  assert.deepEqual(parseFeePct('0'), { num: 0n, den: 1n });
  for (const bad of ['', '1', '1.0', '-0.029', '2.9%', 'abc', '0.0290001', null, undefined]) {
    assert.equal(parseFeePct(bad), null, String(bad));
  }
});

test('T = ceil((S + fixed) / (1 - pct)): T - S covers pct*T + fixed, by less than 1 cent', () => {
  const cases = [];
  for (let s = 1; s <= 20000; s++) cases.push(s);
  for (let s = 20000; s <= 2000000; s += 997) cases.push(s);
  cases.push(428735, 361900, 99999999, 123456789);
  for (const [pctStr, fixed] of [['0.029', 30], ['0.035', 0], ['0.0275', 25], ['0', 30], ['0.1', 1]]) {
    const pct = parseFeePct(pctStr);
    for (const s of cases) {
      const t = surchargeTotalCents(s, pct, fixed);
      assert.ok(Number.isSafeInteger(t), `${s}`);
      // Exact rational check, scaled by den: slack = (T - S - fixed)*den - num*T, in [0, den).
      const slack = (BigInt(t - s - fixed)) * pct.den - pct.num * BigInt(t);
      assert.ok(slack >= 0n, `under-covers S=${s} pct=${pctStr}`);
      assert.ok(slack < pct.den, `over 1 cent S=${s} pct=${pctStr}`);
    }
  }
});

test('contractor net is exactly S - platform fee; platform net is the platform fee (+0 or 1 cent)', () => {
  for (let s = 100; s <= 1000000; s += 389) {
    const t = surchargeTotalCents(s, PCT, 30);
    const processing = t - s;
    const fee = feeCentsFor(s, 0.0195);
    const applicationFee = processing + fee;
    assert.equal(t - applicationFee, s - fee);
    // Stripe's own fee on T: 2.9% rounded half-up to the cent, plus 30.
    const stripeFee = Number((29n * BigInt(t) + 500n) / 1000n) + 30;
    const platformNet = applicationFee - stripeFee;
    assert.ok(platformNet === fee || platformNet === fee + 1, `S=${s} platformNet=${platformNet} fee=${fee}`);
  }
});

test('worked example: $4,287.35 at 1.95%', () => {
  const s = 428735;
  const t = surchargeTotalCents(s, PCT, 30);
  const fee = feeCentsFor(s, 0.0195);
  assert.equal(t, 441571);
  assert.equal(t - s, 12836);
  assert.equal(fee, 8360);
  assert.equal(t - s + fee, 21196);
  assert.equal(t - (t - s + fee), 420375);
});

// ------------------------------------------------------------ the config

test('passFeeConfig: off unless exactly "true"; defaults 0.029 + 30; bad config refused', () => {
  for (const off of [undefined, '', 'false', 'TRUE', 'True', '1', 'yes', ' true']) {
    assert.equal(passFeeConfig(off === undefined ? {} : { STRIPE_PASS_FEE: off }), null, String(off));
  }
  assert.deepEqual(passFeeConfig({ STRIPE_PASS_FEE: 'true' }), { pct: { num: 29n, den: 1000n }, fixedCents: 30 });
  assert.deepEqual(
    passFeeConfig({ STRIPE_PASS_FEE: 'true', STRIPE_FEE_PCT: '0.035', STRIPE_FEE_FIXED_CENTS: '0' }),
    { pct: { num: 35n, den: 1000n }, fixedCents: 0 },
  );
  for (const bad of [{ STRIPE_FEE_PCT: '2.9' }, { STRIPE_FEE_PCT: '1' }, { STRIPE_FEE_FIXED_CENTS: '-5' }, { STRIPE_FEE_FIXED_CENTS: '0.3' }]) {
    assert.throws(() => passFeeConfig({ STRIPE_PASS_FEE: 'true', ...bad }), err => err.statusCode === 500);
  }
});

// ----------------------------------------------------------- env off path

test('env off (unset, "false", "TRUE", "1"): Stripe params, row write and reply are exactly today\'s', async () => {
  const baseline = await runCheckout({});
  assert.equal(baseline.res.statusCode, 200);
  assert.deepEqual(baseline.created.params.line_items, [{
    price_data: { currency: 'usd', unit_amount: 428735, product_data: { name: 'Invoice INV-12345678 - FL-1BA500' } },
    quantity: 1,
  }]);
  assert.equal(baseline.created.params.payment_intent_data.application_fee_amount, 8360);
  assert.deepEqual(Object.keys(baseline.body).sort(), ['amountCents', 'feeCents', 'sessionId', 'url']);
  assert.equal(baseline.invoice.processing_fee_cents, undefined);
  assert.equal(baseline.invoice.charge_total_cents, undefined);

  for (const value of ['false', 'TRUE', '1']) {
    const other = await runCheckout({ STRIPE_PASS_FEE: value, STRIPE_FEE_PCT: '0.05' });
    assert.deepEqual(other.created, baseline.created, value);
    assert.deepEqual(other.body, baseline.body, value);
    const { payment_initiated_at: _a, ...rowA } = other.invoice;
    const { payment_initiated_at: _b, ...rowB } = baseline.invoice;
    assert.deepEqual(rowA, rowB, value);
  }
});

test('env off: payment-status reply has no new fields', async () => {
  await withEnv({}, async () => {
    const db = fakeSupabase(seed({ processing_fee_cents: 12836, charge_total_cents: 441571 }));
    const res = await handle(statusEvent, deps(db, fakeStripe()));
    assert.deepEqual(Object.keys(JSON.parse(res.body).invoice).sort(),
      ['id', 'invoice_number', 'paid_at', 'payment_status', 'total']);
  });
});

// ------------------------------------------------------------ env on path

test('env on: second "Card processing fee" line, Checkout total T, application fee = processing + platform', async () => {
  const { res, body, created, invoice } = await runCheckout({ STRIPE_PASS_FEE: 'true' });
  assert.equal(res.statusCode, 200);
  const items = created.params.line_items;
  assert.equal(items.length, 2);
  assert.equal(items[0].price_data.unit_amount, 428735);
  assert.deepEqual(items[1], {
    price_data: { currency: 'usd', unit_amount: 12836, product_data: { name: 'Card processing fee' } },
    quantity: 1,
  });
  assert.equal(items.reduce((sum, i) => sum + i.price_data.unit_amount * i.quantity, 0), 441571);
  assert.equal(created.params.payment_intent_data.application_fee_amount, 21196);
  assert.deepEqual(created.params.payment_intent_data.transfer_data, { destination: ACCT });

  assert.equal(invoice.amount_cents, 428735);
  assert.equal(invoice.application_fee_cents, 8360);
  assert.equal(invoice.processing_fee_cents, 12836);
  assert.equal(invoice.charge_total_cents, 441571);
  assert.equal(body.amountCents, 428735);
  assert.equal(body.feeCents, 8360);
  assert.equal(body.processingFeeCents, 12836);
  assert.equal(body.chargeTotalCents, 441571);
});

test('env on: reusing an open session returns the stored processing fee and total', async () => {
  await withEnv({ STRIPE_PASS_FEE: 'true' }, async () => {
    const db = fakeSupabase(seed({
      payment_status: 'pending', stripe_checkout_session_id: 'cs_test_open', amount_cents: 428735,
      application_fee_cents: 8360, processing_fee_cents: 12836, charge_total_cents: 441571,
    }));
    const stripeFake = fakeStripe();
    const body = JSON.parse((await handle(checkoutEvent('inv-1'), deps(db, stripeFake))).body);
    assert.equal(stripeFake.created.length, 0);
    assert.equal(body.processingFeeCents, 12836);
    assert.equal(body.chargeTotalCents, 441571);
  });
});

test('env on: payment-status returns processing_fee_cents and charge_total_cents', async () => {
  await withEnv({ STRIPE_PASS_FEE: 'true' }, async () => {
    const db = fakeSupabase(seed({ processing_fee_cents: 12836, charge_total_cents: 441571 }));
    const invoice = JSON.parse((await handle(statusEvent, deps(db, fakeStripe()))).body).invoice;
    assert.equal(invoice.processing_fee_cents, 12836);
    assert.equal(invoice.charge_total_cents, 441571);
  });
});

test('env on with a bad rate: refused before any Stripe call or row write', async () => {
  const { res, created, invoice } = await runCheckout({ STRIPE_PASS_FEE: 'true', STRIPE_FEE_PCT: '2.9' });
  assert.equal(res.statusCode, 500);
  assert.equal(created, undefined);
  assert.equal(invoice.payment_status, 'unpaid');
});

test('env on: logs never contain amounts', async () => {
  const lines = [];
  const original = console.log;
  console.log = (...args) => lines.push(args.join(' '));
  try {
    await runCheckout({ STRIPE_PASS_FEE: 'true' });
  } finally {
    console.log = original;
  }
  const feeLine = lines.find(l => l.includes('card processing fee'));
  assert.ok(feeLine);
  assert.ok(!/12836|441571|21196/.test(feeLine));
});
