-- Xapi : commandes par virement, avec page d'administration protégée par mot de passe.
-- À coller une seule fois dans Supabase > SQL Editor d'un projet dédié à Xapi.
-- AVANT de lancer : remplacez REMPLACER_PAR_VOTRE_MOT_DE_PASSE (tout en bas) par un mot de passe long.
-- Ne gardez pas ce mot de passe dans le dépôt GitHub.

create extension if not exists pgcrypto with schema extensions;

-- ---------- Commandes ----------
create table if not exists public.orders (
  id            bigint generated always as identity (start with 1) primary key,
  created_at    timestamptz not null default now(),
  customer_name text not null check (char_length(customer_name) between 2 and 80),
  contact       text not null check (char_length(contact) between 3 and 120),
  pickup        text not null check (char_length(pickup) between 3 and 120),
  note          text check (note is null or char_length(note) <= 300),
  items         jsonb not null,
  total         numeric(8,2) not null check (total > 0),
  communication text,
  status        text not null default 'attente' check (status in ('attente','paye','retire','annule')),
  paid_at       timestamptz,
  picked_at     timestamptz
);
alter table public.orders add column if not exists email text;
alter table public.orders add column if not exists reminded_at timestamptz;
alter table public.orders add column if not exists staff_alerted_at timestamptz;
alter table public.orders enable row level security;
revoke all on public.orders from anon, authenticated;
-- Aucune politique RLS : personne ne lit ni n'écrit directement, tout passe par les fonctions ci-dessous.

create table if not exists public.admin_secret (
  id   int primary key default 1 check (id = 1),
  hash text not null
);
alter table public.admin_secret enable row level security;
revoke all on public.admin_secret from anon, authenticated;

create table if not exists public.admin_attempts (at timestamptz not null default now());
alter table public.admin_attempts enable row level security;
revoke all on public.admin_attempts from anon, authenticated;

-- ---------- Communication structurée belge +++AAA/BBBB/CCCDD+++ ----------
create or replace function public.ogm(n bigint) returns text
language plpgsql immutable set search_path = public as $$
declare d text := lpad(n::text, 10, '0'); r int := (n % 97);
begin
  if r = 0 then r := 97; end if;
  return '+++' || substr(d,1,3) || '/' || substr(d,4,4) || '/' || substr(d,8,3) || lpad(r::text,2,'0') || '+++';
end $$;
revoke execute on function public.ogm(bigint) from public, anon, authenticated;

-- ---------- Création d'une commande (appelée par le site, prix vérifiés ici) ----------
create or replace function public.create_order(p_name text, p_contact text, p_pickup text, p_note text, p_items jsonb)
returns table(id bigint, communication text, total numeric)
language plpgsql security definer set search_path = public, extensions as $$
declare
  it jsonb; clean jsonb := '[]'::jsonb; unit numeric; q int; sum numeric := 0; pots int := 0; new_id bigint; comm text;
begin
  if p_name is null or char_length(trim(p_name)) < 2 or char_length(p_name) > 80 then raise exception 'nom invalide'; end if;
  if p_contact is null or char_length(trim(p_contact)) < 3 or char_length(p_contact) > 120 then raise exception 'contact invalide'; end if;
  if p_pickup is null or char_length(trim(p_pickup)) < 3 or char_length(p_pickup) > 120 then raise exception 'retrait invalide'; end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) not between 1 and 20 then raise exception 'panier invalide'; end if;
  for it in select * from jsonb_array_elements(p_items) loop
    if not public.honey_ok(it->>'honey', false) or coalesce(it->>'texture','') not in ('classique','cremeux') or coalesce(it->>'size','') !~ '^[0-9]{1,4}(,[0-9]{1,2})? ?(g|kg)$' then
      raise exception 'article invalide';
    end if;
    q := (it->>'qty')::int;
    if q is null or q < 1 or q > 30 then raise exception 'quantité invalide'; end if;
    unit := case (it->>'texture') || '|' || (it->>'size')
      when 'classique|250 g' then 6 when 'classique|500 g' then 10
      when 'cremeux|250 g' then 7  when 'cremeux|500 g' then 11 end;
    sum := sum + unit * q; pots := pots + q;
    clean := clean || jsonb_build_array(jsonb_build_object('honey',it->>'honey','texture',it->>'texture','size',it->>'size','qty',q,'unit',unit));
  end loop;
  if pots > 60 then raise exception 'panier trop grand'; end if;
  insert into public.orders(customer_name, contact, pickup, note, items, total)
    values (trim(p_name), trim(p_contact), trim(p_pickup), nullif(left(trim(coalesce(p_note,'')),300),''), clean, sum)
    returning orders.id into new_id;
  comm := public.ogm(new_id);
  update public.orders set communication = comm where orders.id = new_id;
  return query select new_id, comm, sum;
end $$;
revoke execute on function public.create_order(text,text,text,text,jsonb) from public;
grant execute on function public.create_order(text,text,text,text,jsonb) to anon, authenticated;

-- ---------- Administration (mot de passe vérifié à chaque appel, 5 essais ratés = blocage 10 minutes) ----------
create or replace function public.admin_check(p text) returns text
language plpgsql security definer set search_path = public, extensions as $$
begin
  delete from public.admin_attempts where at < now() - interval '1 day';
  if (select count(*) from public.admin_attempts where at > now() - interval '10 minutes') >= 5 then return 'verrouille'; end if;
  if p is not null and exists (select 1 from public.admin_secret s where s.hash = extensions.crypt(p, s.hash)) then return 'ok'; end if;
  insert into public.admin_attempts default values;
  return 'mot_de_passe';
end $$;
revoke execute on function public.admin_check(text) from public, anon, authenticated;

create or replace function public.admin_orders(p text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare r text := public.admin_check(p);
begin
  if r <> 'ok' then return jsonb_build_object('error', r); end if;
  return jsonb_build_object('orders', coalesce((select jsonb_agg(to_jsonb(o) order by o.id desc) from public.orders o), '[]'::jsonb));
end $$;
revoke execute on function public.admin_orders(text) from public;
grant execute on function public.admin_orders(text) to anon, authenticated;

create or replace function public.admin_set_status(p text, p_id bigint, p_status text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare r text := public.admin_check(p);
begin
  if r <> 'ok' then return jsonb_build_object('error', r); end if;
  if p_status not in ('attente','paye','retire','annule') then return jsonb_build_object('error','statut'); end if;
  update public.orders set
    status = p_status,
    paid_at   = case p_status when 'attente' then null when 'annule' then paid_at else coalesce(paid_at, now()) end,
    picked_at = case p_status when 'retire' then now() else null end
  where id = p_id;
  return jsonb_build_object('ok', true);
end $$;
revoke execute on function public.admin_set_status(text,bigint,text) from public;
grant execute on function public.admin_set_status(text,bigint,text) to anon, authenticated;

-- ---------- Mot de passe de la page admin (à changer ici avant de lancer le script) ----------
insert into public.admin_secret (id, hash)
values (1, extensions.crypt('REMPLACER_PAR_VOTRE_MOT_DE_PASSE', extensions.gen_salt('bf')))
on conflict (id) do nothing;
-- Pour le changer plus tard :
-- update public.admin_secret set hash = extensions.crypt('NOUVEAU_MOT_DE_PASSE', extensions.gen_salt('bf')) where id = 1;

-- ---------- Alerte e-mail automatique à Xavier à chaque nouvelle commande (via Brevo) ----------
-- 1) Brevo : créez une clé API (SMTP & API > Clés API) et vérifiez l'adresse expéditeur (Senders).
-- 2) Remplacez les trois valeurs ci-dessous, puis lancez. La clé reste dans la base, jamais dans le site.
create extension if not exists pg_net with schema extensions;

create table if not exists public.notify_config (
  id int primary key default 1 check (id = 1),
  brevo_key text not null, sender_email text not null, to_email text not null
);
alter table public.notify_config enable row level security;
revoke all on public.notify_config from anon, authenticated;

insert into public.notify_config (id, brevo_key, sender_email, to_email)
values (1, 'REMPLACER_PAR_CLE_API_BREVO', 'REMPLACER_PAR_EXPEDITEUR_VERIFIE', 'efats@pm.me')
on conflict (id) do nothing; -- adresse de test ; à changer plus tard dans la page admin > Réglages

