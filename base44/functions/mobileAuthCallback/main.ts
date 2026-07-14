const nativeCallbackBase = "spyclash://auth";

function htmlFallback(nativeURL: string) {
  const escaped = nativeURL.replace(/"/g, "&quot;");
  return `<!doctype html>
<html>
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Returning to SpyClash</title>
    <script>location.replace(${JSON.stringify(nativeURL)});</script>
  </head>
  <body style="background:#050505;color:#f4f4f5;font-family:-apple-system,BlinkMacSystemFont,sans-serif;">
    <p>Returning to SpyClash...</p>
    <a style="color:#ef4444;" href="${escaped}">Open SpyClash</a>
  </body>
</html>`;
}

Deno.serve((req) => {
  const requestURL = new URL(req.url);
  const nativeURL =
    `${nativeCallbackBase}?${requestURL.searchParams.toString()}`;

  return new Response(htmlFallback(nativeURL), {
    status: 302,
    headers: {
      "Content-Type": "text/html; charset=utf-8",
      "Location": nativeURL,
      "Cache-Control": "no-store",
    },
  });
});
