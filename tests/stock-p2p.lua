-- Standalone on Lua 5.1; ROOT points to addon/. Optional STOCK_LEGACY_ROOT and
-- OFFICER_LEGACY_ROOT point to extracted WowUp v1.3.0 and v1.4.1 archives (containing LiLiBanque/).
local root=ROOT or 'addon'
local function load(path)
    LiLiBanque={}
    for _,module in ipairs({'Core','Wire','Sync'}) do dofile(path..'/LiLiBanque/'..module..'.lua') end
    return LiLiBanque
end
local api=load(root)
local W=api.Wire
local function test(name,fn) fn(); print('PASS stock: '..name) end
local function eq(got,want) assert(got==want,tostring(got)..' ~= '..tostring(want)) end
local function same(a,b)
    if type(a)~='table' or type(b)~='table' then eq(a,b); return end
    for k,v in pairs(a) do same(v,b[k]) end
    for k in pairs(b) do assert(a[k]~=nil,'unexpected key '..tostring(k)) end
end
local function snapshot(at,label,slots)
    return {name=label or 'Coffre des métiers',icon=134400,scannedAt=at,scannedBy='Orin Fictif',slots=slots or {}}
end
local function item(name)
    return {item='item:14113::::::-1182:0:0',name=name or 'Étoffe des métiers',count=12,quality=2}
