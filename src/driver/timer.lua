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
timer.stm = nil
timer.notifier = nil

timer.interval = {
    general = 1400,     -- use 3000 interval in debug mode
    reg = 3000,         -- Sim registration state (checking interval)
    cpin = 3000,        -- Sim inserted or not?
    signal = 4000,      -- Signal strength (checking interval)
    balance = 18000,    -- Balance value (checking interval) - 60 sec. minimum to avoid Provider blocking USSD
    netmode = 5000,     -- 4G/3G mode state (checking interval)
    provider = 6000,    -- GSM provider name (autodetection checking interval)
    ping = 4000,        -- Ping GSM network (checking interval)
    sim = 3000,         -- Get what slot is active. It runs only if active slot was not detected by some reason

    last_balance_request_time = os.time(),  -- Helper. Need to avoid doing USSD requests too often.
    balance_repeated_request_delay = 125,   -- If GSM opeator doen't send back the balance USSD-response
                                            -- then we should wait 1..2 mins before repeating
}

timer.timeout = {
    balance = 60000      -- Once a balance USSD requested, "in progress" state is set on "tsmodem.driver balance" method.
}                       -- Then, if by some reason provider will not respond to the balance USSD request,
                        -- then we clear balance state after the timeout.

--[[ Step-by-step delays of switching Sim-card process ]]
timer.switch_delay = {
    ["1_MDM_UNPOLL"] = 100,     -- Stop modem polling since ubus call tsmodem.driver do_switch runs
    ["2_STM_SIM_SEL"] = 200,    -- Select Sim-card by STM32 since modem unpolled
    ["3_STM_SIM_EN_0"] = 2000,
    ["4_STM_SIM_EN_1"] = 2000,
    ["5_STM_SIM_PWR_0"] = 2000,
    ["6_MDM_REPEAT_POLL"] = 2000,-- Start modem polling since STM32 RST 1 send
    ["7_MDM_END_SWITCHING"] = 1000,
}

--[[ Step-by-step delays of resetting USB-modem ]]
timer.reset_delay = {
    ["1_MDM_UNPOLL"] = 100,     -- Stop modem polling since ubus call tsmodem.driver do_switch runs
    ["2_STM_SIM_EN_0"] = 2000,
    ["3_STM_SIM_EN_1"] = 2000,
    ["4_STM_SIM_PWR_0"] = 2000,
    ["5_MDM_REPEAT_POLL"] = 2000,
}

timer.init = function(modem, state, stm, notifier)
    timer.modem = modem
    timer.state = state
    timer.stm = stm
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


-- [[ PING Google to check internet connection ]]
function t_PING()
    function p1(r) --[[ call back is empty as not needed now. ]]   end

    local ok, err, reg = timer.modem.state:get("reg", "value")
    local _,_,sim_id = timer.state:get("sim", "value")
    local host = uci:get("tsmodem", "default", "ping_host") or '8.8.8.8'
    local host_spc_sim = string.format("%s %s", tostring(host), tostring(sim_id))

    if timer.modem.lock.is_automation() then
        if(reg =="1") then
            local SWITCHING = (timer.state:get("switching", "value") == "true")
            if not SWITCHING then
                if_debug("ping", "PING", "ASK", "ping.sh --host " .. host_spc_sim, "[timer.lua]: t_PING() every " .. tostring(timer.interval.ping).."ms. for simid: #" .. tostring(sim_id))

                uloop.process("/usr/lib/lua/tsmodem/util/ping.sh", {"--host", host_spc_sim }, {"PROCESS=1"}, p1)
                timer.PING:set(timer.interval.ping)
            else
                if_debug("ping", "PING", "SKIP", "ping.sh --host " .. host_spc_sim, "[timer.lua]: t_PING() skipping as SWITCHING == true")
                timer.PING:set(timer.interval.ping)
            end
        else
            if_debug("ping", "PING", "SKIP", "ping.sh --host " .. host_spc_sim, "[timer.lua]: t_PING() skipping as REG not equal 1")
            timer.PING:set(timer.interval.ping)
        end
    else
        if_debug("ping", "PING", "SKIP", "ping.sh --host " .. host_spc_sim, "[timer.lua]: t_PING() skipping as timer.modem.lock.is_automation() is not equal 'true'")
        timer.PING:set(timer.interval.ping)
    end
