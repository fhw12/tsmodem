local text_decoder = require "tsmodem.util.text_decoder"

local pdu_decoder = {}

function pdu_decoder.parse(msg)
    local p = 1

    local smsc_length = msg:sub(p, p + 1)
    p = p + 2

    local smsc_address_type = msg:sub(p, p + 1)
    p = p + 2

    local service_center_number = "+"
    for i = 0, tonumber(smsc_length, 16) - 2 do
        local digits = msg:sub(p, p + 1)
        p = p + 2

        local first_digit = digits:sub(2, 2)
        local second_digit = digits:sub(1, 1)

        if i == tonumber(smsc_length, 16) - 2 then
            second_digit = ""
        end

        service_center_number = service_center_number .. first_digit .. second_digit
    end

    local message_type = msg:sub(p, p + 1)
    p = p + 2

    local sender_address_length = msg:sub(p, p + 1)
    p = p + 2

    local sender_address_type = msg:sub(p, p + 1)
    p = p + 2

    local sender_number = ""
    if sender_address_type == "91" or sender_address_type == "81" then
        if sender_address_type == "91" then
            sender_number = "+"
        end

        for i = 0, math.ceil(tonumber(sender_address_length, 16) / 2) - 1 do
            local digits = msg:sub(p, p + 1)
            p = p + 2

            local first_digit = digits:sub(2, 2)
            local second_digit = digits:sub(1, 1)

            if i == math.ceil(tonumber(sender_address_length, 16) / 2) - 1 and second_digit == "F" then
                second_digit = ""
            end

            sender_number = sender_number .. first_digit .. second_digit
        end
    elseif sender_address_type == "D0" then
        for i = 0, math.ceil(tonumber(sender_address_length, 16) / 2) - 1 do
            local digits = msg:sub(p, p + 1)
            sender_number = sender_number .. digits:sub(1, 2)
            p = p + 2
        end

        sender_number = text_decoder.gsm7bit_to_text(sender_number)
    end

    local protocol_identifier = msg:sub(p, p + 1)
    p = p + 2

    local data_coding_scheme = msg:sub(p, p + 1)
    p = p + 2

    local date = {
        text = "",
        year = "",
        month = "",
        day = "",
        hours = "",
        minutes = "",
        seconds = "",
        time_zone = "",
    }

    for i = 0, 6 do
        local digits = msg:sub(p, p + 1)
        local date_number = digits:sub(2, 2) .. digits:sub(1, 1)
        p = p + 2

        if i == 0 then
            date.year = date_number
        elseif i == 1 then
            date.month = date_number
        elseif i == 2 then
            date.day = date_number
        elseif i == 3 then
            date.hours = date_number
        elseif i == 4 then
            date.minutes = date_number
        elseif i == 5 then
            date.seconds = date_number
        elseif i == 6 then
            date.time_zone = date_number
        end
    end
    date.text = date.day .. '.' .. date.month .. '.' .. date.year .. ' ' .. date.hours .. ':' .. date.minutes .. ':' .. date.seconds .. ' ' .. 'GMT+' .. tostring(tonumber(date.time_zone, 10) * 15 / 60)

    local user_data_length = msg:sub(p, p + 1)
    p = p + 2

    local message_hex = msg:sub(p, #msg)

    local message_text = ""
    if data_coding_scheme == "08" then
        message_text = text_decoder.utf16be_to_utf8(message_hex)
    elseif data_coding_scheme == "00" then
        message_text = text_decoder.gsm7bit_to_text(message_hex)
    end

    return {
        smsc_length = smsc_length,
        smsc_address_type = smsc_address_type,
        service_center_number = service_center_number,
        message_type = message_type,
        sender_address_length = sender_address_length,
        sender_address_type = sender_address_type,
        sender_number = sender_number,
        protocol_identifier = protocol_identifier,
        data_coding_scheme = data_coding_scheme,
        date = date,
        user_data_length = user_data_length,
        message_hex = message_hex,
        message_text = message_text,
    }
end

return pdu_decoder