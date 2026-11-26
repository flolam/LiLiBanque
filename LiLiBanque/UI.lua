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
local function text(parent,font,justify,layer)
    local fs=parent:CreateFontString(nil,layer or 'OVERLAY',font or 'GameFontHighlight')
    fs:SetJustifyH(justify or 'LEFT'); fs:SetWordWrap(false)
    return fs
end

-- Sections: one entry per guild tool (Journal, Coffre); native tabs appear when there are two or more.
UI.sections={}
function UI.addSection(section) UI.sections[#UI.sections+1]=section end

---------------------------------------------------------------- Banque
-- Layout (Operate/Inspect): two facts side by side at first glance — the last gold-log reading
-- (left) and what officers have proven to each other (right) — then the latest gold movements.
-- Technical counters (queue size, coverage, digests) stay in /lili diag.
-- Colours: Li Li DA (guilde-li-li/da/README.md) lightened for text on the dark inset:
-- ivoire E5DAC3, ambre D6A46E, jade 3B756C → 7FC4B4, brique A84234 → E0705C (contrast on charcoal).
local IVORY,AMBER,JADE,BRICK='|cffe5dac3','|cffd6a46e','|cff7fc4b4','|cffe0705c'
UI.COLORS={ivory=IVORY,amber=AMBER,jade=JADE,brick=BRICK}
local bank={key='banque',title='Journal',heading='Journal de la banque'}
local ROWS,ROW_H,SPLIT=10,18,222
local function rule(parent,horizontal)
    local t=parent:CreateTexture(nil,'ARTWORK')
    t:SetColorTexture(0.84,0.64,0.43,0.28) -- ambre, assourdi
    if horizontal then t:SetHeight(1) else t:SetWidth(1) end
    return t
end
function bank.build(panel)
    local values={}
    -- Left: « Dernier relevé d’or ».
    local lhead=text(panel,'GameFontNormal'); lhead:SetPoint('TOPLEFT',10,-8); lhead:SetText('Dernier relevé d’or')
    values.scan=text(panel,'GameFontHighlight'); values.scan:SetPoint('TOPLEFT',10,-28); values.scan:SetWidth(SPLIT-20)
    values.scan:SetWordWrap(true); values.scan:SetHeight(30)
    values.money=text(panel,'GameFontHighlightSmall'); values.money:SetPoint('TOPLEFT',10,-62); values.money:SetWidth(SPLIT-20)
    values.stock=text(panel,'GameFontHighlightSmall'); values.stock:SetPoint('TOPLEFT',10,-78); values.stock:SetWidth(SPLIT-20)
    local split=rule(panel,false); split:SetPoint('TOPLEFT',SPLIT,-10); split:SetHeight(84)
    -- Right: « Entre officiers » (proof of P2P only, never total bank coverage).
    local rhead=text(panel,'GameFontNormal'); rhead:SetPoint('TOPLEFT',SPLIT+12,-8); rhead:SetText('Entre officiers')
    values.sync=text(panel,'GameFontHighlight'); values.sync:SetPoint('TOPLEFT',SPLIT+12,-28); values.sync:SetPoint('TOPRIGHT',panel,'TOPRIGHT',-10,-28)
    values.sync:SetWordWrap(true); values.sync:SetHeight(30)
    values.peers=text(panel,'GameFontHighlightSmall'); values.peers:SetPoint('TOPLEFT',SPLIT+12,-60); values.peers:SetPoint('TOPRIGHT',panel,'TOPRIGHT',-10,-60)
    values.peers:SetWordWrap(true); values.peers:SetHeight(40)
    local top=rule(panel,true); top:SetPoint('TOPLEFT',8,-102); top:SetPoint('TOPRIGHT',panel,'TOPRIGHT',-8,-102)
    -- Gap alert: only takes room when a gap exists.
    local alert=CreateFrame('Frame',nil,panel); alert:SetPoint('TOPLEFT',6,-108); alert:SetPoint('TOPRIGHT',panel,'TOPRIGHT',-6,-108); alert:SetHeight(48)
    local abg=alert:CreateTexture(nil,'BACKGROUND'); abg:SetAllPoints(); abg:SetColorTexture(0.66,0.26,0.20,0.22) -- brique
    values.gaps=text(alert,'GameFontHighlightSmall'); values.gaps:SetPoint('TOPLEFT',8,-5); values.gaps:SetPoint('TOPRIGHT',alert,'TOPRIGHT',-8,-5)
    values.gaps:SetWordWrap(true); values.gaps:SetHeight(38)
    alert:Hide(); panel.alert=alert
    panel.values=values
    -- Latest movements.
    local list=CreateFrame('Frame',nil,panel); list:SetHeight(22+ROWS*ROW_H); panel.list=list
    local head=text(list,'GameFontNormal'); head:SetPoint('TOPLEFT',4,0); head:SetText('Derniers mouvements d’or'); panel.listHead=head
    panel.rows={}
    for i=1,ROWS do
        local y=-20-(i-1)*ROW_H
        local r={}
        if i%2==1 then
            local z=list:CreateTexture(nil,'BACKGROUND'); z:SetPoint('TOPLEFT',0,y+2); z:SetPoint('TOPRIGHT',list,'TOPRIGHT',0,y+2); z:SetHeight(ROW_H)
            z:SetColorTexture(0.90,0.85,0.76,0.05) -- ivoire, rangée alternée
        end
        r.name=text(list,'GameFontHighlight'); r.name:SetPoint('TOPLEFT',6,y); r.name:SetWidth(170)
        r.amount=text(list,'GameFontHighlight','RIGHT'); r.amount:SetPoint('TOPLEFT',178,y); r.amount:SetWidth(112)
        r.kind=text(list,'GameFontHighlightSmall'); r.kind:SetPoint('TOPLEFT',302,y-1); r.kind:SetWidth(78)
        r.ago=text(list,'GameFontHighlightSmall','RIGHT'); r.ago:SetPoint('TOPLEFT',380,y-1); r.ago:SetPoint('TOPRIGHT',list,'TOPRIGHT',-6,y-1)
        panel.rows[i]=r
    end
    panel.empty=text(list,'GameFontDisableSmall'); panel.empty:SetPoint('TOPLEFT',6,-22)
    panel.hint=text(panel,'GameFontHighlightSmall'); panel.hint:SetPoint('BOTTOMLEFT',10,6); panel.hint:SetPoint('BOTTOMRIGHT',panel,'BOTTOMRIGHT',-10,6)
    panel.hint:SetText('Fichier WoW mis à jour au /reload ou à la déconnexion.')
    bank.place(panel,false)
end
function bank.place(panel,withAlert)
    if panel.alertShown==withAlert then return end
    panel.alertShown=withAlert
    panel.alert:SetShown(withAlert)
    panel.list:ClearAllPoints()
    local y=withAlert and -164 or -112
    panel.list:SetPoint('TOPLEFT',panel,'TOPLEFT',6,y)
    panel.list:SetPoint('TOPRIGHT',panel,'TOPRIGHT',-6,y)
end
-- Officer sync state, read only through the transport contract sync:status(now) →
-- {state='idle'|'waiting'|'checking'|'catchup'|'matched'|'paused'|'blocked', peer=name?}.
-- Missing/old function or unknown state → neutral wording, never « à jour » or a percentage.
local SYNC_TEXT={
    idle={GREY,'Rien à comparer pour l’instant'},
    waiting={GREY,'En attente d’un autre officier'},
    checking={IVORY,'Comparaison avec %s…','Comparaison en cours…'},
    catchup={AMBER,'Rattrapage auprès de %s','Rattrapage en cours'},
    matched={JADE,'Même journal que %s','Même journal qu’un autre officier'},
    paused={AMBER,'En pause : combat, instance ou envoi limité'},
    blocked={BRICK,'Bloquée, détails avec /lili diag'},
}
UI.SYNC_TEXT=SYNC_TEXT
function UI.syncStatus(sync,now)
    if type(sync)~='table' or type(sync.status)~='function' then return nil end
    local ok,st=pcall(sync.status,sync,now)
    if not ok or type(st)~='table' or not SYNC_TEXT[st.state] then return nil end
    local peer=type(st.peer)=='string' and st.peer~='' and st.peer or nil
    return st.state,peer
end
function bank.syncText(sync,now)
    if not sync then return GREY..'Inactive|r' end
    local state,peer=UI.syncStatus(sync,now)
    if not state then return IVORY..'Synchro active|r' end
    local t=SYNC_TEXT[state]
    local s=peer and t[2]:find('%s',1,true) and t[2]:format(UI.classColored(peer)..t[1]) or (t[3] or t[2])
    return t[1]..s..'|r',state
end
function bank.lastScanText()
    local last=A.last
    if not A:active() then return ORANGE..A:inactiveReason()..'|r' end
    if A.pending then return 'relevé en cours…' end
    local shared=A.db and A.state and LiLiBanque.Core.bankScanTime(A.db,A.state,A.now())
    local function lines(n) return n..(n<2 and ' nouvelle ligne' or ' nouvelles lignes') end
    -- Line 1: when (local time + age). Line 2: who, and what that reading brought.
    if shared and (not last or shared>last.at) then
        return UI.when(shared)..GREY..' · '..UI.ago(A.now()-shared)..'|r\n'
            ..GREY..'partagé par les officiers'..(last and last.ok and (' · chez vous : '..lines(last.newLines)) or '')..'|r'
    end
    if not last then return GREY..'aucun pour l’instant\nouvrez la banque de guilde|r' end
    local when=UI.when(last.at)..GREY..' · '..UI.ago(A.now()-last.at)..'|r\n'
    if last.ok then return when..GREY..'par vous · |r'..lines(last.newLines) end
    return when..RED..tostring(last.reason)..'|r'
end
function bank.refresh(panel)
    local v=panel.values; local db=A.db
    v.scan:SetText(bank.lastScanText())
    v.stock:SetText(GREY..'Coffre :|r '..A:stockText():gsub('^Coffre : ',''))
    local money=db and db.bankMoney[#db.bankMoney]
    -- The balance date is only repeated when it is older than the reading shown just above.
    local scanAt=math.max(A.last and A.last.at or 0,db and A.state and LiLiBanque.Core.bankScanTime(db,A.state,A.now()) or 0)
    local stale=money and money.at<scanAt-60
    v.money:SetText(GREY..'Solde :|r '..(money and A.money(money.copper)..(stale and GREY..' le '..UI.when(money.at)..'|r' or '') or GREY..'pas encore relevé|r'))
    local sync=A.sync
    v.sync:SetText((bank.syncText(sync,A.clock())))
    if not sync then v.peers:SetText('')
    else
        local seen={}
        for name,at in pairs(sync.seen or {}) do if A.clock()-at<=900 then seen[#seen+1]=name end end
        table.sort(seen)
        for i,name in ipairs(seen) do seen[i]=UI.classColored(name) end
        local who=#seen>0 and 'Officiers vus : '..table.concat(seen,GREY..', ') or 'Aucun officier vu ces 15 min'
        v.peers:SetText(who..(sync.lastSync and '\n'..GREY..'Dernier ajout reçu '..UI.ago(A.clock()-sync.lastSync)..'|r' or ''))
    end
    local gaps=db and db.gaps or {}
    v.gaps:SetText(#gaps==0 and 'aucun' or BRICK..'Trous dans le journal : |r'..RED..#gaps..'|r, dernier le '..UI.when(gaps[#gaps].at)..'\n'..RED..A:gapText()..'|r')
    bank.place(panel,#gaps>0)
    -- Sorted once per change of the journal, not at every refresh.
    local ledger=db and db.ledger or {}; local n=0
    for _ in pairs(ledger) do n=n+1 end
    panel.listHead:SetText('Derniers mouvements d’or'..(n>ROWS and GREY..' · '..ROWS..' affichés|r' or ''))
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
            if r.kind=='buyTab' then row.amount:SetText(GREY..'—|r')
            elseif r.kind=='deposit' or r.kind=='depositSummary' then row.amount:SetText(A.money(r.copper))
            else row.amount:SetText(RED..'-'..A.money(r.copper)..'|r') end
            row.kind:SetText(KIND_FR[r.kind] or r.kind)
            row.ago:SetText((r.tsPrecision>=86400 and '~' or '')..UI.ago(t-r.ts))
        else for _,fs in pairs(row) do fs:SetText('') end end
    end
    panel.empty:SetText(n==0 and 'Aucun mouvement relevé.' or '')
end
UI.addSection(bank)

---------------------------------------------------------------- Coffre
-- Read-only browser of the tab readings saved by the stock scanner (A.db.stock[tab], Addon.lua).
-- Grid copied from Blizzard_GuildBankUI/Mainline (Forever d9c22e32): 98 slots in 7 columns of 14;
-- OnLoad maps slot i to Columns[ceil((i-0.5)/14)].Buttons[(i-1)%14+1], and the XML puts Button2..7
-- under the previous one and Button8 to the right of Button1. Slots here are plain frames, never
-- GuildBankItemButtonTemplate (its OnClick/OnDragStart pick up and move bank items).
-- Access: a tab is listed only when THIS character's GetGuildBankTabInfo(tab) third return
-- (isViewable) is true, re-read at each refresh (1 s while shown) and at each hover. A saved
-- reading never proves access on its own: unknown (nil, /reload before the bank) shows nothing.
local vault={key='coffre',title='Coffre',heading='Coffre de guilde'}
local SLOTS,PER_GROUP,ROWS_PER_COL=98,14,7
local SLOT,SLOT_GAP,GROUP_GAP=26,3,10 -- the gutter (10) reads as the native column break
local GROUP_PITCH=2*SLOT+SLOT_GAP+GROUP_GAP
local GRID_W=6*GROUP_PITCH+2*SLOT+SLOT_GAP
local GRID_H=ROWS_PER_COL*SLOT+(ROWS_PER_COL-1)*SLOT_GAP
local PANEL_W=462 -- frame 480 − Inset (4 + 6) − panel (4 + 4)
local MAX_TABS=8 -- MAX_GUILDBANK_TABS
UI.SLOT,UI.SLOT_GAP,UI.GROUP_PITCH=SLOT,SLOT_GAP,GROUP_PITCH
local QUESTION='Interface\\Icons\\INV_Misc_QuestionMark'
UI.QUESTION=QUESTION
-- Blizzard item-quality colours, border only from Uncommon up (as the native bag/bank buttons).
local QUALITY={[2]={0.12,1,0},[3]={0,0.44,0.87},[4]={0.64,0.21,0.93},[5]={1,0.5,0},[6]={0.9,0.8,0.5},[7]={0,0.8,1}}
local ITEM_LINK='^item:%d+[:%d%-]*$'
-- Tabs this character may see right now, in bank order. Never reads A.db.stock.
function UI.coffreTabs()
    local out={tabs={},bought=nil,hidden=0,unknown=0}
    local n=A.safe(GetNumGuildBankTabs)
    if type(n)~='number' or n<0 or n>MAX_TABS or n~=floor(n) then return out end
    out.bought=n
    for i=1,n do
        local name,icon,viewable=A.safe(GetGuildBankTabInfo,i)
        if viewable==true then
            out.tabs[#out.tabs+1]={index=i,name=type(name)=='string' and name~='' and name or ('Onglet '..i),icon=icon}
        elseif viewable==false then out.hidden=out.hidden+1
        else out.unknown=out.unknown+1 end
    end
    return out
end
function UI.tabViewable(tab)
    if not A:active() then return false end
    local n=A.safe(GetNumGuildBankTabs)
    if type(n)~='number' or type(tab)~='number' or tab<1 or tab>n then return false end
    local _,_,viewable=A.safe(GetGuildBankTabInfo,tab)
    return viewable==true
end
function UI.coffreSelect(tab)
    if not UI.tabViewable(tab) then return end
    UI.coffreTab=tab; UI.refresh()
end
UI.iconCache={}
local function itemIcon(link)
    local id=type(link)=='string' and link:match(ITEM_LINK) and tonumber(link:match('^item:(%d+)'))
    if not id then return nil,false end
    local cached=UI.iconCache[id]; if cached then return cached,true end
    local getter=C_Item and C_Item.GetItemIconByID
    if type(getter)~='function' then return nil,false end
    local icon=A.safe(getter,id)
    if type(icon)=='number' and icon>0 or type(icon)=='string' and icon~='' then UI.iconCache[id]=icon; return icon,true end
    return nil,true -- cold item cache: retried later, spaced out
end
local function tooltipOwner()
    return GameTooltip and GameTooltip.GetOwner and GameTooltip:GetOwner()
end
local function hideCoffreTooltip(includeTabs)
    local owner=tooltipOwner()
    if owner and (owner.liliSlot or includeTabs and owner.liliCoffreTab) then GameTooltip:Hide() end
end
function UI.slotEnter(s)
    if not s.item or not s.tab or not GameTooltip or not UI.tabViewable(s.tab) then return end
    GameTooltip:SetOwner(s,'ANCHOR_RIGHT'); GameTooltip:SetHyperlink(s.item); GameTooltip:Show()
end
function UI.chipEnter(c)
    if not c.tab or not GameTooltip or not UI.tabViewable(c.tab) then return end
    GameTooltip:SetOwner(c,'ANCHOR_BOTTOM'); GameTooltip:SetText(c.name or ''); GameTooltip:Show()
end
local function leave(self) if tooltipOwner()==self then GameTooltip:Hide() end end
function vault.build(panel)
    panel.chips={}
    for i=1,MAX_TABS do
        local c=CreateFrame('Button',nil,panel); c.liliCoffreTab=true; c:SetHeight(24); c:Hide()
        c.bg=c:CreateTexture(nil,'BACKGROUND'); c.bg:SetAllPoints()
        c.mark=c:CreateTexture(nil,'BORDER'); c.mark:SetPoint('BOTTOMLEFT',0,0); c.mark:SetPoint('BOTTOMRIGHT',c,'BOTTOMRIGHT',0,0); c.mark:SetHeight(2)
        c.mark:SetColorTexture(0.84,0.64,0.43,0.9) -- ambre
        c.icon=c:CreateTexture(nil,'ARTWORK'); c.icon:SetSize(18,18); c.icon:SetPoint('LEFT',3,0); c.icon:SetTexCoord(0.07,0.93,0.07,0.93)
        c.label=text(c,'GameFontHighlightSmall'); c.label:SetPoint('LEFT',25,0); c.label:SetPoint('RIGHT',c,'RIGHT',-4,0)
        c:SetScript('OnClick',function(self) A:guard('Coffre',UI.coffreSelect,self.tab) end)
        c:SetScript('OnEnter',function(self) A:guard('Coffre',UI.chipEnter,self) end)
        c:SetScript('OnLeave',leave)
        panel.chips[i]=c
    end
    local top=rule(panel,true); top:SetPoint('TOPLEFT',8,-40); top:SetPoint('TOPRIGHT',panel,'TOPRIGHT',-8,-40)
    panel.tabTitle=text(panel,'GameFontNormal'); panel.tabTitle:SetPoint('TOPLEFT',10,-48); panel.tabTitle:SetWidth(270)
    panel.summary=text(panel,'GameFontHighlightSmall','RIGHT'); panel.summary:SetPoint('TOPLEFT',284,-50); panel.summary:SetPoint('TOPRIGHT',panel,'TOPRIGHT',-10,-50)
    panel.detail=text(panel,'GameFontHighlightSmall'); panel.detail:SetPoint('TOPLEFT',10,-66); panel.detail:SetPoint('TOPRIGHT',panel,'TOPRIGHT',-10,-66)
    local grid=CreateFrame('Frame',nil,panel); grid:SetSize(GRID_W,GRID_H); grid:SetPoint('TOPLEFT',floor((PANEL_W-GRID_W)/2),-88)
    panel.grid=grid; panel.slots={}
    for i=1,SLOTS do
        local group=floor((i-1)/PER_GROUP); local within=(i-1)%PER_GROUP
        local col,row=floor(within/ROWS_PER_COL),within%ROWS_PER_COL
        local s=CreateFrame('Frame',nil,grid); s:SetSize(SLOT,SLOT); s.liliSlot=i
        s:SetPoint('TOPLEFT',grid,'TOPLEFT',group*GROUP_PITCH+col*(SLOT+SLOT_GAP),-row*(SLOT+SLOT_GAP))
        local bg=s:CreateTexture(nil,'BACKGROUND'); bg:SetAllPoints(); bg:SetColorTexture(0.90,0.85,0.76,0.07) -- ivoire, case vide
        s.border=s:CreateTexture(nil,'BORDER'); s.border:SetAllPoints(); s.border:Hide()
        s.icon=s:CreateTexture(nil,'ARTWORK'); s.icon:SetPoint('TOPLEFT',2,-2); s.icon:SetPoint('BOTTOMRIGHT',s,'BOTTOMRIGHT',-2,2)
        s.icon:SetTexCoord(0.07,0.93,0.07,0.93); s.icon:Hide()
        s.count=text(s,'NumberFontNormal','RIGHT'); s.count:SetPoint('BOTTOMRIGHT',-1,2)
        s:EnableMouse(true)
        s:SetScript('OnEnter',function(self) A:guard('Coffre',UI.slotEnter,self) end)
        s:SetScript('OnLeave',leave)
        panel.slots[i]=s
    end
    panel.message=text(panel,'GameFontHighlight','CENTER'); panel.message:SetPoint('TOPLEFT',20,-150); panel.message:SetPoint('TOPRIGHT',panel,'TOPRIGHT',-20,-150)
    panel.message:SetWordWrap(true); panel.message:SetHeight(60)
    panel.hint=text(panel,'GameFontHighlightSmall'); panel.hint:SetPoint('BOTTOMLEFT',10,6); panel.hint:SetPoint('BOTTOMRIGHT',panel,'BOTTOMRIGHT',-10,6)
end
local function clearSlot(s)
    s.tab=nil; s.item=nil; s.missing=nil
    s.icon:SetTexture(nil); s.icon:Hide(); s.count:SetText(''); s.border:Hide()
end
function vault.clear(panel)
    hideCoffreTooltip()
    if not panel.paintKey then return end
    for _,s in ipairs(panel.slots) do clearSlot(s) end
    panel.paintKey=nil; panel.missing=nil
end
function vault.paint(panel,tab,snap,t)
    local key=tab..':'..tostring(snap)..':'..tostring(snap.scannedAt)
    local full=panel.paintKey~=key
    if not full and not (panel.missing and t>=panel.retryAt and panel.tries<30) then return end
    if full then hideCoffreTooltip(); panel.paintKey=key; panel.tries=0 else panel.tries=panel.tries+1 end
    local missing=false
    for i,s in ipairs(panel.slots) do
        if full or s.missing then
            local it=snap.slots[i]
            if type(it)=='table' and (it.item or it.count) then
                local icon,retry=itemIcon(it.item)
                s.missing=retry and not icon or nil; missing=missing or s.missing==true
                s.tab=tab; s.item=type(it.item)=='string' and it.item:match(ITEM_LINK) and it.item or nil
                s.icon:SetTexture(icon or QUESTION); s.icon:Show()
                local n=type(it.count)=='number' and it.count or 0
                s.count:SetText(n>1 and tostring(n) or '')
                local q=QUALITY[it.quality]
                if q then s.border:SetColorTexture(q[1],q[2],q[3],0.85); s.border:Show() else s.border:Hide() end
            else clearSlot(s) end
        end
    end
    panel.missing=missing or nil; panel.retryAt=t+2
end
function vault.refresh(panel)
    local model=A.db and A:active() and UI.coffreTabs() or {tabs={},hidden=0,unknown=0}
    local tabs=model.tabs; local sel
    for _,tb in ipairs(tabs) do if tb.index==UI.coffreTab then sel=tb end end
    sel=sel or tabs[1]; UI.coffreTab=sel and sel.index or nil
    -- Tab selector: real names and order, width shared by the visible tabs.
    local n=#tabs; local w=n>0 and math.min(124,floor((PANEL_W-20-(n-1)*4)/n)) or 0
    for i,c in ipairs(panel.chips) do
        local tb=tabs[i]
        if tooltipOwner()==c and (not tb or tb.index~=c.tab or tb.name~=c.name) then GameTooltip:Hide() end
        if tb then
            local on=tb==sel
            c.tab,c.name=tb.index,tb.name
            c:ClearAllPoints(); c:SetPoint('TOPLEFT',panel,'TOPLEFT',10+(i-1)*(w+4),-8); c:SetWidth(w)
            c.bg:SetColorTexture(0.84,0.64,0.43,on and 0.20 or 0.06)
            c.mark:SetShown(on)
            c.icon:SetTexture(tb.icon or QUESTION); c.icon:Show()
            c.label:SetText((on and AMBER or IVORY)..tb.name..'|r'); c.label:SetShown(w>=80)
            c:Show()
        else
            c.tab,c.name=nil,nil; c.label:SetText(''); c.icon:SetTexture(nil); c:Hide()
        end
    end
    local hidden=model.hidden>0 and ' · '..(model.hidden==1 and '1 onglet non visible pour votre rang' or model.hidden..' onglets non visibles pour votre rang') or ''
    panel.hint:SetText(GREY..'Lecture seule'..hidden..'|r')
    local function nothing(msg)
        panel.tabTitle:SetText(''); panel.summary:SetText(''); panel.detail:SetText('')
        vault.clear(panel); panel.grid:Hide(); panel.message:SetText(msg)
    end
    if not A.db or not A:active() then return nothing(ORANGE..A:inactiveReason()..'|r') end
    if not sel then
        if model.bought==0 and A.bankOpen then return nothing('Aucun onglet acheté.') end
        if model.bought and model.bought>0 and model.unknown==0 then return nothing('Aucun onglet visible pour votre rang.') end
        return nothing('Onglets pas encore connus.\n'..GREY..'Ouvrez la banque de guilde pour vérifier vos droits.|r')
    end
    local snap=A.db.stock and A.db.stock[sel.index]
    if type(snap)~='table' or type(snap.slots)~='table' or type(snap.scannedAt)~='number' then
        nothing('Pas encore relevé.\n'..GREY..(A.bankOpen and 'Sélectionnez l’onglet « '..sel.name..' » dans la banque de guilde.'
            or 'Ouvrez la banque de guilde, puis l’onglet « '..sel.name..' ».')..'|r')
        panel.tabTitle:SetText(AMBER..sel.name..'|r'); return
    end
    panel.message:SetText(''); panel.grid:Show()
    panel.tabTitle:SetText(AMBER..sel.name..'|r')
    local free=SLOTS
    for i=1,SLOTS do if type(snap.slots[i])=='table' then free=free-1 end end
    panel.summary:SetText(free==SLOTS and GREY..'vide au relevé|r' or free..(free==1 and ' place libre' or ' places libres'))
    local by=type(snap.scannedBy)=='string' and snap.scannedBy~='' and GREY..' · par |r'..UI.classColored(snap.scannedBy) or ''
    local busy=A.bankOpen and A.stockScan and AMBER..' · relevé en cours…|r' or ''
    panel.detail:SetText(GREY..'Relevé le |r'..UI.when(snap.scannedAt)..GREY..' · '..UI.ago(A.now()-snap.scannedAt)..'|r'..by..busy)
    vault.paint(panel,sel.index,snap,A.clock())
end
UI.addSection(vault)

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
    if UI.exporting then UI.hideExport() end -- a section tab behind the export leaves it cleanly
    hideCoffreTooltip(true)
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
    f:SetSize(480,480) -- fits 10 rows + the gap alert (3 lines) without an empty band
    f:SetToplevel(true); f:SetMovable(true); f:EnableMouse(true); f:SetClampedToScreen(true)
    f:RegisterForDrag('LeftButton')
    f:SetScript('OnDragStart',function(self) self:StartMoving() end)
    f:SetScript('OnDragStop',function(self) self:StopMovingOrSizing(); savePosition() end)
    f:HookScript('OnShow',function() A:guard('fenêtre',UI.refresh) end)
    f:HookScript('OnHide',function() UI.hideExport(); hideCoffreTooltip(true) end)
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
    export:SetText('Exporter…'); export:SetScript('OnClick',function() A:guard('Exporter',UI.toggleExport) end); UI.exportButton=export
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
    UI.header:SetText(UI.exporting and 'Export pour le site' or s.heading or s.title)
    if not UI.exporting then s.refresh(s.panel) end
    UI.scanButton:SetEnabled(A.bankOpen==true and A:active() and not UI.exporting)
    UI.scanButton:SetShown(not UI.exporting)
    UI.exportButton:SetText(UI.exporting and 'Retour' or 'Exporter…')
    UI.exportButton:SetEnabled(UI.exporting or A.db~=nil)
    UI.footer:SetText(A.bankOpen and JADE..'Banque ouverte|r' or GREY..'Banque fermée|r')
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
    hideCoffreTooltip(true)
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
