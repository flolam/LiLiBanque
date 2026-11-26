-- LiLiBanque: pure data layer, Lua 5.1. No WoW globals or executable deserialization.
LiLiBanque = LiLiBanque or {}
local C = {}; LiLiBanque.Core = C
C.VERSION = '1.4.1'
local moneyKinds = {deposit=true,withdraw=true,repair=true,withdrawForTab=true,buyTab=true,depositSummary=true}
local eventKinds = {join=true,leave=true,remove=true,promote=true,demote=true,invite=true}
function C.copy(t) local o={}; for k,v in pairs(t) do o[k]=v end; return o end
function C.init(db,s,guild)
    if db and db.schema ~= 1 then return nil,nil,'Version de données non prise en charge' end
    db=db or {schema=1,guild=guild}; db.addonVersion=C.VERSION
    for _,k in ipairs({'scannedBy','ledger','events','bankMoney','gaps'}) do db[k]=db[k] or {} end
    db.roster=db.roster or {scannedAt=0,members={}}
    s=s or {}; s.markers=s.markers or {}; s.aliases=s.aliases or {}; s.claims=s.claims or {}; s.seq=s.seq or 0
    return db,s
end
function C.age(now,y,m,d,h)
    y,m,d,h=tonumber(y) or 0,tonumber(m) or 0,tonumber(d) or 0,tonumber(h) or 0
    local precision=y>0 and 31622400 or m>0 and 2678400 or d>0 and 86400 or 3600
    return math.max(0,now-(y*365.25*86400+m*30.4375*86400+d*86400+h*3600)),precision
end
function C.valid(col,r)
    if type(r)~='table' or type(r.id)~='string' or #r.id<1 or #r.id>200 then return false end
    if type(r.ts)~='number' or r.ts<0 or r.ts>4102444800 or r.ts~=r.ts then return false end
    if type(r.tsPrecision)~='number' or r.tsPrecision~=r.tsPrecision or r.tsPrecision<1 or r.tsPrecision>63072000 then return false end
    if col=='ledger' then
        return moneyKinds[r.kind] and type(r.name)=='string' and #r.name<=150 and type(r.source)=='string' and #r.source<=150
            and type(r.seenAt)=='number' and r.seenAt==r.seenAt and r.seenAt>=0 and r.seenAt<=4102444800 and type(r.copper)=='number' and r.copper>=0 and r.copper<=1e15 and r.copper==math.floor(r.copper)
    end
    return col=='events' and eventKinds[r.kind] and type(r.player)=='string' and #r.player<=150 and type(r.actor)=='string' and #r.actor<=150 and (r.rank==nil or type(r.rank)=='string' and #r.rank<=150)
end
function C.same(a,b,col)
    if not a or not b or a.kind~=b.kind then return false end
    if col=='ledger' then
        if a.name~=b.name or a.copper~=b.copper then return false end
    elseif a.player~=b.player or a.actor~=b.actor or a.rank~=b.rank then return false end
    return math.abs(a.ts-b.ts)<=a.tsPrecision+b.tsPrecision
end
local function origin(r) return r.id:match('^[LE]:([^:]+)') or r.source or r.id end
local function tables(s,col)
    s.aliases[col]=s.aliases[col] or {}; s.claims[col]=s.claims[col] or {}; s.markers[col]=s.markers[col] or {}
    return s.aliases[col],s.claims[col],s.markers[col]
end
local function resolve(aliases,id)
    local n=0
    while aliases[id] and aliases[id]~=id and n<100 do id=aliases[id]; n=n+1 end
    return id
end
-- One claim per origin per occurrence: repeated equal rows from an officer are NOT a set.
local function mergeOne(db,s,col,r,used)
    if not C.valid(col,r) then return nil,false end
    local aliases,claims=tables(s,col); local records=db[col]; local incoming=r.id
    local id=resolve(aliases,incoming)
    if records[id] then if used then used[id]=true end; return id,false end
    local src=origin(r); local best
    for k,v in pairs(records) do
        claims[k]=claims[k] or {[origin(v)]=v.id}
        if not (used and used[k]) and not claims[k][src] and C.same(v,r,col) then
            if not best or math.abs(v.ts-r.ts)<math.abs(records[best].ts-r.ts) or math.abs(v.ts-r.ts)==math.abs(records[best].ts-r.ts) and k<best then best=k end
        end
    end
    if best then
        claims[best][src]=incoming
        -- IDs converge lexically, independently of which officer observed the row first.
        -- Observation metadata comes from the earliest known scan, never an average.
        local chosen=records[best]
        if col=='ledger' and r.seenAt<chosen.seenAt then chosen=r end
        if incoming<best then
            records[incoming]=C.copy(chosen); records[incoming].id=incoming; records[best]=nil
            claims[incoming]=claims[best]; claims[best]=nil; aliases[best]=incoming
            if used and used[best] then used[best]=nil; used[incoming]=true end
            best=incoming
        else
            aliases[incoming]=best
            records[best]=C.copy(chosen); records[best].id=best
        end
        if used then used[best]=true end
        return best,false
    end
    records[incoming]=C.copy(r); claims[incoming]={[src]=incoming}
    if used then used[incoming]=true end
    return incoming,true
