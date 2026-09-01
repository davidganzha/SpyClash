export const MINIMUM_INTERNAL_PUSH_SECRET_LENGTH = 32;

export function internalPushSecret(value: unknown): string | null {
  const secret = String(value ?? "").trim();
  return secret.length >= MINIMUM_INTERNAL_PUSH_SECRET_LENGTH ? secret : null;
}

export function matchesInternalPushSecret(
  configuredValue: unknown,
  providedValue: unknown,
): boolean {
  const configured = internalPushSecret(configuredValue);
  const provided = internalPushSecret(providedValue);
  if (!configured || !provided) return false;
  const left = new TextEncoder().encode(configured);
  const right = new TextEncoder().encode(provided);
  const length = Math.max(left.length, right.length);
  let difference = left.length ^ right.length;
  for (let index = 0; index < length; index += 1) {
    difference |= (left[index] || 0) ^ (right[index] || 0);
  }
  return difference === 0;
}