end
timer.PING = uloop.timer(t_PING)


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


--[[ Switch Sim: Unpoll modem ]]
function t_SWITCH_1()
    if timer.modem.lock.is_automation() then
        if (timer.modem.debug) then print("----------- t_SWITCH_1_START ----------" .. os.date()) end

        timer.state:update("switching", "true", "", "")

        local resp, n = {}, 0
        local res, sim_id = timer.stm:command("~0:SIM.SEL=?")
        if res == "OK" then
            timer.state:update("sim", tostring(sim_id), "~0:SIM.SEL=?")
            if_debug("", "STM", "ANSWER", "OK", "[timer.lua]: t_SWITCH_1() slot ID: " .. tostring(sim_id))
        else
            if_debug("", "STM", "ANSWER", "ERROR", "[timer.lua]: t_SWITCH_1() ~0:SIM.SEL=?")
        end

        if timer.modem.fds then
            timer.modem.unpoll()
            U.close(timer.modem.fds)
        end

        timer.SWITCH_2:set(timer.switch_delay["2_STM_SIM_SEL"])
    end
end
timer.SWITCH_1 = uloop.timer(t_SWITCH_1)

--[[ Switch Sim: Select sim card ]]
function t_SWITCH_2()
    local _,_,current_sim = timer.state:get("sim", "value")
    local sim_to_switch = ""
    if (timer.modem.debug) then print("----------- t_SWITCH_2 ----------" .. os.date()) end

    if(current_sim == "0") then
        sim_to_switch = "1"
    elseif(current_sim == "1") then
        sim_to_switch = "0"
    else
        -- If active slot was not detected by some reason
        -- then repeat switching process again
        timer.SWITCH_1:set(timer.switch_delay["1_MDM_UNPOLL"])
        return
    end

    if_debug("", "STM", "ASK", "~0:SIM.SEL=" .. sim_to_switch, "[timer.lua]: t_SWITCH_2() selects slot: #"..sim_to_switch)

    local res, val = timer.stm:command("~0:SIM.SEL=" .. sim_to_switch)
    if ("OK" == res) then
        timer.state:update("switching", "true", "", "")
        timer.state:update("sim", sim_to_switch, "~0:SIM.SEL=" .. sim_to_switch, "")
        timer.state:update("stm32", "OK", "~0:SIM.SEL=" .. sim_to_switch, "")
        timer.state:update("reg", CREG_STATE["SWITCHING"], "AT+CREG?", "")
    	timer.state:update("signal", "", "", "")
    	timer.state:update("balance", "", "", "")
    	timer.state:update("netmode", "", "", "")
    	timer.state:update("provider_name", "", "", "")
    	timer.state:update("ping", "", "", "")
        timer.state:update("cpin", "", "", "")
        timer.state.ping.time = "0"

        local provider_id = get_provider_id(sim_to_switch)
        local apn = uci:get(timer.modem.config_gsm, provider_id, "gate_address") or "internet"
        uci:set("network", "tsmodem", "apn", apn)
        uci:save("network")
        uci:commit("network")

        if_debug("", "STM", "ANSWER", "OK", "[timer.lua]: t_SWITCH_2() ~0:SIM.SEL=" .. tostring(sim_to_switch))

        timer.SWITCH_3:set(timer.switch_delay["3_STM_SIM_EN_0"])
    else
        if_debug("", "STM", "ANSWER", "ERROR", "[timer.lua]: t_SWITCH_2() ~0:SIM.SEL=" .. tostring(sim_to_switch) .. ". BREAK SWTICHING")
    end
end
timer.SWITCH_2 = uloop.timer(t_SWITCH_2)


--[[ Switch Sim: EN=0 ]]
function t_SWITCH_3()
    if (timer.modem.debug) then print("----------- t_SWITCH_3 ----------" .. os.date()) end
    timer.state:update("switching", "true", "", "")

    local res, val = timer.stm:command("~0:SIM.EN=0")
    if "OK" == res then
        timer.state:update("stm32", "OK", "~0:SIM.EN=0", "")
        if_debug("", "STM", "ANSWER", "OK", "[timer.lua]: t_SWITCH_3() ~0:SIM.EN=0")

        timer.SWITCH_4:set(timer.switch_delay["4_STM_SIM_EN_1"])
    else
        timer.state:update("stm32", "ERROR", "~0:SIM.EN=0", "")
        if_debug("", "STM", "ANSWER", "ERROR", "[timer.lua]: t_SWITCH_3() ~0:SIM.EN=0. BREAK SWITCHING")
    end