end
-- Original observations stay per-character, never in the exported DB. Migrate the
-- old claim IDs before a canonical ID hides their origin. Old states did not keep
-- each observation's timestamp, so use their existing representative conservatively.
function C.observations(db,s,col)
    s.observations=s.observations or {}
    if not s.observations[col] then
        local all={}; local _,claims=tables(s,col)
        for id,r in pairs(db[col]) do
            all[id]=C.copy(r)
            for _,claim in pairs(claims[id] or {}) do
                local copy=C.copy(r); copy.id=claim
                if C.valid(col,copy) then all[claim]=copy end
            end
        end
        s.observations[col]=all
    end
    return s.observations[col]
end
function C.merge(db,s,col,r,used)
    if not C.valid(col,r) then return nil,false end
    local all=C.observations(db,s,col); local aliases,claims=tables(s,col)
    if all[r.id] then
        local id=resolve(aliases,r.id)
        if used then used[id]=true end
        return id,false
    end
    all[r.id]=C.copy(r)
    -- Reconcile only the connected overlap component. Replay *original* IDs in
    -- lexical order so the same evidence gives identical occurrence slots even
    -- when officers receive D messages in different orders.
    local group={[r.id]=r}; local changed=true
    while changed do
        changed=false
        for id,v in pairs(all) do
            if not group[id] then
                for _,known in pairs(group) do
                    if C.same(v,known,col) then group[id]=v; changed=true; break end
                end
            end
        end
    end
    local before=0; local removed={}
    for id in pairs(group) do
        local canonical=resolve(aliases,id)
        if db[col][canonical] and not removed[canonical] then
            removed[canonical]=true; before=before+1
        end
    end
    local ids={}; for id in pairs(group) do ids[#ids+1]=id end; table.sort(ids)
    local rebuilt={[col]={}}; local state={aliases={},claims={},markers={}}
    for _,id in ipairs(ids) do mergeOne(rebuilt,state,col,group[id]) end
    for id in pairs(removed) do db[col][id]=nil; claims[id]=nil end
    for id in pairs(group) do aliases[id]=nil end
    local after=0
    for id,v in pairs(rebuilt[col]) do
        db[col][id]=v; claims[id]=state.claims[col][id]; after=after+1
    end
    for _,id in ipairs(ids) do
        local canonical=resolve(state.aliases[col],id)
        if canonical~=id then aliases[id]=canonical end
    end
    local id=resolve(aliases,r.id)
    if used then used[id]=true end
    return id,after>before
end
function C.scan(db,s,col,rows,now,source)
    local aliases,_,markers=tables(s,col); local prev=markers[source] or {}; local used={}; local ids={}; local added=0
    local overlap,finish=0,0
    -- Align the longest suffix ending with the last saved marker. Counts preserve duplicates.
    for n=math.min(#prev,#rows),1,-1 do
        for start=1,#rows-n+1 do
            local ok=true
            for j=1,n do
                local old=db[col][resolve(aliases,prev[#prev-n+j])]
                if not C.same(old,rows[start+j-1],col) then ok=false; break end
            end
            if ok then overlap=n; finish=start+n-1; break end
        end
        if overlap>0 then break end
    end
    local gap
    if #prev>0 and #rows>0 and overlap==0 and col=='ledger' then
        local from=s.localLedgerAt or s.lastScan and s.lastScan.ok and s.lastScan.at
        if not from then
            for _,id in ipairs(prev) do
                local r=db.ledger[resolve(aliases,id)]
                if r and (not from or r.seenAt>from) then from=r.seenAt end
            end
        end
        db.gaps[#db.gaps+1]={at=now,reason='rollover'}
        gap={at=now,from=from}; s.lastGap=gap
    end
    if overlap>0 then
        for i=1,overlap do
            local id=resolve(aliases,prev[#prev-overlap+i]); ids[finish-overlap+i]=id; used[id]=true
        end
    end
    for i=1,#rows do
        if not ids[i] and (finish==0 or i>finish) then
            local r=C.copy(rows[i]); s.seq=s.seq+1
            r.id=(col=='ledger' and 'L:' or 'E:')..source..':'..now..':'..s.seq
            if col=='ledger' then r.source=source; r.seenAt=now end
            local id,isNew=C.merge(db,s,col,r,used); ids[i]=id
            if isNew then added=added+1 end
        end
    end
    local nextMarkers={}; for i=1,#rows do if ids[i] then nextMarkers[#nextMarkers+1]=ids[i] end end
    -- An empty/denied response must never erase the previous continuity marker.
    if #nextMarkers>0 then markers[source]=nextMarkers end
    db.scannedBy[source]=now
    if col=='ledger' and #rows>0 then s.localLedgerAt=now end
    return added,gap
end
-- Scan time is internal, never part of the exported DB. A roster timestamp is not a bank scan.
function C.validScanAt(at,now)
    return type(at)=='number' and at==at and at>0 and at<=4102444800
        and at==math.floor(at) and at<=now+300
end
function C.bankScanTime(db,s,now)
    local at=0
    local function take(v) if C.validScanAt(v,now) and v>at then at=v end end
    take(s.bankScanAt); take(s.localLedgerAt)
    if s.lastScan and s.lastScan.ok then take(s.lastScan.at) end
    for _,r in pairs(db.ledger) do take(r.seenAt) end
    if at>0 then s.bankScanAt=at; return at end
end
function C.money(db,now,copper)
    if type(copper)~='number' or copper<0 or copper~=math.floor(copper) then return end
    local last=db.bankMoney[#db.bankMoney]
    if not last or last.copper~=copper then db.bankMoney[#db.bankMoney+1]={at=now,copper=copper} end
end
