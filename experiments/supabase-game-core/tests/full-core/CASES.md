# Full-core integration acceptance cases

These cases target the original action protocol documented in `../../FULL-CORE-PARITY.md`. They require the trusted service, a real local PostgreSQL database, independent authenticated actors and real HTTP requests. Pure reducer unit tests are a separate layer. No production targets or production identities are permitted.

| Group | Required externally observable case | Database invariant |
|---|---|---|
| Join race | Six clients join one six-character room concurrently; every unique actor remains present. Repeated join resumes current membership. | One active membership per actor/room; no lost roster update. |
| Ready/start race | Concurrent readiness, duplicate ready intent, concurrent arm/complete calls produce one frozen assignment and one match. | Immutable receipt; one committed match-start identity. |
| Lost acknowledgement | Proxy forwards a real successful command then drops only its completed downstream response. Another actor changes the room. Original actor retries the exact frozen request. | Original receipt returned; no second mutation/revision/start/history row. |
| Mismatched request ID | Reuse actor/request ID with different action, room or nested lobby payload. | Reject before change; original receipt remains unchanged. |
| Transaction rollback | Injected SQL failure rejects a command, then the same frozen command succeeds after removing the fault. Invalid transitions produce a stable business rejection. | Infrastructure failure rolls back room/revision/receipt/history/outbox; business rejection stores one failure receipt while game state remains unchanged. |
| Room independence | Hold one room row lock with a separate admin connection. A command to another room by the same actor completes before release. | Lock scope does not serialize unrelated rooms. |
| Membership fence | Leave and rejoin, then first-send the old membership intent; replay a previously completed old leave. | Neither can remove the new membership. |
| Lobby fence | Change settings after intent preparation; submit the delayed start/ready/settings intent. | No stale settings or generation can start/change the newer lobby. |
| Match/vote fence | Return/replay, then deliver old match actions or an old vote-round ballot. | New match/vote state unchanged. |
| Questions trace | Create/join, authoritative word settings, ready check, roulette, complete, all role-card reads, eight questions, results, continue. | Server timer starts once at final active card read; actor/phase permissions enforced. |
| Associations trace | Configure associations, start, settle spin, advance speakers through a full round, repair after departure. | Every active player appears once per turn cycle; no reroll on retry. |
| Pause/deadline | Host pause/resume; blocked game actions while paused; finalization on server deadline, including concurrent finalizers. | One terminal decision; deterministic pause accumulation; client cannot choose winner. |
| Detective vote | Majority requests open a scoped round; reject self/replacement ballots; N−S vote threshold ejects. Construct an impossible-candidate round and verify cancellation identity. | Scoped immutable ballots, one shared cancellation event; no plurality substitution. |
| Multi-spy | Six/nine players with two/three spies, team-visibility off/on, civilian and spy snapshots. | Frozen unique role assignment; only authorized exact word/team identity projections. |
| Spy guess | Assigned spy submits correct and incorrect guesses in separate matches; civilian attempt rejected. | Whole-match outcome follows original comparison policy, once. |
| Terminal/replay | Finish, unanimous replay auto-arms, then complete a new match; host finished-return without replay unanimity. | Stable source-match fence; one history/stat/outbox effect per result. |
| Departures | Host waiting exit, pre-timer departure, live actor/host departure, finished host succession, close. | Original roster/tombstone/turn/vote/terminal rules; durable closure signal. |
| Access control | Anonymous/outsider snapshot and command attempts; direct secret-table reads; spoofed player/host/role/winner. | Verified actor only; no private-table access or secret-bearing public signals. |
| Offline recovery | A real stopped transport rejects a pending command; reconnect retries the same ID and resnapshots after independent changes. | Same immutable command outcome, no duplicate mutation. |
| Realtime | Subscribe with confirmed server readiness; assert actual WAL signal; disconnect the real socket, mutate elsewhere, reconnect and converge. | Signal contains revision/room only; fallback cannot disguise missing WAL delivery. |

The executable tests must bind to the actual service/bootstrap API when available. This matrix deliberately does not invent another command envelope or bypass authentication to drive gameplay. Direct SQL is allowed only for assertions, deliberate lock control and deterministic server-clock fixtures, never for client gameplay operations.
