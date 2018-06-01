test_run = require('test_run').new()
test_run:cmd("push filter '.*/init.lua.*[0-9]+: ' to ''")
netbox = require('net.box')
fiber = require('fiber')

REPLICASET_1 = { 'storage_1_a', 'storage_1_b' }
REPLICASET_2 = { 'storage_2_a', 'storage_2_b' }

test_run:create_cluster(REPLICASET_1, 'router')
test_run:create_cluster(REPLICASET_2, 'router')
util = require('util')
util.wait_master(test_run, REPLICASET_1, 'storage_1_a')
util.wait_master(test_run, REPLICASET_2, 'storage_2_a')
test_run:cmd("create server router_1 with script='router/router_1.lua'")
test_run:cmd("start server router_1")

replicaset1_uuid = test_run:eval('storage_1_a', 'box.info.cluster.uuid')[1]
replicaset2_uuid = test_run:eval('storage_2_a', 'box.info.cluster.uuid')[1]
test_run:cmd("push filter '"..replicaset1_uuid.."' to '<replicaset_1>'")
test_run:cmd("push filter '"..replicaset2_uuid.."' to '<replicaset_2>'")

_ = test_run:cmd("switch router_1")
-- gh-46: Ensure a cfg is not destroyed after router.cfg().
cfg.sharding ~= nil

util = require('util')

-- gh-24: log all connnect/disconnect events.
test_run:grep_log('router_1', 'connected to ')
rs1 = vshard.router.internal.replicasets[replicasets[1]]
rs2 = vshard.router.internal.replicasets[replicasets[2]]
fiber = require('fiber')
while not rs1.replica or not rs2.replica do fiber.sleep(0.1) end
-- With no zones the nearest server is master.
rs1.replica == rs1.master
rs2.replica == rs2.master

--
-- Part of gh-76: on reconfiguration do not recreate connections
-- to replicas, that are kept in a new configuration.
--
old_replicasets = vshard.router.internal.replicasets
old_connections = {}
connection_count = 0
test_run:cmd("setopt delimiter ';'")
for _, old_rs in pairs(old_replicasets) do
    for uuid, old_replica in pairs(old_rs.replicas) do
        old_connections[uuid] = old_replica.conn
        connection_count = connection_count + 1
    end
end;
test_run:cmd("setopt delimiter ''");
connection_count == 4
vshard.router.cfg(cfg)
new_replicasets = vshard.router.internal.replicasets
old_replicasets ~= new_replicasets
rs1 = vshard.router.internal.replicasets[replicasets[1]]
rs2 = vshard.router.internal.replicasets[replicasets[2]]
while not rs1.replica or not rs2.replica do fiber.sleep(0.1) end
vshard.router.discovery_wakeup()
-- Check that netbox connections are the same.
test_run:cmd("setopt delimiter ';'")
for _, new_rs in pairs(new_replicasets) do
    for uuid, new_replica in pairs(new_rs.replicas) do
        assert(old_connections[uuid] == new_replica.conn)
    end
end;
test_run:cmd("setopt delimiter ''");

--
-- bucket_id and bucket_count
--

util.check_error(vshard.router.bucket_id) -- invalid arguments
vshard.router.bucket_id(1)
vshard.router.bucket_id(2)
vshard.router.bucket_id({2})
vshard.router.bucket_id('2')
vshard.router.bucket_count()

--
-- Initial distribution
--
util.check_error(vshard.router.call, 1, 'read', 'echo', {123})
replicaset, err = vshard.router.bucket_discovery(1); return err == nil or err
vshard.router.bootstrap()

-- Second one should produce error
vshard.router.bootstrap()

--
-- gh-108: negative bucket count on discovery.
--
vshard.router.internal.route_map = {}
rets = {}
function do_echo() table.insert(rets, vshard.router.callro(1, 'echo', {1})) end
f1 = fiber.create(do_echo) f2 = fiber.create(do_echo)
while f1:status() ~= 'dead' and f2:status() ~= 'dead' do fiber.sleep(0.01) end
vshard.router.info()
rets
rs1.bucket_count
rs2.bucket_count

--
-- Test lua errors.
--
_, e = vshard.router.callro(1, 'raise_client_error', {}, {})
e.trace = nil
e

--
-- gh-48: more precise error messages about bucket unavailability.
--
util.check_error(vshard.router.call, vshard.consts.DEFAULT_BUCKET_COUNT + 1, 'read', 'echo', {123})
util.check_error(vshard.router.call, -1, 'read', 'echo', {123})
util.check_error(vshard.router.call, 0, 'read', 'echo', {123})
replicaset, err = vshard.router.bucket_discovery(0); return err == nil or err
replicaset, err = vshard.router.bucket_discovery(1); return err == nil or err
replicaset, err = vshard.router.bucket_discovery(2); return err == nil or err

