const { requireTechnician } = require('./shared/auth');
const { getSecret } = require('./shared/secrets');

exports.handler = async (event) => {
  try {
    await requireTechnician(event);

    const secretRaw = await getSecret('fieldloop/deepgram-credentials');

    // Handles either format: a plain API key string, or a JSON object
    // like {"apiKey": "..."} — whichever way the secret was actually stored.
    let deepgramKey;
    try {
      const parsed = JSON.parse(secretRaw);
      deepgramKey = parsed.apiKey || parsed.api_key || parsed.key;
      if (!deepgramKey) throw new Error('no recognizable key field in parsed secret');
    } catch {
      // Not valid JSON — treat the whole secret as the raw key itself.
      deepgramKey = secretRaw;
    }

    const response = await fetch('https://api.deepgram.com/v1/auth/grant', {
      method: 'POST',
      headers: {
        'Authorization': `Token ${deepgramKey}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ ttl_seconds: 30 }),
    });
    const data = await response.json();

    return {
      statusCode: 200,
      headers: { 'Access-Control-Allow-Origin': '*' },
      body: JSON.stringify({ token: data.access_token }),
    };
  } catch (err) {
    return {
      statusCode: err.message.includes('technician') ? 403 : 400,
      headers: { 'Access-Control-Allow-Origin': '*' },
      body: JSON.stringify({ error: err.message }),
    };
  }
};