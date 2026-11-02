local Device = require("device")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template
local Metrics = require("bookorbit_board_metrics")
local BoardUI = require("bookorbit_board_ui")
local MenuUI = require("bookorbit_menu_ui")
local MenuPage = require("bookorbit_menu_page")
local DialogUI = require("bookorbit_dialog_ui")
local TextEntry = require("bookorbit_text_entry")
local Toast = require("bookorbit_toast")

local px = Metrics.px
local text, vstack, hstack, space, flex = BoardUI.text, BoardUI.vstack, BoardUI.hstack, BoardUI.space, BoardUI.flex
local Releases = {}
local GRABBABLE = { approved = true, searching = true, failed = true }
local SEARCH_FIELDS = {
    { key = "title", label = _("Title"), limit = 500 },
    { key = "authors", label = _("Authors"), hint = _("Separate authors with ;"), limit = 2000 },
    { key = "isbn", label = _("ISBN"), hint = _("Leave empty to search by title and author"), limit = 20 },
    { key = "language", label = _("Language"), hint = _("Language code, or empty for any"), limit = 20 },
    { key = "formats", label = _("Formats"), hint = _("Comma-separated, e.g. epub, pdf"), limit = 200 },
}

local function trim(value) return (value or ""):match("^%s*(.-)%s*$") end
local function known(value) return value == nil and _("Not reported") or tostring(value) end
local function yes(value) return value and _("Yes") or _("No") end
local function label(value)
    return (tostring(value or ""):gsub("_", " "):gsub("(%l)(%u)", "%1 %2"):gsub("^%l", string.upper))
end
local DELIVERY = { torrent = _("Torrent"), usenet = _("Usenet"), file = _("Direct download") }
local function split(value, pattern)
    local result = {}
    for entry in (value or ""):gmatch(pattern) do
        entry = trim(entry)
        if entry ~= "" then table.insert(result, entry) end
    end
    return result
end

function Releases.bytes(value)
    if value == nil then return _("Size not reported") end
    local units, index = { "B", "KiB", "MiB", "GiB", "TiB" }, 1
    while value >= 1024 and index < #units do value, index = value / 1024, index + 1 end
    return string.format(value < 10 and "%.1f %s" or "%.0f %s", value, units[index])
end

function Releases.canDrive(item, user_id, manage, self_fulfil)
    return manage == true or (self_fulfil == true and (item.fulfillerUserId or item.userId) == user_id)
end

function Releases.searchPayload(draft)
    if trim(draft.title) == "" then return nil, _("Enter a title.") end
    for _i, field in ipairs(SEARCH_FIELDS) do
        local _text, length = (draft[field.key] or ""):gsub("[^\128-\191]", "")
        if length > field.limit then return nil, T(_("%1 is too long."), field.label) end
    end
    local authors, formats = split(draft.authors, "[^;]+"), split(draft.formats, "[^,]+")
    if #authors > 50 or #formats > 20 then return nil, _("Too many authors or formats.") end
    for _i, author in ipairs(authors) do
        local _text, length = author:gsub("[^\128-\191]", "")
        if length > 255 then return nil, _("An author name is too long.") end
    end
    for _i, format in ipairs(formats) do
        local _text, length = format:gsub("[^\128-\191]", "")
        if length > 20 then return nil, _("A format name is too long.") end
    end
    return { title = trim(draft.title), authors = authors, isbn = trim(draft.isbn),
        language = trim(draft.language), preferredFormats = formats }
end

local function source(page, release)
    for _i, entry in ipairs(page.search and page.search.indexers or {}) do
        if entry.indexerId == release.indexerId then return entry end
    end
    return {}
end

local function formats(release)
    local values = release.formats or {}
    if #values == 0 then return release.format and release.format:upper() or _("Format not reported") end
    return table.concat(values, ", "):upper()
end

local function formatValues(release)
    return release.formats and #release.formats > 0 and release.formats or release.format and { release.format } or {}
end

local function summary(page, release)
    local delivery = source(page, release).delivery
    local swarm = delivery == "torrent" or source(page, release).seedsBack
    return formats(release) .. " · " .. Releases.bytes(release.sizeBytes)
        .. (swarm and " · " .. T(_("Seeds: %1"), known(release.seeders)) or " · " .. (DELIVERY[delivery] or _("Source")))
