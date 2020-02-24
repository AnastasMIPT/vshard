test_run = require('test_run').new()
REPLICASET_1 = { 'storage_1_a', 'storage_1_b' }
REPLICASET_2 = { 'storage_2_a', 'storage_2_b' }

test_run:create_cluster(REPLICASET_1, 'storage')
test_run:create_cluster(REPLICASET_2, 'storage')
util = require('util')
util.wait_master(test_run, REPLICASET_1, 'storage_1_a')
util.wait_master(test_run, REPLICASET_2, 'storage_2_a')
util.push_rs_filters(test_run)
--
-- Test timeout error during bucket sending, when on a destination
-- bucket becomes active.
--
_ = test_run:switch('storage_2_a')
vshard.storage.internal.errinj.ERRINJ_LAST_RECEIVE_DELAY = true
_ = test_run:switch('storage_1_a')
_bucket = box.space._bucket
_bucket:replace{1, vshard.consts.BUCKET.ACTIVE, util.replicasets[2]}
ret, err = vshard.storage.bucket_send(1, util.replicasets[2], {timeout = 0.1})
ret, err.code
_bucket = box.space._bucket
_bucket:get{1}

_ = test_run:switch('storage_2_a')
vshard.storage.internal.errinj.ERRINJ_LAST_RECEIVE_DELAY = false
_bucket = box.space._bucket
while _bucket:get{1}.status ~= vshard.consts.BUCKET.ACTIVE do fiber.sleep(0.01) end
_bucket:get{1}

_ = test_run:switch('storage_1_a')
while _bucket:count() ~= 0 do vshard.storage.recovery_wakeup() fiber.sleep(0.1) end

_ = test_run:switch("default")
test_run:drop_cluster(REPLICASET_2)
test_run:drop_cluster(REPLICASET_1)
_ = test_run:cmd('clear filter')
