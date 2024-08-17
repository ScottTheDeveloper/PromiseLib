-- @scott's Promise System

local Promise = {}
Promise.__index = Promise

-- Utility function to create a new promise
local function createPromise(executor)
    local self = setmetatable({}, Promise)
    self._status = "Pending"
    self._value = nil
    self._callbacks = {}
    self._progressCallbacks = {}
    self._cancellationToken = nil

    -- Handles the resolution of the promise
    local function resolve(value)
        if self._status ~= "Pending" then return end
        self._status = "Fulfilled"
        self._value = value
        for _, callback in ipairs(self._callbacks) do
            callback()
        end
    end

    -- Handles the rejection of the promise
    local function reject(reason)
        if self._status ~= "Pending" then return end
        self._status = "Rejected"
        self._value = reason
        for _, callback in ipairs(self._callbacks) do
            callback()
        end
    end

    -- Handles progress notifications
    local function notifyProgress(progress)
        for _, progressCallback in ipairs(self._progressCallbacks) do
            pcall(progressCallback, progress, self._value)
        end
    end

    -- Safely execute the provided executor function
    local success, err = pcall(function()
        executor(resolve, reject, notifyProgress)
    end)
    if not success then
        reject(err)
    end

    return self
end

-- Creates a new Promise
function Promise.new(executor)
    return createPromise(executor)
end

-- Adds callbacks for when the promise is fulfilled or rejected
function Promise:Then(onFulfilled, onRejected, onProgress)
    -- If already resolved or rejected, handle it immediately
    if self._status == "Fulfilled" and onFulfilled then
        return Promise.Resolve(onFulfilled(self._value))
    elseif self._status == "Rejected" and onRejected then
        return Promise.Reject(onRejected(self._value))
    end
    
    local newPromise = Promise.new(function(resolve, reject, notifyProgress)
        local function callback()
            if self._status == "Fulfilled" then
                if onFulfilled then
                    local success, result = pcall(onFulfilled, self._value)
                    if success then
                        resolve(result)
                    else
                        reject(result)
                    end
                else
                    resolve(self._value)
                end
            elseif self._status == "Rejected" then
                if onRejected then
                    local success, result = pcall(onRejected, self._value)
                    if success then
                        resolve(result)
                    else
                        reject(result)
                    end
                else
                    reject(self._value)
                end
            end
        end

        if self._status == "Pending" then
            table.insert(self._callbacks, callback)
            if onProgress then
                table.insert(self._progressCallbacks, onProgress)
            end
        else
            callback()
        end
    end)

    return newPromise
end

-- Adds a callback for when the promise is rejected
function Promise:Catch(onRejected)
    return self:Then(nil, onRejected)
end

-- Returns a promise that rejects if the original promise does not settle within the specified time
function Promise:Timeout(ms)
    local timeoutPromise = Promise.new(function(_, reject)
        delay(ms / 1000, function()
            reject("Promise timed out")
        end)
    end)

    return Promise.Race(self, timeoutPromise)
end

-- Adds a progress callback to the promise
function Promise:Progress(onProgress)
    return self:Then(nil, nil, onProgress)
end

-- Chains multiple promises together
function Promise:Chain(...)
    local promises = {...}
    return self:Then(function()
        local nextPromise = promises[1]
        return nextPromise and nextPromise:Chain(table.unpack(promises, 2))
    end)
end

-- Executes a callback regardless of the promise's outcome
function Promise:Finally(onFinally)
    return self:Then(
        function(value)
            onFinally()
            return value
        end,
        function(reason)
            onFinally()
            error(reason)
        end
    )
end

-- Cancels the promise if a cancellation token is provided
function Promise:Cancel()
    if self._status ~= "Pending" then return end
    if self._cancellationToken then
        self._cancellationToken()
        self._status = "Cancelled"
    end
end

-- Attaches a cancellation token to the promise
function Promise:WithCancellation(token)
    self._cancellationToken = token
    return self
end

-- Resolves a promise with a given value
function Promise.Resolve(value)
    return Promise.new(function(resolve)
        resolve(value)
    end)
end

-- Rejects a promise with a given reason
function Promise.Reject(reason)
    return Promise.new(function(_, reject)
        reject(reason)
    end)
end

-- Returns a promise that resolves when all of the given promises resolve
function Promise.All(...)
    local promises = {...}
    return Promise.new(function(resolve, reject)
        local results = {}
        local count = 0

        for i, promise in ipairs(promises) do
            promise:Then(function(result)
                results[i] = result
                count = count + 1
                if count == #promises then
                    resolve(results)
                end
            end):Catch(function(error)
                reject(error)
            end)
        end
    end)
end

-- Returns a promise that resolves or rejects as soon as one of the given promises does
function Promise.Race(...)
    local promises = {...}
    return Promise.new(function(resolve, reject)
        for _, promise in ipairs(promises) do
            promise:Then(resolve):Catch(reject)
        end
    end)
end

-- Returns a promise that resolves as soon as any one of the given promises resolves
function Promise.Any(...)
    local promises = {...}
    return Promise.new(function(resolve, reject)
        local rejections = {}
        local count = 0

        for i, promise in ipairs(promises) do
            promise:Then(resolve):Catch(function(reason)
                rejections[i] = reason
                count = count + 1
                if count == #promises then
                    reject(rejections)
                end
            end)
        end
    end)
end

-- Delays the resolution of the promise
function Promise:Delay(ms)
    return self:Then(function(value)
        return Promise.new(function(resolve)
            delay(ms / 1000, function()
                resolve(value)
            end)
        end)
    end)
end

return Promise
