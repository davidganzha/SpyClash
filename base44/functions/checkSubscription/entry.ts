import Stripe from 'npm:stripe@14';
import { createClientFromRequest } from 'npm:@base44/sdk@0.8.25';

const stripe = new Stripe(Deno.env.get('STRIPE_SECRET_KEY'));

Deno.serve(async (req) => {
  try {
    const base44 = createClientFromRequest(req);
    let email;
    try {
      const user = await base44.auth.me();
      email = user?.email;
    } catch {}

    if (!email) {
      return Response.json({ active: false });
    }

    // Find customers by email
    const customers = await stripe.customers.list({ email, limit: 5 });
    if (!customers.data.length) {
      return Response.json({ active: false });
    }

    // Check if any customer has an active subscription
    for (const customer of customers.data) {
      const subs = await stripe.subscriptions.list({ customer: customer.id, status: 'active', limit: 5 });
      if (subs.data.length > 0) {
        return Response.json({ active: true });
      }
    }

    return Response.json({ active: false });
  } catch (error) {
    console.error('Subscription check error:', error.message);
    return Response.json({ active: false });
  }
});