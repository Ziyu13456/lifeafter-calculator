# Supabase 配置指南（折中方案：云端配方 + 本地兜底）

目标：
- **配方 recipes**：云端集中管理（匿名可读），普通用户不可修改；管理员可通过 **Edge Function** 修改（可审计、可回滚）。
- **价格 prices**：游客可在本地录入并保存；登录用户可同步到云端，且只能读写自己的价格。
- **账号密码**：使用 **Supabase Auth** 管理（不自建密码表、不自存密码）。

> 前端约定：用户名登录会映射为 `username@lifeafter.local` 的邮箱形式；用户输入的密码直接交给 Supabase Auth。

---

## 1. 建表（SQL）

在 Supabase 控制台 → SQL Editor 执行。

### 1.1 profiles（用户资料与角色）

```sql
create table if not exists public.profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null,
  role text not null default 'user', -- 'user' | 'admin'
  profession text,
  updated_at timestamptz not null default now()
);

alter table public.profiles enable row level security;

-- 自己可读自己的 profile
create policy "profiles_select_own"
on public.profiles for select
using (auth.uid() = user_id);

-- 自己可写自己的 profile（注册后 upsert display_name）
create policy "profiles_upsert_own"
on public.profiles for insert
with check (auth.uid() = user_id);

create policy "profiles_update_own"
on public.profiles for update
using (auth.uid() = user_id)
with check (auth.uid() = user_id);
```

> 管理员授予方式：见本文最后“管理员授予”。

---

### 1.2 user_prices（每个用户自己的材料价格）

```sql
create table if not exists public.user_prices (
  user_id uuid primary key references auth.users(id) on delete cascade,
  prices jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

alter table public.user_prices enable row level security;

create policy "user_prices_select_own"
on public.user_prices for select
using (auth.uid() = user_id);

create policy "user_prices_upsert_own"
on public.user_prices for insert
with check (auth.uid() = user_id);

create policy "user_prices_update_own"
on public.user_prices for update
using (auth.uid() = user_id)
with check (auth.uid() = user_id);
```

---

### 1.3 recipes_current（当前生效配方：匿名可读，客户端不可写）

```sql
create table if not exists public.recipes_current (
  name text primary key,
  materials jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now(),
  updated_by uuid
);

alter table public.recipes_current enable row level security;

-- 允许匿名与登录用户读取
create policy "recipes_current_select_all"
on public.recipes_current for select
using (true);

-- 不给任何客户端 INSERT/UPDATE/DELETE 权限（写入仅允许通过 Edge Function + service_role）
-- 注意：RLS 开启后，只要不创建写策略，客户端就无法写入。
```

---

### 1.4 recipes_history（审计日志：仅管理员可读；写入由 Edge Function 负责）

```sql
create table if not exists public.recipes_history (
  id uuid primary key default gen_random_uuid(),
  recipe_name text not null,
  materials jsonb not null default '{}'::jsonb,
  op text not null, -- 'upsert' | 'delete'
  changed_at timestamptz not null default now(),
  changed_by uuid,
  note text
);

alter table public.recipes_history enable row level security;

-- 仅管理员可读（管理员身份通过 profiles.role 判断）
create policy "recipes_history_admin_select"
on public.recipes_history for select
using (
  exists (
    select 1 from public.profiles p
    where p.user_id = auth.uid()
      and p.role = 'admin'
  )
);

-- 不开放客户端写策略（同 recipes_current）
```

---

## 2. Edge Function（管理员写配方的唯一入口）

你需要创建两个函数：
- `recipes-admin-upsert`：新增/更新配方
- `recipes-admin-delete`：删除配方

在 Supabase 控制台 → Edge Functions 创建，对应函数名粘贴代码。

> 关键点：函数内部使用 `SUPABASE_SERVICE_ROLE_KEY`（仅存在函数环境变量中），所以可以绕过 RLS 执行写入；同时我们会校验调用者是否管理员。

### 2.1 recipes-admin-upsert（Deno 示例）

