# Production safety

- Never deploy, publish, promote, release, or otherwise mutate a production environment without explicit approval in the current chat immediately before the production action.
- This prohibition includes App Store Connect submission, App Review submission, TestFlight promotion, App Store release, Base44 production deploy/publish, production Stripe changes, production webhook changes, and production secret/configuration changes.
- General instructions such as "continue", "finish", "prepare for release", or approval given in another chat do not authorize a production action.
- Agents may inspect, audit, prepare code and metadata, build locally, and run tests or dry runs that do not mutate production.
- Before any authorized production action, state the exact target and operation and obtain a fresh, unambiguous confirmation from the user.
