import { Buffer } from 'node:buffer';
import { createRequire } from 'node:module';
import type { KeyObject, X509Certificate } from 'node:crypto';
import { X509 } from 'npm:jsrsasign@11.1.3';

// Apple SDK 3.1.0 and jsonwebtoken use this same mutable CommonJS export.
// Install before importing the SDK: jsonwebtoken captures its key factories.
const nodeCrypto = createRequire(import.meta.url)('crypto') as typeof import('node:crypto');
const installed = Symbol.for('spyclash.apple-node-crypto-compatibility.v1');
const probePublicKey = 'MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEKYz8fDnrfTMqZ7+Se8AnT58dqnZpDgbiLup7OZ9TRcKE2Bc4JO2fdeaZ5QNHkNSGk244clCyYKlMOAtHX0qlOQ==';
const canonicalCurves: Record<string, string> = {
  'P-256': 'prime256v1', p256: 'prime256v1',
  'P-384': 'secp384r1', p384: 'secp384r1',
  'P-521': 'secp521r1', p521: 'secp521r1',
};

function derBytes(input: ConstructorParameters<typeof X509Certificate>[0]): Buffer {
  const encoded = typeof input === 'string' ? Buffer.from(input)
    : ArrayBuffer.isView(input) ? Buffer.from(input.buffer, input.byteOffset, input.byteLength)
    : Buffer.from(input as ArrayBuffer);
  const text = encoded.toString('utf8').trimStart();
  const pem = text.startsWith('-----BEGIN CERTIFICATE-----')
    ? text.match(/^-----BEGIN CERTIFICATE-----([\s\S]*?)-----END CERTIFICATE-----/) : null;
  return pem ? Buffer.from(pem[1].replace(/\s/g, ''), 'base64') : Buffer.from(encoded);
}

function needsCertificateCompatibility(certificate: X509Certificate): boolean {
  for (const operation of [
    () => certificate.toString(), () => certificate.raw,
    () => certificate.infoAccess, () => certificate.verify(certificate.publicKey),
  ]) {
    try { operation(); }
    catch (error) {
      // A malformed certificate/configuration must not be treated as a missing
      // runtime feature. Construction already used the native certificate parser.
      if (error instanceof Error && /not implemented.*X509Certificate/i.test(error.message)) return true;
      throw error;
    }
  }
  return false;
}

/** Restore Node API behavior missing in Supabase edge-runtime 1.70.5/Deno 2.1.4.
 * Native parsing, keys, dates, issuer/subject and CA constraints stay in use.
 * Apple's full verifier still checks the chain, extensions, OCSP and JWS. */
export function ensureAppleX509Compatibility(rootCertificate: Uint8Array): void {
  const runtime = nodeCrypto as typeof nodeCrypto & { [installed]?: boolean };
  if (runtime[installed]) return;
  const NativeCertificate = runtime.X509Certificate;
  const nativeCreatePublicKey = runtime.createPublicKey;
  const nativeCreatePrivateKey = runtime.createPrivateKey;
  const root = new NativeCertificate(Buffer.from(rootCertificate));

  if (needsCertificateCompatibility(root)) {
    class CompatibleCertificate extends NativeCertificate {
      #der: Buffer;
      #parsed: InstanceType<typeof X509>;
      constructor(input: ConstructorParameters<typeof NativeCertificate>[0]) {
        super(input);
        this.#der = derBytes(input);
        this.#parsed = new X509();
        this.#parsed.readCertHex(this.#der.toString('hex'));
        // Node's type declarations expose these runtime accessors as readonly
        // fields. Define own accessors without changing the native prototype.
        Object.defineProperties(this, {
          raw: { get: () => Buffer.from(this.#der) },
          infoAccess: { get: () => this.#readInfoAccess() },
        });
      }
      override toString(): string {
        return '-----BEGIN CERTIFICATE-----\n' + this.#der.toString('base64').match(/.{1,64}/g)!.join('\n')
          + '\n-----END CERTIFICATE-----\n';
      }
      #readInfoAccess(): string | undefined {
        const access = this.#parsed.getExtAIAInfo();
        const lines: string[] = [];
        for (const [label, urls] of [['OCSP', access?.ocsp], ['CA Issuers', access?.caissuer]] as const) {
          for (const url of urls || []) {
            // Node quotes control characters in AIA values. Reject them here so
            // they cannot create another field in the SDK's line-based parser.
            if (typeof url !== 'string' || /[\u0000-\u001f\u007f]/.test(url)) throw new Error('Invalid certificate authority information access.');
            lines.push(`${label} - URI:${url}`);
          }
        }
        return lines.length ? lines.join('\n') : undefined;
      }
      override verify(publicKey: KeyObject): boolean {
        const signatureAlgorithm = this.#parsed.getSignatureAlgorithmField();
        const issuerKeyType = publicKey.asymmetricKeyType;
        // Native X509 returns false when a candidate issuer has the wrong key
        // type. jsrsasign throws for an ECDSA certificate with an RSA key, which
        // would abort Apple's trusted-root search before a later matching root.
        if (signatureAlgorithm.endsWith('withECDSA') && issuerKeyType !== 'ec') return false;
        if (/withRSA(?:andMGF1)?$/.test(signatureAlgorithm)
            && issuerKeyType !== 'rsa' && issuerKeyType !== 'rsa-pss') return false;
        // Use the SDK's pinned ASN.1/signature library for the missing synchronous
        // X509 operation. This verifies the certificate signature, never bypasses it.
        return this.#parsed.verifySignature(String(publicKey.export({ type: 'spki', format: 'pem' })));
      }
    }
    runtime.X509Certificate = CompatibleCertificate;
  }

  const probe = nativeCreatePublicKey({ key: Buffer.from(probePublicKey, 'base64'), type: 'spki', format: 'der' });
  if (canonicalCurves[probe.asymmetricKeyDetails?.namedCurve || '']) {
    const normalize = <T extends KeyObject>(key: T): T => {
      const details = key.asymmetricKeyDetails;
      const canonical = details?.namedCurve && canonicalCurves[details.namedCurve];
      if (key.asymmetricKeyType === 'ec' && canonical) {
        // Cross-check the alias against the native public key's actual curve.
        // Private key material is never exported. Mismatches remain unmodified
        // and are rejected by jsonwebtoken's normal algorithm/curve checks.
        const publicKey = key.type === 'private' ? nativeCreatePublicKey(key) : key;
        const curve = publicKey.export({ format: 'jwk' }).crv;
        if (curve && canonicalCurves[curve] === canonical) {
          Object.defineProperty(key, 'asymmetricKeyDetails', {
            value: { ...details, namedCurve: canonical }, configurable: true,
          });
        }
      }
      return key;
    };
    runtime.createPublicKey = ((...args: Parameters<typeof nativeCreatePublicKey>) =>
      normalize(nativeCreatePublicKey(...args))) as typeof nativeCreatePublicKey;
    runtime.createPrivateKey = ((...args: Parameters<typeof nativeCreatePrivateKey>) =>
      normalize(nativeCreatePrivateKey(...args))) as typeof nativeCreatePrivateKey;
  }
  Object.defineProperty(runtime, installed, { value: true });
}
