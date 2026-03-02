local M = {}

---Run a function in a coroutine context
---@param func fun()
function M.run(func)
    local coroutine_handle = coroutine.create(func)
    local ok, error_message = coroutine.resume(coroutine_handle)
    if not ok then
        vim.schedule(function()
            vim.notify("[review.nvim] async error: " .. tostring(error_message), vim.log.levels.ERROR)
        end)
    end
end

---Async wrapper around vim.system() — must be called from within M.run()
---@param cmd string[]
---@param opts table|nil
---@return vim.SystemCompleted
function M.system(cmd, opts)
    local coroutine_handle = coroutine.running()
    assert(coroutine_handle, "async.system() must be called inside async.run()")

    vim.system(cmd, opts or {}, function(result)
        vim.schedule(function()
            local ok, error_message = coroutine.resume(coroutine_handle, result)
            if not ok then
                vim.notify("[review.nvim] async resume error: " .. tostring(error_message), vim.log.levels.ERROR)
            end
        end)
    end)

    return coroutine.yield()
end

---Run multiple async functions concurrently and wait for all to complete
---@param functions fun()[]
---@return any[] results (one per function, in order)
function M.all(functions)
    local coroutine_handle = coroutine.running()
    assert(coroutine_handle, "async.all() must be called inside async.run()")

    local results = {}
    local remaining = #functions

    if remaining == 0 then
        return results
    end

    for index, func in ipairs(functions) do
        M.run(function()
            results[index] = func()
            remaining = remaining - 1
            if remaining == 0 then
                vim.schedule(function()
                    local ok, error_message = coroutine.resume(coroutine_handle, results)
                    if not ok then
                        vim.notify(
                            "[review.nvim] async.all resume error: " .. tostring(error_message),
                            vim.log.levels.ERROR
                        )
                    end
                end)
            end
        end)
    end

    return coroutine.yield()
end

return M