end

local function details(page, release)
    local lines = { release.title, "",
        T(_("Source: %1"), release.indexerName or ""),
        T(_("Type: %1 / %2"), label(page.item.mediaKind), DELIVERY[source(page, release).delivery] or _("Not reported")),
        T(_("Formats: %1"), formats(release)), Releases.bytes(release.sizeBytes),
        T(_("Seeders: %1"), known(release.seeders)), T(_("Leechers: %1"), known(release.leechers)),
        T(_("Language: %1"), known(release.language)), T(_("Published: %1"), known(release.publishedAt)),
        T(_("Files reported by source: %1"), known(release.fileCount)),
        T(_("Freeleech: %1"), yes(release.freeleech)), T(_("VIP only: %1"), yes(release.vipOnly)),
        T(_("Previously grabbed: %1"), yes(release.alreadyGrabbed)), T(_("Score: %1"), known(release.score)),
    }
    if release.tierName then table.insert(lines, T(_("Profile tier: %1"), release.tierName)) end
    if release.profileMismatch then table.insert(lines, _("Does not match the configured release profile.")) end
    for _i, reason in ipairs(release.reasons or {}) do
        table.insert(lines, label(reason.code) .. ": " .. tostring(reason.points or 0) .. (reason.detail and " (" .. reason.detail .. ")" or ""))
    end
    local audio = release.audio
    if audio then
        table.insert(lines, "")
        for _i, field in ipairs({ { _("Bitrate (kbps)"), "bitrateKbps" }, { _("Bitrate mode"), "bitrateMode" },
            { _("Channels"), "channels" }, { _("Sample rate (Hz)"), "samplingRateHz" },
            { _("Duration (seconds)"), "durationSeconds" }, { _("Chapters"), "chapterCount" } }) do
            if audio[field[2]] ~= nil then table.insert(lines, field[1] .. ": " .. tostring(audio[field[2]])) end
        end
    end
    return table.concat(lines, "\n")
end

local function inspectionText(inspection)
    local labels = { ready = _("Supported book found"), no_supported_file = _("No supported book file; download blocked"),
        multiple_supported_files = _("Several books; choose one after downloading"), contents_unknown = _("Archive contents checked after download"),
        metadata_unavailable = _("File metadata is unavailable; contents checked after download") }
    local lines = { labels[inspection.status] or tostring(inspection.status),
        T(_("Total files: %1"), known(inspection.totalFiles)), T(_("Books: %1"), known(inspection.unitCount)), "" }
    for _i, unit in ipairs(inspection.units or {}) do
        table.insert(lines, (unit.title or unit.mediaKind or _("Book")) .. " · " .. T(_("%1 content files"), unit.contentFileCount or 0))
    end
    for _i, file in ipairs(inspection.files or {}) do
        table.insert(lines, file.path .. " · " .. Releases.bytes(file.sizeBytes) .. (file.bookFile and " · " .. _("Book file") or ""))
    end
    if inspection.truncated then table.insert(lines, _("The server limited this file list; totals include omitted files.")) end
    return table.concat(lines, "\n")
end

local function read(title, value) require("bookorbit_text_pages").about({ title = title }, value) end
local function refilter(page)
    local rows = {}
    for index, release in ipairs(page.search and page.search.releases or {}) do
        local format_match = not page.format
        for _i, value in ipairs(formatValues(release)) do
            if value and value:upper() == page.format then format_match = true end
        end
        if format_match and (not page.source_id or page.source_id == release.indexerId)
                and (not page.language or page.language == (release.language or "")) then
            table.insert(rows, { release = release, rank = index })
        end
    end
    table.sort(rows, function(a, b)
        local left, right = a.release, b.release
        if page.sort == "seeds" and left.seeders ~= right.seeders then return (left.seeders or -1) > (right.seeders or -1) end
        if page.sort == "small" and left.sizeBytes ~= right.sizeBytes then return (left.sizeBytes or math.huge) < (right.sizeBytes or math.huge) end
        if page.sort == "large" and left.sizeBytes ~= right.sizeBytes then return (left.sizeBytes or -1) > (right.sizeBytes or -1) end
        if page.sort == "new" and left.publishedAt ~= right.publishedAt then return (left.publishedAt or "") > (right.publishedAt or "") end
        return a.rank < b.rank
    end)
    page.visible, page.index = {}, 1
    for _i, row in ipairs(rows) do table.insert(page.visible, row.release) end
