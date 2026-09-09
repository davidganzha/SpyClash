import { Buffer } from "node:buffer";
import { Response as NodeFetchResponse } from "npm:node-fetch@2.7.0";

type ResponseBody = { arrayBuffer(): Promise<ArrayBuffer> };

// Base44's node-fetch shim returns a Web Response. Apple SDK 3.1.0 uses
// node-fetch 2's buffer() for the OCSP DER response. Adapt only body reading;
// the SDK still verifies the complete OCSP response, certificate chain and JWS.
export function installNodeFetchBufferCompatibility(
  prototype: object,
): boolean {
  if ("buffer" in prototype) {
    if (typeof (prototype as { buffer: unknown }).buffer !== "function") {
      throw new Error("Incompatible Response buffer implementation.");
    }
    return false;
  }
  if (typeof (prototype as ResponseBody).arrayBuffer !== "function") {
    throw new Error("Response binary body reading is unavailable.");
  }
  Object.defineProperty(prototype, "buffer", {
    configurable: true,
    writable: true,
    enumerable: false,
    value: async function (this: ResponseBody): Promise<Buffer> {
      return Buffer.from(await this.arrayBuffer());
    },
  });
  return true;
}

export function ensureAppleFetchBodyCompatibility() {
  // Cover the Web Response used by the deployment shim and the Node response
  // used by a native node-fetch runtime. Preserve every existing buffer().
  const prototypes = new Set<object>([Response.prototype]);
  if (typeof NodeFetchResponse === "function") {
    prototypes.add(NodeFetchResponse.prototype);
  }
  for (const prototype of prototypes) {
    installNodeFetchBufferCompatibility(prototype);
  }
}
