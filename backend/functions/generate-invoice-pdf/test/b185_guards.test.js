// Build 185 guards in generate-invoice-pdf: ownership, freeze-before-
// auto-close, approved-estimate selection and the no-fallback cents math.
// Run with: node --test "test/*.test.js" (from generate-invoice-pdf/).
// auth, supabase and S3 are stubbed in the require cache — nothing here
// touches the network.
const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { fakeSupabase } = require('./fake_supabase');

const dir = path.join(__dirname, '..');
let currentDb = null;
let currentTech = null;
const s3Puts = [];

function stub(request, exports) {
  const resolved = require.resolve(request, { paths: [dir] });
  require.cache[resolved] = { id: resolved, filename: resolved, loaded: true, exports };
}
stub(path.join(dir, 'shared', 'auth.js'), { requireTechnician: async () => currentTech });
stub(path.join(dir, 'shared', 'supabaseClient.js'), { getSupabaseClient: async () => currentDb });
stub('@aws-sdk/client-s3', {
  S3Client: class { async send(cmd) { s3Puts.push(cmd); return {}; } },
  PutObjectCommand: class { constructor(input) { this.input = input; } },
  GetObjectCommand: class { constructor(input) { this.input = input; } },
});
stub('@aws-sdk/s3-request-presigner', { getSignedUrl: async () => 'https://example.test/invoice.pdf' });

const { handler } = require('../index');

const JOB_ID = '13be2358-5296-4d94-9a58-9d1662ac4902';
const TECH = { id: 'tech-1', contractor_id: 'contractor-1', full_name: 'Demo Tech' };

function seed() {
  return {
    jobs: [{
      id: JOB_ID, contractor_id: 'contractor-1', lead_technician_id: 'tech-1', billable_hours: 2,
      service_address: '1 Main St', description: 'Demo', customers: { household_name: 'Demo Home' },
    }],
    // Open visit: arrived, never departed — the auto-close would fire.
    field_events: [{ id: 'fe-1', job_id: JOB_ID, event_type: 'gps_arrive', event_ts: '2026-10-22T08:00:00Z' }],
    contractors: [{ id: 'contractor-1', legal_name: 'Demo Contractor', contractor_compliance: null }],
    contractor_financials: [{ contractor_id: 'contractor-1', platform_fee_rate: 0.0195 }],
    job_estimates: [
      { id: 'est-old-voided', job_id: JOB_ID, status: 'approved', voided_at: '2026-10-20T00:00:00Z', created_at: '2026-10-19T00:00:00Z', total_amount: 9999, line_items: [] },
      { id: 'est-approved', job_id: JOB_ID, status: 'approved', voided_at: null, created_at: '2026-10-20T00:00:00Z', total_amount: 3619, line_items: [{ description: 'Work', amount: 3619 }] },
      { id: 'est-newer-draft', job_id: JOB_ID, status: 'draft', voided_at: null, created_at: '2026-10-21T00:00:00Z', total_amount: 5000, line_items: [] },
    ],
    change_orders: [],
    invoice_adjustments: [],
    invoices: [],
  };
}

function run(db, tech = TECH) {
  currentDb = db;
  currentTech = tech;
  return handler({ headers: { authorization: 'Bearer x' }, body: JSON.stringify({ jobId: JOB_ID }) });
}

const writes = db => db.calls.filter(c => c.op !== 'select');

test('happy path: newest approved, unvoided estimate; fee 7057 cents; net 354843 cents', async () => {
  const db = fakeSupabase(seed());
  const res = await run(db);
  assert.equal(res.statusCode, 200);
  const body = JSON.parse(res.body);
  assert.deepEqual(Object.keys(body).sort(), ['invoice', 'pdfUrl']);
  const inv = db.tables.invoices[0];
  assert.equal(inv.estimate_total, 3619);
  assert.equal(inv.total, 3619);
  assert.equal(inv.tax, 0);
  assert.equal(inv.platform_fee, 70.57);
  assert.equal(inv.platform_fee_rate, 0.0195);
  assert.equal(inv.net_to_contractor, 3548.43);
  assert.equal(inv.status, 'draft');
  // Unfrozen jobs still get the visit auto-close.
  assert.ok(db.tables.field_events.some(e => e.event_type === 'gps_depart'));
});

test('job not found -> 404, nothing written', async () => {
  const data = seed();
  data.jobs = [];
  const db = fakeSupabase(data);
  const res = await run(db);
  assert.equal(res.statusCode, 404);
  assert.deepEqual(writes(db), []);
});

test('another technician -> 403, nothing written', async () => {
  const db = fakeSupabase(seed());
  const res = await run(db, { id: 'tech-2' });
  assert.equal(res.statusCode, 403);
  assert.deepEqual(writes(db), []);
});

for (const status of ['pending', 'paid']) {
  test(`freeze: an invoice with payment_status ${status} refuses before the auto-close`, async () => {
    const data = seed();
    data.invoices = [{ id: 'inv-1', job_id: JOB_ID, payment_status: status }];
    const db = fakeSupabase(data);
    const putsBefore = s3Puts.length;
    const res = await run(db);
    assert.equal(res.statusCode, 409);
    assert.match(JSON.parse(res.body).error, /Payment has already started/);
    assert.deepEqual(writes(db), []);
    assert.equal(db.tables.field_events.length, 1);
    assert.equal(db.tables.invoices.length, 1);
    assert.equal(s3Puts.length, putsBefore);
  });
}

test('an unpaid earlier invoice does not freeze', async () => {
  const data = seed();
  data.invoices = [{ id: 'inv-0', job_id: JOB_ID, payment_status: 'unpaid' }];
  const res = await run(fakeSupabase(data));
  assert.equal(res.statusCode, 200);
});

test('no approved estimate -> "No approved estimate"', async () => {
  const data = seed();
  data.job_estimates = data.job_estimates.filter(e => e.id !== 'est-approved');
  const res = await run(fakeSupabase(data));
  assert.equal(res.statusCode, 400);
  assert.equal(JSON.parse(res.body).error, 'No approved estimate');
});

test('missing contractor_financials row -> error, no invoice', async () => {
  const data = seed();
  data.contractor_financials = [];
  const db = fakeSupabase(data);
  const res = await run(db);
  assert.equal(res.statusCode, 400);
  assert.match(JSON.parse(res.body).error, /Platform fee rate is not configured/);
  assert.equal(db.tables.invoices.length, 0);
});

for (const rate of [null, 0, -0.01, 'abc']) {
  test(`fee rate ${String(rate)} -> error, no 2% fallback`, async () => {
    const data = seed();
    data.contractor_financials[0].platform_fee_rate = rate;
    const db = fakeSupabase(data);
    const res = await run(db);
    assert.equal(res.statusCode, 400);
    assert.match(JSON.parse(res.body).error, /Platform fee rate is not configured/);
    assert.equal(db.tables.invoices.length, 0);
  });
}
