const verificationStatuses = [
  'OK', 'VERIFICATION_FAILURE', 'RETRYABLE_VERIFICATION_FAILURE',
  'INVALID_APP_IDENTIFIER', 'INVALID_ENVIRONMENT', 'INVALID_CHAIN_LENGTH',
  'INVALID_CERTIFICATE', 'FAILURE',
] as const;

/** Closed diagnostics only: nested SDK messages can contain signed payloads.
 * A missing server primitive is recoverable; it says nothing about the purchase.
 */
export function appleVerificationFailure(error: unknown) {
  const failure = error && typeof error === 'object'
    ? error as {status?: unknown; cause?: unknown} : undefined;
  const cause = failure?.cause ?? error;
  const message = cause instanceof Error ? cause.message : '';
  const code = cause && typeof cause === 'object' && 'code' in cause
    ? cause.code : undefined;
  const unsupportedCrypto = code === 'ERR_NOT_IMPLEMENTED'
    || /not implemented.*(?:crypto\.|X509Certificate)/i.test(message);
  const missingBodyReader = /\.buffer is not a function/.test(message);
  const status = typeof failure?.status === 'number' && Number.isInteger(failure.status)
    ? verificationStatuses[failure.status] ?? 'UNKNOWN' : 'UNKNOWN';
  return {
    status,
    reason: unsupportedCrypto ? 'SERVER_CRYPTO_UNAVAILABLE'
      : missingBodyReader ? 'SERVER_BODY_READER_UNAVAILABLE' : 'VERIFICATION_REJECTED',
    runtimeFailure: unsupportedCrypto || missingBodyReader,
  };
}
