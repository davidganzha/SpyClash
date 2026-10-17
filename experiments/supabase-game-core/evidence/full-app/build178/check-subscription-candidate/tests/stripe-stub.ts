export default class Stripe {
  customers!: { list: (...args: any[]) => Promise<{ data: Array<{ id: string }> }> };
  subscriptions: any;
  constructor(..._arguments: unknown[]) {
    throw new Error("LIMITLESS handler must not invoke deferred Stripe verification");
  }
}
