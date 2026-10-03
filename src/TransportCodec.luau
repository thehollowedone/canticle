--!strict
--!optimize 2
--!native

local TransportCodec = {}

local MAX_BYTES = 65535
local MAX_DEPTH = 8
local MAX_FIELDS = 64
local MAX_ARRAY = 1024
local MAX_STRING = 8192
local U32 = 4294967295
local I32_MIN = -2147483648
local I32_MAX = 2147483647

type Node = { [string]: any }
type Reader = { data: buffer, offset: number, length: number }

local function finite(v: any): boolean
    return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

local function integer(v: any): boolean
    return finite(v) and v == math.floor(v)
end

local function writeVarUInt(out: buffer, offset: number, value: number): number
    local v = value
    repeat
        local byte = v % 128
        v = math.floor(v / 128)
        if v > 0 then
            byte += 128
        end
        buffer.writeu8(out, offset, byte)
        offset += 1
    until v == 0
    return offset
end

local function varUIntBytes(value: number): number
    local n = 1
    local v = value
    while v >= 128 do
        v = math.floor(v / 128)
        n += 1
    end
    return n
end

local function readVarUInt(reader: Reader): (number?, string?)
    local value = 0
    local factor = 1
    for i = 1, 5 do
        if reader.offset >= reader.length then
            return nil, "truncated_varint"
        end
        local byte = buffer.readu8(reader.data, reader.offset)
        reader.offset += 1
        local low = byte % 128
        if i == 5 and low > 15 then
            return nil, "varint_overflow"
        end
        value += low * factor
        if byte < 128 then
            if i > 1 and low == 0 then
                return nil, "noncanonical_varint"
            end
            return value, nil
        end
        factor *= 128
    end
    return nil, "unterminated_varint"
end

local function zigzagEncode(v: number): number
    if v >= 0 then
        return v * 2
    end
    return -v * 2 - 1
end

local function zigzagDecode(v: number): number
    if v % 2 == 0 then
        return v / 2
    end
    return -(v + 1) / 2
end

local function normalizeIntegerEncoding(
    spec: any,
    minimum: number,
    maximum: number
): (string?, string?)
    local encoding = spec.encoding or "auto"
    if encoding == "auto" then
        if minimum >= 0 and maximum <= 255 then
            return "u8", nil
        elseif minimum >= -128 and maximum <= 127 then
            return "i8", nil
        elseif minimum >= 0 and maximum <= 65535 then
            return "u16", nil
        elseif minimum >= -32768 and maximum <= 32767 then
            return "i16", nil
        elseif minimum >= 0 and maximum > I32_MAX then
            return "u32", nil
        end
        return "varint", nil
    end
    local accepted = {
        varint = minimum >= I32_MIN and maximum <= I32_MAX,
        u8 = minimum >= 0 and maximum <= 255,
        i8 = minimum >= -128 and maximum <= 127,
        u16 = minimum >= 0 and maximum <= 65535,
        i16 = minimum >= -32768 and maximum <= 32767,
        u32 = minimum >= 0 and maximum <= U32,
        i32 = minimum >= I32_MIN and maximum <= I32_MAX,
    }
    if accepted[encoding] ~= true then
        return nil, "integer encoding cannot represent declared range"
    end
    return encoding, nil
end

