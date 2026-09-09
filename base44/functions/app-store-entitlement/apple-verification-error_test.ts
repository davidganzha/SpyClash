import {
  VerificationException,
  VerificationStatus,
} from "npm:@apple/app-store-server-library@3.1.0";
import {
  appleVerificationFailureDetails,
  inspectAppleTestNotification,
} from "./apple-verification-error.ts";

function assert(condition: unknown, message: string) {
  if (!condition) throw new Error(message);
}

Deno.test("empty Apple verification errors retain their actionable status without their payload", () => {
  const cause = new Error(
    "eyJprivate.payload.signature https://example.test/?token=private-secret",
  );
  cause.name = "PrivateSecretClass";
  Object.assign(cause, { code: "PRIVATE_SECRET_CODE" });
  const error = new VerificationException(
    VerificationStatus.INVALID_APP_IDENTIFIER,
    cause,
  );
  assert(
    error.message === "",
    "fixture does not reproduce Apple's empty error message",
  );
  const details = appleVerificationFailureDetails(error);
  assert(details.status === "INVALID_APP_IDENTIFIER", "Apple status was lost");
  assert(
    details.causeClass === "UnknownError" && details.causeCode === null,
    "unbounded cause metadata was exposed",
  );
  assert(
    !JSON.stringify(details).toLowerCase().includes("private"),
    "sensitive nested fields leaked",
  );
});

Deno.test("network and unsupported runtime failures remain distinguishable using closed values", () => {
  const network = Object.assign(new Error("socket hang up, secret url"), {
    code: "ECONNRESET",
  });
  const networkDetails = appleVerificationFailureDetails(
    new VerificationException(
      VerificationStatus.RETRYABLE_VERIFICATION_FAILURE,
      network,
    ),
  );
  assert(
    networkDetails.causeCode === "ECONNRESET" &&
      networkDetails.causeDetail === "NETWORK_SOCKET_CLOSED",
    "OCSP network cause lost",
  );
  const runtime = new Error(
    "Not implemented: crypto.X509Certificate.prototype.verify",
  );
  const runtimeDetails = appleVerificationFailureDetails(
    new VerificationException(VerificationStatus.VERIFICATION_FAILURE, runtime),
  );
  assert(
    runtimeDetails.causeDetail === "NODE_X509_VERIFY_UNSUPPORTED",
    "Deno crypto cause lost",
  );
});

Deno.test("a replay diagnostic verifies a TEST but rejects other notification types", async () => {
  let observed = "";
  const result = await inspectAppleTestNotification({
    signedPayload: "server-only-test",
    verify: async (payload) => {
      observed = payload;
      return { notificationType: "TEST" };
    },
  });
  assert(
    observed === "server-only-test" && result.valid && result.status === "OK",
    "TEST verification did not run",
  );
  const other = await inspectAppleTestNotification({
    signedPayload: "server-only-transaction",
    verify: async () => ({ notificationType: "DID_RENEW" }),
  });
  assert(
    !other.valid && other.status === "UNEXPECTED_NOTIFICATION_TYPE",
    "non-TEST payload accepted as TEST",
  );
  assert(
    !JSON.stringify([result, other]).includes("server-only"),
    "signed payload escaped diagnostic",
  );
});

Deno.test("verifier initialization failure reports no raw message or stack", async () => {
  const result = await inspectAppleTestNotification({
    signedPayload: "private-payload",
    verify: () =>
      Promise.reject(
        new TypeError("private-key-payload https://example.test/?token=secret"),
      ),
  });
  assert(
    !result.valid && result.status === "VERIFIER_RUNTIME_FAILURE",
    "initialization failure was mistaken for success",
  );
  const serialized = JSON.stringify(result);
  assert(
    !serialized.includes("private") && !serialized.includes("secret") &&
      !serialized.includes("https"),
    "runtime failure detail leaked",
  );
});

Deno.test("TypeError stage and operation are classified without exposing any stack or message text", () => {
  const samples = [
    [
      "intermediate.verify is not a function",
      "verifyCertificateChainWithoutCaching",
      "VERIFY_METHOD_UNAVAILABLE",
      "CERTIFICATE_CHAIN_VALIDATION",
    ],
    [
      "parsedResponse.certs is not iterable",
      "checkOCSPStatus",
      "OCSP_CERTIFICATES_NOT_ITERABLE",
      "OCSP_VALIDATION",
    ],
    [
      "jsrsasign_1.X509 is not a constructor",
      "verifyCertificateChainWithoutCaching",
      "X509_CONSTRUCTOR_UNAVAILABLE",
      "CERTIFICATE_CHAIN_VALIDATION",
    ],
  ];
  for (const [message, method, detail, stage] of samples) {
    const cause = new TypeError(`${message}: secret-token`);
    cause.stack = `at ${method} (https://private.example/?token=secret)`;
    const result = appleVerificationFailureDetails(
      new VerificationException(VerificationStatus.VERIFICATION_FAILURE, cause),
    );
    assert(
      result.causeDetail === detail && result.causeStage === stage,
      "closed classification mismatch",
    );
    assert(
      !JSON.stringify(result).includes("secret") &&
        !JSON.stringify(result).includes("private"),
      "stack/message escaped classifier",
    );
  }
});

Deno.test("node-fetch buffer mismatch is identified without the raw response or error", () => {
  const cause = new TypeError(
    "response.buffer is not a function: private-response",
  );
  cause.stack = "at checkOCSPStatus (https://private.example/?token=secret)";
  const result = appleVerificationFailureDetails(
    new VerificationException(VerificationStatus.VERIFICATION_FAILURE, cause),
  );
  assert(
    result.causeProperty === "buffer" &&
      result.causeStage === "OCSP_VALIDATION",
    "node-fetch mismatch not classified",
  );
  assert(!JSON.stringify(result).includes("private"), "raw detail leaked");
});
