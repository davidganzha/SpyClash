import { Buffer } from "node:buffer";
import { Response as NodeFetchResponse } from "npm:node-fetch@2.7.0";
import { installNodeFetchBufferCompatibility } from "./apple-fetch-body-compatibility.ts";

function assert(condition: unknown, message: string) {
  if (!condition) throw new Error(message);
}

Deno.test("the Web Response adapter preserves every byte of an OCSP binary body", async () => {
  class AdaptedResponse extends Response {}
  assert(
    installNodeFetchBufferCompatibility(AdaptedResponse.prototype),
    "adapter not installed",
  );
  const bytes = new Uint8Array([0x30, 0x82, 0x00, 0xff, 0x80, 0x01]);
  const response = new AdaptedResponse(bytes) as AdaptedResponse & {
    buffer(): Promise<Buffer>;
  };
  const body = await response.buffer();
  assert(Buffer.isBuffer(body), "Apple's expected Buffer was not returned");
  assert(body.equals(Buffer.from(bytes)), "binary OCSP response was changed");
  assert(response.bodyUsed, "native body consumption semantics were bypassed");
  let secondReadFailed = false;
  try {
    await response.buffer();
  } catch {
    secondReadFailed = true;
  }
  assert(secondReadFailed, "a consumed body was silently accepted");
});

Deno.test("a binary body read failure propagates without creating an empty success", async () => {
  const failure = new Error("body stream failed");
  class BrokenBody {
    arrayBuffer(): Promise<ArrayBuffer> {
      return Promise.reject(failure);
    }
  }
  installNodeFetchBufferCompatibility(BrokenBody.prototype);
  let observed: unknown;
  try {
    await (new BrokenBody() as BrokenBody & { buffer(): Promise<Buffer> })
      .buffer();
  } catch (error) {
    observed = error;
  }
  assert(observed === failure, "body failure was swallowed or replaced");
});

Deno.test("native and inherited node-fetch buffer methods are preserved exactly", async () => {
  const nodePrototype = NodeFetchResponse.prototype as unknown as {
    buffer(): Promise<Buffer>;
  };
  const original = nodePrototype.buffer;
  assert(
    !installNodeFetchBufferCompatibility(NodeFetchResponse.prototype),
    "existing node-fetch implementation overwritten",
  );
  assert(
    nodePrototype.buffer === original,
    "native method identity changed",
  );
  class NodeResponseSubclass extends NodeFetchResponse {}
  assert(
    !installNodeFetchBufferCompatibility(NodeResponseSubclass.prototype),
    "inherited node-fetch method overwritten",
  );
  const bytes = new Uint8Array([0x00, 0xff, 0x80]);
  assert(
    (await (new NodeResponseSubclass(bytes) as unknown as {
      buffer(): Promise<Buffer>;
    }).buffer()).equals(Buffer.from(bytes)),
    "native node-fetch body changed",
  );
});

Deno.test("a frozen or conflicting Response implementation fails closed", () => {
  for (
    const prototype of [
      Object.freeze({
        arrayBuffer() {
          return Promise.resolve(new ArrayBuffer(0));
        },
      }),
      {
        buffer: null,
        arrayBuffer() {
          return Promise.resolve(new ArrayBuffer(0));
        },
      },
      {},
    ]
  ) {
    let failed = false;
    try {
      installNodeFetchBufferCompatibility(prototype);
    } catch {
      failed = true;
    }
    assert(failed, "unsupported runtime was silently accepted");
  }
});