local function compile(spec: any, depth: number): (Node?, string?)
    if depth > MAX_DEPTH or type(spec) ~= "table" then
        return nil, "invalid_schema"
    end
    local kind = spec.type
    if kind == "boolean" then
        return { kind = kind, maximumBytes = 1, signature = "b" }, nil
    elseif kind == "number" then
        local width = spec.encoding or "f64"
        if width ~= "f32" and width ~= "f64" then
            return nil, "invalid_number_encoding"
        end
        local minimum = if spec.min == nil then -math.huge else spec.min
        local maximum = if spec.max == nil then math.huge else spec.max
        if not finite(minimum) and minimum ~= -math.huge then
            return nil, "invalid_minimum"
        end
        if not finite(maximum) and maximum ~= math.huge then
            return nil, "invalid_maximum"
        end
        if minimum > maximum then
            return nil, "invalid_number_range"
        end
        return {
            kind = kind,
            encoding = width,
            minimum = minimum,
            maximum = maximum,
            maximumBytes = if width == "f32" then 4 else 8,
            signature = kind .. ":" .. width .. ":" .. tostring(minimum) .. ":" .. tostring(
                maximum
            ),
        },
            nil
    elseif kind == "integer" then
        local minimum = spec.min
        local maximum = spec.max
        if
            not integer(minimum)
            or not integer(maximum)
            or minimum > maximum
            or minimum < I32_MIN
            or maximum > U32
        then
            return nil, "integer_requires_bounded_32_bit_range"
        end
        local encoding, err = normalizeIntegerEncoding(spec, minimum, maximum)
        if not encoding then
            return nil, err
        end
        local maxBytes = if encoding == "u8" or encoding == "i8"
            then 1
            elseif encoding == "u16" or encoding == "i16" then 2
            elseif encoding == "u32" or encoding == "i32" then 4
            else 5
        return {
            kind = kind,
            encoding = encoding,
            minimum = minimum,
            maximum = maximum,
            maximumBytes = maxBytes,
            signature = table.concat({ kind, encoding, tostring(minimum), tostring(maximum) }, ":"),
        },
            nil
    elseif kind == "string" then
        local maximum = spec.maxLength
        local minimum = spec.minLength or 0
        if
            not integer(maximum)
            or not integer(minimum)
            or minimum < 0
            or maximum < minimum
            or maximum > MAX_STRING
        then
            return nil, "invalid_string_bounds"
        end
        local fixed = minimum == maximum
        return {
            kind = kind,
            minimum = minimum,
            maximum = maximum,
            fixed = fixed,
            maximumBytes = maximum + if fixed then 0 else varUIntBytes(maximum),
            signature = table.concat({ kind, tostring(minimum), tostring(maximum) }, ":"),
        },
            nil
    elseif kind == "enum" then
        local values = spec.values
        if type(values) ~= "table" or #values < 1 or #values > 256 then
            return nil, "invalid_enum"
        end
        local byValue = {}
        local copy = {}
        for i, value in ipairs(values) do
            if type(value) ~= "string" or byValue[value] then
                return nil, "invalid_enum_value"
            end
            byValue[value] = i - 1
            copy[i] = value
        end
        local bytes = if #copy <= 1 then 0 else 1
        return {
            kind = kind,
            values = copy,
            byValue = byValue,
            maximumBytes = bytes,
            signature = kind .. ":" .. table.concat(copy, "|"),
        },
            nil
    elseif kind == "array" then
        local maximum = spec.maxLength
        local minimum = spec.minLength or 0
        if
            not integer(maximum)
            or not integer(minimum)
            or minimum < 0
            or maximum < minimum
            or maximum > MAX_ARRAY
        then
            return nil, "invalid_array_bounds"
        end
        local item, err = compile(spec.items, depth + 1)
        if not item then
            return nil, err
        end
        local fixed = minimum == maximum
        local packedBoolean = spec.encoding == "packed"
        if spec.encoding ~= nil and (spec.encoding ~= "packed" or item.kind ~= "boolean") then
            return nil, "invalid_array_encoding"
        end
        local maximumBytes = (
            if packedBoolean then math.ceil(maximum / 8) else item.maximumBytes * maximum
        ) + if fixed then 0 else varUIntBytes(maximum)
        if maximumBytes > MAX_BYTES then
            return nil, "schema_too_large"
        end
        return {
            kind = kind,
            minimum = minimum,
            maximum = maximum,
            fixed = fixed,
            item = item,
            packedBoolean = packedBoolean,
            maximumBytes = maximumBytes,
            signature = if packedBoolean
                then table.concat(
                    { kind, "packed", tostring(minimum), tostring(maximum), item.signature },
                    ":"
                )
                else table.concat(
                    { kind, tostring(minimum), tostring(maximum), item.signature },
                    ":"
                ),
        },
            nil
    elseif kind == "object" then
        local fields = spec.fields
        if type(fields) ~= "table" or #fields > MAX_FIELDS then
            return nil, "invalid_object_fields"
        end
        local out = {}
        local names = {}
        local optionalCount = 0
        local maximumBytes = 0
        local signatures = {}
        for index, field in ipairs(fields) do
            if
                type(field) ~= "table"
                or type(field.name) ~= "string"
                or field.name == ""
                or names[field.name]
            then
                return nil, "invalid_object_field"
            end
            names[field.name] = true
            local node, err = compile(field.schema, depth + 1)
            if not node then
                return nil, err
            end
            local optional = field.optional == true
            if optional then
                optionalCount += 1
            end
            out[index] = {
                name = field.name,
                node = node,
                optional = optional,
                optionalIndex = if optional then optionalCount else nil,
            }
            maximumBytes += node.maximumBytes
            signatures[index] = field.name .. (if optional then "?" else "!") .. node.signature
        end
        local bitmapBytes = math.ceil(optionalCount / 8)
        maximumBytes += bitmapBytes
        if maximumBytes > MAX_BYTES then
            return nil, "schema_too_large"
        end
        return {
            kind = kind,
            fields = out,
            bitmapBytes = bitmapBytes,
            maximumBytes = maximumBytes,
            signature = kind .. "{" .. table.concat(signatures, ",") .. "}",
        },
            nil
    end
    return nil, "unsupported_schema_type"
end

