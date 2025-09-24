
local bit = require "bit"
local uci = require "luci.model.uci".cursor()
local util = require "luci.util"
local log = require "tsmodem.util.log"
local uloop = require "uloop"
local ubus = require "ubus"

local M = require 'posix.termio'
local F = require 'posix.fcntl'
local U = require 'posix.unistd'

require "tsmodem.driver.util"
require "tsmodem.util.pdu_encoder"
local CREG_STATE = require "tsmodem.constants.creg_state"
local balance_event_keys = require "tsmodem.constants.balance_event_keys"


local state = {}
state.conn = nil      -- Link to UBUS
state.ubus_methods = nil
state.last_at_command = ""

state.modem = nil
state.stm = nil
state.timer = nil
state.notifier = nil

state.init = function(modem, stm, timer, notifier)
    state.modem = modem
    state.stm = stm
    state.timer = timer
    state.notifier = notifier
    return state
end

--[[ STATE VARIABLES. UBUS IS USED TO GET ITS' VALUES ]]
-- It helps to make Journal records in Web UI
state.queue_for = {"stm32", "usb", "reg", "netmode", "provider_name", "remote_control"}

state.stm32 = {}
state.stm32[1] = {
    command = "",
    value = "",                 -- 0 / 1 / OK / ERROR
    time = "",
    unread = ""
}

state.cpin = {}
state.cpin[1] = {
    command = "",
    value = "",                 -- "true" or "false" mean sim is inserted or not
    time = "",
    unread = ""
}

state.reg = {}
state.reg[1] = {
    command = "",
    value = "",                 -- 0 / 1 / 2 / 3 / 4 / 5 / 6 / 7
    time = "",
    unread = ""
}

state.sim = {}
state.sim[1] = {
    command = "~0:SIM.SEL=?",
    value = "",                 -- 0 / 1
    time = "",
    unread = ""
}

state.signal = {}
state.signal[1] = {
    command = "AT+CSQ",
    value = "",                 -- 0..31
    time = "",
    unread = "true"
}


state.balance = {}
state.balance[1] = {
    command = "",
    value = "",
    time = "",
    unread = ""
}

state.usb = {}
state.usb[1] = {
    command = "",               -- /dev/ttyUSB open  |  /dev/ttyUSB close
    value = "",                 -- connected / disconnected
    time = "",
    unread = ""
}

state.netmode = {}
state.netmode[1] = {
    command = "",               -- AT+.... __TODO__
    value = "",                 -- _TODO__
    time = "",
    unread = "true"
}

state.provider_name = {}
state.provider_name[1] = {
    command = "",
    value = "",
    time = "",
    unread = ""
}

state.ping = {}
state.ping[1] = {
    command = "",
    value = "",
    time = "",
    unread = ""
}

state.switching = {}
state.switching[1] = {
    command = "",
    value = "",          -- true or false
    time = "",
    unread = ""
}

state.resetting = {}
state.resetting[1] = {
    command = "",
    value = "",          -- true or false
    time = "",
    unread = ""
}

state.remote_control = {}
state.remote_control[1] = {
    command = "",
    value = "",
    time = "",
    unread = ""
}

-- command - sms text
-- value - phone number
state.send_sms = {}
state.send_sms[1] = {
    command = "",
    value = "",
    time = "",
    unread = ""
}

local ubus_methods = {
    ["tsmodem.driver"] = {
        cpin = {
            function(req, msg)
                local resp = makeResponse("cpin")
                state.conn:reply(req, resp);
            end, {}
        },
        reg = {
            function(req, msg)
                local resp = makeResponse("reg")
                state.conn:reply(req, resp);
            end, {}
        },

        sim = {
            function(req, msg)
                local resp = makeResponse("sim")
                state.conn:reply(req, resp);
            end, {}
        },

        signal = {
            function(req, msg)
                local resp = makeResponse("signal")
                state.conn:reply(req, resp);

            end, {}
        },

        balance = {
            function(req, msg)
                local resp = makeResponse("balance")
                state.conn:reply(req, resp);

            end, {}
        },

        do_request_ussd_balance = {
            function(req, msg)
                local sim_id_settings = msg["sim_id"] or "empty"
                local ok, err, sim_id = state:get("sim", "value")
                local resp = {}

                if(sim_id_settings == sim_id) then
                    -- local provider_id = get_provider_id(sim_id)
                    -- state:update("balance", balance_event_keys["get-balance-in-progress"], ussd_command, uci:get(state.modem.config_gsm, provider_id, "balance_last_message"))
                    --
                    -- --local ussd_command = string.format("AT+CUSD=2,%s,15\r\n", uci:get(state.modem.config_gsm, provider_id, "balance_ussd"))
                    -- local ussd_command = string.format("AT+CUSD=2\r\n")
                    -- if (state.modem.debug and (state.modem.debug_type == "balance" or state.modem.debug_type == "all")) then print("----->>> Cancel USSD session before start new one: "..ussd_command) end
                    -- local chunk, err, errcode = U.write(state.modem.fds, ussd_command)
                    --
                    -- ussd_command = string.format("AT+CUSD=1,%s,15\r\n", tostring(uci:get(state.modem.config_gsm, provider_id, "balance_ussd")))
                    -- state.modem.last_balance_request_time = os.time() -- Do it each time USSD request runs
                    -- state.timer.BAL_TIMEOUT:set(state.timer.timeout["balance"])                  -- clear balance state after timeout
                    -- if (state.modem.debug and (state.modem.debug_type == "balance" or state.modem.debug_type == "all")) then print("----->>> Do USSD request: "..ussd_command .. " ... " .. state.timer.timeout["balance"]) end
                    -- local chunk, err, errcode = U.write(state.modem.fds, ussd_command)

                    resp = {
                        ["ussd_command"] = ussd_command,
                        ["chunk"] = chunk,
                        ["err"] = err,
                        ["errcode"] = errcode
                    }
                else
                    resp = {
                        ["error"] = string.format("[sim_id]=%s parameter doesn't match current modem state [sim]=%s", tostring(sim_id_settings), tostring(sim_id))
                    }
                end

                state.conn:reply(req, resp);

            end, { sim_id = ubus.STRING, NOTE_todo_update__do_request_ussd_balance__code = ubus.STRING }
        },

        usb = {
            function(req, msg)
                local resp = makeResponse("usb")
                state.conn:reply(req, resp);
            end, {}
        },

        stm32 = {
            function(req, msg)
                local resp = makeResponse("stm32")
                state.conn:reply(req, resp);

            end, {}
        },

        netmode = {
            function(req, msg)
                local resp = makeResponse("netmode")
                state.conn:reply(req, resp);

            end, {}
        },

        provider_name = {
            function(req, msg)
                local resp = makeResponse("provider_name")
                state.conn:reply(req, resp);

            end, {}
        },

        ping = {
            function(req, msg)
                local resp = makeResponse("ping")
                state.conn:reply(req, resp);

            end, {}
        },

        do_switch = {
            function(req, msg)
                local resp = {
                    command = "do_switch",
                    value = "false",
                    time = "",
                    unread = "",
                    comment = ""
                }

                if not msg["module_name"] then msg["module_name"] = "unknown" end
                if not state.modem.lock.is_owner_or_set_if_unlocked(msg["module_name"]) then
                    resp.status = "busy"
                    resp.msg = "tsmodem is busy"
                    state.conn:reply(req, resp)
                    return
                end

                state:update("balance", CREG_STATE["SWITCHING"], "", "")

                local switch_already_started = state:get("switching", "value")
                local resetting_started = state:get("resetting", "value")

                if (switch_already_started == "true" or resetting_started == "true") then
                    resp.value = "false"
                else
                    if (state.modem.debug) then
                        print("-----------------------------------------------")
                        print(string.format('|  DO_SWITCH form [%s]', tostring(msg["rule"])))
                        print("-----------------------------------------------")
                    end
                    state.timer.SWITCH_1:set(state.timer.switch_delay["1_MDM_UNPOLL"])
                    resp.value = "true"
                end

                if not (msg["keep_lock"] and msg["keep_lock"] == true) then
                    state.modem.lock.unlock(msg["module_name"])
                end

                state.conn:reply(req, resp)
            end, {rule = ubus.STRING}
        },

        do_reset = {
            function(req, msg)
                local resp = {
                    command = "do_reset",
                    value = "false",
                    time = "",
                    unread = "",
                    comment = ""
                }

                local switch_already_started = state:get("resetting", "value")
                local resetting_started = state:get("resetting", "value")

                if (switch_already_started == "true" or resetting_started == "true") then
                    resp.value = "false"
                else
                    if (state.modem.debug) then
                        print("-----------------------------------------------")
                        print(string.format('|  DO_RESET form [%s]', tostring(msg["rule"])))
                        print("-----------------------------------------------")
                    end
                    state.timer.RESET_1:set(state.timer.reset_delay["1_MDM_UNPOLL"])
                    resp.value = "true"
                end

                state.conn:reply(req, resp)
            end, {id = ubus.INT32, msg = ubus.STRING}
        },

        ping_update = {
            function(req, msg)
                if_debug("ping", "UBUS", "ASK", msg, "Note: ping.sh do the job. and call ubus ping_update method.")

                local resp = {}
                if msg["host"] and msg["value"] and msg["sim_id"] then
                    local host   = msg["host"]
                    local value  = msg["value"]
                    local sim_id = tostring(msg["sim_id"])

                    if value == "1" or value == "0" then
                        local _,_,active_sim_id = state:get("sim", "value")
                        if not (sim_id == "1" or sim_id == "0") then
                            resp = { msg = "Param [sim_id] has to be 0 or 1. Nothing was done. "}
                        elseif sim_id == active_sim_id then
                            state:update("ping", value, "ping "..host, "updated via ubus call 'ping_update'")
                            resp = { msg = "ok" }
                        elseif sim_id ~= active_sim_id and (sim_id == "0" or sim_id == "1") then
                            resp = { msg = "Active sim was switched by user or automation rules. So 'ping_update' doesn't affect this time." }
                        end
                    else
                        resp = { msg = "Param [value] has to be 0 or 1. Nothing was done. "}
                    end
                else
                    resp = { msg = "[host], [value] and [sim_id] are required params. Nothing was done." }
                end

                if_debug("ping", "UBUS", "ANSWER", resp, "Response from ubus ping_update method")

                state.conn:reply(req, resp);
            end, { host = ubus.STRING, sim_id = ubus.STRING, value = ubus.STRING }
        },

        switching = {
            function(req, msg)
                local resp = makeResponse("switching")
                state.conn:reply(req, resp);

            end, {}
        },

        resetting = {
            function(req, msg)
                local resp = makeResponse("resetting")
                state.conn:reply(req, resp);

            end, {}
        },

        send_at = {
            function(req, msg)
                local resp = {}

                print("\n\n\n==============================")
                print("message from ubus: ")
                for key, value in pairs(msg) do
                    print(key, value)
                end
                print("==============================")

                if not msg["module_name"] then msg["module_name"] = "unknown" end
                if not state.modem.lock.is_owner_or_set_if_unlocked(msg["module_name"]) then
                    resp.status = "busy"
                    resp.msg = "tsmodem is busy"
                    print("send_at: ", resp.status, resp.msg)
                    state.conn:reply(req, resp)
                    return
                end

                if msg["command"] then
                    if(state.modem:is_connected(state.modem.fds)) then
                        if (msg["what-to-update"] == "balance") then
                            state.timer.BAL_TIMEOUT:set(state.timer.timeout["balance"]) -- clear balance state after timeout
                            if_debug("send_at", "AT", "ASK", msg, "Note: sends AT command to get balance and clear balance state if no AT-answer during " .. tostring(state.timer.timeout["balance"]/60000) .. " min.")
                        end

                        if(string.find(state.last_at_command, "AT%+CMGS") and string.find(state.last_at_command, "AT%+CMGS") > 0) then
                            local chunk, err, errcode = U.write(state.modem.fds, msg["command"] .. "\26")
                            state.last_at_command = ""
                            if_debug("send_at", "UBUS", "ASK", msg["command"] .. "\26", "SMS was sent")
                        else
                            local chunk, err, errcode = U.write(state.modem.fds, msg["command"] .. "\r\n")
                            state.last_at_command = msg["command"]
                            if_debug("send_at", "UBUS", "ASK", msg, "Note: sends AT command to the modem")
                        end

                        if err then
                            resp["at_answer"] = "tsmodem [state.lua]: Error of sending AT to modem."
                        else
                            resp["at_answer"] = "UBUS will notify subscribers of tsmodem.driver object with the AT answer."
                        end
                    end
                else
                    resp["at_answer"] = "Enter AT command like this " .. "'{" .. '"command": "AT+CSQ"' .. "}'"
                end
                resp["value"] = "true"
                state.conn:reply(req, resp);
            end, {command = ubus.STRING, ["what-to-update"] = ubus.STRING, module_name = ubus.STRING}
        },

        lock = {
            function (req, msg)
                local resp = {}
                if not msg["module_name"] then msg["module_name"] = "unknown" end
                if state.modem.lock.is_owner_or_set_if_unlocked(msg["module_name"]) then
                    resp.is_owner = true
                else
                    resp.is_owner = false
                end
                state.conn:reply(req, resp)
            end, { module_name = ubus.STRING }
        },

        unlock = {
            function (req, msg)
                if not msg["module_name"] then msg["module_name"] = "unknown" end
                local unlock_status, unlock_msg = state.modem.lock.unlock(msg["module_name"])
                print("> ", unlock_status, unlock_msg)
                local resp = { unlock_status = unlock_status, msg = unlock_msg }
                state.conn:reply(req, resp)
            end, { module_name = ubus.STRING }
        },

        lock_status = {
            function (req, msg)
                local resp = {}
                resp.owner = state.modem.lock.owner
                resp.last_request_time = state.modem.lock.last_request_time
                state.conn:reply(req, resp)
            end, {}
        },

        -- [[ Clear all states ]]
        -- [[ e.g. when we save Sim-settings on the web UI]]
        clear_state = {
            function(req, msg)
                if_debug("clear_state", "UBUS", "ASK", msg, "Note: Clear states, e.g. when we save Sim-settings on the web UI")

                local resp = { res = "OK" }
                state:update("reg", "7", "", "")
                state:update("signal", "", "", "")
                -- We souldn't clear balance as its value provided rarely
                -- state:update("balance", "", "", "")
                state:update("provider_name", "", "", "")
                state:update("netmode", "", "", "")
                state:update("cpin", "", "", "")
                state:update("ping", "", "", "")

                if_debug("clear_state", "UBUS", "ANSWER", resp, "")

                state.conn:reply(req, resp);

            end, {}
        },

        -- [[ Clear log ]]
        -- [[ e.g. when a user pressed "Clear log" button in the SIM cards page"]]
        clear_log = {
            function(req, msg)
                if_debug("clear_log", "UBUS", "ASK", msg, "Note: Clear log, e.g. when a user pressed 'Clear log' button in the SIM cards page")
                os.execute("/usr/sbin/tsmjournal clear")
                local resp = { res = "/usr/sbin/tsmjournal clear" }
                if_debug("clear_log", "UBUS", "ANSWER", resp, "")

                --[[ Put "Clear journal event" to the Journal ]]


                state.conn:reply(req, resp);

            end, {}
        },

        -- delete later
        automation = {
            function(req, msg)
                print("automation ubus method called!")
                if msg then
                    print("------------------------------ msg start")
                    print(msg, #msg)
                    for key, value in pairs(msg) do
                        print(key, value)
                    end
                    print("------------------------------ msg end")
                end

                local mode = ""
                if state.modem.lock.is_automation() then mode = "run" else mode = "stop" end
                local resp = { mode = mode, ["occupied"] = state.modem.lock.owner }
                if_debug("automation", "UBUS", "ANSWER", resp, "")
                state.conn:reply(req, resp);
            end, { mode = ubus.STRING, occupied = ubus.STRING }
        },
        -- Дистанционное управление по СМС. Удалить, т.к. не нужно.
        remote_control = {
            function(req, msg)
                local resp = makeResponse("remote_control")
                state.conn:reply(req, resp);

            end, {}
        },

        -- Отправка смс:
        -- command = "sms text"
        -- value = "phone number"
        send_sms = {
            function(req, msg)
                local resp = {}
                if_debug("send_sms", "UBUS", "ASK send_sms", util.serialize_json(msg), "[state.lua]: send_sms")
                -- Проверка, что сообщение не пустое и номер начинается с +7...
                if msg["value"] and type(msg["value"] == "string") and msg["command"] and #msg["command"] > 0 and string.sub(msg["value"], 1, 2) == "+7" then
                    resp = { sms_send_result = rsp }
                    --state.conn:notify( state.ubus_methods["tsmodem.driver"].__ubusobj, "SMS_send_result", resp )
                else
                    resp["note"] = "Example: [command] = 'SMS text', [value] = '+79998881234'"
                end
                state.conn:reply(req, resp);
            end, { command = ubus.STRING, value = ubus.STRING }
        },
    }
}

function state:tsmsms_subscribe_ubus()
    local ok, error = pcall(function ()
        local sub = {
            notify = function(msg, name)
                if name == "NEW-SMS-RECEIVED" then
                    print("[tsmsms_subscribe_ubus -> NEW-SMS-RECEIVED]", util.serialize_json(msg))
                    if
                        msg["sender"] == "000100" or -- Megafon
                        msg["sender"] == "111" or -- MTC
                        msg["sender"] == "1111" or -- Beline
                        msg["sender"] == "105" or -- Tele2
                        msg["sender"] == "100" -- Yota
                    then
                        local balance_str = string.match(msg["message"], "%d+")
                        state:update("balance", balance_str, "", "")
                    end
                end
            end
        }
        state.conn:subscribe("tsmodem.sms", sub)
    end)
    if not ok then
        uloop.timer(function () state:tsmsms_subscribe_ubus() end, 3000)
    end
end

function state:make_ubus()
    state.conn = ubus.connect()
    if not state.conn then
        error("tsmodem: Failed to connect to ubus")
    end

    -- Сделать перебор очереди статусов, проверяя параметр "unread"
    -- и выдавать до тех пор пока unread==true
    function getFirstUnread(name)
        local n = #state[name]
        if n > 0 then
            for i=1, #state[name] do
                if state[name][i].unread == "true" then
                    return state[name][i]
                end
            end
            -- If no unread states then return the last one.
            -- if name == "signal" then
            --     print("+++++", state[name][n].time, #state[name])
            -- end
            return state[name][n]
        end
        return {}
    end

    function makeResponse(name)
        local r, resp = {}, {}
        local n = #state[name]
        if (n > 0) then
            r = getFirstUnread(name)
            resp = util.clone(r)
            r["unread"] = "false"
        else
            resp = {
                command = "",
                value = "",
                time = "",
                unread = "",
                comment = ""
            }
        end
        return resp
    end

    state.conn:add( ubus_methods )
    state.ubus_methods = ubus_methods
end

--[[ For thouse params where queue of state is required ]]
--[[ see state.queue_for table to define the param names which need queue ]]
function state:update_queue(param, value, command, comment)
    local newval = tostring(value)

    local n = #state[param]

    if (n == 0) then
        local item = {
            ["command"] = command,
            ["value"] = newval,
            ["time"] = tostring(os.time()),
            ["unread"] = "true",
            ["comment"] = comment
        }
        state[param][1] = util.clone(item)
    elseif (n >= 1) then
        if(state[param][n].value ~= newval or state[param][n].command ~= command) then
            local item = {
                ["command"] = command,
                ["value"] = newval,
                ["time"] = tostring(os.time()),
                ["unread"] = "true",
                ["comment"] = comment
            }
            state[param][n+1] = util.clone(item)
            if n > 5 then
                table.remove(state[param], 1)
            end
        --[[ Update last time of succesful registration state ]]
        elseif (param == "reg" and (newval == CREG_STATE["REGISTERED"] or newval == CREG_STATE["SWITCHING"])) then
            state["reg"][n].time = tostring(os.time())
        --[[ Update time of last balance ussd request if balance's value is not changed ]]
        elseif (param == "balance") then
            state["balance"][n].time = tostring(os.time())
        --[[ Update time of last successful ping ]]
        elseif (param == "ping") and value == "1" then
            state["ping"][n].time = tostring(os.time())
        end
    end
end

function state:update(param, value, command, comment)
    local newval = tostring(value)

    if (util.contains(state.queue_for, param)) then
        state:update_queue(param, value, command, comment)
    else
        local n = #state[param]
        if (n == 0) then
            local item = {
                ["command"] = command,
                ["value"] = newval,
                ["time"] = tostring(os.time()),
                ["unread"] = "true",
                ["comment"] = comment
            }
            state[param][1] = util.clone(item)
        else
            local _,_,oldval =state:get(param, "value")
            local _,_,oldcomm = state:get(param, "command")

            if(oldval ~= newval or oldcomm ~= command) then
                local item = {
                    ["command"] = command,
                    ["value"] = newval,
                    ["time"] = tostring(os.time()),
                    ["unread"] = "true",
                    ["comment"] = comment
                }
                state[param][1] = util.clone(item)
            --[[ IF NOTHING CHANGED THEN UPDATE ONLY TIME ]]
            --[[ Update last time of succesful registration state ]]
            elseif (param == "reg" and (newval == CREG_STATE["REGISTERED"] or newval == CREG_STATE["SWITCHING"])) then
                state["reg"][1].time = tostring(os.time())
            --[[ Update last time when signal was Ok ]]
            elseif (param == "signal") then
                state["signal"][1].time = tostring(os.time())
            --[[ Update time of last balance ussd request if balance's value is not changed ]]
            elseif (param == "balance") then
                state["balance"][1].time = tostring(os.time())
            --[[ Update time of last successful ping ]]
            elseif (param == "ping") and value == "1" then
                state["ping"][1].time = tostring(os.time())
            --[[ Update time of last successful cpin ]]
            elseif (param == "cpin") and value == "true" then
                state["cpin"][1].time = tostring(os.time())
            --[[ Update SMS command received in any case, even if it was the same like previous one ]]
            elseif (param == "remote_control") then
                local item = {
                    ["command"] = command,
                    ["value"] = newval,
                    ["time"] = tostring(os.time()),
                    ["unread"] = "true",
                    ["comment"] = comment
                }
                state[param][1] = util.clone(item)
            end
        end
    end
end

-- returns triplet: noerror, errmsg, value
function state:get(var, param)
    local value = ""
    local v, p = tostring(var), tostring(param)
    if state[v] and (#state[v] > 0) and state[v][#state[v]][p] then
        value = state[v][#state[v]][p]
        return true, "", value
    else
        return false, string.format("State Var '%s' or Param '%s' are not found in list of state vars.", tostring(v), tostring(p)), value
    end
end


return state