create or replace function public.notify_new_order() returns trigger
language plpgsql security definer set search_path = public, extensions as $$
declare c record; lines text; h text;
begin
  select * into c from public.notify_config where id = 1;
  if not found or c.brevo_key like 'REMPLACER%' then return new; end if;
  select string_agg(format('%s × Miel %s %s %s', i->>'qty', case i->>'honey' when 'ete' then 'd''été' else 'de printemps' end, case i->>'texture' when 'cremeux' then 'crémeux' else 'classique' end, i->>'size'), E'\n')
    into lines from jsonb_array_elements(new.items) i;
  h := format(E'Commande n° %s\n\n%s\n\nTotal : %s €\nRetrait : %s\nClient : %s\nContact : %s\nMessage : %s\nCommunication : %s\n\nÀ marquer « payé » dans la page admin dès réception du virement.',
        new.id, lines, new.total, new.pickup, new.customer_name, new.contact, coalesce(new.note,'-'), new.communication);
  h := replace(replace(replace(h,'&','&amp;'),'<','&lt;'),'>','&gt;');
  h := replace(h, E'\n', '<br>');
  begin
    perform net.http_post(
      url := 'https://api.brevo.com/v3/smtp/email',
      headers := jsonb_build_object('api-key', c.brevo_key, 'content-type', 'application/json', 'accept', 'application/json'),
      body := jsonb_build_object(
        'sender', jsonb_build_object('name','Site Xapi','email',c.sender_email),
        'to', jsonb_build_array(jsonb_build_object('email',c.to_email)),
        'subject', 'Nouvelle commande n° '||lpad(new.id::text,4,'0')||' ('||new.total||' €)',
        'htmlContent', '<p>'||h||'</p>'));
  exception when others then null; -- une alerte ratée ne doit jamais bloquer la commande
  end;
  return new;
end $$;
revoke execute on function public.notify_new_order() from public, anon, authenticated;

drop trigger if exists trg_notify_new_order on public.orders;
create trigger trg_notify_new_order after update of communication on public.orders
  for each row when (old.communication is null and new.communication is not null)
  execute function public.notify_new_order();
-- (le déclencheur part quand la communication est posée, donc avec la commande complète)

-- ---------- Ajouts admin : modifier, supprimer (annulées), e-mail d'alerte, mot de passe ----------
-- admin_orders renvoie aussi l'e-mail d'alerte actuel.
create or replace function public.admin_orders(p text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare r text := public.admin_check(p);
begin
  if r <> 'ok' then return jsonb_build_object('error', r); end if;
  return jsonb_build_object(
    'orders', coalesce((select jsonb_agg(to_jsonb(o) order by o.id desc) from public.orders o), '[]'::jsonb),
    'admin_email', (select to_email from public.notify_config where id = 1));
end $$;
revoke execute on function public.admin_orders(text) from public;
grant execute on function public.admin_orders(text) to anon, authenticated;

create or replace function public.admin_update_order(p text, p_id bigint, p_name text, p_contact text, p_pickup text, p_note text, p_items jsonb) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare r text := public.admin_check(p); it jsonb; q int; unit numeric; sum numeric := 0; clean jsonb := '[]'::jsonb;
begin
  if r <> 'ok' then return jsonb_build_object('error', r); end if;
  if p_name is null or char_length(trim(p_name)) not between 2 and 80 then return jsonb_build_object('error','nom'); end if;
  if p_contact is null or char_length(trim(p_contact)) not between 3 and 120 then return jsonb_build_object('error','contact'); end if;
  if p_pickup is null or char_length(trim(p_pickup)) not between 3 and 120 then return jsonb_build_object('error','retrait'); end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) not between 1 and 20 then return jsonb_build_object('error','articles'); end if;
  for it in select * from jsonb_array_elements(p_items) loop
    if not public.honey_ok(it->>'honey', false) or coalesce(it->>'texture','') not in ('classique','cremeux') or coalesce(it->>'size','') !~ '^[0-9]{1,4}(,[0-9]{1,2})? ?(g|kg)$' then
      return jsonb_build_object('error','articles'); end if;
    q := (it->>'qty')::int;
    if q is null or q < 1 or q > 30 then return jsonb_build_object('error','articles'); end if;
    unit := case (it->>'texture') || '|' || (it->>'size')
      when 'classique|250 g' then 6 when 'classique|500 g' then 10
      when 'cremeux|250 g' then 7  when 'cremeux|500 g' then 11 end;
    sum := sum + unit * q;
    clean := clean || jsonb_build_array(jsonb_build_object('honey',it->>'honey','texture',it->>'texture','size',it->>'size','qty',q,'unit',unit));
  end loop;
  update public.orders set customer_name = trim(p_name), contact = trim(p_contact), pickup = trim(p_pickup),
    note = nullif(left(trim(coalesce(p_note,'')),300),''), items = clean, total = sum where id = p_id;
  if not found then return jsonb_build_object('error','introuvable'); end if;
  return jsonb_build_object('ok', true);
end $$;
revoke execute on function public.admin_update_order(text,bigint,text,text,text,text,jsonb) from public;
grant execute on function public.admin_update_order(text,bigint,text,text,text,text,jsonb) to anon, authenticated;

create or replace function public.admin_delete_order(p text, p_id bigint) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare r text := public.admin_check(p);
begin
  if r <> 'ok' then return jsonb_build_object('error', r); end if;
  delete from public.orders where id = p_id and status = 'annule';
  if not found then return jsonb_build_object('error','non_annulee'); end if;
  return jsonb_build_object('ok', true);
end $$;
revoke execute on function public.admin_delete_order(text,bigint) from public;
grant execute on function public.admin_delete_order(text,bigint) to anon, authenticated;

create or replace function public.admin_set_email(p text, p_email text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare r text := public.admin_check(p);
begin
  if r <> 'ok' then return jsonb_build_object('error', r); end if;
  if p_email is null or p_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' or char_length(p_email) > 120 then return jsonb_build_object('error','email'); end if;
  update public.notify_config set to_email = lower(trim(p_email)) where id = 1;
  return jsonb_build_object('ok', true);
end $$;
revoke execute on function public.admin_set_email(text,text) from public;
grant execute on function public.admin_set_email(text,text) to anon, authenticated;

create or replace function public.admin_change_password(p text, p_new text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare r text := public.admin_check(p);
begin
  if r <> 'ok' then return jsonb_build_object('error', r); end if;
  if p_new is null or char_length(p_new) < 10 then return jsonb_build_object('error','trop_court'); end if;
  update public.admin_secret set hash = extensions.crypt(p_new, extensions.gen_salt('bf')) where id = 1;
  return jsonb_build_object('ok', true);
end $$;
revoke execute on function public.admin_change_password(text,text) from public;
grant execute on function public.admin_change_password(text,text) to anon, authenticated;

-- =====================================================================================
-- V2 : e-mail client, stock, rappels automatiques (remplace les définitions précédentes)
-- =====================================================================================

-- ---------- Dernière connexion à la page admin ----------
alter table public.admin_secret add column if not exists last_seen timestamptz;
create or replace function public.admin_check(p text) returns text
language plpgsql security definer set search_path = public, extensions as $$
begin
  delete from public.admin_attempts where at < now() - interval '1 day';
  if (select count(*) from public.admin_attempts where at > now() - interval '10 minutes') >= 5 then return 'verrouille'; end if;
  if p is not null and exists (select 1 from public.admin_secret s where s.hash = extensions.crypt(p, s.hash)) then
    update public.admin_secret set last_seen = now() where id = 1 and (last_seen is null or last_seen < now() - interval '5 minutes');
    return 'ok';
  end if;
  insert into public.admin_attempts default values;
  return 'mot_de_passe';
end $$;
revoke execute on function public.admin_check(text) from public, anon, authenticated;

-- ---------- Petits outils ----------
create or replace function public.h(t text) returns text language sql immutable as
$$ select replace(replace(replace(replace(coalesce(t,''),'&','&amp;'),'<','&lt;'),'>','&gt;'),'"','&quot;') $$;
revoke execute on function public.h(text) from public, anon, authenticated;

-- Envoi d'e-mail via Brevo (ne bloque jamais l'appelant)
create or replace function public.send_mail(p_to text, p_subject text, p_html text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare c record;
begin
  select * into c from public.notify_config where id = 1;
  if not found or c.brevo_key like 'REMPLACER%' or c.sender_email like 'REMPLACER%' or p_to is null then return; end if;
  begin
    perform net.http_post(
      url := 'https://api.brevo.com/v3/smtp/email',
      headers := jsonb_build_object('api-key', c.brevo_key, 'content-type', 'application/json', 'accept', 'application/json'),
      body := jsonb_build_object(
        'sender', jsonb_build_object('name','Xapi, miel de Dion-le-Mont','email',c.sender_email),
        'replyTo', jsonb_build_object('email', c.to_email),
        'to', jsonb_build_array(jsonb_build_object('email',p_to)),
        'subject', p_subject, 'htmlContent', p_html));
  exception when others then null;
  end;
end $$;
revoke execute on function public.send_mail(text,text,text) from public, anon, authenticated;

-- ---------- Stock (vide = disponible, 0 = épuisé, ou nombre exact de pots) ----------
create table if not exists public.stock (
  honey text not null check (honey in ('printemps','ete')),
  texture text not null check (texture in ('classique','cremeux')),
  size text not null check (size in ('250 g','500 g')),
  qty int check (qty is null or qty >= 0),
  primary key (honey, texture, size)
);
-- Trois états par référence : disponible (qty vide, on ne dit rien), épuisé (0), ou nombre exact de pots.
alter table public.stock alter column qty drop not null;
alter table public.stock alter column qty drop default;
alter table public.stock enable row level security;
revoke all on public.stock from anon, authenticated;
insert into public.stock (honey, texture, size)
select h, t, z from (values ('printemps'),('ete')) a(h), (values ('classique'),('cremeux')) b(t), (values ('250 g'),('500 g')) c(z)
on conflict do nothing;

-- sign = -1 : retirer du stock (échoue si insuffisant), +1 : remettre
create or replace function public.stock_move(items jsonb, sign int) returns void
language plpgsql security definer set search_path = public as $$
declare it jsonb; q int;
begin
  for it in select * from jsonb_array_elements(items) loop
    q := (it->>'qty')::int;
    if sign < 0 then
      update public.stock set qty = case when qty is null then null else qty - q end
        where honey = it->>'honey' and texture = it->>'texture' and size = it->>'size' and (qty is null or qty >= q);
      if not found then raise exception 'stock'; end if;
    else
      update public.stock set qty = qty + q
        where honey = it->>'honey' and texture = it->>'texture' and size = it->>'size' and qty is not null;
    end if;
  end loop;
end $$;
revoke execute on function public.stock_move(jsonb,int) from public, anon, authenticated;

create or replace function public.get_stock() returns jsonb
language sql security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('honey',honey,'texture',texture,'size',size,'qty',qty)), '[]'::jsonb) from public.stock where qty is not null
$$;
revoke execute on function public.get_stock() from public;
grant execute on function public.get_stock() to anon, authenticated;

