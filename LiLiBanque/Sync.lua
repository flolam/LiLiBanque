local C,W=LiLiBanque.Core,LiLiBanque.Wire
local S={}; LiLiBanque.Sync=S
S.PREFIX='LiLiBanque1'
function S.new(db,state,name,guild,send,clock,wallTime)
    wallTime=wallTime or clock
    local self={db=db,state=state,name=name,guild=guild,q=W.queue(send),rx=W.receiver(),clock=clock,serial=0,peers={},seen={},seenCount=0,transferred=0,nextHello=0}
    function self:packet(op,target,col,values)
        local fields={op,self.guild,target or '',col or '',self.name}
        for _,v in ipairs(values or {}) do fields[#fields+1]=v end
        local payload=W.pack(fields); if #payload>32768 then return end
        self.serial=self.serial+1
        local chunks=W.chunks(payload,tostring(self.serial))
        if self.q:size()+#chunks>2048 then self.q.overflow=true; return end
        for _,m in ipairs(chunks) do self.q:add(m) end
    end
    function self:bankScan(target)
        local at=C.bankScanTime(self.db,self.state,wallTime())
        if at then self:packet('B',target,'bankScan',{at}) end
    end
    function self:hello(target)
        for _,col in ipairs({'ledger','events'}) do local digest=W.digest(C.observations(self.db,self.state,col)); self:packet('H',target,col,{digest}) end
        self:bankScan(target)
        self.nextHello=self.clock()+120
    end
    function self:inventory(col,target)
        local _,ids=W.digest(C.observations(self.db,self.state,col))
        for start=1,#ids,30 do
            local page={}; for i=start,math.min(start+29,#ids) do page[#page+1]=ids[i] end
            self:packet('I',target,col,page)
        end
    end
    function self:record(col,target,r)
        if col=='ledger' then self:packet('D',target,col,{r.id,r.kind,r.name,r.copper,r.ts,r.tsPrecision,r.source,r.seenAt})
        else self:packet('D',target,col,{r.id,r.kind,r.player,r.actor,r.rank or '',r.ts,r.tsPrecision}) end
    end
    function self:receive(msg,channel,sender)
        if channel~='OFFICER' or type(sender)~='string' or #sender>150 or sender==self.name then return end
        local now=self.clock(); local peer=self.peers[sender]
        if not peer then
            local n=0; for k,p in pairs(self.peers) do if now-p.at>600 then self.peers[k]=nil else n=n+1 end end
            if n>=64 then return end
            peer={at=now,window=now,received=0,hello={}}; self.peers[sender]=peer
        end
        if now-peer.window>=1 then peer.window=now; peer.received=0 end
        peer.received=peer.received+1; peer.at=now
        if peer.received>20 then return end
        local payload=self.rx:push(sender,msg,now); if not payload then return end
        local f=W.unpack(payload); if not f or #f<5 or f[2]~=self.guild or f[3]~='' and f[3]~=self.name then return end
        -- Application identity is explicit: transport sender may append a hidden realm or
        -- hyphenate a Forever surname. Do not guess/split or rewrite the character's name.
        local peerName=f[5]; if #peerName<1 or #peerName>150 or peerName==self.name then return end
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
            local digest=W.digest(C.observations(self.db,self.state,col))
            if f[5]~=digest and (not peer.hello[col] or now-peer.hello[col]>=30) then
                peer.hello[col]=now; self:inventory(col,peerName)
                self:packet('H',peerName,col,{digest})
            end
        elseif op=='I' then
            local missing={}
            for i=5,math.min(#f,34) do
                local id=f[i]
                if not C.observations(self.db,self.state,col)[id] then missing[#missing+1]=id end
            end
            if #missing>0 then self:packet('R',peerName,col,missing) end
        elseif op=='R' then
            local observations=C.observations(self.db,self.state,col)
            for i=5,math.min(#f,34) do local r=observations[f[i]]; if r then self:record(col,peerName,r) end end
        elseif op=='D' then
            local r
            if col=='ledger' then r={id=f[5],kind=f[6],name=f[7],copper=tonumber(f[8]),ts=tonumber(f[9]),tsPrecision=tonumber(f[10]),source=f[11],seenAt=tonumber(f[12])}
            else r={id=f[5],kind=f[6],player=f[7],actor=f[8],rank=f[9]~='' and f[9] or nil,ts=tonumber(f[10]),tsPrecision=tonumber(f[11])} end
            local id=C.merge(self.db,self.state,col,r)
            if id then
                self.transferred=self.transferred+1; self.lastSync=now
                if col=='ledger' and C.validScanAt(r.seenAt,wallTime()) then
                    self.state.bankScanAt=math.max(C.bankScanTime(self.db,self.state,wallTime()) or 0,r.seenAt)
                end
            end
        end
    end
    function self:tick(now,locked)
        self.q:tick(now,locked)
        if now>=self.nextHello and self.q:size()==0 then self:hello(); self.q.overflow=nil end
    end
    return self
end
