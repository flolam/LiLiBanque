-- Standalone from the repository root, or dofile(ROOT..'/tests/p2p-catchup.lua')
-- before the suite's test loop. All traffic runs through the real Lua modules.
local root=ROOT or 'addon'
local test=test or function(name,fn) fn(); print('PASS '..name) end
local function eq(a,b) assert(a==b,tostring(a)..' ~= '..tostring(b)) end
local function count(t) local n=0; for _ in pairs(t) do n=n+1 end; return n end
local function network()
    LiLiBanque={}
    for _,module in ipairs({'Core','Wire','Sync'}) do dofile(root..'/LiLiBanque/'..module..'.lua') end
    local api=LiLiBanque
    local net={now=0,wall=2000000000,peers={},messages={},tx={}}
    local inspect=api.Wire.receiver()
    for i,name in ipairs({'Orin Fictif','Velka Fictive'}) do
        local peer={name=name,core=api.Core,guild='Guilde de test'}; net.peers[i]=peer
        peer.db,peer.state=api.Core.init(nil,nil,peer.guild)
        peer.sync=api.Sync.new(peer.db,peer.state,name,peer.guild,function(msg)
            assert(#msg<255)
            if peer.lastSend then assert(net.now-peer.lastSend>=0.34999,'cadence dépassée') end
            peer.lastSend=net.now
            if peer.sendResult then
                local result=peer.sendResult(msg)
                if result then return result end
            end
            local payload=inspect:push(name,msg,net.now)
            local fields=payload and api.Wire.unpack(payload)
            if fields then net.tx[#net.tx+1]={from=i,at=net.now,fields=fields} end
            if not net.drop or not net.drop(i,msg,fields) then
                net.messages[#net.messages+1]={from=i,msg=msg}
            end
            return 0
        end,function() return net.now end,function() return net.wall end)
    end
    function net:step()
        self.now=self.now+0.36
        for _,p in ipairs(self.peers) do if not p.offline then p.sync:tick(self.now,p.locked) end end
        for _,m in ipairs(self.messages) do
            local p=self.peers[3-m.from]
            if not p.offline then p.sync:receive(m.msg,'OFFICER',self.peers[m.from].name..'-Realm') end
        end
        self.messages={}
    end
    function net:untilAt(seconds,predicate)
        local deadline=self.now+seconds
        while self.now<deadline do
            if predicate and predicate() then return true end
            self:step()
        end
        return predicate and predicate()
    end
    function net:scan(i,rows,at)
        local p=self.peers[i]; return p.core.scan(p.db,p.state,'ledger',rows,at,p.name)
    end
    function net:observations(i)
        local p=self.peers[i]; return p.core.observations(p.db,p.state,'ledger')
    end
    return net,net.peers[1],net.peers[2],api.Wire
end
local function deposit(name,ts,copper)
    return {kind='deposit',name=name,ts=ts,tsPrecision=3600,copper=copper or 40000}
end
local function recentFirst(net,history)
    local newest=deposit(string.rep('É',55)..' Récent',net.wall-8000)
    local twin=deposit('Don identique',net.wall-12500)
    -- The most recent transactions have *older scan* timestamps than the imported history.
    net:scan(1,{newest,twin,twin},net.wall-2000)
    net:scan(2,{twin},net.wall-1900)
    local older={}
    for i=1,history do older[i]=deposit('Historique '..i,net.wall-30000-i*60) end
    net:scan(1,older,net.wall-1000)
    return newest
end

test('catch-up: montant récent avant les pages historiques, puis convergence sans doublon',function()
    local net,a,b,W=network()
    local newest=recentFirst(net,480)
    local peak=0
    assert(net:untilAt(20,function()
        peak=math.max(peak,a.sync.q:size())
        for _,row in pairs(b.db.ledger) do if row.name==newest.name then return true end end
    end),'le don récent doit arriver dans les 20 s malgré 480 lignes historiques')
    assert(count(b.db.ledger)<=3,'des lignes anciennes sont arrivées avant le don le plus récent')
    assert(peak<=40,'un inventaire ne doit pas remplir la file de transport')
    assert(net:untilAt(500,function() return count(b.db.ledger)==483 and count(net:observations(1))==484 end))
    eq(W.digest(net:observations(1)),W.digest(net:observations(2)))
    eq(count(a.db.ledger),483); eq(count(b.db.ledger),483)
    local received=b.sync.transferred
    net:untilAt(250)
    eq(b.sync.transferred,received)
end)

test('catch-up: un fragment D perdu est redemandé avant la fin du parcours historique',function()
    local net,a,b,W=network()
    local newest=recentFirst(net,480)
    local dropped
    net.drop=function(from,msg,fields)
        if not dropped and from==1 and fields and fields[1]=='D' and fields[8]==newest.name then
            assert(tonumber(msg:match('^1|[^|]+|(%d+)|'))>1,'le D visé doit être fragmenté')
            dropped=net.now
            return true
        end
    end
    assert(net:untilAt(25,function()
        for _,row in pairs(b.db.ledger) do if row.name==newest.name then return true end end
    end),'une redemande ciblée doit réparer le D perdu pendant le parcours')
    assert(dropped and count(b.db.ledger)<483)
    assert(net:untilAt(500,function() return count(b.db.ledger)==483 and count(net:observations(1))==484 end))
    eq(W.digest(net:observations(1)),W.digest(net:observations(2)))
    eq(a.sync.transferred,1); eq(b.sync.transferred,483)
end)

test('statut: égalité fraîche du journal uniquement, invalidée par un nouveau relevé',function()
    local net,a,b=network()
    local function status(p) return p.sync:status(net.now).state end
    eq(status(a),'idle')
    b.offline=true; a.sync:hello(); net:untilAt(2)
    eq(status(a),'waiting')
    b.offline=false; b.state.bankScanAt=net.wall-1; b.sync:bankScan()
    -- A marker and an empty transport queue are not a comparison.
    net.drop=function(from,_,fields) return from==2 and (not fields or fields[1]~='B') end
    net:untilAt(3); eq(a.state.bankScanAt,net.wall-1); assert(status(a)~='matched')
    net.drop=nil; b.sync:hello()
    assert(net:untilAt(3,function() return status(a)=='matched' end))
    eq(a.sync:status(net.now).peer,b.name)
    net:scan(1,{deposit('Nouveau don fictif',net.wall-3600)},net.wall)
    eq(status(a),'checking') -- before any tick / hello after local Core.scan
    a.sync:hello()
    assert(net:untilAt(8,function() return status(b)=='catchup' end))
    assert(net:untilAt(10,function() return count(b.db.ledger)==1 end))
    assert(status(b)~='matched','recevoir le dernier D ne remplace pas un H de contrôle')
    a.sync:hello(); b.sync:hello()
    assert(net:untilAt(10,function() return status(a)=='matched' and status(b)=='matched' end))
    b.offline=true; net:untilAt(180)
    eq(status(a),'waiting')
end)

test('transport: un D invalide et durablement refusé ne bloque pas le reste du journal',function()
    local net,a,b=network()
    local rejected=0
    a.sendResult=function(msg)
        if msg:find('Don refuse',1,true) then rejected=rejected+1; return 2 end -- InvalidMessage
    end
    net:scan(1,{deposit('Don refuse',net.wall-3600),deposit('Don suivant',net.wall-7200)},net.wall)
    assert(net:untilAt(25,function() return count(b.db.ledger)==1 end),'le paquet suivant doit passer malgré un InvalidMessage permanent')
    for _,r in pairs(b.db.ledger) do eq(r.name,'Don suivant') end
    assert(rejected>=1 and rejected<=2)
    a.sendResult=nil
    assert(net:untilAt(150,function() return count(b.db.ledger)==2 end),'le prochain inventaire doit reprendre la ligne refusée')
end)

test('statut: pause sur lockdown et limites, blocage sur refus du canal, puis reprise',function()
    local net,a,b=network()
    local function status() return a.sync:status(net.now).state end
    a.locked=true; net:untilAt(2); eq(status(),'paused'); eq(a.lastSend,nil)
    a.locked=false
    local code=11
    a.sendResult=function() return code end
    net:untilAt(2); eq(status(),'paused')
    code=3; net:untilAt(5); eq(status(),'paused')
    code=8; net:untilAt(5); eq(status(),'paused')
    code=10; net:untilAt(6); eq(status(),'blocked') -- NotInGuild
    code=nil
    net:scan(1,{deposit('Don après la pause',net.wall-3600)},net.wall)
    assert(net:untilAt(180,function() return count(b.db.ledger)==1 and status()=='matched' end))
end)

test('catch-up: inventaire perdu et pair absent, reconvergence sur le prochain H',function()
    local net,a,b,W=network()
    local newest=recentFirst(net,90)
    local dropped
    net.drop=function(from,_,fields)
        if not dropped and from==1 and fields and fields[1]=='I' and fields[4]=='ledger' then
            dropped=true
            return true -- last fragment (or the whole page, if it fit)
        end
    end
    assert(net:untilAt(15,function() return dropped end))
    b.offline=true; net:untilAt(160)
    eq(a.sync:status(net.now).state,'waiting')
    b.offline=false
    assert(net:untilAt(175,function() return count(b.db.ledger)==93 and count(net:observations(1))==94 end))
    eq(W.digest(net:observations(1)),W.digest(net:observations(2)))
    assert(net:untilAt(10,function() return a.sync:status(net.now).state=='matched' end))
    local hasNewest=false
    for _,r in pairs(b.db.ledger) do if r.name==newest.name then hasNewest=true end end
    assert(hasNewest)
end)
