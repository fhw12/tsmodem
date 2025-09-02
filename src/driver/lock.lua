local lock = {
    owner = "",
    last_request_time = 0,
}

function lock.unlock(module_name, is_timeout)
    if lock.owner == module_name or is_timeout then
        lock.owner = ""
        lock.last_request_time = 0
        return "unlocked"
    elseif lock.owner == "" then
        return "already was unlocked"
    else
        return "not the owner"
    end
end

function lock.unlock_if_timeout()
    if lock.owner ~= "" and os.difftime(os.time(), lock.last_request_time) > 60 then
        lock.unlock("", true)
    end
end

function lock.is_owner_or_set_if_unlocked(module_name)
    lock.unlock_if_timeout()

    if lock.owner == "" then
        lock.owner = module_name
        lock.last_request_time = os.time()
        print("> ", "locked")
        return true
    end

    if lock.owner == module_name then
        lock.last_request_time = os.time()
        return true
    end

    return false
end

function lock.is_automation()
    lock.unlock_if_timeout()
    return lock.owner == ""
end

function lock.is_notify()
    return lock.owner ~= ""
end

return lock
