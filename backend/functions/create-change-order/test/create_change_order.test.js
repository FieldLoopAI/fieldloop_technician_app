// create-change-order (manual form and voice flow): lead-technician
// ownership, checked job lookup, amount rules (finite, > 0, < 1,000,000,
// cents) on both paths, explicit error codes with { error, message }
// bodies, smsStatus next to the unchanged smsSent, and the SMS amount as
// $X.XX.
// Run with: node --test "test/*.test.js" (from create-change-order/).
// Offline: auth, Supabase, Secrets Manager, Twilio and fetch (Groq) are
// stubbed (the Supabase fake is generate-invoice-pdf's test double).
const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { fakeSupabase } = require('../../generate-invoice-pdf/test/fake_supabase');

const dir = path.join(__dirname, '..');
let currentDb = null;
let currentTech = null;
let twilioSecret = null;
let twilioFails = null;
let groq = null;
const sent = [];

function stub(request, exports) {
  const resolved = require.resolve(request, { paths: [dir] });
  require.cache[resolved] = { id: resolved, filename: resolved, loaded: true, exports };
}
stub(path.join(dir, 'shared', 'auth.js'), {
  requireTechnician: async () => {
    if (!currentTech) throw new Error('Invalid session');
    return currentTech;
  },
});
stub(path.join(dir, 'shared', 'supabaseClient.js'), { getSupabaseClient: async () => currentDb });
stub(path.join(dir, 'shared', 'secrets.js'), {
  getSecret: async (name) => {
    if (name === 'fieldloop/groq-api-key') return JSON.stringify({ apiKey: 'gk' });
    if (twilioSecret instanceof Error) throw twilioSecret;
    return twilioSecret;
  },
});
stub('twilio', () => ({
  messages: {
    create: async (msg) => {
      if (twilioFails) throw twilioFails;
      sent.push(msg);
      return { sid: 'SM1' };
    },
  },
}));

// Groq: `groq` is the parsed JSON response, or an Error the fetch throws.
global.fetch = async () => {
  if (groq instanceof Error) throw groq;
  return { ok: groq.ok ?? true, status: groq.status ?? 200, json: async () => groq.body };
};
const groqAmount = amount => ({ body: { choices: [{ message: { content: JSON.stringify({ amount }) } }] } });

const { handler } = require('../index');

const JOB_ID = 'job-1';
const TECH = { id: 'tech-1', contractor_id: 'contractor-1', full_name: 'Demo Tech' };
const CREDS = JSON.stringify({ accountSid: 'AC1', authToken: 'token', fromNumber: '+15550000000' });

function seed({ phone = '+15551112222', lead = 'tech-1' } = {}) {
  return { jobs: [{ id: JOB_ID, lead_technician_id: lead, customers: { primary_phone: phone } }], change_orders: [] };
}

async function create(input, { tech = TECH, db = fakeSupabase(seed()), creds = CREDS } = {}) {
  currentDb = db;
  currentTech = tech;
  twilioSecret = creds;
  sent.length = 0;
  const res = await handler({
    headers: { authorization: 'Bearer x' },
    body: typeof input === 'string' ? input : JSON.stringify({ jobId: JOB_ID, ...input }),
  });
  return { res, json: JSON.parse(res.body), db };
}

/** A db whose change_orders insert resolves to [result] instead of running. */
function withInsertResult(base, result) {
  return {
    ...base,
    from(table) {
      const b = base.from(table);
      if (table === 'change_orders') {
        b.insert = () => {
          const chain = { select: () => chain, single: () => chain };
          chain.then = (resolve, reject) => Promise.resolve(result).then(resolve, reject);
          return chain;
        };
      }
      return b;
    },
  };
}

test.afterEach(() => {
  twilioFails = null;
  groq = null;
});

