local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local Notification = require("ui/widget/notification")
local Dispatcher = require("dispatcher")
local DataStorage = require("datastorage")
local logger = require("logger")
local json = require("json")
local lfs = require("libs/libkoreader-lfs")

local TestSyncPlugin = WidgetContainer:extend{
    name = "test_sync",
    is_doc_only = false,
}

TestSyncPlugin.default_settings = {
    remote_server = nil,
    local_dir = nil,
}

function TestSyncPlugin:init()
    self.ui.menu:registerToMainMenu(self)
    self.settings = G_reader_settings:readSetting("test_sync_plugin", self.default_settings)
end

function TestSyncPlugin:addToMainMenu(menu_items)
    menu_items.test_sync_plugin = {
        text = "测试同步",
        sorting_hint = "tools",
        sub_item_table = {
            {
                text_func = function()
                    if self.settings.remote_server and self.settings.remote_server.url then
                        return "远程目录: " .. self.settings.remote_server.url
                    else
                        return "设置远程目录"
                    end
                end,
                callback = function()
                    local SyncService = require("apps/cloudstorage/syncservice")
                    local sync_service = SyncService:new{
                        server_type = self.settings.remote_server and self.settings.remote_server.type or nil,
                        server_address = self.settings.remote_server and self.settings.remote_server.address or nil,
                        server_username = self.settings.remote_server and self.settings.remote_server.username or nil,
                        server_password = self.settings.remote_server and self.settings.remote_server.password or nil,
                        server_url = self.settings.remote_server and self.settings.remote_server.url or nil,
                    }
                    sync_service.onConfirm = function(server)
                        self.settings.remote_server = server
                        G_reader_settings:saveSetting("test_sync_plugin", self.settings)
                    end
                    UIManager:show(sync_service)
                end
            },
            {
                text_func = function()
                    if self.settings.local_dir then
                        return "本地目录: " .. self.settings.local_dir
                    else
                        return "设置本地目录"
                    end
                end,
                callback = function()
                    local DownloadMgr = require("ui/downloadmgr")
                    local current_dir = self.settings.local_dir

                    DownloadMgr:new{
                        title = "选择本地目录",
                        onConfirm = function(path)
                            if path and path ~= "" then
                                self.settings.local_dir = path
                                G_reader_settings:saveSetting("test_sync_plugin", self.settings)
                                UIManager:show(Notification:new{
                                    text = "本地目录已设置: " .. path,
                                    timeout = 2
                                })
                            end
                        end,
                    }:chooseDir(current_dir)
                end,
            },
            {
                text = "开始同步",
                callback = function()
                    self:startSync()
                end
            }
        }
    }
end

--- 获取对应云存储类型的 API 实例
-- @param server 服务器配置表，包含 type 字段
-- @return API 模块或 nil
function TestSyncPlugin:get_api(server)
    if server.type == "dropbox" then
        return require("apps/cloudstorage/dropboxapi")
    elseif server.type == "webdav" then
        return require("apps/cloudstorage/webdavapi")
    end
    return nil
end

