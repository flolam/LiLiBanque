local C,S=LiLiBanque.Core,LiLiBanque.Sync
local A={guild='La Bande à Li Li',newLines=0,nextBank=0,nextQuery=0,nextRoster=0,nextEvents=0,nextInit=0}; LiLiBanque.Addon=A
-- Enum.PlayerInteractionType.GuildBanker = 10 (PlayerInteractionManagerConstantsDocumentation, Forever 1.60.1).
local GUILD_BANKER=10
local KINDS={deposit=true,withdraw=true,repair=true,withdrawForTab=true,buyTab=true,depositSummary=true}
local floor=math.floor
local function shortError(err)
    local s=tostring(err==nil and '?' or err):gsub('^.-AddOns[/\\]LiLiBanque[/\\]',''):gsub('[\r\n]+',' ')
    if #s>180 then s=s:sub(1,177)..'...' end
    return s
end
A.shortError=shortError
local function pack(...) return {n=select('#',...),...} end
local function safe(fn,...)
    if type(fn)~='function' then return nil end
    local r=pack(pcall(fn,...))
    if not r[1] then A.lastApiError=shortError(r[2]); return nil end
    for i=2,r.n do if issecretvalue and issecretvalue(r[i]) then return nil end end
    return unpack(r,2,r.n)
