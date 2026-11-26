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

test('versions par personnage : deux lignes au journal, liste complète et fraîche dans /lili diag',function()
    local A,fire,_,panel=openWithScan()
    local W=LiLiBanque.Wire
    local function receive(name,id,version)
        local fields=version and {'V',A.guild,'','version',name,version}
            or {'H',A.guild,'','ledger',name,'0:1505'}
        for _,msg in ipairs(W.chunks(W.pack(fields),id)) do
            fire('CHAT_MSG_ADDON',LiLiBanque.Sync.PREFIX,msg,'OFFICER',name:gsub(' ','-')..'-Realm')
        end
    end
    receive('Andor Poussière','off1','7.2.3')
    NOW=NOW+10
    receive('Brenø Nom','off2')
    receive('Cyra Brume','off3','6.0.1')
    receive(A.name,'off4','9.9.9')
    A:updateUI()
    has(panel.values.peers.text,'Officiers vus'); has(panel.values.peers.text,'+1'); has(panel.values.peers.text,'/lili diag')
    eq(#panel.peerRows,2)
    has(panel.peerRows[1].name.text,'Andor Poussière'); has(panel.peerRows[1].version.text,'7.2.3')
    has(panel.peerRows[2].name.text,'Brenø Nom'); has(panel.peerRows[2].version.text,'version inconnue')
    eq(panel.peerRows[2].name.wrap,false)
    hasnt(MOCK.texts(LiLiBanqueFrame),'Cyra Brume'); hasnt(MOCK.texts(LiLiBanqueFrame),'en ligne')
    local chat={}; DEFAULT_CHAT_FRAME.AddMessage=function(_,line) chat[#chat+1]=line end
    SlashCmdList.LILIBANQUE('diag')
    local diag=table.concat(chat,'\n')
    has(diag,'Andor Poussière : 7.2.3'); has(diag,'Brenø Nom : version inconnue'); has(diag,'Cyra Brume : 6.0.1')
    hasnt(diag,'9.9.9')
    NOW=NOW+891; A:updateUI()
    has(panel.peerRows[1].name.text,'Brenø Nom'); has(panel.peerRows[2].name.text,'Cyra Brume')
    hasnt(table.concat(A:diagLines(),'\n'),'Andor Poussière')
    NOW=NOW+10; A:updateUI()
    has(panel.values.peers.text,'Aucun officier vu ces 15 min'); eq(panel.peerRows[1].name.text,'')
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

-- Sceau de Li Li : sur la vraie banque de guilde, jamais dans /lili. Géométrie relue dans
-- Blizzard_GuildBankUI/Mainline/Blizzard_GuildBankUI.xml (Forever d9c22e32, 1.60.1.71139) :
-- GuildBankFrame 750×428 ; coin TopLeftOuter 32×32 TOPLEFT -2,-18 (x -2–30, y 18–50) ; TopLeftInner
-- 32×32 à +14,-35 de lui (x 12–44, y 53–85) ; TabTitle centré TOP -30 (y 30–48) ; grille Column1
-- TOPLEFT 18,-59. Placement réel : UIPanelWindows.GuildBankFrame = {area='doublewide'} →
-- FramePositionDelegate:UpdateUIPanelPositions TOPLEFT UIParent (LEFT_OFFSET 16, TOP_OFFSET -116)
-- (Blizzard_UIParentPanelManager/Shared/UIPanelLayoutFrame.lua), donc 116 px libres au-dessus.
-- Li Li ne vit que dans une fenêtre de découpe (Frame:SetClipsChildren, SimpleFrameAPIDocumentation)
-- posée SUR le bord haut du cadre : son corps est découpé par ce bord, pas caché par un niveau de cadre.
local GRID={left=18,right=736,top=59,bottom=370}
local function sealCount()
    local seals,peeks=0,0
    for _,o in ipairs(MOCK.all) do if o.liliSeal then seals=seals+1 end; if o.liliPeek then peeks=peeks+1 end end
    return seals,peeks
end
local function sealRect(UI)
    local seal=UI.bankSeal
    local p,rel,rp,x,y=seal:GetPoint(1)
    eq(p,'TOPLEFT'); eq(rel,GuildBankFrame); eq(rp,'TOPLEFT'); eq(#seal.points,1)
    return x,x+seal.width,-y,-y+seal.height
end
-- Fenêtre de découpe en coordonnées du cadre, y vers le HAUT depuis son bord supérieur.
local function viewRect(UI)
    local v=UI.peekViewport
    local p,rel,rp,x,y=v:GetPoint(1)
    eq(#v.points,1); eq(p,'BOTTOMLEFT'); eq(rel,GuildBankFrame); eq(rp,'TOPLEFT')
    return x,x+v.width,y,y+v.height
end
-- Rectangle du sprite dans la fenêtre (y vers le haut depuis le bas de la fenêtre), puis sa partie
-- réellement dessinée = intersection avec la fenêtre (sémantique de SetClipsChildren).
local function spriteRect(UI)
    local v,s=UI.peekViewport,UI.peekBody
    local p,rel,rp,x,y=s:GetPoint(1)
    eq(#s.points,1); eq(p,'BOTTOM'); eq(rel,v); eq(rp,'BOTTOM')
    local l=(v.width-s.width)/2+x
    return l,l+s.width,y,y+s.height
end
local function drawn(UI)
    local v=UI.peekViewport
    if not v:IsVisible() or not v:DoesClipChildren() then return 0,0 end
    local l,r,b,t=spriteRect(UI)
    local w=math.max(0,math.min(r,v.width)-math.max(l,0))
    local h=math.max(0,math.min(t,v.height)-math.max(b,0))
    return w,h
end
local function peekOnUpdate(UI) return UI.peekViewport:GetScript('OnUpdate') end
-- Joue le peek à 60 images/s via le vrai OnUpdate ; renvoie la hauteur dessinée par image.
local DT=1/60
local function run(UI,seconds)
    local frames={}
    for i=1,math.floor(seconds/DT+0.5) do
        MOCK.tick(DT)
        local _,h=drawn(UI)
        local l,r,b,t=spriteRect(UI)
        frames[#frames+1]={t=i*DT,h=h,l=l,r=r,b=b,top=t,on=UI.peekViewport:IsShown()}
    end
    return frames
end
local function spans(frames,pred)
    local out,cur={},nil
    for _,f in ipairs(frames) do
        if pred(f) then cur=cur or {from=f.t}; cur.to=f.t
        elseif cur then out[#out+1]=cur; cur=nil end
    end
    if cur then out[#out+1]=cur end
    return out
end

test('sceau de Li Li : rien dans /lili, ni sceau, ni Li Li, ni texture',function()
    local _,_,UI,panel=openWithScan()
    eq(panel.seal,nil); eq(panel.peek,nil); eq(UI.sections[2].panel.seal,nil)
    for _,t in ipairs(MOCK.textures) do
        local p=t.parent; local inside=false
        while p do if p==LiLiBanqueFrame then inside=true; break end; p=p.parent end
        assert(not (inside and t.texture==UI.NOTE_TEX),'texture de Li Li dans /lili')
    end
    hasnt(MOCK.texts(LiLiBanqueFrame),'biscuit'); hasnt(MOCK.texts(LiLiBanqueFrame),'— Li Li')
    local _,_,_,hx=panel.hint:GetPoint(2); eq(hx,-10)
end)

test('sceau de Li Li : chargé avec la banque (LoD), posé sur le rail natif et dégagé des portraits',function()
    local A,fire=load()
    local UI=LiLiBanque.UI
    eq(UI.bankSeal,nil); eq(UI.peekViewport,nil)
    fire('PLAYER_INTERACTION_MANAGER_FRAME_SHOW',10); eq(UI.bankSeal,nil)
    GuildBankFrame=MOCK.loadGuildBank(); fire('ADDON_LOADED','Blizzard_GuildBankUI'); GuildBankFrame:Show()
    local seal,open=UI.bankSeal,UI.bankOpenButton
    assert(seal and open,'sceau posé au chargement du cadre'); eq(open.text,'/lili')
    eq(seal.kind,'Button'); eq(seal:GetParent(),GuildBankFrame); assert(seal:GetParent()~=UI.bankLine)
    for _,o in ipairs(MOCK.all) do
        local p=o.parent; while p and p~=UI.bankLine do p=p.parent end
        assert(not (p and (o.liliSeal or o.liliPeek or o.texture==UI.NOTE_TEX)),'rien de Li Li dans la barre LiLiBanque')
    end
    for i,side in ipairs({'LEFT','RIGHT'}) do
        local bp,brel,brp,_,by=UI.bankLine:GetPoint(i)
        eq(bp,'TOP'..side); eq(brel,GuildBankFrame); eq(brp,'BOTTOM'..side)
        assert(by<=-34,'la barre doit laisser les onglets natifs dégagés')
    end
    local tp,trel,trp,tx=UI.bankText:GetPoint(2); eq(tp,'RIGHT'); eq(trel,open); eq(trp,'LEFT'); eq(tx,-6)
    local l,r,t,b=sealRect(UI)
    eq(seal.width,20); eq(seal.height,20); eq(l,530); eq(t,31)
    assert(l>30 and b<53 and b<GRID.top,'sur le rail, au-dessus de la première rangée de cases')
    assert(l>375+80 and r<605,'entre le titre d’onglet centré et la recherche'); assert(t>=22,'sous la barre de titre')
    assert(seal:IsShown() and seal:IsVisible())
    assert(seal:GetFrameLevel()>GuildBankFrame:GetFrameLevel(),'cliquable au-dessus des textures du cadre')
    eq(seal.icon.texture,UI.NOTE_TEX); eq(seal.icon.texCoord[1],452/512); eq(seal.icon.texCoord[4],56/512)
    eq(seal:GetAlpha(),0.55); assert(not seal.glow:IsShown()); assert(not UI.peekPlaying())
    seal:fire('OnEnter'); eq(seal:GetAlpha(),1); assert(seal.glow:IsShown()); eq(seal.glow.blend,'ADD')
    eq(MOCK.tooltip.owner,seal); eq(MOCK.tooltip.text,'Sceau de Li Li'); eq(MOCK.tooltip.anchor,'ANCHOR_RIGHT')
    seal:fire('OnLeave'); eq(seal:GetAlpha(),0.55); assert(not MOCK.tooltip.shown)
    -- Ouvrir la banque ne joue rien : fenêtre cachée, aucun OnUpdate, aucun groupe d’animation.
    assert(not UI.peekViewport:IsShown()); eq(peekOnUpdate(UI),nil); eq(#MOCK.animGroups,0)
    eq(A.lastError,nil)
end)

test('peek : vraie fenêtre de découpe posée sur le bord haut du cadre, transparente et sans souris',function()
    local A,fire,UI=openWithScan()
    local v,s=UI.peekViewport,UI.peekSprite
    eq(v.kind,'Frame'); eq(v:GetParent(),GuildBankFrame); assert(v.liliPeek)
    assert(v:DoesClipChildren(),'SetClipsChildren(true) : le corps est découpé par le bord, pas masqué par un niveau')
    eq(v.mouse,false); eq(next(v.scripts),nil) -- ni clic, ni survol, ni infobulle, ni ticker au repos
    local l,r,b,t=viewRect(UI)
    eq(b,0,'le bas de la fenêtre est le bord haut du cadre')
    assert(t-b<=80 and t-b>=60,'hauteur ~76 : '..(t-b)); assert(r-l<=110 and r-l>=90,'largeur ~100 : '..(r-l))
    assert(t-b<116,'tient dans les 116 px libres au-dessus d’un panneau doublewide')
    local sl,sr=sealRect(UI); local sc=(sl+sr)/2
    assert(math.abs((l+r)/2-sc)<=8,'Li Li sort juste au-dessus du sceau qu’on a cliqué')
    -- SetClipsChildren clips child frames. The sprite is a region of that child, not of the viewport.
    local body=UI.peekBody
    assert(body and body:GetParent()==v and body.mouse==false,'sprite porté par un cadre enfant découpé')
    local regions=0
    for _,o in ipairs(MOCK.textures) do if o.parent==v or o.parent==body then regions=regions+1 end end
    eq(regions,1); eq(s.parent,body); eq(s.texture,UI.NOTE_TEX); eq(s.color,nil)
    for i,c in ipairs({6/512,217/512,4/512,228/512}) do eq(s.texCoord[i],c) end
    assert(math.abs(body.width/body.height-434/460)<0.01,'proportions du sprite')
    assert(body.height<=t-b-2,'la tête entière tient dans la fenêtre (pas coupée en haut)')
    assert(not v:IsShown(),'caché au repos'); eq(#MOCK.animGroups,0)
    eq(A.lastError,nil)
end)

test('peek : au clic, oreilles, hésitation, tête et biscuit, petit balancement, puis retrait vif',function()
    local A,fire,UI=openWithScan()
    SlashCmdList.LILIBANQUE('')
    local chat,sounds,scans=0,0,0
    DEFAULT_CHAT_FRAME.AddMessage=function() chat=chat+1 end; PlaySound=function() sounds=sounds+1 end
    local scanNow=A.scanNow; A.scanNow=function(...) scans=scans+1; return scanNow(...) end
    local queries,special,mode,tab=#MOCK.queries,#UISpecialFrames,GuildBankFrame.mode,MOCK.currentTab
    local v,s=UI.peekViewport,UI.peekSprite
    local before=run(UI,0.5); for _,f in ipairs(before) do eq(f.h,0) end -- rien sans clic
    UI.bankSeal:fire('OnEnter'); UI.bankSeal:Click()
    assert(UI.peekPlaying() and v:IsShown()); assert(not MOCK.tooltip.shown); eq(UI.bankSeal:GetAlpha(),0.55)
    local _,h0=drawn(UI); eq(h0,0,'elle part entièrement derrière le bord')
    local frames=run(UI,2.2)
    local H=UI.peekBody.height
    for _,f in ipairs(frames) do
        if f.on then
            assert(f.top<=v.height,'jamais coupée par le haut de la fenêtre : '..f.top)
            assert(f.b<=0,'le bas plat du sprite reste sous le bord : '..f.b)
            assert(f.l>=0 and f.r<=v.width,'reste dans la largeur de la fenêtre')
            eq(s:GetAlpha(),1) -- un vrai mouvement découpé, pas un fondu
        end
    end
    -- Oreilles : un temps d’arrêt avec le haut de la tête seulement (ni yeux ni biscuit).
    local ears=spans(frames,function(f) return f.on and f.h>=0.25*H and f.h<=0.5*H end)
    local earsHold
    for _,sp in ipairs(ears) do if sp.to-sp.from>=0.15 then earsHold=earsHold or sp end end
    assert(earsHold,'pause sur les oreilles')
    -- Pendant cette pause, le corps est vraiment découpé : le sprite descend sous le bord.
    for _,f in ipairs(frames) do if f.t>=earsHold.from and f.t<=earsHold.to then assert(f.b<-0.4*H) end end
    -- Tête, biscuit et pattes au bord : visible au moins 0,4 s, après les oreilles.
    local peek=spans(frames,function(f) return f.on and f.h>=0.9*H end)
    eq(#peek,1,'une seule sortie franche'); peek=peek[1]
    assert(peek.to-peek.from>=0.4,'regard tenu : '..(peek.to-peek.from)); assert(peek.from>earsHold.to)
    local lo,hi,xs=math.huge,-math.huge,{}
    for _,f in ipairs(frames) do if f.t>=peek.from and f.t<=peek.to then lo=math.min(lo,f.b); hi=math.max(hi,f.b); xs[f.l]=true end end
    assert(hi-lo>=1.5,'petit balancement pendant le regard')
    local moved=0; for _ in pairs(xs) do moved=moved+1 end; assert(moved>1,'léger penché vers l’intérieur')
    -- Retrait vif : de la tête entière à rien en moins de 0,3 s.
    local gone
    for _,f in ipairs(frames) do if f.t>peek.to and f.h==0 then gone=gone or f.t end end
    assert(gone and gone-peek.to<=0.3,'retrait rapide')
    -- Fin entre 1,4 et 2 s : tout se range, plus aucun ticker.
    local stop; for _,f in ipairs(frames) do if not f.on then stop=stop or f.t end end
    assert(stop and stop>=1.4 and stop<=2.0,'durée '..tostring(stop))
    assert(not UI.peekPlaying()); assert(not v:IsShown()); eq(peekOnUpdate(UI),nil)
    eq(chat,0); eq(sounds,0); eq(scans,0); eq(#MOCK.queries,queries); eq(#UISpecialFrames,special)
    eq(GuildBankFrame.mode,mode); eq(MOCK.currentTab,tab); assert(not LiLiBanqueFrame:IsShown(),'/lili ne s’ouvre pas')
    eq(#MOCK.animGroups,0); eq(A.lastError,nil)
end)

test('peek : ni relance au milieu, ni au rafraîchissement ; un nouveau clic rejoue depuis le début',function()
    local A,fire,UI=openWithScan()
    UI.bankSeal:Click(); run(UI,0.6)
    local _,h=drawn(UI); local l1,_,b1=spriteRect(UI)
    UI.bankSeal:Click(); A:updateUI(); fire('GUILDBANKLOG_UPDATE'); fire('GUILDBANKBAGSLOTS_CHANGED'); UI.refreshBankLine()
    local l2,_,b2=spriteRect(UI); eq(l1,l2); eq(b1,b2); assert(UI.peekPlaying(),'le second clic ne coupe ni ne relance')
    run(UI,1.6); assert(not UI.peekPlaying()); eq(peekOnUpdate(UI),nil)
    local quiet=run(UI,1); for _,f in ipairs(quiet) do eq(f.h,0) end
    UI.bankSeal:Click(); local _,h0=drawn(UI); eq(h0,0); assert(UI.peekPlaying())
    local again=run(UI,2.2); local max=0; for _,f in ipairs(again) do max=math.max(max,f.h) end
    assert(max>=0.9*UI.peekBody.height,'rejouée en entier'); eq(A.lastError,nil)
end)

test('peek : un clignement pendant le regard, pas d’image fermée au prochain clic',function()
    local _,_,UI=openWithScan()
    local function uv() return table.concat(UI.peekSprite.texCoord,',') end
    local opened=uv()
    UI.bankSeal:Click(); run(UI,0.8); eq(uv(),opened)
    run(UI,0.15); local half=uv(); assert(half~=opened,'paupières à mi-course')
    run(UI,0.06); local closed=uv(); assert(closed~=opened and closed~=half,'yeux fermés')
    run(UI,0.07); eq(uv(),half)
    run(UI,0.08); eq(uv(),opened)
    run(UI,0.6); assert(not UI.peekPlaying())
    UI.bankSeal:Click(); run(UI,1.01); eq(uv(),closed)
    GuildBankFrame.BankTabs[2].Button:Click(); eq(uv(),opened); assert(not UI.peekPlaying())
    UI.bankSeal:Click(); eq(uv(),opened)
end)

test('peek : coupé net par onglet natif, onglet de coffre, fermeture, Échap ; jamais doublé',function()
    local A,fire,UI=openWithScan()
    local seal,v=UI.bankSeal,UI.peekViewport
    local hooks=#(GuildBankFrame.hooks.OnHide or {}); local seals,peeks=sealCount(); eq(seals,1); eq(peeks,1)
    local function cut(why)
        assert(not v:IsShown(),why..' : fenêtre rangée'); eq(peekOnUpdate(UI),nil,why..' : ticker retiré')
        assert(not UI.peekPlaying(),why)
    end
    seal:Click(); run(UI,0.5); GuildBankFrameTab2:Click(); eq(GuildBankFrame.mode,'log'); cut('onglet Journal')
    seal:Click(); assert(not v:IsShown(),'pas sur le journal natif')
    GuildBankFrameTab1:Click(); eq(GuildBankFrame.mode,'bank'); assert(not v:IsShown(),'pas de reprise au retour')
    seal:Click(); run(UI,0.3); GuildBankFrame.BankTabs[2].Button:Click(); cut('onglet de coffre')
    seal:Click(); run(UI,0.8); GuildBankFrame:Hide(); fire('GUILDBANKFRAME_CLOSED'); cut('fermeture / Échap')
    GuildBankFrame:Show(); fire('GUILDBANKFRAME_OPENED'); fire('PLAYER_INTERACTION_MANAGER_FRAME_SHOW',10)
    eq(UI.bankSeal,seal); eq(UI.peekViewport,v); assert(not v:IsShown(),'pas de réouverture automatique')
    local f=run(UI,0.5); for _,x in ipairs(f) do eq(x.h,0) end
    seals,peeks=sealCount(); eq(seals,1); eq(peeks,1); eq(#GuildBankFrame.hooks.OnHide,hooks)
    seal:Click(); local _,h0=drawn(UI); eq(h0,0,'reprend du début')
    for _,n in ipairs(UISpecialFrames) do assert(n~='GuildBankFrame','pas d’interception d’Échap') end
    eq(A.lastError,nil)
end)

test('peek : sans découpe disponible ou sans place au-dessus du cadre, rien ne s’affiche',function()
    local saved=MOCK.Frame.SetClipsChildren; MOCK.Frame.SetClipsChildren=nil
    local ok,err=pcall(function()
        local A,fire,UI=openWithScan()
        UI.bankSeal:Click(); assert(not UI.peekPlaying()); assert(not UI.peekViewport or not UI.peekViewport:IsShown())
        eq(A.lastError,nil)
    end)
    MOCK.Frame.SetClipsChildren=saved; assert(ok,err)
    local A,fire,UI=openWithScan()
    GuildBankFrame.top=UIParent.top-40 -- panneau remonté par ClampUIPanelY : 40 px au-dessus seulement
    UI.bankSeal:Click(); assert(not UI.peekPlaying()); assert(not UI.peekViewport:IsShown()); eq(peekOnUpdate(UI),nil)
    -- Cadre agrandi (checkFit / échelle) : GetTop est en unités du cadre, la place se compare à l’écran.
    GuildBankFrame.scale=1.4; GuildBankFrame.top=(UIParent.top-116)/1.4 -- 116 px écran ≥ 76 × 1,4
    UI.bankSeal:Click(); assert(UI.peekPlaying()); UI.stopPeek(); assert(not UI.peekViewport:IsShown())
    GuildBankFrame.scale=1.6; GuildBankFrame.top=(UIParent.top-116)/1.6 -- 76 × 1,6 > 116 : pas de demi-Li Li hors écran
    UI.bankSeal:Click(); assert(not UI.peekPlaying())
    eq(A.lastError,nil)
end)

test('sceau de Li Li : autre guilde, sortie de guilde ou banque cachée → ni sceau ni peek',function()
    local A,fire=load()
    GetGuildInfo=function() return 'Autre Guilde' end; fire('PLAYER_GUILD_UPDATE')
    GuildBankFrame=MOCK.loadGuildBank(); GuildBankFrame:Show(); fire('GUILDBANKFRAME_OPENED')
    local UI=LiLiBanque.UI
    assert(UI.bankSeal and not UI.bankSeal:IsShown(),'sceau masqué hors de La Bande à Li Li')
    UI.startPeek(); assert(not UI.peekPlaying(),'rien pour une autre guilde')
    GetGuildInfo=function() return 'La Bande à Li Li' end; fire('PLAYER_GUILD_UPDATE')
    assert(UI.bankSeal:IsShown()); UI.bankSeal:Click(); assert(UI.peekPlaying())
    GetGuildInfo=function() return nil end; fire('PLAYER_GUILD_UPDATE')
    assert(not UI.bankSeal:IsShown()); assert(not UI.peekPlaying(),'sortie de guilde : Li Li se cache')
    assert(not UI.peekViewport:IsShown()); eq(peekOnUpdate(UI),nil)
    GetGuildInfo=function() return 'La Bande à Li Li' end; fire('PLAYER_GUILD_UPDATE')
    GuildBankFrame:Hide(); fire('GUILDBANKFRAME_CLOSED')
    UI.startPeek(); assert(not UI.peekPlaying(),'cadre caché : rien')
    eq(A.lastError,nil)
end)

test('Art/LiLiNote.tga : RGBA 512×512, Li Li détourée sans fond ni frange magenta, sceau intact',function()
    local f=assert(io.open(ROOT..'/LiLiBanque/Art/LiLiNote.tga','rb')); local raw=f:read('*a'); f:close()
    eq(#raw,18+512*512*4)
    local b=function(i) return raw:byte(i) end
    eq(b(1),0); eq(b(2),0); eq(b(3),2)
    eq(b(13)+256*b(14),512); eq(b(15)+256*b(16),512); eq(b(17),32); eq(b(18),8)
    local function px(x,y) local i=18+((511-y)*512+x)*4; return raw:byte(i+3),raw:byte(i+2),raw:byte(i+1),raw:byte(i+4) end
    local function alpha(x,y) local _,_,_,a=px(x,y); return a end
    eq(alpha(480,28),255) -- sceau
    -- Gouttière et hors cellule : transparent.
    for _,p in ipairs({{0,0},{447,463},{0,463},{447,0},{3,230},{445,230},{224,0},{449,30},{480,200},{300,500}}) do eq(alpha(p[1],p[2]),0) end
    -- Fond retiré : coins du sprite transparents, visage/robe opaques, base plate pleine largeur.
    eq(alpha(6,4),0); eq(alpha(216,4),0)
    eq(alpha(111,149),255)
    local base=0; for x=6,216 do if alpha(x,219)==255 then base=base+1 end end
    assert(base>=140,'base plate (robe et pattes) : '..base)
    -- Pas de magenta : ni sur la peinture, ni sur ses bords, ni dans les texels transparents filtrés.
    local partial,bad=0,0
    for y=0,463 do for x=0,447 do
        local r,g,bl,a=px(x,y)
        if a>0 and a<255 then partial=partial+1 end
        if math.min(r,bl)-g>24 then bad=bad+1 end
    end end
    eq(bad,0,'magenta résiduel'); assert(partial>=900,'bords doux (fourrure) : '..partial)
    local differences={0,0}
    for y=4,227 do for x=6,216 do
        local r,g,bl,a=px(x,y)
        for i,p in ipairs({{x+224,y},{x,y+232}}) do
            local rr,gg,bb,aa=px(p[1],p[2])
            eq(aa,a,'silhouette identique à chaque pose')
            if r~=rr or g~=gg or bl~=bb then
                assert(x>=89 and x<=167 and y>=106 and y<=143,'retouche limitée aux yeux')
                differences[i]=differences[i]+1
            end
        end
    end end
    assert(differences[1]>0 and differences[2]>differences[1],'les yeux sont réellement retouchés')
end)

for _,t in ipairs(tests) do
    local ok,e=pcall(t[2])
    local A=LiLiBanque and LiLiBanque.Addon
    if ok and A and A.lastError then ok,e=false,'erreur capturée inattendue : '..A.lastError.msg end
    if not ok then error('FAIL ui-redesign '..t[1]..': '..tostring(e)) end
    passed=passed+1; print('ok - ui - '..t[1])
end
print('PASS '..passed..' ui-redesign tests')
