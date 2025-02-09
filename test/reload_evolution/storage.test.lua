test_run = require('test_run').new()
git_util = require('git_util')
util = require('util')

-- Last meaningful to test commit:
--
--     "router: fix reload problem with global function refs".
--
last_compatible_commit = '139223269cddefe2ba4b8e9f6e44712f099f4b35'
vshard_copy_path = util.git_checkout('vshard_git_tree_copy',                    \
                                     last_compatible_commit)

REPLICASET_1 = { 'storage_1_a', 'storage_1_b' }
REPLICASET_2 = { 'storage_2_a', 'storage_2_b' }
test_run:create_cluster(REPLICASET_1, 'reload_evolution')
test_run:create_cluster(REPLICASET_2, 'reload_evolution')
util = require('util')
util.wait_master(test_run, REPLICASET_1, 'storage_1_a')
util.wait_master(test_run, REPLICASET_2, 'storage_2_a')
util.map_evals(test_run, {REPLICASET_1, REPLICASET_2}, 'bootstrap_storage(\'memtx\')')

test_run:switch('storage_1_a')
vshard.storage.bucket_force_create(1, vshard.consts.DEFAULT_BUCKET_COUNT / 2)
bucket_id_to_move = vshard.consts.DEFAULT_BUCKET_COUNT

test_run:switch('storage_2_a')
vshard.storage.bucket_force_create(vshard.consts.DEFAULT_BUCKET_COUNT / 2 + 1, vshard.consts.DEFAULT_BUCKET_COUNT / 2)
bucket_id_to_move = vshard.consts.DEFAULT_BUCKET_COUNT
vshard.storage.internal.reload_version
wait_rebalancer_state('The cluster is balanced ok', test_run)
box.space.test:insert({42, bucket_id_to_move})

-- Make the old sources invisible. Next require() is supposed to
-- use the most actual source.
package.path = original_package_path
package.loaded['vshard.storage'] = nil
vshard.storage = require("vshard.storage")
test_run:grep_log('storage_2_a', 'vshard.storage.reload_evolution: upgraded to') ~= nil
vshard.storage.internal.reload_version
--
-- gh-237: should be only one trigger. During gh-237 the trigger installation
-- became conditional and therefore required to remember the current trigger
-- somewhere. When reloaded from the old version, the trigger needed to be
-- fetched from _bucket:on_replace().
--
#box.space._bucket:on_replace()

-- Make sure storage operates well.
vshard.storage.bucket_force_drop(2000)
vshard.storage.bucket_force_create(2000)
vshard.storage.buckets_info()[2000]
vshard.storage.call(bucket_id_to_move, 'read', 'do_select', {42})
vshard.storage.bucket_send(bucket_id_to_move, util.replicasets[1])
wait_bucket_is_collected(bucket_id_to_move)
test_run:switch('storage_1_a')
while box.space._bucket:get{bucket_id_to_move}.status ~= vshard.consts.BUCKET.ACTIVE do vshard.storage.recovery_wakeup() fiber.sleep(0.01) end
vshard.storage.bucket_send(bucket_id_to_move, util.replicasets[2])
test_run:switch('storage_2_a')
box.space._bucket:get{bucket_id_to_move}
vshard.storage.call(bucket_id_to_move, 'read', 'do_select', {42})
-- Check info() does not fail.
vshard.storage.info() ~= nil

--
-- Send buckets to create a disbalance. Wait until the rebalancer
-- repairs it. Similar to `tests/rebalancer/rebalancer.test.lua`.
--
vshard.storage.rebalancer_disable()
move_start = vshard.consts.DEFAULT_BUCKET_COUNT / 2 + 1
move_cnt = 100
assert(move_start + move_cnt < vshard.consts.DEFAULT_BUCKET_COUNT)
for i = move_start, move_start + move_cnt - 1 do box.space._bucket:delete{i} end
box.space._bucket.index.status:count({vshard.consts.BUCKET.ACTIVE})
test_run:switch('storage_1_a')
move_start = vshard.consts.DEFAULT_BUCKET_COUNT / 2 + 1
move_cnt = 100
vshard.storage.bucket_force_create(move_start, move_cnt)
box.space._bucket.index.status:count({vshard.consts.BUCKET.ACTIVE})
test_run:switch('storage_2_a')
vshard.storage.rebalancer_enable()
wait_rebalancer_state('The cluster is balanced ok', test_run)
box.space._bucket.index.status:count({vshard.consts.BUCKET.ACTIVE})
test_run:switch('storage_1_a')
box.space._bucket.index.status:count({vshard.consts.BUCKET.ACTIVE})

--
-- Ensure storage refs are enabled and work from the scratch via reload.
--
lref = require('vshard.storage.ref')
vshard.storage.rebalancer_disable()

big_timeout = 1000000
timeout = 0.01
lref.add(0, 0, big_timeout)
status_index = box.space._bucket.index.status
bucket_id_to_move = status_index:min({vshard.consts.BUCKET.ACTIVE}).id
ok, err = vshard.storage.bucket_send(bucket_id_to_move, util.replicasets[2],    \
                                     {timeout = timeout})
assert(not ok and err.message)
lref.del(0, 0)
vshard.storage.bucket_send(bucket_id_to_move, util.replicasets[2],              \
                           {timeout = big_timeout})
wait_bucket_is_collected(bucket_id_to_move)

test_run:switch('storage_2_a')
vshard.storage.rebalancer_disable()

big_timeout = 1000000
bucket_id_to_move = test_run:eval('storage_1_a', 'return bucket_id_to_move')[1]
vshard.storage.bucket_send(bucket_id_to_move, util.replicasets[1],              \
                           {timeout = big_timeout})
wait_bucket_is_collected(bucket_id_to_move)

test_run:switch('default')
test_run:drop_cluster(REPLICASET_2)
test_run:drop_cluster(REPLICASET_1)
test_run:cmd('clear filter')
