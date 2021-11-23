test_run = require('test_run').new()
REPLICASET_1 = { 'storage_1_a', 'storage_1_b' }
REPLICASET_2 = { 'storage_2_a', 'storage_2_b' }
test_run:create_cluster(REPLICASET_1, 'storage')
test_run:create_cluster(REPLICASET_2, 'storage')
util = require('util')
util.wait_master(test_run, REPLICASET_1, 'storage_1_a')
util.wait_master(test_run, REPLICASET_2, 'storage_2_a')

test_run:switch('storage_1_a')
fiber = require('fiber')
s = box.schema.create_space('test')
pk = s:create_index('pk')
vshard.storage.internal.errinj.ERRINJ_CFG_DELAY = true
cfg.sharding[util.replicasets[1]].replicas[util.name_to_uuid.storage_1_b].master = true
cfg.sharding[util.replicasets[1]].replicas[util.name_to_uuid.storage_1_a].master = false
f = fiber.create(function() vshard.storage.cfg(cfg, util.name_to_uuid.storage_1_a) end)
f:status()
-- Can not write - read only mode is already on.
ok, err = pcall(s.replace, s, {1})
assert(not ok and err.code == box.error.READONLY)

test_run:switch('storage_1_b')
cfg.sharding[util.replicasets[1]].replicas[util.name_to_uuid.storage_1_b].master = true
cfg.sharding[util.replicasets[1]].replicas[util.name_to_uuid.storage_1_a].master = false
vshard.storage.cfg(cfg, util.name_to_uuid.storage_1_b)
box.space.test:select{}

test_run:switch('storage_1_a')
vshard.storage.internal.errinj.ERRINJ_CFG_DELAY = false
while f:status() ~= 'dead' do fiber.sleep(0.1) end
s:select{}

test_run:switch('storage_1_b')
box.space.test:select{}
box.space.test:drop()

test_run:cmd("switch default")
test_run:drop_cluster(REPLICASET_2)
test_run:drop_cluster(REPLICASET_1)
