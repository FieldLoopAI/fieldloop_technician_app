const { requireTechnician } = require('./shared/auth');
const { getSecret } = require('./shared/secrets');

// No DB writes here — this endpoint only turns a verbatim change-order
// dictation into a clean additionalAmount number, same Groq-extraction
// approach as parse-estimate-dictation (see that function). The caller
// (JobDetail's "change order" voice command / tap button) makes a second,
// separate call to POST /change-orders/create with this amount plus the
// full transcript as the description — see backend/functions/create-change-order.
exports.handler = async (event) => {
  try {
    await requireTechnician(event);
    const { transcript } = JSON.parse(event.body);
    if (!transcript || !transcript.trim()) {
      throw new Error('Missing transcript');
    }

    const groqSecretRaw = await getSecret('fieldloop/groq-api-key');
    let groqKey;
    try {
      const parsedSecret = JSON.parse(groqSecretRaw);
      groqKey = parsedSecret.apiKey || parsedSecret.api_key || parsedSecret.key;
      if (!groqKey) throw new Error('no recognizable key field in parsed secret');
    } catch {
      groqKey = groqSecretRaw;
    }

    const response = await fetch('https://api.groq.com/openai/v1/chat/completions', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${groqKey}` },
      body: JSON.stringify({
        model: 'openai/gpt-oss-20b',
        response_format: { type: 'json_object' },
        messages: [
          { role: 'system', content: 'Extract the additional cost/price a technician mentioned for extra work on a job. Return ONLY valid JSON, no other text: {"additionalAmount":0.00}. Do not invent a number not present in the text.' },
          { role: 'user', content: transcript },
        ],
      }),
    });

    const groqData = await response.json();

    if (!response.ok || !groqData.choices || !groqData.choices[0]) {
      console.error('Groq call failed. Status:', response.status, 'Body:', JSON.stringify(groqData));
      throw new Error(`Groq request failed: ${groqData.error?.message || JSON.stringify(groqData)}`);
    }

    let parsed;
    try {
      parsed = JSON.parse(groqData.choices[0].message.content);
    } catch (parseErr) {
      console.error('Could not parse Groq output as JSON:', groqData.choices[0].message.content);
      throw new Error('Groq did not return valid JSON — check the raw output in CloudWatch');
    }

    const additionalAmount = Number(parsed.additionalAmount);
    if (!Number.isFinite(additionalAmount)) {
      console.error('Groq returned no usable additionalAmount. Raw content:', groqData.choices[0].message.content);
      throw new Error('No price could be extracted from the dictation — check the transcript quality');
    }

    return {
      statusCode: 200,
      headers: { 'Access-Control-Allow-Origin': '*' },
      body: JSON.stringify({ additionalAmount }),
    };
  } catch (err) {
    console.error('parse-change-order-dictation failed:', err.message);
    return { statusCode: 400, headers: { 'Access-Control-Allow-Origin': '*' }, body: JSON.stringify({ error: err.message }) };
  }
};
