-- ========================================
-- 1. 创建用户资料表
-- ========================================
create table if not exists public.profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null,
  role text not null default 'user',
  profession text,
  updated_at timestamptz not null default now()
);

alter table public.profiles enable row level security;

create policy "profiles_select_own" on public.profiles for select using (auth.uid() = user_id);
create policy "profiles_upsert_own" on public.profiles for insert with check (auth.uid() = user_id);
create policy "profiles_update_own" on public.profiles for update using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- ========================================
-- 2. 创建用户价格表
-- ========================================
create table if not exists public.user_prices (
  user_id uuid primary key references auth.users(id) on delete cascade,
  prices jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

alter table public.user_prices enable row level security;

create policy "user_prices_select_own" on public.user_prices for select using (auth.uid() = user_id);
create policy "user_prices_upsert_own" on public.user_prices for insert with check (auth.uid() = user_id);
create policy "user_prices_update_own" on public.user_prices for update using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- ========================================
-- 3. 创建配方表（可选，匿名可读）
-- ========================================
create table if not exists public.recipes_current (
  name text primary key,
  materials jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now(),
  updated_by uuid
);

alter table public.recipes_current enable row level security;
create policy "recipes_current_select_all" on public.recipes_current for select using (true);

-- ========================================
-- 4. 开启 Auth 邮箱认证（重要！）
-- ========================================
-- 在 Supabase Dashboard → Authentication → Providers → Email
-- 确保 "Enable Email" 已开启
-- 建议同时开启 "Confirm email" 以提高安全性
