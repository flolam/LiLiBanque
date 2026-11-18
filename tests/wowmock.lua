-- Strict simulation of the WoW widget API used by the addon. Only methods that exist on the
-- real widget types are defined: calling anything else fails the test ("attempt to call nil").
local M = {}
local Region = {}
Region.__index = Region
local function proto(parent)
    local p = setmetatable({}, {__index = parent}); p.__index = p; return p
end
local Frame, Button, EditBox, ScrollFrame, FontString, Texture
Frame = proto(Region); Button = proto(Frame); EditBox = proto(Frame); ScrollFrame = proto(Frame)
FontString = proto(Region); Texture = proto(Region)

function Region:SetPoint(point, rel, relPoint, x, y)
    if type(rel) == 'number' then rel, relPoint, x, y = nil, point, rel, relPoint end
    if type(rel) == 'string' then rel = _G[rel] end
    self.points = self.points or {}
    self.points[#self.points + 1] = {point, rel or self.parent, relPoint or point, x or 0, y or 0}
end
function Region:ClearAllPoints() self.points = {} end
function Region:SetAllPoints() self.allPoints = true end
function Region:GetPoint(i) local p = (self.points or {})[i or 1]; if p then return p[1], p[2], p[3], p[4], p[5] end end
function Region:SetSize(w, h) self.width, self.height = w, h end
function Region:SetWidth(w) self.width = w end
function Region:SetHeight(h) self.height = h end
function Region:GetWidth() return self.width or 0 end
function Region:IsShown() return self.shown == true end
function Region:Show() if not self.shown then self.shown = true; if self.fire then self:fire('OnShow') end end end
function Region:Hide() if self.shown then self.shown = false; if self.fire then self:fire('OnHide') end end end
function Region:SetShown(v) if v then self:Show() else self:Hide() end end
function Region:GetParent() return self.parent end

function FontString:SetText(t) self.text = t end
function FontString:GetText() return self.text end
function FontString:SetJustifyH(j) self.justify = j end
function FontString:SetWordWrap(v) self.wrap = v end
function FontString:SetTextColor() end
function Texture:SetColorTexture(r, g, b, a) self.color = {r, g, b, a} end

function Frame:SetScript(name, fn) self.scripts[name] = fn end
function Frame:GetScript(name) return self.scripts[name] end
function Frame:HookScript(name, fn) self.hooks[name] = self.hooks[name] or {}; table.insert(self.hooks[name], fn) end
function Frame:fire(name, ...)
    if self.scripts[name] then self.scripts[name](self, ...) end
    for _, fn in ipairs(self.hooks[name] or {}) do fn(self, ...) end
end
function Frame:RegisterEvent(event)
    if M.unknownEvents and M.unknownEvents[event] then error('unknown event '..event) end
    self.events[event] = true
end
-- Font objects verified in Blizzard_Fonts_Shared/Shared/FontStyles.xml (Forever 1.60.1).
M.fonts = {GameFontNormal = true, GameFontNormalLarge = true, GameFontNormalSmall = true, GameFontHighlight = true,
    GameFontHighlightSmall = true, GameFontDisableSmall = true, GameFontDisableLarge = true}
function Frame:CreateFontString(name, layer, font)
    if font and not M.fonts[font] then error('police absente : '..font) end
    local fs = setmetatable({parent = self, font = font, layer = layer}, FontString); M.all[#M.all + 1] = fs; return fs
end
function Frame:CreateTexture(name, layer)
    local t = setmetatable({parent = self, layer = layer}, Texture); return t
end
function Frame:SetMovable(v) self.movable = v end
function Frame:EnableMouse(v) self.mouse = v end
function Frame:SetClampedToScreen(v) self.clamped = v end
function Frame:RegisterForDrag(b) self.drag = b end
function Frame:StartMoving() self.moving = true end
function Frame:StopMovingOrSizing() self.moving = false end
function Frame:SetToplevel(v) self.toplevel = v end
function Frame:SetID(id) self.id = id end
function Frame:GetID() return self.id end
function Frame:IsVisible()
    local f = self
    while f do if not f.shown then return false end; f = f.parent end
    return true
end

function Button:SetText(t) self.text = t end
function Button:GetText() return self.text end
function Button:SetEnabled(v) self.enabled = v and true or false end
function Button:Enable() self.enabled = true end
function Button:Disable() self.enabled = false end
function Button:IsEnabled() return self.enabled ~= false end
function Button:Click() if self.enabled ~= false then self:fire('OnClick', 'LeftButton') end end

function EditBox:SetText(t) self.text = t; self:fire('OnTextChanged', false) end
function EditBox:GetText() return self.text or '' end
function EditBox:SetFocus() self.focus = true; self:fire('OnEditFocusGained') end
function EditBox:ClearFocus() self.focus = false end
function EditBox:HasFocus() return self.focus == true end
function EditBox:HighlightText() self.highlighted = true end
function EditBox:SetCursorPosition(n) self.cursor = n end
function EditBox:SetFontObject(f) assert(M.fonts[f], 'police absente : '..tostring(f)); self.fontObject = f end
function EditBox:type(t) self.text = t; self:fire('OnTextChanged', true) end

local kinds = {Frame = Frame, Button = Button, EditBox = EditBox, ScrollFrame = ScrollFrame}
local function new(kind, name, parent, template)
    local mt = assert(kinds[kind], 'unknown widget type '..tostring(kind))
    local o = setmetatable({kind = kind, name = name, parent = parent, template = template, scripts = {}, hooks = {}, events = {}, shown = true}, mt)
    if name then _G[name] = o end
    M.all[#M.all + 1] = o
    if template == 'ButtonFrameTemplate' then
        o.Inset = new('Frame', name and name..'Inset', o)
        o.CloseButton = new('Button', name and name..'CloseButton', o, 'UIPanelCloseButtonDefaultAnchors')
        o.CloseButton:SetScript('OnClick', function() o:Hide() end)
        o.SetTitle = function(self, t) self.title = t end
        o.SetBorder = function() end; o.SetPortraitShown = function(self, v) self.portrait = v end
    elseif template == 'InputScrollFrameTemplate' then
        o.EditBox = new('EditBox', nil, o)
        o.CharCount = o:CreateFontString(nil, 'OVERLAY', 'GameFontDisableLarge')
    elseif template == 'PanelTabButtonTemplate' then
        parent.Tabs = parent.Tabs or {}; table.insert(parent.Tabs, o)
    elseif template ~= nil and not M.templates[template] then
        error('template absent de la source Forever simulée : '..template)
    end
    return o
end
M.templates = {UIPanelCloseButtonDefaultAnchors = true, UIPanelButtonTemplate = true, BasicFrameTemplate = true, ButtonFrameTemplate = true, InputScrollFrameTemplate = true, PanelTabButtonTemplate = true}

function M.install()
    M.all = {}
    UIParent = new('Frame', 'UIParent'); UISpecialFrames = {}
    CreateFrame = function(kind, name, parent, template) return new(kind, name, parent, template) end
    ButtonFrameTemplate_HidePortrait = function(f) f:SetPortraitShown(false) end
    PanelTemplates_SetNumTabs = function(f, n) f.numTabs = n end
    PanelTemplates_SetTab = function(f, i) f.selectedTab = i end
    RAID_CLASS_COLORS = {PALADIN = {colorStr = 'fff48cba'}, MAGE = {colorStr = 'ff3fc7eb'}, DRUID = {colorStr = 'ffff7c0a'}}
    Enum = {PlayerInteractionType = {GuildBanker = 10}}
    date = os.date
    GetBuildInfo = function() return '1.60.1', '70959', 'Nov 10 2026', 16001 end
    M.loaded = {}
    C_AddOns = {IsAddOnLoaded = function(n) return M.loaded[n] == true end}
    GuildBankFrame = nil
end
-- Simulates LoadAddOn('Blizzard_GuildBankUI') from the PlayerInteractionManager.
function M.loadGuildBank()
    local f = new('Frame', 'GuildBankFrame', UIParent, 'BasicFrameTemplate')
    f:SetSize(750, 428); f.shown = false
    M.loaded.Blizzard_GuildBankUI = true
    return f
end
function M.find(pred) for _, o in ipairs(M.all) do if pred(o) then return o end end end
function M.texts(frame)
    local out = {}
    for _, o in ipairs(M.all) do
        local p = o.parent; local inside = false
        while p do if p == frame then inside = true; break end; p = p.parent end
        if inside and type(o.text) == 'string' then out[#out + 1] = o.text end
    end
    return table.concat(out, '\n')
end
return M
