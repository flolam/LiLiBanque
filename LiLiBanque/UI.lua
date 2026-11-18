-- LiLiBanque: /lili window (native Blizzard templates only) and the status line under the guild bank.
-- Templates checked in the Forever 1.60.1 interface source: ButtonFrameTemplate (+ ButtonFrameTemplate_HidePortrait,
-- SetTitle, Inset, CloseButton), UIPanelButtonTemplate, PanelTabButtonTemplate, InputScrollFrameTemplate.
local A,E=LiLiBanque.Addon,LiLiBanque.Export
local UI={}; LiLiBanque.UI=UI
local floor=math.floor
local GOLD,GREY,RED,ORANGE='|cffffd100','|cff9d9d9d','|cffff6060','|cffffa040'

local KIND_FR={deposit='dépôt',withdraw='retrait',repair='réparation',withdrawForTab='retrait (onglet)',buyTab='achat d’onglet',depositSummary='récap. dépôts'}
UI.KIND_FR=KIND_FR
function UI.ago(sec)
    sec=math.max(0,floor(sec or 0))
    if sec<60 then return 'à l’instant' end
    if sec<3600 then return 'il y a '..floor(sec/60)..' min' end
    if sec<86400 then return 'il y a '..floor(sec/3600)..' h' end
    return 'il y a '..floor(sec/86400)..' j'
end
function UI.when(ts)
    local s=ts and ts>0 and A.safe(date,'%d/%m %H:%M',ts)
    return s or '?'
end
function UI.classColored(name)
    local db=A.db; local members=db and db.roster and db.roster.members or {}
    local m=members[name]
    if not m and type(name)=='string' then
        local first=name:match('^(%S+)')
        for k,v in pairs(members) do if k:match('^(%S+)')==first then m=v; break end end
    end
    local c=m and RAID_CLASS_COLORS and RAID_CLASS_COLORS[m.classFile]
    if c and c.colorStr then return '|c'..c.colorStr..name..'|r' end
    return name
end
local function text(parent,font,justify)
    local fs=parent:CreateFontString(nil,'OVERLAY',font or 'GameFontHighlight')
    fs:SetJustifyH(justify or 'LEFT'); fs:SetWordWrap(false)
    return fs
end

