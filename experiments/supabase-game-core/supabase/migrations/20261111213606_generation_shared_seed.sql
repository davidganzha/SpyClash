-- Server-only reconstruction data for partial library top-ups. Preserve the
-- original result/completion invariant and all existing table privileges/RLS.
alter table game_center_private.generation_requests
  add column if not exists seed_words jsonb;
alter table game_center_private.generation_requests
  add constraint generation_seed_words_array check (
    seed_words is null or
    (jsonb_typeof(seed_words) = 'array' and jsonb_array_length(seed_words) <= 99)
  );
comment on column game_center_private.generation_requests.seed_words is
  'Validated shared words retained before provider work; immutable once provider calls exist. Never returned as a pending result.';