end

local function loadSearch(page, refresh, overrides)
    page.view = "list"
    page:refresh()
    page.run(page, _("Searching releases…"), function()
        if overrides then return page.client:searchBookRequestReleases(page.item.id, overrides) end
        return page.client:requestReleases(page.item.id, refresh)
    end, function(body)
        page.search, page.overrides = body, overrides
        if page.view == "list" then page.draft = nil end
        page.selected, page.inspection = nil, nil
        refilter(page)
        page:refresh()
    end)
end

local function updateItem(page, item)
    page.item, page.view = item, "workflow"
    page.parent.item = item
    page.parent:refresh()
    page:refresh()
end

local function refreshItem(page)
    page.run(page, _("Refreshing request…"), function() return page.client:bookRequest(page.item.id) end,
        function(body) updateItem(page, body) end)
end

local function inspect(page, done)
    if page.inspection then done(page.inspection) return end
    local selected = page.selected
    page.run(page, _("Inspecting release files…"), function()
        return page.client:inspectBookRequestRelease(page.item.id, selected.indexerId, selected.guid)
    end, function(body)
        page.inspection = body
        page:refresh()
        done(body)
    end)
end

local function options(page, kind, rows, return_view)
    page.view, page.option_kind, page.options, page.option_index, page.return_view = "options", kind, rows, 1, return_view or "list"
    page:refresh()
end

local function filterOptions(page, kind)
    local rows, seen = { { label = _("All"), value = false } }, {}
    for _i, release in ipairs(page.search.releases or {}) do
        local values = kind == "format" and formatValues(release) or { kind == "source" and release.indexerId or release.language or "" }
        for _i, value in ipairs(values) do
            if kind == "format" then value = value:upper() end
            if not seen[value] then
                seen[value] = true
                table.insert(rows, { value = value, label = kind == "source" and (release.indexerName or tostring(value)) or value ~= "" and value or _("Not reported") })
            end
        end
    end
    options(page, kind, rows)
end

local function pager(w, index, count, kind)
    return hstack({ w = w }, { MenuUI.iconButton("chevron-left", index > 1 and { kind = kind, delta = -1 } or nil),
        flex(0), text(T(_("%1 of %2"), index, count), { s = 14 }), flex(0),
        MenuUI.iconButton("chevron-right", index < count and { kind = kind, delta = 1 } or nil) })
end

