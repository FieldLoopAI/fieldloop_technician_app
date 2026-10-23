// Build 185 money check for /invoices/preview (the app's grossTotal):
// approved, unvoided change orders count; pending, declined and voided ones
// don't. Unlike generate-invoice-pdf, the preview takes the job's LATEST
// estimate whatever its status and reports estimateApproved=false for an
// unapproved one — pinned here as it is today. Offline: auth and Supabase
// are stubbed (the fake is generate-invoice-pdf's test double).
const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { fakeSupabase } = require('../../generate-invoice-pdf/test/fake_supabase');

const dir = path.join(__dirname, '..');
let currentDb = null;
const TECH = { id: 'tech-1', contractor_id: 'contractor-1', full_name: 'Demo Tech' };

function stub(file, exports) {
  const resolved = require.resolve(path.join(dir, 'shared', file));
  require.cache[resolved] = { id: resolved, filename: resolved, loaded: true, exports };
}
stub('auth.js', { requireTechnician: async () => TECH });
stub('supabaseClient.js', { getSupabaseClient: async () => currentDb });

const { handler } = require('../index');

const JOB_ID = '13be2358-5296-4d94-9a58-9d1662ac4902';
const co = (id, status, amount, voidedAt = null) => ({
  id, job_id: JOB_ID, status, additional_amount: amount, voided_at: voidedAt, description: id,
});

function seed(estimates, changeOrders = [], adjustments = []) {
  return {
    jobs: [{ id: JOB_ID, contractor_id: 'contractor-1', billable_hours: null }],
    contractor_financials: [{ contractor_id: 'contractor-1', platform_fee_rate: 0.0195 }],
    technicians: [{ id: 'tech-1', hourly_rate: null }],
    job_estimates: estimates,
    change_orders: changeOrders,
    invoice_adjustments: adjustments,
  };
}

async function preview(db) {
  currentDb = db;
  const res = await handler({ headers: { authorization: 'Bearer x' }, body: JSON.stringify({ jobId: JOB_ID }) });
  return { status: res.statusCode, body: JSON.parse(res.body) };
}

const approved = { id: 'est-1', job_id: JOB_ID, status: 'approved', voided_at: null, created_at: '2026-10-20T00:00:00Z', total_amount: 3000 };

test('(a)-(d): grossTotal = estimate + approved unvoided change orders + adjustments', async () => {
  const { status, body } = await preview(fakeSupabase(seed(
    [approved],
    [co('a', 'approved', 100), co('v', 'approved', 200, '2026-10-22T00:00:00Z'), co('p', 'pending', 400), co('d', 'declined', 800)],
    [{ id: 'adj', job_id: JOB_ID, amount: 50, created_at: '2026-10-21T00:00:00Z' }],
  )));
  assert.equal(status, 200);
  assert.equal(body.grossTotal, 3150);
  assert.deepEqual(body.approvedChangeOrders.map(c => c.id), ['a']);
  assert.deepEqual(body.pendingChangeOrders.map(c => c.id), ['p']);
  assert.deepEqual(body.declinedChangeOrders.map(c => c.id), ['d']);
  assert.deepEqual(body.voidedChangeOrders.map(c => c.id), ['v']);
  assert.equal(body.estimateApproved, true);
});

test('(e) as it is today: an unapproved latest estimate is previewed with estimateApproved=false', async () => {
  const { status, body } = await preview(fakeSupabase(seed([{ ...approved, status: 'draft' }])));
  assert.equal(status, 200);
  assert.equal(body.estimateApproved, false);
  assert.equal(body.grossTotal, 3000);
});