end
timer.SWITCH_3 = uloop.timer(t_SWITCH_3)

--[[ Switch Sim: EN=1 ]]
function t_SWITCH_4()
    if (timer.modem.debug) then print("----------- t_SWITCH_4 ----------" .. os.date()) end
    timer.state:update("switching", "true", "", "")

    local res, val = timer.stm:command("~0:SIM.EN=1")
    if "OK" == res then
        timer.state:update("stm32", "OK", "~0:SIM.EN=1", "")
        if_debug("", "STM", "ANSWER", "OK", "[timer.lua]: t_SWITCH_4() ~0:SIM.EN=1")

        timer.SWITCH_5:set(timer.switch_delay["5_STM_SIM_PWR_0"])
    else
        timer.state:update("stm32", "ERROR", "~0:SIM.EN=0", "")
        if_debug("", "STM", "ANSWER", "ERROR", "[timer.lua]: t_SWITCH_4() ~0:SIM.EN=1. BREAK SWITCHING")
    end

end
timer.SWITCH_4 = uloop.timer(t_SWITCH_4)


--[[ Switch Sim: PWR=0 ]]
function t_SWITCH_5()
    if (timer.modem.debug) then print("----------- t_SWITCH_5 ----------" .. os.date()) end
    timer.state:update("switching", "true", "", "")

    local res, val = timer.stm:command("~0:SIM.PWR=0")
    if "OK" == res then
        timer.state:update("stm32", "OK", "~0:SIM.PWR=0", "")
        if_debug("", "STM", "ANSWER", "OK", "[timer.lua]: t_SWITCH_5() ~0:SIM.PWR=0")

        timer.SWITCH_6:set(timer.switch_delay["6_MDM_REPEAT_POLL"])
    else
        timer.state:update("stm32", "ERROR", "~0:SIM.PWR=0", "")
        if_debug("", "STM", "ANSWER", "ERROR", "[timer.lua]: t_SWITCH_5() ~0:SIM.PWR=0. BREAK SWITCHING")
    end

end
timer.SWITCH_5 = uloop.timer(t_SWITCH_5)


--[[ Switch Sim: delay before repeat modem polling ]]
function t_SWITCH_6()
    if (timer.modem.debug) then print("----------- t_SWITCH_6 ----------" .. os.date()) end
    timer.state:update("switching", "true", "", "")
    timer.modem:init()

    if_debug("", "FILE", "POLL", "", "[timer.lua]: t_SWITCH_6() modem:init()")

    timer.SWITCH_7:set(timer.switch_delay["7_MDM_END_SWITCHING"])
end
timer.SWITCH_6 = uloop.timer(t_SWITCH_6)

--[[ Switch Sim: End of switching ]]
function t_SWITCH_7()
    timer.state:update("switching", "false", "", "")
    if (timer.modem.debug) then print("----------- SWITCH_7_END ---------- " .. os.date()) end

end
timer.SWITCH_7 = uloop.timer(t_SWITCH_7)

-- --[[ Get active slot periodically ]]
function t_WHAT_SLOT()
    --if timer.modem.automation_mode.normal == true then
    -- if timer.modem.automation == "run" then
    if timer.modem.lock.is_automation() then
        local _,errmsg,switch_started = (timer.state:get("switching", "value") ~= "false")
        if_debug("sim", "switch_started", "switching", "[timer.lua]: t_WHAT_SLOT() switch_started: " .. tostring(switch_started), "")

        if (not switch_started) then
            local resp, n = {}, 0
            local res, sim_id = timer.stm:command("~0:SIM.SEL=?")
            if (res == "OK" and tonumber(sim_id)) then
                timer.state:update("sim", tostring(sim_id), "~0:SIM.SEL=?")
                if_debug("sim", "STM", "ANSWER", "OK", "[timer.lua]: t_SWITCH_1() slot ID: " .. tostring(sim_id))
            else
                if_debug("sim", "STM", "ANSWER", "ERROR", "[timer.lua]: t_SWITCH_1() ~0:SIM.SEL=?")
            end
        end
    end
    timer.WHAT_SLOT:set(timer.interval.sim)
