local C,W=LiLiBanque.Core,LiLiBanque.Wire
local S={}; LiLiBanque.Sync=S
S.PREFIX='LiLiBanque1'
local FIRST_PAGE,HISTORY_PAGE=6,12
local RETRY_DELAY,RETRY_LIMIT=12,60
local PEER_FRESH=150 -- monotonic seconds, slightly longer than the periodic H
local STATUS_RANK={matched=1,checking=2,catchup=3}
-- At most nine wire fragments per stock batch; leave room for journal traffic.
local STOCK_TABS,STOCK_SLOTS,STOCK_BATCH=8,98,1800
local STOCK_INTERVAL,STOCK_TIMEOUT=5,90
local function integer(x,lo,hi)
    return type(x)=='number' and x>=lo and x<=hi and x==math.floor(x)
end
local function decimal(s,lo,hi)
    if s and #s<=10 and (s=='0' or s:match('^[1-9]%d*$')) then
        local n=tonumber(s); if integer(n,lo,hi) then return n end
    end
end
local function stockText(s)
    if type(s)~='string' or #s>120 or not s:find('%S') or s:find('[%c|]') then return false end
    -- Validate UTF-8 before letting remote strings reach WoW widgets or the export.
    local i=1
    while i<=#s do
        local a,b=s:byte(i,i+1)
        local n=a<128 and 1 or a>=194 and a<=223 and 2 or a>=224 and a<=239 and 3 or a>=240 and a<=244 and 4
        if not n or i+n-1>#s then return false end
        if n>1 and (a==194 and b<160 or a==224 and b<160 or a==237 and b>=160
            or a==240 and b<144 or a==244 and b>=144) then return false end
        for k=i+1,i+n-1 do local c=s:byte(k); if c<128 or c>191 then return false end end
        i=i+n
    end
    return true