local function sizeOf(node: Node, value: any): (number?, string?)
    local kind = node.kind
    if kind == "boolean" then
        if type(value) ~= "boolean" then
            return nil, "expected_boolean"
        end
        return 1, nil
    elseif kind == "number" then
        if not finite(value) or value < node.minimum or value > node.maximum then
            return nil, "invalid_number"
        end
        return node.maximumBytes, nil
    elseif kind == "integer" then
        if not integer(value) or value < node.minimum or value > node.maximum then
            return nil, "invalid_integer"
        end
        if node.encoding == "varint" then
            return varUIntBytes(zigzagEncode(value)), nil
        end
        return node.maximumBytes, nil
    elseif kind == "string" then
        if type(value) ~= "string" or #value < node.minimum or #value > node.maximum then
            return nil, "invalid_string"
        end
        return #value + if node.fixed then 0 else varUIntBytes(#value), nil
    elseif kind == "enum" then
        if node.byValue[value] == nil then
            return nil, "invalid_enum"
        end
        return node.maximumBytes, nil
    elseif kind == "array" then
        if type(value) ~= "table" or #value < node.minimum or #value > node.maximum then
            return nil, "invalid_array"
        end
        if node.packedBoolean then
            for i = 1, #value do
                if type(value[i]) ~= "boolean" then
                    return nil, "expected_boolean"
                end
            end
            return math.ceil(#value / 8) + if node.fixed then 0 else varUIntBytes(#value), nil
        end
        local total = if node.fixed then 0 else varUIntBytes(#value)
        for i = 1, #value do
            local s, err = sizeOf(node.item, value[i])
            if not s then
                return nil, err
            end
            total += s
        end
        return total, nil
    elseif kind == "object" then
        if type(value) ~= "table" then
            return nil, "invalid_object"
        end
        local total = node.bitmapBytes
        for _, field in ipairs(node.fields) do
            local child = value[field.name]
            if child == nil then
                if not field.optional then
                    return nil, "missing_field"
                end
            else
                local s, err = sizeOf(field.node, child)
                if not s then
                    return nil, err
                end
                total += s
            end
        end
        return total, nil
    end
    return nil, "invalid_node"
end

local function writeNode(node: Node, value: any, out: buffer, offset: number): number
    local kind = node.kind
    if kind == "boolean" then
        buffer.writeu8(out, offset, if value then 1 else 0)
        return offset + 1
    elseif kind == "number" then
        if node.encoding == "f32" then
            buffer.writef32(out, offset, value)
            return offset + 4
        end
        buffer.writef64(out, offset, value)
        return offset + 8
    elseif kind == "integer" then
        local e = node.encoding
        if e == "varint" then
            return writeVarUInt(out, offset, zigzagEncode(value))
        elseif e == "u8" then
            buffer.writeu8(out, offset, value)
            return offset + 1
        elseif e == "i8" then
            buffer.writei8(out, offset, value)
            return offset + 1
        elseif e == "u16" then
            buffer.writeu16(out, offset, value)
            return offset + 2
        elseif e == "i16" then
            buffer.writei16(out, offset, value)
            return offset + 2
        elseif e == "u32" then
            buffer.writeu32(out, offset, value)
            return offset + 4
        end
        buffer.writei32(out, offset, value)
        return offset + 4
    elseif kind == "string" then
        if not node.fixed then
            offset = writeVarUInt(out, offset, #value)
        end
        buffer.writestring(out, offset, value)
        return offset + #value
    elseif kind == "enum" then
        if node.maximumBytes == 0 then
            return offset
        end
        buffer.writeu8(out, offset, node.byValue[value])
        return offset + 1
    elseif kind == "array" then
        if not node.fixed then
            offset = writeVarUInt(out, offset, #value)
        end
        if node.packedBoolean then
            local length = #value
            local full = math.floor(length / 8)
            for byte = 0, full - 1 do
                local first = byte * 8 + 1
                local bits = 0
                if value[first] then
                    bits += 1
                end
                if value[first + 1] then
                    bits += 2
                end
                if value[first + 2] then
                    bits += 4
                end
                if value[first + 3] then
                    bits += 8
                end
                if value[first + 4] then
                    bits += 16
                end
                if value[first + 5] then
                    bits += 32
                end
                if value[first + 6] then
                    bits += 64
                end
                if value[first + 7] then
                    bits += 128
                end
                buffer.writeu8(out, offset + byte, bits)
            end
            if length % 8 ~= 0 then
                local bits = 0
                for i = full * 8 + 1, length do
                    if value[i] then
                        bits += bit32.lshift(1, (i - 1) % 8)
                    end
                end
                buffer.writeu8(out, offset + full, bits)
            end
            return offset + full + if length % 8 == 0 then 0 else 1
        end
        for i = 1, #value do
            offset = writeNode(node.item, value[i], out, offset)
        end
        return offset
    elseif kind == "object" then
        local bitmapStart = offset
        for i = 0, node.bitmapBytes - 1 do
            buffer.writeu8(out, bitmapStart + i, 0)
        end
        offset += node.bitmapBytes
        for _, field in ipairs(node.fields) do
            local child = value[field.name]
            if child ~= nil then
                if field.optional then
                    local bit = field.optionalIndex - 1
                    local byteOffset = bitmapStart + math.floor(bit / 8)
                    buffer.writeu8(
                        out,
                        byteOffset,
                        bit32.bor(buffer.readu8(out, byteOffset), bit32.lshift(1, bit % 8))
                    )
                end
                offset = writeNode(field.node, child, out, offset)
            end
        end
        return offset
    end
    return offset
end

local function need(reader: Reader, count: number): boolean
    return count >= 0 and reader.offset <= reader.length - count
end

local function readNode(node: Node, reader: Reader): (any?, string?)
    local kind = node.kind
    if kind == "boolean" then
        if not need(reader, 1) then
            return nil, "truncated"
        end
        local v = buffer.readu8(reader.data, reader.offset)
        reader.offset += 1
        if v > 1 then
            return nil, "invalid_boolean"
        end
        return v == 1, nil
    elseif kind == "number" then
        local n = node.maximumBytes
        if not need(reader, n) then
            return nil, "truncated"
        end
        local v = if n == 4
            then buffer.readf32(reader.data, reader.offset)
            else buffer.readf64(reader.data, reader.offset)
        reader.offset += n
        if not finite(v) or v < node.minimum or v > node.maximum then
            return nil, "invalid_number"
        end
        return v, nil
    elseif kind == "integer" then
        local e = node.encoding
        local v: any
        if e == "varint" then
            local raw, err = readVarUInt(reader)
            if raw == nil then
                return nil, err
            end
            v = zigzagDecode(raw)
        else
            local n = node.maximumBytes
            if not need(reader, n) then
                return nil, "truncated"
            end
            if e == "u8" then
                v = buffer.readu8(reader.data, reader.offset)
            elseif e == "i8" then
                v = buffer.readi8(reader.data, reader.offset)
            elseif e == "u16" then
                v = buffer.readu16(reader.data, reader.offset)
            elseif e == "i16" then
                v = buffer.readi16(reader.data, reader.offset)
            elseif e == "u32" then
                v = buffer.readu32(reader.data, reader.offset)
            else
                v = buffer.readi32(reader.data, reader.offset)
            end
            reader.offset += n
        end
        if v < node.minimum or v > node.maximum then
            return nil, "integer_out_of_range"
        end
        return v, nil
    elseif kind == "string" then
        local length: any = node.maximum
        if not node.fixed then
            local v, err = readVarUInt(reader)
            if v == nil then
                return nil, err
            end
            length = v
        end
        if length < node.minimum or length > node.maximum or not need(reader, length) then
            return nil, "invalid_string_length"
        end
        local v = buffer.readstring(reader.data, reader.offset, length)
        reader.offset += length
        return v, nil
    elseif kind == "enum" then
        if node.maximumBytes == 0 then
            return node.values[1], nil
        end
        if not need(reader, 1) then
            return nil, "truncated"
        end
        local idx = buffer.readu8(reader.data, reader.offset) + 1
        reader.offset += 1
        local v = node.values[idx]
        if v == nil then
            return nil, "invalid_enum"
        end
        return v, nil
    elseif kind == "array" then
        local length: any = node.maximum
        if not node.fixed then
            local v, err = readVarUInt(reader)
            if v == nil then
                return nil, err
            end
            length = v
        end
        if length < node.minimum or length > node.maximum then
            return nil, "invalid_array_length"
        end
        if node.packedBoolean then
            local byteLength = math.ceil(length / 8)
            if not need(reader, byteLength) then
                return nil, "truncated"
            end
            local out = table.create(length)
            local fullBytes = math.floor(length / 8)
            for byte = 0, fullBytes - 1 do
                local bits = buffer.readu8(reader.data, reader.offset + byte)
                local first = byte * 8 + 1
                out[first] = bit32.btest(bits, 1)
                out[first + 1] = bit32.btest(bits, 2)
                out[first + 2] = bit32.btest(bits, 4)
                out[first + 3] = bit32.btest(bits, 8)
                out[first + 4] = bit32.btest(bits, 16)
                out[first + 5] = bit32.btest(bits, 32)
                out[first + 6] = bit32.btest(bits, 64)
                out[first + 7] = bit32.btest(bits, 128)
            end
            if length % 8 ~= 0 then
                local usedBits = length % 8
                local finalByte = buffer.readu8(reader.data, reader.offset + byteLength - 1)
                if bit32.band(finalByte, bit32.bnot(bit32.lshift(1, usedBits) - 1)) ~= 0 then
                    return nil, "noncanonical_boolean_array"
                end
                local first = fullBytes * 8 + 1
                for bit = 0, usedBits - 1 do
                    out[first + bit] = bit32.btest(finalByte, bit32.lshift(1, bit))
                end
            end
            reader.offset += byteLength
            return out, nil
        end
        local out = table.create(length)
        for i = 1, length do
            local v, err = readNode(node.item, reader)
            if err then
                return nil, err
            end
            out[i] = v
        end
        return out, nil
    elseif kind == "object" then
        if not need(reader, node.bitmapBytes) then
            return nil, "truncated"
        end
        local bitmapStart = reader.offset
        reader.offset += node.bitmapBytes
        local out = {}
        for _, field in ipairs(node.fields) do
            local present = true
            if field.optional then
                local bit = field.optionalIndex - 1
                present = bit32.band(
                    buffer.readu8(reader.data, bitmapStart + math.floor(bit / 8)),
                    bit32.lshift(1, bit % 8)
                ) ~= 0
            end
            if present then
                local v, err = readNode(field.node, reader)
                if err then
                    return nil, err
                end
                out[field.name] = v
            end
        end
        return out, nil
    end
    return nil, "invalid_node"
end

local function hash(text: string): number
    local h = 2166136261
    for i = 1, #text do
        h = bit32.bxor(h, string.byte(text, i))
        h = (h * 16777619) % 4294967296
    end
    return h
end

-- Compile byte-array writers once to avoid per-field dispatch.
local function byteRecordFields(root: Node): { any }?
    if root.kind ~= "array" or root.item.kind ~= "object" then
        return nil
    end
    local object = root.item
    if object.bitmapBytes ~= 0 or #object.fields == 0 then
        return nil
    end
    for _, field in ipairs(object.fields) do
        if field.optional or field.node.kind ~= "integer" or field.node.encoding ~= "u8" then
            return nil
        end
    end
    return object.fields
end

local function writeFixedByteArray(
    out: buffer,
    offset: number,
    value: any,
    count: number,
    fields: { any },
    fullRange: boolean
): (number?, string?)
    if type(value) ~= "table" or #value ~= count then
        return nil, "invalid_array"
    end
    if #fields == 6 then
        local f1, f2, f3, f4, f5, f6 =
            fields[1], fields[2], fields[3], fields[4], fields[5], fields[6]
        local n1, n2, n3, n4, n5, n6 = f1.name, f2.name, f3.name, f4.name, f5.name, f6.name
        local lo1, lo2, lo3, lo4, lo5, lo6 =
            f1.node.minimum,
            f2.node.minimum,
            f3.node.minimum,
            f4.node.minimum,
            f5.node.minimum,
            f6.node.minimum
        local hi1, hi2, hi3, hi4, hi5, hi6 =
            f1.node.maximum,
            f2.node.maximum,
            f3.node.maximum,
            f4.node.maximum,
            f5.node.maximum,
            f6.node.maximum
        for i = 1, count do
            local item = value[i]
            if type(item) ~= "table" then
                return nil, "invalid_object"
            end
            local a, b, c, d, e, f = item[n1], item[n2], item[n3], item[n4], item[n5], item[n6]
            if a == nil or b == nil or c == nil or d == nil or e == nil or f == nil then
                return nil, "missing_field"
            end
            if
                type(a) ~= "number"
                or bit32.band(a, 255) ~= a
                or type(b) ~= "number"
                or bit32.band(b, 255) ~= b
                or type(c) ~= "number"
                or bit32.band(c, 255) ~= c
                or type(d) ~= "number"
                or bit32.band(d, 255) ~= d
                or type(e) ~= "number"
                or bit32.band(e, 255) ~= e
                or type(f) ~= "number"
                or bit32.band(f, 255) ~= f
                or (
                    not fullRange
                    and (
                        a < lo1
                        or a > hi1
                        or b < lo2
                        or b > hi2
                        or c < lo3
                        or c > hi3
                        or d < lo4
                        or d > hi4
                        or e < lo5
                        or e > hi5
                        or f < lo6
                        or f > hi6
                    )
                )
            then
                return nil, "invalid_integer"
            end
            buffer.writeu32(out, offset, a + b * 256 + c * 65536 + d * 16777216)
            buffer.writeu16(out, offset + 4, e + f * 256)
            offset += 6
        end
        return offset, nil
    end
    for i = 1, count do
        local item = value[i]
        if type(item) ~= "table" then
            return nil, "invalid_object"
        end
        for _, field in ipairs(fields) do
            local v = item[field.name]
            local node = field.node
            if v == nil then
                return nil, "missing_field"
            end
            if
                type(v) ~= "number"
                or v < node.minimum
                or v > node.maximum
                or v ~= math.floor(v)
            then
                return nil, "invalid_integer"
            end
            buffer.writeu8(out, offset, v)
            offset += 1
        end
    end
    return offset, nil
end

local function writePackedBooleanArray(
    out: buffer,
    offset: number,
    value: any,
    count: number
): (number?, string?)
    local full = math.floor(count / 8)
    for byte = 0, full - 1 do
        local first = byte * 8 + 1
        local a, b, c, d = value[first], value[first + 1], value[first + 2], value[first + 3]
        local e, f, g, h = value[first + 4], value[first + 5], value[first + 6], value[first + 7]
        local bits = 0
        if a == true then
            bits += 1
        elseif a ~= false then
            return nil, "expected_boolean"
        end
        if b == true then
            bits += 2
        elseif b ~= false then
            return nil, "expected_boolean"
        end
        if c == true then
            bits += 4
        elseif c ~= false then
            return nil, "expected_boolean"
        end
        if d == true then
            bits += 8
        elseif d ~= false then
            return nil, "expected_boolean"
        end
        if e == true then
            bits += 16
        elseif e ~= false then
            return nil, "expected_boolean"
        end
        if f == true then
            bits += 32
        elseif f ~= false then
            return nil, "expected_boolean"
        end
        if g == true then
            bits += 64
        elseif g ~= false then
            return nil, "expected_boolean"
        end
        if h == true then
            bits += 128
        elseif h ~= false then
            return nil, "expected_boolean"
        end
        buffer.writeu8(out, offset + byte, bits)
    end
    local tail = count % 8
    if tail ~= 0 then
        local bits = 0
        for bit = 0, tail - 1 do
            local v = value[full * 8 + bit + 1]
            if v == true then
                bits += 2 ^ bit
            elseif v ~= false then
                return nil, "expected_boolean"
            end
        end
        buffer.writeu8(out, offset + full, bits)
    end
    return offset + math.ceil(count / 8), nil
end

-- Cache only within a call; metatable callbacks can mutate earlier values.
local function plainBatch(values: { any }, records: boolean): boolean
    if getmetatable(values :: any) ~= nil then
        return false
    end
    local checked = {}
    for _, value in ipairs(values) do
        if not checked[value] then
            if getmetatable(value) ~= nil then
                return false
            end
            if records then
                for _, item in ipairs(value) do
                    if type(item) ~= "table" or getmetatable(item) ~= nil then
                        return false
                    end
                end
            end
            checked[value] = true
        end
    end
    return true
end

local function readFixedByteArray(
    data: buffer,
    offset: number,
    count: number,
    fields: { any },
    fullRange: boolean
): ({ any }?, string?)
    local out = table.create(count)
    if #fields == 6 then
        local f1, f2, f3, f4, f5, f6 =
            fields[1], fields[2], fields[3], fields[4], fields[5], fields[6]
        local n1, n2, n3, n4, n5, n6 = f1.name, f2.name, f3.name, f4.name, f5.name, f6.name
        for i = 1, count do
            local first = buffer.readu32(data, offset)
            local second = buffer.readu16(data, offset + 4)
            local v1 = bit32.band(first, 255)
            local v2 = bit32.band(bit32.rshift(first, 8), 255)
            local v3 = bit32.band(bit32.rshift(first, 16), 255)
            local v4 = bit32.rshift(first, 24)
            local v5 = bit32.band(second, 255)
            local v6 = bit32.rshift(second, 8)
            if
                not fullRange
                and (
                    v1 < f1.node.minimum
                    or v1 > f1.node.maximum
                    or v2 < f2.node.minimum
                    or v2 > f2.node.maximum
                    or v3 < f3.node.minimum
                    or v3 > f3.node.maximum
                    or v4 < f4.node.minimum
                    or v4 > f4.node.maximum
                    or v5 < f5.node.minimum
                    or v5 > f5.node.maximum
                    or v6 < f6.node.minimum
                    or v6 > f6.node.maximum
                )
            then
                return nil, "integer_out_of_range"
            end
            out[i] = {
                [n1] = v1,
                [n2] = v2,
                [n3] = v3,
                [n4] = v4,
                [n5] = v5,
                [n6] = v6,
            }
            offset += 6
        end
        return out, nil
    end
    for i = 1, count do
        local item = {}
        for _, field in ipairs(fields) do
            local v = buffer.readu8(data, offset)
            if v < field.node.minimum or v > field.node.maximum then
                return nil, "integer_out_of_range"
            end
            item[field.name] = v
            offset += 1
        end
        out[i] = item
    end
    return out, nil
end

function TransportCodec.compile(spec: any): (any?, string?)
    local root, err = compile(spec, 1)
    if not root then
        return nil, err
    end
    local fingerprint = hash(root.signature)
    local codec = { fingerprint = fingerprint, maximumBytes = root.maximumBytes }
    local byteFields = byteRecordFields(root)
    local packedBoolean = root.kind == "array" and root.packedBoolean == true
    local byteFieldsFullRange = true
    if byteFields then
        for _, field in ipairs(byteFields) do
            if field.node.minimum ~= 0 or field.node.maximum ~= 255 then
                byteFieldsFullRange = false
                break
            end
        end
    end
    function codec:encode(value: any): (buffer?, string?)
        if byteFields then
            if type(value) ~= "table" or #value < root.minimum or #value > root.maximum then
                return nil, "invalid_array"
            end
            local count = #value
            local prefix = if root.fixed then 0 else varUIntBytes(count)
            local out = buffer.create(prefix + count * #byteFields)
            local offset = if root.fixed then 0 else writeVarUInt(out, 0, count)
            local finish, e =
                writeFixedByteArray(out, offset, value, count, byteFields, byteFieldsFullRange)
            if not finish then
                return nil, e
            end
            return out, nil
        end
        local size, e = sizeOf(root, value)
        if not size then
            return nil, e
        end
        if size > MAX_BYTES then
            return nil, "payload_too_large"
        end
        local out = buffer.create(size)
        local finish = writeNode(root, value, out, 0)
        if finish ~= size then
            return nil, "encoder_length_mismatch"
        end
        return out, nil
    end
    local function encodeValueBatch(values: any, limits: any?, compact: boolean): (buffer?, string?)
        if type(values) ~= "table" then
            return nil, "invalid_batch"
        end
        local count = #values
        local maximumItems = if limits and limits.maximumItems then limits.maximumItems else 64
        local maximumItemBytes = if limits and limits.maximumItemBytes
            then limits.maximumItemBytes
            else MAX_BYTES
        local maximumPayloadBytes = if limits and limits.maximumPayloadBytes
            then limits.maximumPayloadBytes
            else 1024 * 1024
        if count < 1 or count > maximumItems or count > 65535 then
            return nil, "batch_item_count"
        end
        local keys = 0
        for key in values do
            if not integer(key) or key < 1 or key > count then
                return nil, "invalid_batch"
            end
            keys += 1
        end
        if keys ~= count then
            return nil, "invalid_batch"
        end
        local total = 2
        local sizes = table.create(count)
        local lengths = table.create(count) :: { number }
        local seen = {}
        local duplicates = {}
        local hasDuplicates = false
        for i = 1, count do
            local size: number = 0
            if byteFields or packedBoolean then
                local value = values[i]
                if type(value) ~= "table" or #value < root.minimum or #value > root.maximum then
                    return nil, "invalid_array"
                end
                local length = #value
                size = (
                    if packedBoolean
                        then math.ceil(length / 8)
                        else length * #(byteFields :: { any })
                )
                    + if root.fixed then 0 else varUIntBytes(length)
                lengths[i] = length
                if seen[value] then
                    duplicates[value] = true
                    hasDuplicates = true
                else
                    seen[value] = true
                end
            else
                local calculated, sizeError = sizeOf(root, values[i])
                if not calculated then
                    return nil, sizeError
                end
                size = calculated
            end
            if compact and size < 1 then
                return nil, "compact_zero_size_item"
            end
            if size > maximumItemBytes then
                return nil, "batch_item_invalid"
            end
            total += size + (if compact then 0 else 4)
            if total > maximumPayloadBytes then
                return nil, "batch_too_large"
            end
            sizes[i] = size
        end
        local out = buffer.create(total)
        buffer.writeu16(out, 0, count)
        local offset = 2
        local memo = if hasDuplicates and plainBatch(values, byteFields ~= nil) then {} else nil
        for i = 1, count do
            if not compact then
                buffer.writeu32(out, offset, sizes[i])
                offset += 4
            end
            local itemStart = offset
            local finish: number = offset
            local value = values[i]
            local previous = if memo then memo[value] else nil
            if previous then
                buffer.copy(out, offset, out, previous, sizes[i])
                finish = offset + sizes[i]
            elseif byteFields or packedBoolean then
                if not root.fixed then
                    offset = writeVarUInt(out, offset, lengths[i])
                end
                local endOffset, writeError
                if packedBoolean then
                    endOffset, writeError = writePackedBooleanArray(out, offset, value, lengths[i])
                else
                    endOffset, writeError = writeFixedByteArray(
                        out,
                        offset,
                        value,
                        lengths[i],
                        byteFields :: { any },
                        byteFieldsFullRange
                    )
                end
                if not endOffset then
                    return nil, writeError
                end
                finish = endOffset
            else
                finish = writeNode(root, values[i], out, offset)
            end
            if finish ~= itemStart + sizes[i] then
                return nil, "encoder_length_mismatch"
            end
            if memo and duplicates[value] then
                memo[value] = itemStart
            end
            offset = finish
        end
        return out, nil
    end
    function codec:encodeBatch(values: any, limits: any?): (buffer?, string?)
        return encodeValueBatch(values, limits, false)
    end
    function codec:encodeCompactBatch(values: any, limits: any?): (buffer?, string?)
        return encodeValueBatch(values, limits, true)
    end
    function codec:decode(data: any): (boolean, any?, string?)
        if typeof(data) ~= "buffer" then
            return false, nil, "payload_must_be_buffer"
        end
        if buffer.len(data) > root.maximumBytes then
            return false, nil, "payload_too_large"
        end
        if byteFields then
            local reader = { data = data, offset = 0, length = buffer.len(data) }
            local count = root.maximum
            if not root.fixed then
                local parsed, e = readVarUInt(reader)
                if parsed == nil then
                    return false, nil, e
                end
                count = parsed
            end
            if count < root.minimum or count > root.maximum then
                return false, nil, "invalid_array_length"
            end
            if reader.offset + count * #byteFields ~= reader.length then
                return false, nil, "truncated"
            end
            local value, e =
                readFixedByteArray(data, reader.offset, count, byteFields, byteFieldsFullRange)
            if not value then
                return false, nil, e
            end
            return true, value, nil
        end
        local reader = { data = data, offset = 0, length = buffer.len(data) }
        local value, e = readNode(root, reader)
        if e then
            return false, nil, e
        end
        if reader.offset ~= reader.length then
            return false, nil, "trailing_bytes"
        end
        return true, value, nil
    end
    function codec:decodeBatch(data: any, limits: any?, region: any?): (boolean, any?, string?)
        if typeof(data) ~= "buffer" or (region ~= nil and type(region) ~= "table") then
            return false, nil, "invalid_batch"
        end
        local dataLength = buffer.len(data)
        local start = if region then region.offset else 0
        local length = if region then region.length else dataLength
        if
            not integer(start)
            or not integer(length)
            or start < 0
            or length < 2
            or start > dataLength - length
        then
            return false, nil, "invalid_batch"
        end
        local finish = start + length
        local count = buffer.readu16(data, start)
        local maximumItems = if limits and limits.maximumItems then limits.maximumItems else 64
        local maximumItemBytes = if limits and limits.maximumItemBytes
            then limits.maximumItemBytes
            else MAX_BYTES
        local maximumPayloadBytes = if limits and limits.maximumPayloadBytes
            then limits.maximumPayloadBytes
            else 1024 * 1024
        if count < 1 or count > maximumItems then
            return false, nil, "batch_item_count"
        end
        if length > maximumPayloadBytes then
            return false, nil, "batch_too_large"
        end
        local values = table.create(count)
        local reader = { data = data, offset = start + 2, length = finish }
        for i = 1, count do
            if reader.offset > finish - 4 then
                return false, nil, "truncated_batch"
            end
            local size = buffer.readu32(data, reader.offset)
            reader.offset += 4
            if
                size > maximumItemBytes
                or size > root.maximumBytes
                or reader.offset > finish - size
            then
                return false, nil, "invalid_batch_item"
            end
            if byteFields then
                reader.length = reader.offset + size
                local itemCount = root.maximum
                if not root.fixed then
                    local parsed, e = readVarUInt(reader)
                    if parsed == nil then
                        return false, nil, e
                    end
                    itemCount = parsed
                end
                if itemCount < root.minimum or itemCount > root.maximum then
                    return false, nil, "invalid_array_length"
                end
                if reader.offset + itemCount * #byteFields ~= reader.length then
                    return false, nil, "invalid_batch_item"
                end
                local value, e = readFixedByteArray(
                    data,
                    reader.offset,
                    itemCount,
                    byteFields,
                    byteFieldsFullRange
                )
                if not value then
                    return false, nil, e
                end
                values[i] = value
                reader.offset = reader.length
                reader.length = finish
            else
                reader.length = reader.offset + size
                local value, e = readNode(root, reader)
                if e then
                    return false, nil, e
                end
                if value == nil then
                    return false, nil, "invalid_batch_item"
                end
                if reader.offset ~= reader.length then
                    return false, nil, "trailing_bytes"
                end
                values[i] = value
                reader.length = finish
            end
        end
        if reader.offset ~= finish then
            return false, nil, "trailing_batch_bytes"
        end
        return true, values, nil
    end
    function codec:decodeCompactBatch(
        data: any,
        limits: any?,
        region: any?
    ): (boolean, any?, string?)
        if typeof(data) ~= "buffer" or (region ~= nil and type(region) ~= "table") then
            return false, nil, "invalid_batch"
        end
        local dataLength = buffer.len(data)
        local start = if region then region.offset else 0
        local length = if region then region.length else dataLength
        if
            not integer(start)
            or not integer(length)
            or start < 0
            or length < 2
            or start > dataLength - length
        then
            return false, nil, "invalid_batch"
        end
        local finish = start + length
        local count = buffer.readu16(data, start)
        local maximumItems = if limits and limits.maximumItems then limits.maximumItems else 64
        local maximumItemBytes = if limits and limits.maximumItemBytes
            then limits.maximumItemBytes
            else MAX_BYTES
        local maximumPayloadBytes = if limits and limits.maximumPayloadBytes
            then limits.maximumPayloadBytes
            else 1024 * 1024
        if count < 1 or count > maximumItems then
            return false, nil, "batch_item_count"
        end
        if length > maximumPayloadBytes then
            return false, nil, "batch_too_large"
        end
        local values = table.create(count)
        local reader = { data = data, offset = start + 2, length = finish }
        for i = 1, count do
            local itemStart = reader.offset
            if byteFields then
                local itemCount = root.maximum
                if not root.fixed then
                    local parsed, e = readVarUInt(reader)
                    if parsed == nil then
                        return false, nil, e
                    end
                    itemCount = parsed
                end
                if itemCount < root.minimum or itemCount > root.maximum then
                    return false, nil, "invalid_array_length"
                end
                local itemBytes = itemCount * #byteFields
                if not need(reader, itemBytes) then
                    return false, nil, "truncated_batch"
                end
                local item, e = readFixedByteArray(
                    data,
                    reader.offset,
                    itemCount,
                    byteFields,
                    byteFieldsFullRange
                )
                if not item then
                    return false, nil, e
                end
                reader.offset += itemBytes
                values[i] = item
            else
                local item, e = readNode(root, reader)
                if e then
                    return false, nil, e
                end
                if item == nil then
                    return false, nil, "invalid_batch_item"
                end
                values[i] = item
            end
            if
                reader.offset == itemStart
                or reader.offset - itemStart > maximumItemBytes
                or reader.offset - itemStart > root.maximumBytes
            then
                return false, nil, "invalid_batch_item"
            end
        end
        if reader.offset ~= finish then
            return false, nil, "trailing_batch_bytes"
        end
        return true, values, nil
    end
    return table.freeze(codec), nil
end

return TransportCodec
