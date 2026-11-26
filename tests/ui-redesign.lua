-- Independent tests for the /lili window redesign (UI.lua). Self-contained: own setup, same
-- strict widget mock as tests/test.lua. Expects ROOT (addon dir) like tests/run.py provides.
local tests,passed={},0
local function test(name,fn) tests[#tests+1]={name,fn} end
local function eq(a,b) assert(a==b,tostring(a)..' ~= '..tostring(b)) end
local function has(s,p) assert(type(s)=='string' and s:find(p,1,true),tostring(s)..' ⊅ '..p) end
local function hasnt(s,p) assert(not (type(s)=='string' and s:find(p,1,true)),tostring(s)..' ⊃ '..p) end
local MOCK=assert(loadfile(ROOT..'/tests/wowmock.lua'))()
local NOW
local function load(rows)
    NOW=200000; LiLiBanqueDB=nil; LiLiBanqueState=nil
    MOCK.install()
    SOUNDKIT={IG_MAINMENU_OPTION_CHECKBOX_ON=856}; PlaySound=function() end
    C_ChatInfo={RegisterAddonMessagePrefix=function() return 0 end,SendAddonMessage=function() return 0 end,InChatMessagingLockdown=function() return false end,AreOutgoingAddonChatMessagesRestricted=function() return false end}
    C_GuildInfo={GuildRoster=function() end,CanViewOfficerNote=function() return true end}
    GetServerTime=function() return NOW end; GetTime=function() return NOW end
    GetGuildInfo=function() return 'La Bande à Li Li' end; IsInGuild=function() return true end
    GetUnitName=function() return 'Elvor Valbrume' end; UnitName=function() return 'Elvor','Nom' end
    DEFAULT_CHAT_FRAME={AddMessage=function() end}; SlashCmdList={}; SLASH_LILIBANQUE1=nil; SLASH_LILIBANQUE2=nil
    QueryGuildBankLog=function() end; MAX_GUILDBANK_TABS=8
    GetNumGuildBankTabs=function() return 1 end; CanWithdrawGuildBankMoney=function() return true end
    rows=rows or {{'deposit','Brenø Nom',40000}}
    GetNumGuildBankMoneyTransactions=function() return #rows end
    GetGuildBankMoneyTransaction=function(i) local r=rows[i]; return r[1],r[2],r[3],0,0,0,#rows-i+1 end
    GetGuildBankMoney=function() return 1234567 end
    QueryGuildEventLog=function() end; GetNumGuildEvents=function() return 0 end; GetGuildEventInfo=function() end
    GetNumGuildMembers=function() return 1 end
    GetGuildRosterInfo=function() return 'Brenø Nom','Membre',2,42,'Paladin','','','',false,0,'PALADIN' end
    IsInInstance=nil; InCombatLockdown=nil; issecretvalue=nil; debugprofilestop=nil
    LiLiBanque={}
    for _,f in ipairs({'Core','Wire','Sync','Export','Addon','UI'}) do assert(loadfile(ROOT..'/LiLiBanque/'..f..'.lua'))() end
    local A=LiLiBanque.Addon
    local function fire(e,...) A.frame:fire('OnEvent',e,...) end
    fire('PLAYER_LOGIN'); fire('GUILD_ROSTER_UPDATE')
    return A,fire
end
local function openWithScan(rows)
    local A,fire=load(rows)
    GuildBankFrame=MOCK.loadGuildBank(); GuildBankFrame:Show(); fire('GUILDBANKFRAME_OPENED'); fire('GUILDBANKLOG_UPDATE')
    SlashCmdList.LILIBANQUE('')
    return A,fire,LiLiBanque.UI,LiLiBanque.UI.sections[1].panel
end

test('première lecture : relevé d’or et preuve entre officiers séparés, sans chiffre technique',function()
    local A,_,UI,panel=openWithScan()
    local all=MOCK.texts(LiLiBanqueFrame)
    has(all,'Dernier relevé d’or'); has(all,'Entre officiers'); has(all,'Derniers mouvements d’or')
    hasnt(all,'%'); hasnt(panel.values.sync.text,'à jour'); hasnt(all,'file '); hasnt(all,'couverture')
    has(panel.values.scan.text,'par vous'); has(panel.values.scan.text,'1 nouvelle ligne')
    has(panel.values.money.text,'123 po 45 pa 67 pc')
    eq(panel.rows[1].name.text,'|cfff48cbaBrenø Nom|r'); eq(panel.rows[1].amount.text,'4 po')
    -- The two first-glance columns don't overlap: left text ends before the divider.
    local _,_,_,lx=panel.values.scan:GetPoint(1); local _,_,_,rx=panel.values.sync:GetPoint(1)
    assert(lx+panel.values.scan:GetWidth()<rx,'colonnes séparées')
end)

test('contrat sync:status : libellés naturels, pair nommé, repli neutre',function()
    local A,_,UI,panel=openWithScan()
    local cases={
        {{state='matched',peer='Magor Barbefer'},'Même journal que','Magor Barbefer'},
        {{state='checking',peer='Magor Barbefer'},'Comparaison avec','Magor Barbefer'},
        {{state='catchup',peer='Magor Barbefer'},'Rattrapage auprès de','Magor Barbefer'},
        {{state='catchup'},'Rattrapage en cours'},
        {{state='waiting'},'En attente d’un autre officier'},
        {{state='idle'},'Rien à comparer'},
        {{state='paused'},'En pause'},
        {{state='blocked'},'/lili diag'},
        {{state='inconnu',peer='X'},'Synchro active'},
        {'pas une table','Synchro active'},
    }
    local asked
    for _,c in ipairs(cases) do
        A.sync.status=function(self,now) asked=now; return c[1] end
        A:updateUI()
        has(panel.values.sync.text,c[2]); if c[3] then has(panel.values.sync.text,c[3]) end
        hasnt(panel.values.sync.text,'à jour'); hasnt(panel.values.sync.text,'%')
    end
    eq(asked,A.clock())
    -- matched is jade; a matched state without peer never names anyone.
    A.sync.status=function() return {state='matched',peer='Magor Barbefer'} end; A:updateUI()
    has(panel.values.sync.text,UI.COLORS.jade)
    A.sync.status=function() return {state='matched'} end; A:updateUI()
    eq(panel.values.sync.text,UI.COLORS.jade..'Même journal qu’un autre officier|r')
    -- Old transport (no function) and a throwing one: neutral, no captured error left.
    A.sync.status=nil; A:updateUI(); eq(panel.values.sync.text,UI.COLORS.ivory..'Synchro active|r')
    A.sync.status=function() error('boom') end; A:updateUI(); eq(panel.values.sync.text,UI.COLORS.ivory..'Synchro active|r')
    eq(A.lastError,nil)
    A.sync=nil; A:updateUI(); has(panel.values.sync.text,'Inactive'); eq(panel.values.peers.text,'')
end)

test('alerte de trou : seulement si un trou existe, la liste descend sans chevauchement',function()
    local A,_,UI,panel=openWithScan()
    assert(not panel.alert:IsShown()); local _,_,_,_,y0=panel.list:GetPoint(1); eq(y0,-112)
    A.db.gaps[1]={at=NOW,reason='rollover'}; A:updateUI()
    assert(panel.alert:IsShown()); local _,_,_,_,y1=panel.list:GetPoint(1); eq(y1,-164)
    has(panel.values.gaps.text,'Trous dans le journal'); eq(#panel.list.points,2)
    A.db.gaps={}; A:updateUI(); assert(not panel.alert:IsShown())
end)

test('les deux ancres hautes laissent les bandes et les textes à leur hauteur fixe',function()
    local _,_,_,panel=openWithScan()
    for _,region in ipairs({panel.values.sync,panel.values.peers,panel.alert,panel.values.gaps,panel.list,panel.rows[1].ago}) do
        local left,_,_,_,leftY=region:GetPoint(1)
        local right,_,_,_,rightY=region:GetPoint(2)
        eq(left,'TOPLEFT'); eq(right,'TOPRIGHT'); eq(leftY,rightY)
    end
    local bottom,_,_,_,bottomY=panel.hint:GetPoint(1)
    local right,_,_,_,rightY=panel.hint:GetPoint(2)
    eq(bottom,'BOTTOMLEFT'); eq(right,'BOTTOMRIGHT'); eq(bottomY,rightY)
end)

test('un refus de transport est identifiable dans /lili diag',function()
    local A=openWithScan()
    A.sync.q.lastError='10'; A.sync.q.fault='10'
    has(table.concat(A:diagLines(),'\n'),'envoi refusé (code 10)')
end)

test('états clairsemés : aucun mouvement, noms longs tronqués, dix lignes au plus',function()
    local A,fire=load({})
    SlashCmdList.LILIBANQUE(''); local panel=LiLiBanque.UI.sections[1].panel
    eq(panel.empty.text,'Aucun mouvement relevé.'); eq(panel.rows[1].name.text,'')
    has(panel.values.scan.text,'ouvrez la banque de guilde')
    local rows={}; for i=1,14 do rows[i]={'deposit',i==1 and 'Anastasiabellerose Tetedepandaroux' or 'Membre'..i..' Nom',10000*i} end
    local A2,_,UI,p2=openWithScan(rows)
    eq(p2.empty.text,''); assert(p2.rows[10].name.text~=''); eq(#p2.rows,10)
    eq(p2.rows[1].name.wrap,false); assert(p2.rows[1].name:GetWidth()<=170)
    has(p2.listHead.text,'10 affichés')
end)

test('un achat d’onglet n’affiche pas deux débits pour une seule dépense',function()
    local _,_,_,panel=openWithScan({{'withdrawForTab','Officier Fictif',1000000},{'buyTab','Officier Fictif',1000000}})
    local amountByKind={}
    for _,r in ipairs(panel.rows) do amountByKind[r.kind.text]=r.amount.text end
    has(amountByKind['retrait (onglet)'],'-100 po'); has(amountByKind['achat d’onglet'],'—')
end)

test('ouvrir ne change rien d’autre : banque, Échap, ligne d’état, déplacement',function()
    local A,fire,UI=openWithScan()
    assert(GuildBankFrame:IsShown(),'la banque reste affichée')
    local found=false; for _,n in ipairs(UISpecialFrames) do if n=='LiLiBanqueFrame' then found=true end end; assert(found)
    has(UI.bankText.text,'journal relevé'); eq(UI.bankLine:GetParent(),GuildBankFrame)
    local f=LiLiBanqueFrame; assert(f.movable and f.clamped); eq(f.drag,'LeftButton')
    SlashCmdList.LILIBANQUE(''); assert(not f:IsShown()); assert(GuildBankFrame:IsShown())
    has(UI.footer.text,'Banque ouverte')
end)

for _,t in ipairs(tests) do
    local ok,e=pcall(t[2])
    local A=LiLiBanque and LiLiBanque.Addon
    if ok and A and A.lastError then ok,e=false,'erreur capturée inattendue : '..A.lastError.msg end
    if not ok then error('FAIL ui-redesign '..t[1]..': '..tostring(e)) end
    passed=passed+1; print('ok - ui - '..t[1])
end
print('PASS '..passed..' ui-redesign tests')
