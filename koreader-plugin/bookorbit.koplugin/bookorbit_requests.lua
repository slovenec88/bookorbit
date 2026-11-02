local Device = require("device")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template

local BoardMetrics = require("bookorbit_board_metrics")
local BoardUI = require("bookorbit_board_ui")
local DialogUI = require("bookorbit_dialog_ui")
local MenuPage = require("bookorbit_menu_page")
local MenuUI = require("bookorbit_menu_ui")
local TextEntry = require("bookorbit_text_entry")
local Toast = require("bookorbit_toast")

local px = BoardMetrics.px
local text, vstack, hstack, space, flex = BoardUI.text, BoardUI.vstack, BoardUI.hstack, BoardUI.space, BoardUI.flex
local Requests = {}

local STATUS = {
    pending = _("Awaiting approval"), approved = _("Approved"), rejected = _("Rejected"),
    cancelled = _("Cancelled"), searching = _("Searching"), grabbed = _("Queued for download"),
    downloading = _("Downloading"), importing = _("Importing"), needs_review = _("Needs review"),
    available = _("Available"), failed = _("Failed"),
}
local CANCELLABLE = { pending = true, approved = true, searching = true, grabbed = true,
    downloading = true, importing = true, needs_review = true, failed = true }
local FIELDS = {
    { key = "title", label = _("Title"), limit = 500 },
    { key = "author", label = _("Author"), limit = 255 },
    { key = "language", label = _("Language"), hint = _("Language code, e.g. en"), limit = 20 },
    { key = "note", label = _("Note"), limit = 2000 },
}

local function textLength(value)
    local _text, count = value:gsub("[^\128-\191]", "")
    return count
end

function Requests.payload(draft)
    if type(draft.title) ~= "string" or not draft.title:find("%S") then return nil, _("Enter a title.") end
    if draft.mediaKind ~= "ebook" and draft.mediaKind ~= "audiobook" and draft.mediaKind ~= "both" then
        return nil, _("Choose ebook, audiobook or both.")
    end
    local result = { title = draft.title, mediaKind = draft.mediaKind }
    for _i, field in ipairs(FIELDS) do
        local value = draft[field.key]
        if value and value ~= "" then
            if textLength(value) > field.limit then return nil, T(_("%1 is too long."), field.label) end
            if field.key == "author" then result.authors = { value }
            else result[field.key] = value end
        end
    end
    if draft.mediaKind == "both" then
        result.mediaKind = nil
        if draft.targetLibraryId then
            result.ebook = { targetLibraryId = draft.targetLibraryId }
            result.audiobook = { targetLibraryId = draft.targetLibraryId }
        end
    else
        result.targetLibraryId = draft.targetLibraryId
    end
    return result
end

function Requests.canCancel(item, user_id)
    return item.userId == user_id and CANCELLABLE[item.status] == true
end

local function medium(kind)
    return kind == "both" and _("Ebook and audiobook") or kind == "audiobook" and _("Audiobook") or kind == "ebook" and _("Ebook") or tostring(kind or "")
end

local function summary(item)
    return medium(item.mediaKind) .. " · " .. (STATUS[item.status] or tostring(item.status or ""))
end

local function active(page)
    local client = page.catalog.client
    if page.closed then return false end
    if not page.plugin:isLoggedIn() or not client or client.server_url ~= page.client.server_url
            or client.username ~= page.client.username or client.userkey ~= page.client.userkey then
        page:close()
        return false
    end
    return true
end

local function failure(page, err, body)
    if err == "cancelled" then return end
    local message = type(body) == "table" and body.message
    if type(message) == "table" then message = table.concat(message, "\n") end
    if err == 404 and not page.user_id then message = _("Update the BookOrbit server to use requests from KOReader.")
    elseif err == 403 then message = message or _("Book requests are not enabled for your account.") end
    DialogUI.notice{ title = _("Request failed"), text = type(message) == "string" and message or page.catalog:errorText(err) }
end

-- A page owns one login; an old response cannot populate a different account.
local function run(page, label, call, done)
    if not active(page) or page.busy then return end
    page.catalog:runConnected(function()
        if not active(page) or page.busy then return end
        page.busy = true
        local body, err, errbody = page.catalog:fetch(label, call)
        page.busy = false
        if not active(page) then return end
        if body then done(body) else
            if not page.user_id then page:close() end
            failure(page, err, errbody)
        end
    end)
end

