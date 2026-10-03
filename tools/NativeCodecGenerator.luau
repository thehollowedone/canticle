local Codec = require("../src/TransportCodec")

local Generator = {}

local keywords = {
    ["break"] = true,
    ["continue"] = true,
    ["do"] = true,
    ["else"] = true,
    ["elseif"] = true,
    ["end"] = true,
    ["false"] = true,
    ["for"] = true,
    ["function"] = true,
    ["if"] = true,
    ["in"] = true,
    ["local"] = true,
    ["nil"] = true,
    ["not"] = true,
    ["or"] = true,
    ["repeat"] = true,
    ["return"] = true,
    ["then"] = true,
    ["true"] = true,
    ["until"] = true,
    ["while"] = true,
}
keywords["and"] = true

local function literalName(name)
    if string.match(name, "^[%a_][%w_]*$") and not keywords[name] then
        return name
    end
    return "[" .. string.format("%q", name) .. "]"
end

function Generator.generate(spec)
    local codec, err = Codec.compile(spec)
    if not codec then
        return nil, err
    end
    local packed = spec.type == "array"
        and spec.encoding == "packed"
        and spec.items.type == "boolean"
    if
        not packed
        and (
            spec.type ~= "array"
            or spec.encoding ~= nil
            or type(spec.items) ~= "table"
            or spec.items.type ~= "object"
        )
    then
        return nil, "native decoder requires packed booleans or an array of records"
    end
    local fields = if packed then nil else spec.items.fields
    if not packed then
        if type(fields) ~= "table" or #fields < 1 or #fields > 16 then
            return nil, "native decoder requires 1-16 fields"
        end
        for _, field in ipairs(fields) do
            if field.optional == true or field.schema.type ~= "integer" then
                return nil, "native decoder requires required u8 fields"
            end
            local minimum, maximum = field.schema.min, field.schema.max
            local encoding = field.schema.encoding
            if
                type(minimum) ~= "number"
                or type(maximum) ~= "number"
                or minimum < 0
                or maximum > 255
                or (encoding ~= nil and encoding ~= "u8" and encoding ~= "auto")
            then
                return nil, "native decoder requires required u8 fields"
            end
        end
    end

    local lines = {}
    local function add(line)
        table.insert(lines, line)
    end
    add("--!strict")
    add("--!native")
    add(
        string.format(
            "local Decoder = { maximumBytes = %d, fingerprint = %d }",
            codec.maximumBytes,
            codec.fingerprint
        )
    )
    add("function Decoder:decodeBatch(data, limits, region)")
    add(
        "    if typeof(data) ~= 'buffer' or (region ~= nil and type(region) ~= 'table') then return false, nil, 'invalid_batch' end"
    )
    add("    local dataLength = buffer.len(data)")
    add("    local start = if region then region.offset else 0")
    add("    local length = if region then region.length else dataLength")
    add(
        "    if type(start) ~= 'number' or type(length) ~= 'number' or start ~= math.floor(start) or length ~= math.floor(length) or start < 0 or length < 2 or start > dataLength - length then return false, nil, 'invalid_batch' end"
    )
    add("    local finish = start + length")
    add("    local count = buffer.readu16(data, start)")
    add(
        "    local maximumItems = if limits and limits.maximumItems then limits.maximumItems else 64"
    )
    add(
        "    local maximumItemBytes = if limits and limits.maximumItemBytes then limits.maximumItemBytes else 65535"
    )
    add(
        "    local maximumPayloadBytes = if limits and limits.maximumPayloadBytes then limits.maximumPayloadBytes else 1048576"
    )
    add("    if count < 1 or count > maximumItems then return false, nil, 'batch_item_count' end")
    add("    if length > maximumPayloadBytes then return false, nil, 'batch_too_large' end")
    add("    local values = table.create(count)")
    add("    local offset = start + 2")
    add("    for itemIndex = 1, count do")
    add("        if offset > finish - 4 then return false, nil, 'truncated_batch' end")
    add("        local size = buffer.readu32(data, offset)")
    add("        offset += 4")
    add(
        "        if size > maximumItemBytes or size > Decoder.maximumBytes or offset > finish - size then return false, nil, 'invalid_batch_item' end"
    )
    add("        local itemFinish = offset + size")
    if (spec.minLength or 0) == spec.maxLength then
        add(`        local recordCount = {spec.maxLength}`)
    else
        add("        local recordCount = 0")
        add("        local factor = 1")
        add("        local prefixBytes = 0")
        add("        repeat")
        add(
            "            if offset >= itemFinish or prefixBytes >= 5 then return false, nil, 'truncated_varint' end"
        )
        add("            local byte = buffer.readu8(data, offset)")
        add("            offset += 1")
        add("            prefixBytes += 1")
        add("            local low = byte % 128")
        add(
            "            if prefixBytes == 5 and low > 15 then return false, nil, 'varint_overflow' end"
        )
        add("            recordCount += low * factor")
        add("            if byte < 128 then")
        add(
            "                if prefixBytes > 1 and low == 0 then return false, nil, 'noncanonical_varint' end"
        )
        add("                break")
        add("            end")
        add("            factor *= 128")
        add("        until false")
        add(
            `        if recordCount < {spec.minLength or 0} or recordCount > {spec.maxLength} then return false, nil, 'invalid_array_length' end`
        )
    end
    if packed then
        add("        local byteCount = math.ceil(recordCount / 8)")
        add(
            "        if offset + byteCount ~= itemFinish then return false, nil, 'invalid_batch_item' end"
        )
        add("        local records = table.create(recordCount)")
        add("        local fullBytes = math.floor(recordCount / 8)")
        add("        for byteIndex = 0, fullBytes - 1 do")
        add("            local bits = buffer.readu8(data, offset + byteIndex)")
        add("            local first = byteIndex * 8 + 1")
        for bit = 0, 7 do
            add(`            records[first + {bit}] = bit32.btest(bits, {2 ^ bit})`)
        end
        add("        end")
        add("        if recordCount % 8 ~= 0 then")
        add("            local usedBits = recordCount % 8")
        add("            local tail = buffer.readu8(data, offset + fullBytes)")
        add(
            "            if bit32.band(tail, bit32.bnot(bit32.lshift(1, usedBits) - 1)) ~= 0 then return false, nil, 'noncanonical_boolean_array' end"
        )
        add("            for bit = 0, usedBits - 1 do")
        add(
            "                records[fullBytes * 8 + bit + 1] = bit32.btest(tail, bit32.lshift(1, bit))"
        )
        add("            end")
        add("        end")
        add("        offset = itemFinish")
    else
        add(
            `        if offset + recordCount * {#fields} ~= itemFinish then return false, nil, 'invalid_batch_item' end`
        )
        add("        local records = table.create(recordCount)")
        add("        for recordIndex = 1, recordCount do")
        for index, field in ipairs(fields) do
            add(`            local v{index} = buffer.readu8(data, offset + {index - 1})`)
            if field.schema.min > 0 or field.schema.max < 255 then
                add(
                    `            if v{index} < {field.schema.min} or v{index} > {field.schema.max} then return false, nil, 'integer_out_of_range' end`
                )
            end
        end
        local entries = {}
        for index, field in ipairs(fields) do
            table.insert(entries, `{literalName(field.name)} = v{index}`)
        end
        add("            records[recordIndex] = { " .. table.concat(entries, ", ") .. " }")
        add(`            offset += {#fields}`)
        add("        end")
    end
    add("        values[itemIndex] = records")
    add("    end")
    add("    if offset ~= finish then return false, nil, 'trailing_batch_bytes' end")
    add("    return true, values, nil")
    add("end")
    add("function Decoder:decodeCompactBatch(data, limits, region)")
    add(
        "    if typeof(data) ~= 'buffer' or (region ~= nil and type(region) ~= 'table') then return false, nil, 'invalid_batch' end"
    )
    add("    local dataLength = buffer.len(data)")
    add("    local start = if region then region.offset else 0")
    add("    local length = if region then region.length else dataLength")
    add(
        "    if type(start) ~= 'number' or type(length) ~= 'number' or start ~= math.floor(start) or length ~= math.floor(length) or start < 0 or length < 2 or start > dataLength - length then return false, nil, 'invalid_batch' end"
    )
    add("    local finish = start + length")
    add("    local count = buffer.readu16(data, start)")
    add(
        "    local maximumItems = if limits and limits.maximumItems then limits.maximumItems else 64"
    )
    add(
        "    local maximumItemBytes = if limits and limits.maximumItemBytes then limits.maximumItemBytes else 65535"
    )
    add(
        "    local maximumPayloadBytes = if limits and limits.maximumPayloadBytes then limits.maximumPayloadBytes else 1048576"
    )
    add("    if count < 1 or count > maximumItems then return false, nil, 'batch_item_count' end")
    add("    if length > maximumPayloadBytes then return false, nil, 'batch_too_large' end")
    add("    local values = table.create(count)")
    add("    local offset = start + 2")
    add("    for itemIndex = 1, count do")
    add("        local itemStart = offset")
    if (spec.minLength or 0) == spec.maxLength then
        add(`        local recordCount = {spec.maxLength}`)
    else
        add("        local recordCount = 0")
        add("        local factor = 1")
        add("        local prefixBytes = 0")
        add("        repeat")
        add(
            "            if offset >= finish or prefixBytes >= 5 then return false, nil, 'truncated_varint' end"
        )
        add("            local byte = buffer.readu8(data, offset)")
        add("            offset += 1")
        add("            prefixBytes += 1")
        add("            local low = byte % 128")
        add(
            "            if prefixBytes == 5 and low > 15 then return false, nil, 'varint_overflow' end"
        )
        add("            recordCount += low * factor")
        add("            if byte < 128 then")
        add(
            "                if prefixBytes > 1 and low == 0 then return false, nil, 'noncanonical_varint' end"
        )
        add("                break")
        add("            end")
        add("            factor *= 128")
        add("        until false")
        add(
            `        if recordCount < {spec.minLength or 0} or recordCount > {spec.maxLength} then return false, nil, 'invalid_array_length' end`
        )
    end
    if packed then
        add("        local byteCount = math.ceil(recordCount / 8)")
        add(
            "        if offset > finish - byteCount or offset + byteCount - itemStart > maximumItemBytes then return false, nil, 'invalid_batch_item' end"
        )
        add("        local records = table.create(recordCount)")
        add("        local fullBytes = math.floor(recordCount / 8)")
        add("        for byteIndex = 0, fullBytes - 1 do")
        add("            local bits = buffer.readu8(data, offset + byteIndex)")
        add("            local first = byteIndex * 8 + 1")
        for bit = 0, 7 do
            add(`            records[first + {bit}] = bit32.btest(bits, {2 ^ bit})`)
        end
        add("        end")
        add("        if recordCount % 8 ~= 0 then")
        add("            local usedBits = recordCount % 8")
        add("            local tail = buffer.readu8(data, offset + fullBytes)")
        add(
            "            if bit32.band(tail, bit32.bnot(bit32.lshift(1, usedBits) - 1)) ~= 0 then return false, nil, 'noncanonical_boolean_array' end"
        )
        add("            for bit = 0, usedBits - 1 do")
        add(
            "                records[fullBytes * 8 + bit + 1] = bit32.btest(tail, bit32.lshift(1, bit))"
        )
        add("            end")
        add("        end")
        add("        offset += byteCount")
    else
        add(`        local byteCount = recordCount * {#fields}`)
        add(
            "        if offset > finish - byteCount or offset + byteCount - itemStart > maximumItemBytes then return false, nil, 'invalid_batch_item' end"
        )
        add("        local records = table.create(recordCount)")
        add("        for recordIndex = 1, recordCount do")
        for index, field in ipairs(fields) do
            add(`            local v{index} = buffer.readu8(data, offset + {index - 1})`)
            if field.schema.min > 0 or field.schema.max < 255 then
                add(
                    `            if v{index} < {field.schema.min} or v{index} > {field.schema.max} then return false, nil, 'integer_out_of_range' end`
                )
            end
        end
        local entries = {}
        for index, field in ipairs(fields) do
            table.insert(entries, `{literalName(field.name)} = v{index}`)
        end
        add("            records[recordIndex] = { " .. table.concat(entries, ", ") .. " }")
        add(`            offset += {#fields}`)
        add("        end")
    end
    add("        if offset == itemStart then return false, nil, 'invalid_batch_item' end")
    add("        values[itemIndex] = records")
    add("    end")
    add("    if offset ~= finish then return false, nil, 'trailing_batch_bytes' end")
    add("    return true, values, nil")
    add("end")
    add("return table.freeze(Decoder)")
    return table.concat(lines, "\n") .. "\n", nil
end

return Generator
