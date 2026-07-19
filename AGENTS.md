# Agent deployment safety

- Never deploy, publish, release, upload, or submit anything to a production environment on an agent's own initiative.
- Production actions require a separate, explicit instruction in the current chat that names the target and authorizes that production action.
- General instructions such as "continue", "finish", "make it release-ready", or "prepare for App Store" are not production authorization.
- This restriction includes Base44 production deploys, App Store Connect uploads/submissions/releases, production APNs operations, production migrations, and deployment-triggering GitHub actions.
- Agents may prepare code, run local tests, build archives, perform dry runs, and report the exact remaining production step without executing it.