end
local function network(policies,legacy,count,start)
    local net={now=start or 0,wall=2000000000,peers={},tx={},messages={},serial=0}
    local audit=W.receiver()
    local names={'Orin Fictif','Velka Fictive','Talen Fictif','Neris Fictive'}
    for i=1,count or 3 do
        local name=names[i]
        local peer={name=name,guild='Guilde de test',notes={}}
        local build=legacy and legacy[i] or api
        peer.core=build.Core
        peer.db,peer.state=build.Core.init(nil,nil,peer.guild)
        peer.db.stock={}
        net.peers[i]=peer
        local policy=policies[i]
        if policy then
            policy.onReceived=function(tab,snap,sender)
                peer.notes[#peer.notes+1]={tab,snap,sender,peer.db.stock[tab]}
            end
        end
        peer.sync=build.Sync.new(peer.db,peer.state,name,peer.guild,function(msg)
            assert(#msg<255)
            if not legacy and peer.lastSend then assert(net.now-peer.lastSend>=0.34999,'throttle exceeded') end
            peer.lastSend=net.now
            net.tx[#net.tx+1]={from=i,raw=msg,at=net.now}
            local payload=audit:push(name,msg,net.now)
            if payload then net.tx[#net.tx].fields=assert(W.unpack(payload)) end
            if not net.drop or not net.drop(i,msg,net.tx[#net.tx].fields) then
                net.messages[#net.messages+1]={from=i,msg=msg}
            end
            return 0
        end,function() return net.now end,function() return net.wall end,policy)
    end
    function net:run(seconds,untilTrue)
        local deadline=self.now+seconds
        while self.now<deadline do
            if untilTrue and untilTrue() then return true end
            self.now=self.now+0.36
            for _,p in ipairs(self.peers) do if not p.offline then p.sync:tick(self.now,p.locked) end end
            for _,m in ipairs(self.messages) do
                for i,p in ipairs(self.peers) do
                    -- OFFICER physically broadcasts, regardless of logical target.
                    if i~=m.from and not p.offline then
                        p.sync:receive(m.msg,'OFFICER',self.peers[m.from].name..'-Realm')
                        if self.duplicate then p.sync:receive(m.msg,'OFFICER',self.peers[m.from].name..'-Realm') end
                    end
                end
            end
            self.messages={}
        end
        return untilTrue and untilTrue()
    end
    function net:deliver(peer,fields,channel,sender)
        self.serial=self.serial+1
        for _,msg in ipairs(W.chunks(W.pack(fields),'fake'..self.serial)) do
            peer.sync:receive(msg,channel or 'OFFICER',sender or 'Fausse Fictive-Realm')
        end
    end
    function net:inject(peer,op,target,values,channel,guild)
        local fields={op,guild or peer.guild,target or '','stock','Fausse Fictive'}
        for _,v in ipairs(values) do fields[#fields+1]=v end
        self:deliver(peer,fields,channel)
    end
    return net,net.peers[1],net.peers[2],net.peers[3]
end
local function yes() return true end

test('new Sync clients exchange their own versions by full character name',function()
    local second=load(root)
    second.Core.VERSION='2.0.7'
    local net,a,b,c=network({},{[2]=second})
    c.offline=true
    net:run(5)
    assert(a.sync.officersSeen,'no versioned officer list')
    same(a.sync:officersSeen(),{{name=b.name,version='2.0.7'}})
    same(b.sync:officersSeen(),{{name=a.name,version=a.core.VERSION}})
    local announced={0,0}
    for _,p in ipairs(net.tx) do
        local f=p.fields
        if f and f[4]=='version' then
            eq(f[1],'V'); eq(f[3],''); eq(#f,6)
            announced[p.from]=announced[p.from]+1
        end
    end
    eq(announced[1],1); eq(announced[2],1)
end)

test('version advertisements require canonical ASCII, broadcast OFFICER and a valid peer name',function()
    local net,a=network({})
    local baselineDB,baselineState=a.core.copy(a.db),a.core.copy(a.state)
    local name='Fausse Fictive'
    local function announce(value,channel,target,guild,character,extra,op)
        net:deliver(a,{op or 'V',guild or a.guild,target or '','version',character or name,value,extra},channel)
    end
    for _,value in ipairs({'','v1.2.3','01.2.3','1.02.3','1.2.03','1.2','1.2.3.4','1.2.3-rc.1','1.2.3+metadata',
        '1234567890123.2.3','1.2.٣','1.2.3\n','1.2.3\0','|cffffffff1.2.3|r'}) do announce(value) end
    net.now=1 -- separate rate-limit windows so every malformed case reaches validation
    announce('4.5.6','GUILD'); announce('4.5.6','WHISPER'); announce('4.5.6',nil,a.name)
    announce('4.5.6',nil,nil,'Other guild'); announce('4.5.6',nil,nil,nil,a.name)
    announce('4.5.6',nil,nil,nil,'Fausse |Hitem:1|h'); announce('4.5.6',nil,nil,nil,'Fausse \255')
    announce('4.5.6',nil,nil,nil,name,'extra'); announce('4.5.6',nil,nil,nil,name,nil,'H')
    announce(nil)
    same(a.sync:officersSeen(),{})
    net.now=1; announce('123456789012.2.3') -- exactly 16 bytes
    same(a.sync:officersSeen(),{{name=name,version='123456789012.2.3'}})
    announce('2.0.0|r')
    same(a.sync:officersSeen(),{{name=name,version='123456789012.2.3'}})
    eq(a.sync.q:size(),0); same(a.db,baselineDB); same(a.state,baselineState)
end)

test('journal traffic does not refresh an expired version or borrow it from another sender',function()
    local net,a=network({})
    local name='Fausse Fictive'
    local v={'V',a.guild,'','version',name,'4.5.6'}
    local h={'H',a.guild,'','ledger',name,'0:1505'}
    net:deliver(a,v)
    net.now=900; net:deliver(a,h)
    same(a.sync:officersSeen(),{{name=name,version='4.5.6'}})
    net.now=901
    same(a.sync:officersSeen(),{{name=name}})
    net:deliver(a,v); same(a.sync:officersSeen(),{{name=name,version='4.5.6'}})
    net:deliver(a,h,'OFFICER','Fausse-Fictive-AnotherSender')
    same(a.sync:officersSeen(),{{name=name}})
    eq(a.sync:status().peer,name)
end)

test('late login sees the next periodic version without ping-pong',function()
    local net,a,b,c=network({}); b.offline=true; c.offline=true
    net:run(10); b.offline=false; net:run(15)
    same(b.sync:officersSeen(),{{name=a.name}})
    same(a.sync:officersSeen(),{{name=b.name,version=b.core.VERSION}})
    assert(net:run(125,function() return b.sync:officersSeen()[1].version==a.core.VERSION end))
    local counts,last={0,0},{}
    for _,packet in ipairs(net.tx) do
        local f=packet.fields
        if f and f[4]=='version' then
            local i=packet.from; counts[i]=counts[i]+1
            if last[i] then assert(packet.at-last[i]>=120) end
            last[i]=packet.at
        end
    end
    eq(counts[1],2); eq(counts[2],1)
end)

local function packets(net,from,op)
    local rows={}
    for _,p in ipairs(net.tx) do
        local f=p.fields
        if f and p.from==from and f[4]=='stock' and (not op or f[1]==op) then rows[#rows+1]=p end
    end
    return rows
end

test('local update transfers one exact sparse snapshot and notifies after atomic apply',function()
    local net,a,b,c=network({{canShare=yes},{canRead=yes}})
    net:run(12)
    a.db.stock[1]=snapshot(net.wall,nil,{[3]=item(),[98]=item('Étoffe rare; 100%')})
    assert(a.sync.stockUpdated,'missing Sync:stockUpdated')
    a.sync:stockUpdated(1)
    assert(net:run(30,function() return b.db.stock[1]~=nil end),'snapshot did not arrive')
    same(b.db.stock[1],a.db.stock[1]); eq(c.db.stock[1],nil)
    eq(#b.notes,1); eq(b.notes[1][1],1); eq(b.notes[1][2],b.db.stock[1]); eq(b.notes[1][4],b.db.stock[1])
    eq(b.notes[1][3],a.name..'-Realm'); eq(b.state.bankScanAt,nil)
end)

test('defaults, callback errors, truthy values and peer requests never authorize sending',function()
    local net,a,b,c=network({nil,{canRead=yes},{canShare=function(tab)
        if tab==1 then return false elseif tab==2 then return 'yes' elseif tab==3 then error('realm unavailable') end
    end}})
    a.db.stock[1]=snapshot(net.wall,'Never disclose')
    a.sync:stockUpdated(1)
    for tab=1,4 do
        c.db.stock[tab]=snapshot(net.wall,'Also private'); c.sync:stockUpdated(tab)
        net:inject(c,'SR',c.name,{tab,net.wall})
    end
    net:inject(a,'SR',a.name,{1,net.wall})
    net:inject(a,'SH','',{1,net.wall})
    net:inject(c,'SR',c.name,{1,net.wall,'true'})
    net:run(135)
    eq(#packets(net,1),0); eq(#packets(net,3),0); eq(next(b.db.stock),nil)
end)

test('unknown native rights do not cache; periodic hello after radio pause and reconnect catches up',function()
    local view,name=nil,'Wrong tab name'
    local net,a,b,c=network({{canShare=function(tab) return tab==1 end},{canRead=function(tab,s)
        if view==nil then return nil end
        return tab==1 and view==true and (not s or s.name==name)
    end},{canRead=function() return 'yes' end}})
    a.db.stock[1]=snapshot(net.wall,'Public name',{[98]=item()})
    a.db.stock[2]=snapshot(net.wall,'Secret name',{[9]=item()})
    a.sync:stockUpdated(1); a.sync:stockUpdated(2)
    net:run(35)
    eq(next(b.db.stock),nil); eq(#b.notes,0); eq(next(c.db.stock),nil)
    eq(#packets(net,2,'SR'),0); eq(#packets(net,1,'SS'),0)
    for _,p in ipairs(packets(net,1)) do eq(p.fields[6],'1') end
    view=true; b.offline=true; a.locked=true
    local before=#net.tx; net:run(150)
    eq(next(b.db.stock),nil)
    for i=before+1,#net.tx do assert(net.tx[i].from~=1,'radio pause transmitted') end
    b.offline=false; a.locked=false; name='Public name'
    assert(net:run(155,function() return b.db.stock[1]~=nil end),'next periodic hello failed to reconcile stock')
    same(b.db.stock[1],a.db.stock[1]); eq(#b.notes,1); eq(next(c.db.stock),nil)
end)

test('stale, future, wrong guild/channel, malformed and interrupted batches do not replace; newer empty does',function()
    local net,_,b=network({nil,{canRead=yes}})
    local at=net.wall
    local old=snapshot(at-1,nil,{[17]=item()}); b.db.stock[1]=old
    local function start(stamp,number,name,icon,by,channel,guild,token)
        net:inject(b,'SS','',{1,stamp,token or 'scan-a',name or 'Coffre',icon or 134400,by or 'Orin Fictif',number},channel,guild)
    end
    local function batch(stamp,offset,raw,token)
        net:inject(b,'SD','',{1,stamp,token or 'scan-a',offset,raw})
    end
    local valid='3|item.14113......-1182.0|12|2|Étoffe'
    start(at-2,0); start(at-1,0); start(at+301,0); start(at,0,'Coffre',0)
    start(at,0,'|Hfake'); start(at,0,nil,nil,''); start(at,0,'\255'); start(at,99)
    start(at,0,nil,nil,nil,'GUILD'); start(at,0,nil,nil,nil,'PARTY')
    start(at,0,nil,nil,nil,'OFFICER','Other guild')
    eq(b.db.stock[1],old); eq(#b.notes,0)
    start(at,2); batch(at,1,valid); batch(at,1,valid)
    eq(b.db.stock[1],old); eq(#b.notes,0)
    batch(at,2,valid)
    eq(b.db.stock[1],old)
    for i,raw in ipairs({'99|item.14113|1|2|Étoffe','3|item.0|1|2|Étoffe',
        '3|item.2147483648|1|2|Étoffe','3|item.14113......2147483648|1|2|Étoffe',
        '3|item.14113.--12|1|2|Étoffe','3|item.14113|1001|2|Étoffe',
        '3|item.14113|1|9|Étoffe','3|item.14113|1|2|bad|markup',
        '3|item.14113|1|2|\192\175','3|item.14113|1|2|'..string.rep('x',121)}) do
        if i==4 or i==8 then net:run(1) end -- respect the real 20 fragments/s input guard
        start(at+i,1); batch(at+i,1,raw); eq(b.db.stock[1],old)
    end
    start(at+20,2); batch(at+20,2,valid); net:run(100); batch(at+20,1,valid)
    eq(b.db.stock[1],old); eq(#b.notes,0)
    start(at+20,1,nil,nil,nil,nil,nil,'scan-b'); batch(at+20,1,valid,'scan-a')
    eq(b.db.stock[1],old)
    start(at+21,0); start(at+21,0); start(at+20,0)
    eq(b.db.stock[1].scannedAt,at+21); eq(next(b.db.stock[1].slots),nil)
    eq(#b.notes,1); eq(b.state.bankScanAt,nil); eq(b.sync.transferred,0)
end)

test('a 98-slot worst-size snapshot fits bounded batches and duplicated packets apply once',function()
    local net,a,b=network({{canShare=yes},{canRead=yes}})
    net.duplicate=true
    local slots={}
    for i=1,98 do
        slots[i]={item='item:2147483647'..string.rep(':',497),name=string.rep('é',60),count=1000,quality=5}
    end
    a.db.stock[8]=snapshot(net.wall,string.rep('é',60),slots)
    a.db.stock[8].scannedBy=string.rep('é',60)
    a.db.stock[8].icon=2147483647
    assert(net:run(750,function() return b.db.stock[8]~=nil end),'large tab failed to complete')
    same(b.db.stock[8],a.db.stock[8]); eq(#b.notes,1)
    for _,p in ipairs(packets(net,1)) do assert(#W.pack(p.fields)<=1800 and #p.fields<=128) end
    net:run(150); eq(#b.notes,1)
end)

test('sender revocation during a batch cancels the remaining fragments',function()
    local share=true
    local net,a,b=network({{canShare=function() return share end},{canRead=yes}})
    local slots={}; for i=1,98 do slots[i]=item(string.rep('é',60)) end
    a.db.stock[1]=snapshot(net.wall,nil,slots)
    assert(net:run(35,function()
        local last=net.tx[#net.tx]
        return last and last.from==1 and last.raw:match('^1|[^|]+|1|[2-9]|SD;')
    end))
    share=false
    a.sync:stockUpdated(1)
    net:run(150)
    eq(#packets(net,1,'SD'),0); eq(#packets(net,1,'SH'),1)
    eq(next(b.db.stock),nil); eq(#b.notes,0)
end)

test('a dropped data fragment keeps previous stock until a later periodic retry',function()
    local net,a,b=network({{canShare=yes},{canRead=yes}})
    local slots={}; for i=1,35 do slots[i]=item(string.rep('é',60)) end
    a.db.stock[1]=snapshot(net.wall,nil,slots)
    local old=snapshot(net.wall-1,nil,{[98]=item()}); b.db.stock[1]=old
    local dropped=false
    net.drop=function(i,msg)
        if not dropped and i==1 and msg:match('^1|[^|]+|1|[2-9]|SD;') then dropped=true; return true end
    end
    net:run(85)
    assert(dropped); eq(b.db.stock[1],old); eq(#b.notes,0)
    assert(net:run(130,function() return b.db.stock[1]~=old end),'periodic hello failed to retry partial transfer')
    same(b.db.stock[1],a.db.stock[1]); eq(#b.notes,1)
end)

local function deposit(name,ts)
    return {kind='deposit',name=name,copper=40000,ts=ts,tsPrecision=3600}
end
local function invite(name,ts)
    return {kind='invite',player=name,actor='Orin Fictif',ts=ts,tsPrecision=3600}
end

test('versions arrive during four-officer gold catch-up, before history converges',function()
    local start=10000 -- GetTime need not start at zero when the addon loads
    local net,a,b=network({},nil,4,start)
    local rows={}
    for i=1,500 do rows[i]=deposit('Don fictif '..i,net.wall-7200-i*60) end
    a.core.scan(a.db,a.state,'ledger',rows,net.wall-100,a.name)
    local id
    for key,row in pairs(a.db.ledger) do if row.name==rows[1].name then id=key; break end end
    assert(id,'fixture did not scan the newest deposit')
    local goldAt,versionAt
    local arrived=net:run(20,function()
        if b.db.ledger[id] then goldAt=goldAt or net.now-start end
        for _,seen in ipairs(b.sync:officersSeen()) do
            if seen.name==a.name and seen.version==a.core.VERSION then versionAt=versionAt or net.now-start end
        end
        return goldAt and versionAt
    end)
    assert(goldAt,'newest deposit did not reach the receiving officer')
    same(b.db.ledger[id],a.db.ledger[id])
    assert(W.digest(a.db.ledger)~=W.digest(b.db.ledger),'history unexpectedly converged')
    assert(arrived and versionAt<=20,('no version within 20 s of login despite receiving gold at %.2f s'):format(goldAt))
    print(('  four officers, 500 deposits: newest gold %.2f s, first version %.2f s'):format(goldAt,versionAt))
end)

test('overdue version waits for active fragments, B, lockdown and a transport retry',function()
    local net,a,b,c=network({}); b.offline=true; c.offline=true
    local page={}
    for i=1,12 do page[i]=('%02d'):format(i)..string.rep('x',198) end
    a.sync:packet('I',b.name,'ledger',page)
    a.sync:packet('I',c.name,'ledger',page)
    a.sync:packet('H','','events',{'0:1505'})
    net:run(8.1) -- grace expired during the second fragmented inventory page
    local before=#net.tx
    local id,part,total=net.tx[before].raw:match('^1|([^|]+)|(%d+)|(%d+)|')
    part,total=tonumber(part),tonumber(total)
    assert(part>1 and part<total,'inventory must be in flight')
    a.state.bankScanAt=net.wall-5; a.sync:bankScan()
    a.locked=true; net:run(130); eq(#net.tx,before)
    local send,retryAt=a.sync.q.send
    a.sync.q.send=function(msg)
        if not retryAt and msg:match('|V;') then retryAt=net.now; return 3 end
        return send(msg)
    end
    a.locked=false
    assert(net:run(10,function() return retryAt end),'no version attempt after unlocking')
    eq(a.sync:status().state,'paused')
    for i=part+1,total do
        eq(net.tx[before+i-part].raw:match('^1|[^|]+|%d+|%d+|'),('1|%s|%d|%d|'):format(id,i,total))
    end
    local marker=before+total-part+1
    eq(#net.tx,marker); eq(net.tx[marker].fields[1],'B')
    net:run(20)
    local version=net.tx[marker+1]
    eq(version.fields[1],'V'); assert(version.at>=retryAt+5,'transport backoff bypassed')
    eq(net.tx[marker+2].fields[1],'H')
    for i=marker+2,#net.tx do assert(net.tx[i].fields[1]~='V','version repeated after pause') end
end)

test('gold B and history catch-up proceed during large stock transfer',function()
    local net,a,b=network({{canShare=yes},{canRead=yes}})
    local slots={}; for i=1,98 do slots[i]=item(string.rep('é',60)) end
    a.db.stock[1]=snapshot(net.wall,nil,slots)
    assert(net:run(35,function() return #packets(net,1,'SS')>0 end))
    local rows={}; for i=1,80 do rows[i]=deposit('Fictif '..i,net.wall-7200-i*60) end
    a.core.scan(a.db,a.state,'ledger',rows,net.wall-100,a.name)
    a.sync:hello()
    assert(net:run(12,function() return b.state.bankScanAt==net.wall-100 and next(b.db.ledger)~=nil end))
    eq(next(b.db.stock),nil)
    assert(net:run(200,function() return b.db.stock[1] and W.digest(b.db.ledger)==W.digest(a.db.ledger) end))
    same(b.db.stock[1],a.db.stock[1]); eq(b.state.bankScanAt,net.wall-100)
end)

if STOCK_LEGACY_ROOT then
    test('published v1.3.0 Core/Wire/Sync ignore real stock traffic and exchange H/I/R/D + B',function()
        local old=load(STOCK_LEGACY_ROOT)
        eq(old.Core.VERSION,'1.3.0'); eq(old.Sync.PREFIX,api.Sync.PREFIX)
        local net,a,b,c=network({{canShare=yes},nil,{canRead=yes}},{[2]=old})
        a.db.stock[1]=snapshot(net.wall,nil,{[98]=item()})
        local function evidence(p,index)
            p.core.scan(p.db,p.state,'ledger',{deposit('Don '..index,net.wall-index*5000)},net.wall-index*100,p.name)
            p.core.scan(p.db,p.state,'events',{invite('Recrue '..index,net.wall-index*5000)},net.wall-index*100,p.name)
        end
        evidence(a,1); evidence(b,2)
        assert(net:run(65,function()
            local function converged(col)
                return W.digest(a.db[col])==W.digest(b.db[col]) and W.digest(a.db[col]):match('^2:')
            end
            return c.db.stock[1] and converged('ledger') and converged('events') and b.state.bankScanAt==net.wall-100
        end),'candidate/1.3.0 exchange failed')
        eq(next(b.db.stock),nil); same(c.db.stock[1],a.db.stock[1])
        b.state.bankScanAt=net.wall-50; b.sync:bankScan()
        assert(net:run(15,function() return a.state.bankScanAt==net.wall-50 end),'v1.3.0 B did not reach candidate')
    end)
else
    print('SKIP stock: set STOCK_LEGACY_ROOT for published v1.3.0 qualification')
end

if OFFICER_LEGACY_ROOT then
    test('published v1.4.1 stays visible without a version and exchanges exact gold and stock',function()
        local old=load(OFFICER_LEGACY_ROOT)
        eq(old.Core.VERSION,'1.4.1'); eq(old.Sync.PREFIX,api.Sync.PREFIX)
        local net,a,b,c=network({{canShare=yes,canRead=yes},{canShare=yes,canRead=yes}},{[2]=old})
        c.offline=true
        local tabs={snapshot(net.wall-3,'Stock fictif A',{[7]=item()}),snapshot(net.wall-2,'Stock fictif B',{[98]=item()})}
        local expected={ledger={},events={}}
        for i,p in ipairs({a,b}) do
            p.db.stock[i]=tabs[i]
            p.core.scan(p.db,p.state,'ledger',{deposit('Don fictif '..i,net.wall-i*5000)},net.wall-i*100,p.name)
            p.core.scan(p.db,p.state,'events',{invite('Recrue fictive '..i,net.wall-i*5000)},net.wall-i*100,p.name)
            for col,records in pairs(expected) do
                for id,row in pairs(p.db[col]) do records[id]=p.core.copy(row) end
            end
        end
        net:run(60)
        same(a.sync:officersSeen(),{{name=b.name}})
        local announcements,sentJournal=0,false
        for _,packet in ipairs(net.tx) do
            local f=packet.fields
            if f and packet.from==1 and f[1]=='D' and f[4]=='ledger' then sentJournal=true end
            if f and f[4]=='version' then
                eq(packet.from,1); assert(sentJournal,'version jumped ahead of the gold journal')
                announcements=announcements+1
            end
        end
        eq(announcements,1)
        for _,p in ipairs({a,b}) do
            for col,records in pairs(expected) do same(p.db[col],records) end
            same(p.db.stock,tabs)
            eq(p.state.bankScanAt,net.wall-100)
        end
    end)
else
    print('SKIP stock: set OFFICER_LEGACY_ROOT for published v1.4.1 qualification')
end
