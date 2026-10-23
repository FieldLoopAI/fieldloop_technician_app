// Build 185 money check: exactly what makes up invoices.total and
// platform_fee. Approved, unvoided change orders count; pending, declined
// and voided ones don't; only an approved, unvoided estimate can be
// invoiced; every invoice_adjustments row counts (a removed one is deleted,
// there is no voided state). Offline: auth, Supabase and S3 are stubbed.
const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { fakeSupabase } = require('./fake_supabase');

const dir = path.join(__dirname, '..');
let currentDb = null;
const TECH = { id: 'tech-1', contractor_id: 'contractor-1', full_name: 'Demo Tech' };

function stub(request, exports) {
  const resolved = require.resolve(request, { paths: [dir] });
  require.cache[resolved] = { id: resolved, filename: resolved, loaded: true, exports };
}
stub(path.join(dir, 'shared', 'auth.js'), { requireTechnician: async () => TECH });
stub(path.join(dir, 'shared', 'supabaseClient.js'), { getSupabaseClient: async () => currentDb });
stub('@aws-sdk/client-s3', {
  S3Client: class { async send() { return {}; } },
  PutObjectCommand: class { constructor(input) { this.input = input; } },
  GetObjectCommand: class { constructor(input) { this.input = input; } },
});
stub('@aws-sdk/s3-request-presigner', { getSignedUrl: async () => 'https://example.test/invoice.pdf' });

const { handler } = require('../index');

const JOB_ID = '13be2358-5296-4d94-9a58-9d1662ac4902';

function seed({ estimates, changeOrders = [], adjustments = [] }) {
  return {
    jobs: [{
      id: JOB_ID, contractor_id: 'contractor-1', lead_technician_id: 'tech-1', billable_hours: 2,
      service_address: '1 Main St', description: 'Demo', customers: { household_name: 'Demo Home' },
    }],
    field_events: [],
    contractors: [{ id: 'contractor-1', legal_name: 'Demo Contractor', contractor_compliance: null }],
    contractor_financials: [{ contractor_id: 'contractor-1', platform_fee_rate: 0.0195 }],
    job_estimates: estimates,
    change_orders: changeOrders,
    invoice_adjustments: adjustments,
    invoices: [],
  };
}

const approvedEstimate = { id: 'est-1', job_id: JOB_ID, status: 'approved', voided_at: null, created_at: '2026-10-20T00:00:00Z', total_amount: 3000, line_items: [] };
const co = (id, status, amount, voidedAt = null) => ({
  id, job_id: JOB_ID, status, additional_amount: amount, voided_at: voidedAt, void_reason: voidedAt ? 'test' : null,
  description: id, created_at: '2026-10-21T00:00:00Z',
});

async function generate(db) {
  currentDb = db;
  return handler({ headers: { authorization: 'Bearer x' }, body: JSON.stringify({ jobId: JOB_ID }) });
}

test('(a)-(d): approved change orders count; pending, declined and voided do not', async () => {
  const db = fakeSupabase(seed({
    estimates: [approvedEstimate],
    changeOrders: [
      co('co-approved', 'approved', 100),
      co('co-approved-voided', 'approved', 200, '2026-10-22T00:00:00Z'),
      co('co-pending', 'pending', 400),
      co('co-declined', 'declined', 800),
    ],
  }));
  const res = await generate(db);
  assert.equal(res.statusCode, 200);
  const inv = db.tables.invoices[0];
  assert.equal(inv.estimate_total, 3000);
  assert.equal(inv.approved_change_orders_total, 100);
  assert.equal(inv.total, 3100);
  assert.equal(inv.platform_fee, 60.45); // round(310000 * 0.0195) = 6045 cents
  assert.equal(inv.net_to_contractor, 3039.55);
});

test('(e): only a draft/sent/declined estimate -> nothing is invoiced', async () => {
  for (const status of ['draft', 'sent', 'declined']) {
    const db = fakeSupabase(seed({ estimates: [{ ...approvedEstimate, status }] }));
    const res = await generate(db);
    assert.equal(res.statusCode, 400, status);
    assert.equal(JSON.parse(res.body).error, 'No approved estimate');
    assert.equal(db.tables.invoices.length, 0);
  }
});

test('(e): a voided approved estimate is not invoiced either', async () => {
  const db = fakeSupabase(seed({ estimates: [{ ...approvedEstimate, voided_at: '2026-10-21T00:00:00Z' }] }));
  const res = await generate(db);
  assert.equal(res.statusCode, 400);
  assert.equal(db.tables.invoices.length, 0);
});

test('(e): a newer unapproved estimate is ignored; the approved one is invoiced', async () => {
  const db = fakeSupabase(seed({
    estimates: [approvedEstimate, { ...approvedEstimate, id: 'est-2', status: 'draft', created_at: '2026-10-22T00:00:00Z', total_amount: 9000 }],
  }));
  const res = await generate(db);
  assert.equal(res.statusCode, 200);
  assert.equal(db.tables.invoices[0].estimate_total, 3000);
});

test('(f): every adjustment row counts (fees and discounts); a removed one is simply gone', async () => {
  const db = fakeSupabase(seed({
    estimates: [approvedEstimate],
    adjustments: [
      { id: 'adj-1', job_id: JOB_ID, description: 'Disposal fee', amount: 50, created_at: '2026-10-21T00:00:00Z' },
      { id: 'adj-2', job_id: JOB_ID, description: 'Discount', amount: -25, created_at: '2026-10-21T01:00:00Z' },
    ],
  }));
  const res = await generate(db);
  assert.equal(res.statusCode, 200);
  assert.equal(db.tables.invoices[0].adjustments_total, 25);
  assert.equal(db.tables.invoices[0].total, 3025);
});
