const { requireTechnician } = require('./shared/auth');
const { getSupabaseClient } = require('./shared/supabaseClient');
const { getSecret } = require('./shared/secrets');
const twilio = require('twilio');

exports.handler = async (event) => {
  try {
    await requireTechnician(event);
    const { estimateId, pdfUrl } = JSON.parse(event.body);
    const supabase = await getSupabaseClient();

    const { data: estimate, error } = await supabase
      .from('job_estimates')
      .select('*, jobs(*, customers(*))')
      .eq('id', estimateId).single();
    if (error) throw error;

    const customer = estimate.jobs.customers;
    if (!customer?.primary_phone) throw new Error('No customer phone number on file');

    const twilioCreds = JSON.parse(await getSecret('fieldloop/twilio-credentials'));
    const client = twilio(twilioCreds.accountSid, twilioCreds.authToken);

    const itemLines = estimate.line_items.map(i => `- ${i.description}: $${i.amount}`).join('\n');
    const linkLine = pdfUrl ? `\n\nView your estimate: ${pdfUrl}` : '';
    const message = `Your FieldLoop estimate is ready. Total: $${estimate.total_amount}. Tap to view and approve: https://tqb5mpwlpf.execute-api.us-east-1.amazonaws.com/dev/estimates/${estimateId}/view`;

    await client.messages.create({
      body: message,
      from: twilioCreds.fromNumber,
      to: customer.primary_phone,
    });

    await supabase.from('job_estimates').update({ status: 'sent' }).eq('id', estimateId);

    return { statusCode: 200, headers: { 'Access-Control-Allow-Origin': '*' }, body: JSON.stringify({ success: true }) };
  } catch (err) {
    return { statusCode: 400, headers: { 'Access-Control-Allow-Origin': '*' }, body: JSON.stringify({ error: err.message }) };
  }
};