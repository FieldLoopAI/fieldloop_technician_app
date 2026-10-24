const { requireTechnician } = require('./shared/auth');
const { getSupabaseClient } = require('./shared/supabaseClient');
const { getSecret } = require('./shared/secrets');
const twilio = require('twilio');

const HEADERS = { 'Access-Control-Allow-Origin': '*' };

// raise exception text from reject_write_when_payment_locked
// (supabase/migrations/20261023_payment_freeze.sql).
const PAYMENT_LOCKED = 'Payment started - invoice is locked';

// A change order amount must stay below $1,000,000.00.
const MAX_AMOUNT = 1000000;

const UNREADABLE = "We couldn't read that change order. Please try again.";

// A refusal with its HTTP status: `error` keeps the raw detail, `message`
// is a plain sentence the app can show as is.
class HttpError extends Error {
  constructor(statusCode, error, message) {
    super(error);
    this.statusCode = statusCode;
    this.plainMessage = message;
  }
}

async function extractAmount(groqKey, transcript) {
  let response;
  let data;
  try {
    response = await fetch('https://api.groq.com/openai/v1/chat/completions', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${groqKey}` },
      body: JSON.stringify({
        model: 'openai/gpt-oss-20b',
        response_format: { type: 'json_object' },
        messages: [
          { role: 'system', content: 'Extract or CALCULATE the total additional dollar amount from this technician\'s spoken change order description. IMPORTANT: if a quantity and a per-unit rate are both mentioned (e.g. "200 square feet at $18 per square foot", "3 hours at $150 an hour"), you must MULTIPLY them to get the real total — do not just return the rate or the quantity alone. Example: "200 square feet at $18 per square foot" = 200 × 18 = 3600, so amount should be 3600, not 18 and not 200. If only a single flat dollar amount is stated with no quantity/rate pattern, use that number directly. Return ONLY valid JSON: {"amount": 0.00}.' },
          { role: 'user', content: transcript },
        ],
        max_tokens: 200,
        reasoning_effort: 'low',
      }),
    });
    data = await response.json();
  } catch (err) {
    throw new HttpError(502, `Groq request failed: ${err.message}`, UNREADABLE);
  }
  if (!response.ok || !data.choices || !data.choices[0]) {
    throw new HttpError(502, `Groq request failed: ${data?.error?.message || `status ${response.status}`}`, UNREADABLE);
  }
  try {
    return JSON.parse(data.choices[0].message.content).amount;
  } catch {
    return null;
  }
}

/**
 * [raw] (a number, or Groq's numeric string) as cents-rounded dollars, or
 * null unless finite, > 0 and < MAX_AMOUNT.
 */
function validAmount(raw) {
  if (typeof raw === 'boolean' || raw === null || raw === undefined || raw === '') return null;
  const amount = Math.round(Number(raw) * 100) / 100;
  return Number.isFinite(amount) && amount > 0 && amount < MAX_AMOUNT ? amount : null;
}

/** Twilio credentials, or null when the secret is missing or incomplete. */
async function loadTwilioCreds() {
  try {
    const creds = JSON.parse(await getSecret('fieldloop/twilio-credentials'));
    if (creds?.accountSid && creds?.authToken && creds?.fromNumber) return creds;
    console.error('SMS not configured: Twilio credentials are incomplete');
  } catch (err) {
    console.error('SMS not configured: Twilio credentials unavailable:', err.message);
  }
  return null;
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
      body = JSON.parse(event.body || '{}') || {};
    } catch {
      throw new HttpError(400, 'Request body is not valid JSON', UNREADABLE);
    }
    const { jobId, description, amount } = body;
    if (!jobId) throw new HttpError(400, 'jobId is required', UNREADABLE);
    if (!String(description ?? '').trim()) {
      throw new HttpError(400, 'A description is required', 'Add a description of the additional work.');
    }
    const supabase = await getSupabaseClient();

    // Same ownership rule as parse-estimate-dictation's manual path.
    const { data: job, error: jobErr } = await supabase.from('jobs').select('*, customers(*)').eq('id', jobId).single();
    if (jobErr?.code === 'PGRST116' || (!jobErr && !job)) {
      throw new HttpError(404, 'Job not found', 'This job could not be found.');
    }
    if (jobErr) throw jobErr;
    if (job.lead_technician_id !== technician.id) {
      throw new HttpError(403, 'This technician is not assigned to this job',
        'You can only add change orders to jobs assigned to you.');
    }

    let additionalAmount;
    if (amount !== undefined && amount !== null) {
      // Manual (typed) change order — the technician entered the amount, so
      // no Groq extraction. Everything after this (pending status, customer
      // approval SMS) is identical to the dictated path.
      // The app sends a JSON number; anything else is refused.
      additionalAmount = typeof amount === 'number' ? validAmount(amount) : null;
      if (additionalAmount === null) {
        throw new HttpError(400, 'The amount must be a positive number below 1,000,000',
          'The amount must be more than $0.00 and less than $1,000,000.00.');
      }
    } else {
      const groqSecretRaw = await getSecret('fieldloop/groq-api-key');
      let groqKey;
      try {
        const parsedSecret = JSON.parse(groqSecretRaw);
        groqKey = parsedSecret.apiKey || parsedSecret.api_key || parsedSecret.key;
      } catch {
        groqKey = groqSecretRaw;
      }

      const extracted = await extractAmount(groqKey, description);
      if (extracted === null || extracted === undefined) {
        throw new HttpError(400, 'Could not extract a dollar amount from the dictated description', UNREADABLE);
      }
      additionalAmount = validAmount(extracted);
      if (additionalAmount === null) {
        throw new HttpError(400, `The extracted amount is not valid: ${extracted}`, UNREADABLE);
      }
    }

    const { data: changeOrder, error: insertErr } = await supabase
      .from('change_orders')
      .insert({ job_id: jobId, technician_id: technician.id, description, additional_amount: additionalAmount, status: 'pending' })
      .select().single();
    if (insertErr) {
      if (String(insertErr.message ?? '').includes(PAYMENT_LOCKED)) {
        throw new HttpError(409, PAYMENT_LOCKED, 'Payment has started on this job, so change orders are locked.');
      }
      throw insertErr;
    }

    // The change order is saved whatever happens to the SMS below.
    const customerPhone = job.customers?.primary_phone;
    let smsStatus = 'no_phone';
    if (customerPhone) {
      const twilioCreds = await loadTwilioCreds();
      if (!twilioCreds) {
        smsStatus = 'not_configured';
      } else {
        try {
          const client = twilio(twilioCreds.accountSid, twilioCreds.authToken);
          await client.messages.create({
            body: `Your technician found additional work needed: ${description}. Additional cost: $${additionalAmount.toFixed(2)}. Tap to review and approve: https://tqb5mpwlpf.execute-api.us-east-1.amazonaws.com/dev/change-orders/${changeOrder.id}/approve`,
            from: twilioCreds.fromNumber,
            to: customerPhone,
          });
          smsStatus = 'sent';
        } catch (smsErr) {
          console.error('SMS failed but change order was saved:', smsErr.message);
          smsStatus = 'failed';
        }
      }
    }
    const smsSent = smsStatus === 'sent';

    return { statusCode: 200, headers: HEADERS, body: JSON.stringify({ changeOrder, smsSent, smsStatus }) };
  } catch (err) {
    const known = err instanceof HttpError;
    if (!known) console.error('create-change-order failed:', err.message);
    return {
      statusCode: known ? err.statusCode : 500,
      headers: HEADERS,
      body: JSON.stringify({
        error: err.message,
        message: known ? err.plainMessage : 'Saving the change order failed. Please try again.',
      }),
    };
  }
};
