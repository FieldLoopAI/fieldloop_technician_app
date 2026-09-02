const { requireTechnician } = require('./shared/auth');
const { getSupabaseClient } = require('./shared/supabaseClient');
const { getSecret } = require('./shared/secrets');
const twilio = require('twilio');

async function extractAmount(groqKey, transcript) {
  const response = await fetch('https://api.groq.com/openai/v1/chat/completions', {
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
  const data = await response.json();
  if (!data.choices || !data.choices[0]) return null;
  try {
    return JSON.parse(data.choices[0].message.content).amount;
  } catch {
    return null;
  }
}

exports.handler = async (event) => {
  try {
    const technician = await requireTechnician(event);
    const { jobId, description } = JSON.parse(event.body);
    const supabase = await getSupabaseClient();

    const groqSecretRaw = await getSecret('fieldloop/groq-api-key');
    let groqKey;
    try {
      const parsedSecret = JSON.parse(groqSecretRaw);
      groqKey = parsedSecret.apiKey || parsedSecret.api_key || parsedSecret.key;
    } catch {
      groqKey = groqSecretRaw;
    }

    const additionalAmount = await extractAmount(groqKey, description);
    if (additionalAmount === null || additionalAmount === undefined) {
      throw new Error('Could not extract a dollar amount from the dictated description');
    }

    const { data: changeOrder, error: insertErr } = await supabase
      .from('change_orders')
      .insert({ job_id: jobId, technician_id: technician.id, description, additional_amount: additionalAmount, status: 'pending' })
      .select().single();
    if (insertErr) throw insertErr;

    const { data: job } = await supabase.from('jobs').select('*, customers(*)').eq('id', jobId).single();
    const customerPhone = job?.customers?.primary_phone;
    let smsSent = false;

    if (customerPhone) {
      try {
        const twilioSecretRaw = await getSecret('fieldloop/twilio-credentials');
        const twilioCreds = JSON.parse(twilioSecretRaw);
        const client = twilio(twilioCreds.accountSid, twilioCreds.authToken);
        await client.messages.create({
          body: `Your technician found additional work needed: ${description}. Additional cost: $${additionalAmount}. Tap to review and approve: https://tqb5mpwlpf.execute-api.us-east-1.amazonaws.com/dev/change-orders/${changeOrder.id}/approve`,
          from: twilioCreds.fromNumber,
          to: customerPhone,
        });
        smsSent = true;
      } catch (smsErr) {
        console.error('SMS failed but change order was saved:', smsErr.message);
      }
    }

    return { statusCode: 200, headers: { 'Access-Control-Allow-Origin': '*' }, body: JSON.stringify({ changeOrder, smsSent }) };
  } catch (err) {
    return { statusCode: err.message.includes('technician') ? 403 : 400, headers: { 'Access-Control-Allow-Origin': '*' }, body: JSON.stringify({ error: err.message }) };
  }
};