local function loadList(page, index, filter)
    run(page, _("Loading your requests…"), function()
        return page.client:myBookRequests{ page = index, limit = page.limit, mediaKind = filter, sortBy = "createdAt", sortDir = "desc" }
    end, function(body)
        local last = math.max(1, math.ceil((body.total or 0) / page.limit))
        if index > last then loadList(page, last, filter) return end
        page.view, page.index, page.filter, page.items, page.total = "list", index, filter, body.items or {}, body.total or 0
        page:refresh()
    end)
end

local function loadDetail(page, id)
    run(page, _("Loading request…"), function() return page.client:bookRequest(id) end, function(body)
        page.view, page.item = "detail", body
        page:refresh()
    end)
end

local function formRows(page, w)
    local rows, iw = {}, MenuUI.rowsIn(w)
    for index, field in ipairs(FIELDS) do
        table.insert(rows, MenuUI.row(iw, { label = field.label, sub = page.draft[field.key] ~= "" and page.draft[field.key] or _("Tap to enter"),
            sub_data = true, chevron = true, h = 54, action = { kind = "field", index = index } }))
    end
    table.insert(rows, MenuUI.row(iw, { label = _("Destination library"), sub = page.draft.libraryName or _("Use BookOrbit default"),
        sub_data = true, chevron = true, h = 54, action = { kind = "library" } }))
    return MenuUI.group(w, rows)
end

local function pager(w, index, count, kind)
    return hstack({ w = w }, {
        MenuUI.iconButton("chevron-left", index > 1 and { kind = kind, delta = -1 } or nil), flex(0),
        text(T(_("%1 of %2"), index, count), { s = 14 }), flex(0),
        MenuUI.iconButton("chevron-right", index < count and { kind = kind, delta = 1 } or nil),
    })
end

