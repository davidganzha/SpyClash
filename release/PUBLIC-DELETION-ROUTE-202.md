# Scoped public deletion route activation

The owner approved this exact follow-up on 27 October 2026. The new Base44
route and Supabase app-services routing patch have been deployed. Fresh runtime
responses and one positive historical immutable-owner match are confirmed.
Historical coverage/readiness and the final feature activation are recorded
separately in `PUBLIC-BACKEND-202-ACTIVATION.md`.

The approved 201 deployment installed the four private Supabase migrations,
three functions and disabled configuration. Base44 stored both prepared function
sources and the private receipt entity, but its existing public `deleteAccount`
route still runs the older published handler. A whole app publication would
include unrelated editor drafts and is not part of this operation.

The prepared remedy targets only original Base44 app
`69a0e57fa939f578082f8091` and Supabase `bbkfsgnordtdiblgdzkg`:

1. Create `deleteAccountPublic` from the already reviewed deletion handler.
   All 15 TypeScript files are byte-identical to package 201. Only the function
   name in its deployment metadata changes. Existing `deleteAccount` is retained.
2. Replace only `app-services/main-account-deletion.ts` in the deployed Supabase
   dependency graph. Its three provider operations (capabilities, deletion and
   receipt recovery) use the new fixed route under the validated original app.
3. Prove the new route actually serves the prepared handler, then run the signed
   read-only historical-selector probe. A successful deployment response alone
   does not establish runtime routing or a matching historical key.
4. Only after the positive match and existing checks pass, enable the previously
   approved Game Center, IAP, managed AI and full-deletion flags. No user account
   is deleted by these checks.

No new secrets, schema migrations, full website publication, App Review
submission or App Store release are included in this follow-up.

The archive is `.local/public-server202-alias/package.tar.gz`, SHA256
`7d503d69630416058c15a92b4c8dcdf32dc89a4af9b36fe0cc6179fde01574df`.
The manifest is `.local/public-server202-alias/manifest.json`, SHA256
`e9fe541293bd4b89e012391478c0bc25189a7f4938ebda3564566a12355ce8ad`.
Exactly one of the 68 Supabase deployment files differs from package 201.
Twenty-five focused database/auth/archive tests, the exact overlay typecheck
and independent review passed. Runtime readback now confirms the new handler:
malformed JSON returns 400, unsigned archive probes return 403 and the valid
signed read-only probe returns 200 with the expected historical selector.
