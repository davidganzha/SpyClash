export const APPLE_NATIVE_HANDOFF_V2 = "apple-native-v2";
const LEGACY_CALLBACK =
  "https://spyclash.com/api/apps/69a0e57fa939f578082f8091/functions/mobileAuthCallback";
const HTTPS_CALLBACK =
  "https://spyclash.com/MobileAppleAuthCallback.html?auth_provider=apple";

/** Only an explicit fixed version can opt into the HTTPS return. No client URL
 * is accepted. The chosen version is carried inside the signed native ticket. */
export function nativeHandoffVersion(
  value: unknown,
): typeof APPLE_NATIVE_HANDOFF_V2 | undefined {
  if (value === undefined) return undefined;
  if (value === APPLE_NATIVE_HANDOFF_V2) return APPLE_NATIVE_HANDOFF_V2;
  throw new Error("invalid_native_handoff_version");
}

export function nativeHandoffCallback(version: unknown): string {
  return nativeHandoffVersion(version) === APPLE_NATIVE_HANDOFF_V2
    ? HTTPS_CALLBACK
    : LEGACY_CALLBACK;
}
