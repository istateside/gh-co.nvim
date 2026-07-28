local FS = require('gh-co.fs')

local CO = {}

local function isComment(pathPattern)
  return string.match(pathPattern, '#') ~= nil
end

local function buildEscapedPattern(rawPattern)
  -- Escape Lua pattern special characters except *
  local escaped = string.gsub(rawPattern, "([%-%+%?%(%)])", "%%%1")

  -- Handle ** first (before single *) - use placeholder to avoid conflicts
  escaped = string.gsub(escaped, "%*%*", "__DOUBLESTAR__")

  -- Convert remaining * to match any character except /
  escaped = string.gsub(escaped, "%*", "[^/]*")

  -- Replace placeholder with pattern that matches any path including /
  escaped = string.gsub(escaped, "__DOUBLESTAR__", ".*")

  -- Special handling for **/name patterns - they should match directories.
  -- Exclude **/* (trailing segment is a literal "*", not a directory name) -
  -- that's a glob wildcard and must not get the directory-only trailing slash.
  if string.match(rawPattern, "%*%*/[^/*]+$") then
    -- **/logs should match files within logs directories
    escaped = escaped .. "/"
  end

  -- Handle trailing slash - directory patterns should match everything within
  if string.match(escaped, "/$") then
    -- Remove trailing slash and match anything that starts with this path
    escaped = string.gsub(escaped, "/$", "/")
    -- Don't anchor with $ - allow matching subdirectories
  elseif not string.match(escaped, "^/") then
    -- Anchor non-directory patterns to match exactly
    escaped = escaped .. "$"
  end

  return escaped
end

-- `**` means "zero or more path segments" in gitignore/minimatch glob syntax
-- (e.g. `a/**/b` must match `a/b` too). buildEscapedPattern always keeps both
-- slashes flanking the `.*` it substitutes for `**` as literal, mandatory
-- characters, so it can only represent the "one or more segments" case - two
-- literal slashes can never be adjacent in a real file path. This derives the
-- zero-segment variant of an already-built pattern by dropping the flanking
-- slash that would otherwise vanish, so callers can try both.
local function buildZeroSegmentVariant(escaped)
  if string.match(escaped, "^%.%*/") then
    return (string.gsub(escaped, "^%.%*/", "", 1))
  end

  local collapsed, replacements = string.gsub(escaped, "/%.%*/", "/", 1)
  if replacements > 0 then
    return collapsed
  end

  return nil
end

-- matches file path substrings
local function isMatch(filePath, pathPattern)
  if pathPattern == nil or pathPattern == "" then return false end
  if isComment(pathPattern) then return false end

  local pattern = buildEscapedPattern(pathPattern)
  if string.match(filePath, pattern) ~= nil then return true end

  if string.find(pathPattern, "**", 1, true) then
    local zeroSegmentPattern = buildZeroSegmentVariant(pattern)
    if zeroSegmentPattern ~= nil then
      return string.match(filePath, zeroSegmentPattern) ~= nil
    end
  end

  return false
end

-- Detects `*` pattern (global match - only exact "*")
local function isGlobalMatch(pathPattern)
  if pathPattern == nil or pathPattern == "" then return false end
  if isComment(pathPattern) then return false end

  return pathPattern == "*"
end

local function collectCodeowners(group)
  local list = {}

  for i = 2, #group, 1 do
    table.insert(list, group[i])
  end

  return list
end

local function sortMatches(matches)
  table.sort(matches, function(a, b)
    return #a.pathPattern > #b.pathPattern
  end)
end

local function containsValue(list, value)
  for i = 1, #list do
    if list[i] == value then return true end
  end

  return false
end

local function mapCodeowners(matches)
  local list = {}

  for _, item in ipairs(matches) do
    for _, owner in ipairs(item.codeowners) do
      if containsValue(list, owner) == false then
        table.insert(list, owner)
      end
    end
  end

  return list
end

CO.matchFilesToCodeowner = function(filePaths)
  local lines = FS.openCodeownersFileAsLines()

  local matches = {}
  local globalCodeowners = nil
  for line, _, __ in lines do
    local split = vim.split(line, " ")
    local pathPattern = split[1]

    for _, filePath in ipairs(filePaths) do
      if isGlobalMatch(pathPattern) then
        globalCodeowners = collectCodeowners(split)
      elseif isMatch(filePath, pathPattern) then
        table.insert(matches, { pathPattern = pathPattern, codeowners = collectCodeowners(split) })
      end
    end
  end

  if #matches == 0 and globalCodeowners ~= nil and #globalCodeowners ~= 0 then return globalCodeowners end
  if #matches == 0 then return {} end

  sortMatches(matches)

  -- Only use the most specific pattern(s) - those with the longest pathPattern
  local maxLength = #matches[1].pathPattern
  local mostSpecificMatches = {}
  for _, match in ipairs(matches) do
    if #match.pathPattern == maxLength then
      table.insert(mostSpecificMatches, match)
    else
      break -- Since sorted by length, we can break early
    end
  end

  local codeownersList = mapCodeowners(mostSpecificMatches)
  return codeownersList
end

return CO
