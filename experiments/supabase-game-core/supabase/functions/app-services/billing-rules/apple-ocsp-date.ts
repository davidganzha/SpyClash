const installed = new WeakSet<object>();

/** Apple SDK 3.1.0 receives GeneralizedTime with a trailing Z from jsrsasign,
 * but its parser only rewrites the form without Z. Invalid Date makes the
 * subsequent freshness comparisons false. Parse both forms explicitly as UTC
 * and reject invalid calendar fields instead of allowing Date normalization.
 */
export function parseAppleOCSPDate(value: string): Date {
  const match = typeof value === 'string' ? /^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})Z?$/.exec(value) : null;
  if (!match) throw new RangeError('Invalid Apple OCSP timestamp.');
  const [year, month, day, hour, minute, second] = match.slice(1).map(Number);
  const date = new Date(Date.UTC(year, month - 1, day, hour, minute, second));
  if (year < 1970 || date.getUTCFullYear() !== year || date.getUTCMonth() !== month - 1
      || date.getUTCDate() !== day || date.getUTCHours() !== hour
      || date.getUTCMinutes() !== minute || date.getUTCSeconds() !== second)
    throw new RangeError('Invalid Apple OCSP timestamp.');
  return date;
}

export function ensureAppleOCSPDateParsing(verifier: object): void {
  if (installed.has(verifier)) return;
  if (typeof (verifier as {parseX509Date?: unknown}).parseX509Date !== 'function')
    throw new Error('Unsupported Apple verifier date parser.');
  // Deliberately scoped to this pinned verifier instance. The SDK retains its
  // OCSP signature, signer authorization, certificate ID, status and skew checks.
  Object.defineProperty(verifier, 'parseX509Date', {value:parseAppleOCSPDate});
  installed.add(verifier);
}
