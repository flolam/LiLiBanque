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
function Texture:SetColorTexture(r, g, b, a) self.color = {r, g, b, a}; self.texture = nil end
function Texture:SetTexture(t) self.texture = t; self.color = nil end
function Texture:GetTexture() return self.texture end
function Texture:SetTexCoord(...) self.texCoord = {...} end

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
-- NumberFontNormal: same file, used by ItemButton's Count (Blizzard_ItemButton/Shared/ItemButtonTemplate.xml).
M.fonts = {GameFontNormal = true, GameFontNormalLarge = true, GameFontNormalSmall = true, GameFontHighlight = true,
    GameFontHighlightSmall = true, GameFontDisableSmall = true, GameFontDisableLarge = true, NumberFontNormal = true}
function Frame:CreateFontString(name, layer, font)
    if font and not M.fonts[font] then error('police absente : '..font) end
    local fs = setmetatable({parent = self, font = font, layer = layer, shown = true}, FontString); M.all[#M.all + 1] = fs; return fs
end
function Frame:CreateTexture(name, layer)
    local t = setmetatable({parent = self, layer = layer, shown = true}, Texture); M.textures[#M.textures + 1] = t; return t
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
    M.all = {}; M.textures = {}
    UIParent = new('Frame', 'UIParent'); UISpecialFrames = {}
    -- GameTooltip (Blizzard_GameTooltip): only the widget methods the addon may call.
    M.tooltip = {shown = false}
    GameTooltip = {
        SetOwner = function(self, owner, anchor) M.tooltip = {owner = owner, anchor = anchor, shown = false} end,
        GetOwner = function(self) return M.tooltip.owner end,
        SetHyperlink = function(self, link) M.tooltip.link = link end,
        SetText = function(self, t) M.tooltip.text = t end,
        Show = function(self) M.tooltip.shown = true end,
        Hide = function(self) M.tooltip.shown = false; M.tooltip.owner = nil end,
        IsShown = function(self) return M.tooltip.shown end,
    }
    -- C_Item.GetItemIconByID (ItemDocumentation.lua): fileID or nil when unknown.
    M.icons = {}; M.iconCalls = 0
    C_Item = {GetItemIconByID = function(info) M.iconCalls = M.iconCalls + 1; return M.icons[info] end}
    CreateFrame = function(kind, name, parent, template) return new(kind, name, parent, template) end
    ButtonFrameTemplate_HidePortrait = function(f) f:SetPortraitShown(false) end
    PanelTemplates_SetNumTabs = function(f, n) f.numTabs = n end
    PanelTemplates_SetTab = function(f, i) f.selectedTab = i end
    RAID_CLASS_COLORS = {PALADIN = {colorStr = 'fff48cba'}, MAGE = {colorStr = 'ff3fc7eb'}, DRUID = {colorStr = 'ffff7c0a'}}
    Enum = {PlayerInteractionType = {GuildBanker = 10}}
    date = os.date
    GetBuildInfo = function() return '1.60.1', '71091', 'Nov 24 2026', 16001 end
    M.loaded = {}
    C_AddOns = {IsAddOnLoaded = function(n) return M.loaded[n] == true end}
    GuildBankFrame = nil
    M.tabs = {{name = 'Réserves', icon = 133784, viewable = true, slots = {}}}
    M.queries = {}; M.currentTab = 1
    M.fileIDs = {['Interface\\Icons\\INV_Misc_QuestionMark'] = 134400}
    GetFileIDFromPath = function(path) return M.fileIDs[path] or 0 end
    GetNumGuildBankTabs = function() return #M.tabs end
    GetCurrentGuildBankTab = function() return M.currentTab end
    GetGuildBankTabInfo = function(tab)
        local t = M.tabs[tab]
        if t then return t.name, t.icon, t.viewable, t.deposit ~= false, 0, 0 end
    end
    QueryGuildBankTab = function(tab)
        assert(M.tabs[tab] and M.tabs[tab].viewable, 'onglet inaccessible interrogé')
        M.queries[#M.queries + 1] = {tab = tab, at = GetTime()}
    end
    GetGuildBankItemInfo = function(tab, slot)
        assert(slot >= 1 and slot <= 98, 'emplacement hors limites')
        local s = M.tabs[tab].slots[slot]
        if s then return s.texture or 134400, s.count, s.locked or false, false, s.quality or 1 end
    end
    GetGuildBankItemLink = function(tab, slot)
        local s = M.tabs[tab].slots[slot]
        if s and not s.delayed then return '|cff1eff00|H'..s.item..'|h['..s.name..']|h|r' end
    end
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