end
timer.WHAT_SLOT = uloop.timer(t_WHAT_SLOT)

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

--[[ RESETTING MODEM TO FIND A SIM-CARD]]


--[[ Switch Sim: Unpoll modem ]]
function t_RESET_1()
    -- if timer.modem.automation == "run" then
    if timer.modem.lock.is_automation() then
        if (timer.modem.debug) then print("----------- t_RESET_1_START ----------" .. os.date()) end
        timer.state:update("resetting", "true", "", "")


        if timer.modem.fds then
            timer.modem.unpoll()
            U.close(timer.modem.fds)
        end

        timer.RESET_2:set(timer.reset_delay["2_STM_SIM_EN_0"])
    end
end
timer.RESET_1 = uloop.timer(t_RESET_1)

--[[ Switch Sim: EN=0 ]]
function t_RESET_2()
    if (timer.modem.debug) then print("----------- t_RESET_2 ----------" .. os.date()) end

    local res, val = timer.stm:command("~0:SIM.EN=0")
    if "OK" == res then
        timer.state:update("stm32", "OK", "~0:SIM.EN=0", "")
        if_debug("", "STM", "ANSWER", "OK", "[timer.lua]: t_RESET_2() ~0:SIM.EN=0")

        timer.RESET_3:set(timer.reset_delay["3_STM_SIM_EN_1"])
    else
        timer.state:update("stm32", "ERROR", "~0:SIM.EN=0", "")
        if_debug("", "STM", "ANSWER", "ERROR", "[timer.lua]: t_RESET_2() ~0:SIM.EN=0. BREAK RESETTING")
    end

end
timer.RESET_2 = uloop.timer(t_RESET_2)

--[[ Switch Sim: EN=1 ]]
function t_RESET_3()
    if (timer.modem.debug) then print("----------- t_RESET_3 ----------" .. os.date()) end

    local res, val = timer.stm:command("~0:SIM.EN=1")
    if "OK" == res then
        timer.state:update("stm32", "OK", "~0:SIM.EN=1", "")
        if_debug("", "STM", "ANSWER", "OK", "[timer.lua]: t_RESET_3() ~0:SIM.EN=1")

        timer.RESET_4:set(timer.reset_delay["4_STM_SIM_PWR_0"])
    else
        timer.state:update("stm32", "ERROR", "~0:SIM.EN=0", "")
        if_debug("", "STM", "ANSWER", "ERROR", "[timer.lua]: t_RESET_3() ~0:SIM.EN=1. BREAK RESETTING")
    end

end
timer.RESET_3 = uloop.timer(t_RESET_3)


--[[ Switch Sim: PWR=0 ]]
function t_RESET_4()
    if (timer.modem.debug) then print("----------- t_RESET_4 ----------" .. os.date()) end

    local res, val = timer.stm:command("~0:SIM.PWR=0")
    if "OK" == res then
        timer.state:update("stm32", "OK", "~0:SIM.PWR=0", "")
        if_debug("", "STM", "ANSWER", "OK", "[timer.lua]: t_RESET_4() ~0:SIM.PWR=0")

        timer.RESET_5:set(timer.reset_delay["5_MDM_REPEAT_POLL"])
    else
        timer.state:update("stm32", "ERROR", "~0:SIM.PWR=0", "")
        if_debug("", "STM", "ANSWER", "ERROR", "[timer.lua]: t_RESET_4() ~0:SIM.PWR=0. BREAK RESETTING")
    end

end
timer.RESET_4 = uloop.timer(t_RESET_4)


--[[ Switch Sim: delay before repeat modem polling ]]
function t_RESET_5()
    if (timer.modem.debug) then print("----------- t_RESET_5 ----------" .. os.date()) end
    timer.modem:init()

    if_debug("", "FILE", "POLL", "", "[timer.lua]: t_RESET_5() modem:init()")

    timer.state:update("resetting", "false", "", "")
    if (timer.modem.debug) then print("----------- RESET_5_END ---------- " .. os.date()) end

end
timer.RESET_5 = uloop.timer(t_RESET_5)


return timer
