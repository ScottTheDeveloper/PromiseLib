-- @scott

local Promise = {}
Promise.__index = Promise

local function isPromise(obj)
    return type(obj) == "table" and getmetatable(obj) == Promise
end

local function asyncCall(fn, ...)
    local args = table.pack(...)
    task.defer(function()
        fn(table.unpack(args, 1, args.n))
    end)
end

local function safePcall(fn, ...)
    return pcall(fn, ...)
end

local function createPromise(executor)
    local self = setmetatable({}, Promise)
    self._status = "Pending"
    self._value = nil
    self._callbacks = {}
    self._progressCallbacks = {}
    self._cancellationCallback = nil
    self._finalized = false

    local function drainCallbacks()
        if self._finalized then return end
        self._finalized = true
        task.defer(function()
            for _, cb in ipairs(self._callbacks) do
                safePcall(cb)
            end
            self._callbacks = {}
            self._progressCallbacks = {}
        end)
    end

    local function resolve(value)
        if self._status ~= "Pending" then return end
        if isPromise(value) then
            value:Then(function(v)
                resolve(v)
            end, function(r)
                reject(r)
            end, function(p, cur)
                notifyProgress(p, cur)
            end)
            return
        end
        self._status = "Fulfilled"
        self._value = value
        drainCallbacks()
    end

    function reject(reason)
        if self._status ~= "Pending" then return end
        self._status = "Rejected"
        if type(reason) == "string" then
            self._value = debug.traceback(reason, 2)
        else
            self._value = reason
        end
        drainCallbacks()
    end

    function notifyProgress(progress, current)
        for _, cb in ipairs(self._progressCallbacks) do
            safePcall(cb, progress, current)
        end
    end

    local ok, err = safePcall(function()
        executor(resolve, reject, notifyProgress)
    end)
    if not ok then
        reject(err)
    end

    return self
end

function Promise.new(executor)
    return createPromise(executor)
end

function Promise:Then(onFulfilled, onRejected, onProgress)
    local parent = self
    return Promise.new(function(resolve, reject, notifyProgress)
        local function handle()
            if parent._status == "Fulfilled" then
                if onFulfilled then
                    local ok, result = safePcall(onFulfilled, parent._value)
                    if ok then resolve(result) else reject(result) end
                else
                    resolve(parent._value)
                end
            elseif parent._status == "Rejected" or parent._status == "Cancelled" then
                if onRejected then
                    local ok, result = safePcall(onRejected, parent._value)
                    if ok then resolve(result) else reject(result) end
                else
                    reject(parent._value)
                end
            end
        end

        if parent._status == "Pending" then
            table.insert(parent._callbacks, handle)
            if onProgress then
                table.insert(parent._progressCallbacks, onProgress)
            end
        else
            asyncCall(handle)
        end
    end)
end

function Promise:Catch(onRejected)
    return self:Then(nil, onRejected)
end

function Promise:Finally(onFinally)
    return self:Then(
        function(value)
            local ok, err = safePcall(onFinally)
            if not ok then return Promise.Reject(err) end
            return value
        end,
        function(reason)
            local ok, err = safePcall(onFinally)
            if not ok then return Promise.Reject(err) end
            return Promise.Reject(reason)
        end
    )
end

function Promise:Progress(onProgress)
    return self:Then(nil, nil, onProgress)
end

function Promise:Timeout(ms)
    local timeoutPromise = Promise.new(function(_, reject)
        task.delay(ms / 1000, function()
            reject("Promise timed out")
        end)
    end)
    return Promise.Race(self, timeoutPromise)
end

function Promise:TimeoutWithFallback(ms, fallback)
    return self:Timeout(ms):Catch(function()
        return fallback
    end)
end

function Promise:Delay(ms)
    return self:Then(function(value)
        return Promise.new(function(resolve)
            task.delay(ms / 1000, function()
                resolve(value)
            end)
        end)
    end)
end

function Promise:Cancel()
    if self._status ~= "Pending" then return end
    self._status = "Cancelled"
    self._value = "Promise cancelled"
    for _, cb in ipairs(self._callbacks) do
        safePcall(cb)
    end
    self._callbacks = {}
    if self._cancellationCallback then
        self._cancellationCallback()
    end
end

function Promise:WithCancellation(token)
    self._cancellationCallback = token
    return self
end

function Promise:Status()
    return self._status
end

function Promise.Resolve(value)
    return Promise.new(function(resolve)
        resolve(value)
    end)
end

function Promise.Reject(reason)
    return Promise.new(function(_, reject)
        reject(reason)
    end)
end

function Promise.All(...)
    local promises = {...}
    return Promise.new(function(resolve, reject)
        local results, count = {}, 0
        for i, p in ipairs(promises) do
            p:Then(function(result)
                results[i] = result
                count += 1
                if count == #promises then
                    resolve(results)
                end
            end):Catch(function(err)
                reject(err)
            end)
        end
    end)
end

function Promise.AllSettled(...)
    local promises = {...}
    return Promise.new(function(resolve)
        local results, count = {}, 0
        for i, p in ipairs(promises) do
            p:Then(function(value)
                results[i] = {status = "fulfilled", value = value}
            end):Catch(function(reason)
                results[i] = {status = "rejected", reason = reason}
            end):Finally(function()
                count += 1
                if count == #promises then
                    resolve(results)
                end
            end)
        end
    end)
end

function Promise.Race(...)
    local promises = {...}
    return Promise.new(function(resolve, reject)
        for _, p in ipairs(promises) do
            p:Then(resolve):Catch(reject)
        end
    end)
end

function Promise.Any(...)
    local promises = {...}
    return Promise.new(function(resolve, reject)
        local rejections, count = {}, 0
        for i, p in ipairs(promises) do
            p:Then(resolve):Catch(function(reason)
                rejections[i] = reason
                count += 1
                if count == #promises then
                    reject(rejections)
                end
            end)
        end
    end)
end

function Promise.FromEvent(event, predicate)
    return Promise.new(function(resolve)
        local conn
        conn = event:Connect(function(...)
            if not predicate or predicate(...) then
                conn:Disconnect()
                resolve(...)
            end
        end)
    end)
end

function Promise.FromYield(fn, ...)
    local args = table.pack(...)
    return Promise.new(function(resolve, reject)
        local ok, result = pcall(fn, table.unpack(args, 1, args.n))
        if ok then resolve(result) else reject(result) end
    end)
end

function Promise.Retry(fn, retries, delayMs)
    retries = retries or 3
    delayMs = delayMs or 0
    return Promise.new(function(resolve, reject)
        local function attempt(n)
            local p = fn()
            p:Then(resolve):Catch(function(err)
                if n < retries then
                    if delayMs > 0 then
                        task.delay(delayMs / 1000, function()
                            attempt(n + 1)
                        end)
                    else
                        attempt(n + 1)
                    end
                else
                    reject(err)
                end
            end)
        end
        attempt(1)
    end)
end

return Promise