end
local function stockItem(s)
    if type(s)~='string' or #s>512 then return false end
    local id,rest=s:match('^item:([1-9]%d*)(.*)$')
    if not decimal(id,1,2147483647) or rest~='' and not rest:match('^:[%d:%-]*$') then return false end
    local field=0
    for v in rest:gmatch(':([^:]*)') do
        field=field+1
        local hi=field==6 and 2147483647 or 4294967295 -- random suffix is signed
        if v~='' and (#v>11 or not v:match('^%-?%d+$') or not integer(tonumber(v),-2147483647,hi)) then return false end
    end
    return true
end
local function stockHeader(s,wall)
    return type(s)=='table' and C.validScanAt(s.scannedAt,wall) and stockText(s.name)
        and stockText(s.scannedBy) and integer(s.icon,1,2147483647) and type(s.slots)=='table'
end
local function allow(policy,key,tab,snapshot)
    local fn=policy[key]; if type(fn)~='function' then return false end
    local ok,allowed=pcall(function() return fn(tab,snapshot)==true end)
    return ok and allowed
end
-- SH advertises tab/time; SR requests it. SS declares a generation and the
-- exact number of occupied slots (zero = confirmed empty); SD carries ordered
-- batches referring to that generation. No partial generation reaches db.stock.
local function stockTransport(self,wallTime,policy,stockId)
    policy=type(policy)=='table' and policy or {}
    local announce,want,serve,receiving,recent={},{},{},{},{}
    local out,nextAt,lastTab=nil,0,0
    local function current(tab)
        return type(self.db.stock)=='table' and self.db.stock[tab] or nil
    end
    local function newer(tab,at)
        local s=current(tab)
        return type(s)~='table' or type(s.scannedAt)~='number' or at>s.scannedAt
    end
    -- OFFICER broadcasts physically. A true result authorizes *every* channel
    -- recipient, not just the requesting officer. Recheck before every fragment.
    local function share(tab,s)
        return stockHeader(s,wallTime()) and allow(policy,'canShare',tab,s)
    end
    function self:stockUpdated(tab)
        if type(policy.canShare)=='function' and integer(tab,1,STOCK_TABS) then announce[tab]=true end
    end
    local function advertised()
        for tab=1,STOCK_TABS do self:stockUpdated(tab) end
    end
    local function prune(now)
        local n=0
        for sender,p in pairs(receiving) do
            if now-p.progress>STOCK_TIMEOUT or not newer(p.tab,p.s.scannedAt) then receiving[sender]=nil
            else n=n+1 end
        end
        return n
    end
    local function apply(sender,tab,s)
        if not newer(tab,s.scannedAt) or not allow(policy,'canRead',tab,s) then return end
        if type(self.db.stock)~='table' then self.db.stock={} end
        self.db.stock[tab]=s
        if type(policy.onReceived)=='function' then pcall(policy.onReceived,tab,s,sender) end
    end
    local function receive(op,f,sender,peerName,now,bytes)
        if bytes>STOCK_BATCH then return end
        local tab,at=decimal(f[5],1,STOCK_TABS),decimal(f[6],1,4102444800)
        if not tab or not at or not C.validScanAt(at,wallTime()) then return end
        if op=='SH' and #f==6 and f[3]=='' and type(policy.canRead)=='function' and newer(tab,at) then
            if not want[tab] or at>=want[tab].at then want[tab]={at=at,peerName=peerName} end
        elseif op=='SR' and #f==6 and f[3]==self.name then
            local s=current(tab)
            if share(tab,s) and at<=s.scannedAt and not (out and out.tab==tab and out.s.scannedAt>=at)
                and not (recent[tab] and recent[tab].at==s.scannedAt and now-recent[tab].when<15) then
                serve[tab]=true
            end
        elseif type(policy.canRead)=='function' and f[3]=='' and newer(tab,at) then
            local token=f[7]
            if not token or #token>32 or not token:match('^[%w_-]+$') then return end
            if op=='SS' and #f==11 then
                local s={scannedAt=at,name=f[8],icon=decimal(f[9],1,2147483647),scannedBy=f[10],slots={}}
                local total=decimal(f[11],0,STOCK_SLOTS)
                if total==nil or not stockHeader(s,wallTime()) or not allow(policy,'canRead',tab,s) then return end
                local count=prune(now)
                local old=receiving[sender]
                if old and old.tab==tab and (at<old.s.scannedAt or at==old.s.scannedAt and token==old.token) then return end
                if total==0 then receiving[sender]=nil; apply(sender,tab,s); return end
                if old or count<STOCK_TABS then
                    receiving[sender]={s=s,tab=tab,token=token,peerName=peerName,total=total,got=0,lastSlot=0,progress=now}
                end
            elseif op=='SD' and #f>=9 then
                local p=receiving[sender]
                if not p or p.tab~=tab or p.s.scannedAt~=at or p.token~=token or p.peerName~=peerName
                    or now-p.progress>STOCK_TIMEOUT then return end
                if not allow(policy,'canRead',tab,p.s) then receiving[sender]=nil; return end
                local start=decimal(f[8],1,STOCK_SLOTS)
                if start~=p.got+1 then return end -- duplicate, stale or missing batch
                if p.got+#f-8>p.total then receiving[sender]=nil; return end
                for i=9,#f do
                    local slot,packed,n,q,name=f[i]:match('^(%d+)|([%d.item%-]+)|(%d+)|(%d+)|([^|]+)$')
                    slot,n,q=decimal(slot,1,STOCK_SLOTS),decimal(n,1,1000),decimal(q,0,8)
                    local item=packed and packed:gsub('%.',':')
                    if not slot or slot<=p.lastSlot or not n or not q or not stockItem(item) or not stockText(name) then
                        receiving[sender]=nil; return
                    end
                    p.s.slots[slot]={item=item,count=n,quality=q,name=name}; p.lastSlot=slot
                end
                p.got=p.got+#f-8; p.progress=now
                if p.got==p.total then receiving[sender]=nil; apply(sender,tab,p.s) end
            end
        end
    end
    local function publishable(tab,s)
        if not share(tab,s) then return end
        local ids,rows={},{}
        for slot,row in pairs(s.slots) do
            if not integer(slot,1,STOCK_SLOTS) or type(row)~='table' or not stockItem(row.item)
                or not integer(row.count,1,1000) or not integer(row.quality,0,8) or not stockText(row.name) then return end
            ids[#ids+1]=slot
        end
        table.sort(ids)
        for i,slot in ipairs(ids) do
            local row=s.slots[slot]; rows[i]=table.concat({slot,row.item:gsub(':','.'),row.count,row.quality,row.name},'|')
        end
        return rows
    end
    local function sendStock(op,target,values,guard)
        return self:packet(op,target,'stock',values,guard,STOCK_BATCH)
    end
    local function work(now)
        if now<nextAt then return end
        local function sent(ok)
            if ok then nextAt=now+STOCK_INTERVAL; return true end
        end
        -- Bounded control state: at most one pending advertisement/request/job per tab.
        for tab=1,STOCK_TABS do
            local w=want[tab]
            if w then
                if not newer(tab,w.at) or not C.validScanAt(w.at,wallTime()) then want[tab]=nil
                -- SH has no name to compare. Keep the offer while native access
                -- is unknown or denied; SS/SD and apply check the actual name.
                elseif allow(policy,'canRead',tab) and sent(sendStock('SR',w.peerName,{tab,w.at},function()
                    if not newer(tab,w.at) then return false end
                    if allow(policy,'canRead',tab) then return true end
                    -- Access can change between enqueue and the actual send.
                    if not want[tab] or w.at>want[tab].at then want[tab]=w end
                    return false
                end)) then want[tab]=nil; return true end
            end
        end
        if not out then
            for i=1,STOCK_TABS do
                local tab=(lastTab+i-1)%STOCK_TABS+1
                if serve[tab] then
                    local s=current(tab); serve[tab]=nil
                    local rows=publishable(tab,s)
                    if rows then
                        out={tab=tab,s=s,rows=rows,at=s.scannedAt,index=0,token=stockId(self.serial+1)}
                        lastTab=tab; break
                    end
                end
            end
        end
        if out then
            local p=out; local tab,s=p.tab,p.s
            local function guard()
                if share(tab,s) then return true end
                if out==p then out=nil end
                return false
            end
            if guard() then
                if p.index==0 then
                    if sent(sendStock('SS','',{tab,p.at,p.token,s.name,s.icon,s.scannedBy,#p.rows},guard)) then
                        recent[tab]={at=p.at,when=now}
                        p.index=1; if #p.rows==0 then out=nil end
                        return true
                    end
                else
                    local values={tab,p.at,p.token,p.index}
                    local bytes=#W.pack({'SD',self.guild,'','stock',self.name,tab,p.at,p.token,p.index})
                    local i=p.index
                    while i<=#p.rows and #values<24 do
                        local row=p.rows[i]; bytes=bytes+1+#W.pack({row})
                        if bytes>STOCK_BATCH then break end
                        values[#values+1]=row; i=i+1
                    end
                    if i==p.index then out=nil -- cannot fit even one slot; never apply a partial snapshot
                    elseif sent(sendStock('SD','',values,guard)) then
                        p.index=i; if i>#p.rows then out=nil end
                        return true
                    end
                end
            end
        end
        for tab=1,STOCK_TABS do
            if announce[tab] then
                announce[tab]=nil; local s=current(tab)
                if share(tab,s) and sent(sendStock('SH','',{tab,s.scannedAt},function()
                    return current(tab)==s and share(tab,s)
                end)) then return true end
            end
        end
    end
    return advertised,receive,work
end
function S.new(db,state,name,guild,send,clock,wallTime,stockPolicy)
    wallTime=wallTime or clock
    local self={db=db,state=state,name=name,guild=guild,q=W.queue(send),rx=W.receiver(),clock=clock,serial=0,peers={},seen={},seenCount=0,transferred=0,nextHello=0,turn=0}
    local epoch=string.format('%x',math.floor(clock()*1000)%2147483647)
    local function stockId(serial) return 's'..epoch..'-'..serial end
    function self:packet(op,target,col,values,guard,maxBytes)
        local fields={op,self.guild,target or '',col or '',self.name}
        for _,v in ipairs(values or {}) do fields[#fields+1]=v end
        local payload=W.pack(fields); if #payload>(maxBytes or 32768) then return end
        self.serial=self.serial+1
        local chunks=W.chunks(payload,col=='stock' and stockId(self.serial) or tostring(self.serial))
        -- Only broadcast scan markers share the priority slot; never coalesce distinct targets.
        return self.q:addPacket(chunks,op=='B' and col=='bankScan' and fields[3]=='' and #payload<=512,guard)
    end
    local stockHello,stockReceive,stockWork=stockTransport(self,wallTime,stockPolicy,stockId)
    function self:bankScan(target)
        local at=C.bankScanTime(self.db,self.state,wallTime())
        if at then self:packet('B',target,'bankScan',{at}) end
    end
    function self:hello(target)
        for _,col in ipairs({'ledger','events'}) do local digest=W.digest(C.observations(self.db,self.state,col)); self:packet('H',target,col,{digest}) end
        self:bankScan(target)
        stockHello()
        self.nextHello=self.clock()+120
    end
    function self:status(now)
        now=now or self.clock()
        if self.locked or self.q.blocked then return {state='paused'} end
        if self.q.fault then return {state='blocked'} end
        local state,chosen,rank=self.nextHello==0 and 'idle' or 'waiting',nil,0
        for _,peer in pairs(self.peers) do
            if peer.ledgerAt and now-peer.ledgerAt<=PEER_FRESH then
                local compared=peer.ledgerCompared
                local nextState='checking'
                if compared and now-compared.at<=PEER_FRESH then
                    if compared.equal then
                        -- Core.scan increments seq even when new original evidence
                        -- is deduplicated into an existing canonical occurrence.
                        if compared.seq==self.state.seq and compared.rx==self.ledgerRx then nextState='matched' end
                    elseif peer.jobs.ledger or peer.requests.ledger and peer.requests.ledger.count>0
                        or peer.ledgerWorkAt and now-peer.ledgerWorkAt<=RETRY_DELAY then nextState='catchup' end
                end
                local nextRank=STATUS_RANK[nextState]
                if nextRank>rank or nextRank==rank and (peer.ledgerAt>chosen.ledgerAt
                    or peer.ledgerAt==chosen.ledgerAt and peer.name<chosen.name) then
                    state,chosen,rank=nextState,peer,nextRank
                end
            end
        end
        return {state=state,peer=chosen and chosen.name}
    end
    function self:inventoryPage()
        local job,owner
        for _,peer in pairs(self.peers) do
            for _,candidate in pairs(peer.jobs) do
                if not job or candidate.turn<job.turn then job,owner=candidate,peer end
            end
        end
        if not job then return end
        if not job.ids then
            local observations=C.observations(self.db,self.state,job.col)
            local ids={}
            for id in pairs(observations) do
                if type(id)=='string' and #id>0 and #id<=200 then ids[#ids+1]=id end
            end
            table.sort(ids,function(a,b)
                local x,y=observations[a].ts,observations[b].ts
                if type(x)~='number' or x~=x then x=0 end
                if type(y)~='number' or y~=y then y=0 end
                if x==y then return a<b end
                return x>y
            end)
            job.ids=ids
        end
        local page={}
        local pageSize=job.start==1 and FIRST_PAGE or HISTORY_PAGE
        local last=math.min(job.start+pageSize-1,#job.ids)
        for i=job.start,last do page[#page+1]=job.ids[i] end
        if #page==0 or self:packet('I',job.target,job.col,page) then
            job.start=last+1
            if job.start>#job.ids then owner.jobs[job.col]=nil
            else self.turn=self.turn+1; job.turn=self.turn end
        end
    end
    function self:record(col,target,r)
        if col=='ledger' then self:packet('D',target,col,{r.id,r.kind,r.name,r.copper,r.ts,r.tsPrecision,r.source,r.seenAt})
        else self:packet('D',target,col,{r.id,r.kind,r.player,r.actor,r.rank or '',r.ts,r.tsPrecision}) end
    end
    local function clearRetry(pending,id)
        if id and pending.ids[id] then pending.ids[id]=nil; pending.count=pending.count-1 end
    end
    function self:retryRequests(now)
        for _,peer in pairs(self.peers) do
            for col,pending in pairs(peer.requests) do
                local observations=C.observations(self.db,self.state,col)
                local retry={}
                for id,at in pairs(pending.ids) do
                    if observations[id] then clearRetry(pending,id)
                    elseif now>=at and #retry<FIRST_PAGE then retry[#retry+1]=id end
                end
                if #retry>0 and self:packet('R',peer.name,col,retry) then
                    -- One targeted retry per advertisement; later H/I rounds
                    -- reconcile anything still missing, including a lost I page.
                    for _,id in ipairs(retry) do clearRetry(pending,id) end
                    return true
                end
            end
        end
    end
    local function ledgerWork(peer,now)
        peer.ledgerAt=now; peer.ledgerWorkAt=now
        -- A request for an ID we have, or inventory with an ID we lack,
        -- invalidates an earlier equality comparison.
        if peer.ledgerCompared then peer.ledgerCompared.equal=false end
    end
    function self:receive(msg,channel,sender)
        if channel~='OFFICER' or type(sender)~='string' or #sender>150 or sender==self.name then return end
        local now=self.clock(); local peer=self.peers[sender]
        if not peer then
            local n=0; for k,p in pairs(self.peers) do if now-p.at>600 then self.peers[k]=nil else n=n+1 end end
            if n>=64 then return end
            peer={at=now,window=now,received=0,hello={},jobs={},requests={}}; self.peers[sender]=peer
        end
        if now-peer.window>=1 then peer.window=now; peer.received=0 end
        peer.received=peer.received+1; peer.at=now
        if peer.received>20 then return end
        local payload=self.rx:push(sender,msg,now); if not payload then return end
        local f=W.unpack(payload); if not f or #f<5 or f[2]~=self.guild or f[3]~='' and f[3]~=self.name then return end
        -- Application identity is explicit: transport sender may append a hidden realm or
        -- hyphenate a Forever surname. Do not guess/split or rewrite the character's name.
        local peerName=f[5]; if #peerName<1 or #peerName>150 or peerName==self.name then return end
        if f[4]=='stock' then
            table.remove(f,5)
            stockReceive(f[1],f,sender,peerName,now,#payload)
            return
        end
        if peer.name~=peerName then
            peer.name=peerName; peer.hello={}; peer.jobs={}; peer.requests={}
            peer.ledgerAt=nil; peer.ledgerCompared=nil; peer.ledgerWorkAt=nil; peer.echo=nil
        end
        -- Officers seen this session (display only): bounded like peers.
        if self.seen[peerName] or self.seenCount<64 then
            if not self.seen[peerName] then self.seenCount=self.seenCount+1 end
            self.seen[peerName]=now
        end
        table.remove(f,5) -- remaining fields have the stable v1 operation layout below
        local op,col=f[1],f[4]
        -- 1.1.x rejects this new column before interpreting its unknown operation.
        if op=='B' and col=='bankScan' then
            if #payload>512 or #f~=5 or #f[5]>10 or not f[5]:match('^%d+$') then return end
            local at=tonumber(f[5]); local wall=wallTime()
            if not C.validScanAt(at,wall) then return end
            local previous=C.bankScanTime(self.db,self.state,wall) or 0
            if at>previous then self.state.bankScanAt=at end
            return
        end
        if col~='ledger' and col~='events' then return end
        if op=='H' then
            if #f~=5 or #f[5]>24 or not f[5]:match('^%d+:[0-9a-f]+$') then return end
            local digest=W.digest(C.observations(self.db,self.state,col))
            if col=='ledger' then
                peer.ledgerAt=now
                peer.ledgerCompared={at=now,equal=f[5]==digest,seq=self.state.seq,rx=self.ledgerRx}
            end
            if f[5]==digest then
                peer.jobs[col]=nil; peer.requests[col]=nil
                -- Echo a new matching ledger digest once so a peer that just
                -- finished receiving need not wait for the next periodic H.
                if col=='ledger' and peer.echo~=digest and self:packet('H',peerName,col,{digest}) then peer.echo=digest end
            elseif not peer.jobs[col] and (not peer.hello[col] or now-peer.hello[col]>=30) then
                peer.hello[col]=now; self.turn=self.turn+1
                peer.jobs[col]={col=col,target=peerName,turn=self.turn,start=1}
                self:packet('H',peerName,col,{digest})
            end
        elseif op=='I' then
            local missing={}
            local observations=C.observations(self.db,self.state,col)
            for i=5,math.min(#f,34) do
                local id=f[i]
                if #id>0 and #id<=200 and not observations[id] then missing[#missing+1]=id end
            end
            if #missing>0 and self:packet('R',peerName,col,missing) then
                if col=='ledger' then ledgerWork(peer,now) end
                local pending=peer.requests[col] or {ids={},count=0}
                peer.requests[col]=pending
                for _,id in ipairs(missing) do
                    if pending.count<RETRY_LIMIT and not pending.ids[id] then
                        pending.ids[id]=now+RETRY_DELAY; pending.count=pending.count+1
                    end
                end
            end
        elseif op=='R' then
            local observations=C.observations(self.db,self.state,col)
            for i=5,math.min(#f,34) do
                local r=observations[f[i]]
                if r then
                    self:record(col,peerName,r)
                    if col=='ledger' then ledgerWork(peer,now) end
                end
            end
        elseif op=='D' then
            local r
            if col=='ledger' then r={id=f[5],kind=f[6],name=f[7],copper=tonumber(f[8]),ts=tonumber(f[9]),tsPrecision=tonumber(f[10]),source=f[11],seenAt=tonumber(f[12])}
            else r={id=f[5],kind=f[6],player=f[7],actor=f[8],rank=f[9]~='' and f[9] or nil,ts=tonumber(f[10]),tsPrecision=tonumber(f[11])} end
            local known=r.id and C.observations(self.db,self.state,col)[r.id]
            local id=C.merge(self.db,self.state,col,r)
            if id then
                local pending=peer.requests[col]; if pending then clearRetry(pending,r.id) end
                if not known then self.transferred=self.transferred+1; self.lastSync=now end
                if col=='ledger' then
                    peer.ledgerAt=now
                    if not known then
                        self.ledgerRx=(self.ledgerRx or 0)+1; self.confirmAt=now+5; peer.ledgerWorkAt=now
                    end
                end
                if col=='ledger' and C.validScanAt(r.seenAt,wallTime()) then
                    self.state.bankScanAt=math.max(C.bankScanTime(self.db,self.state,wallTime()) or 0,r.seenAt)
                end
            end
        end
    end
    function self:tick(now,locked)
        self.locked=locked
        self.q:tick(now,locked)
        if self.q:size()==0 then
            if now>=self.nextHello and not locked then self:hello(); self.q.overflow=nil; self.confirmAt=nil
            elseif not locked and self.confirmAt and now>=self.confirmAt then
                local digest=W.digest(C.observations(self.db,self.state,'ledger'))
                self:packet('H','','ledger',{digest})
                self.confirmAt=nil
            -- Leave a response window after each packet. R/D traffic can take the
            -- queue before another inventory page; at most one page is queued.
            elseif not locked and now>=self.q.nextAt+0.7 and not self:retryRequests(now) and not stockWork(now) then self:inventoryPage() end
        end
    end
    return self
end