test('manual: saves a pending change order, texts the customer; success shape unchanged plus smsStatus', async () => {
  const { res, json, db } = await create({ description: 'New valve', amount: 120.5 });
  assert.equal(res.statusCode, 200);
  assert.deepEqual(Object.keys(json), ['changeOrder', 'smsSent', 'smsStatus']);
  assert.equal(json.smsSent, true);
  assert.equal(json.smsStatus, 'sent');
  const row = db.tables.change_orders[0];
  assert.deepEqual(json.changeOrder, row);
  assert.equal(row.job_id, JOB_ID);
  assert.equal(row.technician_id, 'tech-1');
  assert.equal(row.description, 'New valve');
  assert.equal(row.additional_amount, 120.5);
  assert.equal(row.status, 'pending');
});

test('SMS amount is $X.XX; the rest of the text and the link are unchanged', async () => {
  const { json } = await create({ description: 'New valve', amount: 120.5 });
  assert.equal(sent.length, 1);
  assert.equal(
    sent[0].body,
    'Your technician found additional work needed: New valve. Additional cost: $120.50. Tap to review and approve: '
      + `https://tqb5mpwlpf.execute-api.us-east-1.amazonaws.com/dev/change-orders/${json.changeOrder.id}/approve`,
  );
  assert.equal(sent[0].to, '+15551112222');
  assert.equal(sent[0].from, '+15550000000');
});

test('manual amounts are rounded to cents', async () => {
  const { json } = await create({ description: 'x', amount: 19.999 });
  assert.equal(json.changeOrder.additional_amount, 20);
});

test('voice: no amount sent -> Groq extracts it (numeric string accepted), rounded to cents', async () => {
  groq = groqAmount('3600.004');
  const { res, json } = await create({ description: '200 square feet at $18 per square foot' });
  assert.equal(res.statusCode, 200);
  assert.equal(json.changeOrder.additional_amount, 3600);
  assert.equal(json.smsStatus, 'sent');
  assert.match(sent[0].body, /Additional cost: \$3600\.00\./);
});

test('not the lead technician -> 403, nothing saved or sent', async () => {
  const { res, json, db } = await create({ description: 'x', amount: 10 }, { tech: { ...TECH, id: 'tech-2' } });
  assert.equal(res.statusCode, 403);
  assert.deepEqual(json, {
    error: 'This technician is not assigned to this job',
    message: 'You can only add change orders to jobs assigned to you.',
  });
  assert.equal(db.tables.change_orders.length, 0);
  assert.equal(sent.length, 0);
});

test('unknown job -> 404', async () => {
  const { res, json } = await create({ description: 'x', amount: 10 }, { db: fakeSupabase({ jobs: [], change_orders: [] }) });
  assert.equal(res.statusCode, 404);
  assert.deepEqual(json, { error: 'Job not found', message: 'This job could not be found.' });
});

test('job lookup error -> 500, nothing saved', async () => {
  const db = fakeSupabase(seed(), { failOn: [{ table: 'jobs', op: 'select' }] });
  const { res, json } = await create({ description: 'x', amount: 10 }, { db });
  assert.equal(res.statusCode, 500);
  assert.deepEqual(json, {
    error: 'injected select failure on jobs',
    message: 'Saving the change order failed. Please try again.',
  });
  assert.equal(db.tables.change_orders.length, 0);
});

test('bad manual amounts -> 400, nothing saved', async () => {
  for (const amount of [0, -5, 'NaN', 1e9, 1000000, '120', 'abc', true, {}]) {
    const { res, json, db } = await create({ description: 'x', amount });
    assert.equal(res.statusCode, 400, JSON.stringify(amount));
    assert.deepEqual(json, {
      error: 'The amount must be a positive number below 1,000,000',
      message: 'The amount must be more than $0.00 and less than $1,000,000.00.',
    });
    assert.equal(db.tables.change_orders.length, 0);
  }
  // A NaN number can't travel in JSON; the closest is a raw body with it.
  const { res } = await create(`{"jobId":"${JOB_ID}","description":"x","amount":NaN}`);
  assert.equal(res.statusCode, 400);
});

