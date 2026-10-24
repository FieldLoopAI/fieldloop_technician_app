// send-estimate-sms: ownership (lead technician), only draft/sent can be
// sent, and clear JSON errors ({ error, message }) with their codes —
// 401/400/403/404/409/422, 500 for missing Twilio configuration, 502 for a
// failed send. The SMS text itself is unchanged.
// Run with: node --test "test/*.test.js" (from send-estimate-sms/).
// Offline: auth, Supabase, Secrets Manager and Twilio are stubbed (the
// Supabase fake is generate-invoice-pdf's test double).
const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { fakeSupabase } = require('../../generate-invoice-pdf/test/fake_supabase');

const dir = path.join(__dirname, '..');
let currentDb = null;
let currentTech = null;
let secret = null;
let twilioFails = null;
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
  getSecret: async () => {
    if (secret instanceof Error) throw secret;
    return secret;
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

const { handler } = require('../index');

const TECH = { id: 'tech-1', contractor_id: 'contractor-1', full_name: 'Demo Tech' };
const CREDS = JSON.stringify({ accountSid: 'AC1', authToken: 'token', fromNumber: '+15550000000' });

function row(overrides = {}) {
  return {
    id: 'est-1', job_id: 'job-1', status: 'draft', voided_at: null, total_amount: 230,
    line_items: [{ description: 'Valve', amount: 150 }],
    jobs: { id: 'job-1', lead_technician_id: 'tech-1', customers: { primary_phone: '+15551112222' } },
    ...overrides,
  };
}

async function send(estimate, { tech = TECH, creds = CREDS, body } = {}) {
  currentDb = fakeSupabase({ job_estimates: estimate ? [estimate] : [] });
  currentTech = tech;
  secret = creds;
  sent.length = 0;
  const res = await handler({
    headers: { authorization: 'Bearer x' },
    body: body ?? JSON.stringify({ estimateId: 'est-1', pdfUrl: 'https://example.test/e.pdf' }),
  });
  return { res, json: JSON.parse(res.body), db: currentDb };
}

test.afterEach(() => { twilioFails = null; });

test('owner, draft: texts the customer (same message as before) and marks it sent', async () => {
  const { res, json, db } = await send(row());
  assert.equal(res.statusCode, 200);
  assert.deepEqual(json, { success: true });
  assert.equal(sent.length, 1);
  assert.equal(sent[0].to, '+15551112222');
  assert.equal(sent[0].from, '+15550000000');
  assert.equal(
    sent[0].body,
    'Your FieldLoop estimate is ready. Total: $230. Tap to view and approve: '
      + 'https://tqb5mpwlpf.execute-api.us-east-1.amazonaws.com/dev/estimates/est-1/view',
  );
  assert.equal(db.tables.job_estimates[0].status, 'sent');
});

test('an already sent estimate can be re-sent', async () => {
  const { res } = await send(row({ status: 'sent' }));
  assert.equal(res.statusCode, 200);
  assert.equal(sent.length, 1);
});

test('another technician\'s job -> 403, nothing sent', async () => {
  const { res, json, db } = await send(row(), { tech: { ...TECH, id: 'tech-2' } });
  assert.equal(res.statusCode, 403);
  assert.deepEqual(json, {
    error: 'This technician is not assigned to this job',
    message: 'You can only send estimates for jobs assigned to you.',
  });
  assert.equal(sent.length, 0);
  assert.equal(db.tables.job_estimates[0].status, 'draft');
});

test('unknown estimate -> 404', async () => {
  const { res, json } = await send(null);
  assert.equal(res.statusCode, 404);
  assert.deepEqual(json, { error: 'Estimate not found', message: 'This estimate could not be found.' });
});

test('approved / declined -> 409; voided -> 409; nothing sent or changed', async () => {
  for (const status of ['approved', 'declined']) {
    const { res, json, db } = await send(row({ status }));
    assert.equal(res.statusCode, 409);
    assert.deepEqual(json, {
      error: `Estimate is already ${status}`,
      message: 'The customer has already answered this estimate, so it cannot be sent again.',
    });
    assert.equal(sent.length, 0);
    assert.equal(db.tables.job_estimates[0].status, status);
  }
  const { res, json } = await send(row({ status: 'sent', voided_at: '2026-10-20T00:00:00Z' }));
  assert.equal(res.statusCode, 409);
  assert.deepEqual(json, { error: 'Estimate is voided', message: 'This estimate was voided and cannot be sent.' });
  assert.equal(sent.length, 0);
});

test('missing or incomplete Twilio secret -> 500, nothing sent', async () => {
  for (const creds of [new Error('ResourceNotFoundException: secret not found'), '{"accountSid":"AC1"}', 'not json']) {
    const { res, json, db } = await send(row(), { creds });
    assert.equal(res.statusCode, 500);
    assert.deepEqual(json, {
      error: 'Twilio credentials are not configured',
      message: "Texting isn't set up yet. Please contact support.",
    });
    assert.equal(sent.length, 0);
    assert.equal(db.tables.job_estimates[0].status, 'draft');
  }
});

test('Twilio send failure -> 502, status unchanged', async () => {
  twilioFails = new Error('Invalid To number');
  const { res, json, db } = await send(row());
  assert.equal(res.statusCode, 502);
  assert.deepEqual(json, {
    error: 'SMS send failed: Invalid To number',
    message: "The text message couldn't be sent. Check the customer's phone number and try again.",
  });
  assert.equal(db.tables.job_estimates[0].status, 'draft');
});

test('no customer phone -> 422', async () => {
  const { res, json } = await send(row({ jobs: { lead_technician_id: 'tech-1', customers: { primary_phone: null } } }));
  assert.equal(res.statusCode, 422);
  assert.deepEqual(json, {
    error: 'No customer phone number on file',
    message: 'This customer has no phone number on file. Add one before sending.',
  });
});

test('no session -> 401; missing estimateId -> 400', async () => {
  let { res, json } = await send(row(), { tech: null });
  assert.equal(res.statusCode, 401);
  assert.deepEqual(json, { error: 'Invalid session', message: 'Please sign in again.' });
  ({ res, json } = await send(row(), { body: '{}' }));
  assert.equal(res.statusCode, 400);
  assert.deepEqual(json, { error: 'estimateId is required', message: 'Something went wrong. Please try again.' });
});
