-- See Copyright Notice in LICENSE.txt

util = {}

function util.shader_loader(filename)
    return resource.create_shader(resource.load_file(filename))
end

function util.videoplayer(name, opt)
    local stream, start, fps, frame, width, height

    local function open_stream()
        stream = resource.load_video(name)
        start = sys.now()
        fps = stream:fps()
        frame = 0
        width, height = stream:size()
    end

    open_stream()

    opt = opt or {}
    local speed = opt.speed or 1
    fps = fps * speed

    local loop = true
    if opt.loop ~= nil then loop = opt.loop end

    local done = false

    return {
        draw = function(self, x1, y1, x2, y2, alpha)
            if done then return end
            local now = sys.now()
            local target_frame = (now - start) * fps
            if target_frame > frame + 10 then
                print(string.format(
                    "slow player for '%s'. missed %d frames since last call",
                    name,
                    target_frame - frame
                ))
                -- too slow to decode. rebase time
                start = now - frame * 1/fps
            else
                while frame < target_frame do
                    if not stream:next() then
                        if loop then
                            print("player: looping")
                            open_stream()
                            stream:next()
                            break
                        else
                            -- stream completed
                            done = true
                            return false
                        end
                    end
                    frame = frame + 1
                end
            end
            stream:draw(x1, y1, x2, y2, alpha)
            return true
        end;
        texid = function(self)
            return stream:texid()
        end;
        next = function(self)
            return not done
        end;
        state = function(self)
            return stream:state()
        end;
        size = function(self)
            return stream:size()
        end;
        dispose = function(self)
            return stream:dispose()
        end;
    }
end

util.loaders = {
    png  = resource.load_image;
    jpg  = resource.load_image;
    jpeg = resource.load_image;
    gif  = resource.load_image;
    bmp  = resource.load_image;
    ttf  = resource.load_font;
    otf  = resource.load_font;
    avi  = util.videoplayer;
    mpg  = util.videoplayer;
    ogg  = util.videoplayer;
    flv  = util.videoplayer;
    mkv  = util.videoplayer;
    mp4  = util.videoplayer;
    mov  = util.videoplayer;
    frag = util.shader_loader;
}

function util.auto_loader(container, filter)
    container = container or {}
    filter = filter or function() return true end
    local loaded_version = {}
    local function auto_load(name)
        if filter and not filter(name) then
            return
        end
        if loaded_version[name] == CONTENTS[name] then
            -- print("auto_loader: already loaded " .. name)
            return
        end
        local target, suffix = name:match("(.*)[.]([^.]+)$")
        if not target then
            print("loader: invalid resource name " .. name .. ". ignoring " .. name)
            return
        end
        local loader = util.loaders[suffix]
        if not loader then
            print("loader: no resource loader for suffix " .. suffix .. ". ignoring " .. name)
            return
        end
        local success, res = pcall(loader, name)
        if not success then
            print("loader: cannot load " .. name .. ": " .. res)
        else
            print("loader: updated " .. target .. " (triggered by " .. name .. ")")
            container[target] = res
            loaded_version[name] = CONTENTS[name]
        end
    end
    print("loader: loading known resources")
    for name, added in pairs(CONTENTS) do
        auto_load(name)
    end
    node.event("content_update", auto_load)
    node.event("content_remove", function(name)
        local target, suffix = name:match("(.*)[.]([^.]+)$")
        if target and util.loaders[suffix] and container[target] then
            print("loader: unloaded " .. target .. " (triggered by " .. name .. ")")
            container[target] = nil
            loaded_version[name] = nil
        end
    end)
    return container
end

function util.resource_loader(resources, container)
    container = container or _G
    local whitelist = {}
    for _, name in ipairs(resources) do
        whitelist[name] = true
    end
    return util.auto_loader(container, function(name)
        return whitelist[name]
    end)
end

function util.file_watch(filename, handler)
    local loaded_version = nil
    local function updated(name)
        if name ~= filename then
            return
        end
        if loaded_version == CONTENTS[filename] then
            return
        end
        loaded_version = CONTENTS[filename]
        handler(resource.load_file(filename))
    end
    node.event("content_update", updated)
    updated(filename)
end