test_run:cmd('switch storage_2_a')
box.space._bucket:replace({1, vshard.consts.BUCKET.SENDING})
test_run:cmd('switch storage_1_a')
box.space._bucket:replace({1, vshard.consts.BUCKET.RECEIVING})
test_run:cmd('switch router_1')
-- Ok to read sending bucket.
vshard.router.call(1, 'read', 'echo', {123})
-- Not ok to write sending bucket.
util.check_error(vshard.router.call, 1, 'write', 'echo', {123})

test_run:cmd('switch storage_2_a')
box.space._bucket:replace({1, vshard.consts.BUCKET.ACTIVE})
test_run:cmd('switch storage_1_a')
box.space._bucket:delete({1})
test_run:cmd('switch router_1')

-- Check unavailability of master of a replicaset.
_ = vshard.router.bucket_discovery(2)
_ = vshard.router.bucket_discovery(3)
vshard.router.buckets_info(0, 3)
test_run:cmd('stop server storage_2_a')
util.check_error(vshard.router.call, 1, 'read', 'echo', {123})
vshard.router.buckets_info(0, 3)
test_run:cmd('start server storage_2_a')

--
-- gh-26: API to get netbox by bucket identifier.
--
vshard.router.route(vshard.consts.DEFAULT_BUCKET_COUNT + 100)
util.check_error(vshard.router.route, 'asdfg')
util.check_error(vshard.router.route)
conn = vshard.router.route(1).master.conn
conn.state
-- Test missing master.
rs_uuid = 'ac522f65-aa94-4134-9f64-51ee384f1a54'
rs = vshard.router.internal.replicasets[rs_uuid]
master = rs.master
rs.master = nil
vshard.router.route(1).master
rs.master = master
-- Test reconnect on bucker_route().
master.conn:close()
conn = vshard.router.route(1):connect()
conn:wait_connected()
conn.state

--
-- gh-44: API to get connections to all replicasets.
--
map = vshard.router.routeall()
uuids = {}
for uuid, _ in pairs(map) do table.insert(uuids, uuid) end
uuids

--
-- Function call
--

bucket_id = 1
test_run:cmd("setopt delimiter ';'")

customer = {
    customer_id = 1,
    name = "Customer 1",
    bucket_id = bucket_id,
    accounts = {
        {
            account_id = 10,
            name = "Credit Card",
            balance = 100,
        },
        {
            account_id = 11,
            name = "Debit Card",
            balance = 50,
        },
    }
}
test_run:cmd("setopt delimiter ''");

--
-- gh-69: aliases for router.call - callro and callrw.
--
vshard.router.callrw(bucket_id, 'customer_add', {customer})
vshard.router.callro(bucket_id, 'customer_lookup', {1})
vshard.router.callro(bucket_id + 1500, 'customer_lookup', {1}) -- nothing

--
-- Test errors from router call.
--
new_bid = vshard.consts.DEFAULT_BUCKET_COUNT + 1
space_data = {{1000, {{1}, {2}}}}
-- Insert in a not existing space - it must return box.error.
vshard.router.call(bucket_id, 'write', 'vshard.storage.bucket_recv', {new_bid, 'from_uuid', space_data})

--
-- Monitoring
--

-- All is ok, when all servers are up.
-- gh-103: show bucket info for each replicaset.
vshard.router.info()

-- Remove replica and master connections to trigger alert
-- UNREACHABLE_REPLICASET.
rs = vshard.router.internal.replicasets[replicasets[1]]
master_conn = rs.master.conn
replica_conn = rs.replica.conn
rs.master.conn = nil
rs.replica.conn = nil
info = vshard.router.info()
info.replicasets[rs.uuid]
info.status
info.alerts
rs.master.conn = master_conn
rs.replica.conn = replica_conn

-- Trigger alert MISSING_MASTER by manual removal of master.
master = rs.master
rs.master = nil
info = vshard.router.info()
info.replicasets[rs.uuid]
info.status
info.alerts
rs.master = master

buckets_info = vshard.router.buckets_info()
#buckets_info
buckets_info[1]
buckets_info[1501]

vshard.router.buckets_info(0, 3)
vshard.router.buckets_info(1500, 3)
vshard.router.buckets_info(vshard.consts.DEFAULT_BUCKET_COUNT - 3)
util.check_error(vshard.router.buckets_info, '123')
util.check_error(vshard.router.buckets_info, 123, '456')

--
-- gh-51: discovery fiber.
--
test_run:cmd("setopt delimiter ';'")
function calculate_known_buckets()
    local known_buckets = 0
    for _, rs in pairs(vshard.router.internal.route_map) do
        known_buckets = known_buckets + 1
    end
    return known_buckets
