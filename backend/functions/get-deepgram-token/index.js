const { requireTechnician } = require('./shared/auth');
const { getSecret } = require('./shared/secrets');
//const fetch = require('node-fetch');

exports.handler = async (event) => {
  try {
    await requireTechnician(event);
    const deepgramKey = await getSecret('fieldloop/deepgram-api-key');

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