test('bad Groq amounts -> 400 with the unreadable message', async () => {
  for (const amount of [0, -5, 'abc', 1e9, null]) {
    groq = groqAmount(amount);
    const { res, json, db } = await create({ description: 'some work' });
    assert.equal(res.statusCode, 400, JSON.stringify(amount));
    assert.equal(json.message, "We couldn't read that change order. Please try again.");
    assert.equal(db.tables.change_orders.length, 0);
  }
});

test('empty description -> 400', async () => {
  for (const description of ['', '   ', undefined]) {
    const { res, json } = await create({ description, amount: 10 });
    assert.equal(res.statusCode, 400);
    assert.deepEqual(json, { error: 'A description is required', message: 'Add a description of the additional work.' });
  }
});

test('payment-lock refusal from the database -> 409', async () => {
  const db = withInsertResult(fakeSupabase(seed()), {
    data: null, error: { code: 'P0001', message: 'Payment started - invoice is locked' },
  });
  const { res, json } = await create({ description: 'x', amount: 10 }, { db });
  assert.equal(res.statusCode, 409);
  assert.deepEqual(json, {
    error: 'Payment started - invoice is locked',
    message: 'Payment has started on this job, so change orders are locked.',
  });
  assert.equal(sent.length, 0);
});

test('other insert error -> 500', async () => {
  const db = fakeSupabase(seed(), { failOn: [{ table: 'change_orders', op: 'insert' }] });
  const { res, json } = await create({ description: 'x', amount: 10 }, { db });
  assert.equal(res.statusCode, 500);
  assert.equal(json.message, 'Saving the change order failed. Please try again.');
});

test('Groq failure (network, error status, no choices) -> 502, nothing saved', async () => {
  for (const failure of [
    new Error('fetch failed'),
    { ok: false, status: 503, body: { error: { message: 'Service unavailable' } } },
    { body: { choices: [] } },
  ]) {
    groq = failure;
    const { res, json, db } = await create({ description: 'some work' });
    assert.equal(res.statusCode, 502);
    assert.match(json.error, /^Groq request failed: /);
    assert.equal(json.message, "We couldn't read that change order. Please try again.");
    assert.equal(db.tables.change_orders.length, 0);
  }
});

test('smsStatus: no_phone, not_configured, failed — the change order is saved every time', async () => {
  let r = await create({ description: 'x', amount: 10 }, { db: fakeSupabase(seed({ phone: null })) });
  assert.equal(r.res.statusCode, 200);
  assert.equal(r.json.smsStatus, 'no_phone');
  assert.equal(r.json.smsSent, false);
  assert.equal(r.db.tables.change_orders.length, 1);

  for (const creds of [new Error('ResourceNotFoundException'), '{"accountSid":"AC1"}', 'not json']) {
    r = await create({ description: 'x', amount: 10 }, { creds });
    assert.equal(r.res.statusCode, 200);
    assert.equal(r.json.smsStatus, 'not_configured');
    assert.equal(r.json.smsSent, false);
    assert.equal(r.db.tables.change_orders.length, 1);
    assert.equal(sent.length, 0);
  }

  twilioFails = new Error('Invalid To number');
  r = await create({ description: 'x', amount: 10 });
  assert.equal(r.res.statusCode, 200);
  assert.equal(r.json.smsStatus, 'failed');
  assert.equal(r.json.smsSent, false);
  assert.equal(r.db.tables.change_orders.length, 1);
});

test('no session -> 401; bad body or missing jobId -> 400', async () => {
  let { res, json } = await create({ description: 'x', amount: 10 }, { tech: null });
  assert.equal(res.statusCode, 401);
  assert.deepEqual(json, { error: 'Invalid session', message: 'Please sign in again.' });

  ({ res, json } = await create('not json'));
  assert.equal(res.statusCode, 400);
  assert.deepEqual(json, {
    error: 'Request body is not valid JSON',
    message: "We couldn't read that change order. Please try again.",
  });

  ({ res, json } = await create(JSON.stringify({ description: 'x', amount: 10 })));
  assert.equal(res.statusCode, 400);
  assert.deepEqual(json, { error: 'jobId is required', message: "We couldn't read that change order. Please try again." });
});
