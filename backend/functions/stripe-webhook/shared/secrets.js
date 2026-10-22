const { SecretsManagerClient, GetSecretValueCommand, CreateSecretCommand, PutSecretValueCommand }
  = require('@aws-sdk/client-secrets-manager');

const client = new SecretsManagerClient({});

async function getSecret(name) {
  const res = await client.send(new GetSecretValueCommand({ SecretId: name }));
  return res.SecretString;
}

async function storeSecret(name, value) {
  try {
    await client.send(new CreateSecretCommand({ Name: name, SecretString: value }));
  } catch (err) {
    if (err.name === 'ResourceExistsException') {
      await client.send(new PutSecretValueCommand({ SecretId: name, SecretString: value }));
    } else {
      throw err;
    }
  }
  return name;
}

module.exports = { getSecret, storeSecret };