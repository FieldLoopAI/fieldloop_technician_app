const { requireTechnician } = require('./shared/auth');
const { getSecret } = require('./shared/secrets');
const fetch = require('node-fetch');

exports.handler = async (event) => {
  try {
    await requireTechnician(event);
    const { question, tradeCategory, jobDescription } = JSON.parse(event.body);

    const groqKey = await getSecret('fieldloop/groq-api-key');

    const response = await fetch('https://api.groq.com/openai/v1/chat/completions', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${groqKey}`,
      },
      body: JSON.stringify({
        model: 'llama-3.1-8b-instant',
        messages: [
          {
            role: 'system',
            content: `You are a helpful field technician coach for a ${tradeCategory || 'general trade'} job. Job context: ${jobDescription || 'none provided'}. Give short, practical, spoken-friendly answers - this will be read aloud to a technician mid-job.`,
          },
          { role: 'user', content: question },
        ],
        max_tokens: 200,
      }),
    });
    const data = await response.json();
    const answer = data.choices?.[0]?.message?.content || "Sorry, I couldn't find an answer.";

    return {
      statusCode: 200,
      headers: { 'Access-Control-Allow-Origin': '*' },
      body: JSON.stringify({ answer }),
    };
  } catch (err) {
    return {
      statusCode: err.message.includes('technician') ? 403 : 400,
      headers: { 'Access-Control-Allow-Origin': '*' },
      body: JSON.stringify({ error: err.message }),
    };
  }
};