local lpeg = require "lpeg"
local log = require "tsmodem.util.log"

function not_inserted(s) return s and "false" end
function ready(s) return s and "true" end
function failure(s) return s and "failure" end

local spc = lpeg.S(" \t\n\r")^0
local sim_not_inserted = spc * lpeg.P("AT+CPIN?")^0 * spc * lpeg.P('+CME ERROR: SIM not inserted') * spc / not_inserted
local sim_busy = spc * lpeg.P("AT+CPIN?")^0 * spc * lpeg.P('+CME ERROR: 10') * spc / not_inserted
local sim_not_ready = spc * lpeg.P("AT+CPIN?")^0 * spc * lpeg.P('+CME ERROR: 313') * spc / not_inserted
local sim_ready = spc * lpeg.P("AT+CPIN?")^0 * spc * lpeg.P('+CPIN: READY') * spc / ready
local sim_failure = spc * lpeg.P("AT+CPIN?")^0 * spc * lpeg.P('+CME ERROR: (U)SIM failure') * spc / failure
local sim_not_available = spc * lpeg.P("AT+CPIN?")^0 * spc * lpeg.P('+SIMCARD: NOT AVAILABLE') * spc / not_inserted

local cpin = sim_not_inserted + sim_busy + sim_not_ready + sim_ready + sim_failure + sim_not_available

return cpin

--local text = "+CME ERROR: SIM not inserted"
-- local text = "+CPIN: READY"
--local text = "+CME ERROR: (U)SIM failure"
--print(text)
--print(cpin:match(text))
