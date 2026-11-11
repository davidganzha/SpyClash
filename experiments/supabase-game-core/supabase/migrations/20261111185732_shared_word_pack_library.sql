-- Server-only shared stock. Existing account-owned cache records are not copied.
-- Raw themes, exclusion words and account identifiers are deliberately absent.
create table public.word_pack_library_variants (
  variant_key text primary key check (variant_key ~ '^swv1_[A-Za-z0-9_-]{43}$'),
  cache_key text not null check (cache_key ~ '^swk1_[A-Za-z0-9_-]{43}$'),
  language_key text not null check (length(language_key) between 1 and 35),
  prompt_version text not null check (prompt_version ~ '^[a-z0-9][a-z0-9._-]{0,63}$'),
  exclusion_key text not null check (exclusion_key ~ '^swe1_[A-Za-z0-9_-]{43}$'),
  words jsonb not null check (jsonb_typeof(words) = 'array' and jsonb_array_length(words) between 2 and 100),
  exhausted boolean not null,
  word_count integer not null check (word_count = jsonb_array_length(words)),
  generated_at timestamptz not null,
  expires_at timestamptz not null,
  check (expires_at > generated_at and expires_at <= generated_at + interval '30 days')
);
create index word_pack_library_lookup on public.word_pack_library_variants (cache_key, expires_at);

create table public.word_pack_library_leases (
  cache_key text primary key check (cache_key ~ '^swk1_[A-Za-z0-9_-]{43}$'),
  token uuid not null,
  expires_at timestamptz not null
);

alter table public.word_pack_library_variants enable row level security;
alter table public.word_pack_library_leases enable row level security;
revoke all on public.word_pack_library_variants, public.word_pack_library_leases from public, anon, authenticated;
grant usage on schema public to service_role;
grant select, insert, update, delete on public.word_pack_library_variants, public.word_pack_library_leases to service_role;

-- A JSON aggregate avoids PostgREST's row limit truncating an otherwise usable
-- pool. Application selection verifies every row before serving its words.
create function public.word_pack_library_read(p_cache_key text)
returns jsonb language sql stable security invoker set search_path = '' as $$
  select coalesce(jsonb_agg(to_jsonb(v) order by v.generated_at desc, v.variant_key), '[]'::jsonb)
  from public.word_pack_library_variants v
  where v.cache_key = p_cache_key and v.expires_at > now();
$$;

-- Requests from either backend compete for the same topic/version lease. A
-- losing request retries; it must not independently start paid generation.
create function public.word_pack_library_claim(p_cache_key text, p_token uuid)
returns boolean language sql volatile security invoker set search_path = '' as $$
  with claimed as (
    insert into public.word_pack_library_leases(cache_key, token, expires_at)
    values (p_cache_key, p_token, clock_timestamp() + interval '5 minutes')
    on conflict(cache_key) do update
      set token = excluded.token, expires_at = excluded.expires_at
      where public.word_pack_library_leases.expires_at <= clock_timestamp()
         or public.word_pack_library_leases.token = excluded.token
    returning token
  )
  select exists(select 1 from claimed);
$$;

-- Publication is fenced by the generation lease. A delayed worker cannot
-- overwrite stock after another request has acquired the expired lease.
create function public.word_pack_library_publish(p_record jsonb, p_token uuid)
returns boolean language plpgsql volatile security invoker set search_path = '' as $$
declare
  live_token uuid;
  generated timestamptz;
  expiry timestamptz;
begin
  if jsonb_typeof(p_record) is distinct from 'object'
     or jsonb_typeof(p_record->'words') is distinct from 'array'
     or jsonb_typeof(p_record->'exhausted') is distinct from 'boolean' then
    raise exception 'Invalid shared word pack' using errcode = '22023';
  end if;
  if jsonb_array_length(p_record->'words') not between 2 and 100
     or exists(select 1 from jsonb_array_elements(p_record->'words') w
       where jsonb_typeof(w) is distinct from 'string' or length(w #>> '{}') not between 1 and 120) then
    raise exception 'Invalid shared words' using errcode = '22023';
  end if;
  select token into live_token from public.word_pack_library_leases
    where cache_key = p_record->>'cache_key' and token = p_token
      and expires_at > clock_timestamp() for update;
  if live_token is null then return false; end if;

  generated := (p_record->>'generated_at')::timestamptz;
  expiry := (p_record->>'expires_at')::timestamptz;
  if generated is null or expiry is null or generated > clock_timestamp() + interval '1 minute'
     or expiry <= clock_timestamp() then
    raise exception 'Invalid shared word pack expiry' using errcode = '22023';
  end if;

  insert into public.word_pack_library_variants
    (variant_key, cache_key, language_key, prompt_version, exclusion_key, words, exhausted, word_count, generated_at, expires_at)
  values (p_record->>'variant_key', p_record->>'cache_key', p_record->>'language_key',
    p_record->>'prompt_version', p_record->>'exclusion_key', p_record->'words',
    (p_record->>'exhausted')::boolean, jsonb_array_length(p_record->'words'), generated, expiry)
  on conflict(variant_key) do update set generated_at = excluded.generated_at, expires_at = excluded.expires_at
    where public.word_pack_library_variants.cache_key = excluded.cache_key;
  -- Bound expired storage opportunistically, within the topic whose lease is
  -- held. Unrelated topics and every active variant remain untouched.
  delete from public.word_pack_library_variants
    where cache_key = p_record->>'cache_key' and expires_at <= clock_timestamp();
  return true;
end;
$$;

create function public.word_pack_library_release(p_cache_key text, p_token uuid)
returns void language sql volatile security invoker set search_path = '' as $$
  delete from public.word_pack_library_leases where cache_key = p_cache_key and token = p_token;
$$;

revoke all on function public.word_pack_library_read(text),
  public.word_pack_library_claim(text, uuid),
  public.word_pack_library_publish(jsonb, uuid),
  public.word_pack_library_release(text, uuid) from public, anon, authenticated;
grant execute on function public.word_pack_library_read(text),
  public.word_pack_library_claim(text, uuid),
  public.word_pack_library_publish(jsonb, uuid),
  public.word_pack_library_release(text, uuid) to service_role;
