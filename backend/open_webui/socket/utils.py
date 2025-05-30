import json
import uuid
from open_webui.utils.redis import get_redis_connection
import logging

log = logging.getLogger(__name__)


class RedisLock:
    def __init__(self, redis_url, lock_name, timeout_secs, redis_sentinels=[]):
        self.lock_name = lock_name
        self.lock_id = str(uuid.uuid4())
        self.timeout_secs = timeout_secs
        self.lock_obtained = False
        self.redis = get_redis_connection(
            redis_url, redis_sentinels, decode_responses=True
        )

    def aquire_lock(self):
        log.debug(f"RedisLock: Attempting to acquire lock '{self.lock_name}'. Redis client: {self.redis}")
        try:
            # nx=True will only set this key if it _hasn't_ already been set
            self.lock_obtained = self.redis.set(
                self.lock_name, self.lock_id, nx=True, ex=self.timeout_secs
            )
            log.debug(f"RedisLock: Lock '{self.lock_name}' acquisition attempt result: {self.lock_obtained}")
            return self.lock_obtained
        except Exception as e:
            log.error(f"RedisLock: Exception during acquire_lock for '{self.lock_name}': {e}", exc_info=True)
            self.lock_obtained = False # Ensure it's false on error
            return False

    def renew_lock(self):
        log.debug(f"RedisLock: Attempting to renew lock '{self.lock_name}'. Redis client: {self.redis}")
        try:
            # xx=True will only set this key if it _has_ already been set
            result = self.redis.set(
                self.lock_name, self.lock_id, xx=True, ex=self.timeout_secs
            )
            log.debug(f"RedisLock: Lock '{self.lock_name}' renewal attempt result: {result}")
            return result
        except Exception as e:
            log.error(f"RedisLock: Exception during renew_lock for '{self.lock_name}': {e}", exc_info=True)
            return False

    def release_lock(self):
        lock_value = self.redis.get(self.lock_name)
        if lock_value and lock_value == self.lock_id:
            self.redis.delete(self.lock_name)


class RedisDict:
    def __init__(self, name, redis_url, redis_sentinels=[]):
        self.name = name
        self.redis = get_redis_connection(
            redis_url, redis_sentinels, decode_responses=True
        )

    def __setitem__(self, key, value):
        serialized_value = json.dumps(value)
        self.redis.hset(self.name, key, serialized_value)

    def __getitem__(self, key):
        value = self.redis.hget(self.name, key)
        if value is None:
            raise KeyError(key)
        return json.loads(value)

    def __delitem__(self, key):
        result = self.redis.hdel(self.name, key)
        if result == 0:
            raise KeyError(key)

    def __contains__(self, key):
        return self.redis.hexists(self.name, key)

    def __len__(self):
        return self.redis.hlen(self.name)

    def keys(self):
        return self.redis.hkeys(self.name)

    def values(self):
        return [json.loads(v) for v in self.redis.hvals(self.name)]

    def items(self):
        return [(k, json.loads(v)) for k, v in self.redis.hgetall(self.name).items()]

    def get(self, key, default=None):
        try:
            return self[key]
        except KeyError:
            return default

    def clear(self):
        self.redis.delete(self.name)

    def update(self, other=None, **kwargs):
        if other is not None:
            for k, v in other.items() if hasattr(other, "items") else other:
                self[k] = v
        for k, v in kwargs.items():
            self[k] = v

    def setdefault(self, key, default=None):
        if key not in self:
            self[key] = default
        return self[key]
