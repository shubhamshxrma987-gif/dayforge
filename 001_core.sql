-- DayForge core schema. Run in Supabase SQL Editor or via `supabase db push`.
-- After running, set the owner (replace with YOUR verified email):
--   insert into app_config values ('owner_email','you@gmail.com');
create extension if not exists pgcrypto;

create table app_config(key text primary key, value text not null);
alter table app_config enable row level security;  -- no policies: server only

create function is_owner() returns boolean language sql stable security definer set search_path=public as $$
  select exists(select 1 from auth.users u
    where u.id=auth.uid() and u.email_confirmed_at is not null
    and lower(u.email)=lower((select value from app_config where key='owner_email')));
$$;

create table profiles(
  id uuid primary key references auth.users on delete cascade,
  full_name text, age int check (age is null or age between 13 and 110),
  country text, timezone text default 'UTC', goal text,
  wake_time time default '06:30', sleep_time time default '22:30',
  theme text default 'dark', suspended boolean not null default false,
  last_active timestamptz, created_at timestamptz not null default now());
create function handle_new_user() returns trigger language plpgsql security definer set search_path=public as $$
begin insert into profiles(id) values(new.id); insert into notification_prefs(user_id) values(new.id); return new; end $$;

create table notification_prefs(user_id uuid primary key references auth.users on delete cascade,
  enabled boolean default true, lead_min int default 10, quiet_start time, quiet_end time, leaderboard_opt_in boolean default true);
create trigger on_signup after insert on auth.users for each row execute function handle_new_user();

create table categories(id uuid primary key default gen_random_uuid(), user_id uuid not null references auth.users on delete cascade,
  name text not null, color text not null default '#64748b', unique(user_id,name));
create table activities(id uuid primary key default gen_random_uuid(), user_id uuid not null references auth.users on delete cascade,
  title text not null, category text not null default 'Other', activity_date date not null,
  start_min int not null, end_min int not null, check (start_min>=0 and end_min<=1440 and end_min>start_min),
  repeat text not null default 'none' check (repeat in ('none','daily','weekdays','weekly')),
  notes text, reminder boolean default true, created_at timestamptz default now(), updated_at timestamptz default now());
create table activity_completions(id uuid primary key default gen_random_uuid(), user_id uuid not null references auth.users on delete cascade,
  activity_id uuid not null references activities on delete cascade, occurrence_date date not null,
  actual_minutes int, completed_at timestamptz default now(), unique(activity_id,occurrence_date));
create table goals(id uuid primary key default gen_random_uuid(), user_id uuid not null references auth.users on delete cascade,
  title text not null, target numeric not null, unit text, progress numeric default 0, goal_date date not null);
create table habits(id uuid primary key default gen_random_uuid(), user_id uuid not null references auth.users on delete cascade,
  title text not null, days int[] default '{0,1,2,3,4,5,6}', created_at timestamptz default now());
create table habit_logs(id uuid primary key default gen_random_uuid(), user_id uuid not null references auth.users on delete cascade,
  habit_id uuid not null references habits on delete cascade, log_date date not null, unique(habit_id,log_date));
create table focus_sessions(id uuid primary key default gen_random_uuid(), user_id uuid not null references auth.users on delete cascade,
  started_at timestamptz not null, ended_at timestamptz, planned_min int, actual_min int, activity_id uuid references activities on delete set null);

-- Server-managed money and access tables (users can only read their own rows)
create table entitlements(user_id uuid primary key references auth.users on delete cascade,
  trial_started_at timestamptz, trial_ends_at timestamptz,
  plan text check (plan in ('monthly','yearly')), valid_until timestamptz, updated_at timestamptz default now());
create table coupons(id uuid primary key default gen_random_uuid(), code text not null unique check (code=upper(code)),
  description text, type text not null check (type in ('percent','fixed')), value int not null check (value>0),
  plan text not null default 'both' check (plan in ('monthly','yearly','both')),
  starts_at timestamptz default now(), expires_at timestamptz, max_total int, max_per_user int default 1,
  min_amount_paise int default 0, new_only boolean default false, enabled boolean default true, created_at timestamptz default now());
create table payments(id uuid primary key default gen_random_uuid(), user_id uuid not null references auth.users,
  plan text not null, razorpay_order_id text unique, razorpay_subscription_id text, razorpay_payment_id text unique,
  base_paise int not null, discount_paise int not null default 0, amount_paise int not null check (amount_paise>=100),
  coupon_id uuid references coupons, status text not null default 'pending' check (status in ('pending','paid','failed','canceled','refunded')),
  created_at timestamptz default now(), paid_at timestamptz);
