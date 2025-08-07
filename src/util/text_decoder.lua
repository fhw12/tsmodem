local text_decoder = {}

-- Convert a hex string (e.g., "0041") into a raw byte string (e.g., "\x00\x41")
local function fromhex(hex)
    return (hex:gsub('..', function(pair)
        return string.char(tonumber(pair, 16))
    end))
end

-- Convert a single Unicode codepoint into UTF-8 bytes and add to the output
local function encode_utf8(codepoint, out)
    if codepoint < 0x80 then
        -- 1-byte UTF-8 encoding
        out[#out+1] = string.char(codepoint)
    elseif codepoint < 0x800 then
        -- 2-byte UTF-8 encoding
        out[#out+1] = string.char(0xC0 + math.floor(codepoint / 0x40))
        out[#out+1] = string.char(0x80 + (codepoint % 0x40))
    else
        -- 3-byte UTF-8 encoding
        out[#out+1] = string.char(0xE0 + math.floor(codepoint / 0x1000))
        out[#out+1] = string.char(0x80 + (math.floor(codepoint / 0x40) % 0x40))
        out[#out+1] = string.char(0x80 + (codepoint % 0x40))
    end
end

-- Convert a UTF-16BE byte string into a UTF-8 string
-- Supports both basic characters and special high-low code unit pairs for emojis and other symbols
function text_decoder.utf16be_to_utf8(packed_hex)
    local bytes = fromhex(packed_hex)
    local out = {}      -- List of UTF-8 bytes
    local i = 1         -- Current position in the byte string

    while i + 1 <= #bytes do
        -- Read two bytes and combine into a 16-bit code unit
        local first_byte = string.byte(bytes, i)
        local second_byte = string.byte(bytes, i + 1)
        local codeunit = first_byte * 256 + second_byte

        -- Check if it's the start of a high surrogate (used for emojis and symbols outside the BMP)
        if codeunit >= 0xD800 and codeunit <= 0xDBFF and i + 3 <= #bytes then
            -- Read the next 16-bit code unit (low surrogate)
            local next_first_byte = string.byte(bytes, i + 2)
            local next_second_byte = string.byte(bytes, i + 3)
            local next_codeunit = next_first_byte * 256 + next_second_byte

            -- If the second unit is in the low surrogate range, combine both to get the full codepoint
            if next_codeunit >= 0xDC00 and next_codeunit <= 0xDFFF then
                local unicode_codepoint = 0x10000 + ((codeunit - 0xD800) * 0x400) + (next_codeunit - 0xDC00)

                -- Convert to 4-byte UTF-8
                out[#out+1] = string.char(0xF0 + math.floor(unicode_codepoint / 0x40000))
                out[#out+1] = string.char(0x80 + (math.floor(unicode_codepoint / 0x1000) % 0x40))
                out[#out+1] = string.char(0x80 + (math.floor(unicode_codepoint / 0x40) % 0x40))
                out[#out+1] = string.char(0x80 + (unicode_codepoint % 0x40))

                i = i + 4  -- Move past both 16-bit units
            else
                -- If not a valid pair, treat the first as a normal character
                encode_utf8(codeunit, out)
                i = i + 2
            end
        else
            -- Regular 16-bit character in the Basic Multilingual Plane (BMP)
            encode_utf8(codeunit, out)
            i = i + 2
        end
    end

    return table.concat(out)
end

-- Bitwise shift helpers using math
local function lshift(x, n)
    return (x * 2^n) % 256
  end

local function rshift(x, n)
    return math.floor(x / 2^n)
end

local function band(a, b)
    local result = 0
    for i = 0, 7 do
        local bit_a = a % 2
        local bit_b = b % 2
        if bit_a == 1 and bit_b == 1 then
        result = result + 2^i
        end
        a = math.floor(a / 2)
        b = math.floor(b / 2)
    end
    return result
end

local function bor(a, b)
    local result = 0
    for i = 0, 7 do
        local bit_a = a % 2
        local bit_b = b % 2
        if bit_a == 1 or bit_b == 1 then
        result = result + 2^i
        end
        a = math.floor(a / 2)
        b = math.floor(b / 2)
    end
    return result
end

-- GSM 7-bit decoding function
function text_decoder.gsm7bit_to_text(packed_hex)
    local bytes = {}
    for i = 1, #packed_hex, 2 do
        table.insert(bytes, tonumber(packed_hex:sub(i, i+1), 16))
    end

    local septets = {}
    local carry_over = 0
    local carry_over_bits = 0

    for i = 1, #bytes do
        local current = bytes[i]
        local shifted = lshift(current, carry_over_bits)
        local septet = band(bor(shifted, carry_over), 0x7F)
        table.insert(septets, septet)

        carry_over = rshift(current, 7 - carry_over_bits)
        carry_over_bits = carry_over_bits + 1

        if carry_over_bits == 7 then
        table.insert(septets, carry_over)
        carry_over_bits = 0
        carry_over = 0
        end
    end

    -- GSM 7-bit default alphabet
    local gsm7bit_table = {
        [0] = '@', '£', '$', '¥', 'è', 'é', 'ù', 'ì', 'ò', 'Ç', '\n', 'Ø', 'ø', '\r', 'Å', 'å',
        'Δ', '_', 'Φ', 'Γ', 'Λ', 'Ω', 'Π', 'Ψ', 'Σ', 'Θ', 'Ξ', '', 'Æ', 'æ', 'ß', 'É',
        ' ', '!', '"', '#', '¤', '%', '&', '\'', '(', ')', '*', '+', ',', '-', '.', '/',
        '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', ':', ';', '<', '=', '>', '?',
        '¡', 'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M', 'N', 'O',
        'P', 'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z', 'Ä', 'Ö', 'Ñ', 'Ü', '§',
        '¿', 'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j', 'k', 'l', 'm', 'n', 'o',
        'p', 'q', 'r', 's', 't', 'u', 'v', 'w', 'x', 'y', 'z', 'ä', 'ö', 'ñ', 'ü', 'à'
    }

    local result = {}
    for _, septet in ipairs(septets) do
        table.insert(result, gsm7bit_table[septet] or '?')
    end

    return table.concat(result)
end

return text_decoder