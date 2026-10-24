// generate-estimate-pdf: only the job's lead technician gets a PDF.
// Run with: node --test "test/*.test.js" (from generate-estimate-pdf/).
// Offline: auth, Supabase and S3 are stubbed (the Supabase fake is
// generate-invoice-pdf's test double); pdfkit runs for real.
const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { fakeSupabase } = require('../../generate-invoice-pdf/test/fake_supabase');

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
stub('@aws-sdk/s3-request-presigner', { getSignedUrl: async () => 'https://example.test/estimate.pdf' });

const { handler } = require('../index');

function seed() {
  return {
    job_estimates: [{
      id: 'est-1', job_id: 'job-1', status: 'draft', total_amount: 230,
      line_items: [{ description: 'Valve', amount: 150 }, { description: 'Labor', amount: 80 }],
      jobs: {
        id: 'job-1', lead_technician_id: 'tech-1', service_address: '1 Main St',
        customers: { household_name: 'Demo Home' },
        contractors: {
          legal_name: 'Demo Contractor', physical_street: '2 Side St', physical_city: 'Town', physical_state: 'TX',
          contractor_compliance: null,
        },
      },
    }],
  };
}

async function generate(techId) {
  currentDb = fakeSupabase(seed());
  currentTech = { id: techId, contractor_id: 'contractor-1', full_name: 'Tech' };
  s3Puts.length = 0;
  const res = await handler({ headers: { authorization: 'Bearer x' }, body: JSON.stringify({ estimateId: 'est-1' }) });
  return { res, json: JSON.parse(res.body) };
}

test('the job\'s lead technician gets the PDF as before', async () => {
  const { res, json } = await generate('tech-1');
  assert.equal(res.statusCode, 200);
  assert.deepEqual(json, { pdfUrl: 'https://example.test/estimate.pdf', s3Key: 'job-1/estimate-est-1.pdf' });
  assert.equal(s3Puts.length, 1);
});

test('another technician -> 403, nothing generated or uploaded', async () => {
  const { res, json } = await generate('tech-2');
  assert.equal(res.statusCode, 403);
  assert.deepEqual(json, {
    error: 'This technician is not assigned to this job',
    message: 'You can only create estimates for jobs assigned to you.',
  });
  assert.equal(s3Puts.length, 0);
});
