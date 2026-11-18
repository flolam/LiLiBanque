local tests, passed = {}, 0
function test(name, fn) tests[#tests+1]={name,fn} end
function eq(a,b) assert(a==b, tostring(a)..' ~= '..tostring(b)) end
function count(t) local n=0; for _ in pairs(t) do n=n+1 end; return n end
function loadCore() LiLiBanque={}; assert(loadfile(ROOT..'/LiLiBanque/Core.lua'))(); return LiLiBanque.Core end
local C
local function row(name,ts) return {kind='deposit',name=name,copper=40000,ts=ts or 100000,tsPrecision=3600} end
test('premier scan et chevauchement sans doublon',function()
 C=loadCore(); local db,s=C.init(nil,nil,'La Bande à Li Li')
 eq(C.scan(db,s,'ledger',{row('A'),row('B')},100010,'Elvor'),2)
 eq(C.scan(db,s,'ledger',{row('A'),row('B'),row('C')},100020,'Elvor'),1)
 eq(C.scan(db,s,'ledger',{row('B'),row('C')},100030,'Elvor'),0)
 eq(count(db.ledger),3); eq(#db.gaps,0)
end)
test('rotation signale un trou sans multiplier les alertes',function()
 local db,s=C.init(nil,nil,'G'); C.scan(db,s,'ledger',{row('A'),row('B')},100000,'Elvor')
 eq(C.scan(db,s,'ledger',{row('C'),row('D')},110000,'Elvor'),2)
 eq(#db.gaps,1); eq(db.gaps[1].reason,'rollover')
 C.scan(db,s,'ledger',{row('C'),row('D')},110010,'Elvor'); eq(#db.gaps,1)
end)
test('occurrences identiques et fusion inter-officiers décalée',function()
 local a,sa=C.init(nil,nil,'G'); local b,sb=C.init(nil,nil,'G')
 C.scan(a,sa,'ledger',{row('A'),row('A')},100000,'Elvor')
 C.scan(b,sb,'ledger',{row('A',100900),row('A',100900)},100900,'Mage')
 for _,r in pairs(b.ledger) do C.merge(a,sa,'ledger',r) end
 eq(count(a.ledger),2)
 C.scan(a,sa,'ledger',{row('A'),row('A'),row('A')},100950,'Elvor'); eq(count(a.ledger),3)
 for _,r in pairs(b.ledger) do C.merge(a,sa,'ledger',r) end; eq(count(a.ledger),3)
 for _,r in pairs(a.ledger) do C.merge(b,sb,'ledger',r) end; eq(count(b.ledger),3)
 for id in pairs(a.ledger) do assert(b.ledger[id], 'identifiants convergents') end
end)
test('horodatage et solde dédupliqué',function()
 local ts,p=C.age(200000,0,0,1,2); eq(ts,106400); eq(p,86400)
 local db=C.init(nil,nil,'G'); C.money(db,1,40000); C.money(db,2,40000); C.money(db,3,80000); eq(#db.bankMoney,2)
end)
test('transport découpe et réassemble sans exécuter de Lua',function()
 assert(loadfile(ROOT..'/LiLiBanque/Wire.lua'))(); local W=LiLiBanque.Wire
 local payload=W.pack({'D','ledger','L:Elvor:1:1','deposit','Brenø Nom',40000,100000,3600,'Elvor',100100,string.rep('é;%',300)})
 local chunks=W.chunks(payload,'abc'); assert(#chunks>1)
 local rx=W.receiver(); local out
 for i=#chunks,1,-1 do assert(#chunks[i]<255); out=rx:push('Mage',chunks[i],1) or out end
 local values=W.unpack(out); eq(values[5],'Brenø Nom'); eq(values[11],string.rep('é;%',300))
 eq(rx:push('Mage','garbage',1),nil)
end)
test('file de débit conserve lockdown et throttle puis reprend',function()
 local W=LiLiBanque.Wire; local result=11; local calls=0
 local q=W.queue(function(msg) calls=calls+1; return result end)
 q:add('hello'); q:tick(0,true); eq(calls,0); eq(q:size(),1)
 q:tick(3,false); eq(calls,1); eq(q:size(),1)
 result=3; q:tick(9,false); eq(q:size(),1)
 result=0; q:tick(15,false); eq(q:size(),0)
end)
test('handshake ne transporte que le manquant entre deux officiers',function()
 assert(loadfile(ROOT..'/LiLiBanque/Sync.lua'))(); local S=LiLiBanque.Sync
 local a,sa=C.init(nil,nil,'G'); local b,sb=C.init(nil,nil,'G')
 C.scan(a,sa,'ledger',{row('A'),row('A')},100000,'Elvor')
 local now=0; local aq,bq={},{}
 local x=S.new(a,sa,'Elvor','G',function(m) aq[#aq+1]=m; return 0 end,function() return now end)
 local y=S.new(b,sb,'Mage','G',function(m) bq[#bq+1]=m; return 0 end,function() return now end)
 x:hello(); y:hello()
 for n=1,1000 do
  now=n; x:tick(now,false); y:tick(now,false)
  while #aq>0 do y:receive(table.remove(aq,1),'OFFICER','Elvor-Surname-CAMWOWEU4Realm7PvP') end
  while #bq>0 do x:receive(table.remove(bq,1),'OFFICER','Mage') end
 end
 eq(count(b.ledger),2); eq(x.transferred,0); eq(y.transferred,2)
 x:hello(); y:hello()
 for n=1001,1100 do now=n; x:tick(now,false); y:tick(now,false)
  while #aq>0 do y:receive(table.remove(aq,1),'OFFICER','Elvor-Surname-CAMWOWEU4Realm7PvP') end
  while #bq>0 do x:receive(table.remove(bq,1),'OFFICER','Mage') end
 end
 eq(y.transferred,2)
end)

-- A real H/I/R/D exchange, not a copy of canonical DB rows: origin evidence must travel.
local function network(names,oldIndex)
 local core=loadCore(); assert(loadfile(ROOT..'/LiLiBanque/Wire.lua'))()
 assert(loadfile(ROOT..'/LiLiBanque/Sync.lua'))(); local sync=LiLiBanque.Sync
 local oldSync,oldCore
 if oldIndex then
  assert(loadfile(ROOT..'/tests/compat/core-1.2.0.lua'))(); oldCore=LiLiBanque.Core
  assert(loadfile(ROOT..'/tests/compat/sync-1.1.1.lua'))(); oldSync=LiLiBanque.Sync
  LiLiBanque.Core=core; LiLiBanque.Sync=sync
 end
 local net={now=0,peers={},messages={}}
 for i,name in ipairs(names) do
  local peerCore=i==oldIndex and oldCore or core
  local db,state=peerCore.init(nil,nil,'G'); local p={db=db,state=state,name=name,core=peerCore}; net.peers[i]=p
  p.sync=(i==oldIndex and oldSync or sync).new(db,state,name,'G',function(m)
   net.messages[#net.messages+1]={from=i,msg=m}; return 0
  end,function() return net.now end,function() return 200000 end)
 end
 function net:scan(i,n,at)
  local rows={}; for _=1,n do rows[#rows+1]=row('Donateur Inventé') end
  return self.peers[i].core.scan(self.peers[i].db,self.peers[i].state,'ledger',rows,at,self.peers[i].name)
 end
 function net:exchange(order,steps)
  order=order or {1,2}
  for _,i in ipairs(order) do self.peers[i].sync:hello() end
  for _=1,steps or 180 do
   self.now=self.now+1
   for _,i in ipairs(order) do self.peers[i].sync:tick(self.now,false) end
   while #self.messages>0 do
    local m=table.remove(self.messages,1)
    for _,i in ipairs(order) do if i~=m.from then self.peers[i].sync:receive(m.msg,'OFFICER',self.peers[m.from].name) end end
   end
  end
 end
 function net:check(n)
  local expected=self.peers[1].db.ledger
  for _,p in ipairs(self.peers) do
   eq(count(p.db.ledger),n)
   for id,r in pairs(expected) do
    local other=assert(p.db.ledger[id],'ID divergent : '..id)
    for k,v in pairs(r) do eq(other[k],v) end
   end
   eq(count(p.db),9); eq(#p.db.gaps,0)
  end
 end
 return net
end
test('régression : Zelvor 3 dépôts identiques après canonisation Mage, synchro sans perte',function()
 local net=network({'Zelvor','Mage'})
 eq(net:scan(1,2,100000),2); eq(net:scan(2,2,100900),2)
 for _,r in pairs(net.peers[2].db.ledger) do C.merge(net.peers[1].db,net.peers[1].state,'ledger',r) end
 eq(count(net.peers[1].db.ledger),2)
 eq(net:scan(1,3,100950),1); eq(count(net.peers[1].db.ledger),3)
 net:exchange(); net:check(3)
end)

test('trois officiers : maximum et convergence pour les six ordres, relevés répétés',function()
 local orders={{1,2,3},{1,3,2},{2,1,3},{2,3,1},{3,1,2},{3,2,1}}
 for _,order in ipairs(orders) do
  local net=network({'Zelvor','Mage','Alor'})
  net:scan(1,2,100000); net:scan(2,2,100100); net:scan(3,1,100200)
  for _,r in pairs(net.peers[2].db.ledger) do C.merge(net.peers[1].db,net.peers[1].state,'ledger',r) end
  net:scan(1,3,100300); net:exchange(order); net:check(3)
  for round=1,3 do
   eq(net:scan(1,3,100300+round),0); eq(net:scan(2,3,100400+round),0); eq(net:scan(3,2,100500+round),0)
   net:exchange(order); net:check(3)
  end
  eq(net:scan(3,4,100600),1); net:exchange(order); net:check(4)
  local transferred={}; for i,p in ipairs(net.peers) do transferred[i]=p.sync.transferred end
  net:exchange(order)
  for i,p in ipairs(net.peers) do eq(p.sync.transferred,transferred[i]) end
 end
end)
test('preuves originales reçues en ordre inverse ou entrelacé : même ensemble, pas somme',function()
 C=loadCore(); local evidence={}
 for source,n in pairs({Zelvor=4,Mage=2,Alor=3}) do
  local db,s=C.init(nil,nil,'G'); local rows={}; for _=1,n do rows[#rows+1]=row('A') end
  C.scan(db,s,'ledger',rows,100000,source)
  for _,r in pairs(db.ledger) do evidence[#evidence+1]=r end
 end
 table.sort(evidence,function(a,b) return a.id<b.id end)
 local expected
 for _,order in ipairs({{1,2,3,4,5,6,7,8,9},{9,8,7,6,5,4,3,2,1},{9,1,5,2,8,4,7,3,6}}) do
  local db,s=C.init(nil,nil,'G')
  for _,i in ipairs(order) do C.merge(db,s,'ledger',evidence[i]) end
  eq(count(db.ledger),4)
  if expected then for id in pairs(expected) do assert(db.ledger[id],'ordre différent : '..id) end else expected=db.ledger end
  for _=1,3 do for _,i in ipairs(order) do C.merge(db,s,'ledger',evidence[i]) end end
  eq(count(db.ledger),4)
 end
end)
test('migration des claims 1.2.0 : origine conservée après reload, DB inchangée',function()
 C=loadCore(); local db,s=C.init(nil,nil,'G')
 for i=1,2 do
  local id='L:Mage:100100:'..i; local old='L:Zelvor:100000:'..i
  local r=row('Donateur Inventé'); r.id=id; r.source='Zelvor'; r.seenAt=100000; db.ledger[id]=r
  s.claims.ledger=s.claims.ledger or {}; s.claims.ledger[id]={Mage=id,Zelvor=old}
  s.aliases.ledger=s.aliases.ledger or {}; s.aliases.ledger[old]=id
 end
 s.seq=2; s.markers.ledger={Zelvor={'L:Zelvor:100000:1','L:Zelvor:100000:2'}}
 eq(count(C.observations(db,s,'ledger')),4)
 local rows={row('Donateur Inventé'),row('Donateur Inventé'),row('Donateur Inventé')}
 eq(C.scan(db,s,'ledger',rows,100200,'Zelvor'),1); eq(count(db.ledger),3)
 local reloaded,rs=C.init(db,s,'G'); eq(C.scan(reloaded,rs,'ledger',rows,100300,'Zelvor'),0)
 eq(count(reloaded.ledger),3); eq(count(reloaded),9)
 local peer,ps=C.init(nil,nil,'G')
 for _,r in pairs(C.observations(reloaded,rs,'ledger')) do C.merge(peer,ps,'ledger',r) end
 eq(count(peer.ledger),3); for id in pairs(reloaded.ledger) do assert(peer.ledger[id]) end
end)
test('fenêtres disjointes et types/noms/montants différents restent distincts',function()
 C=loadCore(); local db,s=C.init(nil,nil,'G')
 local rows={row('A'),row('A'),row('A',120000),row('B'),row('A'),row('A')}
 rows[5].copper=60000; rows[6].kind='withdraw'
 C.scan(db,s,'ledger',rows,120100,'Zelvor')
 C.scan(db,s,'ledger',rows,120200,'Mage')
 eq(count(db.ledger),6)
end)
test('régression envoyée au vrai Core 1.2.0 + Sync 1.1.1 : protocole conservé',function()
 do
  local net=network({'Zelvor','Mage'},2)
  net:scan(1,2,100000); net:scan(2,2,100900)
  for _,r in pairs(net.peers[2].db.ledger) do C.merge(net.peers[1].db,net.peers[1].state,'ledger',r) end
  net:scan(1,3,100950); net:exchange(); net:check(3)
  net:scan(2,4,101000); net:exchange(); net:check(4)
 end
end)

test('réception depuis un ancien pair : journal distinct paginé et idempotent',function()
 local net=network({'Zelvor','Mage'},1); local source=net.peers[1]
 local rows={}; for i=1,35 do rows[i]=row('Donateur '..i) end
 source.core.scan(source.db,source.state,'ledger',rows,100000,source.name)
 net:exchange(nil,600); net:check(35)
 local transferred=net.peers[2].sync.transferred
 net:exchange(nil,300); net:check(35); eq(net.peers[2].sync.transferred,transferred)
end)
test('événements identiques : preuves par origine et ordre déterministe',function()
 C=loadCore(); local all={}
 for source,n in pairs({Zelvor=3,Mage=2,Alor=1}) do
  local db,s=C.init(nil,nil,'G'); local rows={}
  for i=1,n do rows[i]={kind='promote',player='Recrue Inventée',actor='Chef Inventé',rank='Officier',ts=100000,tsPrecision=3600} end
  C.scan(db,s,'events',rows,100000,source)
  for _,r in pairs(db.events) do all[#all+1]=r end
 end
 table.sort(all,function(a,b) return a.id<b.id end)
 local a,sa=C.init(nil,nil,'G'); local b,sb=C.init(nil,nil,'G')
 for i=1,#all do C.merge(a,sa,'events',all[i]); C.merge(b,sb,'events',all[#all-i+1]) end
 eq(count(a.events),3); eq(count(b.events),3)
 for id,r in pairs(a.events) do assert(b.events[id]); eq(b.events[id].rank,r.rank) end
end)

local MOCK=assert(loadfile(ROOT..'/tests/wowmock.lua'))()
CHAT={}
local function chat(pattern) for i=#CHAT,1,-1 do if CHAT[i]:find(pattern,1,true) then return CHAT[i] end end; return nil end
-- Loads the six TOC files in order, like the client, against the strict widget mock.
local function loadAddon(keep)
 NOW=200000
 if not keep then LiLiBanqueDB=nil; LiLiBanqueState=nil end
 MOCK.install(); CHAT={}; SOUNDS={}
 SOUNDKIT={IG_MAINMENU_OPTION_CHECKBOX_ON=856}; PlaySound=function(id) SOUNDS[#SOUNDS+1]=id end
 C_ChatInfo={RegisterAddonMessagePrefix=function() return 0 end,SendAddonMessage=function() return 0 end,InChatMessagingLockdown=function() return false end,AreOutgoingAddonChatMessagesRestricted=function() return false end}
 C_GuildInfo={GuildRoster=function() end,CanViewOfficerNote=function() return true end}
 GetServerTime=function() return NOW end; GetTime=function() return NOW end
 GetGuildInfo=function() return 'La Bande à Li Li' end; IsInGuild=function() return true end
 GetUnitName=function() return 'Elvor Valbrume' end; UnitName=function() return 'Elvor','Nom' end
 DEFAULT_CHAT_FRAME={AddMessage=function(_,m) CHAT[#CHAT+1]=m end}; SlashCmdList={}
 SLASH_LILIBANQUE1=nil; SLASH_LILIBANQUE2=nil
 QUERIES=0; QueryGuildBankLog=function(tab) eq(tab,9); QUERIES=QUERIES+1 end; MAX_GUILDBANK_TABS=8
 GetNumGuildBankTabs=function() return 1 end; CanWithdrawGuildBankMoney=function() return true end
 GetNumGuildBankMoneyTransactions=function() return 2 end
 GetGuildBankMoneyTransaction=function(i) return 'deposit','Brenø Nom',40000,0,0,0,1 end
 GetGuildBankMoney=function() return 80000 end
 QueryGuildEventLog=function() end; GetNumGuildEvents=function() return 2 end
 GetGuildEventInfo=function(i) if i==1 then return 'join','Recrue Neuve',nil,nil,0,0,0,1 else return 'invite','Elvor Valbrume','Recrue Neuve',nil,0,0,0,2 end end
 GetNumGuildMembers=function() return 1 end
 GetGuildRosterInfo=function() return 'Brenø Nom','Membre',2,42,'Paladin','','Salut','reroll de Elvor Valbrume',false,0,'PALADIN' end
 IsInInstance=nil; InCombatLockdown=nil; issecretvalue=nil; debugprofilestop=nil
 LiLiBanque={}
 for _,f in ipairs({'Core','Wire','Sync','Export','Addon','UI'}) do assert(loadfile(ROOT..'/LiLiBanque/'..f..'.lua'))() end
 return LiLiBanque.Addon,LiLiBanque.Addon.frame
end
-- Events go through the real OnEvent script (with its error guard), like the client.
local function fire(event,...) LiLiBanque.Addon.frame:fire('OnEvent',event,...) end
local function update(seconds) NOW=NOW+(seconds or 0); LiLiBanque.Addon.frame:fire('OnUpdate',1) end
test('événements WoW réels simulés : banque, roster, recrues et UI',function()
 local A=loadAddon(); fire('PLAYER_LOGIN'); GuildBankFrame=MOCK.loadGuildBank(); GuildBankFrame:Show()
 fire('GUILDBANKFRAME_OPENED'); fire('GUILDBANKLOG_UPDATE')
 eq(count(LiLiBanqueDB.ledger),2); eq(#LiLiBanqueDB.bankMoney,1)
 fire('GUILD_ROSTER_UPDATE'); fire('GUILD_EVENT_LOG_UPDATE')
 eq(LiLiBanqueDB.roster.members['Brenø Nom'].classFile,'PALADIN')
 eq(LiLiBanqueDB.roster.members['Brenø Nom'].officerNote,'reroll de Elvor Valbrume')
 eq(count(LiLiBanqueDB.events),2)
 for _,e in pairs(LiLiBanqueDB.events) do if e.kind=='invite' then eq(e.actor,'Elvor Valbrume'); eq(e.player,'Recrue Neuve') end end
 assert(LiLiBanque.UI.bankText.text:find('journal relevé',1,true),LiLiBanque.UI.bankText.text)
 assert(chat('journal relevé, 2 nouvelles lignes (solde 8 po)'))
 fire('GUILDBANKFRAME_CLOSED'); NOW=NOW+5; fire('GUILDBANKLOG_UPDATE'); eq(count(LiLiBanqueDB.ledger),2)
end)
test('chargement unique : message de version une fois, /lili et /lilibanque',function()
 local A=loadAddon(); fire('PLAYER_LOGIN')
 eq(#CHAT,1); assert(CHAT[1]:find('version 1.2.1 chargée — /lili',1,true),CHAT[1])
 eq(SLASH_LILIBANQUE1,'/lili'); eq(SLASH_LILIBANQUE2,'/lilibanque')
 SlashCmdList.LILIBANQUE(''); assert(LiLiBanqueFrame:IsShown(),'fenêtre ouverte par /lili')
 SlashCmdList.LILIBANQUE('  '); assert(not LiLiBanqueFrame:IsShown(),'second /lili referme')
 SlashCmdList.LILIBANQUE('inconnu'); assert(chat('/lili diag : diagnostic'))
 SlashCmdList.LILIBANQUE('scan'); assert(chat('ouvrez la banque de guilde'))
end)
test('banque chargée à la demande : cadre créé après le signal, ligne d’état attachée',function()
 local A=loadAddon(); fire('PLAYER_LOGIN'); eq(GuildBankFrame,nil)
 -- The interaction manager signal arrives before LoadAddOn created GuildBankFrame.
 fire('PLAYER_INTERACTION_MANAGER_FRAME_SHOW',10); assert(A.bankOpen); eq(QUERIES,1); eq(LiLiBanque.UI.bankLine,nil)
 local bank=MOCK.loadGuildBank(); fire('ADDON_LOADED','Blizzard_GuildBankUI'); bank:Show()
 local line=LiLiBanque.UI.bankLine; assert(line,'ligne d’état créée au chargement du cadre'); eq(line:GetParent(),bank)
 local p,rel,rp,x,y=line:GetPoint(1); eq(p,'TOPLEFT'); eq(rel,bank); eq(rp,'BOTTOMLEFT')
 fire('GUILDBANKFRAME_OPENED') -- duplicate signal: no second request
 eq(QUERIES,1)
 fire('GUILDBANKLOG_UPDATE'); assert(chat('journal relevé, 2 nouvelles lignes'))
 assert(LiLiBanque.UI.bankText.text:find('2 nouvelles lignes',1,true))
 -- Closing then reopening through the frame itself (no legacy event at all).
 bank:Hide(); assert(not A.bankOpen,'OnHide referme')
 CHAT={}; bank:Show(); assert(A.bankOpen); eq(A.openedVia,'cadre')
 fire('GUILDBANKLOG_UPDATE'); assert(chat('journal relevé, 0 nouvelle ligne'),tostring(CHAT[1]))
 fire('PLAYER_INTERACTION_MANAGER_FRAME_HIDE',10); assert(not A.bankOpen)
 fire('PLAYER_INTERACTION_MANAGER_FRAME_SHOW',26); assert(not A.bankOpen,'autre interaction ignorée')
end)
test('nom de guilde : variantes tolérées, autre guilde annoncée et isolée',function()
 local A=loadAddon(); GetGuildInfo=function() return 'la  bande a\194\160li li' end
 fire('PLAYER_LOGIN'); assert(A:active(),'casse/espaces/accent tolérés'); eq(LiLiBanqueDB.guild,'La Bande à Li Li')
 A=loadAddon(); GetGuildInfo=function() return 'La Bande à Lili' end
 fire('PLAYER_LOGIN'); eq(A.db,nil)
 GuildBankFrame=MOCK.loadGuildBank(); GuildBankFrame:Show(); fire('GUILDBANKFRAME_OPENED')
 assert(chat('inactif : guilde lue « La Bande à Lili », attendue « La Bande à Li Li »'),tostring(CHAT[#CHAT]))
 assert(LiLiBanque.UI.bankText.text:find('La Bande à Lili',1,true))
 eq(QUERIES,0); eq(LiLiBanqueDB,nil)
 CHAT={}; SlashCmdList.LILIBANQUE('diag')
 assert(chat('Guilde lue : « La Bande à Lili » ; attendue « La Bande à Li Li » ; différente'))
 assert(chat('Actif : non'))
 GetGuildInfo=function() return nil end; CHAT={}; SlashCmdList.LILIBANQUE('diag'); assert(chat('Guilde lue : aucune'))
end)
test('banque sans onglet : journal vide expliqué, solde à 0 relevé',function()
 local A=loadAddon(); GetNumGuildBankTabs=function() return 0 end
 GetNumGuildBankMoneyTransactions=function() return 0 end; GetGuildBankMoney=function() return 0 end
 fire('PLAYER_LOGIN'); GuildBankFrame=MOCK.loadGuildBank(); GuildBankFrame:Show(); fire('GUILDBANKFRAME_OPENED')
 fire('GUILDBANKLOG_UPDATE'); eq(chat('journal'),nil) -- not concluded on the first empty answer
 update(1); update(3)
 assert(chat('journal d’or vide (aucun onglet acheté)'),tostring(CHAT[#CHAT]))
 eq(#LiLiBanqueDB.bankMoney,1); eq(LiLiBanqueDB.bankMoney[1].copper,0); eq(#LiLiBanqueDB.gaps,0)
 eq(LiLiBanqueDB.scannedBy['Elvor Valbrume'],NOW)
 -- A first purchase then appears in the log as buyTab: read normally.
 GetNumGuildBankTabs=function() return 1 end; GetNumGuildBankMoneyTransactions=function() return 1 end
 GetGuildBankMoneyTransaction=function() return 'buyTab','Elvor Valbrume',1000000,0,0,0,0 end
 CHAT={}; SlashCmdList.LILIBANQUE('scan'); fire('GUILDBANKLOG_UPDATE'); assert(chat('journal relevé, 1 nouvelle ligne'))
end)
test('lignes hors contrat ignorées, noms non chargés réessayés puis expliqués',function()
 local A=loadAddon()
 GetNumGuildBankMoneyTransactions=function() return 3 end
 GetGuildBankMoneyTransaction=function(i) if i==2 then return 'buyRename','Elvor Valbrume',50000,0,0,0,1 end; return 'deposit','Brenø Nom',40000+i,0,0,0,1 end
 fire('PLAYER_LOGIN'); GuildBankFrame=MOCK.loadGuildBank(); GuildBankFrame:Show(); fire('GUILDBANKFRAME_OPENED'); fire('GUILDBANKLOG_UPDATE')
 eq(count(LiLiBanqueDB.ledger),2); eq(A.skipped,1); assert(chat('2 nouvelles lignes'))
 GetGuildBankMoneyTransaction=function(i) return 'deposit',nil,40000,0,0,0,1 end
 CHAT={}; SlashCmdList.LILIBANQUE('scan')
 fire('GUILDBANKLOG_UPDATE'); eq(chat('journal'),nil); update(2)
 fire('GUILDBANKLOG_UPDATE'); fire('GUILDBANKLOG_UPDATE')
 assert(chat('journal incomplet (ligne 1 : nom pas encore chargé)'),tostring(CHAT[#CHAT]))
 eq(count(LiLiBanqueDB.ledger),2)
 -- No answer at all: explained after 10 s.
 GetNumGuildBankMoneyTransactions=function() return 2 end
 CHAT={}; SlashCmdList.LILIBANQUE('scan'); update(5); update(6)
 assert(chat('journal non reçu après 10 s'),tostring(CHAT[#CHAT]))
end)
test('erreur Lua capturée : message en jeu et détail dans /lili diag',function()
 local A=loadAddon(); fire('PLAYER_LOGIN'); GuildBankFrame=MOCK.loadGuildBank(); GuildBankFrame:Show(); fire('GUILDBANKFRAME_OPENED')
 local scan=LiLiBanque.Core.scan; LiLiBanque.Core.scan=function() error('boom de test') end
 fire('GUILDBANKLOG_UPDATE'); LiLiBanque.Core.scan=scan
 assert(chat('erreur pendant le relevé : '),tostring(CHAT[#CHAT])); assert(chat('boom de test (/lili diag)'))
 eq(LiLiBanqueState.lastError.where,'GUILDBANKLOG_UPDATE')
 CHAT={}; SlashCmdList.LILIBANQUE('diag')
 local line=chat('Dernière erreur Lua : '); assert(line and line:find('boom de test',1,true) and line:find('[GUILDBANKLOG_UPDATE]',1,true),tostring(line))
 assert(chat('LiLiBanque 1.2.1 ; client 1.60.1 (70959), interface 16001'))
 assert(chat('Banque ouverte : oui (signal : événement) ; GuildBankFrame : chargé, affiché ; Blizzard_GuildBankUI chargé : oui ; onglets achetés : 1'))
 assert(chat('Notes d’officier lisibles : oui'))
 -- Errors survive a /reload through the per-character state.
 local state=LiLiBanqueState; loadAddon(true); LiLiBanqueState=state; fire('PLAYER_LOGIN')
 CHAT={}; SlashCmdList.LILIBANQUE('diag'); assert(chat('boom de test'))
 -- Errors in a click handler are captured too.
 QueryGuildBankLog=function() error('Interface/AddOns/LiLiBanque/x.lua:1: refusé') end
 GuildBankFrame=MOCK.loadGuildBank(); GuildBankFrame:Show(); fire('GUILDBANKFRAME_OPENED')
 assert(chat('journal refusé par le jeu : x.lua:1: refusé'),tostring(CHAT[#CHAT]))
end)
test('fenêtre /lili : Échap, déplacement mémorisé, rendu des mouvements et bouton Relever',function()
 local A=loadAddon(); fire('PLAYER_LOGIN'); fire('GUILD_ROSTER_UPDATE')
 GuildBankFrame=MOCK.loadGuildBank(); GuildBankFrame:Show(); fire('GUILDBANKFRAME_OPENED'); fire('GUILDBANKLOG_UPDATE')
 SlashCmdList.LILIBANQUE('')
 local f=LiLiBanqueFrame; assert(f:IsShown()); eq(f.template,'ButtonFrameTemplate'); eq(f.title,'La Bande à Li Li'); eq(f.portrait,false)
 assert(f.movable and f.clamped and f.toplevel); eq(f.drag,'LeftButton')
 local found=false; for _,n in ipairs(UISpecialFrames) do if n=='LiLiBanqueFrame' then found=true end end; assert(found,'Échap')
 eq(f.Tabs,nil) -- one section: no tab bar
 local UI=LiLiBanque.UI; local panel=UI.sections[1].panel
 local r=panel.rows[1]
 eq(r.name.text,'|cfff48cbaBrenø Nom|r'); eq(r.amount.text,'4 po'); eq(r.kind.text,'dépôt'); eq(r.ago.text,'il y a 1 h')
 eq(panel.rows[3].name.text,'')
 assert(panel.values.scan.text:find('2 nouvelles lignes',1,true),panel.values.scan.text)
 assert(panel.values.money.text:find('8 po',1,true)); eq(panel.values.gaps.text,'aucun')
 assert(panel.values.sync.text:find('file',1,true))
 eq(panel.hint.text,'Le fichier pour le site n’est écrit qu’au /reload ou à la déconnexion.')
 assert(UI.scanButton:IsEnabled()); fire('GUILDBANKFRAME_CLOSED'); update(1); assert(not UI.scanButton:IsEnabled(),'Relever grisé banque fermée')
 fire('GUILDBANKFRAME_OPENED'); update(1); assert(UI.scanButton:IsEnabled()); NOW=NOW+60; UI.scanButton:Click(); eq(A.pending,true)
 -- Withdrawal row, class colour by first name, gaps line.
 A.db.ledger['L:x']={id='L:x',kind='repair',name='Brenø',copper=12345,ts=NOW-90000,tsPrecision=86400,source='Elvor Valbrume',seenAt=NOW}
 A.db.gaps[1]={at=NOW,reason='rollover'}; A:updateUI()
 eq(panel.rows[3].amount.text,'|cffff6060-1 po 23 pa 45 pc|r'); eq(panel.rows[3].name.text,'|cfff48cbaBrenø|r'); eq(panel.rows[3].ago.text,'~il y a 1 j')
 assert(panel.values.gaps.text:find('1|r, dernier le',1,true))
 -- Drag then reload: position restored from the per-character state.
 f:fire('OnDragStart'); f:ClearAllPoints(); f:SetPoint('TOPLEFT',UIParent,'TOPLEFT',123.4,-56.6); f:fire('OnDragStop')
 eq(LiLiBanqueState.ui.point,'TOPLEFT'); eq(LiLiBanqueState.ui.x,123); eq(LiLiBanqueState.ui.y,-57)
 f:Hide(); assert(not f:IsShown())
 local db,state=LiLiBanqueDB,LiLiBanqueState; loadAddon(true); LiLiBanqueDB,LiLiBanqueState=db,state; fire('PLAYER_LOGIN')
 SlashCmdList.LILIBANQUE('')
 local p,_,rp,x,y=LiLiBanqueFrame:GetPoint(1); eq(p,'TOPLEFT'); eq(rp,'TOPLEFT'); eq(x,123); eq(y,-57)
 local st=LiLiBanque.UI.sections[1].panel.values.scan.text; assert(st:find('2 nouvelles lignes',1,true),st) -- last scan kept across /reload
 -- Inactive addon: the window still opens and says why.
 loadAddon(); GetGuildInfo=function() return 'Autre' end; fire('PLAYER_LOGIN'); SlashCmdList.LILIBANQUE('')
 assert(LiLiBanque.UI.sections[1].panel.values.scan.text:find('guilde lue « Autre »',1,true))
 assert(not LiLiBanque.UI.exportButton:IsEnabled())
end)
test('sections déclarées dans une table : onglets seulement à partir de deux',function()
 loadAddon(); fire('PLAYER_LOGIN')
 local built,refreshed=0,0
 LiLiBanque.UI.addSection({key='autre',title='Autre outil',build=function(p) built=built+1 end,refresh=function() refreshed=refreshed+1 end})
 SlashCmdList.LILIBANQUE('')
 local f=LiLiBanqueFrame; eq(#f.Tabs,2); eq(f.numTabs,2); eq(f.Tabs[2].text,'Autre outil'); eq(built,1)
 f.Tabs[2]:Click(); eq(f.selectedTab,2); assert(LiLiBanque.UI.sections[2].panel:IsShown()); assert(not LiLiBanque.UI.sections[1].panel:IsShown())
 assert(refreshed>0); eq(LiLiBanque.UI.header.text,'Autre outil')
end)

test('absence de droits et données secrètes : aucune erreur ni fuite',function()
 local A=loadAddon(); C_GuildInfo.CanViewOfficerNote=function() return false end
 QueryGuildBankLog=function() error('Permission refusée') end
 GetNumGuildBankMoneyTransactions=function() error('Permission refusée') end
 fire('PLAYER_LOGIN'); fire('GUILDBANKFRAME_OPENED'); fire('GUILDBANKLOG_UPDATE'); fire('GUILD_ROSTER_UPDATE')
 eq(count(LiLiBanqueDB.ledger),0); eq(LiLiBanqueDB.roster.members['Brenø Nom'].officerNote,nil)
 local refused=chat('journal refusé par le jeu : '); assert(refused and refused:find('Permission refusée',1,true),tostring(refused)); eq(A.lastError,nil)
 local secret={}; issecretvalue=function(v) return v==secret end
 GetGuildRosterInfo=function() return secret end
 fire('GUILD_ROSTER_UPDATE'); eq(count(LiLiBanqueDB.roster.members),1)
 issecretvalue=nil
end)
test('reset exige confirmation ; une autre guilde ne contamine pas le relevé',function()
 local A=loadAddon(); fire('PLAYER_LOGIN'); fire('GUILDBANKFRAME_OPENED'); fire('GUILDBANKLOG_UPDATE')
 A:command('reset CONFIRMER'); eq(count(A.db.ledger),2)
 A:command('reset'); NOW=NOW+31; A:command('reset CONFIRMER'); eq(count(A.db.ledger),2)
 LiLiBanqueState.ui={point='TOP',relPoint='TOP',x=1,y=2}
 A:command('reset'); A:command('reset CONFIRMER'); eq(count(A.db.ledger),0); eq(LiLiBanqueState.ui.point,'TOP')
 GetGuildInfo=function() return 'Autre guilde' end
 fire('GUILD_EVENT_LOG_UPDATE'); fire('GUILD_ROSTER_UPDATE'); fire('GUILDBANKLOG_UPDATE'); eq(count(A.db.ledger),0)
end)
test('Forever restriction générale hors instance ne bloque pas une API autorisée',function()
 local A=loadAddon(); local sends=0
 C_ChatInfo.AreOutgoingAddonChatMessagesRestricted=function() return true end
 C_ChatInfo.SendAddonMessage=function() sends=sends+1; return 0 end
 IsInInstance=function() return false end; InCombatLockdown=function() return false end
 fire('PLAYER_LOGIN'); update(0); assert(sends>0,'ne pas bloquer indéfiniment les envois hors lockdown')
 C_ChatInfo.InChatMessagingLockdown=function() return true end
 local before=sends; update(10); eq(sends,before)
end)
test('officiers vus par la synchro affichés par leur nom applicatif',function()
 local A=loadAddon(); fire('PLAYER_LOGIN')
 local W=LiLiBanque.Wire; local other,so=LiLiBanque.Core.init(nil,nil,'La Bande à Li Li'); local out={}
 local peer=LiLiBanque.Sync.new(other,so,'Magor Barbefer','La Bande à Li Li',function(m) out[#out+1]=m; return 0 end,function() return NOW end)
 peer:hello(); for _=1,10 do peer.q:tick(NOW,false); NOW=NOW+1 end
 for _,m in ipairs(out) do fire('CHAT_MSG_ADDON','LiLiBanque1',m,'OFFICER','Magor-Barbefer-CAMWOWEU4Realm7PvP') end
 assert(A.sync.seen['Magor Barbefer']); SlashCmdList.LILIBANQUE('')
 assert(LiLiBanque.UI.sections[1].panel.values.sync.text:find('vus : Magor Barbefer',1,true),LiLiBanque.UI.sections[1].panel.values.sync.text)
end)
test('solde relevé même lorsque le journal est refusé',function()
 local A=loadAddon(); QueryGuildBankLog=function() error('refusé') end
 fire('PLAYER_LOGIN'); fire('GUILDBANKFRAME_OPENED')
 eq(#A.db.bankMoney,1); eq(A.db.bankMoney[1].copper,80000)
end)
test('login avec guilde non encore chargée : roster, banque ou relance périodique',function()
 local A=loadAddon(); GetGuildInfo=function() return nil end
 fire('PLAYER_LOGIN'); eq(A.db,nil)
 GetGuildInfo=function() return 'La Bande à Li Li' end
 fire('GUILD_ROSTER_UPDATE'); assert(A.db,'initialisation après cache de guilde')
 eq(count(A.db.roster.members),1)
 A=loadAddon(); GetGuildInfo=function() return nil end; fire('PLAYER_LOGIN')
 GetGuildInfo=function() return 'La Bande à Li Li' end; fire('GUILDBANKFRAME_OPENED'); assert(A.db,'init à l’ouverture de la banque'); eq(QUERIES,1)
 A=loadAddon(); GetGuildInfo=function() return nil end; fire('PLAYER_LOGIN')
 GetGuildInfo=function() return 'La Bande à Li Li' end; update(6); assert(A.db,'relance toutes les 5 s')
end)
test('événement inconnu du client : les autres restent enregistrés',function()
 MOCK.unknownEvents={GUILDBANKFRAME_OPENED=true}
 local A=loadAddon(); MOCK.unknownEvents=nil
 assert(A.frame.events.PLAYER_INTERACTION_MANAGER_FRAME_SHOW); assert(A.frame.events.GUILDBANKLOG_UPDATE); eq(A.frame.events.GUILDBANKFRAME_OPENED,nil)
end)
test('paquets H stricts et valeurs numériques hostiles rejetées',function()
 local W=LiLiBanque.Wire; local db,s=C.init(nil,nil,'G'); local chunks={}
 local x=LiLiBanque.Sync.new(db,s,'Elvor','G',function(m) chunks[#chunks+1]=m; return 0 end,function() return 1 end)
 x:hello(); x.q:tick(1,false)
 local p=W.receiver():push('Elvor',chunks[1],1); local f=W.unpack(p); eq(#f,6); eq(f[5],'Elvor')
 local r=row('A'); r.id='L:Elvor:1:1'; r.source='Elvor'; r.seenAt=0/0; assert(not C.valid('ledger',r))
 r.seenAt=100; r.tsPrecision=0/0; assert(not C.valid('ledger',r))
end)
test('SavedVariables survit au rechargement et fixture respecte le contrat',function()
 local a,s=C.init(nil,nil,'G'); C.scan(a,s,'ledger',{row('A'),row('A')},100000,'Elvor')
 local a2,s2=C.init(a,s,'G'); eq(C.scan(a2,s2,'ledger',{row('A'),row('A')},100100,'Elvor'),0)
 assert(loadfile(ROOT..'/fixtures/LiLiBanque.lua'))(); local fixture=LiLiBanqueDB
 eq(fixture.schema,1); eq(count(fixture.roster.members),15); eq(count(fixture.ledger),30); eq(count(fixture.events),5); eq(#fixture.gaps,1)
 for id,r in pairs(fixture.ledger) do eq(id,r.id); assert(C.valid('ledger',r)) end
 for id,r in pairs(fixture.events) do eq(id,r.id); assert(C.valid('events',r)) end
end)
test('100 dépôts tournants, deux relevés et convergence différée',function()
 local a,sa=C.init(nil,nil,'G'); local b,sb=C.init(nil,nil,'G'); local all={}
 for i=1,100 do
  all[#all+1]=row('Joueur '..(i%7),100000+i*3600)
  local function snapshot()
   local r={}; for j=math.max(1,i-19),i do r[#r+1]=C.copy(all[j]) end; return r
  end
  if i%4==0 or i==100 then C.scan(a,sa,'ledger',snapshot(),100000+i*3600,'Elvor') end
  if i%7==0 or i==100 then C.scan(b,sb,'ledger',snapshot(),100000+i*3600+600,'Mage') end
  if i%13==0 or i==100 then
   local ar,br={},{}; for _,r in pairs(a.ledger) do ar[#ar+1]=C.copy(r) end; for _,r in pairs(b.ledger) do br[#br+1]=C.copy(r) end
   for _,r in ipairs(ar) do C.merge(b,sb,'ledger',r) end; for _,r in ipairs(br) do C.merge(a,sa,'ledger',r) end
  end
 end
 eq(count(a.ledger),100); eq(count(b.ledger),100); eq(#a.gaps,0); eq(#b.gaps,0)
end)
test('fusion conserve le premier observateur réel plutôt que le premier nom lexical',function()
 local a,sa=C.init(nil,nil,'G'); local b,sb=C.init(nil,nil,'G')
 C.scan(a,sa,'ledger',{row('A')},100900,'Aofficier')
 C.scan(b,sb,'ledger',{row('A')},100000,'Zofficier')
 local incoming; for _,r in pairs(b.ledger) do incoming=r end
 C.merge(a,sa,'ledger',incoming)
 for _,r in pairs(a.ledger) do eq(r.source,'Zofficier'); eq(r.seenAt,100000) end
end)

test('export : CRC32 de référence, base64 RFC 4648 et échappement JSON',function()
 local A=loadAddon(); local E=LiLiBanque.Export
 eq(E.crc32('123456789'),'cbf43926'); eq(E.crc32(''),'00000000')
 eq(E.base64(''),''); eq(E.base64('f'),'Zg=='); eq(E.base64('fo'),'Zm8='); eq(E.base64('foo'),'Zm9v'); eq(E.base64('foobar'),'Zm9vYmFy')
 eq(E.jstring('a"b\\c\n\t\1'),'"a\\"b\\\\c\\n\\t\\u0001"')
 eq(E.jstring('Brenø Aélia à'),'"Brenø Aélia à"')
 eq(E.jstring('x\255y'),'"x\239\191\189y"'); eq(E.jstring('\195'),'"\239\191\189"')
 eq(E.json({bankMoney={},gaps={},ledger={},n=1.5,b=false}),'{"b":false,"bankMoney":[],"gaps":[],"ledger":{},"n":1.5}')
 for _,s in ipairs({'','é','Brenø'..string.rep('\0\255',300)}) do eq(E.crc32(s),PY_CRC32(s)) end
end)
test('export : aller-retour décodé en Python avec accents, ø et caractères spéciaux',function()
 local A=loadAddon(); fire('PLAYER_LOGIN')
 assert(loadfile(ROOT..'/fixtures/LiLiBanque.lua'))()
 local db=LiLiBanqueDB; LiLiBanqueDB=nil
 A=loadAddon(); LiLiBanqueDB=db; fire('PLAYER_LOGIN'); assert(A.db==db)
 db.ledger['L:x:1:1']={id='L:x:1:1',kind='deposit',name='Ça "va" \\ Øyvind\tø 🐼',copper=1,ts=1,tsPrecision=3600,source='Elvor Valbrume',seenAt=2}
 db.roster.members['Zoé\255']={fullName='Zoé\255',level=40,classFile='MAGE',note='ligne1\nligne2',online=true}
 local out=LiLiBanque.Export.build(db)
 eq(out:sub(1,7),'!LILI1!'); assert(out:find('^!LILI1![A-Za-z0-9+/]+=*![0-9a-f]+$')); eq(#out:match('!([0-9a-f]+)$'),8)
 eq(PY_CHECK(out,db),'ok')
 eq(LiLiBanque.Export.build(db),out) -- deterministic
 -- Tampering is detected by the CRC.
 local bad=out:sub(1,20)..(out:sub(21,21)=='A' and 'B' or 'A')..out:sub(22); eq(PY_CHECK(bad,db),'crc32 different')
 -- Empty base: objects stay objects, lists stay lists.
 local empty=LiLiBanque.Core.init(nil,nil,'La Bande à Li Li'); eq(PY_CHECK(LiLiBanque.Export.build(empty),empty),'ok')
 assert(LiLiBanque.Export.json(LiLiBanque.Export.payload(empty)):find('"ledger":{}',1,true))
end)
test('export : 500 lignes et 300 soldes découpés sur plusieurs images, sans gel',function()
 local A=loadAddon(); fire('PLAYER_LOGIN'); fire('GUILD_ROSTER_UPDATE')
 local db=A.db
 for i=1,500 do local id='L:Elvor Valbrume:'..(100000+i)..':'..i; db.ledger[id]={id=id,kind=i%9==0 and 'withdraw' or 'deposit',name='Brenø Nom '..(i%37),copper=40000+i,ts=100000+i*600,tsPrecision=3600,source='Elvor Valbrume',seenAt=100000+i*600} end
 for i=1,300 do db.bankMoney[i]={at=100000+i,copper=i*100} end
 local E=LiLiBanque.Export; local job=E.job(db); local steps,worst=0,0
 local t0=os.clock()
 repeat local s=os.clock(); local done=job:step(); worst=math.max(worst,os.clock()-s); steps=steps+1 until done or steps>5000
 local total=os.clock()-t0
 assert(job.done and not job.error,tostring(job.error)); assert(steps>10,'découpé en '..steps..' étapes')
 assert(worst<0.05,'étape la plus longue '..worst..' s'); assert(total<10,'total '..total..' s')
 eq(PY_CHECK(job.result,db),'ok')
 local decoded=0; for _ in job.json:gmatch('"kind"') do decoded=decoded+1 end; eq(decoded,500)
 local money=job.json:match('"bankMoney":(%b[])'); local n=0; for _ in money:gmatch('"at"') do n=n+1 end; eq(n,30)
 print(string.format('   export 500 lignes : %d octets, %d étapes, pire étape %.1f ms, total %.0f ms',#job.result,steps,worst*1000,total*1000))
end)
test('export depuis la fenêtre : zone de texte remplie, sélectionnée, en lecture seule',function()
 local A=loadAddon(); fire('PLAYER_LOGIN'); GuildBankFrame=MOCK.loadGuildBank(); GuildBankFrame:Show(); fire('GUILDBANKFRAME_OPENED'); fire('GUILDBANKLOG_UPDATE')
 SlashCmdList.LILIBANQUE(''); local UI=LiLiBanque.UI
 eq(UI.exportButton.text,'Exporter'); UI.exportButton:Click()
 local p=UI.exportPanel; assert(p:IsShown()); assert(not UI.sections[1].panel:IsShown()); eq(p.hint.text,'Préparation de l’export…')
 eq(UI.exportButton.text,'Retour'); assert(not UI.scanButton:IsShown())
 local frames=0; while UI.job and frames<1000 do p:fire('OnUpdate',0.016); frames=frames+1 end
 assert(frames>=1); local box=p.box
 assert(box.text:find('^!LILI1!')); eq(PY_CHECK(box.text,A.db),'ok')
 assert(box.focus and box.highlighted,'texte sélectionné et focus'); eq(box.cursor,0)
 eq(p.hint.text,'Ctrl+C, puis collez-le sur le site de la guilde.')
 local text=box.text; box.highlighted=false; box:type('abc'); eq(box.text,text); assert(box.highlighted)
 box:fire('OnEscapePressed'); assert(not LiLiBanqueFrame:IsShown(),'Échap dans la zone ferme la fenêtre')
 assert(not UI.exporting and box.text=='')
 SlashCmdList.LILIBANQUE('export'); assert(LiLiBanqueFrame:IsShown() and UI.exporting)
 UI.exportButton:Click(); assert(not UI.exporting); assert(UI.sections[1].panel:IsShown())
end)
test('trou visible : rouge, son natif, intervalle local, état et diagnostic persistants',function()
 local A=loadAddon(); fire('PLAYER_LOGIN'); fire('GUILDBANKFRAME_OPENED'); fire('GUILDBANKLOG_UPDATE')
 eq(chat('dépôts ont pu être perdus'),nil)
 local before=NOW; NOW=NOW+600; fire('GUILD_ROSTER_UPDATE') -- never the previous bank scan
 GetGuildBankMoneyTransaction=function() return 'deposit','Lunor Brumebleue',60000,0,0,0,0 end
 CHAT={}; NOW=NOW+600; A:scanNow(); fire('GUILDBANKLOG_UPDATE')
 eq(#A.db.gaps,1); eq(count(A.db.gaps[1]),2) -- server contract unchanged
 local alert=assert(chat('dépôts ont pu être perdus'),'rotation annoncée')
 assert(alert:find('|cffff6060',1,true)); assert(alert:find(date('%d/%m %H:%M',before),1,true))
 assert(alert:find(date('%d/%m %H:%M',NOW),1,true)); assert(alert:find('vérifiez sur le site',1,true))
 eq(#SOUNDS,1); eq(SOUNDS[1],856)
 SlashCmdList.LILIBANQUE(''); assert(LiLiBanque.UI.sections[1].panel.values.gaps.text:find('dépôts ont pu être perdus',1,true))
 CHAT={}; A:scanNow(); fire('GUILDBANKLOG_UPDATE'); eq(chat('dépôts ont pu être perdus'),nil); eq(#SOUNDS,1)
 loadAddon(true); fire('PLAYER_LOGIN'); CHAT={}; SlashCmdList.LILIBANQUE('diag')
 assert(chat('Dernier trou : ')); assert(chat(date('%d/%m %H:%M',before)))
end)
test('rappel au login : banque connue seulement, dernier journal et pas roster',function()
 local A=loadAddon(); fire('PLAYER_LOGIN'); fire('GUILD_ROSTER_UPDATE')
 eq(chat('Banque pas relevée'),nil)
 local db=A.db
 db.bankMoney={{at=100000,copper=0}}
 LiLiBanqueState.lastScan={at=100000,ok=true,lines=2,newLines=0}
 db.scannedBy['Elvor Valbrume']=200000 -- not proof of a bank scan
 A=loadAddon(true); fire('PLAYER_LOGIN')
 assert(chat('Banque pas relevée depuis 27 h'),'rappel au login avec banque connue et vieux journal')
 eq(LiLiBanqueState.lastReminderAt,NOW)
 loadAddon(); fire('PLAYER_LOGIN'); eq(chat('Banque pas relevée'),nil)
end)
test('rappel périodique : seuils locaux mercredi/jeudi, autres jours et bornes',function()
 for day=0,6 do
  for _,delta in ipairs({-1,0,1}) do
   local A=loadAddon(); fire('PLAYER_LOGIN')
   date=function(fmt,ts) if fmt=='%w' then return tostring(day) end; return os.date(fmt,ts) end
   local threshold=(day==3 or day==4) and 14400 or 43200
   A.db.bankMoney={{at=NOW-100000,copper=0}}; A.state.bankScanAt=NOW-threshold-delta
   CHAT={}; update(0)
   eq(chat('Banque pas relevée')~=nil,delta==1)
  end
 end
end)
test('rappel sans spam : deux heures, rechargement, combat, instance et préférence par perso',function()
 local A=loadAddon(); fire('PLAYER_LOGIN'); A.db.bankMoney={{at=100,copper=0}}; A.state.bankScanAt=100
 local blocked=true
 InCombatLockdown=function() return blocked end; IsInInstance=function() return false end
 CHAT={}; update(0); eq(#CHAT,0); eq(A.state.lastReminderAt,nil)
 blocked=false; IsInInstance=function() return true end; update(0); eq(#CHAT,0)
 IsInInstance=function() return false end; update(0); eq(#CHAT,1)
 CHAT={}; update(7199); eq(#CHAT,0); update(1); eq(#CHAT,1)
 local at=NOW; loadAddon(true); NOW=at; fire('PLAYER_LOGIN'); eq(chat('Banque pas relevée'),nil)
 A=LiLiBanque.Addon; SlashCmdList.LILIBANQUE('rappel off'); eq(A.state.reminderEnabled,false)
 CHAT={}; update(7200); eq(chat('Banque pas relevée'),nil)
 at=NOW; loadAddon(true); NOW=at; fire('PLAYER_LOGIN'); eq(LiLiBanqueState.reminderEnabled,false)
 CHAT={}; update(7200); eq(chat('Banque pas relevée'),nil)
 SlashCmdList.LILIBANQUE('rappel on'); eq(LiLiBanqueState.reminderEnabled,true)
 CHAT={}; update(0); eq(#CHAT,1); assert(chat('Banque pas relevée'))
end)
test('synchro partage chaque relevé réussi, même sans nouvelle ligne, et borne seenAt',function()
 local A=loadAddon(); fire('PLAYER_LOGIN'); fire('GUILDBANKFRAME_OPENED'); fire('GUILDBANKLOG_UPDATE')
 local W,S=LiLiBanque.Wire,LiLiBanque.Sync; local db,s=LiLiBanque.Core.init(nil,nil,A.guild)
 local peer=S.new(db,s,'Lunor Brumebleue',A.guild,function() return 0 end,function() return NOW end,function() return NOW end)
 local received={}; A.sync.q.send=function(m) received[#received+1]=m; return 0 end
 local function flush()
  while A.sync.q:size()>0 do
   A.sync.q:tick(NOW,false); NOW=NOW+1
   while #received>0 do peer:receive(table.remove(received,1),'OFFICER',A.name) end
  end
 end
 flush(); eq(s.bankScanAt,200000)
 -- A successful unchanged journal must announce the new scan time too.
 local at=NOW+100; NOW=at; A:scanNow(); fire('GUILDBANKLOG_UPDATE'); eq(A.newLines,0)
 flush(); eq(s.bankScanAt,at)
 -- With an older peer, received ledger rows provide a conservative lower bound.
 local empty,se=LiLiBanque.Core.init(nil,nil,A.guild)
 local rx=S.new(empty,se,'Autre Officier',A.guild,function() return 0 end,function() return NOW end,function() return NOW end)
 local r; for _,v in pairs(A.db.ledger) do r=v; break end
 local fragments={}; local tx=S.new(A.db,A.state,A.name,A.guild,function(m) fragments[#fragments+1]=m; return 0 end,function() return NOW end)
 tx:record('ledger','',r)
 while tx.q:size()>0 do tx.q:tick(NOW,false); NOW=NOW+1 end
 for _,m in ipairs(fragments) do rx:receive(m,'OFFICER',A.name) end
 eq(LiLiBanque.Core.bankScanTime(empty,se,NOW),r.seenAt)
end)
test('op B bornée : valeurs hostiles, futur, champs et canal, sans changer le contrat',function()
 local A=loadAddon(); fire('PLAYER_LOGIN'); local W=LiLiBanque.Wire; local serial=0
 local function send(value,opts)
  opts=opts or {}; serial=serial+1
  local f={opts.op or 'B',opts.guild or A.guild,opts.target or '',opts.col or 'bankScan','Lunor Brumebleue',value}
  if opts.extra then f[#f+1]='extra' end
  for _,m in ipairs(W.chunks(W.pack(f),tostring(serial))) do
   NOW=NOW+1; A.sync:receive(m,opts.channel or 'OFFICER','Lunor-Brumebleue')
  end
 end
 for _,v in ipairs({'-1','0','NaN','inf','1e309','200000.5','4102444800',tostring(NOW+86400),string.rep('9',12000),'loadstring("boom")'}) do
  send(v); eq(A.state.bankScanAt,nil)
 end
 for _,opts in ipairs({{extra=true},{channel='GUILD'},{guild='Autre'},{target='Autre'},{op='D'},{col='ledger'}}) do
  send('190000',opts); eq(A.state.bankScanAt,nil)
 end
 A.sync:receive(string.rep('x',100000),'OFFICER','Lunor'); eq(A.state.bankScanAt,nil)
 send(tostring(NOW+300)); local newest=A.state.bankScanAt; assert(newest)
 send('100000'); eq(A.state.bankScanAt,newest)
 eq(count(A.db.ledger),0); eq(count(A.db.events),0); eq(count(A.db),9)
end)
test('la vraie réception 1.1.1 ignore B/bankScan et continue à recevoir le journal',function()
 local A=loadAddon(); fire('PLAYER_LOGIN'); local S=LiLiBanque.Sync
 assert(loadfile(ROOT..'/tests/compat/sync-1.1.1.lua'))(); local oldS=LiLiBanque.Sync; LiLiBanque.Sync=S
 local db,s=LiLiBanque.Core.init(nil,nil,A.guild)
 local old=oldS.new(db,s,'Ancien Officier',A.guild,function() return 0 end,function() return NOW end)
 local out={}; local tx=S.new(A.db,A.state,A.name,A.guild,function(m) out[#out+1]=m; return 0 end,function() return NOW end,function() return NOW end)
 A.state.bankScanAt=NOW; tx:bankScan()
 local r={id='L:Test:1:1',kind='deposit',name='Lunor Brumebleue',copper=40000,ts=NOW,tsPrecision=3600,source=A.name,seenAt=NOW}
 tx:record('ledger','',r)
 while tx.q:size()>0 do tx.q:tick(NOW,false); NOW=NOW+1 end
 for _,m in ipairs(out) do old:receive(m,'OFFICER',A.name) end
 eq(s.bankScanAt,nil); eq(count(db.ledger),1); eq(old.transferred,1)
end)
test('borne reçue garde le seenAt récent même pour une ligne déjà dédupliquée',function()
 local A=loadAddon(); fire('PLAYER_LOGIN'); fire('GUILDBANKFRAME_OPENED'); fire('GUILDBANKLOG_UPDATE')
 local r; for _,v in pairs(A.db.ledger) do r=LiLiBanque.Core.copy(v); break end
 r.seenAt=NOW+100; local W=LiLiBanque.Wire
 for _,msg in ipairs(W.chunks(W.pack({'D',A.guild,'','ledger','Autre Officier',r.id,r.kind,r.name,r.copper,r.ts,r.tsPrecision,r.source,r.seenAt}),'lowerbound')) do
  A.sync:receive(msg,'OFFICER','Autre Officier')
 end
 eq(A.state.bankScanAt,r.seenAt)
end)
test('fenêtre et diag montrent le dernier journal partagé, jamais le roster',function()
 local A=loadAddon(); fire('PLAYER_LOGIN'); fire('GUILD_ROSTER_UPDATE'); SlashCmdList.LILIBANQUE('')
 assert(LiLiBanque.UI.sections[1].panel.values.scan.text:find('aucun',1,true))
 A.state.bankScanAt=NOW-600; A:updateUI()
 assert(LiLiBanque.UI.sections[1].panel.values.scan.text:find('officiers',1,true))
 CHAT={}; SlashCmdList.LILIBANQUE('diag'); assert(chat('Dernier journal connu (officiers) : '))
end)
test('préférence et anti-spam survivent au reset local',function()
 local A=loadAddon(); fire('PLAYER_LOGIN'); SlashCmdList.LILIBANQUE('rappel off')
 A.state.lastReminderAt=NOW
 SlashCmdList.LILIBANQUE('reset'); SlashCmdList.LILIBANQUE('reset CONFIRMER')
 eq(A.state.reminderEnabled,false); eq(A.state.lastReminderAt,NOW)
end)
test('journal refusé ou vide ne rafraîchit pas le dernier succès ; solde seul reste inconnu',function()
 local A=loadAddon(); fire('PLAYER_LOGIN'); fire('GUILDBANKFRAME_OPENED'); fire('GUILDBANKLOG_UPDATE')
 local last=A.state.bankScanAt; NOW=NOW+100
 GetNumGuildBankMoneyTransactions=function() return 0 end
 A:scanNow(); fire('GUILDBANKLOG_UPDATE'); update(4)
 eq(LiLiBanque.Core.bankScanTime(A.db,A.state,NOW),last)
 QueryGuildBankLog=function() error('refusé') end; A:scanNow()
 eq(LiLiBanque.Core.bankScanTime(A.db,A.state,NOW),last)
 A=loadAddon(); fire('PLAYER_LOGIN'); A.db.bankMoney={{at=100,copper=0}}
 CHAT={}; update(0); assert(chat('dernier relevé du journal d’or inconnu'))
 eq(A.state.bankScanAt,nil)
end)
test('rotation après mise à jour : date du dernier succès, pas première observation ni roster',function()
 local A=loadAddon(); fire('PLAYER_LOGIN'); fire('GUILDBANKFRAME_OPENED'); fire('GUILDBANKLOG_UPDATE')
 NOW=NOW+100; A:scanNow(); fire('GUILDBANKLOG_UPDATE')
 local previous=NOW; A.state.localLedgerAt=nil -- state written by 1.1.1
 NOW=NOW+100; fire('GUILD_ROSTER_UPDATE')
 GetGuildBankMoneyTransaction=function() return 'deposit','Lunor Brumebleue',60000,0,0,0,0 end
 A:scanNow(); fire('GUILDBANKLOG_UPDATE'); eq(A.state.lastGap.from,previous)
end)
for _,t in ipairs(tests) do
 local ok,e=pcall(t[2])
 -- No test may leave an unexpected captured Lua error behind (they would be silent in game).
 local A=LiLiBanque and LiLiBanque.Addon
 if ok and A and A.lastError and not t[1]:find('erreur',1,true) then ok,e=false,'erreur capturée inattendue : '..A.lastError.msg end
 if not ok then error('FAIL '..t[1]..': '..tostring(e)) end; passed=passed+1; print('ok - '..t[1]) end
print('PASS '..passed..' tests ('.._VERSION..')')
