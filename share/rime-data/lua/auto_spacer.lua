-- 在 CJK 与 ASCII 的提交边界补一个空格。
--
-- 必须挂在 engine/processors 的 ascii_composer 之前：完整西文态下
-- ascii_composer 会把可打印键 kRejected 直接放行给应用，commit 不经过
-- filter，只有在 processor 里用 Engine:commit_text(" ") 才能补上左空格。
--
-- 只处理边界，不改候选文本；不产生尾随空格；纯 ASCII 串内部不碰
-- （URL / email / 代码 / 数字分隔符保持原样）。
--
-- Lua 5.2 compatible：nixpkgs librime 链接 Lua 5.2，Squirrel 用 5.4。

local M = {}
local kNoop = 2

local HAN, FULL, WORD, OPEN, CLOSE, SPACE, OTHER = 1, 2, 3, 4, 5, 6, 7

local function cp_at(s, i)
  local b = s:byte(i)
  if not b then return nil, i end
  local n, cp
  if b < 0x80 then n, cp = 0, b
  elseif b >= 0xF0 then n, cp = 3, b - 0xF0
  elseif b >= 0xE0 then n, cp = 2, b - 0xE0
  elseif b >= 0xC0 then n, cp = 1, b - 0xC0
  else n, cp = 0, b end
  for k = 1, n do
    local c = s:byte(i + k)
    if not c then break end
    cp = cp * 64 + (c - 0x80)
  end
  return cp, i + n + 1
end

local function first_cp(s)
  return (cp_at(s, 1))
end

-- 从尾部取最后一个码点，避免每个按键都分配一张码点表。
local function last_cp(s)
  local i = #s
  if i == 0 then return nil, nil end
  local j = i
  while j > 1 do
    local b = s:byte(j)
    if b < 0x80 or b >= 0xC0 then break end
    j = j - 1
  end
  local cp = cp_at(s, j)
  return cp, j
end

local function last2(s)
  local p, start = last_cp(s or '')
  if not p then return nil, nil end
  local j = start - 1
  if j < 1 then return p, nil end
  while j > 1 do
    local b = s:byte(j)
    if b < 0x80 or b >= 0xC0 then break end
    j = j - 1
  end
  return p, (cp_at(s, j))
end

local function is_han(cp)
  return (cp >= 0x3400 and cp <= 0x4DBF) or
         (cp >= 0x4E00 and cp <= 0x9FFF) or
         (cp >= 0xF900 and cp <= 0xFAFF) or
         (cp >= 0x20000 and cp <= 0x2FA1F)
end

local function is_full(cp)
  return (cp >= 0x3000 and cp <= 0x303F) or
         (cp >= 0xFF01 and cp <= 0xFF60) or
         (cp >= 0xFFE0 and cp <= 0xFFE6) or
         (cp >= 0xFE10 and cp <= 0xFE19) or
         (cp >= 0xFE30 and cp <= 0xFE4F)
end

-- 这些符号算英文 token 的一部分：C++、C#、a_b、foo@bar、/usr/local。
local TOKEN_PUNCT = {
  [0x2B] = true, [0x23] = true, [0x5F] = true, [0x40] = true,
  [0x24] = true, [0x26] = true, [0x2A] = true, [0x3D] = true,
  [0x2F] = true, [0x5C] = true, [0x7C] = true, [0x7E] = true,
  [0x5E] = true, [0x2D] = true,
}
local OPEN_PUNCT = { [0x28] = true, [0x5B] = true, [0x7B] = true, [0x3C] = true }
local CLOSE_PUNCT = {
  [0x29] = true, [0x5D] = true, [0x7D] = true, [0x3E] = true,
  [0x2C] = true, [0x2E] = true, [0x21] = true, [0x3F] = true,
  [0x3B] = true, [0x3A] = true, [0x25] = true,
}

local function kind(cp)
  if cp == 0x20 or cp == 0x09 or cp == 0x0A or cp == 0x0D or cp == 0x3000 then
    return SPACE
  end
  if is_han(cp) then return HAN end
  if is_full(cp) then return FULL end
  if (cp >= 0x30 and cp <= 0x39) or (cp >= 0x41 and cp <= 0x5A) or
     (cp >= 0x61 and cp <= 0x7A) or TOKEN_PUNCT[cp] then
    return WORD
  end
  if OPEN_PUNCT[cp] then return OPEN end
  if CLOSE_PUNCT[cp] then return CLOSE end
  return OTHER
end

-- prev2 只在需要判断“逗号前是否中文”时才取，避免每个按键分配 history 表。
local function previous_text(ctx)
  local t = ctx.commit_history:to_table()
  local r = t[#t - 1]
  return r and r.text or ''
end

local function need_before_ascii(ctx, prev, ch_cp, mode)
  local p, p2 = last2(prev or '')
  if not p then return false end
  local pk, ck = kind(p), kind(ch_cp)
  if pk == HAN then
    if ck == WORD then return true end
    if ck == OPEN and mode ~= 'off' then return true end
    if ck == CLOSE and mode == 'both' then return true end
  elseif pk == CLOSE and (ck == WORD or ck == HAN) and mode ~= 'off' then
    if mode == 'both' then return true end
    if not p2 then
      p2 = last2(previous_text(ctx))
    end
    return p2 ~= nil and kind(p2) == HAN
  end
  return false
end

local function need_before_cjk(prev, mode)
  local p = last2(prev or '')
  if not p then return false end
  local pk = kind(p)
  if pk == HAN or pk == FULL or pk == SPACE then return false end
  if pk == OPEN then return mode == 'both' end
  if pk == CLOSE then return mode ~= 'off' end
  return true
end

local function latest(ctx)
  return ctx.commit_history:latest_text()
end

function M.init(env)
  local conf = env.engine.schema and env.engine.schema.config
  env.enabled = conf and conf:get_bool('auto_spacer/enable') or false
  local mode = conf and conf:get_string('auto_spacer/punct_mode') or ''
  if mode ~= 'smart' and mode ~= 'both' and mode ~= 'off' then mode = 'smart' end
  env.punct_mode = mode
end

function M.func(key, env)
  if not env.enabled then return kNoop end
  if key:release() or key:ctrl() or key:alt() or key:super() then
    return kNoop
  end

  local ctx = env.engine.context
  if ctx:is_composing() then return kNoop end

  local ch = key.keycode
  if ch < 0x20 or ch > 0x7e or ch == 0x20 then return kNoop end

  local c = string.char(ch)
  local is_lower = ch >= 0x61 and ch <= 0x7a
  local is_upper = ch >= 0x41 and ch <= 0x5a
  local is_digit = ch >= 0x30 and ch <= 0x39
  local is_punct = not (is_lower or is_upper or is_digit)

  if not ctx:get_option('ascii_mode') then
    if is_lower then
      -- 拼音首键：从英文/半角标点切回中文。
      if need_before_cjk(latest(ctx), env.punct_mode) then
        env.engine:commit_text(' ')
      end
      return kNoop
    end
    if is_punct and not ctx:get_option('ascii_punct') then
      -- punctuator 会把它翻成全角；不要先加半角空格。
      return kNoop
    end
  end

  -- 裸 ASCII：中文后英文/数字、开括号前、中文逗号后的英文。
  if need_before_ascii(ctx, latest(ctx), first_cp(c), env.punct_mode) then
    env.engine:commit_text(' ')
  end
  return kNoop
end

return M
