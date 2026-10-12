import http from 'node:http';
import https from 'node:https';
import { requireAllowedTestTarget } from '../client/game-client.mjs';

/** Test transport: real HTTP forwarding; never fabricates an RPC result. */
export async function faultProxy(upstream, { config } = {}) {
  const target = requireAllowedTestTarget(upstream, config);
  if (!['http:', 'https:'].includes(target.protocol)) throw new Error('Fault proxy requires HTTP(S)');
  let dropRequestID = null;
  let port = 0;
  const stats = { forwardedCommands: 0, droppedResponses: 0, committedStatus: null };
  const server = http.createServer(async (req, res) => {
    // Never permit absolute-form requests to turn this into an open proxy.
    if (!req.url.startsWith('/') || req.url.startsWith('//')) { res.writeHead(400); res.end(); return; }
    const destination = new URL(req.url, target);
    if (destination.origin !== target.origin || destination.username || destination.password) { res.writeHead(400); res.end(); return; }
    const chunks = [];
    let bytes = 0;
    for await (const chunk of req) {
      bytes += chunk.length;
      if (bytes > 64 * 1024) { res.writeHead(413); res.end(); return; }
      chunks.push(chunk);
    }
    const body = Buffer.concat(chunks);
    const isCommand = req.url.split('?')[0] === '/rest/v1/rpc/game_command';
    if (isCommand) stats.forwardedCommands += 1;
    let shouldDrop = false;
    if (isCommand && dropRequestID) {
      let parsed;
      try { parsed = JSON.parse(body.toString('utf8')); }
      catch { res.writeHead(400); res.end(); return; }
      shouldDrop = parsed.p_request_id === dropRequestID;
      if (shouldDrop) dropRequestID = null;
    }
    const headers = { ...req.headers, host: target.host };
    delete headers.connection;
    const transport = target.protocol === 'https:' ? https : http;
    const outgoing = transport.request(destination, { method: req.method, headers, timeout: 20_000 }, (incoming) => {
      const response = [];
      incoming.on('data', (chunk) => response.push(chunk));
      incoming.on('end', () => {
        // A successful, fully received upstream response establishes that the
        // database transaction completed. Only the downstream acknowledgement
        // is discarded. The game client never receives this receipt.
        if (shouldDrop && incoming.statusCode >= 200 && incoming.statusCode < 300) {
          stats.droppedResponses += 1;
          stats.committedStatus = incoming.statusCode;
          res.destroy();
          return;
        }
        res.writeHead(incoming.statusCode, incoming.headers);
        res.end(Buffer.concat(response));
      });
    });
    outgoing.on('error', () => res.destroy());
    outgoing.on('timeout', () => { outgoing.destroy(); res.destroy(); });
    outgoing.end(body);
  });
  const start = async () => {
    await new Promise((resolve, reject) => {
      server.once('error', reject);
      server.listen(port, '127.0.0.1', () => { server.off('error', reject); resolve(); });
    });
    port = server.address().port;
  };
  const stop = async () => {
    if (!server.listening) return;
    const stopped = new Promise((resolve) => server.close(resolve));
    server.closeAllConnections();
    await stopped;
  };
  await start();
  return {
    url: `http://127.0.0.1:${port}`,
    stats,
    dropNextResponse(requestID) { dropRequestID = requestID; },
    disconnect: stop,
    reconnect: start,
    close: stop,
  };
}
