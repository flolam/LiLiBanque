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
    function rx:push(sender,msg,now)
        for k,v in pairs(self.pending) do if now-v.at>120 then self.pending[k]=nil end end
        if type(msg)~='string' or #msg>=255 then return end
        local id,i,n,data=msg:match('^1|([%w_-]+)|(%d+)|(%d+)|(.*)$')
        i,n=tonumber(i),tonumber(n)
        if not id or #id>32 or not i or not n or n>164 or n<1 or i<1 or i>n or #data>200 then return end
        local key=sender..':'..id; local p=self.pending[key]
        if not p then
            local total,per=0,0
            for _,v in pairs(self.pending) do total=total+1; if v.sender==sender then per=per+1 end end
            if total>=64 or per>=4 then return end
            p={at=now,n=n,parts={},count=0,sender=sender}; self.pending[key]=p
        end
        if p.n~=n or p.parts[i] and p.parts[i]~=data then self.pending[key]=nil; return end
        if not p.parts[i] then p.parts[i]=data; p.count=p.count+1 end
        if p.count==n then self.pending[key]=nil; local s=table.concat(p.parts); if #s<=32768 then return s end end
    end
    return rx
end
-- Fixed-rate queue: max one 200-byte fragment per 0.35s; retain on lockdown/throttle/errors.
function W.queue(send)
    local q={items={},head=1,tail=0,nextAt=0,send=send,blocked=false}
    function q:add(msg)
        if self.tail-self.head+1>=2048 then self.overflow=true; return false end
        self.tail=self.tail+1; self.items[self.tail]=msg; return true
    end
    function q:tick(now,locked)
        if now<self.nextAt or not self.items[self.head] then return end
        self.nextAt=now+0.35
        if locked then self.blocked=true; self.nextAt=now+2; return end
        local ok,result=pcall(self.send,self.items[self.head])
        -- Enum.SendAddonMessageResult.Success=0; old API can return nil/true.
        if ok and (result==nil or result==true or result==0) then
            self.items[self.head]=nil; self.head=self.head+1; self.blocked=false
            if self.head>self.tail then self.head=1; self.tail=0 end
        else self.blocked=true; self.lastError=tostring(result); self.nextAt=now+5 end
    end
    function q:size() return self.tail-self.head+1 end
    return q
end
function W.digest(records)
    local ids={}; for id in pairs(records) do ids[#ids+1]=id end; table.sort(ids)
    local hash=5381
    for _,id in ipairs(ids) do for i=1,#id do hash=(hash*33+id:byte(i))%2147483647 end end
    return tostring(#ids)..':'..string.format('%x',hash),ids
end