create or replace function public.admin_set_stock(p text, p_stock jsonb) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare r text := public.admin_check(p); s jsonb; v int;
begin
  if r <> 'ok' then return jsonb_build_object('error', r); end if;
  if jsonb_typeof(p_stock) <> 'array' then return jsonb_build_object('error','stock_invalide'); end if;
  for s in select * from jsonb_array_elements(p_stock) loop
    v := case when s->>'qty' is null or s->>'qty' = '' then null else (s->>'qty')::int end;
    if v is not null and (v < 0 or v > 9999) then return jsonb_build_object('error','stock_invalide'); end if;
    update public.stock set qty = v where honey = s->>'honey' and texture = s->>'texture' and size = s->>'size';
  end loop;
  return jsonb_build_object('ok', true);
end $$;
revoke execute on function public.admin_set_stock(text,jsonb) from public;
grant execute on function public.admin_set_stock(text,jsonb) to anon, authenticated;

-- ---------- Création de commande (avec e-mail facultatif et stock) ----------
drop function if exists public.create_order(text,text,text,text,jsonb);
create or replace function public.create_order(p_name text, p_contact text, p_pickup text, p_note text, p_items jsonb, p_email text default null)
returns table(id bigint, communication text, total numeric)
language plpgsql security definer set search_path = public, extensions as $$
declare
  it jsonb; clean jsonb := '[]'::jsonb; unit numeric; q int; sum numeric := 0; pots int := 0; new_id bigint; comm text; em text;
begin
  if p_name is null or char_length(trim(p_name)) < 2 or char_length(p_name) > 80 then raise exception 'nom invalide'; end if;
  if p_contact is null or char_length(trim(p_contact)) < 3 or char_length(p_contact) > 120 then raise exception 'contact invalide'; end if;
  if p_pickup is null or char_length(trim(p_pickup)) < 3 or char_length(p_pickup) > 120 then raise exception 'retrait invalide'; end if;
  em := nullif(lower(trim(coalesce(p_email,''))),'');
  if em is null or em !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' or char_length(em) > 120 then raise exception 'email invalide'; end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) not between 1 and 20 then raise exception 'panier invalide'; end if;
  for it in select * from jsonb_array_elements(p_items) loop
    if not public.honey_ok(it->>'honey', false) or coalesce(it->>'texture','') not in ('classique','cremeux') or coalesce(it->>'size','') !~ '^[0-9]{1,4}(,[0-9]{1,2})? ?(g|kg)$' then
      raise exception 'article invalide';
    end if;
    q := (it->>'qty')::int;
    if q is null or q < 1 or q > 30 then raise exception 'quantité invalide'; end if;
    unit := case (it->>'texture') || '|' || (it->>'size')
      when 'classique|250 g' then 6 when 'classique|500 g' then 10
      when 'cremeux|250 g' then 7  when 'cremeux|500 g' then 11 end;
    sum := sum + unit * q; pots := pots + q;
    clean := clean || jsonb_build_array(jsonb_build_object('honey',it->>'honey','texture',it->>'texture','size',it->>'size','qty',q,'unit',unit));
  end loop;
  if pots > 60 then raise exception 'panier trop grand'; end if;
  perform public.stock_move(clean, -1);
  insert into public.orders(customer_name, contact, email, pickup, note, items, total)
    values (trim(p_name), trim(p_contact), em, trim(p_pickup), nullif(left(trim(coalesce(p_note,'')),300),''), clean, sum)
    returning orders.id into new_id;
  comm := public.ogm(new_id);
  update public.orders set communication = comm where orders.id = new_id;
  return query select new_id, comm, sum;
end $$;
revoke execute on function public.create_order(text,text,text,text,jsonb,text) from public;
grant execute on function public.create_order(text,text,text,text,jsonb,text) to anon, authenticated;