-- Sections: one entry per guild tool. Only one today (Banque); tabs appear when there are two or more.
UI.sections={}
function UI.addSection(section) UI.sections[#UI.sections+1]=section end

---------------------------------------------------------------- Banque
local bank={key='banque',title='Banque'}
local KEYS={{'scan','Dernier relevé'},{'money','Solde relevé'},{'sync','Synchro'},{'gaps','Trous'}}
local ROWS=10
function bank.build(panel)
    local values={}
    local y=-6
    for _,k in ipairs(KEYS) do
        local key=text(panel,'GameFontNormal'); key:SetPoint('TOPLEFT',8,y); key:SetWidth(110); key:SetText(k[2])
        local val=text(panel,'GameFontHighlight'); val:SetPoint('TOPLEFT',122,y); val:SetPoint('RIGHT',panel,'RIGHT',-8,0)
        values[k[1]]=val
        if k[1]=='gaps' then val:SetWordWrap(true); val:SetHeight(80); y=y-80 else y=y-20 end
    end
    panel.values=values
    local head=text(panel,'GameFontNormal'); head:SetPoint('TOPLEFT',8,y-10); head:SetText('Derniers mouvements d’or')
    y=y-32
    panel.rows={}
    for i=1,ROWS do
        local r={}
        r.name=text(panel,'GameFontHighlightSmall'); r.name:SetPoint('TOPLEFT',8,y); r.name:SetWidth(150)
        r.amount=text(panel,'GameFontHighlightSmall','RIGHT'); r.amount:SetPoint('TOPLEFT',160,y); r.amount:SetWidth(100)
        r.kind=text(panel,'GameFontHighlightSmall'); r.kind:SetPoint('TOPLEFT',272,y); r.kind:SetWidth(90)
        r.ago=text(panel,'GameFontDisableSmall','RIGHT'); r.ago:SetPoint('TOPLEFT',362,y); r.ago:SetPoint('RIGHT',panel,'RIGHT',-8,0)
        panel.rows[i]=r; y=y-16
    end
    panel.empty=text(panel,'GameFontDisableSmall'); panel.empty:SetPoint('TOPLEFT',8,-178)
    panel.hint=text(panel,'GameFontDisableSmall'); panel.hint:SetPoint('BOTTOMLEFT',8,6); panel.hint:SetPoint('RIGHT',panel,'RIGHT',-8,0)
    panel.hint:SetText('Le fichier pour le site n’est écrit qu’au /reload ou à la déconnexion.')
end
function bank.lastScanText()
    local last=A.last
    if not A:active() then return ORANGE..A:inactiveReason()..'|r' end
    if A.pending then return 'relevé en cours…' end
    local shared=A.db and A.state and LiLiBanque.Core.bankScanTime(A.db,A.state,A.now())
    if shared and (not last or shared>last.at) then
        return UI.when(shared)..GREY..' ('..UI.ago(A.now()-shared)..', officiers)|r'
            ..(last and last.ok and (' · '..last.newLines..(last.newLines<2 and ' nouvelle ligne' or ' nouvelles lignes')..' au dernier relevé local') or '')
    end
    if not last then return GREY..'aucun : ouvrez la banque de guilde|r' end
    local when=UI.when(last.at)..GREY..' ('..UI.ago(A.now()-last.at)..')|r'
    if last.ok then return when..' · '..last.newLines..(last.newLines<2 and ' nouvelle ligne' or ' nouvelles lignes') end
    return when..' · '..RED..tostring(last.reason)..'|r'
end
function bank.refresh(panel)
    local v=panel.values; local db=A.db
    v.scan:SetText(bank.lastScanText())
    local money=db and db.bankMoney[#db.bankMoney]
    v.money:SetText(money and A.money(money.copper)..GREY..' · '..UI.when(money.at)..'|r' or GREY..'pas encore relevé|r')
    local sync=A.sync
    if not sync then v.sync:SetText(GREY..'inactive|r')
    else
        local seen={}
        for name,at in pairs(sync.seen or {}) do if A.clock()-at<=900 then seen[#seen+1]=name end end
        table.sort(seen)
        local parts={sync.lastSync and 'reçue '..UI.ago(A.clock()-sync.lastSync) or 'rien reçu cette session','file '..sync.q:size()}
        if sync.q.blocked then parts[#parts+1]=ORANGE..'en pause (instance, combat ou limite)|r' end
        parts[#parts+1]=#seen>0 and 'vus : '..table.concat(seen,', ') or 'aucun officier vu'
        v.sync:SetText(table.concat(parts,' · '))
    end
    local gaps=db and db.gaps or {}
    v.gaps:SetText(#gaps==0 and 'aucun' or RED..#gaps..'|r, dernier le '..UI.when(gaps[#gaps].at)..'\n'..RED..A:gapText()..'|r')
    -- Sorted once per change of the journal, not at every refresh.
    local ledger=db and db.ledger or {}; local n=0
    for _ in pairs(ledger) do n=n+1 end
    local key=n..':'..tostring(A.lastScan)..':'..tostring(sync and sync.transferred)..':'..tostring(ledger)
    if panel.sortKey~=key then
        local list={}
        for _,r in pairs(ledger) do list[#list+1]=r end
        table.sort(list,function(a,b) if a.ts~=b.ts then return a.ts>b.ts end; return a.id>b.id end)
        local top={}; for i=1,math.min(ROWS,#list) do top[i]=list[i] end
        panel.sorted,panel.sortKey=top,key
    end
    local list=panel.sorted
    local t=A.now()
    for i=1,ROWS do
        local row,r=panel.rows[i],list[i]
        if r then
            row.name:SetText(r.kind=='depositSummary' and GREY..'(système)|r' or UI.classColored(r.name))
            row.amount:SetText((r.kind=='deposit' or r.kind=='depositSummary') and A.money(r.copper) or RED..'-'..A.money(r.copper)..'|r')
            row.kind:SetText(KIND_FR[r.kind] or r.kind)
            row.ago:SetText((r.tsPrecision>=86400 and '~' or '')..UI.ago(t-r.ts))
        else for _,fs in pairs(row) do fs:SetText('') end end
    end
    panel.empty:SetText(n==0 and 'Aucun mouvement relevé.' or '')
end
UI.addSection(bank)

---------------------------------------------------------------- Window
local function savePosition()
    local f=UI.frame; if not f then return end
    local point,_,relPoint,x,y=f:GetPoint(1)
    if point then A.uiState().ui={point=point,relPoint=relPoint,x=floor(x+0.5),y=floor(y+0.5)} end
end
local function restorePosition()
    local f=UI.frame; local p=A.uiState().ui
    f:ClearAllPoints()
    if type(p)=='table' and type(p.point)=='string' and type(p.x)=='number' and type(p.y)=='number' then
        f:SetPoint(p.point,UIParent,p.relPoint or p.point,p.x,p.y)
    else f:SetPoint('CENTER',UIParent,'CENTER',0,40) end
end
UI.savePosition=savePosition
function UI.select(i)
    UI.current=i
    for n,s in ipairs(UI.sections) do s.panel:SetShown(n==i) end
    if UI.frame.numTabs and PanelTemplates_SetTab then PanelTemplates_SetTab(UI.frame,i) end
    UI.refresh()
end
function UI.create()
    if UI.frame then return UI.frame end
    local f=CreateFrame('Frame','LiLiBanqueFrame',UIParent,'ButtonFrameTemplate')
    UI.frame=f
    if ButtonFrameTemplate_HidePortrait then ButtonFrameTemplate_HidePortrait(f) end
    f:SetTitle('La Bande à Li Li')
    f:SetSize(480,490)
    f:SetToplevel(true); f:SetMovable(true); f:EnableMouse(true); f:SetClampedToScreen(true)
    f:RegisterForDrag('LeftButton')
    f:SetScript('OnDragStart',function(self) self:StartMoving() end)
    f:SetScript('OnDragStop',function(self) self:StopMovingOrSizing(); savePosition() end)
    f:HookScript('OnShow',function() A:guard('fenêtre',UI.refresh) end)
    f:HookScript('OnHide',function() UI.hideExport() end)
    table.insert(UISpecialFrames,'LiLiBanqueFrame') -- Échap ferme la fenêtre
    local header=text(f,'GameFontNormalLarge'); header:SetPoint('TOPLEFT',16,-34); UI.header=header
    local version=text(f,'GameFontDisableSmall','RIGHT'); version:SetPoint('TOPRIGHT',-14,-38); version:SetText('LiLiBanque '..LiLiBanque.Core.VERSION)
    for _,s in ipairs(UI.sections) do
        local panel=CreateFrame('Frame',nil,f.Inset)
        panel:SetPoint('TOPLEFT',f.Inset,'TOPLEFT',4,-4); panel:SetPoint('BOTTOMRIGHT',f.Inset,'BOTTOMRIGHT',-4,4)
        s.panel=panel; s.build(panel); panel:Hide()
    end
    if #UI.sections>1 then
        for i,s in ipairs(UI.sections) do
            local tab=CreateFrame('Button','LiLiBanqueFrameTab'..i,f,'PanelTabButtonTemplate')
            tab:SetID(i); tab:SetText(s.title)
            if i==1 then tab:SetPoint('TOPLEFT',f,'BOTTOMLEFT',12,2) else tab:SetPoint('LEFT','LiLiBanqueFrameTab'..(i-1),'RIGHT',-16,0) end
            tab:SetScript('OnClick',function() UI.select(i) end)
        end
        PanelTemplates_SetNumTabs(f,#UI.sections)
    end
    -- Bottom bar (ButtonFrameTemplate leaves 26 px under the inset).
    local scan=CreateFrame('Button',nil,f,'UIPanelButtonTemplate'); scan:SetSize(110,22); scan:SetPoint('BOTTOMRIGHT',-6,4)
    scan:SetText('Relever'); scan:SetScript('OnClick',function() A:guard('Relever',A.scanNow,A) end); UI.scanButton=scan
    local export=CreateFrame('Button',nil,f,'UIPanelButtonTemplate'); export:SetSize(110,22); export:SetPoint('RIGHT',scan,'LEFT',-4,0)
    export:SetText('Exporter'); export:SetScript('OnClick',function() A:guard('Exporter',UI.toggleExport) end); UI.exportButton=export
    local status=text(f,'GameFontHighlightSmall'); status:SetPoint('BOTTOMLEFT',12,10); status:SetPoint('RIGHT',export,'LEFT',-8,0); UI.footer=status
    UI.buildExport(f)
    f:Hide()
    restorePosition()
    UI.select(1)
    return f
end
function UI.isShown() return UI.frame~=nil and UI.frame:IsShown() end
function UI.show() UI.create():Show() end
function UI.toggle() local f=UI.create(); if f:IsShown() then f:Hide() else f:Show() end end
function UI.refresh()
    UI.refreshBankLine()
    if not UI.isShown() then return end
    local s=UI.sections[UI.current or 1]
    UI.header:SetText(UI.exporting and 'Export pour le site' or s.title)
    if not UI.exporting then s.refresh(s.panel) end
    UI.scanButton:SetEnabled(A.bankOpen==true and A:active() and not UI.exporting)
    UI.scanButton:SetShown(not UI.exporting)
    UI.exportButton:SetText(UI.exporting and 'Retour' or 'Exporter')
    UI.exportButton:SetEnabled(UI.exporting or A.db~=nil)
    UI.footer:SetText(A.bankOpen and 'Banque ouverte' or GREY..'Banque fermée|r')
end

---------------------------------------------------------------- Export
function UI.buildExport(f)
    local p=CreateFrame('Frame',nil,f.Inset)
    p:SetPoint('TOPLEFT',f.Inset,'TOPLEFT',4,-4); p:SetPoint('BOTTOMRIGHT',f.Inset,'BOTTOMRIGHT',-4,4); p:Hide()
    local hint=text(p,'GameFontHighlight'); hint:SetPoint('TOPLEFT',8,-6); hint:SetPoint('RIGHT',p,'RIGHT',-8,0); p.hint=hint
    local scroll=CreateFrame('ScrollFrame',nil,p,'InputScrollFrameTemplate')
    scroll:SetPoint('TOPLEFT',12,-32); scroll:SetPoint('BOTTOMRIGHT',-12,10)
    if scroll.CharCount then scroll.CharCount:Hide() end
    local box=scroll.EditBox
    box:SetWidth(420); box:SetFontObject('GameFontHighlightSmall')
    -- Read-only: any typing restores the export and selects it again.
    box:HookScript('OnTextChanged',function(self,user) if user and UI.exportText then self:SetText(UI.exportText); self:HighlightText() end end)
    box:HookScript('OnEditFocusGained',function(self) self:HighlightText() end)
    box:SetScript('OnEscapePressed',function(self) self:ClearFocus(); f:Hide() end)
    p.box=box; p.scroll=scroll
    p:SetScript('OnUpdate',function() A:guard('export',UI.stepExport) end)
    UI.exportPanel=p
end
function UI.startExport()
    UI.create()
    if not A.db then A.print('rien à exporter : addon inactif ('..A:inactiveReason()..')'); return end
    local p=UI.exportPanel
    UI.exporting=true; UI.exportText=nil; p.box:SetText('')
    for _,s in ipairs(UI.sections) do s.panel:Hide() end
    p:Show(); p.hint:SetText('Préparation de l’export…')
    UI.job=E.job(A.db)
    UI.refresh()
end
function UI.stepExport()
    local job=UI.job; if not job then return end
    local start=debugprofilestop and debugprofilestop()
    repeat
        local done=job:step()
        if done then break end
    until not start or debugprofilestop()-start>8 -- ~8 ms par image, sans geler l'écran
    if not job.done then return end
    UI.job=nil
    local p=UI.exportPanel
    if job.error then A:capture('export',job.error); p.hint:SetText(RED..'Échec de l’export : '..A.shortError(job.error)..'|r'); return end
    UI.exportText=job.result
    p.box:SetText(job.result); p.box:SetCursorPosition(0); p.box:SetFocus(); p.box:HighlightText()
    p.hint:SetText('Ctrl+C, puis collez-le sur le site de la guilde.')
end
function UI.hideExport()
    if not UI.exportPanel then return end
    UI.exporting=false; UI.job=nil; UI.exportText=nil
    UI.exportPanel.box:SetText(''); UI.exportPanel.box:ClearFocus(); UI.exportPanel:Hide()
end
function UI.toggleExport()
    if UI.exporting then UI.hideExport(); UI.select(UI.current or 1) else UI.startExport() end
end

---------------------------------------------------------------- Guild bank status line
function UI.attach()
    local gb=_G.GuildBankFrame; if not gb then return end
    if not UI.bankLine then
        local b=CreateFrame('Frame',nil,gb)
        b:SetPoint('TOPLEFT',gb,'BOTTOMLEFT',0,-2); b:SetPoint('TOPRIGHT',gb,'BOTTOMRIGHT',0,-2); b:SetHeight(24)
        local bg=b:CreateTexture(nil,'BACKGROUND'); bg:SetAllPoints(); bg:SetColorTexture(0,0,0,0.8)
        local t=text(b,'GameFontHighlight'); t:SetPoint('LEFT',10,0); t:SetPoint('RIGHT',b,'RIGHT',-80,0)
        local open=CreateFrame('Button',nil,b,'UIPanelButtonTemplate'); open:SetSize(70,20); open:SetPoint('RIGHT',-2,0)
        open:SetText('/lili'); open:SetScript('OnClick',function() A:guard('/lili',UI.toggle) end)
        UI.bankLine,UI.bankText=b,t
    end
    UI.refreshBankLine()
end
function UI.bankLineText()
    local prefix=GOLD..'LiLiBanque|r  '
    if not A:active() then return prefix..ORANGE..A:inactiveReason()..'|r' end
    if A.pending then return prefix..(A.status or 'relevé en cours…') end
    local last=A.last
    if not last then return prefix..'en attente du journal d’or' end
    local sync=A.sync and A.sync.lastSync and ' · synchro '..UI.ago(A.clock()-A.sync.lastSync) or ''
    if last.ok then
        return prefix..'journal relevé à '..(A.safe(date,'%H:%M',last.at) or '?')..' · '..last.newLines..(last.newLines<2 and ' nouvelle ligne' or ' nouvelles lignes')..sync
    end
    return prefix..RED..tostring(last.reason)..'|r'
end
function UI.refreshBankLine()
    if UI.bankText then UI.bankText:SetText(UI.bankLineText()) end
end
