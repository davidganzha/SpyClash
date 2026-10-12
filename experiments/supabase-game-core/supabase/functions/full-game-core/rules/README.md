# Original game policies

Vendored from `base44/functions/gameRoomAction` at source checkpoint `568720f1`.
Original production files are unchanged. The full engine uses these existing policies for parity; it does not import the Base44 SDK or lease orchestrator.

- `active-game-lobby-return-policy.ts`: SHA256 `be935e238fc543e3f94328296d5114fcee3aadce370cd1097b26f2ac0bb05416`
- `association-turn-order.ts`: SHA256 `5dc3497378f59ed654d85ef8e0f0669e7497a4094fd67f76465a7e352ed81ffa`
- `content-safety.ts`: SHA256 `9d2698787d133a6eb4a7807c9765ceafdcf726671839621248189cfcb634e84b`
- `detective-vote-policy.ts`: SHA256 `74e51a572605127319b48c018fd6fb8169f96237077c56a2d9f76f2ec9cad5c4`
- `finished-room-departure-policy.ts`: SHA256 `d27b46836bb44f1d8086af6bcb03481f16ac801b993117c9539c427fbb18ab14`
- `game-history-idempotency.ts`: SHA256 `8e27cd9df57aa9cdf7ee2c0164bf9a92e40fa70c93227946a5d3b748f44502d0`
- `game-round.ts`: SHA256 `85c38cfba7b78ec6dbb5060d8478c5c4ebd454d835f1999f700030bdfc3684af`
- `game-timer-policy.ts`: SHA256 `33837768c2a60210a3ef2b5cc68ca1c76f821cfc5fdbd0e845f0ac5f595a78ee`
- `lobby-kick-policy.ts`: SHA256 `37eb0383c205282027e5420bb2aef6a73955dd8fa67d27e568e4fb83f2eb74a6`
- `lobby-state-policy.ts`: SHA256 `de7c5c0ca28b277753c5b1816b0dc1088b34b4961418a805e493005931c4f4d6`
- `multi-spy-policy.ts`: SHA256 `8a9ff1826c2b3d5c9033897eccebbd614471b9326aaff3af9797efaa23ec91e9`
- `question-round-policy.ts`: SHA256 `e59d66fb4c808ae68357907971d440c0a779351db7ce225e1675ca6b250929ad`
- `question-turn-order.ts`: SHA256 `8da578fb29e840b1aa9c5b967fac64475f4eb8bb0ac83922e4ce2c279af361ef`
- `replay-auto-start-policy.ts`: SHA256 `1c4cbbe426152c8120ea86353d0e1f5667d0ebbc491e9d7313868a92c1e2d0a7`
- `replay-policy.ts`: SHA256 `87f19132b355bc97b54ee802f83a92976364d09716184a14d7717a5950841380`
- `room-interaction-safety.ts`: SHA256 `b6183d05fb00fdd2cfd473f50afb92ed58a0f98d2f2f21c7611f5fb72264b06c`
- `room-membership-generation.ts`: SHA256 `97f10bf14a8dff24547a372e7bd26f423b17660eb524f7e3bf75965478fbc10b`
- `room-projection.ts`: SHA256 `6492fe9ac5f8aae257578025cafb65726e9c00b96f999200add3f979ff4559ab`
- `room-result-policy.ts`: SHA256 `c2fcfb859df4e1596d5a42c17a00434119e835f37f56cc340bcde922b89da874`
- `round-action-access.ts`: SHA256 `8175ec5ddf9bb115549b36c81b6e6c2b345cc703aae6df95df9957b46d8e5dda`
- `start-word-pool-policy.ts`: SHA256 `b4f7df0d7eb40050a65413d6c33db3c5f81965ccf0e64584b24f60160c97b01b`
- `terminal-finalization-scope.ts`: SHA256 `ecddb8175e7bb0d2d09019a4074aa59e5ae2ed3fc2873c0b4791459a3370dc12`
- `terminal-outbox-commit.ts`: SHA256 `6b87e575425faee886dff8e93534f68ac821a59760d7c30da829efcdc84bba1e`

Port-only adaptation: `multi-spy-policy.ts` adds an optional entropy argument to `activeDepartureTransition`, forwarding it to the unchanged question/association roster algorithms. Defaults retain original behavior; the reducer injects per-request entropy instead of ambient randomness. The hashes above identify the original source before this adapter.

Additional unchanged original leaderboard modules (same canonical baseline):

- `competitive-stats.ts` — SHA256 `058bfd9029172554a0f648c8b23b78e788b7b1f6b9e89502974ff9bdc64d0a45`
- `leaderboard.ts` — SHA256 `1127d3b778fb47c6e8bc0ea3b176ec84e2e99638f2db35d3ce2ea8e575b34b94`