```ts
// supabase/functions/recipes-admin-upsert/index.ts
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("Method Not Allowed", { status: 405 });

  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;

  // 1) 用 anonKey + 用户 JWT 验证调用者身份（用于拿到 auth.uid）
  const authHeader = req.headers.get("Authorization") ?? "";
  const userClient = createClient(supabaseUrl, anonKey, { global: { headers: { Authorization: authHeader } } });
  const { data: userData, error: userErr } = await userClient.auth.getUser();
  if (userErr || !userData?.user) return Response.json({ error: "Unauthorized" }, { status: 401 });

  const userId = userData.user.id;

  // 2) 校验管理员角色（用 userClient 查 profiles，受 RLS 保护）
  const { data: prof, error: profErr } = await userClient.from("profiles").select("role").eq("user_id", userId).maybeSingle();
  if (profErr || !prof || prof.role !== "admin") return Response.json({ error: "Forbidden" }, { status: 403 });

  // 3) 解析并校验入参
  const body = await req.json().catch(() => null);
  const name = body?.name;
  const materials = body?.materials;
  if (typeof name !== "string" || !name.trim()) return Response.json({ error: "Invalid name" }, { status: 400 });
  if (typeof materials !== "object" || Array.isArray(materials) || materials === null) {
    return Response.json({ error: "Invalid materials" }, { status: 400 });
  }

  // 4) 用 service_role 执行写入（绕过 RLS）
  const adminClient = createClient(supabaseUrl, serviceKey);

  const now = new Date().toISOString();
  const { error: upsertErr } = await adminClient
    .from("recipes_current")
    .upsert({ name: name.trim(), materials, updated_at: now, updated_by: userId }, { onConflict: "name" });
  if (upsertErr) return Response.json({ error: upsertErr.message }, { status: 500 });

  const { error: histErr } = await adminClient
    .from("recipes_history")
    .insert({ recipe_name: name.trim(), materials, op: "upsert", changed_at: now, changed_by: userId });
  if (histErr) return Response.json({ error: histErr.message }, { status: 500 });

  return Response.json({ ok: true });
});
```

### 2.2 recipes-admin-delete（Deno 示例）

```ts
// supabase/functions/recipes-admin-delete/index.ts
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("Method Not Allowed", { status: 405 });

  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;

  const authHeader = req.headers.get("Authorization") ?? "";
  const userClient = createClient(supabaseUrl, anonKey, { global: { headers: { Authorization: authHeader } } });
  const { data: userData, error: userErr } = await userClient.auth.getUser();
  if (userErr || !userData?.user) return Response.json({ error: "Unauthorized" }, { status: 401 });

  const userId = userData.user.id;
  const { data: prof } = await userClient.from("profiles").select("role").eq("user_id", userId).maybeSingle();
  if (!prof || prof.role !== "admin") return Response.json({ error: "Forbidden" }, { status: 403 });

  const body = await req.json().catch(() => null);
  const name = body?.name;
  if (typeof name !== "string" || !name.trim()) return Response.json({ error: "Invalid name" }, { status: 400 });

  const adminClient = createClient(supabaseUrl, serviceKey);
  const now = new Date().toISOString();

  const { error: delErr } = await adminClient.from("recipes_current").delete().eq("name", name.trim());
  if (delErr) return Response.json({ error: delErr.message }, { status: 500 });

  const { error: histErr } = await adminClient
    .from("recipes_history")
    .insert({ recipe_name: name.trim(), materials: {}, op: "delete", changed_at: now, changed_by: userId });
  if (histErr) return Response.json({ error: histErr.message }, { status: 500 });

  return Response.json({ ok: true });
});
```

---

## 3. 管理员授予（你选择的方式：后台手动授予）

步骤：
1. 让目标账号先在网页里注册并登录一次（确保 profiles 被创建）
2. Supabase 控制台 → Table Editor → `profiles` → 找到该 `user_id` 行
3. 把 `role` 从 `user` 改成 `admin`

之后该账号登录时，前端会显示“配方管理”，并通过 Edge Function 修改配方。

---

## 4. 前端侧行为（与你的 index.html 已对齐）

- 配方加载顺序：Supabase `recipes_current` → localStorage 缓存 → `recipes.json` → 内置配方
- 游客价格：仅本地 `localStorage.material_prices`
- 登录用户价格：可上传/下载 `user_prices`（RLS 保证只读写自己）
- 配方管理：只有管理员看得到入口；实际写入必须由 Edge Function 完成

