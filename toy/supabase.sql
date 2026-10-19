-- Toy Bridge: Supabase 命令信箱
-- 在 Supabase 控制台 → SQL Editor 里整段运行一次即可。
--
-- 设计要点（对应《Supabase TOY 控制》文档）：
--   * 表本身不对 anon / authenticated 开放，前端和 AI 只能通过下面几个函数访问
--   * 每个函数都要带 bridge token，数据库里只存它的 sha256
--   * 命令有 expires_at，过期不执行
--   * 领取用 FOR UPDATE SKIP LOCKED，同一条命令只会被领取一次
--   * 数据库层先校验一遍参数，前端执行前再校验一遍

create extension if not exists pgcrypto with schema extensions;

-- ---------------------------------------------------------------------------
-- 表
-- ---------------------------------------------------------------------------

create table if not exists public.toy_bridge_tokens (
    token_hash text primary key,
    label      text,
    created_at timestamptz not null default now()
);

create table if not exists public.device_commands (
    id               uuid primary key default gen_random_uuid(),
    created_at       timestamptz not null default now(),
    expires_at       timestamptz not null default (now() + interval '90 seconds'),

    action           text not null check (action in ('pulse', 'combo', 'stop', 'status')),
    device           text not null default 'toy',

    -- pulse 单通道
    channel          text check (channel in ('vibration', 'suction', 'thrust')),
    pattern          text default 'steady' check (pattern in ('steady', 'pulse', 'wave', 'escalate')),
    intensity        smallint check (intensity between 0 and 100),
    duration_seconds numeric(5,1) check (duration_seconds > 0 and duration_seconds <= 600),

    -- combo 多通道
    channels         jsonb,

    state            text not null default 'pending'
                     check (state in ('pending', 'claimed', 'done', 'rejected', 'error', 'expired')),
    claimed_at       timestamptz,
    finished_at      timestamptz,
    result           jsonb,
    source           text not null default 'ai'
);

create index if not exists device_commands_pending_idx
    on public.device_commands (state, created_at);

alter table public.device_commands   enable row level security;
alter table public.toy_bridge_tokens enable row level security;
-- 不建任何 policy：anon / authenticated 直接读写表一律被拒。
revoke all on public.device_commands   from anon, authenticated;
revoke all on public.toy_bridge_tokens from anon, authenticated;

-- ---------------------------------------------------------------------------
-- 内部工具函数
-- ---------------------------------------------------------------------------

create or replace function public.toy_check_token(p_token text)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
    if p_token is null or not exists (
        select 1 from public.toy_bridge_tokens
        where token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex')
    ) then
        raise exception 'invalid bridge token' using errcode = '28000';
    end if;
end;
$$;

-- 校验 combo 的 channels：必须是非空对象，只允许已知通道和字段
create or replace function public.toy_validate_channels(p_channels jsonb)
returns void
language plpgsql
immutable
as $$
declare
    k text;
    v jsonb;
    f text;
begin
    if p_channels is null or jsonb_typeof(p_channels) <> 'object' or p_channels = '{}'::jsonb then
        raise exception 'combo 需要非空的 channels 对象';
    end if;

    for k, v in select * from jsonb_each(p_channels) loop
        if k not in ('vibration', 'suction', 'thrust') then
            raise exception '未知 channel: %', k;
        end if;
        if jsonb_typeof(v) <> 'object' then
            raise exception 'channel % 必须是对象', k;
        end if;
        for f in select jsonb_object_keys(v) loop
            if f not in ('pattern', 'intensity', 'duration_seconds') then
                raise exception 'channel % 含未知字段: %', k, f;
            end if;
        end loop;
        if jsonb_typeof(v->'intensity') <> 'number'
           or (v->>'intensity')::numeric not between 0 and 100 then
            raise exception 'channel % 的 intensity 必须在 0-100', k;
        end if;
        if jsonb_typeof(v->'duration_seconds') <> 'number'
           or (v->>'duration_seconds')::numeric <= 0
           or (v->>'duration_seconds')::numeric > 600 then
            raise exception 'channel % 的 duration_seconds 必须在 0-600', k;
        end if;
        if v ? 'pattern' and (v->>'pattern') not in ('steady', 'pulse', 'wave', 'escalate') then
            raise exception 'channel % 的 pattern 不支持: %', k, v->>'pattern';
        end if;
    end loop;
end;
$$;

-- ---------------------------------------------------------------------------
-- 对外函数（anon key + bridge token 调用）
-- ---------------------------------------------------------------------------

