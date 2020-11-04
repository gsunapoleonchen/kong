local pl_file = require "pl.file"
local lyaml = require "lyaml"
local raw_log = require "ngx.errlog".raw_log

local logging = require "logging"
local rpc = require "mp_rpc"

local ngx = ngx
local kong = kong
local ngx_INFO = ngx.INFO

local external_plugins = {}

local _servers
local _plugin_infos

local save_for_later = {}


--[[

Configuration

The external_plugins_config YAML file defines a list of plugin servers.  Each one
can have the following fields:

name: (required) a unique string.  Shouldn't collide with Lua packages available as `kong.plugins.<name>`
socket: (required) path of a unix domain socket to use for RPC.
exec: (optional) executable file of the server.  If omitted, the server process won't be managed by Kong.
args: (optional) a list of strings to be passed as command line arguments.
env: (optional) a {string:string} map to be passed as environment variables.
info_cmd: (optional) command line to request plugin info.

--]]

--[[

RPC

Each plugin server specifies a socket path to communicate.  Protocol is the same
as Go plugins.

CONSIDER:

- when a plugin server notifies a new PID, Kong should request all plugins info again.
  Should it use RPC at this time, instead of commandline?

- Should we add a new notification to ask kong to request plugin info again?

--]]


local rpc_notifications = {}


--[[

Instance_id/conf   relation

--]]


--- get_instance_id: gets an ID to reference a plugin instance running in a
--- pluginserver each configuration in the database is handled by a different
--- instance.  Biggest complexity here is due to the remote (and thus non-atomic
--- and fallible) operation of starting the instance at the server.
---
--- reset_instance: removes an instance from the table.
local get_instance_id, reset_instance
do
  local instances = {}

  function get_instance_id(plugin_name, conf)
    local key = type(conf) == "table" and conf.__key__ or plugin_name
    local instance_info = instances[key]

    while instance_info and not instance_info.id do
      -- some other thread is already starting an instance
      ngx.sleep(0)
      instance_info = instances[key]
    end

    if instance_info
      and instance_info.id
      and instance_info.seq == conf.__seq__
    then
      -- exact match, return it
      return instance_info.id
    end

    local old_instance_id = instance_info and instance_info.id
    if not instance_info then
      -- we're the first, put something to claim
      instance_info = {
        conf = conf,
        seq = conf.__seq__,
      }
      instances[key] = instance_info
    else

      -- there already was something, make it evident that we're changing it
      instance_info.id = nil
    end

    local plugin_info = _plugin_infos[plugin_name]

    local status, err = plugin_info.rpc:call("plugin.StartInstance", {
      Name = plugin_name,
      Config = cjson_encode(conf)
    })
    if status == nil then
      kong.log.err("starting instance: ", err)
      -- remove claim, some other thread might succeed
      instances[key] = nil
      error(err)
    end

    instance_info.id = status.Id
    instance_info.conf = conf
    instance_info.seq = conf.__seq__
    instance_info.Config = status.Config
    instance_info.rpc = plugin_info.rpc

    if old_instance_id then
      -- there was a previous instance with same key, close it
      plugin_info.rpc:call("plugin.CloseInstance", old_instance_id)
      -- don't care if there's an error, maybe other thread closed it first.
    end

    return status.Id
  end

  function reset_instance(plugin_name, conf)
    local key = type(conf) == "table" and conf.__key__ or plugin_name
    instances[key] = nil
  end


  --- serverPid notification sent by the pluginserver.  if it changes,
  --- all instances tied to this RPC socket should be restarted.
  function rpc_notifications:serverPid(n)
    n = tonumber(n)
    if self.pluginserver_pid and n ~= self.pluginserver_pid then
      for key, instance in pairs(instances) do
        if instance.rpc == self then
          instances[key] = nil
        end
      end
    end

    self.pluginserver_pid = n
  end
end

--[[

--- Event loop -- instance reconnection

--]]

local function bridge_loop(rpc, instance_id, phase)
  local step_in, err = rpc:call("plugin.HandleEvent", {
    InstanceId = instance_id,
    EventName = phase,
  })
  if not step_in then
    return step_in, err
  end

  local event_id = step_in.EventId

  while true do
    if step_in.Data == "ret" then
      break
    end

    local pdk_res, pdk_err = call_pdk_method(
      step_in.Data.Method,
      step_in.Data.Args)

    local step_method, step_res = get_step_method(step_in, pdk_res, pdk_err)

    step_in, err = rpc:call(step_method, {
      EventId = event_id,
      Data = step_res,
    })
    if not step_in then
      return step_in, err
    end
  end
end


local function handle_event(rpc, plugin_name, conf, phase)
  local instance_id = get_instance_id(plugin_name, conf)
  local _, err = bridge_loop(rpc, instance_id, phase)

  if err then
    kong.log.err(err)

    if string.match(err, "No plugin instance") then
      reset_instance(plugin_name, conf)
      return handle_event(rpc, plugin_name, conf, phase)
    end
  end
end


--- Phase closures
local function build_phases(plugin)
  for _, phase in ipairs(plugin.phases) do
    if phase == "log" then
      plugin[phase] = function(self, conf)
        local saved = {
          serialize_data = kong.log.serialize(),
          ngx_ctx = ngx.ctx,
          ctx_shared = kong.ctx.shared,
        }

        ngx_timer_at(0, function()
          local co = coroutine.running()
          save_for_later[co] = saved

          handle_event(self.name, conf, phase)

          save_for_later[co] = nil
        end)
      end

    else
      plugin[phase] = function(self, conf)
        handle_event(self.rpc, self.name, conf, phase)
      end
    end
  end

  return plugin
