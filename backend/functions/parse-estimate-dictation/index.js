const { requireTechnician } = require('./shared/auth');
const { getSupabaseClient } = require('./shared/supabaseClient');
const { getSecret } = require('./shared/secrets');

async function callGroq(groqKey, transcript) {
  const response = await fetch('https://api.groq.com/openai/v1/chat/completions', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${groqKey}` },
    body: JSON.stringify({
      model: 'openai/gpt-oss-20b',
      response_format: { type: 'json_object' },
      messages: [
        { role: 'system', content: 'Extract line items from a technician\'s spoken estimate. Return ONLY valid JSON, no other text: {"line_items":[{"description":"...","amount":0.00}],"total_amount":0.00}. total_amount must equal the sum of all line item amounts. Do not invent numbers not present in the text.' },
        { role: 'user', content: transcript },
      ],
      max_tokens: 600,
      reasoning_effort: 'low',
    }),
  });
  const data = await response.json();
  return { ok: response.ok, status: response.status, data };
}

// Manual (typed) estimate — same route as dictation parsing so no new API
// Gateway route is needed. Writes the exact same job_estimates row shape the
// dictation path writes (line_items [{description, amount}], total_amount),
// so everything downstream — change order totals, /invoices/preview, the
// invoice PDF, Mark Job Complete — treats both identically. quantity/
// unit_price are kept on each line item when given (extra JSON keys; readers
// only use description/amount). source_dictation_id is null.
async function createManualEstimate(supabase, technician, jobId, rawItems) {
  if (!jobId) throw new Error('jobId is required');
  const { data: job, error: jobErr } = await supabase
    .from('jobs').select('id, lead_technician_id').eq('id', jobId).single();
  if (jobErr || !job) throw new Error('Job not found');
  if (job.lead_technician_id !== technician.id) throw new Error('This technician is not assigned to this job');

  if (!Array.isArray(rawItems) || rawItems.length === 0) throw new Error('At least one line item is required');
  const lineItems = rawItems.map((raw, i) => {
    const description = String(raw?.description ?? '').trim();
    const amount = Math.round(Number(raw?.amount) * 100) / 100;
    if (!description) throw new Error(`Line item ${i + 1} needs a description`);
    if (!Number.isFinite(amount) || amount < 0) throw new Error(`Line item ${i + 1} needs a non-negative amount`);
    const item = { description, amount };
    if (raw.quantity != null) item.quantity = Number(raw.quantity);
    if (raw.unit_price != null) item.unit_price = Number(raw.unit_price);
    return item;
  });
  const total = Math.round(lineItems.reduce((sum, item) => sum + item.amount, 0) * 100) / 100;

  const { data: estimate, error: insertErr } = await supabase.from('job_estimates').insert({
    job_id: jobId,
    technician_id: technician.id,
    source_dictation_id: null,
    line_items: lineItems,
    total_amount: total,
  }).select().single();
  if (insertErr) throw insertErr;
  return estimate;
}

exports.handler = async (event) => {
  try {
    const technician = await requireTechnician(event);
    const body = JSON.parse(event.body);
    const supabase = await getSupabaseClient();

    if (body.mode === 'manual') {
      const estimate = await createManualEstimate(supabase, technician, body.jobId, body.lineItems);
      return { statusCode: 200, headers: { 'Access-Control-Allow-Origin': '*' }, body: JSON.stringify({ estimate }) };
    }

    const { dictationId } = body;

    const { data: dictation, error: fetchErr } = await supabase
      .from('job_dictations').select('*').eq('id', dictationId).single();
    if (fetchErr) throw fetchErr;

    const groqSecretRaw = await getSecret('fieldloop/groq-api-key');
    let groqKey;
    try {
      const parsedSecret = JSON.parse(groqSecretRaw);
      groqKey = parsedSecret.apiKey || parsedSecret.api_key || parsedSecret.key;
      if (!groqKey) throw new Error('no recognizable key field in parsed secret');
    } catch {
      groqKey = groqSecretRaw;
    }

    // First attempt
    let { ok, status, data: groqData } = await callGroq(groqKey, dictation.transcript);

    // If it failed, retry once before giving up — a transient generation
    // hiccup (e.g. Groq's JSON validation rejecting one attempt) shouldn't
    // kill the whole estimate on the first try.
    if (!ok || !groqData.choices || !groqData.choices[0]) {
      console.error('First Groq attempt failed, retrying once. Status:', status, 'Body:', JSON.stringify(groqData));
      ({ ok, status, data: groqData } = await callGroq(groqKey, dictation.transcript));
    }

    if (!ok || !groqData.choices || !groqData.choices[0]) {
      console.error('Groq call failed after retry. Status:', status, 'Body:', JSON.stringify(groqData));
      throw new Error(`Groq request failed after retry: ${groqData.error?.message || JSON.stringify(groqData)}`);
    }

    let parsed;
    try {
      parsed = JSON.parse(groqData.choices[0].message.content);
    } catch (parseErr) {
      console.error('Could not parse Groq output as JSON:', groqData.choices[0].message.content);
      throw new Error('Groq did not return valid JSON — check the raw output in CloudWatch');
    }

    // Never trust the model's own total — always compute it ourselves from
    // the actual line items, and use that as a safety net if it's missing
    // or doesn't match.
    const lineItems = Array.isArray(parsed.line_items) ? parsed.line_items : [];
    const computedTotal = lineItems.reduce((sum, item) => sum + (Number(item.amount) || 0), 0);
    const finalTotal = Number(parsed.total_amount) || computedTotal;

    if (lineItems.length === 0) {
      console.error('Groq returned zero line items. Raw content:', groqData.choices[0].message.content);
      throw new Error('No line items could be extracted from the dictation — check the transcript quality');
    }

    const { data: estimate, error: insertErr } = await supabase.from('job_estimates').insert({
      job_id: dictation.job_id,
      technician_id: technician.id,
      source_dictation_id: dictationId,
      line_items: lineItems,
      total_amount: finalTotal,
    }).select().single();
    if (insertErr) throw insertErr;

    await supabase.from('job_dictations').update({ status: 'processed' }).eq('id', dictationId);

    return { statusCode: 200, headers: { 'Access-Control-Allow-Origin': '*' }, body: JSON.stringify({ estimate }) };
  } catch (err) {
    console.error('parse-estimate-dictation failed:', err.message);
    return { statusCode: 400, headers: { 'Access-Control-Allow-Origin': '*' }, body: JSON.stringify({ error: err.message }) };
  }
};