import Stripe from 'npm:stripe@14';
import { createClientFromRequest } from 'npm:@base44/sdk@0.8.25';

const stripe = new Stripe(Deno.env.get('STRIPE_SECRET_KEY'));

Deno.serve(async (req) => {
  try {
    const base44 = createClientFromRequest(req);
    const { success_url, cancel_url } = await req.json();

    let customer_email;
    try {
      const user = await base44.auth.me();
      if (user?.email) customer_email = user.email;
    } catch {}

    const session = await stripe.checkout.sessions.create({
      payment_method_types: ['card'],
      mode: 'subscription',
      line_items: [{
        price: 'price_1TR5wiRFCq3jt6C66NdM8NY4',
        quantity: 1,
      }],
      ...(customer_email ? { customer_email } : {}),
      success_url: success_url || `${req.headers.get('origin')}/Pricing?success=1`,
      cancel_url: cancel_url || `${req.headers.get('origin')}/Pricing`,
      metadata: {
        base44_app_id: Deno.env.get('BASE44_APP_ID'),
      },
    });

    return Response.json({ url: session.url });
  } catch (error) {
    console.error('Checkout error:', error.message);
    return Response.json({ error: error.message }, { status: 500 });
  }
});