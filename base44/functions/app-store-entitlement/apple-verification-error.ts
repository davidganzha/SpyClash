import {
  VerificationException,
  VerificationStatus,
} from "npm:@apple/app-store-server-library@3.1.0";

const CAUSE_CLASSES = new Set([
  "Error",
  "TypeError",
  "RangeError",
  "FetchError",
  "AbortError",
  "NotSupportedError",
  "NotCapable",
  "PermissionDenied",
  "InvalidData",
]);
const CAUSE_CODES = new Set([
  "ECONNRESET",
  "ECONNREFUSED",
  "ENOTFOUND",
  "ETIMEDOUT",
  "EAI_AGAIN",
  "ERR_INVALID_ARG_TYPE",
  "ERR_NOT_IMPLEMENTED",
  "ERR_OSSL_UNSUPPORTED",
  "ERR_CRYPTO_INVALID_KEY_OBJECT_TYPE",
  "CERT_HAS_EXPIRED",
]);

// Return a closed vocabulary only. Apple's exceptions have an empty message,
// while nested messages/stacks can contain URLs or signed payloads.
export function appleVerificationFailureDetails(error: unknown) {
  const appleError = error instanceof VerificationException ? error : null;
  const cause = appleError?.cause ?? error;
  const causeName = cause instanceof Error ? cause.name : "";
  const rawCode = cause && typeof cause === "object" && "code" in cause
    ? cause.code
    : undefined;
  const message = cause instanceof Error ? cause.message : "";
  let causeDetail = "UNCLASSIFIED";
  if (/not implemented.*X509Certificate.*verify/i.test(message)) {
    causeDetail = "NODE_X509_VERIFY_UNSUPPORTED";
  } else if (/not implemented.*X509Certificate.*checkIssued/i.test(message)) {
    causeDetail = "NODE_X509_CHECK_ISSUED_UNSUPPORTED";
  } else if (/right.hand side of.*instanceof.*not an object/i.test(message)) {
    causeDetail = "NODE_INSTANCEOF_CONSTRUCTOR_UNAVAILABLE";
  } else if (/socket hang up/i.test(message)) {
    causeDetail = "NETWORK_SOCKET_CLOSED";
  }
  const stack = cause instanceof Error ? cause.stack ?? "" : "";
  const causeStage = [
    ["checkOCSPStatus", "OCSP_VALIDATION"],
    ["verifyCertificateChainWithoutCaching", "CERTIFICATE_CHAIN_VALIDATION"],
    ["verifyCertificateChain", "CERTIFICATE_CHAIN_VALIDATION"],
    ["verifyJWT", "JWS_VERIFICATION"],
  ].find(([method]) => stack.includes(method))?.[1] ?? "UNKNOWN_STAGE";
  if (causeDetail === "UNCLASSIFIED") {
    if (/\.verify is not a function/.test(message)) {
      causeDetail = "VERIFY_METHOD_UNAVAILABLE";
    } else if (/\.export is not a function/.test(message)) {
      causeDetail = "KEY_EXPORT_UNAVAILABLE";
    } else if (/X509.*is not a constructor/.test(message)) {
      causeDetail = "X509_CONSTRUCTOR_UNAVAILABLE";
    } else if (/OCSPRequest.*is not a constructor/.test(message)) {
      causeDetail = "OCSP_REQUEST_CONSTRUCTOR_UNAVAILABLE";
    } else if (/OCSPParser.*is not a constructor/.test(message)) {
      causeDetail = "OCSP_PARSER_CONSTRUCTOR_UNAVAILABLE";
    } else if (/\.certs is not iterable/.test(message)) {
      causeDetail = "OCSP_CERTIFICATES_NOT_ITERABLE";
    } else if (/Cannot read propert.*(?:undefined|null)/.test(message)) {
      causeDetail = "MISSING_OBJECT_PROPERTY";
    } else if (/is not a function/.test(message)) {
      causeDetail = "METHOD_UNAVAILABLE";
    } else if (/is not a constructor/.test(message)) {
      causeDetail = "CONSTRUCTOR_UNAVAILABLE";
    } else if (/is not iterable/.test(message)) {
      causeDetail = "VALUE_NOT_ITERABLE";
    }
  }
  const causeProperty = [
    "buffer",
    "verify",
    "export",
    "readCertHex",
    "publicKey",
    "raw",
    "toString",
    "X509",
    "KJUR",
    "asn1",
    "ocsp",
    "OCSPRequest",
    "OCSPParser",
    "getOCSPResponse",
    "certs",
    "respid",
    "getExtExtKeyUsage",
    "array",
    "sighex",
    "replace",
    "decode",
    "createHash",
    "createPublicKey",
  ].find((property) =>
    message.includes(`(reading '${property}')`) ||
    message.includes(`.${property} is not a function`) ||
    message.includes(`.${property} is not a constructor`)
  ) ?? null;
  const runtimeVersion = /^\d+\.\d+\.\d+$/.test(Deno.version.deno)
    ? Deno.version.deno
    : null;
  return {
    status: appleError
      ? VerificationStatus[appleError.status] ?? "UNKNOWN_VERIFICATION_STATUS"
      : "VERIFIER_RUNTIME_FAILURE",
    causeClass: CAUSE_CLASSES.has(causeName) ? causeName : "UnknownError",
    causeCode: typeof rawCode === "string" && CAUSE_CODES.has(rawCode)
      ? rawCode
      : null,
    causeDetail,
    causeStage,
    causeProperty,
    runtimeVersion,
  };
}

export async function inspectAppleTestNotification(input: {
  signedPayload: string;
  verify: (signedPayload: string) => Promise<{ notificationType?: string }>;
}) {
  try {
    const notification = await input.verify(input.signedPayload);
    return notification.notificationType === "TEST"
      ? { valid: true, status: "OK" }
      : { valid: false, status: "UNEXPECTED_NOTIFICATION_TYPE" };
  } catch (error) {
    return { valid: false, ...appleVerificationFailureDetails(error) };
  }
}
