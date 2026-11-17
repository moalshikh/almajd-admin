-- =====================================================================
-- تنبيهات واتساب لقروب الإدارة (Evolution API) — نظام الشؤون الإدارية
-- طريقة التركيب: Supabase ← SQL Editor ← الصق الملف كاملاً كما هو ← Run
-- لا يحتاج أي تعديل. بيانات الربط (الرابط، المفتاح، القروب) تُدخل بعدها
-- من صفحة الإعدادات داخل النظام، بحساب المدير.
-- آمن لإعادة التشغيل أكثر من مرة.
-- =====================================================================

create extension if not exists pg_net;

-- إعدادات الربط: صف واحد فقط، لا يقرؤه أحد من المتصفح مباشرة
create table if not exists public.app_wa_config(
  id        int primary key default 1 check (id = 1),
  base_url  text not null,
  instance  text not null,
  apikey    text not null default '',
  group_jid text not null,
  enabled   boolean not null default true,
  updated_at timestamptz not null default now()
);
alter table public.app_wa_config enable row level security;
revoke all on public.app_wa_config from anon, authenticated;

-- سجل التنبيهات المرسلة
create table if not exists public.app_wa_log(
  id         bigint generated always as identity primary key,
  at         timestamptz not null default now(),
  by_name    text,
  body       text not null,
  request_id bigint
);
create index if not exists app_wa_log_at on public.app_wa_log(at desc);
alter table public.app_wa_log enable row level security;
revoke all on public.app_wa_log from anon, authenticated;

-- التحقق من باركود الدخول بنفس دالة المزامنة الموجودة (app_pull)
-- ترجع {id,name,role} أو ترفع invalid_token
create or replace function public.app_wa_me(p_token text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v jsonb;
begin
  v := to_jsonb(public.app_pull(p_token => p_token, p_since => 99999999999999));
  if v is null or jsonb_typeof(v->'me') is distinct from 'object' then
    raise exception 'invalid_token';
  end if;
  return v->'me';
end $$;
revoke all on function public.app_wa_me(text) from public, anon, authenticated;

-- إرسال تنبيه للقروب
create or replace function public.app_wa_send(p_token text, p_text text) returns bigint
language plpgsql security definer set search_path = public, extensions, net as $$
declare me jsonb; c public.app_wa_config; rid bigint; t text;
begin
  me := public.app_wa_me(p_token);
  t := left(btrim(coalesce(p_text, '')), 1500);
  if t = '' then raise exception 'empty_text'; end if;

  select * into c from public.app_wa_config where id = 1;
  if not found or coalesce(c.apikey, '') = '' then raise exception 'wa_not_configured'; end if;
  if not c.enabled then raise exception 'wa_disabled'; end if;

  -- حماية من الإغراق: 20 رسالة في الدقيقة كحد أقصى
  if (select count(*) from public.app_wa_log where at > now() - interval '1 minute') >= 20 then
    raise exception 'rate_limited';
  end if;

  select net.http_post(
    url     := rtrim(c.base_url, '/') || '/message/sendText/' || c.instance,
    body    := jsonb_build_object('number', c.group_jid, 'text', t),
    headers := jsonb_build_object('Content-Type', 'application/json', 'apikey', c.apikey),
    timeout_milliseconds := 8000
  ) into rid;

  insert into public.app_wa_log(by_name, body, request_id) values (me->>'name', t, rid);
  delete from public.app_wa_log where at < now() - interval '60 days';
  return rid;
end $$;

-- حفظ بيانات الربط (للمدير فقط). المفتاح الفارغ = إبقاء المفتاح الحالي
create or replace function public.app_wa_setup(
  p_token text, p_base_url text, p_instance text, p_group text, p_apikey text default ''
) returns boolean
language plpgsql security definer set search_path = public as $$
declare me jsonb; u text := rtrim(btrim(coalesce(p_base_url, '')), '/');
        i text := btrim(coalesce(p_instance, '')); g text := btrim(coalesce(p_group, ''));
        k text := btrim(coalesce(p_apikey, ''));
begin
  me := public.app_wa_me(p_token);
  if me->>'role' is distinct from 'manager' then raise exception 'not_manager'; end if;
  if u !~* '^https?://[^\s/]+' then raise exception 'رابط السيرفر غير صحيح'; end if;
  if i !~ '^[A-Za-z0-9_.-]+$' then raise exception 'اسم الـ instance غير صحيح'; end if;
  if g !~ '^[0-9-]+@(g\.us|s\.whatsapp\.net)$' then raise exception 'معرّف القروب غير صحيح'; end if;

  insert into public.app_wa_config(id, base_url, instance, group_jid, apikey)
  values (1, u, i, g, k)
  on conflict (id) do update set
    base_url = excluded.base_url, instance = excluded.instance, group_jid = excluded.group_jid,
    apikey = case when excluded.apikey = '' then public.app_wa_config.apikey else excluded.apikey end,
    updated_at = now();
  return true;
end $$;

-- قراءة بيانات الربط بدون المفتاح (للمدير فقط)
create or replace function public.app_wa_info(p_token text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me jsonb; c public.app_wa_config;
begin
  me := public.app_wa_me(p_token);
  if me->>'role' is distinct from 'manager' then raise exception 'not_manager'; end if;
  select * into c from public.app_wa_config where id = 1;
  if not found then return jsonb_build_object('has_key', false); end if;
  return jsonb_build_object('base_url', c.base_url, 'instance', c.instance,
                            'group_jid', c.group_jid, 'has_key', c.apikey <> '', 'enabled', c.enabled);
end $$;

-- آخر 15 تنبيهاً مع حالة وصولها للسيرفر (للمدير فقط)
create or replace function public.app_wa_recent(p_token text) returns jsonb
language plpgsql security definer set search_path = public, net as $$
declare me jsonb;
begin
  me := public.app_wa_me(p_token);
  if me->>'role' is distinct from 'manager' then raise exception 'not_manager'; end if;
  return (
    select coalesce(jsonb_agg(to_jsonb(q)), '[]'::jsonb) from (
      select l.at, l.by_name, left(l.body, 90) as body, r.status_code, r.timed_out, r.error_msg
      from public.app_wa_log l
      left join net._http_response r on r.id = l.request_id
      order by l.at desc limit 15
    ) q
  );
end $$;

grant execute on function public.app_wa_send(text, text) to anon, authenticated;
grant execute on function public.app_wa_setup(text, text, text, text, text) to anon, authenticated;
grant execute on function public.app_wa_info(text) to anon, authenticated;
grant execute on function public.app_wa_recent(text) to anon, authenticated;

notify pgrst, 'reload schema';
