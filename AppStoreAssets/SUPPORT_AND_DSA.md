# Support mailbox and DSA release gate

## Current state

The July 16, 2026 release audit found that `spyclash.com` is served through
Cloudflare nameservers, but the apex domain has no MX record and no SPF or
DMARC policy. Therefore `support@spyclash.com` must not be entered in App Store
Connect or shown as a monitored address until mail delivery and outbound
replies have been tested.

The public support route is available at `https://spyclash.com/support`, but it
intentionally contains no unverified email address.

## Mailbox completion

Choose a real mail provider or a forwarding service with authenticated outbound
mail. Configure it through the domain owner, then verify all of the following:

1. `support@spyclash.com` accepts mail from an unrelated external account.
2. A human receives the message in the monitored inbox.
3. A reply can be sent as `support@spyclash.com` without exposing a private
   destination address.
4. MX and SPF records match the selected provider.
5. A DMARC record exists with an initial monitoring policy.
6. The address is monitored throughout TestFlight and App Review.
7. Only after those checks, publish the address on `/support` and use it for
   App Review contact or DSA contact where legally appropriate.

DNS/mail changes are production operations. The destination mailbox and the
selected provider are private operator choices and must not be guessed or
committed to Git.

## Digital Services Act declaration

The Account Holder must choose the truthful trader status in App Store Connect.
For a trader declaration, Apple may require verification and public display of:

- exact legal person or company name;
- postal address;
- international phone number;
- monitored email address;
- supporting registration or identity evidence requested by Apple.

Do not assemble these fields from Git history, social profiles, or assumed
citizenship/residency. The final values must come directly from the legal person
or entity receiving App Store proceeds.

## Evidence to retain

- screenshot or export of the final App Store Connect DSA status;
- successful external inbound and outbound support-mail tests;
- provider/DNS configuration record without passwords or recovery codes;
- date and operator who verified that the mailbox was monitored.
