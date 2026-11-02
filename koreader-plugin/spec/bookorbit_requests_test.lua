package.path = "koreader-plugin/bookorbit.koplugin/?.lua;" .. package.path

local screen = { w = 600, h = 800 }
local shown, notices, toasts, confirms, choices, entries = {}, {}, {}, {}, {}, {}
local read_pages = {}
local Widget = {}
function Widget:new(o) return setmetatable(o or {}, { __index = self }) end
function Widget:extend(o) return setmetatable(o or {}, { __index = self }) end
function Widget:free() end
function Widget:getBaseline() return math.ceil((self.face and self.face.size or 14) * 1.05) end
function Widget:isTruncated() return self.max_width and #self.text * self.face.size * 0.5 > self.max_width end
function Widget:getSize()
    if self.dimen then return self.dimen end
    local kind = self.kind
    if kind == "hspan" then return { w = self.width or 0, h = 0 } end
    if kind == "vspan" then return { w = 0, h = self.width or 0 } end
    if kind == "text" then
        return { w = math.min(self.max_width or math.huge, #self.text * self.face.size * 0.5), h = math.ceil(self.face.size * 1.362) }
    end
    if kind == "textbox" then
        local line = math.floor(self.face.size * 1.3 + 0.5)
        return { w = self.width, h = self.height or line }
    end
    local w, h = 0, 0
    for _, child in ipairs(self) do
        local size = child:getSize()
        if kind == "horizontal" then w, h = w + size.w, math.max(h, size.h)
        elseif kind == "vertical" then w, h = math.max(w, size.w), h + size.h
        else w, h = math.max(w, size.w), math.max(h, size.h) end
    end
    local border = self.bordersize or 0
    return { w = w + 2 * border, h = h + 2 * border }
end
for name, kind in pairs({
    ["ui/geometry"] = "geom", ["ui/widget/container/centercontainer"] = "container",
    ["ui/widget/container/framecontainer"] = "container", ["ui/widget/container/leftcontainer"] = "container",
    ["ui/widget/container/rightcontainer"] = "container", ["ui/widget/container/widgetcontainer"] = "container",
    ["ui/widget/horizontalgroup"] = "horizontal", ["ui/widget/horizontalspan"] = "hspan",
    ["ui/widget/verticalgroup"] = "vertical", ["ui/widget/verticalspan"] = "vspan",
    ["ui/widget/overlapgroup"] = "container", ["ui/widget/widget"] = "container",
    ["ui/widget/textwidget"] = "text", ["ui/widget/textboxwidget"] = "textbox",
    ["ui/widget/iconwidget"] = "icon",
}) do package.loaded[name] = Widget:extend{ kind = kind } end
package.loaded["device"] = { screen = {
    getWidth = function() return screen.w end, getHeight = function() return screen.h end,
    getDPI = function() return 167 end,
} }
package.loaded["ffi/blitbuffer"] = {}
package.loaded["ui/font"] = { getFace = function(_, _, size) return { size = size } end }
package.loaded["ui/bidi"] = { auto = function(value) return value end }
package.loaded["ui/renderimage"] = {}
package.loaded["datastorage"] = {}
package.loaded["libs/libkoreader-lfs"] = {}
package.loaded["util"] = {}
package.loaded["bookorbit_board_icons"] = { widget = function(name, size) return Widget:new{ glyph = name, dimen = { w = size, h = size } } end }
package.loaded["gettext"] = function(value) return value end
package.loaded["ffi/util"] = { template = function(value, ...)
    local values = { ... }
    return (value:gsub("%%(%d+)", function(i) return tostring(values[tonumber(i)]) end))
end }
package.loaded["ui/uimanager"] = { show = function(_, page) table.insert(shown, page) end }
package.loaded["bookorbit_dialog_ui"] = {
    notice = function(o) table.insert(notices, o) end,
    confirm = function(o) table.insert(confirms, o) end,
    choose = function(o) table.insert(choices, o) end,
}
package.loaded["bookorbit_text_entry"] = { open = function(o) table.insert(entries, o) end }
package.loaded["bookorbit_text_pages"] = { about = function(_, value) table.insert(read_pages, value) end }
package.loaded["bookorbit_toast"] = {
    show = function(value) table.insert(toasts, value) end,
    error = function(value) table.insert(toasts, value) end,
}
package.loaded["bookorbit_menu_page"] = { new = function(_, o)
    function o:close() self.closed = true end
    function o:refresh() self.refreshes = (self.refreshes or 0) + 1 end
    return o
end }

local Metrics = require("bookorbit_board_metrics")
local BoardUI = require("bookorbit_board_ui")
local Requests = require("bookorbit_requests")
local function eq(a, b, message) assert(a == b, (message or "unexpected value") .. ": " .. tostring(a) .. " ~= " .. tostring(b)) end
local function actionRects(root)
    local result = {}
    local function walk(node, x, y)
        local size = node:getSize()
        if node.action then result[node.action.kind] = { x = x, y = y, w = size.w, h = size.h } end
        for _, child in ipairs(node) do
            walk(child, x, y)
            if node.kind == "horizontal" then x = x + child:getSize().w
            elseif node.kind == "vertical" then y = y + child:getSize().h end
        end
    end
    walk(root, 0, 0)
    return result
end
local function assertGap(root, first, second, horizontal)
    local rects = actionRects(root)
    local a, b = assert(rects[first], first), assert(rects[second], second)
    local gap = horizontal and b.x - a.x - a.w or b.y - a.y - a.h
    assert(gap >= Metrics.px(horizontal and 12 or 8), first .. " and " .. second .. " need separation")
end
local function hasGlyph(node, name)
    if node.glyph == name then return true end
    for _, child in ipairs(node) do if hasGlyph(child, name) then return true end end
    return false
end
local function fixture(options)
    options = options or {}
    local calls, deferred = {}, {}
    local client = { server_url = "https://book.test/api/v1", username = "me", userkey = "key" }
    local catalog = { client = client, defer = options.defer == true }
    local plugin = { logged_in = true, isLoggedIn = function(self) return self.logged_in end }
    local item = { id = 5, title = "My Book", authors = { "An Author" }, mediaKind = "ebook", userId = 7, status = "pending", createdAt = "2026-11-01" }
    function client:requestAccess()
        table.insert(calls, { "access" })
        if options.access_error then return nil, options.access_error, { message = "Access unavailable" } end
        return { userId = 7, libraries = { { id = 3, name = "Ebooks" } }, canManageRequests = options.manage, canSelfFulfil = options.self_fulfil }
    end
    function client:myBookRequests(query)
        table.insert(calls, { "list", query })
        if self.list_error then return nil, self.list_error, { message = "List unavailable" } end
        return self.list_body or { items = { item }, total = 50 }
    end
    function client:bookRequest(id) table.insert(calls, { "detail", id }); return self.by_id and self.by_id[id] or item end
    function client:submitBookRequest(payload) table.insert(calls, { "submit", payload }); return { request = item, subscribed = self.joined } end
    function client:submitBookRequestPair(payload)
        table.insert(calls, { "pair", payload })
        local audio = { id = 6, title = item.title, authors = item.authors, mediaKind = "audiobook", userId = 7, status = "approved", createdAt = item.createdAt }
        self.by_id = { [5] = item, [6] = audio }
        self.list_body = { items = { item, audio }, total = 2 }
        return { ebook = { request = item, subscribed = false }, audiobook = { request = audio, subscribed = true } }
    end
    function client:cancelBookRequest(id)
        table.insert(calls, { "cancel", id })
        local result = self.by_id and self.by_id[id] or item
        result.status = "cancelled"
        return result
    end
    function client:leaveBookRequest(id) table.insert(calls, { "leave", id }); return {} end
    function catalog:runConnected(fn) if self.defer then table.insert(deferred, fn) else fn() end end
    function catalog:fetch(_, fn)
        local body, err, detail = fn()
        if self.after_fetch then self.after_fetch() end
        return body, err, detail
    end
    function catalog:errorText(err) return tostring(err) end
    function catalog:loadBookDetail(id) self.opened = id end
    local page = Requests.open(plugin, catalog)
    local function act(kind, values)
        values = values or {}; values.kind = kind; page.on_action(page, values)
    end
    return page, act, client, catalog, plugin, item, calls, deferred
end

for _, kind in ipairs({ "ebook", "audiobook" }) do
    local payload = assert(Requests.payload{ title = "A Book", mediaKind = kind, author = "An Author", language = "en", note = "Please", targetLibraryId = 3 })
    eq(payload.mediaKind, kind); eq(payload.authors[1], "An Author"); eq(payload.language, "en"); eq(payload.note, "Please"); eq(payload.targetLibraryId, 3)
    assert(payload.author == nil and payload.libraryName == nil, "DTO accepts only whitelisted fields")
end
local default_pair = assert(Requests.payload{ title = "Both books", mediaKind = "both", author = "An Author", language = "en", note = "Please" })
assert(default_pair.mediaKind == nil and default_pair.targetLibraryId == nil)
assert(default_pair.ebook == nil and default_pair.audiobook == nil, "omit empty pair halves so rapidjson cannot encode them as arrays")
eq(default_pair.authors[1], "An Author"); eq(default_pair.language, "en"); eq(default_pair.note, "Please")
local explicit_pair = assert(Requests.payload{ title = "Both books", mediaKind = "both", targetLibraryId = 3 })
eq(explicit_pair.ebook.targetLibraryId, 3); eq(explicit_pair.audiobook.targetLibraryId, 3)
assert(explicit_pair.mediaKind == nil and explicit_pair.targetLibraryId == nil, "pair DTO has nested destinations and no mediaKind")
assert(not Requests.payload{ title = "  ", mediaKind = "ebook" })
assert(not Requests.payload{ title = "Book", mediaKind = "comic" })
assert(not Requests.payload{ title = string.rep("a", 501), mediaKind = "ebook" })
assert(not Requests.payload{ title = "Book", mediaKind = "ebook", note = string.rep("a", 2001) })
assert(Requests.payload{ title = string.rep("č", 500), mediaKind = "ebook", author = string.rep("é", 255), note = string.rep("📚", 2000) }, "Unicode limits count characters, not bytes")
assert(not Requests.payload{ title = string.rep("č", 501), mediaKind = "ebook" })
assert(not Requests.payload{ title = "Book", mediaKind = "ebook", author = string.rep("é", 256) })
assert(not Requests.payload{ title = "Book", mediaKind = "ebook", note = string.rep("📚", 2001) })
assert(Requests.canCancel({ userId = 7, status = "failed" }, 7))
assert(not Requests.canCancel({ userId = 8, status = "pending" }, 7))
assert(not Requests.canCancel({ userId = 7, status = "available" }, 7))

local page, act, client, catalog, plugin, item, calls, deferred = fixture()
eq(page.user_id, 7); eq(page.items[1].id, 5); eq(calls[2][2].page, 1)
act("page", { delta = -1 }); eq(#calls, 2, "page zero is refused")
act("page", { delta = 1 }); eq(page.index, 2)
page.on_page_key(page, -1); eq(page.index, 1)
act("filter"); choices[#choices].on_pick(3); eq(page.filter, "audiobook"); eq(page.index, 1); eq(calls[#calls][2].mediaKind, "audiobook")
act("new"); eq(page.view, "form")
act("field", { index = 1 }); entries[#entries].on_submit("A new title"); eq(page.draft.title, "A new title")
act("library"); eq(page.view, "libraries"); act("library-pick", { index = 2 }); eq(page.draft.targetLibraryId, 3); eq(page.view, "form")
act("medium", { index = 2 }); eq(page.draft.mediaKind, "audiobook")
act("submit"); eq(calls[#calls][1], "list", "confirmation precedes submission")
confirms[#confirms].on_ok(); eq(calls[#calls][1], "submit"); eq(calls[#calls][2].mediaKind, "audiobook"); eq(page.view, "detail")
eq(toasts[#toasts], "Request submitted"); eq(page.draft.title, "")
act("cancel"); confirms[#confirms].on_ok(); eq(item.status, "cancelled"); eq(calls[#calls][1], "cancel", "cancel response updates details without another request")
page.on_back(page); eq(page.view, "list")
client.joined = true; item.userId = 8
act("new"); page.draft.title = "Shared book"; act("submit"); confirms[#confirms].on_ok()
eq(toasts[#toasts], "Joined the existing request")
act("leave"); confirms[#confirms].on_ok(); eq(calls[#calls - 1][1], "leave"); eq(page.view, "list")
act("detail", { id = 5 }); item.status = "available"; item.matchedBookId = 99
act("refresh"); eq(calls[#calls][1], "detail"); eq(page.item.status, "available")
act("open-book"); eq(catalog.opened, 99); assert(page.closed)

page, act, client, catalog, plugin, item, calls, deferred = fixture()
page.filter = "audiobook"
act("new"); page.draft.title = "Both books"; act("medium", { index = 3 }); eq(page.draft.mediaKind, "both")
act("submit"); confirms[#confirms].on_ok()
eq(calls[#calls - 1][1], "pair"); eq(calls[#calls][1], "list")
eq(page.view, "list"); eq(page.filter, nil); eq(page.draft.mediaKind, "both"); eq(page.draft.title, "")
eq(#page.items, 2); eq(page.items[1].mediaKind, "ebook"); eq(page.items[2].mediaKind, "audiobook")
eq(page.items[1].status, "pending"); eq(page.items[2].status, "approved")
eq(toasts[#toasts], "Ebook and audiobook requested")
act("detail", { id = 5 }); act("cancel"); confirms[#confirms].on_ok()
eq(client.by_id[5].status, "cancelled"); eq(client.by_id[6].status, "approved", "cancelling the ebook does not cancel the audiobook")
act("detail", { id = 6 }); eq(page.item.id, 6)
client.by_id[6].status = "available"; act("refresh"); eq(page.item.status, "available")

page, act, client, catalog, plugin, item, calls, deferred = fixture()
client.list_body = { items = {}, total = 0 }; act("refresh"); eq(#page.items, 0)
client.list_error = 500; act("refresh"); eq(notices[#notices].text, "List unavailable"); assert(not page.busy)
client.list_error = nil
catalog.after_fetch = function() catalog.client = { server_url = client.server_url, username = "other", userkey = "other" } end
local prior = page.items
act("refresh"); assert(page.closed); assert(page.items == prior, "stale response must not publish into a new account")

page, act, client, catalog, plugin, item, calls, deferred = fixture()
catalog.defer = true
act("refresh")
page.on_back(page)
assert(page.closed, "Back must close a page even when a connection prompt never calls back")
for _, callback in ipairs(deferred) do callback() end

page, act, client, catalog, plugin, item, calls, deferred = fixture()
page.view, page.item = "detail", item
item.userId, item.fulfillerUserId = 8, 7
local _widget, hits = BoardUI.collectHits(function() return page.build(page, screen.w, screen.h) end)
for _, hit in ipairs(hits) do assert(hit.action.kind ~= "leave", "a fulfiller cannot unsubscribe from their active work") end
plugin.logged_in = false
local call_count = #calls
act("refresh"); assert(page.closed); eq(#calls, call_count, "logged-out pages never call the server")

page, act, client, catalog, plugin, item, calls, deferred = fixture()
client.list_error = 404
act("refresh"); eq(notices[#notices].text, "List unavailable", "missing request data is not an unsupported server")
client.list_error = 403
act("refresh"); eq(notices[#notices].text, "List unavailable")

page, act, client, catalog, plugin, item, calls, deferred = fixture{ access_error = 404 }
assert(page.closed)
eq(notices[#notices].text, "Update the BookOrbit server to use requests from KOReader.")

page, act, client, catalog, plugin, item, calls, deferred = fixture{ defer = true }
assert(not page.user_id)
act("new"); eq(page.view, "list", "a pending access check cannot open submission")
local _pending_widget, pending_hits = BoardUI.collectHits(function() return page.build(page, screen.w, screen.h) end)
for _, hit in ipairs(pending_hits) do eq(hit.action.kind, "back", "only Back is offered before access succeeds") end
act("submit"); eq(#calls, 0, "a pending access check cannot queue writes")
page.on_back(page); assert(page.closed)

page, act, client, catalog, plugin, item, calls, deferred = fixture()
act("filter"); choices[#choices].on_pick(2); eq(page.filter, "ebook")
local old_items, old_page = page.items, page.index
client.list_error = 500
act("filter"); choices[#choices].on_pick(3)
eq(page.filter, "ebook", "a failed filter fetch keeps the label matching the visible results")
eq(page.items, old_items); eq(page.index, old_page)

client.list_error = nil
act("filter"); choices[#choices].on_pick(3); eq(page.filter, "audiobook")
local paired_old_items = page.items
client.list_error = 500
act("new"); page.draft.title = "Both while refresh fails"; act("medium", { index = 3 }); act("submit"); confirms[#confirms].on_ok()
eq(page.view, "list"); eq(page.filter, "audiobook", "failed post-submit refresh keeps the filter matching old rows")
eq(page.items, paired_old_items); eq(toasts[#toasts], "Ebook and audiobook requested")

page, act, client, catalog, plugin, item, calls, deferred = fixture()
page.libraries = {}
for index = 1, 50 do page.libraries[index] = { id = index, name = "Library " .. index } end
act("new"); page.draft.title = "Keep the draft"; act("library")
page.on_back(page); eq(page.view, "form"); eq(page.draft.title, "Keep the draft")
act("library")
local last_library_page = math.ceil(51 / page.limit)
for index = 2, last_library_page do page.on_page_key(page, 1) end
eq(page.library_index, last_library_page)
local _libraries_widget, library_hits = BoardUI.collectHits(function() return page.build(page, screen.w, screen.h) end)
local picks, last_pick = 0, false
for _, hit in ipairs(library_hits) do
    if hit.action.kind == "library-pick" then picks = picks + 1; last_pick = last_pick or hit.action.index == 51 end
end
assert(picks <= page.limit and last_pick, "library choices are bounded and the last destination is reachable")
act("library-pick", { index = 51 }); eq(page.draft.targetLibraryId, 50); eq(page.view, "form")
act("library"); act("library-pick", { index = 1 }); eq(page.draft.targetLibraryId, nil)

local layouts = 0
for _, dimensions in ipairs({ { 600, 800 }, { 800, 600 } }) do
    screen.w, screen.h = dimensions[1], dimensions[2]
    for _, scale in ipairs(Metrics.UI_SCALES) do
        Metrics.setUserScale(scale)
        page, act, client, catalog, plugin, item = fixture()
        for _, scenario in ipairs({ "list", "form", "libraries", "detail", "available-audiobook", "available-ebook" }) do
            local view = scenario:find("available") and "detail" or scenario
            page.view = view
            if view == "list" then
                page.items = {}
                for index = 1, page.limit do page.items[index] = item end
            elseif view == "libraries" then
                page.libraries, page.library_index = {}, 1
                for index = 1, 100 do page.libraries[index] = { id = index, name = "Library " .. index } end
            elseif view == "detail" then
                page.item = item
                item.note, item.decisionNote, item.statusReason, item.language = "A note", "A decision", "A status reason", "en"
                item.status = scenario:find("available") and "available" or "pending"
                item.mediaKind = scenario == "available-audiobook" and "audiobook" or "ebook"
                item.matchedBookId = 99
                item.userId = scenario:find("available") and 8 or 7
            end
            local fits, root, kind, detail = BoardUI.fits(function() return page.build(page, screen.w, screen.h) end)
            assert(fits, string.format("%s at %dx%d %.2fx: %s %s", scenario, screen.w, screen.h, scale, tostring(kind), tostring(detail)))
            if view == "list" then assertGap(root, "new", "filter", true) end
            layouts = layouts + 1
        end
    end
end
eq(layouts, 60)

package.loaded["ui/network/manager"] = { isConnected = function() return true end, isWifiOn = function() return true end }
package.loaded["datetime"] = { secondsToHour = function() return "12:00" end }
package.loaded["device"].getPowerDevice = function() return {} end
package.loaded["device"].hasBattery = function() return false end
G_reader_settings = { isTrue = function() return false end }
local MenuSheet = require("bookorbit_menu_sheet")
local actual_icons = assert(loadfile("koreader-plugin/bookorbit.koplugin/bookorbit_board_icons.lua"))()
assert(actual_icons.has("book-plus"))
local request_icon = assert(actual_icons.svg("book-plus", "#000000", 2))
assert(request_icon:find('d="M12 7v6"', 1, true) and request_icon:find('d="M9 10h6"', 1, true), "Requests icon renders the book's plus sign")
local menu_layouts = 0
for _, dimensions in ipairs({ { 600, 800 }, { 800, 600 } }) do
    screen.w, screen.h = dimensions[1], dimensions[2]
    for _, scale in ipairs(Metrics.UI_SCALES) do
        Metrics.setUserScale(scale)
        for _, from_list in ipairs({ false, true }) do
            local menu_catalog = { current_context = from_list and { kind = "books", title = "Books" } or {},
                dashboardCache = function() return { bookRequestAccess = true } end }
            local menu = MenuSheet.open({ settings = {}, PLUGIN_VERSION = "test", isLoggedIn = function() return true end }, menu_catalog, function() end)
            local root, menu_hits = BoardUI.collectHits(function() return menu.build(menu, screen.w, screen.h) end)
            local requests_count = 0
            for _, hit in ipairs(menu_hits) do
                if hit.action.kind == "link" and hit.action.link == "requests" then
                    requests_count = requests_count + 1
                    assert(hasGlyph(hit, "book-plus"), "Requests uses the web client's book-plus icon")
                end
                assert(hit.action.kind ~= "requests", "Requests belongs to Go to, not settings rows")
            end
            eq(requests_count, 1, "Go to offers Requests exactly once")
            assert(menu.panel_rect.y + menu.panel_rect.h <= screen.h,
                string.format("BookOrbit menu (%s) at %dx%d %.2fx exceeds screen: y%d+h%d", from_list and "books" or "home", screen.w, screen.h, scale, menu.panel_rect.y, menu.panel_rect.h))
            menu_layouts = menu_layouts + 1
        end
    end
end
eq(menu_layouts, 20)
for _, case in ipairs({ { 1.05, true, true }, { 1.15, false, true }, { 1.2, false, true }, { 1.2, true, false } }) do
    screen.w, screen.h = 800, 600
    Metrics.setUserScale(case[1])
    local menu_plugin = {
        settings = case[3] and { update_latest_version = "9.0.0" } or {},
        PLUGIN_VERSION = "2.1.1", isLoggedIn = function() return true end,
        hasKnownUpdate = function() return case[3] end,
        ui = case[2] and { document = {} } or nil,
        openBookTitle = function() return "A background book" end,
    }
    local menu = MenuSheet.open(menu_plugin, { current_context = { kind = "dashboard" }, dashboardMode = function() return true end,
        dashboardCache = function() return { bookRequestAccess = true } end }, function() end)
    local root, menu_hits = BoardUI.collectHits(function() return menu.build(menu, screen.w, screen.h) end)
    assert(menu.panel_rect.y >= 0 and menu.panel_rect.y + menu.panel_rect.h <= screen.h, "Go to fits with a background book or update banner")
    local requests_count = 0
    for _, hit in ipairs(menu_hits) do
        if hit.action.kind == "link" and hit.action.link == "requests" then
            requests_count = requests_count + 1
            assert(hit:getSize().h >= Metrics.px(44), "compact navigation keeps a full tap target")
        end
    end
    eq(requests_count, 1, "layout rebuild removes old hit targets")
    menu_layouts = menu_layouts + 1
end
eq(menu_layouts, 24)
for _, case in ipairs({ { signed_in = true }, { signed_in = true, access = false },
    { signed_in = true, access = true }, { signed_in = false, access = true } }) do
    local menu_catalog = { dashboardCache = function() return { bookRequestAccess = case.access } end }
    local menu = MenuSheet.open({ settings = {}, isLoggedIn = function() return case.signed_in end }, menu_catalog, function() end)
    local _root, hits = BoardUI.collectHits(function() return menu.build(menu, screen.w, screen.h) end)
    local count = 0
    for _, hit in ipairs(hits) do if hit.action.link == "requests" then count = count + 1 end end
    eq(count, case.signed_in and case.access == true and 1 or 0, "Requests visibility follows the current user's access")
end
print("bookorbit_requests_test.lua: flow, 60 request layouts and 24 menu layouts passed")

local Releases = require("bookorbit_request_releases")
assert(Releases.canDrive({ userId = 7 }, 7, false, true))
assert(not Releases.canDrive({ userId = 7 }, 7, false, false))
assert(not Releases.canDrive({ userId = 7, fulfillerUserId = 8 }, 7, false, true))
assert(Releases.canDrive({ userId = 8, fulfillerUserId = 7 }, 7, false, true))
assert(Releases.canDrive({ userId = 8 }, 7, true, false))
eq(Releases.bytes(0), "0.0 B"); eq(Releases.bytes(1024), "1.0 KiB")
assert(Releases.bytes(nil):find("not reported"))
local search_payload = assert(Releases.searchPayload{ title = " A title ", authors = "One; Two", formats = "epub, pdf", isbn = "", language = "" })
eq(search_payload.title, "A title"); eq(search_payload.authors[2], "Two"); eq(search_payload.preferredFormats[2], "pdf")
assert(not Releases.searchPayload{ title = "   " })
assert(not Releases.searchPayload{ title = string.rep("č", 501) })

local function releaseFixture(options)
    options = options or {}
    screen.w, screen.h = options.w or 600, options.h or 800; Metrics.setUserScale(options.scale or 1)
    local parent, parent_act, release_client, release_catalog, release_plugin, request, release_calls, release_deferred = fixture{
        manage = options.manage ~= false, self_fulfil = options.self_fulfil }
    request.status = "approved"
    local result = { releases = {}, indexers = { { indexerId = 9, indexerName = "Books source", delivery = "torrent", seedsBack = true, ok = true, count = 35 },
        { indexerId = 10, indexerName = "NZB source", delivery = "usenet", ok = true, count = 0 } },
        configuredIndexerCount = 2, enabledIndexerCount = 2, uncoveredIndexerCount = 0,
        criteria = { title = "My Book", authors = { "An Author" }, activeIsbn = "9781234567897", language = "en", preferredFormats = { "epub" } } }
    for index = 1, 35 do result.releases[index] = { indexerId = 9, guid = "release-" .. index, title = "Book release " .. index,
        indexerName = "Books source", formats = { index % 2 == 0 and "pdf" or "epub" }, sizeBytes = index * 1024,
        seeders = index - 1, leechers = 2, language = index % 2 == 0 and "en" or "de", publishedAt = "2026-10-31",
        score = 100 - index, freeleech = true, vipOnly = index == 1, fileCount = 1 } end
    result.releases[2].seeders = nil
    release_client.search_result = result
    release_client.inspection = { status = "ready", source = "torrent_file", totalFiles = 1, unitCount = 1, units = {},
        files = { { path = "Book.epub", sizeBytes = 1024, bookFile = true } } }
    function release_client:requestReleases(id, refresh)
        table.insert(release_calls, { "releases", id, refresh })
        if self.release_error then return nil, 500, { message = "Source not responding" } end
        return self.search_result
    end
    function release_client:searchBookRequestReleases(id, payload)
        table.insert(release_calls, { "search-releases", id, payload }); return self.search_result
    end
    function release_client:inspectBookRequestRelease(id, indexer, guid)
        table.insert(release_calls, { "inspect", id, indexer, guid })
        if self.inspect_error then return nil, 400, { message = "VIP torrent and you are not VIP" } end
        return self.inspection
    end
    function release_client:requestDownloadClients(id)
        table.insert(release_calls, { "clients", id })
        return { { id = 21, name = "Torrent client", delivery = "torrent" }, { id = 22, name = "Usenet client", delivery = "usenet" } }
    end
    function release_client:grabBookRequestRelease(id, payload)
        table.insert(release_calls, { "grab", id, payload })
        request.status = "downloading"
        request.download = { id = 31, status = "downloading", progressPercent = 5, releaseTitle = "Chosen release", downloadedBytes = 1024, totalBytes = 20480 }
        return request
    end
    function release_client:bookRequestReview(id)
        table.insert(release_calls, { "review", id })
        return { bookDockFileId = 50, canFile = true, verification = { score = 60, threshold = 80, rows = {
            { field = "title", verdict = "match", requested = "My Book", imported = "My Book" } } }, files = { { fileName = "Book.epub", fileSize = 1024 } } }
    end
    function release_client:selectBookRequestUnit(id, download, index)
        table.insert(release_calls, { "unit", id, download, index }); request.status = "importing"; request.download.releaseUnits = nil; return request
    end
    function release_client:fileBookRequestImport(id)
        table.insert(release_calls, { "file-import", id }); request.status = "available"; request.matchedBookId = 99; return request
    end
    function release_client:discardBookRequestImport(id)
        table.insert(release_calls, { "discard-import", id }); request.status = "failed"; return request
    end
    function release_client:cancelBookRequestDownload(id, download)
        table.insert(release_calls, { "stop-download", id, download }); request.status = "approved"; request.download.status = "failed"; return request
    end
    parent_act("detail", { id = request.id }); parent_act("releases")
    local child = shown[#shown]
    assert(child.name == "bookorbit_request_releases")
    local function childAct(kind, values) values = values or {}; values.kind = kind; child.on_action(child, values) end
    return child, childAct, release_client, release_catalog, release_plugin, request, release_calls, parent, release_deferred
end

local child, child_act, release_client, release_catalog, release_plugin, request, release_calls, parent = releaseFixture()
eq(child.view, "list"); eq(#child.visible, 35); eq(release_calls[#release_calls][1], "releases")
child.on_page_key(child, 1); eq(child.index, 2); child.on_page_key(child, -1); eq(child.index, 1)
child_act("release", { index = 1 }); eq(child.view, "release")
eq(release_calls[#release_calls][1], "releases", "opening metadata alone does not fetch every file manifest")
child_act("details"); assert(read_pages[#read_pages]:find("Seeders: 0")); assert(read_pages[#read_pages]:find("VIP only: Yes"))
child_act("back"); child_act("release", { index = 2 }); child_act("details"); assert(read_pages[#read_pages]:find("Seeders: Not reported"))
child_act("files"); assert(read_pages[#read_pages]:find("Book.epub")); eq(release_calls[#release_calls][1], "inspect")
local after_inspect_count = #release_calls
child_act("files"); eq(#release_calls, after_inspect_count, "selected release inspection is reused")
child_act("clients"); eq(child.view, "options"); eq(#child.options, 2, "only the matching download protocol is selectable")
child_act("option", { index = 2 }); eq(child.client_id, 21); eq(child.view, "release")
child_act("hold"); child_act("grab"); eq(#release_calls, after_inspect_count + 1, "download waits for confirmation")
confirms[#confirms].on_ok(); eq(release_calls[#release_calls][1], "grab")
local after_grab_count = #release_calls
confirms[#confirms].on_ok(); eq(#release_calls, after_grab_count, "a stale confirmation cannot resend a successful grab")
eq(release_calls[#release_calls][3].releaseGuid, "release-2"); eq(release_calls[#release_calls][3].downloadClientId, 21)
eq(release_calls[#release_calls][3].holdForReview, true); eq(child.view, "workflow"); eq(parent.item.status, "downloading")
child_act("progress"); assert(read_pages[#read_pages]:find("5%%")); child_act("stop"); confirms[#confirms].on_ok()
eq(release_calls[#release_calls][1], "stop-download"); eq(child.item.status, "approved")
child_act("find"); eq(child.view, "list")
child_act("filters"); choices[#choices].on_pick(1); child_act("option", { index = 2 })
eq(child.visible[1].seeders, 34); eq(child.visible[#child.visible].seeders, nil, "unknown seed count sorts after reported zero")
child_act("filters"); choices[#choices].on_pick(2); child_act("option", { index = 2 })
eq(#child.visible, 18, "format filter applies across all bounded results")
child_act("filters"); choices[#choices].on_pick(5); eq(#child.visible, 35)
child_act("filters"); choices[#choices].on_pick(6); assert(read_pages[#read_pages]:find("Configured sources: 2"))
child_act("edit"); eq(child.draft.isbn, "9781234567897")
child_act("field", { index = 1 }); entries[#entries].on_submit("New title"); child.draft.isbn = ""
child_act("search"); eq(release_calls[#release_calls][1], "search-releases"); eq(release_calls[#release_calls][3].title, "New title")
eq(release_calls[#release_calls][3].isbn, ""); eq(child.view, "list")

child, child_act, release_client, release_catalog, release_plugin, request, release_calls = releaseFixture()
child_act("release", { index = 1 }); release_client.inspection.status = "no_supported_file"
local before_blocked = #confirms
child_act("grab"); eq(#confirms, before_blocked); assert(read_pages[#read_pages]:find("download blocked"))
eq(release_calls[#release_calls][1], "inspect")
child_act("back"); child_act("release", { index = 2 }); release_client.inspect_error = true
child_act("grab"); eq(#confirms, before_blocked); eq(notices[#notices].text, "VIP torrent and you are not VIP")
release_client.inspect_error = false; release_client.inspection.status = "metadata_unavailable"
child_act("grab"); eq(#confirms, before_blocked + 1, "unknown metadata is allowed, as in the web client")

child, child_act, release_client, release_catalog, release_plugin, request, release_calls = releaseFixture()
request.status, request.download = "needs_review", { id = 31, status = "needs_review", releaseUnits = { { index = 0, title = "First book", mediaKind = "ebook", sizeBytes = 1024, contentFileCount = 1 } } }
child.view = "workflow"; child_act("review"); eq(child.option_kind, "unit")
child_act("option", { index = 1 }); confirms[#confirms].on_ok(); eq(release_calls[#release_calls][1], "unit")
eq(release_calls[#release_calls][4], 0, "unit indices are zero-based"); eq(child.item.status, "importing")
request.status = "needs_review"; child_act("review"); eq(child.view, "review")
child_act("review-details"); assert(read_pages[#read_pages]:find("required: 80")); assert(read_pages[#read_pages]:find("Book.epub"))
child_act("force-file"); confirms[#confirms].on_ok(); eq(request.status, "available")
child_act("open-book"); eq(release_catalog.opened, 99); assert(child.closed)

child, child_act, release_client, release_catalog, release_plugin, request, release_calls, parent, deferred = releaseFixture()
request.status, request.download = "needs_review", { id = 31, status = "needs_review" }
child.view = "workflow"; child_act("review"); child_act("discard"); confirms[#confirms].on_ok()
eq(request.status, "failed"); eq(release_calls[#release_calls][1], "discard-import")
child_act("find"); release_client.release_error = true
local before_failure_rows = child.visible
child_act("refresh"); eq(child.visible, before_failure_rows); eq(notices[#notices].text, "Source not responding")
release_catalog.defer = true; child_act("refresh"); child_act("back")
local before_closed = #release_calls
assert(child.closed); for _, pending in ipairs(deferred) do pending() end
eq(#release_calls, before_closed)

child, child_act, release_client, release_catalog, release_plugin, request, release_calls = releaseFixture()
child_act("release", { index = 1 })
local before_account_change = #read_pages
release_catalog.after_fetch = function() release_plugin.logged_in = false end
child_act("files"); assert(child.closed); eq(#read_pages, before_account_change, "old release response cannot populate a signed-out page")

page, act, client, catalog, plugin, item, calls = fixture{ self_fulfil = true }
act("new"); page.draft.title = "Manual choice"; act("submit"); confirms[#confirms].on_ok()
eq(calls[#calls][1], "submit"); eq(calls[#calls][2].selfServe, true, "manual selection skips unattended grabbing")

local release_layouts = 0
for _, dimensions in ipairs({ { 600, 800 }, { 800, 600 } }) do
    for _, scale in ipairs(Metrics.UI_SCALES) do
        child, child_act, release_client, release_catalog, release_plugin, request, release_calls, parent = releaseFixture{ w = dimensions[1], h = dimensions[2], scale = scale }
        for _, scenario in ipairs({ "list", "release", "edit", "options", "workflow", "unit-review", "review", "parent-detail", "parent-available" }) do
            local view = scenario == "unit-review" and "workflow" or scenario
            child.view = view; request.status = scenario == "unit-review" and "needs_review" or "downloading"
            request.download = { id = 31, status = scenario == "unit-review" and "needs_review" or "downloading", progressPercent = 20, releaseTitle = "Book release",
                releaseUnits = scenario == "unit-review" and { { index = 0, title = "A book" } } or nil }
            child.selected, child.draft = child.visible[1], { title = "Title", authors = "Author", isbn = "", language = "en", formats = "epub" }
            child.options, child.option_index = {}, 1
            for index = 1, 100 do child.options[index] = { label = "Option " .. index, value = index } end
            child.review = { canFile = true, bookDockFileId = 50, verification = { score = 70, threshold = 80 } }
            local target = scenario:find("parent") and parent or child
            if target == parent then
                parent.view = "detail"; parent.item = request; request.note = "Request note"; request.statusReason = "A status reason"
                if scenario == "parent-available" then request.status = "available"; request.userId = 8; request.matchedBookId = 99 end
            end
            local fits, root, kind, detail = BoardUI.fits(function() return target.build(target, screen.w, screen.h) end)
            assert(fits, string.format("release %s at %dx%d %.2fx: %s %s", scenario, screen.w, screen.h, scale, tostring(kind), tostring(detail)))
            if scenario == "list" then assertGap(root, "edit", "filters", true)
            elseif scenario == "release" then assertGap(root, "hold", "grab")
            elseif scenario == "review" then assertGap(root, "force-file", "discard")
            elseif scenario == "workflow" then assertGap(root, "progress", "stop")
            elseif scenario == "parent-detail" then assertGap(root, "releases", "cancel")
            elseif scenario == "parent-available" then assertGap(root, "open-book", "leave") end
            release_layouts = release_layouts + 1
        end
    end
end
eq(release_layouts, 90)
print("bookorbit_requests_test.lua: release search, inspection, confirmed download, import review and 90 additional layouts passed")
