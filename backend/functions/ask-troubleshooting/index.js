const { requireTechnician } = require('./shared/auth');
const { getSupabaseClient } = require('./shared/supabaseClient');

const KB_SEARCH_URL = 'https://tqb5mpwlpf.execute-api.us-east-1.amazonaws.com/dev/kb/search';

// Maps this app's jobs.trade_category values to the KB's real trade_slug
// values. Confirmed real content exists for: concrete_and_pavers (1008),
// general_contractor (513), roofing (757), insulation (564).
// No dedicated KB content exists yet for electrician, plumbing, or HVAC —
// these route to general_contractor as the closest reasonable fallback,
// not a true match. Update this mapping if/when dedicated content is
// added for any of these trades.
function mapToTradeSlug(tradeCategory) {
  if (!tradeCategory) return 'general_contractor';
  const normalized = tradeCategory.toLowerCase().trim();
  const map = {
    'pavement repairing': 'concrete_and_pavers',
    'roofing': 'roofing',
    'insulation': 'insulation',
    'electrician': 'general_contractor',
    'plumbing': 'general_contractor',
    'hvac': 'general_contractor',
  };
  return map[normalized] || 'general_contractor';
}

// Converts raw KB text (sometimes written in a compact reference-chart
// style, e.g. "4 inches = 4/12 = 0.333 ft") into something that reads
// naturally out loud. Pure string transformation - no AI/LLM involved,
// since this app only ever speaks from vetted Knowledge Base content.
function makeSpeakable(text) {
  return text
    .replace(/(\d+)\/(\d+)/g, '$1 over $2')   // 4/12 → 4 over 12
    .replace(/\s=\s/g, ' equals ')             // = → equals
    .replace(/e\.g\.,?/gi, 'for example')      // e.g. → for example
    .replace(/i\.e\.,?/gi, 'that is')          // i.e. → that is
    .replace(/;/g, ',')                        // semicolons → softer pause
    .replace(/\s+/g, ' ')                      // collapse double spaces
    .trim();
}

exports.handler = async (event) => {
  const handlerStart = Date.now();
  try {
    const requireTechnicianStart = Date.now();
    const technician = await requireTechnician(event);
    console.log(`TIMING: requireTechnician: ${Date.now() - requireTechnicianStart}ms`);
    const { question, jobId } = JSON.parse(event.body);

    let tradeSlug = 'general_contractor';
    if (jobId) {
      const supabase = await getSupabaseClient();
      const tradeCategoryStart = Date.now();
      const { data: job } = await supabase.from('jobs').select('trade_category').eq('id', jobId).single();
      console.log(`TIMING: trade_category lookup: ${Date.now() - tradeCategoryStart}ms`);
      tradeSlug = mapToTradeSlug(job?.trade_category);
    }

    const kbSearchStart = Date.now();
    const kbResponse = await fetch(KB_SEARCH_URL, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': event.headers.Authorization || event.headers.authorization,
      },
      body: JSON.stringify({ question, trade_slug: tradeSlug }),
    });
    const kbData = await kbResponse.json();
    console.log(`TIMING: kb/search call: ${Date.now() - kbSearchStart}ms`);

    // Only trust the KB's answer as final when it's a genuine confident
    // match — NOT "no_match" and NOT "llm_escalation" (which means low-
    // confidence candidates were found but the KB itself deferred).
    const isConfidentKbMatch = kbData.source && kbData.source !== 'no_match' && kbData.source !== 'llm_escalation';

    if (isConfidentKbMatch && kbData.answer) {
      console.log(`TIMING: handler total: ${Date.now() - handlerStart}ms`);
      return {
        statusCode: 200,
        headers: { 'Access-Control-Allow-Origin': '*' },
        body: JSON.stringify({ answer: makeSpeakable(kbData.answer), source: 'knowledge_base', verifyLocally: kbData.verify_locally }),
      };
    }

    // No confident KB match — no Groq fallback anymore. The assistant
    // only ever speaks from vetted Knowledge Base content.
    console.log(`TIMING: handler total: ${Date.now() - handlerStart}ms`);
    return {
      statusCode: 200,
      headers: { 'Access-Control-Allow-Origin': '*' },
      body: JSON.stringify({
        answer: 'Sorry, that information is not available in the Knowledge Base.',
        source: 'no_match',
      }),
    };
  } catch (err) {
    return {
      statusCode: err.message.includes('technician') ? 403 : 400,
      headers: { 'Access-Control-Allow-Origin': '*' },
      body: JSON.stringify({ error: err.message }),
    };
  }
};