local function handle_suffix_match(suffix, pattern, callback, ...)
    local data = {...}
    return (function(s, e, ...)
        if s == nil then
            return false
        end
        local args = {...}
        for n = 1, #data do
            args[#args+1] = data[n]
        end
        callback(unpack(args))
        return true
    end)(suffix:find(pattern))
end

function util.osc_mapper(routes)
    node.event("osc", function(suffix, ...)
        for pattern, callback in pairs(routes) do
            if handle_suffix_match(suffix, pattern, callback, ...) then
                return
            end
        end
    end)
end

function util.data_mapper(routes)
    node.event("data", function(data, suffix)
        for pattern, callback in pairs(routes) do
            if handle_suffix_match(suffix, pattern, callback, data) then
                return
            end
        end
    end)
end

function util.generator(refiller)
    local items = {}
    return {
        next = function(self)
            local next_item = next(items)
            if not next_item then
                for _, value in ipairs(refiller()) do
                    items[value] = 1
                end
                next_item = next(items)
                if not next_item then
                    error("no items available")
                end
            end
            items[next_item] = nil
            return next_item
        end;
        add = function(self, value)
            items[value] = 1
        end;
        remove = function(self, value)
            items[value] = nil
        end;
    }
end

function util.set_interval(interval, callback)
    local next_call = sys.now() + interval
    node.event("render", function()
        local now = sys.now()
        if now > next_call then
            next_call = now + interval
            callback()
        end
    end)
    callback()
end

function util.post_effect(shader, shader_opt)
    local surface = resource.create_snapshot()
    gl.ortho()
    gl.clear(0,0,0,1)
    shader:use(shader_opt)
    surface:draw(0, 0, WIDTH, HEIGHT)
    shader:deactivate()
end

function util.running_text(opt)
    local current_idx = 1
    local current_left = 0
    local last = sys.now()

    local generator = opt.generator
    local font = opt.font
    local size = opt.size or 10
    local speed = opt.speed or 10
    local color = opt.color or {1,1,1,1}

    local texts = {}
    return {
        draw = function(self, y)
            local now = sys.now()
            local xoff = current_left
            local idx = 1
            while xoff < WIDTH do
                if #texts < idx then
                    table.insert(texts, generator.next())
                end
                local width = font:write(xoff, y, texts[idx] .. "   -   ", size, unpack(color))
                xoff = xoff + width
                if xoff < 0 then
                    current_left = xoff
                    table.remove(texts, idx)
                else
                    idx = idx + 1
                end
            end
            local delta = now - last
            last = now
            current_left = current_left - delta * speed
        end;
        add = function(self, text)
            generator:add(text)
        end;
    }
end

function util.scale_into(target_width, target_height, source_width, source_height)
    local prop_height = source_height * target_width / source_width
    local prop_width  = source_width * target_height / source_height
    local x1, y1, x2, y2
    if prop_height > target_height then
        local x_center = target_width / 2
        local half_width = prop_width / 2
        x1 = x_center - half_width
        y1 = 0
        x2 = x_center + half_width
        y2 = target_height
    else
        local y_center = target_height / 2
        local half_height = prop_height / 2
        x1 = 0
        y1 = y_center - half_height
        x2 = target_width
        y2 = y_center + half_height
    end
    return x1, y1, x2, y2
end

function util.draw_correct(obj, x1, y1, x2, y2, ...)
    local ox1, oy1, ox2, oy2 = util.scale_into(
        x2 - x1, y2 - y1, obj:size()
    )
    obj:draw(x1 + ox1, y1 + oy1, x1 + ox2, y1 + oy2, ...)
end


function table.filter(t, predicate)
    local j = 1

    for i, v in ipairs(t) do
        if predicate(v) then
            t[j] = v
            j = j + 1
        end
    end

    while t[j] ~= nil do
        t[j] = nil
        j = j + 1
    end

    return t
end

-- Based on http://lua-users.org/wiki/TableSerialization
-- Modified to *not* use debug.getinfo

--[[
   Author: Julio Manuel Fernandez-Diaz
   Date:   January 12, 2007
   (For Lua 5.1)
   
   Modified slightly by RiciLake to avoid the unnecessary table traversal in tablecount()

   Formats tables with cycles recursively to any depth.
   The output is returned as a string.
   References to other tables are shown as values.
   Self references are indicated.

   The string returned is "Lua code", which can be procesed
   (in the case in which indent is composed by spaces or "--").
   Userdata and function keys and values are shown as strings,
   which logically are exactly not equivalent to the original code.

   This routine can serve for pretty formating tables with
   proper indentations, apart from printing them:

      print(table.show(t, "t"))   -- a typical use
   
   Heavily based on "Saving tables with cycles", PIL2, p. 113.

   Arguments:
      t is the table.
      name is the name of the table (optional)
      indent is a first indentation (optional).
--]]
function table.show(t, name, indent)
   local cart     -- a container
   local autoref  -- for self references

   -- (RiciLake) returns true if the table is empty
   local function isemptytable(t) return next(t) == nil end

   local function basicSerialize (o)
      local so = tostring(o)
      if type(o) == "function" or type(o) == "number" or type(o) == "boolean" then
         return so
      else
         return string.format("%q", so)
      end
   end

   local function addtocart (value, name, indent, saved, field)
      indent = indent or ""
      saved = saved or {}
      field = field or name

      cart = cart .. indent .. field

      if type(value) ~= "table" then
         cart = cart .. " = " .. basicSerialize(value) .. ";\n"
      else
         if saved[value] then
            cart = cart .. " = {...}; -- " .. saved[value] 
                        .. " (self reference)\n"
            autoref = autoref ..  name .. " = " .. saved[value] .. ";\n"
         else
            saved[value] = name
            --if tablecount(value) == 0 then
            if isemptytable(value) then
               cart = cart .. " = {};\n"
            else
               cart = cart .. " = {\n"
               for k, v in pairs(value) do
                  k = basicSerialize(k)
                  local fname = string.format("%s[%s]", name, k)
                  field = string.format("[%s]", k)
                  -- three spaces between levels
                  addtocart(v, fname, indent .. "   ", saved, field)
               end
               cart = cart .. indent .. "};\n"
            end
         end
      end
   end

   name = name or "__unnamed__"
   if type(t) ~= "table" then
      return name .. " = " .. basicSerialize(t)
   end
   cart, autoref = "", ""
   addtocart(t, name, indent)
   return cart .. autoref
end

function table.keys(t)
    local ret = {}
    for k, v in pairs(t) do 
        ret[#ret+1] = k
    end
    return ret
end

function pp(t)
    print(table.show(t))
end

-- Sandboxed package loader
package = {
    loadlib = function(libname, funcname)
        error("no native linking")
    end;

    seeall = function(module)
        return setmetatable(module, {
            __index = _G
        })
    end;

    loaded = {
        table = table;
        string = string;
        math = math;
        table = table;
        coroutine = coroutine;
        debug = debug;
        struct = struct;

        util = util;

        sys = sys;
        gl = gl;
        resource = resource;
    };

    loaders = {
        function(modname)
            local filename = modname .. ".lua"
            local status, content = pcall(resource.load_file, filename)
            if not status then
                return "no file " .. filename .. ": " .. content
            else
                return function(loader_modname)
                    assert(loader_modname == modname)
                    local filename = PATH .. "/" .. modname .. ".lua"
                    return assert(loadstring(content, "=" .. filename))(modname)
                end, filename
            end
        end;

        -- bundled moduls loader
        function(modname)
            local filename = modname .. ".lua"
            local content = _BUNDLED_MODULES[filename]
            if not content then
                return "no file " .. filename
            else
                return function(loader_modname)
                    print("loading bundled module '" .. loader_modname .. "'")
                    assert(loader_modname == modname)
                    return assert(loadstring(content, "=" .. filename))(modname)
                end, filename
            end
        end
    };
}
package.loaded['package'] = package

function require(modname)
    local loaded = package.loaded[modname]
    if loaded then
        return loaded
    end

    -- find loader
    local loader
    local errors = {"module '" .. modname .. "' not found:"}
    for _, searcher in ipairs(package.loaders) do
        local searcher_val = searcher(modname)
        if type(searcher_val) == "function" then
            loader = searcher_val
            break
        elseif type(searcher_val) == "string" then
            errors[#errors + 1] = "\t" .. searcher_val
        end
    end
    if not loader then
        error(table.concat(errors, "\n"))
    end

    -- load module
    local value = loader(modname)
    if value then
        package.loaded[modname] = value
    elseif not package.loaded[modname] then
        package.loaded[modname] = true
    end
    return package.loaded[modname]
end

function util.json_watch(filename, handler)
    util.file_watch(filename, function(content)
        local json = require "json"
        handler(json.decode(content))
    end)
end

function util.init_hosted()
    local json = require "json"
    local hosted = nil
    local config_json = nil
    local node_json = nil

    local reload_config = function()
        print "[hosted] reloading config"
        -- pp(hosted)
        -- pp(node_json)
        -- pp(config_json)
        if hosted and node_json and config_json then
            local parsed = hosted.parse_config(node_json.options, config_json)
            _G['CONFIG'] = parsed
            node.dispatch("config_update", parsed)
        end
    end
    util.file_watch("hosted.lua", function(content)
        print "[hosted] loading hosted.lua"
        local filename = PATH .. "/hosted.lua"
        hosted = assert(loadstring(content, "=" .. filename))()
        reload_config()
    end)
    util.file_watch("node.json", function(content)
        print("[hosted] loading node.json")
        node_json = json.decode(content)
        _G['NODE'] = node_json
        reload_config()
        node.dispatch("node_update", node_json)
    end)
    util.file_watch("config.json", function(content)
        print("[hosted] loading config.json")
        config_json = json.decode(content)
        reload_config()
    end)
    util.file_watch("package.json", function(content)
        print("[hosted] loading package.json")
        local package_json = json.decode(content)
        _G['PACKAGE'] = package_json
        node.dispatch("package_update", package_json)
    end)
end

-- compatibility with older versions
hosted_init = util.init_hosted

do
    local function red(str)    return "[31m" .. str .. "[0m" end
    local function green(str)  return "[32m" .. str .. "[0m" end
    local function yellow(str) return "[33m" .. str .. "[0m" end

    local handlers = {
        ["boolean"] = function(cmd, info, target)
            local function setup()
                target[cmd] = info.value
            end
            local function info()
                return string.format("(%s)", tostring(target[cmd]))
            end
            local function call(arg)
                local value = ({
                    ["true"] = true;
                    ["1"] = true;
                    ["y"] = true;
                    ["false"] = false;
                    ["0"] = false;
                    ["n"] = false;
                })[arg]
                if value == nil then
                    print(red("invalid value: true/false expected"))
                else
                    target[cmd] = value
                    print(green("value updated"))
                end
            end
            return {
                setup = setup;
                param = "<true|false>";
                info = info;
                call = call;
            }
        end;
        ["string"] = function(cmd, info, target)
            local function setup()
                target[cmd] = info.value
            end
            local function info()
                return string.format("(\"%s\")", target[cmd])
            end
            local function call(arg)
                target[cmd] = arg
                print(green("value updated"))
            end
            return {
                setup = setup;
                param = "<\"new value\">";
                info = info;
                call = call;
            }
        end;
        ["number"] = function(cmd, info, target)
            local function setup()
                target[cmd] = info.value
            end
            local function info()
                return string.format("(%f)", target[cmd])
            end
            local function call(arg)
                local value = tonumber(arg)
                if value == nil then
                    print(red("invalid value: number expected"))
                else
                    target[cmd] = value
                    print(green("value updated"))
                end
            end
            return {
                setup = setup;
                param = "<number>";
                info = info;
                call = call;
            }
        end;
        ["function"] = function(cmd, info, target)
            local function call(arg)
                return info.value(target, readln, arg)
            end
            return {
                setup = function() end;
                param = "";
                info = function() return "" end;
                call = call;
            }
        end;
    }


    local function create_menu_interface(name, target, options, readln)
        if not target then
            target = _G
        end

        for cmd, info in pairs(options) do
            local type = info.type or type(info.value)
            info.handler = handlers[type](cmd, info, target)
            info.handler.setup()
        end

        local function print_help()
            local max_size = 0
            local cmds = {}
            for cmd, info in pairs(options) do
                max_size = math.max(max_size, #cmd + 1 + #info.handler.param)
                cmds[#cmds+1] = cmd
            end
            table.sort(cmds)
            print()
            print(green("Available commands/values:"))
            for idx, cmd in ipairs(cmds) do
                local info = options[cmd]
                print(string.format("%-" .. tostring(max_size) .. "s - %s %s", cmd .. " " .. info.handler.param, info.help, info.handler.info()))
            end
            print()
        end

        return function()
            while true do
                print()
                print(yellow(name .. " - your command"))
                local line = readln()
                if line == "?" or line == "help" then
                    print_help()
                elseif line == "" or line == "exit" then
                    break
                else
                    local cmd, arg = string.match(line, "^([^%s]+) (.*)$")
                    if not cmd then
                        cmd = line
                    end
                    local option = options[cmd]
                    if option then
                        option.handler.call(arg)
                    else
                        print(red("invalid command line \"" .. line .. "\". type '?' for help"))
                    end
                end
            end
        end
    end

    local function create_submenu(name, options)
        return {
            value = function(target, readln)
                return create_menu_interface(name, target, options, readln)()
            end;
            help = name;
        }
    end

    local function create_variable(value, help)
        return {
            value = value;
            help = help;
        }
    end

    local function tcp_export(options, target)
        local main_menu = create_menu_interface("main menu", target, options, function()
            return coroutine.yield()
        end)

        if not N.clients then
            N.clients = {}
        end

        node.event("connect", function(client)
            local handler = coroutine.wrap(function()
                print(green("configuration interface for " .. PATH))
                print(green("-----------------------------------------"))
                while true do
                    main_menu()
                end
            end)
            N.clients[client] = handler
            handler()
        end)

        node.event("input", function(line, client)
            N.clients[client](line)
        end)

        node.event("disconnect", function(client)
            N.clients[client] = nil
        end)
    end

    util.menu = {
        tcp = tcp_export;
        sub = create_submenu;
        var = create_variable;
    }
end