-- ---------- Statut et modification avec gestion du stock ----------
create or replace function public.admin_set_status(p text, p_id bigint, p_status text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare r text := public.admin_check(p); o public.orders;
begin
  if r <> 'ok' then return jsonb_build_object('error', r); end if;
  if p_status not in ('attente','paye','retire','annule') then return jsonb_build_object('error','statut'); end if;
  select * into o from public.orders where id = p_id for update;
  if not found then return jsonb_build_object('error','introuvable'); end if;
  begin
    if o.status <> 'annule' and p_status = 'annule' then perform public.stock_move(o.items, 1); end if;
    if o.status = 'annule' and p_status <> 'annule' then perform public.stock_move(o.items, -1); end if;
  exception when others then return jsonb_build_object('error','stock');
  end;
  update public.orders set
    status = p_status,
    paid_at   = case p_status when 'attente' then null when 'annule' then paid_at else coalesce(paid_at, now()) end,
    picked_at = case p_status when 'retire' then now() else null end
  where id = p_id;
  return jsonb_build_object('ok', true);
end $$;
revoke execute on function public.admin_set_status(text,bigint,text) from public;
grant execute on function public.admin_set_status(text,bigint,text) to anon, authenticated;

create or replace function public.admin_update_order(p text, p_id bigint, p_name text, p_contact text, p_pickup text, p_note text, p_items jsonb, p_email text default null) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare r text := public.admin_check(p); it jsonb; q int; unit numeric; sum numeric := 0; clean jsonb := '[]'::jsonb; o public.orders; em text;
begin
  if r <> 'ok' then return jsonb_build_object('error', r); end if;
  if p_name is null or char_length(trim(p_name)) not between 2 and 80 then return jsonb_build_object('error','nom'); end if;
  if p_contact is null or char_length(trim(p_contact)) not between 3 and 120 then return jsonb_build_object('error','contact'); end if;
  if p_pickup is null or char_length(trim(p_pickup)) not between 3 and 120 then return jsonb_build_object('error','retrait'); end if;
  em := nullif(lower(trim(coalesce(p_email,''))),'');
  if em is null or em !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' or char_length(em) > 120 then return jsonb_build_object('error','email'); end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) not between 1 and 20 then return jsonb_build_object('error','articles'); end if;
  for it in select * from jsonb_array_elements(p_items) loop
    if not public.honey_ok(it->>'honey', false) or coalesce(it->>'texture','') not in ('classique','cremeux') or coalesce(it->>'size','') !~ '^[0-9]{1,4}(,[0-9]{1,2})? ?(g|kg)$' then
      return jsonb_build_object('error','articles'); end if;
    q := (it->>'qty')::int;
    if q is null or q < 1 or q > 30 then return jsonb_build_object('error','articles'); end if;
    unit := case (it->>'texture') || '|' || (it->>'size')
      when 'classique|250 g' then 6 when 'classique|500 g' then 10
      when 'cremeux|250 g' then 7  when 'cremeux|500 g' then 11 end;
    sum := sum + unit * q;
    clean := clean || jsonb_build_array(jsonb_build_object('honey',it->>'honey','texture',it->>'texture','size',it->>'size','qty',q,'unit',unit));
  end loop;
  select * into o from public.orders where id = p_id for update;
  if not found then return jsonb_build_object('error','introuvable'); end if;
  begin
    if o.status <> 'annule' then perform public.stock_move(o.items, 1); perform public.stock_move(clean, -1); end if;
  exception when others then return jsonb_build_object('error','stock');
  end;
  update public.orders set customer_name = trim(p_name), contact = trim(p_contact), email = em, pickup = trim(p_pickup),
    note = nullif(left(trim(coalesce(p_note,'')),300),''), items = clean, total = sum where id = p_id;
  return jsonb_build_object('ok', true);
end $$;
drop function if exists public.admin_update_order(text,bigint,text,text,text,text,jsonb);
revoke execute on function public.admin_update_order(text,bigint,text,text,text,text,jsonb,text) from public;
grant execute on function public.admin_update_order(text,bigint,text,text,text,text,jsonb,text) to anon, authenticated;

create or replace function public.admin_orders(p text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare r text := public.admin_check(p);
begin
  if r <> 'ok' then return jsonb_build_object('error', r); end if;
  return jsonb_build_object(
    'orders', coalesce((select jsonb_agg(to_jsonb(o) order by o.id desc) from public.orders o), '[]'::jsonb),
    'admin_email', (select to_email from public.notify_config where id = 1),
    'stock', (select jsonb_agg(jsonb_build_object('honey',honey,'texture',texture,'size',size,'qty',qty) order by honey desc, texture, size) from public.stock));
end $$;
revoke execute on function public.admin_orders(text) from public;
grant execute on function public.admin_orders(text) to anon, authenticated;

-- ---------- E-mails : alerte à Xavier + confirmation au client ----------
create or replace function public.notify_new_order() returns trigger
language plpgsql security definer set search_path = public, extensions as $$
declare c record; lines text; lines_h text; to_x text;
begin
  select * into c from public.notify_config where id = 1;
  if not found then return new; end if;
  select string_agg(format('%s × %s %s %s', i->>'qty', public.h(coalesce((select pr.name from public.products pr where pr.id = i->>'honey'), i->>'honey')), case i->>'texture' when 'cremeux' then 'crémeux' else 'classique' end, i->>'size'), '<br>')
    into lines from jsonb_array_elements(new.items) i;
  perform public.send_mail(c.to_email, 'Nouvelle commande n° '||lpad(new.id::text,4,'0')||' ('||new.total||' €)',
    '<p>Commande n° '||lpad(new.id::text,4,'0')||'<br><br>'||lines||'<br><br>Total : '||new.total||' €<br>Retrait : '||public.h(new.pickup)||
    '<br>Client : '||public.h(new.customer_name)||'<br>Contact : '||public.h(new.contact)||'<br>E-mail : '||public.h(coalesce(new.email,'-'))||
    '<br>Message : '||public.h(coalesce(new.note,'-'))||'<br>Communication : '||new.communication||
    '<br><br>À marquer « payé » dans la page admin dès réception du virement.</p>');
  if new.email is not null then
    perform public.send_mail(new.email, 'Votre commande de miel Xapi n° '||new.id,
      '<p>Bonjour '||public.h(new.customer_name)||',</p><p><b>Votre pot est presque chez vous !</b></p><p>Merci pour votre commande n° '||lpad(new.id::text,4,'0')||' :</p><p>'||lines||'</p>'||
      '<p><b>Total : '||new.total||' €</b><br>Retrait : '||public.h(new.pickup)||'</p>'||
      '<p>Pour la confirmer, merci de payer par virement, de préférence instantané :<br>'||public.bank_html()||'Montant : '||new.total||' €<br>Communication : <b>'||new.communication||'</b></p>'||
      '<p>Xavier prépare vos pots dès qu''il a reçu le paiement, et vous écrit pour convenir du retrait. Pour toute question, répondez simplement à ce message.</p><p>Xapi, miel de Dion-le-Mont</p>');
  end if;
  return new;
end $$;
revoke execute on function public.notify_new_order() from public, anon, authenticated;

-- ---------- Rappels automatiques (tous les jours vers 8 h) ----------
-- Client : un seul rappel, 3 jours après la commande, s'il a donné son e-mail et n'a pas payé.
-- Xavier : un mail de relance (une fois par commande) pour les commandes impayées depuis plus de 48 h.
create or replace function public.send_reminders() returns void
language plpgsql security definer set search_path = public, extensions as $$
declare o record; late text; n int; xa text;
begin
  -- Rappels clients seulement si Xavier s'est connecté à la page admin ces 48 dernières heures
  -- (sinon un client qui a payé risquerait d'être relancé alors que la commande n'est pas encore marquée « payée »).
  for o in select * from public.orders where status = 'attente' and email is not null and reminded_at is null and created_at < now() - interval '3 days'
           and exists (select 1 from public.admin_secret where last_seen > now() - interval '48 hours') loop
    perform public.send_mail(o.email, 'Rappel : commande de miel Xapi n° '||o.id,
      '<p>Bonjour '||public.h(o.customer_name)||',</p><p>Nous n''avons pas encore reçu le paiement de votre commande n° '||lpad(o.id::text,4,'0')||' ('||o.total||' €).</p>'||
      '<p>'||public.bank_html()||'Montant : '||o.total||' €<br>Communication : <b>'||o.communication||'</b></p>'||
      '<p>Si vous avez déjà payé, merci d''ignorer ce message. Sinon, répondez-nous si vous souhaitez annuler ou modifier la commande.</p><p>Xapi, miel de Dion-le-Mont</p>');
    update public.orders set reminded_at = now() where id = o.id;
  end loop;
  -- Relance à Xavier (une seule fois par commande) : commandes en attente de paiement depuis plus de 48 h.
  select count(*), string_agg('n° '||lpad(id::text,4,'0')||' · '||public.h(customer_name)||' · '||total||' €', '<br>' order by id) into n, late
    from public.orders where status = 'attente' and staff_alerted_at is null and created_at < now() - interval '48 hours';
  if n > 0 then
    select to_email into xa from public.notify_config where id = 1;
    perform public.send_mail(xa, n||' commande(s) en attente de paiement depuis plus de 48 h', '<p>'||late||'</p><p>Vérifiez votre compte : si le virement est arrivé, marquez la commande « payée » dans la page admin ; sinon relancez le client ou annulez la commande.</p>');
    update public.orders set staff_alerted_at = now() where status = 'attente' and staff_alerted_at is null and created_at < now() - interval '48 hours';
  end if;
end $$;
revoke execute on function public.send_reminders() from public, anon, authenticated;

do $$ begin
  create extension if not exists pg_cron with schema pg_catalog;
  perform cron.schedule('xapi-rappels', '0 7 * * *', 'select public.send_reminders()');
exception when others then
  raise notice 'pg_cron non activé : activez-le dans Database > Extensions puis relancez ce bloc.';
end $$;

-- =====================================================================================
-- V3 : prix et lieux de retrait modifiables depuis la page admin
-- =====================================================================================
create table if not exists public.prices (
  texture text not null check (texture in ('classique','cremeux')),
  size text not null check (size in ('250 g','500 g')),
  price numeric(8,2) not null check (price > 0 and price <= 500),
  primary key (texture, size)
);
alter table public.prices enable row level security;
revoke all on public.prices from anon, authenticated;
insert into public.prices values ('classique','250 g',6),('classique','500 g',10),('cremeux','250 g',7),('cremeux','500 g',11) on conflict do nothing;

create table if not exists public.places (
  id int generated always as identity primary key,
  name text not null check (char_length(name) between 3 and 120),
  active boolean not null default true,
  sort int not null default 0
);
alter table public.places enable row level security;
revoke all on public.places from anon, authenticated;
insert into public.places (name, sort)
select * from (values ('Dion-le-Mont, sur rendez-vous',1),('Mini-Marché de La Chaumière, Chaumont-Gistoux (jeudi)',2)) v(name,sort)
where not exists (select 1 from public.places);

create or replace function public.get_config() returns jsonb
language sql security definer set search_path = public as $$
  select jsonb_build_object(
    'prices', (select jsonb_agg(jsonb_build_object('texture',texture,'size',size,'price',price)) from public.prices),
    'places', coalesce((select jsonb_agg(jsonb_build_object('id',id,'name',name) order by sort, id) from public.places where active), '[]'::jsonb))
$$;
revoke execute on function public.get_config() from public;
grant execute on function public.get_config() to anon, authenticated;

create or replace function public.admin_set_prices(p text, p_prices jsonb) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare r text := public.admin_check(p); x jsonb; v numeric;
begin
  if r <> 'ok' then return jsonb_build_object('error', r); end if;
  if jsonb_typeof(p_prices) <> 'array' then return jsonb_build_object('error','prix_invalide'); end if;
  for x in select * from jsonb_array_elements(p_prices) loop
    v := (x->>'price')::numeric;
    if v is null or v <= 0 or v > 500 then return jsonb_build_object('error','prix_invalide'); end if;
    update public.prices set price = round(v,2) where texture = x->>'texture' and size = x->>'size';
  end loop;
  return jsonb_build_object('ok', true);
end $$;
revoke execute on function public.admin_set_prices(text,jsonb) from public;
grant execute on function public.admin_set_prices(text,jsonb) to anon, authenticated;

-- p_places : [{id?, name, active}] ; sans id = nouveau lieu ; l'ordre du tableau = l'ordre d'affichage
create or replace function public.admin_set_places(p text, p_places jsonb) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare r text := public.admin_check(p); x jsonb; i int := 0; nm text;
begin
  if r <> 'ok' then return jsonb_build_object('error', r); end if;
  if jsonb_typeof(p_places) <> 'array' or jsonb_array_length(p_places) > 20 then return jsonb_build_object('error','lieu_invalide'); end if;
  for x in select * from jsonb_array_elements(p_places) loop
    i := i + 1; nm := trim(coalesce(x->>'name',''));
    if char_length(nm) not between 3 and 120 then return jsonb_build_object('error','lieu_invalide'); end if;
    if x->>'id' is null or x->>'id' = '' then
      insert into public.places(name, active, sort) values (nm, coalesce((x->>'active')::boolean, true), i);
    else
      update public.places set name = nm, active = coalesce((x->>'active')::boolean, true), sort = i where id = (x->>'id')::int;
    end if;
  end loop;
  if not exists (select 1 from public.places where active) then raise exception 'au moins un lieu actif'; end if;
  return jsonb_build_object('ok', true);
exception when others then return jsonb_build_object('error','lieu_invalide');
end $$;
revoke execute on function public.admin_set_places(text,jsonb) from public;
grant execute on function public.admin_set_places(text,jsonb) to anon, authenticated;

-- Création de commande : prix et lieux lus dans les tables
create or replace function public.create_order(p_name text, p_contact text, p_pickup text, p_note text, p_items jsonb, p_email text default null)
returns table(id bigint, communication text, total numeric)
language plpgsql security definer set search_path = public, extensions as $$
declare
  it jsonb; clean jsonb := '[]'::jsonb; unit numeric; q int; sum numeric := 0; pots int := 0; new_id bigint; comm text; em text;
begin
  if coalesce((select sc.paused from public.shop_config sc where sc.id = 1), false) then raise exception 'pause'; end if;
  if p_name is null or char_length(trim(p_name)) < 2 or char_length(p_name) > 80 then raise exception 'nom invalide'; end if;
  if p_contact is null or char_length(trim(p_contact)) < 3 or char_length(p_contact) > 120 then raise exception 'contact invalide'; end if;
  if p_pickup is null or not exists (select 1 from public.places pl where pl.active and pl.name = trim(p_pickup)) then raise exception 'retrait invalide'; end if;
  em := nullif(lower(trim(coalesce(p_email,''))),'');
  if em is null or em !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' or char_length(em) > 120 then raise exception 'email invalide'; end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) not between 1 and 20 then raise exception 'panier invalide'; end if;
  for it in select * from jsonb_array_elements(p_items) loop
    if not public.honey_ok(it->>'honey', true) or coalesce(it->>'texture','') not in ('classique','cremeux') or coalesce(it->>'size','') !~ '^[0-9]{1,4}(,[0-9]{1,2})? ?(g|kg)$' then
      raise exception 'article invalide';
    end if;
    q := (it->>'qty')::int;
    if q is null or q < 1 or q > 30 then raise exception 'quantité invalide'; end if;
    select (pp.prices->>((it->>'texture')||'|'||(it->>'size')))::numeric into unit from public.products pp where pp.id = it->>'honey';
    if unit is null then raise exception 'prix inconnu'; end if;
    sum := sum + unit * q; pots := pots + q;
    clean := clean || jsonb_build_array(jsonb_build_object('honey',it->>'honey','texture',it->>'texture','size',it->>'size','qty',q,'unit',unit));
  end loop;
  if pots > 60 then raise exception 'panier trop grand'; end if;
  perform public.stock_move(clean, -1);
  insert into public.orders(customer_name, contact, email, pickup, note, items, total)
    values (trim(p_name), trim(p_contact), em, trim(p_pickup), nullif(left(trim(coalesce(p_note,'')),300),''), clean, sum)
    returning orders.id into new_id;
  comm := public.ogm(new_id);
  update public.orders set communication = comm where orders.id = new_id;
  return query select new_id, comm, sum;
end $$;
revoke execute on function public.create_order(text,text,text,text,jsonb,text) from public;
grant execute on function public.create_order(text,text,text,text,jsonb,text) to anon, authenticated;

-- Modification admin : prix lus dans la table
create or replace function public.admin_update_order(p text, p_id bigint, p_name text, p_contact text, p_pickup text, p_note text, p_items jsonb, p_email text default null) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare r text := public.admin_check(p); it jsonb; q int; unit numeric; sum numeric := 0; clean jsonb := '[]'::jsonb; o public.orders; em text; old jsonb;
begin
  if r <> 'ok' then return jsonb_build_object('error', r); end if;
  if p_name is null or char_length(trim(p_name)) not between 2 and 80 then return jsonb_build_object('error','nom'); end if;
  if p_contact is null or char_length(trim(p_contact)) not between 3 and 120 then return jsonb_build_object('error','contact'); end if;
  if p_pickup is null or char_length(trim(p_pickup)) not between 3 and 120 then return jsonb_build_object('error','retrait'); end if;
  em := nullif(lower(trim(coalesce(p_email,''))),'');
  if em is null or em !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' or char_length(em) > 120 then return jsonb_build_object('error','email'); end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) not between 1 and 20 then return jsonb_build_object('error','articles'); end if;
  select * into o from public.orders where id = p_id for update;
  if not found then return jsonb_build_object('error','introuvable'); end if;
  for it in select * from jsonb_array_elements(p_items) loop
    if not public.honey_ok(it->>'honey', false) or coalesce(it->>'texture','') not in ('classique','cremeux') or coalesce(it->>'size','') !~ '^[0-9]{1,4}(,[0-9]{1,2})? ?(g|kg)$' then
      return jsonb_build_object('error','articles'); end if;
    q := (it->>'qty')::int;
    if q is null or q < 1 or q > 30 then return jsonb_build_object('error','articles'); end if;
    -- une ligne inchangée garde son prix d'origine ; une ligne nouvelle ou modifiée prend le prix actuel
    select (x->>'unit')::numeric into unit from jsonb_array_elements(o.items) x
      where x->>'honey' = it->>'honey' and x->>'texture' = it->>'texture' and x->>'size' = it->>'size' limit 1;
    if unit is null then select (pp.prices->>((it->>'texture')||'|'||(it->>'size')))::numeric into unit from public.products pp where pp.id = it->>'honey'; end if;
    if unit is null then return jsonb_build_object('error','articles'); end if;
    sum := sum + unit * q;
    clean := clean || jsonb_build_array(jsonb_build_object('honey',it->>'honey','texture',it->>'texture','size',it->>'size','qty',q,'unit',unit));
  end loop;
  begin
    if o.status <> 'annule' then perform public.stock_move(o.items, 1); perform public.stock_move(clean, -1); end if;
  exception when others then return jsonb_build_object('error','stock');
  end;
  update public.orders set customer_name = trim(p_name), contact = trim(p_contact), email = em, pickup = trim(p_pickup),
    note = nullif(left(trim(coalesce(p_note,'')),300),''), items = clean, total = sum where id = p_id;
  return jsonb_build_object('ok', true);
end $$;
revoke execute on function public.admin_update_order(text,bigint,text,text,text,text,jsonb,text) from public;
grant execute on function public.admin_update_order(text,bigint,text,text,text,text,jsonb,text) to anon, authenticated;

create or replace function public.admin_orders(p text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare r text := public.admin_check(p);
begin
  if r <> 'ok' then return jsonb_build_object('error', r); end if;
  return jsonb_build_object(
    'orders', coalesce((select jsonb_agg(to_jsonb(o) order by o.id desc) from public.orders o), '[]'::jsonb),
    'admin_email', (select to_email from public.notify_config where id = 1),
    'stock', (select jsonb_agg(jsonb_build_object('honey',honey,'texture',texture,'size',size,'qty',qty) order by honey desc, texture, size) from public.stock),
    'prices', (select jsonb_agg(jsonb_build_object('texture',texture,'size',size,'price',price)) from public.prices),
    'places', (select jsonb_agg(jsonb_build_object('id',id,'name',name,'active',active) order by sort, id) from public.places));
end $$;
revoke execute on function public.admin_orders(text) from public;
grant execute on function public.admin_orders(text) to anon, authenticated;


-- =====================================================================================
-- V4 : IBAN et titulaire modifiables depuis la page admin
-- =====================================================================================
create table if not exists public.shop_config (
  id int primary key default 1 check (id = 1),
  iban text not null,
  beneficiary text not null check (char_length(beneficiary) between 2 and 80)
);
alter table public.shop_config enable row level security;
revoke all on public.shop_config from anon, authenticated;
insert into public.shop_config (id, iban, beneficiary) values (1, 'BE45002031237489', 'Xavier Van Cauter') on conflict (id) do nothing;

-- Vérification d'un IBAN (longueur, caractères, clé modulo 97)
create or replace function public.iban_ok(p text) returns boolean
language plpgsql immutable as $$
declare s text := upper(regexp_replace(coalesce(p,''), '\s', '', 'g')); r text; rem int := 0; i int; c text; v int;
begin
  if s !~ '^[A-Z]{2}[0-9]{2}[A-Z0-9]{11,30}$' then return false; end if;
  r := substr(s,5) || substr(s,1,4);
  for i in 1..length(r) loop
    c := substr(r,i,1);
    if c ~ '[0-9]' then rem := (rem * 10 + c::int) % 97;
    else v := ascii(c) - 55; rem := (rem * 100 + v) % 97; end if;
  end loop;
  return rem = 1;
end $$;

create or replace function public.iban_fmt(p text) returns text
language sql immutable as $$ select trim(regexp_replace(upper(regexp_replace(coalesce(p,''), '\s', '', 'g')), '(.{4})', '\1 ', 'g')) $$;

create or replace function public.bank_html() returns text
language sql security definer set search_path = public as $$
  select 'Bénéficiaire : '||public.h(beneficiary)||'<br>IBAN : '||public.iban_fmt(iban)||'<br>' from public.shop_config where id = 1
$$;
revoke execute on function public.bank_html() from public, anon, authenticated;
revoke execute on function public.iban_ok(text), public.iban_fmt(text) from public, anon, authenticated;

create or replace function public.admin_set_bank(p text, p_iban text, p_benef text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare r text := public.admin_check(p);
begin
  if r <> 'ok' then return jsonb_build_object('error', r); end if;
  if not public.iban_ok(p_iban) then return jsonb_build_object('error','iban'); end if;
  if p_benef is null or char_length(trim(p_benef)) not between 2 and 80 then return jsonb_build_object('error','titulaire'); end if;
  update public.shop_config set iban = upper(regexp_replace(p_iban, '\s', '', 'g')), beneficiary = trim(p_benef) where id = 1;
  return jsonb_build_object('ok', true);
end $$;
revoke execute on function public.admin_set_bank(text,text,text) from public;
grant execute on function public.admin_set_bank(text,text,text) to anon, authenticated;

create or replace function public.get_config() returns jsonb
language sql security definer set search_path = public as $$
  select jsonb_build_object(
    'prices', (select jsonb_agg(jsonb_build_object('texture',texture,'size',size,'price',price)) from public.prices),
    'places', coalesce((select jsonb_agg(jsonb_build_object('id',id,'name',name) order by sort, id) from public.places where active), '[]'::jsonb),
    'bank', (select jsonb_build_object('iban', public.iban_fmt(iban), 'beneficiary', beneficiary) from public.shop_config where id = 1))
$$;
revoke execute on function public.get_config() from public;
grant execute on function public.get_config() to anon, authenticated;

create or replace function public.admin_orders(p text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare r text := public.admin_check(p);
begin
  if r <> 'ok' then return jsonb_build_object('error', r); end if;
  return jsonb_build_object(
    'orders', coalesce((select jsonb_agg(to_jsonb(o) order by o.id desc) from public.orders o), '[]'::jsonb),
    'admin_email', (select to_email from public.notify_config where id = 1),
    'stock', (select jsonb_agg(jsonb_build_object('honey',honey,'texture',texture,'size',size,'qty',qty) order by honey desc, texture, size) from public.stock),
    'prices', (select jsonb_agg(jsonb_build_object('texture',texture,'size',size,'price',price)) from public.prices),
    'places', (select jsonb_agg(jsonb_build_object('id',id,'name',name,'active',active) order by sort, id) from public.places),
    'bank', (select jsonb_build_object('iban', public.iban_fmt(iban), 'beneficiary', beneficiary) from public.shop_config where id = 1));
end $$;
revoke execute on function public.admin_orders(text) from public;
grant execute on function public.admin_orders(text) to anon, authenticated;


-- =====================================================================================
-- V5 : catalogue de miels, photos, pause/bandeau, mot de passe oublié, suivi des e-mails
-- =====================================================================================

-- ---------- Catalogue ----------
create table if not exists public.products (
  id text primary key check (id ~ '^[a-z0-9-]{2,40}$'),
  name text not null check (char_length(name) between 2 and 80),
  notes text not null default '' check (char_length(notes) <= 400),
  tech jsonb not null default '[]'::jsonb,
  photos jsonb not null default '{}'::jsonb,
  visible boolean not null default true,
  sort int not null default 0
);
alter table public.products enable row level security;
revoke all on public.products from anon, authenticated;
insert into public.products (id, name, notes, tech, sort)
select * from (values
  ('printemps', 'Miel de printemps', 'Le miel de printemps de Dion-le-Mont, en pot depuis fin septembre.', '[["Récolte","Printemps 2026"],["Origine","Dion-le-Mont, BE"]]'::jsonb, 1),
  ('ete', 'Miel d’été', 'Le miel d’été de Dion-le-Mont, récolté en 2026. Analysé par le CARI : 5 étoiles.', '[["Récolte","Été 2026"],["Humidité","16,4 % (CARI)"],["Origine","Dion-le-Mont, BE"]]'::jsonb, 2)
) v(id,name,notes,tech,sort)
where not exists (select 1 from public.products);
alter table public.products add column if not exists prices jsonb not null default '{}'::jsonb;
update public.products set prices = (select jsonb_object_agg(texture||'|'||size, price) from public.prices) where prices = '{}'::jsonb;
alter table public.stock drop constraint if exists stock_honey_check;
alter table public.stock drop constraint if exists stock_size_check;
do $$ begin
  if not exists (select 1 from public.orders) then alter table public.orders alter column id restart with 1; end if;
end $$;

create or replace function public.honey_ok(h text, need_visible boolean) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.products where id = h and (visible or not need_visible))
$$;
revoke execute on function public.honey_ok(text,boolean) from public, anon, authenticated;

-- ---------- Boutique : pause et bandeau ----------
alter table public.shop_config add column if not exists paused boolean not null default false;
alter table public.shop_config add column if not exists pause_message text not null default '';
alter table public.shop_config add column if not exists banner text not null default '';

create or replace function public.admin_set_shop(p text, p_paused boolean, p_pause_message text, p_banner text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare r text := public.admin_check(p);
begin
  if r <> 'ok' then return jsonb_build_object('error', r); end if;
  if char_length(coalesce(p_pause_message,'')) > 200 or char_length(coalesce(p_banner,'')) > 200 then return jsonb_build_object('error','texte_long'); end if;
  update public.shop_config set paused = coalesce(p_paused,false), pause_message = trim(coalesce(p_pause_message,'')), banner = trim(coalesce(p_banner,'')) where id = 1;
  return jsonb_build_object('ok', true);
end $$;
revoke execute on function public.admin_set_shop(text,boolean,text,text) from public;
grant execute on function public.admin_set_shop(text,boolean,text,text) to anon, authenticated;

-- ---------- Photos : envoi depuis l'admin ----------
create table if not exists public.upload_tokens (token text primary key, expires_at timestamptz not null);
alter table public.upload_tokens enable row level security;
revoke all on public.upload_tokens from anon, authenticated;

create or replace function public.admin_upload_token(p text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare r text := public.admin_check(p); t text;
begin
  if r <> 'ok' then return jsonb_build_object('error', r); end if;
  delete from public.upload_tokens where expires_at < now();
  t := encode(extensions.gen_random_bytes(12), 'hex');
  insert into public.upload_tokens values (t, now() + interval '30 minutes');
  return jsonb_build_object('token', t);
end $$;
revoke execute on function public.admin_upload_token(text) from public;
grant execute on function public.admin_upload_token(text) to anon, authenticated;

create or replace function public.upload_ok(n text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.upload_tokens where token = split_part(n, '/', 1) and expires_at > now())
$$;
revoke execute on function public.upload_ok(text) from public;
grant execute on function public.upload_ok(text) to anon, authenticated;

do $$ begin
  insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
  values ('photos', 'photos', true, 3145728, array['image/jpeg','image/png','image/webp']) on conflict (id) do nothing;
exception when others then raise notice 'Stockage des photos : bucket non créé (%). Créez un bucket public « photos » dans Storage.', sqlerrm;
end $$;
do $$ begin
  drop policy if exists xapi_upload on storage.objects;
  create policy xapi_upload on storage.objects for insert to anon, authenticated
    with check (bucket_id = 'photos' and public.upload_ok(name));
exception when others then raise notice 'Stockage des photos : règle d''envoi non créée (%).', sqlerrm;
end $$;

-- ---------- Gestion du catalogue ----------
-- p_products : [{id?, name, notes, tech:[[libellé,valeur],...], photos:{"classique|250 g":url,...}, visible}], l'ordre du tableau = l'ordre d'affichage
create or replace function public.admin_set_products(p text, p_products jsonb) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare r text := public.admin_check(p); x jsonb; i int := 0; nm text; pid text; base text; n int; t jsonb; ph jsonb; k text; v text; vis boolean; pr jsonb; pk text; pv text;
begin
  if r <> 'ok' then return jsonb_build_object('error', r); end if;
  if jsonb_typeof(p_products) <> 'array' or jsonb_array_length(p_products) not between 1 and 30 then return jsonb_build_object('error','produit_invalide'); end if;
  for x in select * from jsonb_array_elements(p_products) loop
    i := i + 1; nm := trim(coalesce(x->>'name',''));
    if char_length(nm) not between 2 and 80 then return jsonb_build_object('error','produit_invalide'); end if;
    if char_length(coalesce(x->>'notes','')) > 400 then return jsonb_build_object('error','produit_invalide'); end if;
    t := coalesce(x->'tech', '[]'::jsonb);
    if jsonb_typeof(t) <> 'array' or jsonb_array_length(t) > 8 then return jsonb_build_object('error','produit_invalide'); end if;
    ph := coalesce(x->'photos', '{}'::jsonb);
    if jsonb_typeof(ph) <> 'object' then return jsonb_build_object('error','produit_invalide'); end if;
    for k, v in select key, value from jsonb_each_text(ph) loop
      if k !~ '^(classique|cremeux)\|[0-9]{1,4}(,[0-9]{1,2})? ?(g|kg)$' or v !~ '^https://[^ ]+/storage/v1/object/public/photos/[^ ]+$' or char_length(v) > 300 then return jsonb_build_object('error','photo_invalide'); end if;
    end loop;
    pr := coalesce(x->'prices', (select jsonb_object_agg(texture||'|'||size, price) from public.prices));
    if jsonb_typeof(pr) <> 'object' or (select count(*) from jsonb_object_keys(pr)) = 0 then return jsonb_build_object('error','prix_invalide'); end if;
    for pk, pv in select key, value from jsonb_each_text(pr) loop
      if pk !~ '^(classique|cremeux)\|[0-9]{1,4}(,[0-9]{1,2})? ?(g|kg)$' or pv !~ '^[0-9]+([.][0-9]{1,2})?$' or pv::numeric < 0.01 or pv::numeric > 500 then return jsonb_build_object('error','prix_invalide'); end if;
    end loop;
    vis := coalesce((x->>'visible')::boolean, true);
    if x->>'id' is null or x->>'id' = '' then
      base := left(trim(both '-' from regexp_replace(lower(translate(nm,'àâäéèêëîïôöùûüçœ','aaaeeeeiioouuuco')), '[^a-z0-9]+', '-', 'g')), 30);
      if char_length(base) < 2 then base := 'miel'; end if;
      pid := base; n := 1;
      while exists (select 1 from public.products where id = pid) loop n := n + 1; pid := left(base, 30) || '-' || n; end loop;
      insert into public.products (id, name, notes, tech, photos, prices, visible, sort) values (pid, nm, coalesce(x->>'notes',''), t, ph, pr, vis, i);
    else
      update public.products set name = nm, notes = coalesce(x->>'notes',''), tech = t, photos = ph, prices = pr, visible = vis, sort = i where id = x->>'id';
    end if;
  end loop;
  insert into public.stock (honey, texture, size) select pr.id, split_part(k.key,'|',1), split_part(k.key,'|',2) from public.products pr, jsonb_each(pr.prices) k on conflict do nothing;
  if not exists (select 1 from public.products where visible) then raise exception 'au moins un produit visible'; end if;
  return jsonb_build_object('ok', true);
exception when others then return jsonb_build_object('error','produit_invalide');
end $$;
revoke execute on function public.admin_set_products(text,jsonb) from public;
grant execute on function public.admin_set_products(text,jsonb) to anon, authenticated;

-- ---------- Mot de passe oublié (code envoyé par e-mail à l'adresse d'alerte) ----------
create table if not exists public.admin_reset (
  id int primary key default 1 check (id = 1),
  code_hash text, expires_at timestamptz, tries int not null default 0, requests timestamptz[] not null default '{}'
);
alter table public.admin_reset enable row level security;
revoke all on public.admin_reset from anon, authenticated;
insert into public.admin_reset (id) values (1) on conflict do nothing;

create or replace function public.admin_request_reset() returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare c record; code text; reqs timestamptz[];
begin
  select * into c from public.notify_config where id = 1;
  if not found or c.brevo_key like 'REMPLACER%' or c.sender_email like 'REMPLACER%' then return jsonb_build_object('error','mail_non_configure'); end if;
  select array_agg(t) into reqs from unnest((select requests from public.admin_reset where id = 1)) t where t > now() - interval '1 hour';
  if coalesce(array_length(reqs,1),0) >= 3 then return jsonb_build_object('error','trop_de_demandes'); end if;
  code := lpad((('x' || encode(extensions.gen_random_bytes(4), 'hex'))::bit(32)::bigint % 1000000)::text, 6, '0');
  update public.admin_reset set code_hash = extensions.crypt(code, extensions.gen_salt('bf')), expires_at = now() + interval '30 minutes', tries = 0,
    requests = coalesce(reqs, '{}') || now() where id = 1;
  perform public.send_mail(c.to_email, 'Votre code pour changer le mot de passe Xapi',
    '<p>Votre code : <b style="font-size:1.4em">'||code||'</b></p><p>Il est valable 30 minutes. Si vous n''avez rien demandé, ignorez ce message.</p>');
  return jsonb_build_object('ok', true);
end $$;
revoke execute on function public.admin_request_reset() from public;
grant execute on function public.admin_request_reset() to anon, authenticated;

create or replace function public.admin_reset_password(p_code text, p_new text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare a public.admin_reset;
begin
  if p_new is null or char_length(p_new) < 10 then return jsonb_build_object('error','trop_court'); end if;
  select * into a from public.admin_reset where id = 1 for update;
  if a.code_hash is null or a.expires_at is null or a.expires_at < now() or a.tries >= 5 then return jsonb_build_object('error','code_invalide'); end if;
  if p_code is null or a.code_hash <> extensions.crypt(trim(p_code), a.code_hash) then
    update public.admin_reset set tries = tries + 1 where id = 1;
    return jsonb_build_object('error','code_invalide');
  end if;
  update public.admin_secret set hash = extensions.crypt(p_new, extensions.gen_salt('bf')) where id = 1;
  update public.admin_reset set code_hash = null, expires_at = null, tries = 0 where id = 1;
  delete from public.admin_attempts;
  return jsonb_build_object('ok', true);
end $$;
revoke execute on function public.admin_reset_password(text,text) from public;
grant execute on function public.admin_reset_password(text,text) to anon, authenticated;

-- ---------- Suivi des e-mails en échec ----------
create table if not exists public.mail_log (id bigint primary key, at timestamptz not null default now(), status int, error text, acked boolean not null default false);
alter table public.mail_log enable row level security;
revoke all on public.mail_log from anon, authenticated;

create or replace function public.record_mail_results() returns void
language plpgsql security definer set search_path = public as $$
begin
  insert into public.mail_log (id, at, status, error)
    select r.id, coalesce(r.created, now()), r.status_code, r.error_msg from net._http_response r
    where (r.status_code >= 400 or r.error_msg is not null) on conflict (id) do nothing;
  delete from public.mail_log where at < now() - interval '60 days';
exception when others then null;
end $$;
revoke execute on function public.record_mail_results() from public, anon, authenticated;

do $$ begin
  perform cron.schedule('xapi-suivi-mails', '17 * * * *', 'select public.record_mail_results()');
exception when others then raise notice 'pg_cron non activé : le suivi des e-mails en échec ne tournera pas.';
end $$;

create or replace function public.admin_ack_mail(p text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare r text := public.admin_check(p);
begin
  if r <> 'ok' then return jsonb_build_object('error', r); end if;
  update public.mail_log set acked = true;
  return jsonb_build_object('ok', true);
end $$;
revoke execute on function public.admin_ack_mail(text) from public;
grant execute on function public.admin_ack_mail(text) to anon, authenticated;

-- ---------- Lecture finale pour le site et l'admin ----------
create or replace function public.get_config() returns jsonb
language sql security definer set search_path = public as $$
  select jsonb_build_object(
    'prices', (select jsonb_agg(jsonb_build_object('texture',texture,'size',size,'price',price)) from public.prices),
    'places', coalesce((select jsonb_agg(jsonb_build_object('id',id,'name',name) order by sort, id) from public.places where active), '[]'::jsonb),
    'bank', (select jsonb_build_object('iban', public.iban_fmt(iban), 'beneficiary', beneficiary) from public.shop_config where id = 1),
    'products', coalesce((select jsonb_agg(jsonb_build_object('id',id,'name',name,'notes',notes,'tech',tech,'photos',photos,'prices',prices) order by sort, id) from public.products where visible), '[]'::jsonb),
    'shop', (select jsonb_build_object('paused',paused,'pause_message',pause_message,'banner',banner) from public.shop_config where id = 1))
$$;
revoke execute on function public.get_config() from public;
grant execute on function public.get_config() to anon, authenticated;

create or replace function public.admin_orders(p text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare r text := public.admin_check(p); nc record;
begin
  if r <> 'ok' then return jsonb_build_object('error', r); end if;
  select * into nc from public.notify_config where id = 1;
  return jsonb_build_object(
    'orders', coalesce((select jsonb_agg(to_jsonb(o) order by o.id desc) from public.orders o), '[]'::jsonb),
    'admin_email', nc.to_email,
    'stock', (select jsonb_agg(jsonb_build_object('honey',honey,'texture',texture,'size',size,'qty',qty) order by honey, texture, size) from public.stock),
    'prices', (select jsonb_agg(jsonb_build_object('texture',texture,'size',size,'price',price)) from public.prices),
    'places', (select jsonb_agg(jsonb_build_object('id',id,'name',name,'active',active) order by sort, id) from public.places),
    'bank', (select jsonb_build_object('iban', public.iban_fmt(iban), 'beneficiary', beneficiary) from public.shop_config where id = 1),
    'products', coalesce((select jsonb_agg(jsonb_build_object('id',id,'name',name,'notes',notes,'tech',tech,'photos',photos,'prices',prices,'visible',visible) order by sort, id) from public.products), '[]'::jsonb),
    'shop', (select jsonb_build_object('paused',paused,'pause_message',pause_message,'banner',banner) from public.shop_config where id = 1),
    'mail', jsonb_build_object(
      'configured', (nc.brevo_key is not null and nc.brevo_key not like 'REMPLACER%' and nc.sender_email not like 'REMPLACER%'),
      'failures', (select count(*) from public.mail_log where not acked and at > now() - interval '14 days')));
end $$;
revoke execute on function public.admin_orders(text) from public;
grant execute on function public.admin_orders(text) to anon, authenticated;


-- ---------- Sauvegarde des commandes par e-mail (CSV en pièce jointe, le 1er du mois à 7 h) ----------
create or replace function public.send_backup() returns void
language plpgsql security definer set search_path = public, extensions as $$
declare c record; csv text; n int;
begin
  select * into c from public.notify_config where id = 1;
  if not found or c.brevo_key like 'REMPLACER%' or c.sender_email like 'REMPLACER%' then return; end if;
  select count(*) into n from public.orders;
  select E'\ufeff' || 'N°;Date;Client;E-mail;Contact;Retrait;Pots;Total;Statut;Communication;Payé le;Retiré le;Message' || E'\r\n' ||
    coalesce(string_agg(format('%s;%s;"%s";"%s";"%s";"%s";"%s";%s;%s;%s;%s;%s;"%s"',
      lpad(o.id::text,4,'0'), to_char(o.created_at at time zone 'Europe/Brussels','YYYY-MM-DD HH24:MI'),
      replace(o.customer_name,'"','""'), replace(coalesce(o.email,''),'"','""'), replace(o.contact,'"','""'), replace(o.pickup,'"','""'),
      replace((select string_agg(format('%s x %s %s %s', i->>'qty', coalesce((select pr.name from public.products pr where pr.id = i->>'honey'), i->>'honey'), i->>'texture', i->>'size'), ' + ') from jsonb_array_elements(o.items) i),'"','""'),
      replace(o.total::text,'.',','), o.status, coalesce(o.communication,''),
      coalesce(to_char(o.paid_at at time zone 'Europe/Brussels','YYYY-MM-DD'),''), coalesce(to_char(o.picked_at at time zone 'Europe/Brussels','YYYY-MM-DD'),''),
      replace(coalesce(o.note,''),'"','""')), E'\r\n' order by o.id), '')
  into csv from public.orders o;
  begin
    perform net.http_post(
      url := 'https://api.brevo.com/v3/smtp/email',
      headers := jsonb_build_object('api-key', c.brevo_key, 'content-type', 'application/json', 'accept', 'application/json'),
      body := jsonb_build_object(
        'sender', jsonb_build_object('name','Xapi, miel de Dion-le-Mont','email',c.sender_email),
        'to', jsonb_build_array(jsonb_build_object('email',c.to_email)),
        'subject', 'Sauvegarde des commandes Xapi du '||to_char(now() at time zone 'Europe/Brussels','DD/MM/YYYY'),
        'htmlContent', '<p>Ci-joint la sauvegarde de vos '||n||' commande(s) (fichier à ouvrir avec Excel). Gardez ce mail.</p>',
        'attachment', jsonb_build_array(jsonb_build_object('name','commandes-xapi-'||to_char(now(),'YYYY-MM-DD')||'.csv','content',
          replace(replace(encode(convert_to(csv,'UTF8'),'base64'),E'\n',''),E'\r','')))));
  exception when others then null;
  end;
end $$;
revoke execute on function public.send_backup() from public, anon, authenticated;

create or replace function public.admin_send_backup(p text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare r text := public.admin_check(p);
begin
  if r <> 'ok' then return jsonb_build_object('error', r); end if;
  perform public.send_backup();
  return jsonb_build_object('ok', true);
end $$;
revoke execute on function public.admin_send_backup(text) from public;
grant execute on function public.admin_send_backup(text) to anon, authenticated;

do $$ begin
  perform cron.schedule('xapi-sauvegarde', '0 6 1 * *', 'select public.send_backup()');
exception when others then raise notice 'pg_cron non activé : pas de sauvegarde mensuelle automatique.';
end $$;
