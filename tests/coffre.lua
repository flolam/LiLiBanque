-- /lili « Coffre » section: read-only browser of the guild-bank tabs saved by the stock scanner.
-- Self-contained (own setup, strict widget mock). Expects ROOT (addon dir) like tests/run.py provides.
local tests,passed={},0
local function test(name,fn) tests[#tests+1]={name,fn} end
local function eq(a,b) assert(a==b,tostring(a)..' ~= '..tostring(b)) end
local function has(s,p) assert(type(s)=='string' and s:find(p,1,true),tostring(s)..' ⊅ '..p) end
local function hasnt(s,p) assert(not (type(s)=='string' and s:find(p,1,true)),tostring(s)..' ⊃ '..p) end
local MOCK=assert(loadfile(ROOT..'/tests/wowmock.lua'))()
local NOW,CHAT
local TEST_GUILD='Guilde expérimentale fictive'
local SIDE -- calls that would act on the real guild bank
local function load()
    NOW=200000; CHAT={}; LiLiBanqueDB=nil; LiLiBanqueState=nil
    MOCK.install()
    SOUNDKIT={IG_MAINMENU_OPTION_CHECKBOX_ON=856}; PlaySound=function() end
    C_ChatInfo={RegisterAddonMessagePrefix=function() return 0 end,SendAddonMessage=function() return 0 end,InChatMessagingLockdown=function() return false end,AreOutgoingAddonChatMessagesRestricted=function() return false end}
    C_GuildInfo={GuildRoster=function() end,CanViewOfficerNote=function() return true end}
    GetServerTime=function() return math.floor(NOW) end; GetTime=function() return NOW end
    GetGuildInfo=function() return TEST_GUILD end; IsInGuild=function() return true end
    GetUnitName=function() return 'Elvor Valbrume' end; UnitName=function() return 'Elvor','Valbrume' end
    DEFAULT_CHAT_FRAME={AddMessage=function(_,m) CHAT[#CHAT+1]=m end}; SlashCmdList={}; SLASH_LILIBANQUE1=nil; SLASH_LILIBANQUE2=nil
    QueryGuildBankLog=function() end; MAX_GUILDBANK_TABS=8; CanWithdrawGuildBankMoney=function() return true end
    GetNumGuildBankMoneyTransactions=function() return 0 end; GetGuildBankMoneyTransaction=function() end
    GetGuildBankMoney=function() return 1234567 end
    QueryGuildEventLog=function() end; GetNumGuildEvents=function() return 0 end; GetGuildEventInfo=function() end
    GetNumGuildMembers=function() return 1 end
    GetGuildRosterInfo=function() return 'Elvor Valbrume','Officier',1,60,'Druide','','','',true,0,'DRUID' end
    IsInInstance=nil; InCombatLockdown=nil; issecretvalue=nil; debugprofilestop=nil
    SIDE={}
    for _,fn in ipairs({'SetCurrentGuildBankTab','PickupGuildBankItem','SplitGuildBankItem','AutoStoreGuildBankItem','QueryGuildBankText','SetGuildBankTabInfo'}) do
        _G[fn]=function() SIDE[#SIDE+1]=fn end
    end
    LiLiBanque={}
    for _,f in ipairs({'Core','Wire','Sync','Export','Addon','UI'}) do assert(loadfile(ROOT..'/LiLiBanque/'..f..'.lua'))() end
    local A=LiLiBanque.Addon
    A.guild=TEST_GUILD
    local function fire(e,...) A.frame:fire('OnEvent',e,...) end
    fire('PLAYER_LOGIN'); fire('GUILD_ROSTER_UPDATE')
    return A,fire
end
local function item(id,name,count,quality) return {item='item:'..id..'::::::::60:::::::::',count=count,name=name,quality=quality or 1} end
-- Three bought tabs; tab 3 is not viewable for this rank. Snapshots exist for 1 (full) and 3 (left by another character).
local function guildBank(A)
    MOCK.tabs={{name='Le Bazar',icon=133784,viewable=true,slots={}},{name='Potions',icon=134712,viewable=true,slots={}},{name='Secret',icon=134400,viewable=false,slots={}}}
    A.db.stock[1]={name='Le Bazar',icon=133784,scannedAt=NOW-720,scannedBy='Elvor Valbrume',slots={[1]=item(2318,'Light Leather',20),[8]=item(13446,'Major Healing Potion',1,2),[98]=item(12359,'Thorium Bar',5)}}
    A.db.stock[3]={name='Secret',icon=134400,scannedAt=NOW-60,scannedBy='Autre Perso',slots={[1]=item(19019,'Thunderfury',1,5)}}
    MOCK.icons={[2318]=134256,[13446]=134833,[12359]=135245,[19019]=135349}
end
local function coffre()
    SlashCmdList.LILIBANQUE('')
    local UI=LiLiBanque.UI
    LiLiBanqueFrame.Tabs[2]:Click()
    return UI,UI.sections[2].panel
end
local function frameText() return MOCK.texts(LiLiBanqueFrame) end
local function iconsShown(panel)
    local n=0
    for _,s in ipairs(panel.slots) do if s.icon.texture and s.icon:IsShown() and s:IsShown() then n=n+1 end end
    return n
end
local function serialize(v,seen)
    if type(v)~='table' then return tostring(v) end
    local keys={}; for k in pairs(v) do keys[#keys+1]=tostring(k) end; table.sort(keys)
    local out={}; for _,k in ipairs(keys) do out[#out+1]=k..'='..serialize(v[k] or v[tonumber(k)]) end
    return '{'..table.concat(out,',')..'}'
end

test('navigation : onglets natifs Journal et Coffre, Échap, export propre depuis un onglet',function()
    local A,fire=load(); guildBank(A)
    SlashCmdList.LILIBANQUE('')
    local f=LiLiBanqueFrame; local UI=LiLiBanque.UI
    eq(#f.Tabs,2); eq(f.numTabs,2); eq(f.Tabs[1].text,'Journal'); eq(f.Tabs[2].text,'Coffre')
    eq(f.Tabs[1].template,'PanelTabButtonTemplate'); eq(f.selectedTab,1)
    f.Tabs[2]:Click(); eq(f.selectedTab,2)
    assert(UI.sections[2].panel:IsShown()); assert(not UI.sections[1].panel:IsShown())
    has(UI.header.text,'Coffre')
    local found=false; for _,n in ipairs(UISpecialFrames) do if n=='LiLiBanqueFrame' then found=true end end; assert(found,'Échap')
    -- The export label keeps its ellipsis across refreshes.
    eq(UI.exportButton.text,'Exporter…'); A:updateUI(); eq(UI.exportButton.text,'Exporter…')
    UI.exportButton:Click(); assert(UI.exporting); eq(UI.exportButton.text,'Retour')
    assert(not UI.sections[2].panel:IsShown())
    -- A section tab behind the export closes the export cleanly, then opens that section.
    f.Tabs[1]:Click()
    assert(not UI.exporting); assert(not UI.exportPanel:IsShown()); eq(UI.exportPanel.box.text,''); eq(UI.job,nil)
    assert(UI.sections[1].panel:IsShown()); eq(f.selectedTab,1); eq(UI.exportButton.text,'Exporter…'); assert(UI.scanButton:IsShown())
    -- Retour comes back to the section the export was started from.
    f.Tabs[2]:Click(); UI.exportButton:Click(); UI.exportButton:Click()
    assert(UI.sections[2].panel:IsShown()); eq(f.selectedTab,2)
    -- Drag still saves the position from the Coffre section.
    f:fire('OnDragStart'); f:ClearAllPoints(); f:SetPoint('TOPLEFT',UIParent,'TOPLEFT',10,-20); f:fire('OnDragStop'); eq(LiLiBanqueState.ui.x,10)
end)

test('grille réelle : 14 colonnes × 7, groupes de 2, 1–7 vers le bas puis 8 à droite de 1',function()
    local A=load(); guildBank(A)
    local UI,panel=coffre()
    eq(#panel.slots,98)
    local S,G,P=UI.SLOT,UI.SLOT_GAP,UI.GROUP_PITCH
    local function at(i) local p,rel,rp,x,y=panel.slots[i]:GetPoint(1); eq(p,'TOPLEFT'); eq(rel,panel.grid); eq(rp,'TOPLEFT'); return x,y end
    local x,y=at(1); eq(x,0); eq(y,0)
    x,y=at(7); eq(x,0); eq(y,-6*(S+G))
    x,y=at(8); eq(x,S+G); eq(y,0)
    x,y=at(14); eq(x,S+G); eq(y,-6*(S+G))
    x,y=at(15); eq(x,P); eq(y,0)
    x,y=at(98); eq(x,6*P+S+G); eq(y,-6*(S+G))
    -- Fits inside the panel (inset 470 - 2×4) with the same left/right margin.
    local _,_,_,gx=panel.grid:GetPoint(1)
    local w=6*P+2*S+G; eq(panel.grid:GetWidth(),w); assert(gx>=8 and gx+w<=462-8,'grille dans le panneau')
    eq(panel.slots[1]:GetWidth(),S); eq(panel.slots[1].kind,'Frame') -- local frame, never a bank item button
    for _,o in ipairs(MOCK.all) do assert(o.template~='GuildBankItemButtonTemplate') end
    -- Two-point anchors keep their pair and height: TOPLEFT/TOPRIGHT (or BOTTOM…) on the same Y.
    for _,region in ipairs({panel.summary,panel.detail,panel.message,panel.hint}) do
        local a,_,_,_,ya=region:GetPoint(1); local b,_,_,_,yb=region:GetPoint(2)
        eq(a:gsub('LEFT',''),b:gsub('RIGHT','')); eq(ya,yb)
    end
end)

test('onglet relevé : icônes, quantités, qualité, info du relevé, infobulle native sur lien réel',function()
    local A=load(); guildBank(A)
    local UI,panel=coffre()
    eq(UI.coffreTab,1); has(panel.tabTitle.text,'Le Bazar')
    has(panel.detail.text,UI.when(NOW-720)); has(panel.detail.text,'il y a 12 min'); has(panel.detail.text,'Elvor Valbrume')
    has(panel.summary.text,'95 places libres')
    assert(panel.grid:IsShown()); eq(panel.message.text,'')
    eq(panel.slots[1].icon.texture,134256); eq(panel.slots[1].count.text,'20')
    eq(panel.slots[8].icon.texture,134833); eq(panel.slots[8].count.text,'') -- native: no count for a single item
    assert(panel.slots[8].border:IsShown()); assert(not panel.slots[1].border:IsShown()) -- uncommon+ only
    eq(panel.slots[98].count.text,'5'); eq(panel.slots[2].icon.texture,nil); eq(iconsShown(panel),3)
    -- Hover: native item tooltip from the saved item string, owned by the slot.
    panel.slots[1]:fire('OnEnter')
    eq(MOCK.tooltip.owner,panel.slots[1]); eq(MOCK.tooltip.link,A.db.stock[1].slots[1].item); assert(MOCK.tooltip.shown)
    panel.slots[1]:fire('OnLeave'); assert(not MOCK.tooltip.shown)
    panel.slots[2]:fire('OnEnter'); assert(not MOCK.tooltip.shown,'pas d’infobulle sur un emplacement vide')
    A.db.stock[1]={name='Le Bazar',icon=133784,scannedAt=NOW,scannedBy='Elvor Valbrume',slots={[1]={item='spell:1234',count=1,name='Piège',quality=1}}}
    A:updateUI()
    panel.slots[1]:fire('OnEnter'); assert(not MOCK.tooltip.shown,'jamais d’infobulle pour un lien autre qu’objet')
end)

test('pas encore relevé ≠ vide au relevé',function()
    local A,fire=load(); guildBank(A)
    A.db.stock[1].slots={} -- relevé vide réel
    local UI,panel=coffre()
    assert(panel.grid:IsShown()); eq(iconsShown(panel),0); has(panel.summary.text,'vide au relevé'); eq(panel.message.text,'')
    panel.chips[2]:Click(); eq(UI.coffreTab,2)
    assert(not panel.grid:IsShown(),'aucune grille sans relevé'); has(panel.message.text,'Pas encore relevé')
    has(panel.message.text,'Ouvrez la banque de guilde'); has(panel.message.text,'« Potions »'); has(panel.tabTitle.text,'Potions')
    eq(panel.detail.text,'')
    -- Bank open: the instruction becomes « select this tab », never « live ».
    GuildBankFrame=MOCK.loadGuildBank(); GuildBankFrame:Show(); fire('GUILDBANKFRAME_OPENED'); A:updateUI()
    has(panel.message.text,'Sélectionnez l’onglet « Potions »'); hasnt(frameText(),'en direct')
end)

test('zéro, un, huit onglets : noms et ordre réels, sélecteur dans le panneau',function()
    local A,fire=load(); MOCK.tabs={}
    GuildBankFrame=MOCK.loadGuildBank(); GuildBankFrame:Show(); fire('GUILDBANKFRAME_OPENED')
    local UI,panel=coffre()
    for _,c in ipairs(panel.chips) do assert(not c:IsShown()) end
    has(panel.message.text,'Aucun onglet acheté'); assert(not panel.grid:IsShown())
    MOCK.tabs={{name='Le Bazar',icon=133784,viewable=true,slots={}}}; A:updateUI()
    assert(panel.chips[1]:IsShown()); assert(not panel.chips[2]:IsShown()); eq(panel.chips[1].label.text,UI.COLORS.amber..'Le Bazar|r') -- the only tab is the selected one
    eq(panel.chips[1].icon.texture,133784); eq(UI.coffreTab,1); assert(panel.chips[1].label:IsShown()); has(panel.message.text,'Pas encore relevé')
    for i=2,8 do MOCK.tabs[i]={name='Onglet fictif '..i,icon=134400+i,viewable=true,slots={}} end; A:updateUI()
    local _,_,_,_,y1=panel.chips[1]:GetPoint(1); local right=0
    for i=1,8 do
        local c=panel.chips[i]; assert(c:IsShown()); eq(c.tab,i)
        local _,_,_,x,y=c:GetPoint(1); eq(y,y1); right=x+c:GetWidth()
        if i>1 then has(c.label.text,'Onglet fictif '..i) end
    end
    assert(right<=462-8,'8 onglets tiennent dans la largeur : '..right)
    -- Too narrow for a name: icon only, the name comes in the chip tooltip and the title line.
    assert(not panel.chips[3].label:IsShown()); assert(panel.chips[3].icon:IsShown())
    panel.chips[3]:fire('OnEnter'); eq(MOCK.tooltip.owner,panel.chips[3]); eq(MOCK.tooltip.text,'Onglet fictif 3'); assert(MOCK.tooltip.shown)
    panel.chips[3]:fire('OnLeave'); assert(not MOCK.tooltip.shown)
    panel.chips[8]:Click(); eq(UI.coffreTab,8); has(panel.tabTitle.text,'Onglet fictif 8')
    has(panel.chips[8].label.text,UI.COLORS.amber); hasnt(panel.chips[1].label.text,UI.COLORS.amber)
end)

test('droits : refusé, inconnu, /reload ou retrait — aucun relevé non vérifié affiché',function()
    local A,fire=load(); guildBank(A)
    local UI,panel=coffre()
    -- Tab 3 denied: no chip, no name, no content, even though a snapshot from another character exists.
    for _,c in ipairs(panel.chips) do if c:IsShown() then assert(c.tab~=3) end end
    local all=frameText(); hasnt(all,'Secret'); hasnt(all,'Thunderfury'); hasnt(all,'Autre Perso')
    has(panel.hint.text,'1 onglet non visible pour votre rang')
    UI.coffreSelect(3); assert(UI.coffreTab~=3,'sélection d’un onglet refusé ignorée')
    -- Bank closed but the API still confirms tab 1: the saved reading stays readable.
    eq(A.bankOpen,nil); eq(iconsShown(panel),3)
    -- Permissions removed while the window is open: cleared on the next refresh, hover inert.
    local slot=panel.slots[1]
    MOCK.tabs[1].viewable=false
    slot:fire('OnEnter'); assert(not MOCK.tooltip.shown,'infobulle refusée dès le retrait')
    A:updateUI(); eq(iconsShown(panel),0); hasnt(frameText(),'Light Leather'); hasnt(frameText(),'Le Bazar'); eq(slot.item,nil)
    eq(UI.coffreTab,2)
    -- Unknown viewability (nil) is never treated as allowed.
    panel.chips[1]:fire('OnEnter'); assert(MOCK.tooltip.shown)
    MOCK.tabs[2].viewable=nil; A:updateUI()
    assert(not MOCK.tooltip.shown,'ancienne infobulle d’onglet fermée quand le droit disparaît')
    for _,c in ipairs(panel.chips) do assert(not c:IsShown()) end
    eq(iconsShown(panel),0); has(panel.message.text,'Ouvrez la banque de guilde')
    -- /reload: tab info not received yet (0 tabs, nil info) with snapshots in the DB.
    local db,state=LiLiBanqueDB,LiLiBanqueState
    load(); LiLiBanqueDB,LiLiBanqueState=db,state; LiLiBanque.Addon.frame:fire('OnEvent','PLAYER_LOGIN')
    MOCK.tabs={}
    UI,panel=coffre()
    eq(iconsShown(panel),0); local t=frameText(); hasnt(t,'Le Bazar'); hasnt(t,'Light Leather'); hasnt(t,'Secret')
    has(panel.message.text,'Ouvrez la banque de guilde'); hasnt(panel.message.text,'Aucun onglet acheté')
    assert(LiLiBanqueDB.stock[1] and LiLiBanqueDB.stock[3],'relevés conservés, seulement masqués')
end)

test('changement de guilde : l’ancien relevé n’ouvre pas une infobulle avant le prochain rafraîchissement',function()
    local A=load(); guildBank(A)
    local _,panel=coffre()
    GetGuildInfo=function() return 'Une autre guilde' end
    panel.slots[1]:fire('OnEnter')
    assert(not MOCK.tooltip.shown,'le nouveau rang ne confirme pas les onglets de l’ancienne guilde')
end)

test('lecture seule : aucun appel à la banque, aucune donnée ni état modifié, pas de redessin permanent',function()
    local A,fire=load(); guildBank(A)
    GuildBankFrame=MOCK.loadGuildBank(); GuildBankFrame:Show(); fire('GUILDBANKFRAME_OPENED')
    local queries=#MOCK.queries
    local stock=serialize(A.db.stock); local state=serialize(LiLiBanqueState)
    local E=LiLiBanque.Export; local payload=serialize(E.payload(A.db))
    local UI,panel=coffre()
    panel.chips[2]:Click(); panel.chips[1]:Click()
    for i=1,98 do panel.slots[i]:fire('OnEnter'); panel.slots[i]:fire('OnLeave') end
    local calls=MOCK.iconCalls
    for _=1,5 do A:updateUI() end
    eq(MOCK.iconCalls,calls) -- same reading: icons resolved once, slots not redrawn every second
    eq(#SIDE,0); eq(#MOCK.queries,queries); eq(MOCK.currentTab,1)
    eq(serialize(A.db.stock),stock); eq(serialize(E.payload(A.db)),payload)
    local after=serialize(LiLiBanqueState); eq(after,state)
end)

test('cache d’objets froid : point d’interrogation, nouvel essai espacé, puis icône réelle',function()
    local A=load(); guildBank(A); MOCK.icons[2318]=nil
    local UI,panel=coffre()
    eq(panel.slots[1].icon.texture,'Interface\\Icons\\INV_Misc_QuestionMark'); eq(panel.slots[1].count.text,'20')
    local calls=MOCK.iconCalls; A:updateUI(); eq(MOCK.iconCalls,calls,'pas de nouvel essai avant 2 s')
    NOW=NOW+2; A:updateUI(); eq(MOCK.iconCalls,calls+1,'un seul objet redemandé')
    MOCK.icons[2318]=134256; NOW=NOW+2; A:updateUI(); eq(panel.slots[1].icon.texture,134256)
    calls=MOCK.iconCalls; NOW=NOW+10; A:updateUI(); eq(MOCK.iconCalls,calls)
    -- No C_Item at all: still readable, no captured error.
    C_Item=nil; A.db.stock[1]={name='Le Bazar',icon=133784,scannedAt=NOW,scannedBy='Elvor Valbrume',slots={[3]=item(4306,'Silk Cloth',2)}}
    A:updateUI(); eq(panel.slots[3].icon.texture,'Interface\\Icons\\INV_Misc_QuestionMark'); eq(A.lastError,nil)
end)

test('nouveau relevé pendant l’affichage : la grille suit, l’infobulle ouverte se ferme',function()
    local A,fire=load(); guildBank(A)
    local UI,panel=coffre()
    panel.slots[1]:fire('OnEnter'); assert(MOCK.tooltip.shown)
    A.db.stock[1]={name='Le Bazar',icon=133784,scannedAt=NOW,scannedBy='Elvor Valbrume',slots={[2]=item(12359,'Thorium Bar',7)}}
    A:updateUI()
    assert(not MOCK.tooltip.shown,'infobulle d’un emplacement redessiné fermée')
    eq(panel.slots[1].icon.texture,nil); eq(panel.slots[2].count.text,'7'); has(panel.detail.text,'à l’instant')
    -- The window hides: tooltip owned by a slot closes too.
    panel.slots[2]:fire('OnEnter'); LiLiBanqueFrame:Hide(); assert(not MOCK.tooltip.shown)
end)

test('stock P2P : tous les onglets accessibles, affichage et export à la réception, uniquement OFFICER',function()
    local A,fire=load(); guildBank(A)
    local api=LiLiBanque; local sent,received={},{}
    C_ChatInfo.SendAddonMessage=function(prefix,msg,channel)
        eq(prefix,api.Sync.PREFIX); eq(channel,'OFFICER'); sent[#sent+1]=msg; return 0
    end
    local peerDb,peerState=api.Core.init(nil,nil,A.guild); peerDb.stock={}
    local allow=function() return true end
    local peer=api.Sync.new(peerDb,peerState,'Officier Fictif',A.guild,function(msg)
        received[#received+1]=msg; return 0
    end,function() return NOW end,function() return NOW end,{canRead=allow,canShare=allow})
    local function run(seconds)
        for _=1,seconds*2 do
            NOW=NOW+0.5; A.sync:tick(NOW,false); peer:tick(NOW,false)
            for _,m in ipairs(sent) do peer:receive(m,'OFFICER',A.name..'-Realm') end
            for _,m in ipairs(received) do fire('CHAT_MSG_ADDON',api.Sync.PREFIX,m,'OFFICER','Officier-Fictif-Realm') end
            sent,received={},{}
        end
    end
    local t=NOW-10
    A.db.stock[2]={name='Potions',icon=134712,scannedAt=t,scannedBy=A.name,slots={[3]=item(13446,'Major Healing Potion',5)}}
    A.sync:stockUpdated(1); A.sync:stockUpdated(2); A.sync:stockUpdated(3)
    run(110)
    eq(peerDb.stock[1].slots[98].count,5); eq(peerDb.stock[2].slots[3].count,5)
    eq(peerDb.stock[3],nil)
    local _,panel=coffre(); panel.chips[2]:Click()
    peerDb.stock[2]={name='Potions',icon=134712,scannedAt=NOW,scannedBy='Officier Fictif',slots={[8]=item(13446,'Major Healing Potion',9)}}
    peer:stockUpdated(2)
    run(35)
    eq(A.db.stock[2].slots[8].count,9); eq(A.db.stock[2].slots[3],nil)
    eq(panel.slots[8].count.text,'9'); has(panel.detail.text,'Officier Fictif')
    eq(api.Export.payload(A.db).stock[2].slots[8].count,9)
    eq(A.state.bankScanAt,nil)

    -- Once native access is confirmed, every bought tab (not just the first) is relayed.
    MOCK.tabs[3].viewable=true; A.sync:stockUpdated(3)
    for tab=4,8 do
        local name='Onglet fictif '..tab
        MOCK.tabs[tab]={name=name,icon=134712,viewable=true,slots={}}
        A.db.stock[tab]={name=name,icon=134712,scannedAt=NOW,scannedBy=A.name,
            slots={[tab]=item(13446,'Major Healing Potion',tab)}}
        A.sync:stockUpdated(tab)
    end
    run(180)
    for tab=1,8 do eq(peerDb.stock[tab].name,MOCK.tabs[tab].name) end
    eq(peerDb.stock[8].slots[8].count,8)
end)

local function connect(A,fire)
    local api=LiLiBanque
    local sent,received,counts={},{},{}
    local audit=api.Wire.receiver()
    local function record(side,msg)
        local payload=audit:push(side,msg,NOW)
        if not payload then return end
        local f=assert(api.Wire.unpack(payload))
        if f[4]=='stock' then counts[f[1]]=(counts[f[1]] or 0)+1 end
    end
    C_ChatInfo.SendAddonMessage=function(prefix,msg,channel)
        eq(prefix,api.Sync.PREFIX); eq(channel,'OFFICER'); record('addon',msg); sent[#sent+1]=msg; return 0
    end
    local db,state=api.Core.init(nil,nil,A.guild); db.stock={}
    local function allowed() return true end
    local peer=api.Sync.new(db,state,'Nalma Inventée',A.guild,function(msg)
        record('peer',msg); received[#received+1]=msg; return 0
    end,function() return NOW end,function() return math.floor(NOW) end,{canRead=allowed,canShare=allowed})
    local function run(seconds,untilTrue)
        local stop=NOW+seconds
        while NOW<stop and not (untilTrue and untilTrue()) do
            NOW=NOW+0.5; A:tick(); peer:tick(NOW,false)
            for _,m in ipairs(sent) do peer:receive(m,'OFFICER',A.name..'-Realm') end
            for _,m in ipairs(received) do fire('CHAT_MSG_ADDON',api.Sync.PREFIX,m,'OFFICER','Nalma-Inventee-Realm') end
            sent,received={},{}
        end
    end
    return db,peer,run,function(op) return counts[op] or 0 end
end

test('P2P : offre retenue sans métadonnées ni droits, reprise avant le prochain heartbeat',function()
    local A,fire=load()
    MOCK.tabs={}
    local db,peer,run,count=connect(A,fire)
    local function blocked()
        run(12); eq(count('SR'),0); eq(count('SS'),0); eq(count('SD'),0); eq(A.db.stock[2],nil)
    end
    db.stock[2]={name='Réserve fictive',icon=134400,scannedAt=NOW-10,scannedBy=peer.name,slots={[98]=item(2318,'Étoffe fictive',7)}}
    peer:stockUpdated(2); blocked(); eq(count('SH'),1) -- n=0
    local getCount=GetNumGuildBankTabs; GetNumGuildBankTabs=function() return nil end
    blocked(); GetNumGuildBankTabs=getCount
    MOCK.tabs={{name='Premier fictif',icon=134400,viewable=true,slots={}},
        {name=db.stock[2].name,icon=134400,viewable=nil,slots={}}}
    blocked(); MOCK.tabs[2].viewable=false; blocked()
    db.stock[2].scannedAt=NOW-1; db.stock[2].slots[98].count=9; peer:stockUpdated(2)
    blocked(); eq(count('SH'),2)
    GetGuildInfo=function() return TEST_GUILD:lower() end -- tolerated by gold, not by stock
    MOCK.tabs[2].viewable=true; blocked(); GetGuildInfo=function() return TEST_GUILD end
    run(30); eq(count('SR'),1); eq(count('SS'),1); eq(count('SD'),1)
    eq(A.db.stock[2].slots[98].count,9); eq(A.stockPeerUpdates,1)
    run(160); eq(count('SR'),1); eq(count('SS'),1); eq(count('SD'),1); eq(A.stockPeerUpdates,1)
    eq(#MOCK.queries,0); eq(MOCK.currentTab,1)
end)

test('P2P : retrait du droit pendant la réception et nom du vrai onglet contrôlé',function()
    local A,fire=load()
    MOCK.tabs={{name='Vrai nom fictif',icon=134400,viewable=true,slots={}}}
    local db,peer,run,count=connect(A,fire)
    db.stock[1]={name=MOCK.tabs[1].name,icon=134400,scannedAt=NOW-10,scannedBy=peer.name,slots={[98]=item(2318,'Étoffe fictive',7)}}
    run(25,function() return count('SS')==1 end)
    eq(count('SS'),1); eq(count('SD'),0); MOCK.tabs[1].viewable=false
    run(12); eq(count('SD'),1); eq(A.db.stock[1],nil); eq(A.stockPeerUpdates,nil)
    db.stock[1].name='Autre nom fictif'; db.stock[1].scannedAt=NOW-1
    MOCK.tabs[1].viewable=true; peer:stockUpdated(1); run(30)
    eq(count('SS'),2); eq(A.db.stock[1],nil); eq(A.stockPeerUpdates,nil); eq(#MOCK.queries,0)
end)

test('relevé : total visible, confirmation par ouverture ou Relever, pas par mouvement',function()
    local A,fire=load()
    local function slot(n) return item(2318,'Étoffe fictive',n) end
    MOCK.tabs={{name='Premier fictif',icon=134400,viewable=true,slots={[1]=slot(20)}},
        {name='Deuxième fictif',icon=134400,viewable=true,slots={[98]=slot(3)}},
        {name='Privé fictif',icon=134400,viewable=false,slots={}}}
    A.db.stock[3]={name=MOCK.tabs[3].name,icon=134400,scannedAt=NOW-5,scannedBy=A.name,slots={[1]=slot(100)}}
    local _,_,run=connect(A,fire)
    local function stockChats()
        local rows={}; for _,m in ipairs(CHAT) do if m:find('Coffre : ',1,true) then rows[#rows+1]=m end end
        return rows
    end
    local function answer() run(1); fire('GUILDBANKBAGSLOTS_CHANGED'); run(0.5) end
    fire('GUILDBANKFRAME_OPENED'); has(A:stockText(),'relevé en cours'); answer()
    eq(#stockChats(),1); has(stockChats()[1],'1 onglet, 20 objets')
    MOCK.currentTab=2; answer()
    eq(A:stockText(),'Coffre : 2 onglets, 23 objets'); eq(#stockChats(),1)
    for i=4,8 do
        MOCK.tabs[2].slots[98].count=i; fire('GUILDBANKBAGSLOTS_CHANGED'); answer()
    end
    eq(A:stockText(),'Coffre : 2 onglets, 28 objets'); eq(#stockChats(),1)
    SlashCmdList.LILIBANQUE('relever'); answer()
    eq(#stockChats(),2); has(stockChats()[2],'2 onglets, 28 objets')
    local queries=#MOCK.queries
    MOCK.currentTab=3; run(1); has(A:stockText(),'non visible')
    eq(#MOCK.queries,queries); eq(#stockChats(),3); hasnt(stockChats()[3],'Privé fictif')
    fire('GUILDBANKBAGSLOTS_CHANGED'); run(1); eq(#stockChats(),3); has(A:stockText(),'non visible')
    fire('GUILDBANKFRAME_CLOSED'); MOCK.currentTab=1
    fire('GUILDBANKFRAME_OPENED'); answer()
    eq(#stockChats(),4); has(stockChats()[4],'2 onglets, 28 objets')
end)

test('premier relevé vide : un faux signal ne remplace pas le plein du pair, deux réponses propagent le vide',function()
    local A,fire=load()
    MOCK.tabs={{name='Premier fictif',icon=134400,viewable=true,slots={}},
        {name='Réserve fictive',icon=134400,viewable=true,slots={}}}
    MOCK.currentTab=2
    local db,peer,run,count=connect(A,fire)
    local old={name=MOCK.tabs[2].name,icon=134400,scannedAt=NOW-80,scannedBy=peer.name,
        slots={[42]=item(2318,'Étoffe fictive',17)}}
    db.stock[2]=old; peer.nextHello=NOW+120 -- don't offer the peer's old stock first
    local function answer() fire('GUILDBANKBAGSLOTS_CHANGED'); run(0.5) end
    fire('GUILDBANKFRAME_OPENED'); run(1)
    eq(#MOCK.queries,1); eq(MOCK.queries[1].tab,2)
    answer() -- unindexed event from an unrelated movement; our slot cache is still cold
    eq(A.db.stock[2],nil); has(A:stockText(),'vide non confirmé')
    run(15)
    eq(#MOCK.queries,2); eq(A.db.stock[2],nil)
    eq(db.stock[2],old); eq(count('SH'),0); eq(count('SS'),0)
    A:scanNow(); run(1); eq(#MOCK.queries,3)
    answer(); eq(A.db.stock[2],nil)
    answer(); eq(#MOCK.queries,3) -- duplicate before the next query isn't its reply
    run(0.5); eq(#MOCK.queries,4); eq(A.db.stock[2],nil)
    answer(); eq(next(A.db.stock[2].slots),nil)
    run(25); eq(db.stock[2].scannedAt,A.db.stock[2].scannedAt); eq(next(db.stock[2].slots),nil)
    eq(count('SH'),1); eq(count('SR'),1); eq(count('SS'),1); eq(count('SD'),0)
    local at=A.db.stock[2].scannedAt
    A:scanNow(); run(1); answer() -- already confirmed empty can refresh once
    assert(A.db.stock[2].scannedAt>at); eq(#MOCK.queries,5)
    for i,q in ipairs(MOCK.queries) do
        eq(q.tab,2); if i>1 then assert(q.at-MOCK.queries[i-1].at>=1) end
    end
    eq(#SIDE,0); eq(MOCK.currentTab,2)
end)

for _,t in ipairs(tests) do
    local ok,e=pcall(t[2])
    local A=LiLiBanque and LiLiBanque.Addon
    if ok and A and A.lastError then ok,e=false,'erreur capturée inattendue : '..A.lastError.msg end
    if not ok then error('FAIL coffre '..t[1]..': '..tostring(e)) end
    passed=passed+1; print('ok - coffre - '..t[1])
end
print('PASS '..passed..' coffre tests')
