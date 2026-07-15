import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import {
  decryptPushToken,
  digest,
  encryptPushToken,
  importTokenEncryptionKey,
} from "./token-crypto.ts";

Deno.test("push tokens are encrypted with binding-authenticated AES-GCM", async () => {
  const key = await importTokenEncryptionKey("11".repeat(32));
  const token = "ab".repeat(32);
  const encrypted = await encryptPushToken(token, "owner-a:alert", key);
  assertEquals(
    await decryptPushToken(
      encrypted.ciphertext,
      encrypted.iv,
      "owner-a:alert",
      key,
    ),
    token,
  );
  await assertRejects(() =>
    decryptPushToken(
      encrypted.ciphertext,
      encrypted.iv,
      "owner-b:alert",
      key,
    )
  );
});

Deno.test("installation and token hashes are namespace separated", async () => {
  const value = "same-input";
  const installation = await digest(value, "installation");
  const token = await digest(value, "apns-token");
  assertEquals(installation.length, 64);
  assertEquals(installation === token, false);
});