end
A.safe=safe
local function now() return safe(GetServerTime) or safe(time) or 0 end
local function clock() return safe(GetTime) or now() end
A.now,A.clock=now,clock
local function printFR(s) if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage('|cffffd100LiLiBanque|r : '..s) end end
A.print=printFR
local function info(name) return C_GuildInfo and C_GuildInfo[name] or _G[name] end
local function order(rows,newestFirst)
    if #rows<2 then return rows end
    local reverse=rows[1].ts>rows[#rows].ts or rows[1].ts==rows[#rows].ts and newestFirst
    if reverse then local o={}; for i=#rows,1,-1 do o[#o+1]=rows[i] end; return o end
    return rows
end
local function lines(n) return n..(n<2 and ' nouvelle ligne' or ' nouvelles lignes') end
function A.money(c)
    c=floor(tonumber(c) or 0)
    local g,s,cu=floor(c/10000),floor(c/100)%100,c%100
    local out={}
    if g>0 then out[#out+1]=g..' po' end
    if s>0 then out[#out+1]=s..' pa' end
    if cu>0 or #out==0 then out[#out+1]=cu..' pc' end
    return table.concat(out,' ')
end
-- Tolerant comparison for the guild name: case, spaces (incl. NBSP) and « à/a ».
function A.normalizeGuild(s)
    if type(s)~='string' then return nil end
    s=s:gsub('\194\160',' '):gsub('\226\128\175',' '):gsub('\195[\160\128\162\130]','a')
    s=s:lower():gsub('%s+',' '):gsub('^ ',''):gsub(' $','')
    return s
end
function A:inGuild()
    local raw=safe(GetGuildInfo,'player'); self.guildRead=raw
    return raw~=nil and A.normalizeGuild(raw)==A.normalizeGuild(self.guild)
end
function A:active()
    return self.db~=nil and self:inGuild()
end
local function uiState()
    if type(LiLiBanqueState)~='table' then LiLiBanqueState={} end
    return LiLiBanqueState
end
A.uiState=uiState

-- Errors are kept (short message) for /lili diag instead of being swallowed.
function A:capture(where,err)
    local e={msg=shortError(err),where=where,at=now()}
    self.lastError=e; self.errors=(self.errors or 0)+1
    local st=LiLiBanqueState; if type(st)=='table' then st.lastError=e end
    self.status='Erreur interne : '..e.msg
    if self.bankOpen and not self.reported then self.reported=true; printFR('erreur pendant le relevé : '..e.msg..' (/lili diag)')
    elseif self.errors==1 then printFR('erreur interne, détails avec /lili diag') end
    pcall(self.updateUI,self)
end
function A:guard(where,fn,...)
    local ok,err=pcall(fn,...)
    if not ok then self:capture(where,err) end
end

function A:init()
    self.nextInit=clock()+5
    if not self:inGuild() then
        if self.guildRead then self.status='Autre guilde : « '..self.guildRead..' »'
        elseif safe(IsInGuild)==true then self.status='Infos de guilde pas encore reçues'
        else self.status='Pas dans la guilde La Bande à Li Li' end
        return
    end
    local name=safe(GetUnitName,'player',true)
    if not name then local first,last=safe(UnitName,'player'); if first then name=first..(last and last~='' and ' '..last or '') end end
    if not name or name=='' or name=='Unknown' then self.status='Nom du personnage pas encore disponible'; return end
    local db,state,err=C.init(LiLiBanqueDB,uiState(),self.guild)
    if not db then self.status=err; return end
    if db.guild~=self.guild then self.status='Données d’une autre guilde : relevé suspendu'; return end
    LiLiBanqueDB,LiLiBanqueState=db,state; self.db,self.state,self.name=db,state,name
    db.stock=db.stock or {}
    if not self.last and state.lastScan then self.last=C.copy(state.lastScan) end
    if not self.sync then
        local registration=safe(C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix,S.PREFIX)
        self.prefixOK=registration==true or registration==0 or registration==1
        self.sync=S.new(db,state,name,self.guild,function(msg)
            if not self.prefixOK or not self:active() or not C_ChatInfo or not C_ChatInfo.SendAddonMessage then return 9 end
            return C_ChatInfo.SendAddonMessage(S.PREFIX,msg,'OFFICER')
        end,clock,now)
    end
    self.status='Prêt'; self:request(); self.sync:hello(); self:remind()
    if self.bankOpen then self:startStock() end
end
-- One short reminder per character per two hours, including /reloads.
function A:remind()
    if not self:active() or not self.state or self.state.reminderEnabled==false
        or safe(info('CanViewOfficerNote'))~=true or safe(InCombatLockdown)==true or safe(IsInInstance)==true then return end
    if not next(self.db.ledger) and #self.db.bankMoney==0 then return end
    local at=now(); local lastReminder=self.state.lastReminderAt
    if type(lastReminder)=='number' and at-lastReminder<7200 then return end
    local scan=C.bankScanTime(self.db,self.state,at)
    local baseline=scan
    if not baseline then
        for _,m in ipairs(self.db.bankMoney) do
            if C.validScanAt(m.at,at) and (not baseline or m.at>baseline) then baseline=m.at end
        end
    end
    if not baseline then return end
    local day=tonumber(safe(date,'%w',at)) -- PC local time, Sunday=0
    if not day then return end
    local threshold=(day==3 or day==4) and 4*3600 or 12*3600
    if at-baseline<=threshold then return end
    local text=scan and ('Banque pas relevée depuis '..floor((at-scan)/3600)..' h') or 'Banque : dernier relevé du journal d’or inconnu'
    printFR(text..' : passe à la banque de guilde si tu peux, le journal d’or ne garde que les dernières lignes.')
    self.state.lastReminderAt=at
end
-- Reason shown in chat and on the bank line when the addon cannot scan.
function A:inactiveReason()
    if not self:inGuild() then
        if self.guildRead then return 'inactif : guilde lue « '..self.guildRead..' », attendue « '..self.guild..' »' end
        if safe(IsInGuild)==true then return 'inactif : infos de guilde pas encore reçues, réessayez dans quelques secondes' end
        return 'inactif : aucune guilde lue par le jeu'
    end
    return 'inactif : '..(self.status or 'en attente')
end
function A:recordMoney()
    if not self:active() then return end
    local copper=safe(GetGuildBankMoney)
    if type(copper)=='number' then C.money(self.db,now(),copper); self.lastMoney=copper end
end
function A:startBankRequest()
    if not self:active() or not self.bankOpen then return end
    if not self.pending then self.pending=true; self.requestedAt=clock(); self.attempts=0; self.emptyAt=nil end
    self.nextQuery=clock()+2; self.status='Relevé en cours…'
    local ok,err=pcall(QueryGuildBankLog,(MAX_GUILDBANK_TABS or 8)+1)
    if not ok then self.lastApiError=shortError(err); self:finish(false,'journal refusé par le jeu : '..shortError(err)) end
end
function A:request()
    if not self:active() then return end
    if self.bankOpen and not self.pending and clock()>=self.nextBank then self:startBankRequest() end
    if clock()>=self.nextRoster then self.nextRoster=clock()+10; safe(info('GuildRoster')) end
    if clock()>=self.nextEvents then self.nextEvents=clock()+30; safe(QueryGuildEventLog) end
end
function A:finish(ok,reason)
    self.pending=false; self.emptyAt=nil; self.nextBank=clock()+30
    local last={at=now(),ok=ok,reason=reason,newLines=ok and self.newLines or 0,lines=self.lastCount or 0}
    self.last=last; if self.state then self.state.lastScan=C.copy(last) end
    self.status=ok and 'Prêt' or reason
    local text=ok and ('journal relevé, '..lines(self.newLines)..(self.lastMoney and ' (solde '..A.money(self.lastMoney)..')' or '')) or reason
    if not self.reported then self.reported=true; printFR(text)
    elseif ok and self.newLines>0 then printFR(text) end
    self:updateUI()
end
function A:finishEmpty()
    local tabs=safe(GetNumGuildBankTabs)
    self.newLines=0; self.lastCount=0
    if self.db then C.scan(self.db,self.state,'ledger',{},now(),self.name) end
    self:finish(false,tabs==0 and 'journal d’or vide (aucun onglet acheté)' or 'journal d’or vide ou non autorisé pour ce rang')
end
function A:gapText()
    local gaps=self.db and self.db.gaps or {}
    local gap=gaps[#gaps]; if not gap then return nil end
    local detail=self.state and self.state.lastGap
    local from=detail and detail.at==gap.at and detail.from
    local first=from and safe(date,'%d/%m %H:%M',from) or 'un relevé précédent de date inconnue'
    return 'des dépôts ont pu être perdus entre '..first..' et '..(safe(date,'%d/%m %H:%M',gap.at) or '?')..' : vérifiez sur le site.'
end
function A:scanMoney()
    if not self:active() or not self.bankOpen or not self.pending then return end
    local n=safe(GetNumGuildBankMoneyTransactions)
    if type(n)~='number' or n<0 or n>1000 or n~=floor(n) then return self:finish(false,'journal illisible (droits ou cache)') end
    -- An answer to the item log can arrive first: wait a little before calling it empty.
    if n==0 then self.emptyAt=self.emptyAt or clock(); return end
    local rows={}; local at=now(); local skipped=0
    for i=1,n do
        local kind,name,copper,y,m,d,h=safe(GetGuildBankMoneyTransaction,i)
        if kind=='withdrawal' then kind='withdraw' end
        if type(kind)=='string' and not KINDS[kind] then
            -- buyRename/refundRename (Forever UI) and future types: outside the contract,
            -- skipped identically at every scan so the log alignment stays stable.
            skipped=skipped+1
        else
            -- Missing names are cached/invalid, except the anonymous system summary.
            if kind=='depositSummary' and not name then name='' end
            local ts,p=C.age(at,y,m,d,h)
            local r={id='validate',kind=kind,name=name,copper=copper,ts=ts,tsPrecision=p,source=self.name,seenAt=at}
            if not C.valid('ledger',r) or h==nil then
                self.attempts=(self.attempts or 0)+1
                if self.attempts>=3 then return self:finish(false,'journal incomplet (ligne '..i..' : nom pas encore chargé)') end
                self.status='Noms pas encore chargés, nouvel essai…'; self.nextQuery=clock()+2; self:updateUI(); return
            end
            r.id=nil; r.source=nil; r.seenAt=nil; rows[#rows+1]=r
        end
    end
    self.skipped=skipped; self.lastCount=#rows
    local gap
    self.newLines,gap=C.scan(self.db,self.state,'ledger',order(rows,false),at,self.name)
    if gap then
        printFR('|cffff6060Attention : '..self:gapText()..'|r')
        safe(PlaySound,SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or 856)
    end
    self:recordMoney(); self.lastScan=at
    if self.newLines>0 and self.sync.q:size()<500 then self.sync:hello() else self.sync:bankScan() end
    self:finish(true)
end
function A:scanEvents()
    if not self:active() then return end
    local n=safe(GetNumGuildEvents); if type(n)~='number' or n<0 or n>1000 then return end
    local rows={}; local at=now()
    for i=1,n do
        local kind,p1,p2,rank,y,m,d,h=safe(GetGuildEventInfo,i)
        local actor,player='',p1
        if kind=='quit' then kind='leave' end
        if kind=='invite' or kind=='promote' or kind=='demote' or kind=='remove' then actor,player=p1,p2 end
        local ts,p=C.age(at,y,m,d,h)
        local r={id='validate',kind=kind,player=player,actor=actor,rank=rank,ts=ts,tsPrecision=p}
        if not C.valid('events',r) or h==nil then return end
        r.id=nil; rows[#rows+1]=r
    end
    local added=C.scan(self.db,self.state,'events',order(rows,true),at,self.name)
    if added>0 and self.sync.q:size()<500 then self.sync:hello() end
end
function A:scanRoster()
    if not self:active() then return end
    local n=safe(GetNumGuildMembers,true); if type(n)~='number' or n<1 or n>2000 then return end
    local canNote=safe(info('CanViewOfficerNote'))==true; local members={}
    self.canNote=canNote
    for i=1,n do
        local name,rankName,rankIndex,level,_,_,note,officerNote,online,_,classFile=safe(GetGuildRosterInfo,i)
        if type(name)~='string' or type(level)~='number' or not classFile then return end
        members[name]={fullName=name,level=level,classFile=classFile,rankIndex=rankIndex,rankName=rankName,note=note or '',online=online==true}
        if canNote then members[name].officerNote=officerNote or '' end
    end
    self.db.roster={scannedAt=now(),members=members}; self.db.scannedBy[self.name]=now()
end

-- Stock is local only: never passed to Sync. Slot count is local in Blizzard's
-- Mainline GuildBankUI (98), not an exported MAX_GUILDBANK_SLOTS_PER_TAB global.
local STOCK_SLOTS=98
local STOCK_SPACING=1
local STOCK_DEBOUNCE=0.5
function A:stockSummary()
    local tabs,items,latest=0,0,nil
    for _,tab in pairs(self.db and self.db.stock or {}) do
        tabs=tabs+1
        for _,slot in pairs(tab.slots or {}) do items=items+slot.count end
        if not latest or tab.scannedAt>latest then latest=tab.scannedAt end
    end
    return tabs,items,latest
end
function A:stockText()
    if self.stockStatus then return self.stockStatus end
    local tabs,items=self:stockSummary()
    if tabs==0 then return 'Coffre : pas encore relevé' end
    return 'Coffre : '..tabs..(tabs==1 and ' onglet' or ' onglets')..', '..items..(items==1 and ' objet' or ' objets')
end
function A:finishStock(reason)
    local scan=self.stockScan
    self.stockScan=nil; self.stockDue=nil
    local tabs,items=scan and scan.done or 0,scan and scan.items or 0
    local text
    if tabs>0 then
        text='Coffre : '..tabs..(tabs==1 and ' onglet' or ' onglets')..', '..items..(items==1 and ' objet' or ' objets')
        if reason or scan.reason then text=text..' — '..(reason or scan.reason) end
    else text='Coffre : '..(reason or scan and scan.reason or 'aucun onglet relevé') end
    self.stockStatus=text; printFR(text); self:updateUI()
end
function A:startStock()
    if not self:active() or not self.bankOpen then return end
    if self.stockScan then return end
    self.stockScan={started=clock(),queue={},done=0,items=0,discover=true}
    self.stockDue=clock()+STOCK_DEBOUNCE
    self.stockStatus='Coffre : relevé en cours…'
end
function A:stockChanged()
    if not self:active() or not self.bankOpen then return end
    local scan=self.stockScan
    if not scan then self.stockDue=clock()+STOCK_DEBOUNCE; return end
    if not scan.pending then self.stockRefresh=true; return end
    local selected=safe(GetCurrentGuildBankTab)
    if selected~=scan.pending then
        scan.selectedRequest=false; scan.ready=nil; scan.confirmAt=nil; scan.secondEmpty=nil
        scan.pendingReason='onglet '..scan.pending..' non confirmé ; relevé précédent conservé'
        self.stockStatus='Coffre : '..scan.pendingReason..' (sélectionnez cet onglet)'
        self.stockRefresh=true
    elseif scan.issued and scan.selectedRequest and not scan.confirmAt then
        -- The signal is global, not an acknowledgement for any outstanding tab.
        -- Only a query issued while THIS tab was selected can admit a later event.
        scan.ready=true; scan.readAt=clock()+STOCK_DEBOUNCE
    end
end
function A:queryStock(scan,tab)
    scan.pending=tab; scan.askedAt=clock(); scan.ready=nil; scan.issued=false
    scan.selectedRequest=safe(GetCurrentGuildBankTab)==tab
    scan.pendingReason=not scan.selectedRequest and ('onglet '..tab..' non confirmé ; relevé précédent conservé') or nil
    local ok,err=pcall(QueryGuildBankTab,tab)
    scan.issued=ok -- synchronous signals inside Query are not post-query responses
    if not ok then
        self.lastApiError=shortError(err); scan.reason='onglet '..tab..' refusé par le jeu : '..shortError(err)
        scan.pending=nil; scan.confirmAt=nil; scan.secondEmpty=nil
        self.stockDue=clock()+STOCK_SPACING
    elseif not scan.selectedRequest then
        self.stockStatus='Coffre : '..scan.pendingReason..' (sélectionnez cet onglet)'
        self:updateUI()
    end
end
function A:stockTabsChanged()
    if not self:active() or not self.bankOpen then return end
    local meta=self.stockMeta; local n=safe(GetNumGuildBankTabs)
    if not meta or n~=#meta then self.stockRefresh=true; return end
    for tab=1,n do
        local name,icon,viewable=safe(GetGuildBankTabInfo,tab)
        local old=meta[tab]
        if name~=old.name or icon~=old.icon or viewable~=old.viewable then self.stockRefresh=true; return end
    end
end
function A:readStock(tab)
    local name,icon,viewable=safe(GetGuildBankTabInfo,tab)
    if not viewable then return nil,'onglet '..tab..' non visible pour ce rang' end
    if type(icon)=='string' then icon=safe(GetFileIDFromPath,icon) end
    if type(name)~='string' or name=='' or type(icon)~='number' or icon<=0 or icon~=floor(icon) then
        return nil,'onglet '..tab..' : nom ou icône pas encore chargé'
    end
    local slots={}; local items=0
    for i=1,STOCK_SLOTS do
        -- Distinguish a genuinely empty slot from an API failure; do not erase
        -- the last complete snapshot on a denied/secret/broken response.
        local ok,texture,n,_,_,quality=pcall(GetGuildBankItemInfo,tab,i)
        if not ok then self.lastApiError=shortError(texture); return nil,'onglet '..tab..' : emplacements illisibles' end
        if issecretvalue and (issecretvalue(texture) or issecretvalue(n) or issecretvalue(quality)) then
            return nil,'onglet '..tab..' : emplacements masqués par le jeu'
        end
        local link=safe(GetGuildBankItemLink,tab,i)
        if texture or n and n>0 or link then
            local item=type(link)=='string' and link:match('|H(item:[^|]+)|h')
            local itemName=type(link)=='string' and link:match('|h%[(.-)%]|h')
            if not item or not item:match('^item:%d+[:%d%-]*$') or not itemName or itemName==''
                or type(n)~='number' or n<1 or n>1000 or n~=floor(n)
                or type(quality)~='number' or quality~=floor(quality) or quality<0 or quality>8 then
                return nil,'onglet '..tab..' : objet pas encore chargé (emplacement '..i..')'
            end
            slots[i]={item=item,count=n,name=itemName,quality=quality}; items=items+n
        end
    end
    return {name=name,icon=icon,scannedAt=now(),scannedBy=self.name,slots=slots},items
end
function A:tickStock(t)
    if self.stockRefresh and not self.stockScan then
        self.stockRefresh=nil; self:startStock()
    end
    if not self.stockScan then
        if not self.stockDue or t<self.stockDue then return end
        self:startStock()
    end
    local scan=self.stockScan
    if t<(self.stockDue or 0) then return end
    if scan.discover then
        local n=safe(GetNumGuildBankTabs)
        local queue,meta={},{}; local unknown=type(n)~='number' or n<0 or n>8 or n~=floor(n)
        if not unknown then
            self.stockBought=n
            for tab=1,n do
                local name,icon,viewable=safe(GetGuildBankTabInfo,tab)
                meta[tab]={name=name,icon=icon,viewable=viewable}
                if viewable then queue[#queue+1]=tab elseif viewable==nil then unknown=true end
            end
        end
        if unknown then
            if t-scan.started>=10 then return self:finishStock('droits ou onglets pas encore reçus après 10 s') end
            self.stockDue=t+1; return
        end
        self.stockVisible=#queue; self.stockMeta=meta
        if n==0 then return self:finishStock('aucun onglet acheté') end
        if #queue==0 then return self:finishStock('aucun onglet visible pour ce rang') end
        local selected=safe(GetCurrentGuildBankTab)
        for i,tab in ipairs(queue) do
            if tab==selected then table.remove(queue,i); table.insert(queue,1,tab); break end
        end
        scan.queue=queue; scan.discover=nil
    end
    if scan.pending then
        local selected=safe(GetCurrentGuildBankTab)
        if selected~=scan.pending then
            scan.selectedRequest=false; scan.ready=nil; scan.confirmAt=nil; scan.secondEmpty=nil
            scan.pendingReason='onglet '..scan.pending..' non confirmé ; relevé précédent conservé'
        elseif not scan.selectedRequest and t-scan.askedAt>=STOCK_SPACING then
            self:queryStock(scan,scan.pending) -- fresh request after the player visits this tab
            return
        elseif scan.confirmAt and t>=scan.confirmAt then
            scan.confirmAt=nil; scan.secondEmpty=true
            self:queryStock(scan,scan.pending)
            return
        end
        if scan.ready and scan.selectedRequest and t>=scan.readAt then
            local snapshot,items=self:readStock(scan.pending)
            local old=self.db.stock[scan.pending]
            if snapshot and items==0 and old and next(old.slots) and not scan.secondEmpty then
                -- All nil getters can also mean a cold cache. A previously full
                -- tab needs a second selected query and a second post-query event.
                scan.ready=nil; scan.confirmAt=t+STOCK_SPACING
                scan.pendingReason='onglet '..scan.pending..' vide non confirmé ; relevé précédent conservé'
                self.stockStatus='Coffre : '..scan.pendingReason
                self:updateUI()
            elseif snapshot then
                self.db.stock[scan.pending]=snapshot
                scan.done=scan.done+1; scan.items=scan.items+items
                scan.pending=nil; scan.ready=nil; scan.readAt=nil; scan.pendingReason=nil; scan.secondEmpty=nil
                self.stockDue=t+STOCK_SPACING
            else scan.pendingReason=items; scan.readAt=t+1 end
        end
        if scan.pending and t-scan.askedAt>=10 then
            scan.reason=scan.pendingReason or ('onglet '..scan.pending..' : données non reçues après 10 s ; relevé précédent conservé')
            scan.pending=nil; scan.ready=nil; scan.pendingReason=nil; scan.confirmAt=nil; scan.secondEmpty=nil
            self.stockDue=t+STOCK_SPACING
        end
        if scan.pending then return end
    end
    if #scan.queue==0 then return self:finishStock() end
    if t<self.stockDue then return end
    local tab=table.remove(scan.queue,1)
    local _,_,viewable=safe(GetGuildBankTabInfo,tab)
    if not viewable then
        scan.reason='onglet '..tab..' non visible pour ce rang'; self.stockDue=t+STOCK_SPACING; return
    end
    self:queryStock(scan,tab)
end

-- Bank opening: several signals (legacy event, interaction manager, frame OnShow),
-- because Blizzard_GuildBankUI is LoadOnDemand and GuildBankFrame may not exist yet.
function A:hookBankFrame()
    local bank=_G.GuildBankFrame
    if not bank or self.hooked or not bank.HookScript then return end
    self.hooked=true
    bank:HookScript('OnShow',function() A:guard('GuildBankFrame:OnShow',A.bankOpened,A,'cadre') end)
    bank:HookScript('OnHide',function() A:guard('GuildBankFrame:OnHide',A.bankClosed,A) end)
end
function A:bankOpened(via)
    self:hookBankFrame()
    if LiLiBanque.UI then LiLiBanque.UI.attach() end
    if self.bankOpen then return end
    self.bankOpen=true; self.openedVia=via; self.reported=false; self.pending=false; self.nextBank=0
    if not self.db then self:init() end
    if not self:active() then self.reported=true; printFR(self:inactiveReason()); self:updateUI(); return end
    self:recordMoney(); self:request(); self:startStock(); self:updateUI()
end
function A:bankClosed()
    if not self.bankOpen then return end
    if self.pending then self.pending=false; self.status='Banque fermée avant la réponse du journal' end
    if self.stockScan then
        local detail=self.stockScan.pendingReason
        self:finishStock('banque fermée avant la fin du relevé'..(detail and ' — '..detail or ' ; relevé précédent conservé'))
    end
    self.stockDue=nil; self.stockRefresh=nil
    self.bankOpen=false; self:updateUI()
end
function A:scanNow()
    if not self.db then self:init() end
    if not self:active() then printFR(self:inactiveReason()); return end
    if not self.bankOpen then self:request(); printFR('ouvrez la banque de guilde pour relever le journal d’or.'); return end
    self.reported=false; self.pending=false; self.nextBank=0; self:request(); self:startStock()
end
function A:tick()
    local t=clock()
    if not self.db and t>=self.nextInit then self:init() end
    if not self.nextUI or t>=self.nextUI then self.nextUI=t+(LiLiBanque.UI and LiLiBanque.UI.isShown() and 1 or 5); self:updateUI() end
    if not self:active() then return end
    -- Forever addons report the broad restriction flag even outside instances.
    -- Respect actual lockdown unconditionally, and let the send result decide in the open world.
    local inRestrictedContext=safe(IsInInstance)==true or safe(InCombatLockdown)==true
    local locked=safe(C_ChatInfo and C_ChatInfo.InChatMessagingLockdown)==true
        or inRestrictedContext and safe(C_ChatInfo and C_ChatInfo.AreOutgoingAddonChatMessagesRestricted)==true
    self.sync:tick(t,locked)
    self:remind()
    if self.bankOpen then
        self:tickStock(t)
        if self.pending then
            if self.emptyAt and t-self.emptyAt>=3 then self:finishEmpty()
            elseif t-(self.requestedAt or t)>=10 then self:finish(false,'journal non reçu après 10 s (droits ou serveur)')
            elseif t>=self.nextQuery then self:startBankRequest() end
        elseif t>=self.nextBank then self:startBankRequest() end
    end
end
function A:updateUI()
    if LiLiBanque.UI then LiLiBanque.UI.refresh() end
end

local function yesno(v) return v and 'oui' or 'non' end
function A:diagLines()
    local out={}
    local version,build,_,toc=safe(GetBuildInfo)
    out[#out+1]='LiLiBanque '..C.VERSION..' ; client '..tostring(version)..' ('..tostring(build)..'), interface '..tostring(toc)
    local inGuild=self:inGuild()
    out[#out+1]='Guilde lue : '..(self.guildRead and '« '..self.guildRead..' »' or 'aucune')..' ; attendue « '..self.guild..' » ; '
        ..(self.guildRead==self.guild and 'identique' or inGuild and 'équivalente' or 'différente')
    out[#out+1]='Actif : '..yesno(self:active())..' ; perso '..tostring(self.name)..' ; état : '..tostring(self.status or 'en attente')
    local bank=_G.GuildBankFrame
    local loaded=C_AddOns and C_AddOns.IsAddOnLoaded and safe(C_AddOns.IsAddOnLoaded,'Blizzard_GuildBankUI')
    out[#out+1]='Banque ouverte : '..yesno(self.bankOpen)..(self.openedVia and ' (signal : '..self.openedVia..')' or '')
        ..' ; GuildBankFrame : '..(bank and 'chargé' or 'absent')..(bank and bank.IsShown and (bank:IsShown() and ', affiché' or ', caché') or '')
        ..' ; Blizzard_GuildBankUI chargé : '..yesno(loaded)..' ; onglets achetés : '..tostring(safe(GetNumGuildBankTabs))
    local savedTabs,_,stockAt=self:stockSummary()
    out[#out+1]='Coffre : '..tostring(self.stockBought or safe(GetNumGuildBankTabs) or '?')..' achetés, '
        ..tostring(self.stockVisible or '?')..' visibles, '..savedTabs..' relevés ; '..self:stockText()
    out[#out+1]='Dernier relevé du coffre : '..(stockAt and (safe(date,'%d/%m %H:%M',stockAt) or '?') or 'jamais')
    local last=self.last
    out[#out+1]='Journal d’or : '..(last and ((last.ok and 'relevé, ' or 'échec, ')..last.lines..' lignes lues, '..last.newLines..' nouvelles'..(last.reason and ' — '..last.reason or '')) or 'pas encore relevé')
        ..(self.skipped and self.skipped>0 and ' ; '..self.skipped..' lignes hors contrat ignorées' or '')
    out[#out+1]='Notes d’officier lisibles : '..yesno(safe(info('CanViewOfficerNote'))==true)..' ; retrait d’or autorisé : '..yesno(safe(CanWithdrawGuildBankMoney)==true)
    local sync=self.sync
    out[#out+1]='Synchro : préfixe '..yesno(self.prefixOK)..' ; file '..(sync and sync.q:size() or 0)..(sync and sync.q.blocked and ' (en pause)' or '')
        ..' ; reçus '..(sync and sync.transferred or 0)
    if self.db then
        local _,ids=LiLiBanque.Wire.digest(self.db.ledger)
        local members=0; for _ in pairs(self.db.roster and self.db.roster.members or {}) do members=members+1 end
        out[#out+1]='Données : '..#ids..' lignes d’or, '..#self.db.gaps..' trous, roster '..members..' membres'
    end
    local shared=self.db and self.state and C.bankScanTime(self.db,self.state,now())
    out[#out+1]='Dernier journal connu (officiers) : '..(shared and (safe(date,'%d/%m %H:%M',shared) or '?') or 'inconnu')
        ..' ; rappel '..(self.state and self.state.reminderEnabled==false and 'désactivé' or 'activé')
    out[#out+1]='Dernier trou : '..(self:gapText() or 'aucun')
    local e=self.lastError or type(LiLiBanqueState)=='table' and LiLiBanqueState.lastError
    out[#out+1]='Dernière erreur Lua : '..(e and (e.msg..' ['..tostring(e.where)..']'..(e.at and e.at>0 and safe(date,'%d/%m %H:%M',e.at) and ' le '..safe(date,'%d/%m %H:%M',e.at) or '')) or 'aucune')
    out[#out+1]='Dernière erreur d’API : '..(self.lastApiError or 'aucune')
    return out
end
function A:diag() for _,l in ipairs(self:diagLines()) do printFR(l) end end

function A:command(text)
    local raw=(text or ''):match('^%s*(.-)%s*$')
    local cmd=raw:lower()
    if cmd=='' or cmd=='ouvrir' or cmd=='show' then if LiLiBanque.UI then LiLiBanque.UI.toggle() end
    elseif cmd=='rappel on' or cmd=='rappel off' then
        uiState().reminderEnabled=cmd=='rappel on'
        printFR('rappel de passage '..(uiState().reminderEnabled and 'activé' or 'désactivé')..' pour ce personnage.')
    elseif cmd=='rappel' or cmd:match('^rappel%s') then printFR('/lili rappel on|off : rappel de passage pour ce personnage')
    elseif cmd=='diag' then self:diag()
    elseif cmd=='scan' or cmd=='relever' then self:scanNow()
    elseif cmd=='export' or cmd=='exporter' then if LiLiBanque.UI then LiLiBanque.UI.show(); LiLiBanque.UI.startExport() end
    elseif cmd=='status' or cmd=='etat' or cmd=='état' then
        local _,ids=LiLiBanque.Wire.digest(self.db and self.db.ledger or {})
        printFR(C.VERSION..' — '..(self.status or 'En attente')..' ; '..#ids..' lignes ; file '..(self.sync and self.sync.q:size() or 0)..'.')
    elseif cmd=='reset' then self.confirmUntil=clock()+30; printFR('effacement local uniquement. Sauvegardez le fichier avant. Confirmez sous 30 s : /lili reset CONFIRMER')
    elseif raw=='reset CONFIRMER' then
        if self.confirmUntil and clock()<=self.confirmUntil then
            local st=uiState()
            LiLiBanqueDB=nil; LiLiBanqueState={ui=st.ui,reminderEnabled=st.reminderEnabled,lastReminderAt=st.lastReminderAt}
            self.db=nil; self.state=nil; self.sync=nil; self.confirmUntil=nil; self.last=nil
            self.stockScan=nil; self.stockDue=nil; self.stockRefresh=nil; self.stockStatus=nil
            self.stockBought=nil; self.stockVisible=nil; self.stockMeta=nil
            self:init(); printFR('données locales réinitialisées. Les autres officiers pourront les resynchroniser.')
        else printFR('confirmation expirée : /lili reset') end
    else
        printFR('/lili : fenêtre ; /lili diag : diagnostic ; /lili scan : relever (banque ouverte) ; /lili export : export pour le site ; /lili rappel on|off : rappel de passage ; /lili reset : effacer les données locales')
    end
    self:updateUI()
end
function A:onEvent(event,...)
    if event=='PLAYER_LOGIN' then
        printFR('version '..C.VERSION..' chargée — /lili')
        self:init(); self:hookBankFrame()
    elseif event=='ADDON_LOADED' then
        if ...=='Blizzard_GuildBankUI' then
            self:hookBankFrame()
            local bank=_G.GuildBankFrame
            if self.bankOpen or bank and bank.IsShown and bank:IsShown() then self:bankOpened('chargement') end
        end
    elseif event=='PLAYER_GUILD_UPDATE' then if not self.db then self:init() end
    elseif event=='GUILDBANKFRAME_OPENED' then self:bankOpened('événement')
    elseif event=='GUILDBANKFRAME_CLOSED' then self:bankClosed()
    elseif event=='PLAYER_INTERACTION_MANAGER_FRAME_SHOW' then
        local kind=...; local want=Enum and Enum.PlayerInteractionType and Enum.PlayerInteractionType.GuildBanker or GUILD_BANKER
        if kind==want then self:bankOpened('interaction') end
    elseif event=='PLAYER_INTERACTION_MANAGER_FRAME_HIDE' then
        local kind=...; local want=Enum and Enum.PlayerInteractionType and Enum.PlayerInteractionType.GuildBanker or GUILD_BANKER
        if kind==want then self:bankClosed() end
    elseif event=='GUILDBANKBAGSLOTS_CHANGED' then self:stockChanged()
    elseif event=='GUILDBANK_UPDATE_TABS' then self:stockTabsChanged()
    elseif event=='GUILDBANKLOG_UPDATE' then self:scanMoney()
    elseif event=='GUILDBANK_UPDATE_MONEY' then
        if self:active() and self.bankOpen then
            self:recordMoney()
            -- A deposit just happened: read the money log again shortly.
            if not self.pending then self.nextBank=math.min(self.nextBank,clock()+2) end
            self:updateUI()
        end
    elseif event=='GUILD_EVENT_LOG_UPDATE' then self:scanEvents()
    elseif event=='GUILD_ROSTER_UPDATE' then
        if not self.db then self:init() end
        self:scanRoster()
    elseif event=='CHAT_MSG_ADDON' and self:active() then
        local prefix,msg,channel,sender=...
        if issecretvalue and (issecretvalue(prefix) or issecretvalue(msg) or issecretvalue(channel) or issecretvalue(sender)) then return end
        if prefix==S.PREFIX then self.sync:receive(msg,channel,sender) end
    end
end
local frame=CreateFrame('Frame'); A.frame=frame
for _,event in ipairs({'PLAYER_LOGIN','ADDON_LOADED','PLAYER_GUILD_UPDATE','GUILDBANKFRAME_OPENED','GUILDBANKFRAME_CLOSED',
    'PLAYER_INTERACTION_MANAGER_FRAME_SHOW','PLAYER_INTERACTION_MANAGER_FRAME_HIDE','GUILDBANKLOG_UPDATE','GUILDBANK_UPDATE_MONEY',
    'GUILDBANKBAGSLOTS_CHANGED','GUILDBANK_UPDATE_TABS',
    'GUILD_EVENT_LOG_UPDATE','GUILD_ROSTER_UPDATE','CHAT_MSG_ADDON'}) do
    -- An event unknown to this client must not stop the others from registering.
    pcall(frame.RegisterEvent,frame,event)
end
frame:SetScript('OnEvent',function(_,event,...) A:guard(event,A.onEvent,A,event,...) end)
local elapsed=0
frame:SetScript('OnUpdate',function(_,delta)
    elapsed=elapsed+delta; if elapsed<0.35 then return end; elapsed=0
    A:guard('OnUpdate',A.tick,A)
end)
SLASH_LILIBANQUE1='/lili'; SLASH_LILIBANQUE2='/lilibanque'
SlashCmdList.LILIBANQUE=function(text) A:guard('/lili',A.command,A,text) end
