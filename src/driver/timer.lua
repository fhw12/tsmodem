local bit = require "bit"
local uci = require "luci.model.uci".cursor()
local util = require "luci.util"
local log = require "tsmodem.util.log"
local uloop = require "uloop"
local flist = require "tsmodem.util.filelist"
local nixio = require "nixio"


local M = require 'posix.termio'
local F = require 'posix.fcntl'
local U = require 'posix.unistd'


require "tsmodem.driver.util"

local CREG_STATE = require "tsmodem.constants.creg_state"
local balance_event_keys = require "tsmodem.constants.balance_event_keys"


local timer = {}
timer.modem = nil
timer.state = nil
timer.notifier = nil

timer.interval = {
    general = 1400,     -- use 3000 interval in debug mode
    reg = 3000,         -- Sim registration state (checking interval)
    cpin = 3000,        -- Sim inserted or not?
    signal = 4000,      -- Signal strength (checking interval)
    balance = 18000,    -- Balance value (checking interval) - 60 sec. minimum to avoid Provider blocking USSD
    netmode = 5000,     -- 4G/3G mode state (checking interval)
    provider = 6000,    -- GSM provider name (autodetection checking interval)

    last_balance_request_time = os.time(),  -- Helper. Need to avoid doing USSD requests too often.
    balance_repeated_request_delay = 125,   -- If GSM opeator doen't send back the balance USSD-response
                                            -- then we should wait 1..2 mins before repeating
}

timer.timeout = {
    balance = 60000      -- Once a balance USSD requested, "in progress" state is set on "tsmodem.driver balance" method.
}                       -- Then, if by some reason provider will not respond to the balance USSD request,
                        -- then we clear balance state after the timeout.


timer.init = function(modem, state, notifier)
    timer.modem = modem
    timer.state = state
    timer.notifier = notifier
    return timer
end

--[[ General driver timer ]]
function t_general()
    timer.modem:init()
    timer.modem:poll()
    timer.general:set(timer.interval.general)
end
timer.general = uloop.timer(t_general)

-- [[ AT+CREG requests interval ]]
function t_CREG()
    if timer.modem.lock.is_automation() then
        local SWITCHING = (timer.state:get("switching", "value") == "true")
        if not SWITCHING then
            if(timer.modem:is_connected(timer.modem.fds)) then
                if_debug("reg", "AT", "ASK", "AT+CREG?", "[timer.lua]: t_CREG() every " .. tostring(timer.interval.reg).."ms. when SWITCHING == " .. tostring(SWITCHING) .. " and modem:is_connected().")
                local chunk, err, errcode = U.write(timer.modem.fds, "AT+CREG?" .. "\r\n")
            end
        end
    end
    timer.CREG:set(timer.interval.reg)
end
timer.CREG = uloop.timer(t_CREG)

-- [[ AT+CPIN? requests interval ]]
function t_CPIN()
    if timer.modem.lock.is_automation() then
        local SWITCHING = (timer.state:get("switching", "value") == "true")
        if not SWITCHING then
            if(timer.modem:is_connected(timer.modem.fds)) then
                if_debug("cpin", "AT", "ASK", "AT+CPIN?", "[timer.lua]: t_CPIN() every " .. tostring(timer.interval.cpin).."ms")
                local chunk, err, errcode = U.write(timer.modem.fds, "AT+CPIN?" .. "\r\n")
            end
        end
    end
    timer.CPIN:set(timer.interval.cpin)
end
timer.CPIN = uloop.timer(t_CPIN)

-- [[ AT+CSQ requests interval ]]
function t_CSQ()
    if timer.modem.lock.is_automation() then
        local SWITCHING = (timer.state:get("switching", "value") == "true")
        if not SWITCHING then
            if(timer.modem:is_connected(timer.modem.fds)) then
                if_debug("signal", "AT", "ASK", "AT+CSQ", "[timer.lua]: t_CSQ() every " .. tostring(timer.interval.signal).."ms")
                local chunk, err, errcode = U.write(timer.modem.fds, "AT+CSQ" .. "\r\n")
            end
        end
    end
    timer.CSQ:set(timer.interval.signal)
end
timer.CSQ = uloop.timer(t_CSQ)

-- [[ AT+COPS: get GSM provider name from the GSM network ]]
function t_COPS()
    if timer.modem.lock.is_automation() then
        local SWITCHING = (timer.state:get("switching", "value") == "true")
        if not SWITCHING then
            if(timer.modem:is_connected(timer.modem.fds)) then
                if_debug("provider", "AT", "ASK", "AT+COPS?", "[timer.lua]: t_COPS() every " .. tostring(timer.interval.provider).."ms")
                local chunk, err, errcode = U.write(timer.modem.fds, "AT+COPS?" .. "\r\n")
            end
        end
    end
    timer.COPS:set(timer.interval.provider)
end
timer.COPS = uloop.timer(t_COPS)


--[[ Get 3G/4G mode from the GSM network ]]
function t_CNSMOD()
    if timer.modem.lock.is_automation() then
        local SWITCHING = (timer.state:get("switching", "value") == "true")
        if not SWITCHING then
            if(timer.modem:is_connected(timer.modem.fds)) then
                local _,_,reg = timer.state:get("reg", "value")
                if reg == "1" then
                    if (timer.modem.debug and (timer.modem.debug_type == "netmode" or timer.modem.debug_type == "all")) then print("AT sends: ","AT+CNSMOD?") end
                    if_debug("netmode", "AT", "ASK", "AT+CNSMOD?", "[timer.lua]: t_CNSMOD() every " .. tostring(timer.interval.netmode).."ms")

                    local chunk, err, errcode = U.write(timer.modem.fds, "AT+CNSMOD?" .. "\r\n")
                end
            end
        end
    end
    timer.CNSMOD:set(timer.interval.netmode)
end
timer.CNSMOD = uloop.timer(t_CNSMOD)


--[[ Balance request timeout ]]
function t_BAL_TIMEOUT()
    local noerror, errmsg, val = timer.state:get("balance", "value")
    if val == "*" then
        timer.state:update("balance", "", "", "")
        if (timer.modem.debug and (timer.modem.debug_type == "balance" or timer.modem.debug_type == "all")) then
            print(string.format("[timer.lua]: Clear balance on BAL_TIMEOUT: %s %s %s", tostring(noerror), tostring(errmsg), tostring(val)))
        end
    end
end
timer.BAL_TIMEOUT = uloop.timer(t_BAL_TIMEOUT)


return timer