local function build(page, sw, sh)
    local mx = MenuUI.mx()
    local w = sw - 2 * mx
    local title = page.view == "form" and _("New request") or page.view == "libraries" and _("Destination library")
        or page.view == "detail" and _("Request details") or _("My requests")
    local can_refresh = page.user_id and (page.view == "list" or page.view == "detail")
    local items = { MenuUI.pageHeader(w, title, { right = can_refresh and MenuUI.iconButton("refresh-cw", { kind = "refresh" }) or nil }) }
    if not page.user_id then
        table.insert(items, text(_("Checking request access…"), { s = 16, w = w }))
    elseif page.view == "libraries" then
        local rows, iw = {}, MenuUI.rowsIn(w)
        local first = (page.library_index - 1) * page.limit + 1
        for index = first, math.min(first + page.limit - 1, #page.libraries + 1) do
            local library = page.libraries[index - 1]
            table.insert(rows, MenuUI.row(iw, { label = library and library.name or _("Use BookOrbit default"), data = true,
                radio = page.draft.targetLibraryId == (library and library.id), action = { kind = "library-pick", index = index } }))
        end
        table.insert(items, MenuUI.group(w, rows))
        table.insert(items, space(nil, px(8)))
        table.insert(items, flex(0))
        table.insert(items, pager(w, page.library_index, math.ceil((#page.libraries + 1) / page.limit), "library-page"))
    elseif page.view == "form" then
        table.insert(items, MenuUI.segmented(w, { _("Ebook"), _("Audiobook"), _("Both") }, page.draft.mediaKind == "both" and 3 or page.draft.mediaKind == "ebook" and 1 or 2,
            function(index) return { kind = "medium", index = index } end))
        table.insert(items, space(nil, px(8)))
        table.insert(items, formRows(page, w))
        table.insert(items, space(nil, px(12)))
        table.insert(items, MenuUI.pill(page.can_self_fulfil and _("Request & choose release") or _("Submit request"), { w = w, action = { kind = "submit" } }))
    elseif page.view == "detail" then
        local item = page.item
        table.insert(items, text(item.title, { s = 20, b = true, w = w, lines = 2, data = true }))
        table.insert(items, text(table.concat(item.authors or {}, ", "), { s = 14, w = w, lines = 1, data = true }))
        table.insert(items, space(nil, px(10)))
        table.insert(items, text(summary(item), { s = 16, b = true, w = w }))
        table.insert(items, text(T(_("Requested: %1"), (item.createdAt or ""):sub(1, 10)), { s = 13, w = w }))
        if item.language then table.insert(items, text(T(_("Language: %1"), item.language), { s = 13, w = w, data = true })) end
        local notes = {}
        for _i, entry in ipairs({ { _("Note"), item.note }, { _("Decision"), item.decisionNote }, { _("Status details"), item.statusReason } }) do
            if entry[2] then table.insert(notes, entry[1] .. "\n" .. entry[2]) end
        end
        if #notes > 0 then
            table.insert(items, space(nil, px(12)))
            local label = _("Notes & status details")
            table.insert(items, MenuUI.group(w, { MenuUI.row(MenuUI.rowsIn(w), { label = label,
                sub = item.statusReason or item.decisionNote or item.note, sub_data = true, chevron = true,
                action = { kind = "read", title = label, text = table.concat(notes, "\n\n") } }) }))
        end
        table.insert(items, space(nil, px(12)))
        local actions = {}
        local can_drive = require("bookorbit_request_releases").canDrive(item, page.user_id, page.can_manage, page.can_self_fulfil)
        if can_drive and item.status ~= "pending" and item.status ~= "cancelled" and item.status ~= "rejected" and item.status ~= "available" then
            local choosing = item.status == "approved" or item.status == "searching" or item.status == "failed"
            table.insert(actions, MenuUI.pill(choosing and _("Find releases") or _("Download & review"), { w = w, action = { kind = "releases" } }))
        end
        if item.status == "available" and item.matchedBookId and item.mediaKind == "ebook" then
            table.insert(actions, MenuUI.pill(_("Open in library"), { w = w, action = { kind = "open-book" } }))
        elseif item.status == "available" and item.mediaKind == "audiobook" then
            table.insert(actions, text(_("Listen in BookOrbit on the web or in the app."), { s = 14, w = w, lines = 2 }))
        end
        if Requests.canCancel(item, page.user_id) then
            table.insert(actions, MenuUI.pill(_("Cancel request"), { w = w, action = { kind = "cancel" } }))
        elseif item.userId ~= page.user_id and item.fulfillerUserId ~= page.user_id then
            table.insert(actions, MenuUI.pill(_("Leave request"), { w = w, action = { kind = "leave" } }))
        end
        for index, action in ipairs(actions) do
            if index > 1 then table.insert(items, space(nil, px(8))) end
            table.insert(items, action)
        end
    else
        table.insert(items, hstack({ w = w, gap = px(12) }, {
            MenuUI.pill(_("New request"), { w = math.floor((w - px(12)) / 2), action = { kind = "new" } }),
            MenuUI.pill(page.filter and medium(page.filter) or _("All types"), { w = math.floor((w - px(12)) / 2), action = { kind = "filter" } }),
        }))
        table.insert(items, space(nil, px(8)))
        local rows, iw = {}, MenuUI.rowsIn(w)
        for _, item in ipairs(page.items) do
            table.insert(rows, MenuUI.row(iw, { label = item.title, data = true, sub = summary(item), chevron = true, h = 60,
                action = { kind = "detail", id = item.id } }))
        end
        if #rows == 0 then table.insert(items, text(_("No requests yet."), { s = 16, w = w }))
        else table.insert(items, MenuUI.group(w, rows)) end
        table.insert(items, space(nil, px(8)))
        table.insert(items, flex(0))
        local count = math.max(1, math.ceil(page.total / page.limit))
        table.insert(items, pager(w, page.index, count, "page"))
    end
    return vstack({ w = sw, h = sh, pad = { px(6), mx, px(8), mx } }, items)
end

local function edit(page, index)
    local field = FIELDS[index]
    TextEntry.open{ title = field.label, hint = field.hint, icon = "pencil", value = page.draft[field.key], allow_empty = field.key ~= "title",
        validate = function(value)
            if textLength(value) > field.limit then return T(_("Use at most %1 characters."), field.limit) end
        end,
        on_submit = function(value)
            if not active(page) then return end
            page.draft[field.key] = value
            page:refresh()
        end,
    }
end

local function act(page, action)
    if not active(page) then return true end
    local kind = action.kind
    if kind == "back" then
        if page.busy or page.view == "list" then page:close()
        elseif page.view == "libraries" then page.view = "form" page:refresh()
        else page.view = "list" page:refresh() loadList(page, page.index, page.filter) end
        return true
    end
    if page.busy or not page.user_id then return true end
    if kind == "new" then
        page.view = "form"
        page:refresh()
    elseif kind == "medium" then
        page.draft.mediaKind = ({ "ebook", "audiobook", "both" })[action.index]
        page:refresh()
    elseif kind == "field" then edit(page, action.index)
    elseif kind == "library" then
        page.view, page.library_index = "libraries", 1
        page:refresh()
    elseif kind == "library-page" then
        page.library_index = math.max(1, math.min(math.ceil((#page.libraries + 1) / page.limit), page.library_index + action.delta))
        page:refresh()
    elseif kind == "library-pick" then
        local library = page.libraries[action.index - 1]
        page.draft.targetLibraryId, page.draft.libraryName = library and library.id, library and library.name
        page.view = "form"
        page:refresh()
    elseif kind == "filter" then
        DialogUI.choose{ title = _("Request type"), options = { { label = _("All types") }, { label = _("Ebook") }, { label = _("Audiobook") } },
            on_pick = function(index)
                if not active(page) then return end
                loadList(page, 1, ({ [2] = "ebook", [3] = "audiobook" })[index])
            end }
    elseif kind == "detail" then loadDetail(page, action.id)
    elseif kind == "refresh" then
        if page.view == "detail" then loadDetail(page, page.item.id) else loadList(page, page.index, page.filter) end
    elseif kind == "page" then
        local index = page.index + action.delta
        if index >= 1 and index <= math.max(1, math.ceil(page.total / page.limit)) then loadList(page, index, page.filter) end
    elseif kind == "read" then
        require("bookorbit_text_pages").about({ title = action.title }, action.text)
    elseif kind == "releases" then
        local picker = require("bookorbit_request_releases")
        if picker.canDrive(page.item, page.user_id, page.can_manage, page.can_self_fulfil) then
            picker.open(page, { run = run, active = active })
        end
    elseif kind == "submit" then
        local media_kind = page.draft.mediaKind
        local payload, problem = Requests.payload(page.draft)
        if not payload then Toast.error(problem) return true end
        if page.can_self_fulfil then payload.selfServe = true end
        DialogUI.confirm{ title = _("Submit request?"), text = payload.title .. "\n" .. medium(media_kind)
            .. (page.can_self_fulfil and "\n" .. _("You will choose the release to download.") or ""), ok_label = _("Request"), on_ok = function()
            run(page, _("Submitting request…"), function()
                if media_kind == "both" then return page.client:submitBookRequestPair(payload) end
                return page.client:submitBookRequest(payload)
            end, function(body)
                page.draft = { title = "", author = "", language = "", note = "", mediaKind = media_kind }
                if media_kind == "both" then
                    page.view = "list"
                    page:refresh()
                    loadList(page, 1)
                    Toast.show(_("Ebook and audiobook requested"))
                else
                    page.view, page.item = "detail", body.request
                    page:refresh()
                    Toast.show(body.subscribed and _("Joined the existing request") or _("Request submitted"))
                end
            end)
        end }
    elseif kind == "cancel" or kind == "leave" then
        local id = page.item.id
        DialogUI.confirm{ title = kind == "cancel" and _("Cancel request?") or _("Leave request?"), text = page.item.title,
            ok_label = kind == "cancel" and _("Cancel request") or _("Leave"), on_ok = function()
                run(page, _("Updating request…"), function()
                    if kind == "cancel" then return page.client:cancelBookRequest(id) end
                    return page.client:leaveBookRequest(id)
                end, function(body)
                    if kind == "cancel" then page.item = body page:refresh()
                    else loadList(page, 1, page.filter) end
                end)
            end }
    elseif kind == "open-book" then
        local id = page.item.matchedBookId
        page:close()
        page.catalog:loadBookDetail(id)
    end
    return true
end

function Requests.open(plugin, catalog)
    local client = catalog.client
    local page = MenuPage:new{
        name = "bookorbit_requests", plugin = plugin, catalog = catalog, client = client,
        view = "list", index = 1, items = {}, total = 0, libraries = {},
        limit = math.max(1, math.min(20, math.floor((Device.screen:getHeight() - px(230)) / px(62)))),
        draft = { title = "", author = "", language = "", note = "", mediaKind = "ebook" },
        build = build, on_action = act,
        on_back = function(self) act(self, { kind = "back" }) return true end,
        on_page_key = function(self, delta)
            if self.view == "list" then act(self, { kind = "page", delta = delta })
            elseif self.view == "libraries" then act(self, { kind = "library-page", delta = delta }) end
        end,
    }
    UIManager:show(page, "ui")
    run(page, _("Checking request access…"), function() return client:requestAccess() end, function(body)
        page.user_id, page.libraries = body.userId, body.libraries or {}
        page.can_manage, page.can_self_fulfil = body.canManageRequests == true, body.canSelfFulfil == true
        loadList(page, 1)
    end)
    return page
end

return Requests