end;
function wait_discovery()
    local known_buckets = 0
    while known_buckets ~= vshard.consts.DEFAULT_BUCKET_COUNT do
        vshard.router.discovery_wakeup()
        fiber.sleep(0.1)
        known_buckets = calculate_known_buckets()
    end
end;
test_run:cmd("setopt delimiter ''");
-- Pin some buckets to ensure, that pinned buckets are discovered
-- too.
test_run:switch('storage_1_a')
first_active = box.space._bucket.index.status:select({vshard.consts.BUCKET.ACTIVE}, {limit = 1})[1].id
vshard.storage.bucket_pin(first_active)
test_run:switch('storage_2_a')
first_active = box.space._bucket.index.status:select({vshard.consts.BUCKET.ACTIVE}, {limit = 1})[1].id
vshard.storage.bucket_pin(first_active)
test_run:switch('router_1')
wait_discovery()
calculate_known_buckets()
test_run:grep_log('router_1', 'was 1, became 1500')
info = vshard.router.info()
info.bucket
info.alerts
test_run:switch('storage_1_a')
vshard.storage.bucket_unpin(first_active)
test_run:switch('storage_2_a')
vshard.storage.bucket_unpin(first_active)
test_run:switch('router_1')

--
-- Ensure the discovery procedure works continuously.
--
test_run:cmd("setopt delimiter ';'")
for i = 1, 100 do
    local rs = vshard.router.internal.route_map[i]
    assert(rs)
    rs.bucket_count = rs.bucket_count - 1
    vshard.router.internal.route_map[i] = nil
end;
test_run:cmd("setopt delimiter ''");
calculate_known_buckets()
info = vshard.router.info()
info.bucket
info.alerts
wait_discovery()
calculate_known_buckets()
test_run:grep_log('router_1', 'was 1400, became 1500')
info = vshard.router.info()
info.bucket
info.alerts

--
-- Configuration: inconsistency master=true on storage and routers
--
-- This test case flips masters in replicasets without changing
-- configuration on router and tests NON_MASTER response
--

-- Test the WRITE request
vshard.router.call(1, 'write', 'echo', { 'hello world' })

-- Shuffle masters
util.shuffle_masters(cfg)

-- Reconfigure storages
test_run:cmd("switch storage_1_a")
cfg.sharding = test_run:eval('router_1', 'return cfg.sharding')[1]
vshard.storage.cfg(cfg, names['storage_1_a'])

test_run:cmd("switch storage_1_b")
cfg.sharding = test_run:eval('router_1', 'return cfg.sharding')[1]
vshard.storage.cfg(cfg, names['storage_1_b'])

test_run:cmd("switch storage_2_a")
cfg.sharding = test_run:eval('router_1', 'return cfg.sharding')[1]
vshard.storage.cfg(cfg, names['storage_2_a'])

test_run:cmd("switch storage_2_b")
cfg.sharding = test_run:eval('router_1', 'return cfg.sharding')[1]
vshard.storage.cfg(cfg, names['storage_2_b'])

-- Test that the WRITE request doesn't work
test_run:cmd("switch router_1")
util.check_error(vshard.router.call, 1, 'write', 'echo', { 'hello world' })

-- Reconfigure router and test that the WRITE request does work
vshard.router.cfg(cfg)
vshard.router.call(1, 'write', 'echo', { 'hello world' })

-- Sync API
vshard.router.sync()
util.check_error(vshard.router.sync, "xxx")
vshard.router.sync(100500)

--
-- gh-81: Check that user passed self arg.
-- This check ensures that in case a vshard user called an
-- object method like this: object.method() instead of
-- object:method(), an appropriate help-error returns.
--
_, replicaset = next(vshard.router.internal.replicasets)
error_messages = {}

test_run:cmd("setopt delimiter ';'")
for _, func in pairs(getmetatable(replicaset).__index) do
    local ok, msg = pcall(func, "arg_of_wrong_type")
    table.insert(error_messages, msg:match("Use .*"))
end;
test_run:cmd("setopt delimiter ''");
error_messages

_, replica = next(replicaset.replicas)
error_messages = {}

test_run:cmd("setopt delimiter ';'")
for _, func in pairs(getmetatable(replica).__index) do
    local ok, msg = pcall(func, "arg_of_wrong_type")
    table.insert(error_messages, msg:match("Use .*"))
end;
test_run:cmd("setopt delimiter ''");
error_messages

_ = test_run:cmd("switch default")
test_run:drop_cluster(REPLICASET_2)

-- gh-24: log all connnect/disconnect events.
while test_run:grep_log('router_1', 'disconnected from ') == nil do fiber.sleep(0.1) end

test_run:cmd("stop server router_1")
test_run:cmd("cleanup server router_1")
test_run:drop_cluster(REPLICASET_1)
test_run:cmd('clear filter')