local function build(page, sw, sh)
    local mx = MenuUI.mx()
    local w, iw = sw - 2 * mx, MenuUI.rowsIn(sw - 2 * mx)
    local titles = { list = _("Available releases"), release = _("Release"), edit = _("Search releases"),
        options = _("Choose"), workflow = _("Download & import"), review = _("Review import") }
    local items = { MenuUI.pageHeader(w, titles[page.view], {
        right = (page.view == "list" or page.view == "workflow" or page.view == "review") and MenuUI.iconButton("refresh-cw", { kind = "refresh" }) or nil }) }
    if page.view == "list" then
        table.insert(items, text(page.item.title, { s = 15, b = true, w = w, data = true }))
        table.insert(items, space(nil, px(8)))
        table.insert(items, hstack({ w = w, gap = px(12) }, {
            MenuUI.pill(_("Edit search"), { w = math.floor((w - px(12)) / 2), action = { kind = "edit" } }),
            MenuUI.pill(_("Filter & sort"), { w = math.floor((w - px(12)) / 2), action = page.search and { kind = "filters" } or nil }) }))
        table.insert(items, space(nil, px(8)))
        table.insert(items, text(page.search and T(_("%1 releases · %2 shown%3"), #page.search.releases, #page.visible, page.search.cached and _(" · cached") or "")
            or _("Search has not completed."), { s = 13, w = w }))
        local rows = {}
        local first = (page.index - 1) * page.limit + 1
        for index = first, math.min(first + page.limit - 1, #page.visible) do
            local release = page.visible[index]
            table.insert(rows, MenuUI.row(iw, { label = release.title, data = true, sub = summary(page, release), sub_data = true,
                h = 64, chevron = true, action = { kind = "release", index = index } }))
        end
        table.insert(items, space(nil, px(8)))
        if #rows > 0 then table.insert(items, MenuUI.group(w, rows))
        elseif page.search then
            local reason = #page.search.releases > 0 and _("No releases match these filters.")
                or (page.search.configuredIndexerCount or 0) == 0 and _("No release sources are configured.")
                or (page.search.enabledIndexerCount or 0) == 0 and _("All release sources are disabled.")
                or _("No releases found. Edit the search or check source status.")
            table.insert(items, text(reason, { s = 15, w = w, lines = 3 }))
        end
        table.insert(items, space(nil, px(8)))
        table.insert(items, flex(0))
        table.insert(items, pager(w, page.index, math.max(1, math.ceil(#page.visible / page.limit)), "page"))
    elseif page.view == "release" then
        local release = page.selected
        table.insert(items, text(release.title, { s = 18, b = true, w = w, data = true }))
        table.insert(items, text(summary(page, release), { s = 13, w = w, data = true }))
        table.insert(items, space(nil, px(8)))
        table.insert(items, MenuUI.group(w, {
            MenuUI.row(iw, { label = _("Release details"), sub = release.indexerName, sub_data = true, h = 50, chevron = true, action = { kind = "details" } }),
            MenuUI.row(iw, { label = _("Inspect files"), sub = page.inspection and label(page.inspection.status) or _("Check the contents before downloading"), h = 50, chevron = true, action = { kind = "files" } }),
            MenuUI.row(iw, { label = _("Download client"), sub = page.client_name or _("BookOrbit default"), h = 50, chevron = true, action = { kind = "clients" } }),
        }))
        table.insert(items, space(nil, px(8)))
        table.insert(items, MenuUI.row(w, { label = _("Hold import for review"), toggle = page.hold == true, h = 44, action = { kind = "hold" } }))
        table.insert(items, space(nil, px(8)))
        table.insert(items, MenuUI.pill(_("Download this release"), { w = w, action = { kind = "grab" } }))
    elseif page.view == "edit" then
        local rows = {}
        for index, field in ipairs(SEARCH_FIELDS) do
            table.insert(rows, MenuUI.row(iw, { label = field.label, sub = page.draft[field.key] ~= "" and page.draft[field.key] or _("Any / not set"),
                h = 50, sub_data = true, chevron = true, action = { kind = "field", index = index } }))
        end
        table.insert(items, MenuUI.group(w, rows))
        table.insert(items, space(nil, px(8)))
        table.insert(items, MenuUI.pill(_("Search releases"), { w = w, action = { kind = "search" } }))
    elseif page.view == "options" then
        local rows = {}
        local first = (page.option_index - 1) * page.limit + 1
        for index = first, math.min(first + page.limit - 1, #page.options) do
            local option = page.options[index]
            table.insert(rows, MenuUI.row(iw, { label = option.label, data = true, sub = option.sub, sub_data = true, h = 64,
                chevron = true, action = { kind = "option", index = index } }))
        end
        table.insert(items, MenuUI.group(w, rows))
        table.insert(items, space(nil, px(8)))
        table.insert(items, flex(0))
        table.insert(items, pager(w, page.option_index, math.max(1, math.ceil(#page.options / page.limit)), "option-page"))
    elseif page.view == "review" then
        local review = page.review
        table.insert(items, text(page.item.title, { s = 18, b = true, w = w, data = true }))
        table.insert(items, text(review.verification and T(_("Verification score: %1 / required %2"), review.verification.score, review.verification.threshold)
            or _("Import is waiting for your review."), { s = 14, w = w, lines = 2 }))
        table.insert(items, MenuUI.group(w, { MenuUI.row(iw, { label = _("Verification & file details"), h = 54, chevron = true, action = { kind = "review-details" } }) }))
        if review.canFile then
            table.insert(items, space(nil, px(8)))
            table.insert(items, MenuUI.pill(_("File in library"), { w = w, action = { kind = "force-file" } }))
        end
        if review.bookDockFileId then
            table.insert(items, space(nil, px(8)))
            table.insert(items, MenuUI.pill(_("Discard imported files"), { w = w, kind = "outline", action = { kind = "discard" } }))
        end
    else
        local item, download = page.item, page.item.download
        table.insert(items, text(item.title, { s = 18, b = true, w = w, data = true }))
        table.insert(items, text(T(_("Status: %1"), label(item.status)), { s = 16, w = w }))
        local rows = { MenuUI.row(iw, { label = _("Download & status details"), sub = download and download.releaseTitle or item.statusReason,
            sub_data = true, h = 54, chevron = true, action = { kind = "progress" } }) }
        if download then
            table.insert(items, text(T(_("Downloaded: %1%%"), math.floor(download.progressPercent or 0)), { s = 14, w = w }))
        end
        table.insert(items, MenuUI.group(w, rows))
        if GRABBABLE[item.status] then
            table.insert(items, space(nil, px(8)))
            table.insert(items, MenuUI.pill(_("Find another release"), { w = w, action = { kind = "find" } }))
        end
        if item.status == "needs_review" then
            table.insert(items, space(nil, px(8)))
            table.insert(items, MenuUI.pill(download and download.releaseUnits and #download.releaseUnits > 0 and _("Choose book from release") or _("Review imported book"),
                { w = w, action = { kind = "review" } }))
        end
        if download and (download.status == "queued" or download.status == "downloading") then
            table.insert(items, space(nil, px(8)))
            table.insert(items, MenuUI.pill(_("Stop download"), { w = w, kind = "outline", action = { kind = "stop" } }))
        end
        if item.status == "available" and item.mediaKind == "ebook" and item.matchedBookId then
            table.insert(items, space(nil, px(8)))
            table.insert(items, MenuUI.pill(_("Open in library"), { w = w, action = { kind = "open-book" } }))
        elseif item.status == "available" and item.mediaKind == "audiobook" then
            table.insert(items, text(_("Listen in BookOrbit on the web or in the app."), { s = 14, w = w, lines = 2 }))
        end
    end
    return vstack({ w = sw, h = sh, pad = { px(6), mx, px(8), mx } }, items)
end

local function act(page, action)
    if not page.active(page) then return true end
    local kind = action.kind
    if kind == "back" then
        if page.busy or page.view == "list" or page.view == "workflow" then page:close()
        else page.view = page.view == "release" and "list" or page.view == "review" and "workflow" or page.return_view or "list" page:refresh() end
        return true
    end
    if page.busy then return true end
    if kind == "find" then loadSearch(page, false)
    elseif kind == "refresh" then
        if page.view == "list" then loadSearch(page, true, page.overrides)
        elseif page.view == "review" then page.run(page, _("Loading review…"), function() return page.client:bookRequestReview(page.item.id) end, function(body) page.review = body page:refresh() end)
        else refreshItem(page) end
    elseif kind == "page" or kind == "option-page" then
        local field = kind == "page" and "index" or "option_index"
        local count = math.max(1, math.ceil(#(kind == "page" and page.visible or page.options) / page.limit))
        page[field] = math.max(1, math.min(count, page[field] + action.delta)) page:refresh()
    elseif kind == "release" then
        page.selected, page.inspection, page.view = page.visible[action.index], nil, "release"
        page.client_id, page.client_name = nil, nil page:refresh()
    elseif kind == "details" then read(_("Release details"), details(page, page.selected))
    elseif kind == "files" then inspect(page, function(body) read(_("Release files"), inspectionText(body)) end)
    elseif kind == "hold" then page.hold = not page.hold page:refresh()
    elseif kind == "filters" then
        if not page.search then return true end
        DialogUI.choose{ title = _("Filter & sort"), options = { { label = _("Sort") }, { label = _("Format") }, { label = _("Source") },
            { label = _("Language") }, { label = _("Clear filters") }, { label = _("Source status") } }, on_pick = function(index)
            if not page.active(page) then return end
            if index == 1 then options(page, "sort", { { label = _("Ranked"), value = false }, { label = _("Most seeders"), value = "seeds" },
                { label = _("Smallest"), value = "small" }, { label = _("Largest"), value = "large" }, { label = _("Newest"), value = "new" } })
            elseif index <= 4 then filterOptions(page, ({ [2] = "format", [3] = "source", [4] = "language" })[index])
            elseif index == 5 then page.format, page.source_id, page.language = nil, nil, nil refilter(page) page:refresh()
            else
                local lines = { T(_("Configured sources: %1; enabled: %2"), page.search.configuredIndexerCount or 0, page.search.enabledIndexerCount or 0),
                    T(_("Sources not covering this medium: %1"), page.search.uncoveredIndexerCount or 0) }
                for _i, entry in ipairs(page.search.indexers or {}) do
                    table.insert(lines, (entry.indexerName or "") .. ": " .. (entry.ok and T(_("%1 results"), entry.count or 0) or (entry.error or entry.failure or _("Failed"))))
                end
                read(_("Source status"), table.concat(lines, "\n"))
            end
        end }
    elseif kind == "edit" then
        local criteria = page.search and page.search.criteria or page.item
        page.draft = page.draft or { title = criteria.title, authors = table.concat(criteria.authors or {}, "; "), isbn = criteria.activeIsbn or "",
            language = criteria.language or "", formats = table.concat(criteria.preferredFormats or {}, ", ") }
        page.view, page.return_view = "edit", "list" page:refresh()
    elseif kind == "field" then
        local field = SEARCH_FIELDS[action.index]
        TextEntry.open{ title = field.label, hint = field.hint, value = page.draft[field.key], allow_empty = field.key ~= "title",
            on_submit = function(value) if page.active(page) then page.draft[field.key] = value page:refresh() end end }
    elseif kind == "search" then
        local payload, problem = Releases.searchPayload(page.draft)
        if not payload then Toast.error(problem) else loadSearch(page, true, payload) end
    elseif kind == "clients" then
        page.run(page, _("Loading download clients…"), function() return page.client:requestDownloadClients(page.item.id) end, function(body)
            local rows = { { label = _("BookOrbit default"), value = false } }
            local delivery = source(page, page.selected).delivery
            for _i, client in ipairs(body) do
                if client.delivery == delivery then table.insert(rows, { label = client.name, value = client.id }) end
            end
            options(page, "client", rows, "release")
        end)
    elseif kind == "option" then
        local option, target = page.options[action.index], page.option_kind
        if target == "unit" then
            local download_id, unit_index = page.item.download.id, option.value
            DialogUI.confirm{ title = _("Import this book?"), text = option.label .. "\n" .. (option.sub or ""), ok_label = _("Import"), on_ok = function()
                page.run(page, _("Importing selected book…"), function() return page.client:selectBookRequestUnit(page.item.id, download_id, unit_index) end,
                    function(body) updateItem(page, body) end)
            end }
        else
            if target == "client" then page.client_id, page.client_name = option.value or nil, option.value and option.label or nil
            else page[target == "source" and "source_id" or target] = option.value or nil refilter(page) end
            page.view = page.return_view page:refresh()
        end
    elseif kind == "grab" then
        inspect(page, function(body)
            if body.status == "no_supported_file" then read(_("Cannot download release"), inspectionText(body)) return end
            local selected = page.selected
            local payload = { indexerId = selected.indexerId, releaseGuid = selected.guid, downloadClientId = page.client_id,
                holdForReview = page.hold == true }
            DialogUI.confirm{ title = _("Download this release?"), text = selected.title .. "\n" .. summary(page, selected)
                .. "\n" .. (page.client_name or _("BookOrbit default client")) .. "\n" .. T(_("Hold for review: %1"), yes(page.hold)), ok_label = _("Download"),
                on_ok = function()
                    if not GRABBABLE[page.item.status] then return end
                    page.run(page, _("Sending release to download client…"), function() return page.client:grabBookRequestRelease(page.item.id, payload) end,
                    function(item) updateItem(page, item) Toast.show(_("Release sent to download client")) end) end }
        end)
    elseif kind == "progress" then
        local item, download = page.item, page.item.download
        local lines = { item.title, T(_("Status: %1"), label(item.status)), item.statusReason or "" }
        if download then
            table.insert(lines, download.releaseTitle or "")
            table.insert(lines, download.downloadClientName or download.source or "")
            table.insert(lines, T(_("Downloaded: %1%%"), known(download.progressPercent)))
            table.insert(lines, Releases.bytes(download.downloadedBytes) .. " / " .. Releases.bytes(download.totalBytes))
            if download.errorMessage then table.insert(lines, download.errorMessage) end
        end
        read(_("Download details"), table.concat(lines, "\n"))
    elseif kind == "review" then
        local units = page.item.download and page.item.download.releaseUnits
        if units and #units > 0 then
            local rows = {}
            for _i, unit in ipairs(units) do table.insert(rows, { label = unit.title or _("Untitled book"), value = unit.index,
                sub = (unit.mediaKind or "") .. " · " .. Releases.bytes(unit.sizeBytes) .. " · " .. T(_("%1 files"), unit.contentFileCount or 0) }) end
            options(page, "unit", rows, "workflow")
        else
            page.run(page, _("Loading import review…"), function() return page.client:bookRequestReview(page.item.id) end,
                function(body) page.review, page.view = body, "review" page:refresh() end)
        end
    elseif kind == "review-details" then
        local review, lines = page.review, { page.item.statusReason or "" }
        if review.verification then
            table.insert(lines, T(_("Score: %1; required: %2"), review.verification.score, review.verification.threshold))
            for _i, row in ipairs(review.verification.rows or {}) do
                table.insert(lines, label(row.field) .. ": " .. label(row.verdict) .. "\n" .. _("Requested") .. ": " .. known(row.requested) .. "\n" .. _("Imported") .. ": " .. known(row.imported))
            end
        end
        for _i, file in ipairs(review.files or {}) do table.insert(lines, file.fileName .. " · " .. Releases.bytes(file.fileSize)) end
        if review.edition then
            for key, value in pairs(review.edition) do
                if type(value) ~= "table" and value ~= nil then table.insert(lines, label(key) .. ": " .. (type(value) == "boolean" and yes(value) or tostring(value))) end
            end
        end
        read(_("Import verification"), table.concat(lines, "\n\n"))
    elseif kind == "force-file" or kind == "discard" or kind == "stop" then
        local labels = { ["force-file"] = _("File in library"), discard = _("Discard imported files"), stop = _("Stop download") }
        local note = kind == "force-file" and _("File this import even if verification did not pass?")
            or kind == "discard" and _("Delete the held import and mark this request failed?") or _("Stop the active transfer so another release can be chosen?")
        local download_id = page.item.download and page.item.download.id
        DialogUI.confirm{ title = labels[kind] .. "?", text = page.item.title .. "\n" .. note, ok_label = labels[kind], on_ok = function()
            page.run(page, _("Updating request…"), function()
                if kind == "force-file" then return page.client:fileBookRequestImport(page.item.id) end
                if kind == "discard" then return page.client:discardBookRequestImport(page.item.id) end
                return page.client:cancelBookRequestDownload(page.item.id, download_id)
            end, function(item) updateItem(page, item) end)
        end }
    elseif kind == "open-book" then
        local id = page.item.matchedBookId
        page:close() page.parent:close() page.catalog:loadBookDetail(id)
    end
    return true
end

function Releases.open(parent, helpers)
    local page = MenuPage:new{
        name = "bookorbit_request_releases", parent = parent, plugin = parent.plugin, catalog = parent.catalog,
        client = parent.client, user_id = parent.user_id, item = parent.item, run = helpers.run, active = helpers.active,
        view = GRABBABLE[parent.item.status] and "list" or "workflow", index = 1, visible = {},
        limit = math.max(1, math.min(12, math.floor((Device.screen:getHeight() - px(270)) / px(68)))),
        build = build, on_action = act, on_back = function(self) return act(self, { kind = "back" }) end,
        on_page_key = function(self, delta)
            if self.view == "list" then act(self, { kind = "page", delta = delta })
            elseif self.view == "options" then act(self, { kind = "option-page", delta = delta }) end
        end,
    }
    UIManager:show(page, "ui")
    if page.view == "list" then loadSearch(page, false) end
    return page
end

return Releases