create table subscriptions(id uuid primary key default gen_random_uuid(), user_id uuid not null references auth.users,
  plan text not null, status text not null check (status in ('active','past_due','canceled','expired')),
  razorpay_subscription_id text unique, current_period_end timestamptz, created_at timestamptz default now());
create table coupon_redemptions(id uuid primary key default gen_random_uuid(), coupon_id uuid not null references coupons,
  user_id uuid not null references auth.users, payment_id uuid not null unique references payments,
  discount_paise int not null, created_at timestamptz default now());
create table webhook_events(event_id text primary key, event_type text, payload jsonb, processed_at timestamptz default now()); -- idempotency
create table admin_audit_log(id bigserial primary key, admin_id uuid not null, action text not null, target_user uuid, details jsonb, created_at timestamptz default now());

create index on activities(user_id,activity_date); create index on activity_completions(user_id,occurrence_date);
create index on habit_logs(user_id,log_date); create index on focus_sessions(user_id,started_at);
create index on payments(user_id); create index on coupon_redemptions(coupon_id,user_id);

-- RLS: private tables
do $$ declare t text; begin
  foreach t in array array['categories','activities','activity_completions','goals','habits','habit_logs','focus_sessions','notification_prefs'] loop
    execute format('alter table %I enable row level security',t);
    execute format('create policy own_all on %I for all to authenticated using (user_id=auth.uid()) with check (user_id=auth.uid())',t);
  end loop;
  foreach t in array array['entitlements','payments','subscriptions','coupon_redemptions'] loop
    execute format('alter table %I enable row level security',t);
    execute format('create policy own_read on %I for select to authenticated using (user_id=auth.uid())',t);
    execute format('create policy owner_read on %I for select to authenticated using (is_owner())',t);
  end loop;
end $$;
alter table profiles enable row level security;
create policy own_read on profiles for select to authenticated using (id=auth.uid());
create policy own_update on profiles for update to authenticated using (id=auth.uid()) with check (id=auth.uid());
create policy owner_read on profiles for select to authenticated using (is_owner());
revoke update on profiles from authenticated;  -- users cannot un-suspend themselves
grant update(full_name,age,country,timezone,goal,wake_time,sleep_time,theme) on profiles to authenticated;
alter table coupons enable row level security;
create policy owner_all on coupons for all to authenticated using (is_owner()) with check (is_owner());
alter table webhook_events enable row level security;
alter table admin_audit_log enable row level security;
create policy owner_read on admin_audit_log for select to authenticated using (is_owner());
-- Note: no admin policy on activities/habits/goals. The owner cannot read private timetables.

-- Trial: one per account, server time, cannot be restarted by reinstalling or changing the phone clock
create function start_trial() returns timestamptz language plpgsql security definer set search_path=public as $$
declare e timestamptz; begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  insert into entitlements(user_id,trial_started_at,trial_ends_at) values(auth.uid(),now(),now()+interval '7 days')
    on conflict(user_id) do update set trial_started_at=now(),trial_ends_at=now()+interval '7 days'
    where entitlements.trial_started_at is null returning trial_ends_at into e;
  if e is null then raise exception 'Trial already used'; end if; return e; end $$;

create function has_access() returns boolean language sql stable security definer set search_path=public as $$
  select coalesce((select (trial_ends_at>now()) or (valid_until>now()) from entitlements where user_id=auth.uid()),false)
         and not coalesce((select suspended from profiles where id=auth.uid()),false); $$;

create function admin_overview() returns jsonb language plpgsql security definer set search_path=public as $$
begin if not is_owner() then raise exception 'Forbidden'; end if;
  insert into admin_audit_log(admin_id,action) values(auth.uid(),'view_overview');
  return jsonb_build_object(
    'users',(select count(*) from profiles),
    'active_trials',(select count(*) from entitlements where trial_ends_at>now() and coalesce(valid_until,'-infinity')<=now()),
    'expired_trials',(select count(*) from entitlements where trial_ends_at<=now() and coalesce(valid_until,'-infinity')<=now()),
    'paid_active',(select count(*) from entitlements where valid_until>now()),
    'revenue_paise',(select coalesce(sum(amount_paise),0) from payments where status='paid'),
    'discount_paise',(select coalesce(sum(discount_paise),0) from payments where status='paid'),
    'redemptions',(select count(*) from coupon_redemptions)); end $$;
revoke all on function admin_overview(), start_trial(), has_access() from public;
grant execute on function admin_overview(), start_trial(), has_access() to authenticated;
-- Payments, coupon checks, and entitlement grants run in Edge Functions with the service role (next stage).
