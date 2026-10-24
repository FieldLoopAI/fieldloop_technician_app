const { requireTechnician } = require('./shared/auth');
const { getSupabaseClient } = require('./shared/supabaseClient');
const { getSecret } = require('./shared/secrets');
const twilio = require('twilio');

const HEADERS = { 'Access-Control-Allow-Origin': '*' };

// A refusal with its HTTP status: `error` is the existing technical field,
// `message` a plain sentence the app can show as is.
class HttpError extends Error {
  constructor(statusCode, error, message) {
    super(error);
    this.statusCode = statusCode;
    this.plainMessage = message;
  }
}

async function loadTwilio() {
  let creds;
  try {
    creds = JSON.parse(await getSecret('fieldloop/twilio-credentials'));
  } catch (err) {
    console.error('send-estimate-sms: Twilio credentials unavailable:', err.message);
    creds = null;
  }
  if (!creds?.accountSid || !creds?.authToken || !creds?.fromNumber) {
    throw new HttpError(500, 'Twilio credentials are not configured',
      "Texting isn't set up yet. Please contact support.");
  }
  return creds;
}

exports.handler = async (event) => {
  try {
    let technician;
    try {
      technician = await requireTechnician(event);
    } catch (err) {
      throw new HttpError(401, err.message, 'Please sign in again.');
    }

    let body;
    try {
      body = JSON.parse(event.body || '{}');
    } catch {
      body = {};
    }
    const { estimateId, pdfUrl } = body;
    if (!estimateId) throw new HttpError(400, 'estimateId is required', 'Something went wrong. Please try again.');
    const supabase = await getSupabaseClient();

    const { data: estimate, error } = await supabase
      .from('job_estimates')
      .select('*, jobs(*, customers(*))')
      .eq('id', estimateId).single();
    if (error?.code === 'PGRST116' || (!error && !estimate)) {
      throw new HttpError(404, 'Estimate not found', 'This estimate could not be found.');
    }
    if (error) throw error;

    // Same ownership rule as parse-estimate-dictation's manual path.
    if (!estimate.jobs || estimate.jobs.lead_technician_id !== technician.id) {
      throw new HttpError(403, 'This technician is not assigned to this job',
        'You can only send estimates for jobs assigned to you.');
    }
    if (estimate.voided_at) {
      throw new HttpError(409, 'Estimate is voided', 'This estimate was voided and cannot be sent.');
    }
    if (estimate.status !== 'draft' && estimate.status !== 'sent') {
      throw new HttpError(409, `Estimate is already ${estimate.status}`,
        'The customer has already answered this estimate, so it cannot be sent again.');
    }

    const customer = estimate.jobs.customers;
    if (!customer?.primary_phone) {
      throw new HttpError(422, 'No customer phone number on file',
        'This customer has no phone number on file. Add one before sending.');
    }

    const twilioCreds = await loadTwilio();
    const client = twilio(twilioCreds.accountSid, twilioCreds.authToken);

    const itemLines = estimate.line_items.map(i => `- ${i.description}: $${i.amount}`).join('\n');
    const linkLine = pdfUrl ? `\n\nView your estimate: ${pdfUrl}` : '';
    const message = `Your FieldLoop estimate is ready. Total: $${estimate.total_amount}. Tap to view and approve: https://tqb5mpwlpf.execute-api.us-east-1.amazonaws.com/dev/estimates/${estimateId}/view`;

    try {
      await client.messages.create({
        body: message,
        from: twilioCreds.fromNumber,
        to: customer.primary_phone,
      });
    } catch (err) {
      console.error('send-estimate-sms: Twilio send failed:', err.message);
      throw new HttpError(502, `SMS send failed: ${err.message}`,
        "The text message couldn't be sent. Check the customer's phone number and try again.");
    }

    // The text has gone out, so this still reports success; the app sets
    // 'sent' itself next as well.
    const { error: statusErr } = await supabase.from('job_estimates').update({ status: 'sent' }).eq('id', estimateId);
    if (statusErr) console.error('send-estimate-sms: status update failed:', statusErr.message);

    return { statusCode: 200, headers: HEADERS, body: JSON.stringify({ success: true }) };
  } catch (err) {
    const statusCode = err instanceof HttpError ? err.statusCode : 500;
    const message = err instanceof HttpError ? err.plainMessage : 'Sending the estimate failed. Please try again.';
    if (!(err instanceof HttpError)) console.error('send-estimate-sms failed:', err.message);
    return { statusCode, headers: HEADERS, body: JSON.stringify({ error: err.message, message }) };
  }
};
