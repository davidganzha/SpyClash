Deno.serve(() =>
  Response.json(
    {
      error:
        "Account deletion is temporarily unavailable during a security migration. No account data was changed.",
      code: "maintenance",
      retryable: true,
    },
    {
      status: 503,
      headers: {
        "cache-control": "no-store",
        "retry-after": "300",
      },
    },
  )
);
