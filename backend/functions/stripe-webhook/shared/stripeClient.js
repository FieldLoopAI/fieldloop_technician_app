const Stripe = require('stripe');
const { getSecret } = require('./secrets');

// Pinned to the API version bundled with the pinned stripe SDK (23.0.0).
const STRIPE_API_VERSION = '2026-09-30.endive';
const STRIPE_SECRET_NAME = 'fieldloop/stripe-test';

console.log(`STRIPE SDK: version=${Stripe.PACKAGE_VERSION} apiVersion=${STRIPE_API_VERSION}`);

let cached = null;

// { stripe, webhookSecret } from the "fieldloop/stripe-test" secret
// ({"secretKey", "webhookSecret"}). Test mode only: a live key is refused.
async function getStripe() {
  if (cached) return cached;
  const creds = JSON.parse(await getSecret(STRIPE_SECRET_NAME));
  const key = creds.secretKey || '';
  if (!key.startsWith('sk_test_') && !key.startsWith('rk_test_')) {
    throw new Error('Stripe secret is not a test-mode key');
  }
  cached = {
    stripe: new Stripe(key, { apiVersion: STRIPE_API_VERSION }),
    webhookSecret: creds.webhookSecret,
  };
  return cached;
}

module.exports = { getStripe, STRIPE_API_VERSION };
