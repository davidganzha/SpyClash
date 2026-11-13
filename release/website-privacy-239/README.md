# Reviewed policy update for the actual published site

Published after explicit approval on 13 November 2026 at 10:27:36 UTC.
All five public files match the reviewed package. The backend function snapshot
and builder policy source stayed unchanged. Receipt:
[`QA/website-privacy-239/deployment-receipt.json`](../../QA/website-privacy-239/deployment-receipt.json).

Target: canonical Base44 app `69a0e57fa939f578082f8091`,
`https://spyclash.com/privacypolicy`, site-only `POST /deploy-dist`.

The previously prepared four-language branch `36f61fbc` does not reproduce
the published website. Do not deploy its full site. This candidate uses the
retained, actually published source from the October 27 policy release.
All five current public files and all five rebuilt baseline files match exactly.

Only the existing English policy's section 5 and revision month change. The
section describes optional Unity ads, denied-consent/nonbehavioral settings,
provider data handling, server reward records and the verified LIMITLESS flow.
Existing Game Center, Supabase, Apple purchases and deletion disclosures remain.
The prepared four-language policy stays an unpublished draft for its own branch.

Independent review confirms one of 164 source files changes. After normalizing
the new policy text, date and generated asset names, every compiled byte matches
the published baseline. CSS, manifest and authentication wrapper are preserved.
The local page rendered the new text with the existing provider disclosures.
Exact file hashes and upload archive hash are in the adjacent manifests.

The scoped source/content checkpoint increments the repository build to 239.
This does not rebuild, replace or re-upload the already delivered iOS binary
1.0.4 (238); App Store Connect continues to use that verified binary.

Publication rechecked the five live baseline hashes, uploaded the exact archive,
then verified all five deployed files and confirmed unrelated backend/source state.
The previous published archive is retained locally as a rollback artifact.
Unity seller entries and App Store privacy labels remain separate requirements.
