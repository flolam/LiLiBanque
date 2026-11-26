local W={}; LiLiBanque.Wire=W
function W.pack(fields)
    local out={}
    for i=1,#fields do out[i]=tostring(fields[i]):gsub('[^%w ._-]',function(c) return string.format('%%%02X',string.byte(c)) end) end
    return table.concat(out,';')
end
function W.unpack(payload)
    if type(payload)~='string' or #payload>32768 then return nil end
    local out={}
    for s in (payload..';'):gmatch('(.-);') do
        if #out>=128 then return nil end
        -- Reject malformed escapes rather than interpreting any input as Lua.
        if s:gsub('%%[%x][%x]',''):find('%%') then return nil end
        out[#out+1]=s:gsub('%%(%x%x)',function(h) return string.char(tonumber(h,16)) end)
    end
    return out
end
function W.chunks(payload,id)
    assert(#payload<=32768 and #id<=32 and not id:find('[^%w_-]'),'payload invalide')
    local n=math.max(1,math.ceil(#payload/200)); local out={}
    for i=1,n do out[i]='1|'..id..'|'..i..'|'..n..'|'..payload:sub((i-1)*200+1,i*200) end
    return out
end
function W.receiver()
    local rx={pending={}}
    -- Only stock IDs include a session epoch. Remember recently completed
    -- packets so replayed fragments cannot fill the incomplete-packet quota.
    local done,ring,cursor={},{},0
    function rx:push(sender,msg,now)
        for k,v in pairs(self.pending) do if now-v.lastProgress>120 then self.pending[k]=nil end end
        if type(msg)~='string' or #msg>=255 then return end
        local id,i,n,data=msg:match('^1|([%w_-]+)|(%d+)|(%d+)|(.*)$')
        i,n=tonumber(i),tonumber(n)
        if not id or #id>32 or not i or not n or n>164 or n<1 or i<1 or i>n or #data>200 then return end
        local key=sender..':'..id; local p=self.pending[key]
        local stock=id:match('^s[0-9a-f]+%-%d+$')
        if stock and done[key] then return end
        if not p then
            local total,per=0,0
            for _,v in pairs(self.pending) do total=total+1; if v.sender==sender then per=per+1 end end
            if total>=64 or per>=4 then return end
            p={n=n,parts={},count=0,sender=sender}; self.pending[key]=p
        end
        if p.n~=n or p.parts[i] and p.parts[i]~=data then self.pending[key]=nil; return end
        -- Timeout tracks distinct fragments, not the first one or a replay of an old one.
        if not p.parts[i] then p.parts[i]=data; p.count=p.count+1; p.lastProgress=now end
        if p.count==n then
            self.pending[key]=nil
            local s=table.concat(p.parts); if #s>32768 then return end
            if stock then
                cursor=cursor%128+1
                local expired=ring[cursor]; if expired then done[expired]=nil end
                done[key]=true; ring[cursor]=key
            end
            return s
        end
    end
    return rx
end
-- Forever SendAddonMessageResult. Retain temporary failures; an invalid
-- packet cannot be allowed to head-of-line block every later record.
local retryable={[3]=true,[8]=true,[11]=true}
local invalid={[1]=true,[2]=true,[4]=true,[6]=true,[7]=true}
local channelFault={[1]=true,[4]=true,[5]=true,[6]=true,[7]=true,[10]=true}
-- Fixed-rate queue: at most one 200-byte fragment per 0.35s.
function W.queue(send)
    local q={items={},head=1,tail=0,bulk=0,nextAt=0,send=send,blocked=false}
    function q:addPacket(chunks,urgent,allowed)
        if urgent then
            -- One replaceable marker (up to three fragments), separate from bulk capacity.
            self.urgent={chunks=chunks,part=1,urgent=true}
        else
            if self.bulk+#chunks>2048 then self.overflow=true; return false end
            self.tail=self.tail+1; self.items[self.tail]={chunks=chunks,part=1,allowed=allowed}
            self.bulk=self.bulk+#chunks
        end
        return true
    end
    function q:add(msg) return self:addPacket({msg}) end -- legacy Sync sends single fragments
    local function detach(self,packet)
        if self.active then return end
        if packet.urgent then self.urgent=nil
        else
            self.items[self.head]=nil; self.head=self.head+1
            if self.head>self.tail then self.head=1; self.tail=0 end
        end
    end
    function q:tick(now,locked)
        if now<self.nextAt then return end
        local packet=self.active or self.urgent or self.items[self.head]
        if not packet then return end
        if packet.allowed and not packet.allowed() then
            detach(self,packet)
            self.bulk=self.bulk-(#packet.chunks-packet.part+1)
            self.active=nil; self.blocked=false
            return
        end
        self.nextAt=now+0.35
        if locked then self.blocked=true; self.nextAt=now+2; return end
        local ok,result=pcall(self.send,packet.chunks[packet.part])
        -- Enum.SendAddonMessageResult.Success=0; old API can return nil/true.
        if ok and (result==nil or result==true or result==0) then
            detach(self,packet)
            if not packet.urgent then self.bulk=self.bulk-1 end
            packet.part=packet.part+1; packet.failures=nil; self.blocked=false; self.fault=nil
            -- Once any fragment was sent, finish that packet before changing lanes.
            self.active=packet.part<=#packet.chunks and packet or nil
            return
        end
        local code=ok and type(result)=='number' and result or nil
        self.lastError=tostring(result)
        self.blocked=retryable[code] or false
        self.fault=channelFault[code] and self.lastError or nil
        if self.blocked or self.fault and not invalid[code] then self.nextAt=now+5; return end
        packet.failures=(packet.failures or 0)+1
        if not invalid[code] and packet.failures<3 then self.nextAt=now+5; return end
        detach(self,packet)
        if not packet.urgent then self.bulk=self.bulk-(#packet.chunks-packet.part+1) end
        self.active=nil
    end
    function q:size()
        local active=self.active
        return self.bulk+(self.urgent and #self.urgent.chunks or 0)
            +(active and active.urgent and #active.chunks-active.part+1 or 0)
    end
    return q
end
function W.digest(records)
    local ids={}; for id in pairs(records) do ids[#ids+1]=id end; table.sort(ids)
    local hash=5381
    for _,id in ipairs(ids) do for i=1,#id do hash=(hash*33+id:byte(i))%2147483647 end end
    return tostring(#ids)..':'..string.format('%x',hash),ids
end
