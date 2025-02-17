local util = {}
local arglist_mt = {}

-- have pack/unpack both respect the 'n' field
local _unpack = table.unpack or unpack
local unpack = function(t, i, j) return _unpack(t, i or 1, j or t.n or #t) end
local pack = function(...) return { n = select("#", ...), ... } end
util.pack = pack
util.unpack = unpack

local function is_factorio_object(obj)
    return type(obj) == "table" and type(rawget(obj, "__self")) == "userdata"
end

function util.deepcompare(t1,t2,ignore_mt,cycles,thresh1,thresh2)
  local ty1 = type(t1)
  local ty2 = type(t2)
  -- non-table types can be directly compared
  if ty1 ~= 'table' or ty2 ~= 'table' then return t1 == t2 end
  if is_factorio_object(t1) or is_factorio_object(t2) then return t1 == t2 end
  local mt1 = debug.getmetatable(t1)
  local mt2 = debug.getmetatable(t2)
  -- would equality be determined by metatable __eq?
  if mt1 and mt1 == mt2 and mt1.__eq then
    -- then use that unless asked not to
    if not ignore_mt then return t1 == t2 end
  else -- we can skip the deep comparison below if t1 and t2 share identity
    if rawequal(t1, t2) then return true end
  end

  -- handle recursive tables
  cycles = cycles or {{},{}}
  thresh1, thresh2 = (thresh1 or 1), (thresh2 or 1)
  cycles[1][t1] = (cycles[1][t1] or 0)
  cycles[2][t2] = (cycles[2][t2] or 0)
  if cycles[1][t1] == 1 or cycles[2][t2] == 1 then
    thresh1 = cycles[1][t1] + 1
    thresh2 = cycles[2][t2] + 1
  end
  if cycles[1][t1] > thresh1 and cycles[2][t2] > thresh2 then
    return true
  end

  cycles[1][t1] = cycles[1][t1] + 1
  cycles[2][t2] = cycles[2][t2] + 1

  for k1,v1 in next, t1 do
    local v2 = t2[k1]
    if v2 == nil then
      return false, {k1}
    end

    local same, crumbs = util.deepcompare(v1,v2,nil,cycles,thresh1,thresh2)
    if not same then
      crumbs = crumbs or {}
      table.insert(crumbs, k1)
      return false, crumbs
    end
  end
  for k2,_ in next, t2 do
    -- only check whether each element has a t1 counterpart, actual comparison
    -- has been done in first loop above
    if t1[k2] == nil then return false, {k2} end
  end

  cycles[1][t1] = cycles[1][t1] - 1
  cycles[2][t2] = cycles[2][t2] - 1

  return true
end

function util.shallowcopy(t)
  if type(t) ~= "table" then return t end
  local copy = {}
  setmetatable(copy, getmetatable(t))
  for k,v in next, t do
    copy[k] = v
  end
  return copy
end

function util.deepcopy(t, deepmt, cache)
  if type(t) ~= "table" or is_factorio_object(t) then return t end
  local copy = {}

  -- handle recursive tables
  local cache = cache or {}
  if cache[t] then return cache[t] end
  cache[t] = copy

  for k,v in next, t do
    copy[k] = (spy.is_spy(v) and v or util.deepcopy(v, deepmt, cache))
  end
  if deepmt then
    debug.setmetatable(copy, util.deepcopy(debug.getmetatable(t, nil, cache)))
  else
    debug.setmetatable(copy, debug.getmetatable(t))
  end
  return copy
end

-----------------------------------------------
-- Copies arguments as a list of arguments
-- @param args the arguments of which to copy
-- @return the copy of the arguments
function util.copyargs(args)
  local copy = {}
  setmetatable(copy, getmetatable(args))
  for k,v in pairs(args) do
    copy[k] = ((match.is_matcher(v) or spy.is_spy(v)) and v or util.deepcopy(v))
  end
  return { vals = copy, refs = util.shallowcopy(args) }
end

-----------------------------------------------
-- Clear an arguments or return values list from a table
-- @param arglist the table to clear of arguments or return values and their count
-- @return No return values
function util.cleararglist(arglist)
  for idx = arglist.n, 1, -1 do
    util.tremove(arglist, idx)
  end
  arglist.n = nil
end

-----------------------------------------------
-- Test specs against an arglist in deepcopy and refs flavours.
-- @param args deepcopy arglist
-- @param argsrefs refs arglist
-- @param specs arguments/return values to match against args/argsrefs
-- @return true if specs match args/argsrefs, false otherwise
local function matcharg(args, argrefs, specs)
  for idx, argval in pairs(args) do
    local spec = specs[idx]
    if match.is_matcher(spec) then
      if match.is_ref_matcher(spec) then
        argval = argrefs[idx]
      end
      if not spec(argval) then
        return false
      end
    elseif (spec == nil or not util.deepcompare(argval, spec)) then
      return false
    end
  end

  for idx, spec in pairs(specs) do
    -- only check whether each element has an args counterpart,
    -- actual comparison has been done in first loop above
    local argval = args[idx]
    if argval == nil then
      -- no args counterpart, so try to compare using matcher
      if match.is_matcher(spec) then
        if not spec(argval) then
          return false
        end
      else
        return false
      end
    end
  end
  return true
end

-----------------------------------------------
-- Find matching arguments/return values in a saved list of
-- arguments/returned values.
-- @param invocations_list list of arguments/returned values to search (list of lists)
-- @param specs arguments/return values to match against argslist
-- @return the last matching arguments/returned values if a match is found, otherwise nil
function util.matchargs(invocations_list, specs)
  -- Search the arguments/returned values last to first to give the
  -- most helpful answer possible. In the cases where you can place
  -- your assertions between calls to check this gives you the best
  -- information if no calls match. In the cases where you can't do
  -- that there is no good way to predict what would work best.
  assert(not util.is_arglist(invocations_list), "expected a list of arglist-object, got an arglist")
  for ii = #invocations_list, 1, -1 do
    local val = invocations_list[ii]
    if matcharg(val.vals, val.refs, specs) then
      return val
    end
  end
  return nil
end

-----------------------------------------------
-- Find matching oncall for an actual call.
-- @param oncalls list of oncalls to search
-- @param args actual call argslist to match against
-- @return the first matching oncall if a match is found, otherwise nil
function util.matchoncalls(oncalls, args)
  for _, callspecs in ipairs(oncalls) do
    -- This lookup is done immediately on *args* passing into the stub
    -- so pass *args* as both *args* and *argsref* without copying
    -- either.
    if matcharg(args, args, callspecs.vals) then
      return callspecs
    end
  end
  return nil
end

-----------------------------------------------
-- table.insert() replacement that respects nil values.
-- The function will use table field 'n' as indicator of the
-- table length, if not set, it will be added.
-- @param t table into which to insert
-- @param pos (optional) position in table where to insert. NOTE: not optional if you want to insert a nil-value!
-- @param val value to insert
-- @return No return values
function util.tinsert(...)
  -- check optional POS value
  local args = {...}
  local c = select('#',...)
  local t = args[1]
  local pos = args[2]
  local val = args[3]
  if c < 3 then
    val = pos
    pos = nil
  end
  -- set length indicator n if not present (+1)
  t.n = (t.n or #t) + 1
  if not pos then
    pos = t.n
  elseif pos > t.n then
    -- out of our range
    t[pos] = val
    t.n = pos
  end
  -- shift everything up 1 pos
  for i = t.n, pos + 1, -1 do
    t[i]=t[i-1]
  end
  -- add element to be inserted
  t[pos] = val
end
-----------------------------------------------
-- table.remove() replacement that respects nil values.
-- The function will use table field 'n' as indicator of the
-- table length, if not set, it will be added.
-- @param t table from which to remove
-- @param pos (optional) position in table to remove
-- @return No return values
function util.tremove(t, pos)
  -- set length indicator n if not present (+1)
  t.n = t.n or #t
  if not pos then
    pos = t.n
  elseif pos > t.n then
    local removed = t[pos]
    -- out of our range
    t[pos] = nil
    return removed
  end
  local removed = t[pos]
  -- shift everything up 1 pos
  for i = pos, t.n do
    t[i]=t[i+1]
  end
  -- set size, clean last
  t[t.n] = nil
  t.n = t.n - 1
  return removed
end

-----------------------------------------------
-- Checks an element to be callable.
-- The type must either be a function or have a metatable
-- containing an '__call' function.
-- @param object element to inspect on being callable or not
-- @return boolean, true if the object is callable
function util.callable(object)
  return type(object) == "function" or type((debug.getmetatable(object) or {}).__call) == "function"
end
-----------------------------------------------
-- Checks an element has tostring.
-- The type must either be a string or have a metatable
-- containing an '__tostring' function.
-- @param object element to inspect on having tostring or not
-- @return boolean, true if the object has tostring
function util.hastostring(object)
  return type(object) == "string" or type((debug.getmetatable(object) or {}).__tostring) == "function"
end

-----------------------------------------------
-- Find the first level, not defined in the same file as the caller's
-- code file to properly report an error.
-- @param level the level to use as the caller's source file
-- @return number, the level of which to report an error
function util.errorlevel(level)
  local level = (level or 1) + 1 -- add one to get level of the caller
  local info = debug.getinfo(level)
  local source = (info or {}).source
  local file = source
  while file and (file == source or source == "=(tail call)") do
    level = level + 1
    info = debug.getinfo(level)
    source = (info or {}).source
  end
  if level > 1 then level = level - 1 end -- deduct call to errorlevel() itself
  return level
end

local namespace = require 'luassert.namespaces'
-----------------------------------------------
-- Extract modifier and namespace keys from list of tokens.
-- @param nspace the namespace from which to match tokens
-- @param tokens list of tokens to search for keys
-- @return table, list of keys that were extracted
function util.extract_keys(nspace, tokens)

  -- find valid keys by coalescing tokens as needed, starting from the end
  local keys = {}
  local key = nil
  local i = #tokens
  while i > 0 do
    local token = tokens[i]
    key = key and (token .. '_' .. key) or token

    -- find longest matching key in the given namespace
    local longkey = i > 1 and (tokens[i-1] .. '_' .. key) or nil
    while i > 1 and longkey and namespace[nspace][longkey] do
      key = longkey
      i = i - 1
      token = tokens[i]
      longkey = (token .. '_' .. key)
    end

    if namespace.modifier[key] or namespace[nspace][key] then
      table.insert(keys, 1, key)
      key = nil
    end
    i = i - 1
  end

  -- if there's anything left we didn't recognize it
  if key then
    error("luassert: unknown modifier/" .. nspace .. ": '" .. key .."'", util.errorlevel(2))
  end

  return keys
end

-----------------------------------------------
-- store argument list for return values of a function in a table.
-- The table will get a metatable to identify it as an arglist
function util.make_arglist(...)
  local arglist = { ... }
  arglist.n = select('#', ...) -- add values count for trailing nils
  return setmetatable(arglist, arglist_mt)
end

-----------------------------------------------
-- check a table to be an arglist type.
function util.is_arglist(object)
  return getmetatable(object) == arglist_mt
end

return util
