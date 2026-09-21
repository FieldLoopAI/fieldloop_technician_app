const { GoogleGenAI } = require('@google/genai');
const { requireTechnician } = require('./shared/auth');
const { getSecret } = require('./shared/secrets');

exports.handler = async (event) => {
  try {
    await requireTechnician(event);
    const geminiSecretRaw = await getSecret('fieldloop/gemini-api-key');
    let geminiKey;
    try {
      const parsedSecret = JSON.parse(geminiSecretRaw);
      geminiKey = parsedSecret.apiKey || parsedSecret.api_key || parsedSecret.key;
      if (!geminiKey) throw new Error('no recognizable key field in parsed secret');
    } catch {
      geminiKey = geminiSecretRaw;
    }

    // Mints a short-lived, single-use ephemeral token for the Live API instead
    // of ever handing the raw, long-lived Gemini API key to the client. The
    // token is scoped to the exact model/modalities the app's Live session
    // setup uses (lib/screens/gemini_live_test_screen.dart's `_geminiModel`),
    // but leaves the rest of LiveConnectConfig (tools, systemInstruction,
    // contextWindowCompression, ...) open, since the client still sends its
    // own full `setup` message over the WebSocket after connecting with this
    // token. Ephemeral tokens are v1alpha-only.
    const ai = new GoogleGenAI({ apiKey: geminiKey, httpOptions: { apiVersion: 'v1alpha' } });
    const authToken = await ai.authTokens.create({
      config: {
        uses: 1,
        liveConnectConstraints: {
          model: 'models/gemini-3.1-flash-live-preview',
          config: {
            responseModalities: ['AUDIO'],
          },
        },
      },
    });

    return {
      statusCode: 200,
      headers: { 'Access-Control-Allow-Origin': '*' },
      body: JSON.stringify({ token: authToken.name }),
    };
  } catch (err) {
    console.error('Gemini token request failed. Full error:', err);
    console.error('Gemini token request failed. Error keys/props:', JSON.stringify(err, Object.getOwnPropertyNames(err)));
    return { statusCode: 400, headers: { 'Access-Control-Allow-Origin': '*' }, body: JSON.stringify({ error: err.message }) };
  }
};
