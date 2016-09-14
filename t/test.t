use lib 'lib';
use My::Test::Socket 'no_plan';

$ENV{TEST_NGINX_RESOLVER} = '8.8.8.8';
$ENV{TEST_NGINX_REDIS_PORT} ||= 6379;

$ENV{TEST_NGINX_WORK_DIR} = '/path/to/your_server';
$ENV{TEST_NGINX_MID} = '000';

run_tests();


__DATA__

=== TEST 1: test1

--- init_env
local redis = require "resty.redis"

local mid = "000"
local red = redis:new()

red:set_timeout(1000)

local ok, err = red:connect("127.0.0.1", 6379)
if not ok then
    ngx.say("failed to connect: ", err)
    return
end

red:hmset("test1" .. mid, "1", "2")
red:zadd("test2", 1, mid)

red:close()

--- pipelined_requests eval
# your request
["GET /api/yourapi.json?mid=$ENV{TEST_NGINX_MID}"]

--- response_body eval
["your_response\n"]