end


--[[

Plugin info requests

Disclaimer:  The best way to do it is to have "ListPlugins()" and "GetInfo(plugin)"
RPC methods; but Kong would like to have all the plugin schemas at initialization time,
before full cosocket is available.  At one time, we used blocking I/O to do RPC at
non-yielding phases, but was considered dangerous.  The alternative is to use
`io.popen(cmd)` to ask fot that info.


In the external plugins configuration, the `.info_cmd` field contains a string
to be executed as a command line.  The output should be a JSON string that decodes
as an array of objects, each defining the name, priority, version and schema of one
plugin.

    [{
      "name": ... ,
      "priority": ... ,
      "version": ... ,
      "schema": ... ,
      "phases": [ phase_names ... ],
    },
    {
      ...
    },
    ...
    ]

This array should describe all plugins currently available through this server,
no matter if actually enabled in Kong's configuration or not.

--]]


local function register_plugin_info(server_def, plugin_info)
  if _plugin_infos[plugin_info.name] then
    kong.log.error(string.format("Duplicate plugin name [%s] by %s and %s",
      plugin_info.name, _plugin_infos[plugin_info.name].server_def.name, server_def.name))
    return
  end

  _plugin_infos[plugin_info.name] = {
    server_def = server_def,
    rpc = server_def.rpc,
    name = plugin_info.name,
    PRIORITY = plugin_info.priority,
    VERSION = plugin_info.version,
    schema = plugin_info.schema,
    phases = plugin_info.phases,
  }
end

local function ask_info(server_def)
  if not server_def.info_cmd then
    kong.log.info(string.format("No info query for %s", server_def.name))
    return
  end

  local fd, err = io.popen(server_def.info_cmd)
  if not fd then
    local msg = string.format("loading plugins info from [%s]:\n", server_def.name)
    kong.log.error(msg, err)
    return
  end

  local infos_dump = fd:read("*a")
  fd:close()
  local infos = lyaml.load(infos_dump)
  if type(infos) ~= "table" then
    kong.log.error(string.format("Not a plugin info table: \n%s\n%s",
        server_def.info_cmd, infos_dump))
    return
  end

  for _, plugin_info in ipairs(infos) do
    register_plugin_info(server_def, plugin_info)
  end
end

local function load_all_infos()
  if not kong.configuration.external_plugins_config then
    kong.log.info("no external plugins")
    return
  end

  if not _plugin_infos then
    local conf = lyaml.load(assert(pl_file.read(kong.configuration.external_plugins_config)))
    _plugin_infos = {}

    for _, server_def in ipairs(conf) do
      ask_info(server_def)
    end
  end

  return _plugin_infos
end


local loaded_plugins = {}

function external_plugins.load_plugin(plugin_name)
  if not loaded_plugins[plugin_name] then
    local plugin = load_all_infos()[plugin_name]
    loaded_plugins[plugin_name] = build_phases(plugin)
  end

  return loaded_plugins[plugin_name]
end

function external_plugins.load_schema(plugin_name)
  local plugin_info = external_plugins.load_plugin(plugin_name)
  return plugin_info and plugin_info.schema
end


--[[

Process management

Servers that specify an `.exec` field are launched and managed by Kong.
This is an attempt to duplicate the smallest reasonable subset of systemd.

Each process specifies executable, arguments and environment.
Stdout and stderr are joined and logged, if it dies, Kong logs the event
and respawns the server.

--]]

local function grab_logs(proc)
  while true do
    local data, err, partial = proc:stdout_read_line()
    local line = data or partial
    if line and line ~= "" then
      raw_log(ngx_INFO, "[go-pluginserver] " .. line)
    end

    if not data and err == "closed" then
      return
    end
  end
end

local function handle_server(server_def)
  if not server_def.socket then
    -- no error, just ignore
    return
  end

  if server_def.exec then
    ngx_timer_at(0, function(premature)
      if premature then
        return
      end

      local ngx_pipe = require "ngx.pipe"

      while not ngx.worker.exiting() do
        kong.log.notice("Starting " .. server_def.name or "")
        server_def.proc = assert(ngx_pipe.spawn({
          server_def.exec, table.unpack(server_def.args or {})
        }, { environ = server_def.environment }))
        server_def.proc:set_timeouts(nil, nil, nil, 0)     -- block until something actually happens

        server_def.rpc = rpc.new(server_def.socket, rpc_notifications)

        while true do
          grab_logs(server_def.proc)
          local ok, reason, status = server_def.proc:wait()
          if ok ~= nil or reason == "exited" then
            kong.log.notice("external pluginserver '", server_def.name, "' terminated: ", tostring(reason), " ", tostring(status))
            break
          end
        end
      end
      kong.log.notice("Exiting: go-pluginserver not respawned.")
    end)
  end

  return server_def
end

function external_plugins.manage_servers()
  if ngx.worker.id() ~= 0 then
    kong.log.notice("only worker #0 can manage")
    return
  end
  assert(not _servers, "don't call manage_servers() more than once")
  _servers = {}

  if not kong.configuration.external_plugins_config then
    kong.log.info("no external plugins")
    return
  end

  local content = assert(pl_file.read(kong.configuration.external_plugins_config))
  local conf = lyaml.load(content)

  print("conf! ", logging.tostring(conf))

  for i, server_def in ipairs(conf) do
    if not server_def.name then
      server_def.name = string.format("plugin server #%d", i)
    end

    local server, err = handle_server(server_def)
    if not server then
      kong.log.error(err)
    else

      _servers[#_servers + 1] = server
    end
  end
end

return external_plugins