-- AI 投递命令
create or replace function public.toy_enqueue(
    p_token            text,
    p_action           text,
    p_channel          text    default null,
    p_pattern          text    default 'steady',
    p_intensity        int     default null,
    p_duration_seconds numeric default null,
    p_channels         jsonb   default null,
    p_source           text    default 'ai',
    p_ttl_seconds      int     default 90
)
returns table (id uuid, state text, expires_at timestamptz)
language plpgsql
security definer
set search_path = public, extensions
as $$
#variable_conflict use_column
begin
    perform public.toy_check_token(p_token);

    if p_ttl_seconds is null or p_ttl_seconds not between 5 and 600 then
        raise exception 'ttl 必须在 5-600 秒';
    end if;

    if p_action = 'pulse' then
        if p_channel is null or p_intensity is null or p_duration_seconds is null then
            raise exception 'pulse 需要 channel / intensity / duration_seconds';
        end if;
        p_channels := null;
    elsif p_action = 'combo' then
        perform public.toy_validate_channels(p_channels);
        p_channel := null; p_intensity := null; p_duration_seconds := null;
    elsif p_action in ('stop', 'status') then
        p_intensity := null; p_duration_seconds := null; p_channels := null;
        if p_action = 'status' then p_channel := null; end if;
    else
        raise exception '未知 action: %', p_action;
    end if;

    return query
    insert into public.device_commands as c
        (action, channel, pattern, intensity, duration_seconds, channels, source, expires_at)
    values
        (p_action, p_channel, coalesce(p_pattern, 'steady'), p_intensity, p_duration_seconds,
         p_channels, left(coalesce(p_source, 'ai'), 40), now() + make_interval(secs => p_ttl_seconds))
    returning c.id, c.state, c.expires_at;
end;
$$;

-- 前端领取最早一条未过期的 pending 命令（顺便把过期的标成 expired）
create or replace function public.toy_claim_next(p_token text)
returns setof public.device_commands
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
    perform public.toy_check_token(p_token);

    update public.device_commands
       set state = 'expired', finished_at = now()
     where state = 'pending' and expires_at <= now();

    return query
    update public.device_commands c
       set state = 'claimed', claimed_at = now()
     where c.id = (
        select id from public.device_commands
         where state = 'pending' and expires_at > now()
         order by created_at
         limit 1
         for update skip locked
     )
    returning c.*;
end;
$$;

-- 前端回写结果
create or replace function public.toy_finish(
    p_token  text,
    p_id     uuid,
    p_state  text,
    p_result jsonb default null
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
    perform public.toy_check_token(p_token);
    if p_state not in ('done', 'rejected', 'error') then
        raise exception 'finish 的 state 只能是 done / rejected / error';
    end if;
    update public.device_commands
       set state = p_state, result = p_result, finished_at = now()
     where id = p_id and state = 'claimed';
end;
$$;

-- AI 查询一条命令的执行结果
create or replace function public.toy_get(p_token text, p_id uuid)
returns setof public.device_commands
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
    perform public.toy_check_token(p_token);
    return query select * from public.device_commands where id = p_id;
end;
$$;

-- 清理 30 天前已结束的命令
create or replace function public.toy_cleanup(p_token text, p_days int default 30)
returns int
language plpgsql
security definer
set search_path = public, extensions
as $$
declare n int;
begin
    perform public.toy_check_token(p_token);
    delete from public.device_commands
     where state in ('done', 'rejected', 'error', 'expired')
       and created_at < now() - make_interval(days => greatest(p_days, 1));
    get diagnostics n = row_count;
    return n;
end;
$$;

revoke all on function public.toy_check_token(text)       from public, anon, authenticated;
revoke all on function public.toy_validate_channels(jsonb) from public, anon, authenticated;
grant execute on function public.toy_enqueue(text, text, text, text, int, numeric, jsonb, text, int) to anon;
grant execute on function public.toy_claim_next(text)                 to anon;
grant execute on function public.toy_finish(text, uuid, text, jsonb)  to anon;
grant execute on function public.toy_get(text, uuid)                 to anon;
grant execute on function public.toy_cleanup(text, int)               to anon;

-- ---------------------------------------------------------------------------
-- 最后一步：设置你自己的 bridge token（换成一串只有你知道的长随机字符串）
-- ---------------------------------------------------------------------------
-- insert into public.toy_bridge_tokens (token_hash, label)
-- values (encode(extensions.digest('在这里换成你的长随机token', 'sha256'), 'hex'), 'my-phone');
