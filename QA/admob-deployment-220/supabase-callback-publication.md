# Supabase callback-only deployment 220

Approved scope: finish connecting AdMob confirmation while advertisements and new generation limits remain disabled.

Published only `rewarded-generation-ssv` version 2 in project `bbkfsgnordtdiblgdzkg`. Its Google-authenticated public endpoint keeps `verify_jwt=false`. Fresh version-1 source readback matched all 10 previously deployed files. Replaced only `rewarded-generation-ssv/handler.ts`; all 9 existing dependency files were reused exactly. No app-services deployment, secret changes, migrations or grants in this update.

The added branch first validates Google's signature, then requires the exact reserved test markers, synthetic unit `1234567890`, reward `1 generation`, and a valid owned configured unit. It returns `reward_granted:false` before either credit ledger or legacy forwarding. Real callback validation is unchanged.

Deployment bundle SHA256: `df882a7ce4feab9beb0d02562437a1d3419ea677ae0a9ce74561d821564c485b`.
Handler SHA256: `6ec8e0e963c4d3b6bbd401df3cac3268fa18e229f7bdda40c15908c8a88adee4`.

Validation: 13 offline tests and entrypoint typecheck passed against the exact candidate dependency graph. Readback matched all 10 runtime files. Unsigned callback returned 400; app-services without JWT returned 401. App-services remains version19 / JWTtrue with its previous source bundle hash. Feature flag digest still matches explicit `false`; owned ad-unit digest matches the approved value. Native reward ledger had 0 rows and 0 earned rewards before AdMob retry.

The live signed Google dashboard retry returned HTTP 200 at 2026-11-07 19:14:31 UTC. Sanitized evidence confirms the exact reserved markers, synthetic unit 1234567890 and reward 1 generation. A subsequent native ledger readback still showed 0 attempts and 0 earned credits. See admob-verify-sanitized.json. AdMob URL saving is performed separately by the parent agent.

A successful signed dashboard probe proves callback delivery only. It does not prove a completed ad, real native/legacy credit, or readiness to enable advertising/new quotas. No callback signatures, raw query URLs, or secret values are saved here.

