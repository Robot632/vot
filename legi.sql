-- Legile coloniei: o listă de legi, cu data de la care sunt în vigoare.
-- NU șterge nimic: rulează-l o singură dată în Supabase → SQL Editor → New query → Run.
--
--  • O întrebare de tip „Lege” care se încheie ADOPTAT intră automat în legi
--    (cu data la care s-a încheiat votul).
--  • Adminii (președinții) pot adăuga, modifica sau scoate legi.
--  • Toți membrii văd legile și le pot descărca pentru printat.

create table if not exists laws (
  id          bigint generated always as identity primary key,
  law_text    text not null,
  adopted_on  date not null default current_date,
  question_id bigint unique references questions(id) on delete set null,
  removed     boolean not null default false,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz
);
alter table laws enable row level security;
revoke all on laws from anon, authenticated;

drop function if exists list_laws(text);
create function list_laws(p_code text)
returns table(id bigint, law_text text, adopted_on date, updated_at timestamptz, from_vote boolean)
language plpgsql security definer set search_path = public as $$
begin
  perform _member(p_code);
  -- legile adoptate prin vot intră singure în listă; dacă ceva nu merge aici,
  -- lista se arată oricum
  begin
    insert into laws(law_text, adopted_on, question_id)
    select q.question_text,
           (coalesce((to_jsonb(q)->>'decided_at')::timestamptz, q.closes_at, now()) at time zone 'Europe/Bucharest')::date,
           q.id
      from questions q
      join question_outcomes(p_code) o on o.question_id = q.id
     where to_jsonb(q)->>'kind' = 'lege'
       and upper(o.outcome) like 'ADOPTAT%'
       and not exists (select 1 from laws l where l.question_id = q.id)
    on conflict (question_id) do nothing;
  exception when others then null;
  end;
  return query select l.id, l.law_text, l.adopted_on, l.updated_at, l.question_id is not null
    from laws l where not l.removed order by l.adopted_on, l.id;
end $$;

create or replace function add_law(p_code text, p_text text, p_date date) returns bigint
language plpgsql security definer set search_path = public as $$
declare new_id bigint;
begin
  perform _admin(p_code);
  if coalesce(trim(p_text), '') = '' then raise exception 'lege invalida'; end if;
  insert into laws(law_text, adopted_on) values (trim(p_text), coalesce(p_date, current_date))
  returning id into new_id;
  return new_id;
end $$;

create or replace function edit_law(p_code text, p_id bigint, p_text text, p_date date) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform _admin(p_code);
  if coalesce(trim(p_text), '') = '' then raise exception 'lege invalida'; end if;
  update laws set law_text = trim(p_text), adopted_on = coalesce(p_date, adopted_on), updated_at = now()
  where id = p_id and not removed;
end $$;

create or replace function delete_law(p_code text, p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform _admin(p_code);
  -- rămâne în tabel ca să nu fie readusă automat din vot
  update laws set removed = true, updated_at = now() where id = p_id;
end $$;

grant execute on function list_laws(text), add_law(text, text, date), edit_law(text, bigint, text, date), delete_law(text, bigint) to anon;

-- Supabase reîncarcă lista de funcții (altfel site-ul poate să nu le vadă imediat).
notify pgrst, 'reload schema';

-- Legile P.U.C.A. scrise deja (25.09.2026). Se pun doar dacă lista e goală.
insert into laws(law_text, adopted_on)
select t, date '2026-09-25'
  from unnest(array[
    'Nu stropii membrii (Chiri).',
    'Nu vapa din marker (Chiri).',
    '3 abateri → cetățean.',
    'Nu ne batem pe poziții.'
  ]) with ordinality as x(t, n)
 where not exists (select 1 from laws)
 order by n;

select id, law_text, adopted_on from laws where not removed order by adopted_on, id;
