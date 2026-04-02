--[[

    检查更新脚本

    本文件仅作为参考，请不要修改本文件
    本文件会在重装、更新时被原版覆盖

--]]

if not lockfile("/tmp/.xxtouch-check-update.lua.singleton") then
    return
end

local LLANG = (function()
    local _localizations = {
        en = {
            ["XXTouch"] = "XXTouch",
            ["Not Now"] = "Not Now",
            ["Download Update"] = "Download Update",
            ["Skip This Version"] = "Skip This Version",
            ["Use Sileo Update"] = "Use Sileo Update",
            ["Use Cydia Update"] = "Use Cydia Update",
            ["Use Zebra Update"] = "Use Zebra Update",
            ["Update?"] = "Update?",
            ["Use Sileo Update?"] = "Use Sileo Update?",
            ["Use Cydia Update?"] = "Use Cydia Update?",
            ["Use Zebra Update?"] = "Use Zebra Update?",
        },
        zh = {
            ["XXTouch"] = "X.X.T.",
            ["Not Now"] = "暂不更新",
            ["Download Update"] = "下载更新",
            ["Skip This Version"] = "跳过此版本",
            ["Use Sileo Update"] = "使用 Sileo 更新",
            ["Use Cydia Update"] = "使用 Cydia 更新",
            ["Use Zebra Update"] = "使用 Zebra 更新",
            ["New Version"] = "发现新版本",
            ["Update?"] = "是否下载更新？",
            ["Use Sileo Update?"] = "是否使用 Sileo 更新？",
            ["Use Cydia Update?"] = "是否使用 Cydia 更新？",
            ["Use Zebra Update?"] = "是否使用 Zebra 更新？",
        },
    }
    local lang = sys.language() or 'en'
    return function(str)
        for k, v in pairs(_localizations) do
            if lang:find(k, 1, true) then
                if _localizations[k][str] then
                    return _localizations[k][str]
                end
            end
        end
        return _localizations["en"][str] or str
    end
end)()

local json = require('cjson.safe')

local last_check_update = file.reads(XXT_HOME_PATH .. '/caches/.last-check-update') or ""
last_check_update = json.decode(last_check_update)
last_check_update = type(last_check_update) == 'table' and last_check_update or {}
if (tonumber(last_check_update.time or 0) or 0) > (os.time() - 3600) then
    return
end

local c, h, r = http.get("https://xxtouch.app/api/latest-version", 15, {})
if c ~= 200 then
    return
end

local t = json.decode(r)
if type(t) ~= 'table' then
    return
end

t = t["app.xxtouch.ios"]
if type(t) ~= 'table' then
    return
end

if type(t.latest) ~= 'string' then
    return
end

t.time = os.time()
file.writes(XXT_HOME_PATH .. '/caches/.last-check-update', json.encode(t))

if sys.xtversion():compare_version(t.latest) >= 0 then
    -- if sys.xtversion() == (t.latest) then
    return
end

if file.reads(XXT_HOME_PATH .. '/caches/.skiped-version') == t.latest then
    return
end

local description = t.description
if sys.language():starts_with("zh") then
    description = t.description_zh or t.description
end

if IS_TROLLSTORE_EDITION then
    local troll_bid = 'com.opa334.TrollStore'
    local troll_path = app.bundle_path(troll_bid)
    if not troll_path then
        troll_bid = 'com.opa334.TrollStoreLite'
        troll_path = app.bundle_path(troll_bid)
    end
    t.url = "https://xxtouch.app/?action=click-download-tipa"
    file.writes(XXT_HOME_PATH .. '/caches/.last-check-update', json.encode(t))
    local choice = sys.alert(LLANG("New Version") .. " " .. t.latest .. "\n\n" .. description .. "\n\n" ..
    LLANG("Update?"), 30, LLANG("XXTouch"), LLANG("Not Now"), LLANG("Download Update"), LLANG("Skip This Version"))
    if choice == 2 then
        file.writes(XXT_HOME_PATH .. '/caches/.skiped-version', t.latest)
        return os.exit()
    elseif choice ~= 1 then
        return os.exit()
    end
    if (type(t['tipa-url']) ~= 'string') or (not troll_path) or file.exists(troll_path .. "/trollstorehelper") ~= 'file' then
        app.open_url("https://xxtouch.app/?action=click-download-tipa")
    else
        app.open_url(troll_bid, "apple-magnifier://install?url=" .. string.encode_uri_component(t['tipa-url']))
    end
    return os.exit()
end

if app.bundle_path("org.coolstar.SileoStore") then
    t.url = "sileo://source/https://xxtouch.app"
    file.writes(XXT_HOME_PATH .. '/caches/.last-check-update', json.encode(t))
    local choice = sys.alert(
    LLANG("New Version") .. " " .. t.latest .. "\n\n" .. description .. "\n\n" .. LLANG("Use Sileo Update?"), 30,
        LLANG("XXTouch"), LLANG("Not Now"), LLANG("Use Sileo Update"), LLANG("Skip This Version"))
    if choice == 2 then
        file.writes(XXT_HOME_PATH .. '/caches/.skiped-version', t.latest)
        return os.exit()
    elseif choice ~= 1 then
        return os.exit()
    end
    app.open_url("org.coolstar.SileoStore", t.url)
elseif app.bundle_path("com.saurik.Cydia") then
    t.url = "cydia://url/https://cydia.saurik.com/api/share#?source=https://xxtouch.app"
    file.writes(XXT_HOME_PATH .. '/caches/.last-check-update', json.encode(t))
    local choice = sys.alert(
    LLANG("New Version") .. " " .. t.latest .. "\n\n" .. description .. "\n\n" .. LLANG("Use Cydia Update?"), 30,
        LLANG("XXTouch"), LLANG("Not Now"), LLANG("Use Cydia Update"), LLANG("Skip This Version"))
    if choice == 2 then
        file.writes(XXT_HOME_PATH .. '/caches/.skiped-version', t.latest)
        return os.exit()
    elseif choice ~= 1 then
        return os.exit()
    end
    app.open_url("com.saurik.Cydia", t.url)
elseif app.bundle_path("xyz.willy.Zebra") then
    t.url = "zbra://sources/add/https://xxtouch.app"
    file.writes(XXT_HOME_PATH .. '/caches/.last-check-update', json.encode(t))
    local choice = sys.alert(
    LLANG("New Version") .. " " .. t.latest .. "\n\n" .. description .. "\n\n" .. LLANG("Use Zebra Update?"), 30,
        LLANG("XXTouch"), LLANG("Not Now"), LLANG("Use Zebra Update"), LLANG("Skip This Version"))
    if choice == 2 then
        file.writes(XXT_HOME_PATH .. '/caches/.skiped-version', t.latest)
        return os.exit()
    elseif choice ~= 1 then
        return os.exit()
    end
    app.open_url("xyz.willy.Zebra", t.url)
end
