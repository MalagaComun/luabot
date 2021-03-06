#! /usr/bin/env lua
--
-- github.lua
-- Copyright (C) 2016 Adrian Perez <aperez@igalia.com>
--
-- Distributed under terms of the MIT license.
--

local template = require "util.strutil" .template
local decode   = require "util.json" .decode
local jsonnull = require "util.json" .null
local hmac     = require "util.sha1" .hmac
local stanza   = require "util.stanza"
local jid      = require "util.jid"


local format_render = {}
local format_data = {}
local function format(name, text, func)
   format_render[name] = template(text)
   format_data[name] = func
end


local shorten_pattern = "[^%s]+"
local function shorten(text, wordcount)
   wordcount = wordcount or 15
   local words = {}
   for word in text:gmatch(shorten_pattern) do
      if #words >= wordcount then
         words[#words + 1] = " […]"
         break
      end
      words[#words + 1] = word
   end
   return table.concat(words, " ")
end


format("create",
   "[%{repository.name}] %{ref_type} '%{ref}' created by @%{sender.login}")

format("delete",
   "[%{repository.name}] %{ref_type} '%{ref}' deleted by @%{sender.login}")

format("member",
   "[%{repository.name}] @%{sender.login} %{action} collaborator @%{member.login}")

format("pull_request",
   "[%{repository.name}] @%{sender.login} %{action} pull request #%{number}: " ..
   "%{pull_request.title}%{extra} — %{pull_request.html_url}",
   function (data)
      data.extra = (data.action == "assigned") and " to @" .. data.pull_request.assignee.login or ""
      if data.action == "edited" then
         local changes = {}
         if data.changes.title then
            changes[#changes + 1] = "title"
         end
         if data.changes.body then
            changes[#changes + 1] = "description"
         end
         if #changes > 0 then
            data.extra = data.extra .. " (" .. table.concat(changes, ", ") .. ")"
         end
      elseif data.action == "synchronize" then
         data.action = "synchronized"
      end
   end)

format("pull_request_review_comment",
   "[%{repository.name}] @%{sender.login} %{action} comment on pull request " ..
   "#%{pull_request.number}: %{pull_request.title} (%{pull_request.state}) " ..
   "“%{comment.short_body}” — %{comment.html_url}",
   function (data)
      data.comment.short_body = shorten(data.comment.body)
   end)

format("issues",
   "[%{repository.name}] @%{sender.login} %{action} #%{issue.number}: " ..
   "%{issue.title}%{extra} — %{issue.html_url}",
   function (data)
      if data.action == "assigned" or data.action == "unassigned" then
         data.extra = " (owner: @" .. data.assignee.login .. ")"
      elseif data.action == "labeled" or data.action == "unlabeled" then
         data.extra = " (label: " .. data.label.name .. ")"
      elseif data.action == "edited" then
         local changes = {}
         if data.changes.title then
            changes[#changes + 1] = "title"
         end
         if data.changes.body then
            changes[#changes + 1] = "description"
         end
         if #changes > 0 then
            data.extra = " (" .. table.concat(changes, ", ") .. ")"
         end
      else
         data.extra = ""
      end
   end)

format("issue_comment",
   "[%{repository.name}] @%{sender.login} %{action} comment on #%{issue.number}: " ..
   "%{issue.title} “%{comment.short_body}” (%{issue.state}) — %{comment.html_url}",
   function (data)
      data.comment.short_body = shorten(data.comment.body)
   end)

format("push",
   "[%{repository.name}] @%{pusher.name} pushed %{size} commits to %{short_ref} — %{compare}",
   function (data)
      local last_component
      for component in data.ref:gmatch("[^/]+") do
         last_component = component
      end
      data.short_ref = last_component
      data.size = data.size or #data.commits
   end)

format("status",
   "[%{short_name}] Testing %{state}: %{short_sha} “%{commit_title}” " ..
   "by @%{commit.author.login} (%{context})%{optional_url}",
   function (data)
      data.short_sha = data.sha:sub(1, 7)
      for component in data.name:gmatch("[^/]+") do
         -- Pick the last component of the repository name
         data.short_name = component
      end
      for line in data.commit.commit.message:gmatch("[^\n]+") do
         -- Pick the first commit message line only
         data.commit_title = line
         break
      end
      if data.target_url ~= jsonnull then
         data.optional_url = " — " .. data.target_url
      else
         data.optional_url = ""
      end
   end)


local function make_stanza(bot, room, body)
   local bot_jid = bot.rooms[room.jid]
end

local function handle_webhook(bot, room, request, response)
   local secret = bot:get_config("github", "webhook", {}, room.jid).secret
   if secret and request.headers.x_hub_signature then
      local calculated = "sha1=" .. hmac(secret, request.body)
      -- TODO: Use a timing-safe comparison function.
      if request.headers.x_hub_signature ~= calculated then
         return 401  -- Unauthorized
      end
   end

   local event = request.headers.x_github_event
   if not event then
      return 400  -- Bad Request
   end

   response:send()  -- Signal the request as accepted early

   bot:debug("github: webhook event=" .. event)
   bot:debug("github: webhook payload:\n" .. request.body)

   if not format_render[event] then
      bot:warn("github: no formatter for event: " .. event)
      return
   end

   local data = decode(request.body)
   if format_data[event] then
      format_data[event](data)
   end

   local attr = { from = bot.rooms[room.jid].nick }
   local body = format_render[event](data)
   room:send(stanza.message(attr, body))
end

return function (bot)
   bot:hook("groupchat/joined", function (room)
      local webhook = bot:get_config("github", "webhook", {}, room.jid)
      if webhook.repo then
         bot:add_plugin("httpevent")
         bot:debug("github: webhook listener for " .. webhook.repo)
         bot:hook("http/post/github/" .. webhook.repo, function (event)
            return handle_webhook(bot, room, event.request, event.response)
         end)
      end
   end)
end
