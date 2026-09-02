const { requireTechnician } = require('./shared/auth');
const { getSupabaseClient } = require('./shared/supabaseClient');
const { getSecret } = require('./shared/secrets');
const twilio = require('twilio');

exports.handler = async (event) => {
  try {
    await requireTechnician(event);
    const { invoiceId, pdfUrl } = JSON.parse(event.body);
    const supabase = await getSupabaseClient();

    const { data: invoice, error } = await supabase
      .from('invoices')
      .select('*, jobs(*, customers(*), contractors(*))')
      .eq('id', invoiceId).single();
    if (error) throw error;

    const customer = invoice.jobs.customers;
    if (!customer?.primary_phone) throw new Error('No customer phone number on file');

    const twilioSecretRaw = await getSecret('fieldloop/twilio-credentials');
    const twilioCreds = JSON.parse(twilioSecretRaw);
    const client = twilio(twilioCreds.accountSid, twilioCreds.authToken);

    await client.messages.create({
      body: `Your invoice from ${invoice.jobs.contractors.legal_name} is ready. Total due: $${invoice.total}. View here: ${pdfUrl}`,
      from: twilioCreds.fromNumber,
      to: customer.primary_phone,
    });

    await supabase.from('invoices').update({ status: 'sent' }).eq('id', invoiceId);

    return { statusCode: 200, headers: { 'Access-Control-Allow-Origin': '*' }, body: JSON.stringify({ success: true }) };
  } catch (err) {
    return { statusCode: 400, headers: { 'Access-Control-Allow-Origin': '*' }, body: JSON.stringify({ error: err.message }) };
  }
};