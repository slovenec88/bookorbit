package.path = "koreader-plugin/bookorbit.koplugin/?.lua;" .. package.path

local widget = {}
function widget:extend(options)
    local class = options or {}
    class.__index = class
    return setmetatable(class, { __index = self })
end
function widget:new(options) return setmetatable(options or {}, { __index = self }) end
function widget:paintTo(bb, x, y)
    for _, child in ipairs(self) do child:paintTo(bb, x, y) end
end
for _, name in ipairs({
    "ui/geometry", "ui/widget/container/centercontainer", "ui/widget/container/leftcontainer",
    "ui/widget/container/rightcontainer", "ui/widget/container/widgetcontainer", "ui/widget/horizontalgroup",
    "ui/widget/horizontalspan", "ui/widget/overlapgroup", "ui/widget/textboxwidget", "ui/widget/textwidget",
    "ui/widget/verticalgroup", "ui/widget/verticalspan", "ui/widget/widget",
}) do package.loaded[name] = widget end

local gray, rgb = { gray = true }, { rgb = true, value = 0xE6AA50 }
local frame = widget:extend{}
function frame:paintTo(bb, x, y)
    if self.background then
        local paint = self.background.rgb and bb.paintRoundedRectRGB32 or bb.paintRoundedRect
        paint(bb, x, y, 40, 40, self.background, self.radius)
    end
    widget.paintTo(self, bb, x, y)
end
package.loaded["ui/widget/container/framecontainer"] = frame
package.loaded["ffi/blitbuffer"] = { isColor8 = function(c) return c.gray == true end }
package.loaded["ui/bidi"] = {}
package.loaded["ui/renderimage"] = {}
package.loaded["device"] = { screen = {} }
package.loaded["bookorbit_board_icons"] = {}
package.loaded["bookorbit_board_metrics"] = { INK = { white = gray, black = gray }, px = function(n) return n end }

local UI = require("bookorbit_board_ui")
local shapes = {
    tile = function() return UI.box{ w = 48, h = 36, bg = rgb, radius = 8 } end,
    circle = function() return UI.circle(32, { bg = rgb }, widget:new{}) end,
    dot = function() return UI.dot(16, true, { col = rgb }) end,
    bar = function() return UI.bar(48, 8, 60, { fill = rgb, track = rgb, r = 4 }) end,
    grid = function() return UI.cellGrid(48, 36, 16, 4, { { x = 0, y = 0, col = rgb } }) end,
    grid_border = function() return UI.cellGrid(48, 36, 16, 4, { { x = 0, y = 0, col = rgb, border = 2 } }) end,
    tile_border = function() return UI.box{ w = 48, h = 36, border = 2, border_col = rgb, radius = 8 } end,
}

for _, mode in ipairs({
    { name = "day", inverse = 0, cbb = true },
    { name = "Android night", inverse = 1, cbb = true },
    { name = "e-reader night", inverse = 1, cbb = false },
    { name = "Lua day", inverse = 0, cbb = false },
}) do
    for name, build in pairs(shapes) do
        local bb = { inverse = mode.inverse, pixels = {} }
        function bb:getInverse() return self.inverse end
        function bb:setInverse(value) self.inverse = value end
        function bb:canUseCbb() return mode.cbb end
        function bb:getWidth() return 96 end
        function bb:getHeight() return 128 end
        function bb:viewport()
            return setmetatable({ inverse = self.inverse, pixels = self.pixels }, { __index = self })
        end
        function bb:paintRoundedRectRGB32(_, _, _, _, color)
            -- C fills defer inversion on Android; Lua's RGB corner pixels do not.
            local center = self.inverse == 1 and not mode.cbb and 0xFFFFFF - color.value or color.value
            local corner = self.inverse == 1 and 0xFFFFFF - color.value or color.value
            table.insert(self.pixels, { center = center, corner = corner })
        end
        function bb:paintBorderRGB32(x, y, w, h, _, color)
            self:paintRoundedRectRGB32(x, y, w, h, color)
        end
        function bb:paintRoundedRect() end
        build():paintTo(bb, 12, 16)
        assert(#bb.pixels > 0, name .. ": RGB shape was painted")
        local expected = mode.inverse == 1 and 0xFFFFFF - rgb.value or rgb.value
        for _, painted in ipairs(bb.pixels) do
            local center, corner = painted.center, painted.corner
            if mode.inverse == 1 and mode.cbb then
                center, corner = 0xFFFFFF - center, 0xFFFFFF - corner
            end
            assert(center == expected and corner == expected,
                name .. ": " .. mode.name .. " must display matching center and corner colors")
        end
        assert(bb.inverse == mode.inverse, "do not change the screen's inversion flag")
    end
end

print("bookorbit_board_rgb_night_mode_test.lua: 28 cases passed")
