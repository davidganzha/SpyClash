export const MINIMUM_INTERNAL_PUSH_SECRET_LENGTH = 32;

export function internalPushSecret(value: unknown): string | null {
  const secret = String(value ?? "").trim();
  return secret.length >= MINIMUM_INTERNAL_PUSH_SECRET_LENGTH ? secret : null;
}
