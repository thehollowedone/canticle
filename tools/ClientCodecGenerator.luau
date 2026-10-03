local Codec = require("../src/TransportCodec")
local Generator = {}

function Generator.generate(spec, options)
    local codec, err = Codec.compile(spec)
    if not codec then
        return nil, err
    end
    local packed = spec.type == "array"
        and spec.encoding == "packed"
        and spec.items.type == "boolean"
    local fields = if spec.type == "array" and spec.items.type == "object"
        then spec.items.fields
        else nil
    if not packed then
        if spec.encoding ~= nil or type(fields) ~= "table" or #fields < 1 or #fields > 16 then
            return nil, "client specialization requires packed booleans or required u8 records"
        end
        for _, field in ipairs(fields) do
            local s = field.schema
            if
                field.optional
                or s.type ~= "integer"
                or s.min < 0
                or s.max > 255
                or (s.encoding ~= nil and s.encoding ~= "u8" and s.encoding ~= "auto")
            then
                return nil, "client specialization requires required u8 fields"
            end
        end
    end
    local lines = {}
    local function add(s)
        lines[#lines + 1] = s
    end
    local fixed = (spec.minLength or 0) == spec.maxLength
    local width = if packed then 0 else #fields
    local checked = not (options and options.trustOutbound == true)
    add("--!strict\n--!native\n--!optimize 2")
    add(
        string.format(
            "local Encoder = { maximumBytes = %d, fingerprint = %d, validatesOutgoing = %s }",
            codec.maximumBytes,
            codec.fingerprint,
            tostring(checked)
        )
    )
    add(
        "local function prefixSize(n)\n    if n < 128 then return 1 elseif n < 16384 then return 2 elseif n < 2097152 then return 3 elseif n < 268435456 then return 4 else return 5 end\nend"
    )
    add(
        "local function writeItem(out: buffer, offset: number, value: any, length: number): (number?, string?)"
    )
    if not fixed then
        add(
            "    local n = length\n    repeat\n        local low = n % 128\n        n = math.floor(n / 128)\n        buffer.writeu8(out, offset, low + (if n > 0 then 128 else 0))\n        offset += 1\n    until n == 0"
        )
    end
    if packed then
        add("    for first = 1, length - 7, 8 do")
        add(
            "        local a,b,c,d = value[first],value[first+1],value[first+2],value[first+3]\n        local e,f,g,h = value[first+4],value[first+5],value[first+6],value[first+7]"
        )
        add("        local bits=0")
        for bit, name in ipairs({ "a", "b", "c", "d", "e", "f", "g", "h" }) do
            add(
                if checked
                    then `        if {name}==true then bits+={2 ^ (bit - 1)} elseif {name}~=false then return nil,'expected_boolean' end`
                    else `        if {name} then bits+={2 ^ (bit - 1)} end`
            )
        end
        add("        buffer.writeu8(out,offset,bits)\n        offset+=1\n    end")
        add(
            "    local tail=length%8\n    if tail>0 then\n        local bits=0\n        for bit=0,tail-1 do\n            local v=value[length-tail+bit+1]"
        )
        add(
            if checked
                then "            if v==true then bits+=2^bit elseif v~=false then return nil,'expected_boolean' end"
                else "            if v then bits+=2^bit end"
        )
        add("        end\n        buffer.writeu8(out,offset,bits)\n        offset+=1\n    end")
    else
        add("    for row=1,length do\n        local item=value[row]")
        if checked then
            add("        if type(item)~='table' then return nil,'invalid_object' end")
        end
        for i, field in ipairs(fields) do
            add(`        local v{i}=item[{string.format("%q", field.name)}]`)
            if checked then
                add(`        if v{i}==nil then return nil,'missing_field' end`)
            end
            local narrow = if field.schema.min ~= 0 or field.schema.max ~= 255
                then ` or v{i}<{field.schema.min} or v{i}>{field.schema.max}`
                else ""
            -- Equality with the masked byte rejects fractions and values outside 0..255.
            if checked then
                add(
                    `        if type(v{i})~='number' or bit32.band(v{i},255)~=v{i}{narrow} then return nil,'invalid_integer' end`
                )
            end
        end
        local i = 1
        while i <= width do
            if width - i + 1 >= 4 then
                add(
                    `        buffer.writeu32(out,offset,v{i}+v{i + 1}*256+v{i + 2}*65536+v{i + 3}*16777216)\n        offset+=4`
                )
                i += 4
            elseif width - i + 1 >= 2 then
                add(`        buffer.writeu16(out,offset,v{i}+v{i + 1}*256)\n        offset+=2`)
                i += 2
            else
                add(`        buffer.writeu8(out,offset,v{i})\n        offset+=1`)
                i += 1
            end
        end
        add("    end")
    end
    add("    return offset,nil\nend")
    add("local function encode(values: any, limits: any, compact: boolean): (buffer?, string?)")
    add(
        "    if type(values)~='table' then return nil,'invalid_batch' end\n    local count=#values\n    local maxItems=if limits and limits.maximumItems then limits.maximumItems else 64\n    local maxItem=if limits and limits.maximumItemBytes then limits.maximumItemBytes else 65535\n    local maxPayload=if limits and limits.maximumPayloadBytes then limits.maximumPayloadBytes else 1048576\n    if count<1 or count>maxItems or count>65535 then return nil,'batch_item_count' end\n    local keys=0\n    for key in values do\n        if type(key)~='number' or key~=math.floor(key) or key<1 or key>count then return nil,'invalid_batch' end\n        keys+=1\n    end\n    if keys~=count then return nil,'invalid_batch' end"
    )
    add(
        "    local sizes=table.create(count)\n    local lengths=table.create(count)\n    local seen={}\n    local duplicates={}\n    local repeated=false\n    local total=2"
    )
    add(
        "    for i=1,count do\n        local value=values[i]\n        if type(value)~='table' then return nil,'invalid_array' end\n        local length=#value"
    )
    add(
        `        if length<{spec.minLength or 0} or length>{spec.maxLength} then return nil,'invalid_array' end`
    )
    add(
        `        local size={if packed then "math.ceil(length/8)" else `length*{width}`}+{if fixed
            then "0"
            else "prefixSize(length)"}`
    )
    add(
        "        if compact and size<1 then return nil,'compact_zero_size_item' end\n        if size>maxItem then return nil,'batch_item_invalid' end\n        total+=size+(if compact then 0 else 4)\n        if total>maxPayload then return nil,'batch_too_large' end\n        sizes[i]=size\n        lengths[i]=length\n        if seen[value] then duplicates[value]=true repeated=true else seen[value]=true end\n    end"
    )
    add(
        "    local memo=nil\n    if repeated and getmetatable(values)==nil then\n        local plain=true\n        for value in seen do\n            if getmetatable(value)~=nil then plain=false break end"
    )
    if not packed then
        add(
            "            for _,item in ipairs(value) do\n                if type(item)~='table' or getmetatable(item)~=nil then plain=false break end\n            end\n            if not plain then break end"
        )
    end
    add(
        "        end\n        if plain then memo={} end\n    end\n    local out=buffer.create(total)\n    buffer.writeu16(out,0,count)\n    local offset=2"
    )
    add(
        "    for i=1,count do\n        local value=values[i]\n        if not compact then buffer.writeu32(out,offset,sizes[i]) offset+=4 end\n        local start=offset\n        local previous=if memo then memo[value] else nil\n        if previous then\n            buffer.copy(out,offset,out,previous,sizes[i])\n            offset+=sizes[i]\n        else\n            local finish,reason=writeItem(out,offset,value,lengths[i])\n            if not finish then return nil,reason end\n            offset=finish\n        end\n        if offset~=start+sizes[i] then return nil,'encoder_length_mismatch' end\n        if memo and duplicates[value] then memo[value]=start end\n    end\n    return out,nil\nend"
    )
    add(
        "function Encoder:encodeCompactBatch(values: any, limits: any): (buffer?, string?)\n    return encode(values,limits,true)\nend\nfunction Encoder:encodeBatch(values: any, limits: any): (buffer?, string?)\n    return encode(values,limits,false)\nend\nreturn table.freeze(Encoder)"
    )
    return table.concat(lines, "\n") .. "\n", nil
end

return Generator