--- 下载远程根目录的 index.json，并根据用户设置的远程子目录过滤文件列表（仅 WebDAV 使用）
-- @param server 服务器配置表，需包含 address, username, password, url（远程子目录）
-- @param api WebDAV API 实例
-- @return 过滤后的文件列表（表数组，每个元素含 path, size, full_path），以及错误信息（若失败）
function TestSyncPlugin:fetchAndFilterWebDAVIndex(server, api)
    local index_remote_path = "/index.json"
    local root_url = server.address
    local index_full_url = api:getJoinedPath(root_url, index_remote_path)
    local temp_file = "/tmp/koreader_index.json"

    local code = api:downloadFile(index_full_url, server.username, server.password, temp_file, nil)
    if code ~= 200 and code ~= 201 and code ~= 206 then
        return nil, "无法下载索引文件 index.json (HTTP " .. tostring(code) .. ")"
    end

    local file = io.open(temp_file, "r")
    if not file then
        return nil, "无法读取临时索引文件"
    end
    local content = file:read("*all")
    file:close()
    os.remove(temp_file)

    local data = json.decode(content)
    if not data or type(data) ~= "table" then
        return nil, "索引文件 index.json 格式错误"
    end

    -- 规范化远程子目录：去除首尾斜杠，末尾保留斜杠，空字符串表示根目录
    local remote_subdir = server.url or ""
    if remote_subdir == "" or remote_subdir == "/" then
        remote_subdir = ""
    else
        if remote_subdir:sub(1,1) == "/" then
            remote_subdir = remote_subdir:sub(2)
        end
        if remote_subdir:sub(-1) ~= "/" then
            remote_subdir = remote_subdir .. "/"
        end
    end

    local filtered = {}
    for _, item in ipairs(data) do
        if item.type == "file" and item.path then
            local full_path = item.path  -- 例如 "ebook/xxx.epub"
            if remote_subdir == "" then
                -- 根目录模式：包含所有文件
                table.insert(filtered, {
                    path = full_path,
                    size = item.size,
                    full_path = full_path
                })
            else
                if full_path:sub(1, #remote_subdir) == remote_subdir then
                    local rel_path = full_path:sub(#remote_subdir + 1)
                    if rel_path ~= "" then
                        table.insert(filtered, {
                            path = rel_path,
                            size = item.size,
                            full_path = full_path
                        })
                    end
                end
            end
        end
    end

    return filtered, nil
end

--- 主同步入口：校验设置，根据云存储类型选择对应同步方法
function TestSyncPlugin:startSync()
    local server = self.settings.remote_server
    local local_dir = self.settings.local_dir

    if not server or not local_dir then
        UIManager:show(InfoMessage:new{
            text = "请先设置远程目录和本地目录。",
            timeout = 3
        })
        return
    end

    local api = self:get_api(server)
    if not api then
        UIManager:show(InfoMessage:new{text = "不支持的云存储类型。", timeout = 3})
        return
    end

    -- WebDAV 模式：使用预生成的 index.json 并支持子目录过滤
    if server.type == "webdav" then
        local fetch_notification = Notification:new{text = "正在读取索引文件 index.json ..."}
        UIManager:show(fetch_notification)

        UIManager:scheduleIn(0, function()
            local filtered_items, err = self:fetchAndFilterWebDAVIndex(server, api)
            UIManager:close(fetch_notification)

            if not filtered_items then
                UIManager:show(InfoMessage:new{
                    text = "未找到 index.json 或索引文件错误。请在 WebDAV 根目录运行 Python 脚本生成索引文件。",
                    timeout = 5
                })
                return
            end

            -- 构建待下载列表（比较文件大小）
            local download_list = {}
            for _, item in ipairs(filtered_items) do
                local rel_path = item.path          -- 相对于用户设置的远程子目录
                local local_path = local_dir .. "/" .. rel_path
                local_path = local_path:gsub("//+", "/")
                local remote_size = tonumber(item.size) or -1
                local local_size = lfs.attributes(local_path, "size")

                if not local_size or (remote_size ~= -1 and local_size ~= remote_size) then
                    table.insert(download_list, {
                        cloud_path = item.full_path,   -- 完整路径（相对于根目录），用于下载
                        target_path = local_path,
                        filename = rel_path:match("([^/]+)$") or rel_path
                    })
                else
                    logger.info("TestSync: 跳过 " .. local_path .. " (文件大小相同)")
                end
            end

            if #download_list == 0 then
                UIManager:show(InfoMessage:new{text = "没有需要下载的文件（所有文件大小一致）", timeout = 3})
                return
            end

            self:showSelectionDialog(download_list, server, api)
        end)
        return
    end

    -- Dropbox 模式：使用实时遍历方式
    if server.type == "dropbox" then
        self:syncDropboxLegacy(server, api, local_dir)
    else
        UIManager:show(InfoMessage:new{text = "不支持的云存储类型。", timeout = 3})
    end
end

--- Dropbox 同步逻辑（保持原有实时遍历方式）
-- @param server 服务器配置
-- @param api Dropbox API 实例
-- @param local_dir 本地目录路径
function TestSyncPlugin:syncDropboxLegacy(server, api, local_dir)
    local fetch_notification = Notification:new{text = "正在获取远程文件列表..."}
    UIManager:show(fetch_notification)

    UIManager:scheduleIn(0, function()
        local download_list = {}

        local function collectFiles(remote_folder, local_folder)
            local token = server.password
            if server.address and server.address ~= "" then
                token = api:getAccessToken(server.password, server.address)
            end
            local items = api:listFolder(remote_folder, token, false)

            if not items or type(items) ~= "table" then
                logger.warn("TestSync: 列出目录失败 " .. tostring(remote_folder))
                return
            end

            for _, item in ipairs(items) do
                local filename = item.text
                local cloud_path = item.url

                if filename and filename ~= "" and filename ~= "." and filename ~= ".." then
                    local clean_filename = filename:gsub("/$", "")
                    local target_path = local_folder .. "/" .. clean_filename

                    if item.type == "directory" or item.type == "folder" or item.is_dir then
                        collectFiles(cloud_path, target_path)
                    elseif item.type == "file" then
                        local remote_size = tonumber(item.filesize) or tonumber(item.size) or -1
                        local local_size = lfs.attributes(target_path, "size")
                        if not local_size or (remote_size ~= -1 and local_size ~= remote_size) then
                            table.insert(download_list, {
                                cloud_path = cloud_path,
                                target_path = target_path,
                                filename = clean_filename
                            })
                        else
                            logger.info("TestSync: 跳过 " .. target_path .. " (文件大小相同)")
                        end
                    end
                end
            end
        end

        collectFiles(server.url, local_dir)
        UIManager:close(fetch_notification)

        if #download_list == 0 then
            UIManager:show(InfoMessage:new{text = "未找到可下载的文件或目录为空。", timeout = 3})
            return
        end

        self:showSelectionDialog(download_list, server, api)
    end)
end

--- 显示文件选择对话框，用户可勾选需要下载的文件
-- @param download_list 待下载文件信息列表（含 cloud_path, target_path, filename）
-- @param server 服务器配置
-- @param api API 实例
function TestSyncPlugin:showSelectionDialog(download_list, server, api)
    local function show_dialog(page, selected_states)
        local ButtonDialog = require("ui/widget/buttondialog")
        local dialog

        local items_per_page = 10
        local total_pages = math.ceil(#download_list / items_per_page)
        if page < 1 then page = 1 end
        if page > total_pages then page = total_pages end

        local start_idx = (page - 1) * items_per_page + 1
        local end_idx = math.min(page * items_per_page, #download_list)

        local buttons = {}
        for i = start_idx, end_idx do
            local file_info = download_list[i]
            local is_selected = selected_states[i] or false
            table.insert(buttons, {
                {
                    text = (is_selected and "[✓] " or "[ ] ") .. file_info.filename,
                    callback = function()
                        selected_states[i] = not is_selected
                        if dialog then UIManager:close(dialog) end
                        show_dialog(page, selected_states)
                    end
                }
            })
        end

        local nav_buttons = {}
        if total_pages > 1 then
            table.insert(nav_buttons, {
                text = page > 1 and "◀" or " ",
                enabled = page > 1,
                callback = function()
                    if dialog then UIManager:close(dialog) end
                    show_dialog(page - 1, selected_states)
                end
            })
            table.insert(nav_buttons, {
                text = string.format("%d / %d", page, total_pages),
                enabled = false
            })
            table.insert(nav_buttons, {
                text = page < total_pages and "▶" or " ",
                enabled = page < total_pages,
                callback = function()
                    if dialog then UIManager:close(dialog) end
                    show_dialog(page + 1, selected_states)
                end
            })
            table.insert(buttons, nav_buttons)
        end

        local selected_count = 0
        for i = 1, #download_list do
            if selected_states[i] then selected_count = selected_count + 1 end
        end

        table.insert(buttons, {
            {
                text = "全选",
                callback = function()
                    for i = 1, #download_list do selected_states[i] = true end
                    if dialog then UIManager:close(dialog) end
                    show_dialog(page, selected_states)
                end
            },
            {
                text = "全不选",
                callback = function()
                    for i = 1, #download_list do selected_states[i] = false end
                    if dialog then UIManager:close(dialog) end
                    show_dialog(page, selected_states)
                end
            }
        })

        table.insert(buttons, {
            {
                text = "取消",
                callback = function()
                    if dialog then UIManager:close(dialog) end
                end
            },
            {
                text = string.format("开始同步 (%d 个文件)", selected_count),
                callback = function()
                    if dialog then UIManager:close(dialog) end
                    local final_list = {}
                    for i = 1, #download_list do
                        if selected_states[i] then
                            table.insert(final_list, download_list[i])
                        end
                    end
                    if #final_list == 0 then
                        UIManager:show(InfoMessage:new{text = "请至少选择一个文件", timeout = 2})
                        return
                    end
                    self:executeDownload(final_list, server, api)
                end
            }
        })

        dialog = ButtonDialog:new{
            title = "选择要下载的文件",
            buttons = buttons
        }
        UIManager:show(dialog)
    end

    local initial_states = {}
    for i = 1, #download_list do initial_states[i] = true end
    show_dialog(1, initial_states)
end

--- 执行下载：创建父目录，显示进度条，依次下载选中的文件
-- @param download_list 需要下载的文件列表
-- @param server 服务器配置
-- @param api API 实例
function TestSyncPlugin:executeDownload(download_list, server, api)
    -- 创建所有需要下载的文件的父目录
    local parent_dirs = {}
    for _, file_info in ipairs(download_list) do
        local target_path = file_info.target_path
        local parent = target_path:match("^(.*)/[^/]+$")
        if parent and parent ~= "" then
            parent_dirs[parent] = true
        end
    end
    if self.settings.local_dir and lfs.attributes(self.settings.local_dir, "mode") ~= "directory" then
        parent_dirs[self.settings.local_dir] = true
    end
    for dir, _ in pairs(parent_dirs) do
        if lfs.attributes(dir, "mode") ~= "directory" then
            os.execute("mkdir -p " .. string.format("%q", dir))
        end
    end

    local ProgressbarDialog = require("ui/widget/progressbardialog")
    local blitbuffer = require("ffi/blitbuffer")
    local progress_dialog = ProgressbarDialog:new{
        title = "正在下载文件",
        text = "准备下载...",
        progress = 0,
        progress_max = #download_list,
    }
    if progress_dialog.progress_bar then
        progress_dialog.progress_bar.fillcolor = blitbuffer.COLOR_BLACK
    end
    UIManager:show(progress_dialog)

    local current_idx = 1
    local success_count = 0

    local function download_next()
        if current_idx > #download_list then
            progress_dialog:close()
            UIManager:show(InfoMessage:new{
                text = string.format("同步完成！\n成功: %d 个，失败/跳过: %d 个", success_count, #download_list - success_count),
                timeout = 3
            })
            return
        end

        local file_info = download_list[current_idx]
        progress_dialog.text = "正在下载: " .. file_info.filename
        progress_dialog:reportProgress(current_idx - 1)
        UIManager:setDirty(progress_dialog, "ui")

        UIManager:scheduleIn(0.1, function()
            local code
            if server.type == "dropbox" then
                local token = server.password
                if server.address and server.address ~= "" then
                    token = api:getAccessToken(server.password, server.address)
                end
                code = api:downloadFile(file_info.cloud_path, token, file_info.target_path, nil)
            elseif server.type == "webdav" then
                -- 使用完整路径（相对于 WebDAV 根目录）进行下载
                local download_url = api:getJoinedPath(server.address, file_info.cloud_path)
                code = api:downloadFile(download_url, server.username, server.password, file_info.target_path, nil)
            end

            if code == 200 or code == 201 or code == 207 or code == 206 then
                logger.info("TestSync: 已下载 " .. file_info.target_path)
                success_count = success_count + 1
            else
                logger.warn("TestSync: 下载失败 " .. tostring(file_info.filename) .. "，HTTP 状态码 " .. tostring(code))
            end

            current_idx = current_idx + 1
            UIManager:scheduleIn(0, download_next)
        end)
    end

    UIManager:scheduleIn(0.1, download_next)
end

return TestSyncPlugin